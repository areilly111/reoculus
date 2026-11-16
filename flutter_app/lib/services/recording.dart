import 'dart:async';
import 'dart:io';

/// Long recording: spawns questctl `device record-loop`, which
/// records the headset screen in 180 s raw-H.264 segments into a
/// folder until it is killed. Stopping kills the process; the app
/// then runs `device record-finish` through the backend to stitch
/// the segments into one video.
///
/// [onError] fires when the loop dies on its own (headset asleep
/// or disconnected) with a plain message. The app stitches what
/// was recorded so far in that case, instead of losing it.
class RecordingSession {
  Process? _proc;
  bool _stopping = false;
  final _stderr = StringBuffer();

  bool get running => _proc != null;

  /// Start the loop. Returns false when the process could not start.
  Future<bool> start({
    required String cliPath,
    required String? directAddr,
    required String serial,
    required String dir,
    String? home,
    required void Function(String message) onError,
  }) async {
    await stop();
    _stopping = false;
    _stderr.clear();
    final args = <String>[];
    if (directAddr != null && directAddr.isNotEmpty) {
      args.addAll(['--transport', 'direct', '--addr', directAddr]);
    }
    args.addAll(['device', 'record-loop', '--serial', serial, '--dir', dir]);
    try {
      _proc = await Process.start(
        cliPath,
        args,
        environment: home != null ? {'HOME': home} : null,
      );
    } catch (_) {
      return false;
    }
    final proc = _proc!;
    proc.stderr.listen((chunk) {
      _stderr.write(String.fromCharCodes(chunk));
    });
    unawaited(proc.exitCode.then((code) async {
      final wasStopping = _stopping;
      _proc = null;
      if (!wasStopping) {
        final err = _stderr.toString().trim();
        onError(err.isEmpty
            ? 'The recording stopped. Is the headset awake and still connected?'
            : err);
      }
    }));
    return true;
  }

  /// Stop the loop. The segments stay in the folder; call
  /// `finishRecording` on the backend to stitch them.
  Future<void> stop() async {
    _stopping = true;
    final proc = _proc;
    _proc = null;
    proc?.kill();
    if (proc != null) {
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
  }
}
