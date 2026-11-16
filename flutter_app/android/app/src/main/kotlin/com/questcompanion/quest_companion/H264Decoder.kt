package com.questcompanion.quest_companion

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer

/**
 * Raw H.264 (Annex B) decoder for the Android live mirror.
 *
 * questctl streams the headset display with `device mirror-stream`;
 * this class feeds those bytes into the hardware AVC decoder and
 * renders them into a Flutter texture, so the Mirror screen can show
 * the headset live. View only: no input, no recording. When the
 * decoder is busy the leftover bytes wait in a small pending queue
 * for the next feed instead of being dropped, so the picture does
 * not lose frames on a busy moment. The queue is capped, so a slow
 * decoder can never fall minutes behind.
 *
 * The decoder is not configured until the stream's SPS and PPS
 * arrive. A video file carries them in its header, so a player can
 * hand them to the decoder up front; a raw stream only has them
 * in-band, and this decoder used to rely on that alone. The tablet
 * picture stayed blocky on a stream that decodes cleanly elsewhere,
 * while the same clip played fine in the tablet's video player, so
 * the decoder now gets the SPS/PPS as its codec config (csd-0 and
 * csd-1), the way a player does, before any frame is fed.
 */
class H264Decoder(private val textures: TextureRegistry) {
    private var codec: MediaCodec? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var lastPtsUs: Long = 0
    /** Bytes that could not be fed because the decoder was busy. */
    private var pending = ByteArray(0)
    /** Bytes held back until the SPS/PPS arrive and the decoder is configured. */
    private var heldBack = ByteArray(0)
    private var configured = false
    private var width = 1280
    private var height = 720

    companion object {
        /** Past this much pending data, drop the oldest bytes. */
        private const val MAX_PENDING = 512 * 1024
    }

    /** Create the texture for a stream of this size. Returns the Flutter texture id.
     * The decoder itself is created once the stream's SPS/PPS arrive (see feed). */
    fun create(width: Int, height: Int): Long {
        val entry = textures.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        this.entry = entry
        this.surface = surface
        this.width = width
        this.height = height
        return entry.id()
    }

    /** Feed one chunk of Annex B bytes to the decoder. */
    fun feed(bytes: ByteArray) {
        if (!configured) {
            // Hold the bytes until the SPS and PPS show up, then
            // configure the decoder with them as its codec config
            // and feed everything held back, SPS/PPS included.
            heldBack += bytes
            val sps = findNal(heldBack, 7)
            val pps = findNal(heldBack, 8)
            if (sps == null || pps == null) {
                // Cap the held-back bytes so a stream that never
                // sends SPS/PPS cannot grow without bound.
                if (heldBack.size > MAX_PENDING) {
                    heldBack = heldBack.copyOfRange(heldBack.size - MAX_PENDING, heldBack.size)
                }
                return
            }
            val surface = this.surface ?: return
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
            format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, surface, null, 0)
            codec.start()
            this.codec = codec
            configured = true
            val buffered = heldBack
            heldBack = ByteArray(0)
            feedConfigured(buffered)
            return
        }
        feedConfigured(bytes)
    }

    /** Feed bytes to an already configured decoder. */
    private fun feedConfigured(bytes: ByteArray) {
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

    /** Find the first NAL unit of the given type in Annex B bytes.
     * Returns the NAL unit without its start code, or null. */
    private fun findNal(data: ByteArray, type: Int): ByteArray? {
        var i = 0
        while (i + 4 <= data.size) {
            // Find a start code: 0x000001 or 0x00000001.
            val startLen = when {
                i + 3 < data.size && data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte() -> 4
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte() -> 3
                else -> {
                    i++
                    continue
                }
            }
            val nalStart = i + startLen
            if (nalStart >= data.size) return null
            val nalType = data[nalStart].toInt() and 0x1F
            // Find the next start code to bound this unit.
            var j = nalStart + 1
            var next = data.size
            while (j + 3 <= data.size) {
                if (data[j] == 0.toByte() && data[j + 1] == 0.toByte() && data[j + 2] == 1.toByte()) {
                    next = j
                    break
                }
                if (j + 3 < data.size && data[j] == 0.toByte() && data[j + 1] == 0.toByte() && data[j + 2] == 0.toByte() && data[j + 3] == 1.toByte()) {
                    next = j
                    break
                }
                j++
            }
            if (nalType == type) return data.copyOfRange(nalStart, next)
            i = next
        }
        return null
    }

    fun release() {
        pending = ByteArray(0)
        heldBack = ByteArray(0)
        configured = false
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        try { surface?.release() } catch (_: Exception) {}
        surface = null
        try { entry?.release() } catch (_: Exception) {}
        entry = null
    }
}
