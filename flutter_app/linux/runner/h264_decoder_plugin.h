#ifndef H264_DECODER_PLUGIN_H_
#define H264_DECODER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

#ifdef __cplusplus
extern "C" {
#endif

// Registers the reoculus/h264 method channel (create/feed/release)
// and the H.264 decoder behind it. Called once from the runner
// after the generated plugins are registered.
void h264_decoder_plugin_register(FlPluginRegistry* registry);

#ifdef __cplusplus
}
#endif

#endif  // H264_DECODER_PLUGIN_H_
