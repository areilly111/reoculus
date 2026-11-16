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
 * up front. When the decoder is busy a chunk is dropped; the next
 * keyframe heals the picture.
 */
class H264Decoder(private val textures: TextureRegistry) {
    private var codec: MediaCodec? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var lastPtsUs: Long = 0

    /** Create the decoder and texture. Returns the Flutter texture id. */
    fun create(): Long {
        val entry = textures.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720)
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
        var offset = 0
        while (offset < bytes.size) {
            val index = codec.dequeueInputBuffer(0)
            if (index < 0) break // decoder busy: drop the rest of this chunk
            val buf = codec.getInputBuffer(index) ?: break
            buf.clear()
            val n = minOf(bytes.size - offset, buf.remaining())
            buf.put(bytes, offset, n)
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
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        try { surface?.release() } catch (_: Exception) {}
        surface = null
        try { entry?.release() } catch (_: Exception) {}
        entry = null
    }
}
