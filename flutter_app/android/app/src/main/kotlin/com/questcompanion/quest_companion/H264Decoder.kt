package com.questcompanion.quest_companion

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * Raw H.264 (Annex B) decoder for the Android live mirror.
 *
 * questctl streams the headset display with `device mirror-stream`;
 * this class feeds those bytes into the hardware AVC decoder and
 * renders them into a Flutter texture, so the Mirror screen can show
 * the headset live. View only: no input, no recording. The decoder
 * reads SPS/PPS from the stream itself, so no codec config is needed
 * up front. When the decoder is busy the leftover bytes wait in a
 * small pending queue for the next feed instead of being dropped,
 * so the picture does not lose frames on a busy moment. The queue
 * is capped, so a slow decoder can never fall minutes behind.
 */
class H264Decoder(private val textures: TextureRegistry) {
    private var codec: MediaCodec? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var lastPtsUs: Long = 0
    /** Bytes that could not be fed because the decoder was busy. */
    private var pending = ByteArray(0)

    companion object {
        /** Past this much pending data, drop the oldest bytes. */
        private const val MAX_PENDING = 512 * 1024
    }

    /** Create the decoder and texture for a stream of this size. Returns the Flutter texture id. */
    fun create(width: Int, height: Int): Long {
        val entry = textures.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, surface, null, 0)
        codec.start()
        this.entry = entry
        this.surface = surface
        this.codec = codec
        return entry.id()
    }

    /** Feed one chunk of Annex B bytes to the decoder. */
    fun feed(bytes: ByteArray) {
        val codec = this.codec ?: return
        // New bytes join whatever could not be fed last time, so
        // nothing is dropped when the decoder is busy.
        val combined = if (pending.isEmpty()) bytes else pending + bytes
        pending = ByteArray(0)
        var offset = 0
        while (offset < combined.size) {
            val index = codec.dequeueInputBuffer(0)
            if (index < 0) {
                // Decoder busy: keep the rest for the next feed.
                // Cap it so a slow decoder never falls far behind:
                // past the cap the oldest bytes go.
                val rest = combined.copyOfRange(offset, combined.size)
                pending = if (rest.size > MAX_PENDING) {
                    rest.copyOfRange(rest.size - MAX_PENDING, rest.size)
                } else {
                    rest
                }
                break
            }
            val buf = codec.getInputBuffer(index) ?: break
            buf.clear()
            val n = minOf(combined.size - offset, buf.remaining())
            buf.put(combined, offset, n)
            val now = System.nanoTime() / 1000
            lastPtsUs = if (now <= lastPtsUs) lastPtsUs + 1 else now
            codec.queueInputBuffer(index, 0, n, lastPtsUs, 0)
            offset += n
        }
        // Drain rendered frames to the surface.
        val info = MediaCodec.BufferInfo()
        while (true) {
            val out = codec.dequeueOutputBuffer(info, 0)
            if (out < 0) break
            codec.releaseOutputBuffer(out, true)
        }
    }

    fun release() {
        pending = ByteArray(0)
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        try { surface?.release() } catch (_: Exception) {}
        surface = null
        try { entry?.release() } catch (_: Exception) {}
        entry = null
    }
}
