package com.questcompanion.quest_companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var h264: H264Decoder? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reoculus/native")
            .setMethodCallHandler { call, result ->
                if (call.method == "nativeLibraryDir") {
                    result.success(applicationInfo.nativeLibraryDir)
                } else {
                    result.notImplemented()
                }
            }
        // Raw H.264 decoder for the Android live mirror: questctl
        // streams the headset display and this renders it into a
        // Flutter texture. View only, no input.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reoculus/h264")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "create" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            val width = (args?.get("width") as? Number)?.toInt() ?: 1280
                            val height = (args?.get("height") as? Number)?.toInt() ?: 720
                            val decoder = H264Decoder(flutterEngine.renderer)
                            val id = decoder.create(width, height)
                            h264?.release()
                            h264 = decoder
                            result.success(id)
                        } catch (e: Exception) {
                            result.error("no-decoder", "Could not start the video decoder: ${e.message}", null)
                        }
                    }
                    "feed" -> {
                        val bytes = call.arguments as? ByteArray
                        if (bytes == null) {
                            result.error("bad-args", "feed needs bytes", null)
                        } else {
                            h264?.feed(bytes)
                            result.success(null)
                        }
                    }
                    "release" -> {
                        h264?.release()
                        h264 = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
