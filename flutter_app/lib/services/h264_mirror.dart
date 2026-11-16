import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Live H.264 mirror: spawns questctl `device mirror-stream` and
/// feeds its raw output into the platform video decoder (MediaCodec
/// on Android, libavcodec on Linux), which renders into a Flutter
/// texture.
///
/// View only, no input. The picture runs about a second behind the
/// headset, and screenrecord restarts itself every 3 minutes, so
/// there is a brief black gap at each restart.
///
/// The feed is paced, not fired per chunk: adb delivers the stream
/// in bursts over Wi-Fi, and handing every burst straight to the
/// decoder made the tablet picture glitch. Incoming chunks queue
/// up and one goes to the decoder every 33 ms, about 30 a second,
/// which smooths the bursts out. That adds a little latency, on
/// top of the second the stream already has. The queue is capped
/// at 90 chunks (about 3 seconds): past that the oldest chunk is
/// dropped, so a slow decoder can never fall minutes behind.
class H264Mirror {
  static const _channel = MethodChannel('reoculus/h264');

  /// One chunk per tick, 33 ms apart.
  static const _tick = Duration(milliseconds: 33);
  /// Past this many queued chunks, drop the oldest.
  static const _maxQueued = 90;

  Process? _proc;
  int? _textureId;
  StreamSubscription<List<int>>? _sub;
  bool _stopping = false;
  final _stderr = StringBuffer();
  final _queue = <Uint8List>[];
  Timer? _timer;
  bool _feeding = false;

  int? get textureId => _textureId;
  bool get running => _proc != null;

  /// Start the stream. Returns the texture id to show, or null when
  /// the decoder or the backend could not start. [onError] fires when
  /// the stream dies on its own (headset asleep or disconnected)
  /// with a plain message.
  Future<int?> start({
    required String cliPath,
    required String? directAddr,
    required String serial,
    String? home,
    required void Function(String message) onError,
  }) async {
    await stop();
    _stopping = false;
    _stderr.clear();
    try {
      final id = await _channel.invokeMethod<int>('create');
      if (id == null) return null;
      _textureId = id;
    } catch (_) {
      return null;
    }
    final args = <String>[];
    if (directAddr != null && directAddr.isNotEmpty) {
      args.addAll(['--transport', 'direct', '--addr', directAddr]);
    }
    args.addAll(['device', 'mirror-stream', '--serial', serial]);
    try {
      _proc = await Process.start(
        cliPath,
        args,
        environment: home != null ? {'HOME': home} : null,
      );
    } catch (_) {
      await _releaseTexture();
      return null;
    }
    final proc = _proc!;
    _sub = proc.stdout.listen((chunk) {
      _queue.add(Uint8List.fromList(chunk));
      if (_queue.length > _maxQueued) _queue.removeAt(0);
    });
    _timer = Timer.periodic(_tick, (_) => _feedOne());
    proc.stderr.listen((chunk) {
      _stderr.write(String.fromCharCodes(chunk));
    });
    unawaited(proc.exitCode.then((code) async {
      final wasStopping = _stopping;
      await stop();
      if (!wasStopping) {
        final err = _stderr.toString().trim();
        onError(err.isEmpty
            ? 'The mirror stopped. Is the headset awake and still connected?'
            : err);
      }
    }));
    return _textureId;
  }

  /// Feed the oldest queued chunk to the decoder. Skips the tick
  /// while a feed is still in flight, so feeds never overlap.
  Future<void> _feedOne() async {
    if (_feeding || _queue.isEmpty || _textureId == null) return;
    _feeding = true;
    final chunk = _queue.removeAt(0);
    try {
      await _channel.invokeMethod('feed', chunk);
    } catch (_) {}
    _feeding = false;
  }

  Future<void> stop() async {
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    await _sub?.cancel();
    _sub = null;
    final proc = _proc;
    _proc = null;
    proc?.kill();
    await _releaseTexture();
  }

  Future<void> _releaseTexture() async {
    if (_textureId == null) return;
    _textureId = null;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}
