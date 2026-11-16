// H.264 decoder plugin for the Linux built-in mirror.
//
// The backend streams the headset display as raw H.264 (Annex B)
// with `device mirror-stream`; this plugin decodes it and shows it
// in a Flutter texture, so the Mirror screen can show the headset
// live inside the app window, the same way MediaCodec does it on
// Android. View only, no input.
//
// Channel "reoculus/h264", same API as the Android decoder:
//   create  -> int texture id (or an error when no decoder exists)
//   feed    -> takes a Uint8List chunk of Annex B bytes
//   release -> stops the decoder and unregisters the texture
//
// The stream is fixed at 1280x720 by the backend. Frames at any
// other size are dropped. Decoding runs on the platform thread:
// a 720p frame takes a few milliseconds, so the UI stays smooth.
//
// The ffmpeg libraries are loaded at runtime with dlopen, not
// linked. Linking them statically drags in the whole codec
// registry (options.o references av_codec_iterate, which pulls
// every codec wrapper and its external library), and bundling the
// shared libraries means shipping ffmpeg's whole dependency
// closure. The AppImage therefore needs nothing: on a computer
// with ffmpeg installed the built-in stream just works, and
// without it create() fails with a clear message.

#include "h264_decoder_plugin.h"

#include <dlfcn.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <string.h>

#define H264_WIDTH 1280
#define H264_HEIGHT 720

// ---- Runtime ffmpeg -----------------------------------------------------
// Function pointers resolved from the system libraries at first use.

typedef struct {
  void* avcodec;
  void* avutil;
  void* swscale;
  const AVCodec* (*find_decoder)(enum AVCodecID);
  AVCodecContext* (*alloc_context3)(const AVCodec*);
  int (*open2)(AVCodecContext*, const AVCodec*, AVDictionary**);
  int (*send_packet)(AVCodecContext*, const AVPacket*);
  int (*receive_frame)(AVCodecContext*, AVFrame*);
  void (*free_context)(AVCodecContext**);
  AVCodecParserContext* (*parser_init)(int);
  int (*parser_parse2)(AVCodecParserContext*, AVCodecContext*,
                       uint8_t**, int*, const uint8_t*, int, int64_t,
                       int64_t, int64_t);
  void (*parser_close)(AVCodecParserContext*);
  AVFrame* (*frame_alloc)(void);
  void (*frame_free)(AVFrame**);
  void (*frame_unref)(AVFrame*);
  AVPacket* (*packet_alloc)(void);
  void (*packet_free)(AVPacket**);
  int (*new_packet)(AVPacket*, int);
  struct SwsContext* (*sws_get_context)(int, int, enum AVPixelFormat,
                                        int, int, enum AVPixelFormat,
                                        int, SwsFilter*, SwsFilter*,
                                        const double*);
  int (*sws_scale)(struct SwsContext*, const uint8_t* const*,
                   const int*, int, int, uint8_t* const*, const int*);
  void (*sws_free_context)(struct SwsContext*);
} FFmpeg;

static FFmpeg g_ff;
static gboolean g_ff_loaded = FALSE;
static gboolean g_ff_tried = FALSE;

// The sonames, newest first. The three libraries move together per
// ffmpeg release (8 = 62/60/9, 7 = 61/59/8, 6 = 60/58/7, 5 = 59/57/6),
// so each set is tried as a whole before moving to the next.
static const char* kAvcodecNames[] = {"libavcodec.so.62", "libavcodec.so.61",
                                      "libavcodec.so.60", "libavcodec.so.59",
                                      "libavcodec.so", NULL};
static const char* kAvutilNames[] = {"libavutil.so.60", "libavutil.so.59",
                                     "libavutil.so.58", "libavutil.so.57",
                                     "libavutil.so", NULL};
static const char* kSwscaleNames[] = {"libswscale.so.9", "libswscale.so.8",
                                      "libswscale.so.7", "libswscale.so.6",
                                      "libswscale.so", NULL};

static void* ff_open_set(const char** names) {
  for (int i = 0; names[i] != NULL; i++) {
    void* handle = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (handle != NULL) {
      return handle;
    }
  }
  return NULL;
}

static gboolean ff_load(void) {
  if (g_ff_tried) {
    return g_ff_loaded;
  }
  g_ff_tried = TRUE;
  g_ff.avcodec = ff_open_set(kAvcodecNames);
  g_ff.avutil = ff_open_set(kAvutilNames);
  g_ff.swscale = ff_open_set(kSwscaleNames);
  if (g_ff.avcodec == NULL || g_ff.avutil == NULL || g_ff.swscale == NULL) {
    return FALSE;
  }
  g_ff.find_decoder = dlsym(g_ff.avcodec, "avcodec_find_decoder");
  g_ff.alloc_context3 = dlsym(g_ff.avcodec, "avcodec_alloc_context3");
  g_ff.open2 = dlsym(g_ff.avcodec, "avcodec_open2");
  g_ff.send_packet = dlsym(g_ff.avcodec, "avcodec_send_packet");
  g_ff.receive_frame = dlsym(g_ff.avcodec, "avcodec_receive_frame");
  g_ff.free_context = dlsym(g_ff.avcodec, "avcodec_free_context");
  g_ff.parser_init = dlsym(g_ff.avcodec, "av_parser_init");
  g_ff.parser_parse2 = dlsym(g_ff.avcodec, "av_parser_parse2");
  g_ff.parser_close = dlsym(g_ff.avcodec, "av_parser_close");
  g_ff.frame_alloc = dlsym(g_ff.avutil, "av_frame_alloc");
  g_ff.frame_free = dlsym(g_ff.avutil, "av_frame_free");
  g_ff.frame_unref = dlsym(g_ff.avutil, "av_frame_unref");
  g_ff.packet_alloc = dlsym(g_ff.avcodec, "av_packet_alloc");
  g_ff.packet_free = dlsym(g_ff.avcodec, "av_packet_free");
  g_ff.new_packet = dlsym(g_ff.avcodec, "av_new_packet");
  g_ff.sws_get_context = dlsym(g_ff.swscale, "sws_getContext");
  g_ff.sws_scale = dlsym(g_ff.swscale, "sws_scale");
  g_ff.sws_free_context = dlsym(g_ff.swscale, "sws_freeContext");
  if (g_ff.find_decoder == NULL || g_ff.alloc_context3 == NULL ||
      g_ff.open2 == NULL || g_ff.send_packet == NULL ||
      g_ff.receive_frame == NULL || g_ff.free_context == NULL ||
      g_ff.parser_init == NULL || g_ff.parser_parse2 == NULL ||
      g_ff.parser_close == NULL || g_ff.frame_alloc == NULL ||
      g_ff.frame_free == NULL || g_ff.frame_unref == NULL ||
      g_ff.packet_alloc == NULL || g_ff.packet_free == NULL ||
      g_ff.new_packet == NULL || g_ff.sws_get_context == NULL ||
      g_ff.sws_scale == NULL || g_ff.sws_free_context == NULL) {
    return FALSE;
  }
  g_ff_loaded = TRUE;
  return TRUE;
}

// ---- Texture ------------------------------------------------------------
// A pixel-buffer texture holding two RGBA frames. The decoder writes
// into the back buffer and swaps; the render thread reads the front
// buffer. The two buffers are never freed, so a pointer handed to
// the render thread stays valid after the swap.

typedef struct {
  FlPixelBufferTexture parent_instance;
  uint8_t* front;
  uint8_t* back;
  GMutex mutex;
} H264Texture;

// G_DEFINE_TYPE uses the class struct but does not declare it.
typedef struct _H264TextureClass H264TextureClass;
struct _H264TextureClass {
  FlPixelBufferTextureClass parent_class;
};

G_DEFINE_TYPE(H264Texture, h264_texture, fl_pixel_buffer_texture_get_type())

static gboolean h264_texture_copy_pixels(FlPixelBufferTexture* texture,
                                         const uint8_t** buffer,
                                         uint32_t* width,
                                         uint32_t* height,
                                         GError** error) {
  (void)error;
  H264Texture* self = (H264Texture*)texture;
  g_mutex_lock(&self->mutex);
  *buffer = self->front;
  *width = H264_WIDTH;
  *height = H264_HEIGHT;
  g_mutex_unlock(&self->mutex);
  return TRUE;
}

static void h264_texture_init(H264Texture* self) {
  self->front = g_malloc0(H264_WIDTH * H264_HEIGHT * 4);
  self->back = g_malloc0(H264_WIDTH * H264_HEIGHT * 4);
  g_mutex_init(&self->mutex);
}

static void h264_texture_dispose(GObject* object) {
  H264Texture* self = (H264Texture*)object;
  g_clear_pointer(&self->front, g_free);
  g_clear_pointer(&self->back, g_free);
  g_mutex_clear(&self->mutex);
  G_OBJECT_CLASS(h264_texture_parent_class)->dispose(object);
}

static void h264_texture_class_init(H264TextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      h264_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = h264_texture_dispose;
}

// Swap the back buffer to the front, so the next render shows it.
static void h264_texture_swap(H264Texture* self) {
  g_mutex_lock(&self->mutex);
  uint8_t* tmp = self->front;
  self->front = self->back;
  self->back = tmp;
  g_mutex_unlock(&self->mutex);
}

// ---- Decoder ------------------------------------------------------------

typedef struct {
  FlTextureRegistrar* registrar;
  FlMethodChannel* channel;
  H264Texture* texture;
  AVCodecContext* codec_ctx;
  AVCodecParserContext* parser;
  AVFrame* frame;
  struct SwsContext* sws;
  int sws_format;
} H264Decoder;

static void h264_decoder_close(H264Decoder* dec) {
  if (dec->texture != NULL && dec->registrar != NULL) {
    fl_texture_registrar_unregister_texture(dec->registrar,
                                            FL_TEXTURE(dec->texture));
  }
  g_clear_object(&dec->texture);
  if (dec->sws != NULL) {
    g_ff.sws_free_context(dec->sws);
    dec->sws = NULL;
  }
  dec->sws_format = -1;
  if (dec->frame != NULL) {
    g_ff.frame_free(&dec->frame);
  }
  if (dec->parser != NULL) {
    g_ff.parser_close(dec->parser);
    dec->parser = NULL;
  }
  if (dec->codec_ctx != NULL) {
    g_ff.free_context(&dec->codec_ctx);
  }
}

static gboolean h264_decoder_open(H264Decoder* dec, GError** error) {
  if (!ff_load()) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                "This computer does not have the ffmpeg video libraries "
                "installed. Install ffmpeg to use the live view.");
    return FALSE;
  }
  const AVCodec* codec = g_ff.find_decoder(AV_CODEC_ID_H264);
  if (codec == NULL) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                "No H.264 decoder found on this computer");
    return FALSE;
  }
  dec->parser = g_ff.parser_init(AV_CODEC_ID_H264);
  dec->codec_ctx = g_ff.alloc_context3(codec);
  if (dec->parser == NULL || dec->codec_ctx == NULL ||
      g_ff.open2(dec->codec_ctx, codec, NULL) < 0) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Could not open the H.264 decoder");
    h264_decoder_close(dec);
    return FALSE;
  }
  dec->frame = g_ff.frame_alloc();
  if (dec->frame == NULL) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Could not allocate a video frame");
    h264_decoder_close(dec);
    return FALSE;
  }
  dec->sws = NULL;
  dec->sws_format = -1;

  dec->texture =
      (H264Texture*)g_object_new(h264_texture_get_type(), NULL);
  if (!fl_texture_registrar_register_texture(dec->registrar,
                                             FL_TEXTURE(dec->texture))) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Could not register the video texture");
    h264_decoder_close(dec);
    return FALSE;
  }
  return TRUE;
}

// Decode one chunk of Annex B bytes. Arbitrary splits are fine:
// the parser cuts complete frames out of the stream. A chunk is
// dropped when the decoder is busy or a frame is not 1280x720;
// the next keyframe heals the picture.
static void h264_decoder_feed(H264Decoder* dec, const uint8_t* data,
                              size_t size) {
  size_t offset = 0;
  while (offset < size) {
    uint8_t* pkt_data = NULL;
    int pkt_size = 0;
    int consumed = g_ff.parser_parse2(dec->parser, dec->codec_ctx,
                                    &pkt_data, &pkt_size,
                                    data + offset,
                                    (int)(size - offset),
                                    AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
    if (consumed < 0) {
      break;
    }
    offset += (size_t)consumed;
    if (pkt_size == 0) {
      continue;
    }
    AVPacket* pkt = g_ff.packet_alloc();
    if (pkt == NULL) {
      break;
    }
    // The parser owns pkt_data, so copy it: the packet frees its
    // own data when it is released.
    if (g_ff.new_packet(pkt, pkt_size) < 0) {
      g_ff.packet_free(&pkt);
      break;
    }
    memcpy(pkt->data, pkt_data, (size_t)pkt_size);
    if (g_ff.send_packet(dec->codec_ctx, pkt) < 0) {
      g_ff.packet_free(&pkt);
      continue;
    }
    g_ff.packet_free(&pkt);
    while (g_ff.receive_frame(dec->codec_ctx, dec->frame) == 0) {
      if (dec->frame->width != H264_WIDTH ||
          dec->frame->height != H264_HEIGHT) {
        g_ff.frame_unref(dec->frame);
        continue;
      }
      if (dec->sws == NULL || dec->sws_format != dec->frame->format) {
        if (dec->sws != NULL) {
          g_ff.sws_free_context(dec->sws);
        }
        dec->sws = g_ff.sws_get_context(H264_WIDTH, H264_HEIGHT,
                                  (enum AVPixelFormat)dec->frame->format,
                                  H264_WIDTH, H264_HEIGHT,
                                  AV_PIX_FMT_RGBA, SWS_BILINEAR,
                                  NULL, NULL, NULL);
        dec->sws_format = dec->frame->format;
      }
      if (dec->sws != NULL) {
        uint8_t* dst[4] = {dec->texture->back, NULL, NULL, NULL};
        int stride[4] = {H264_WIDTH * 4, 0, 0, 0};
        g_ff.sws_scale(dec->sws,
                  (const uint8_t* const*)dec->frame->data,
                  dec->frame->linesize, 0, H264_HEIGHT, dst, stride);
        h264_texture_swap(dec->texture);
        fl_texture_registrar_mark_texture_frame_available(
            dec->registrar, FL_TEXTURE(dec->texture));
      }
      g_ff.frame_unref(dec->frame);
    }
  }
}

// ---- Method channel -----------------------------------------------------

static void h264_method_call(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  (void)channel;
  H264Decoder* dec = (H264Decoder*)user_data;
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "create") == 0) {
    if (dec->texture != NULL) {
      fl_method_call_respond_success(
          call,
          fl_value_new_int(fl_texture_get_id(FL_TEXTURE(dec->texture))),
          NULL);
      return;
    }
    GError* error = NULL;
    if (!h264_decoder_open(dec, &error)) {
      fl_method_call_respond_error(call, "no-decoder",
                                   error != NULL ? error->message
                                                 : "Could not start "
                                                   "the video decoder",
                                   NULL, NULL);
      g_clear_error(&error);
      return;
    }
    fl_method_call_respond_success(
        call,
        fl_value_new_int(fl_texture_get_id(FL_TEXTURE(dec->texture))),
        NULL);
  } else if (strcmp(method, "feed") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args == NULL || fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
      fl_method_call_respond_error(call, "bad-args", "feed needs bytes",
                                   NULL, NULL);
      return;
    }
    size_t length = fl_value_get_length(args);
    const uint8_t* data = fl_value_get_uint8_list(args);
    if (dec->texture != NULL && data != NULL) {
      h264_decoder_feed(dec, data, length);
    }
    fl_method_call_respond_success(call, NULL, NULL);
  } else if (strcmp(method, "release") == 0) {
    h264_decoder_close(dec);
    fl_method_call_respond_success(call, NULL, NULL);
  } else {
    fl_method_call_respond_not_implemented(call, NULL);
  }
}

void h264_decoder_plugin_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry,
                                                  "H264DecoderPlugin");
  // One decoder for the life of the app: the Mirror screen creates
  // and releases it each time the live view starts and stops.
  H264Decoder* dec = g_new0(H264Decoder, 1);
  dec->registrar = fl_plugin_registrar_get_texture_registrar(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  dec->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "reoculus/h264",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(dec->channel, h264_method_call,
                                            dec, NULL);
}
