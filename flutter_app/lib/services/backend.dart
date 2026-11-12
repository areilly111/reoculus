import 'dart:convert';
import 'dart:io';
import '../models.dart';

// ---------------------------------------------------------------------------
// BackendService: the ONLY way the UI talks to a headset.
// Real mode only: RealBackend spawns the Rust questctl CLI built by
// the backend. There is no demo/mock backend any more: if questctl
// is missing or no headset is connected, calls return ok:false with
// a plain message and the UI shows an error state, never sample data.
// The UI never calls ADB directly and never imports dart:io process
// code outside RealBackend.
// ---------------------------------------------------------------------------

abstract class BackendService {
  String get label;
  Future<List<QuestDevice>> listDevices();
  Future<DeviceInfo?> deviceInfo(String serial);
  Future<List<QuestApp>> listApps(String serial, {bool thirdPartyOnly = false, bool withIcons = false, bool withSizes = false});
  /// Real label + local icon file for one app, or null when the app
  /// has no launcher icon / the icon could not be read. The backend
  /// caches icons, so repeat calls are cheap.
  Future<AppIcon?> appIcon(String serial, String package);
  Future<AppDetails?> appDetails(String serial, String package);
  Future<BackendResult> installApk(String serial, String path, {bool reinstall = true});
  Future<BackendResult> installMultiple(String serial, List<String> paths);
  Future<BackendResult> uninstallApp(String serial, String package, {bool keepData = false});
  Future<BackendResult> uninstallSystemApp(String serial, String package);
  Future<BackendResult> launchApp(String serial, String package);
  Future<BackendResult> forceStopApp(String serial, String package);
  Future<BackendResult> clearAppData(String serial, String package);
  Future<BackupReport?> backupApp(String serial, String package, {bool skipData = false});
  Future<BackupReport?> saveBackup(String serial, String package, {bool includeObb = false});
  Future<RestoreReport?> restoreBackup(String serial, String backupPath, {bool includeData = false, bool dryRun = false, bool confirm = false});
  Future<RestoreReport?> saveRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false});
  Future<List<BackupEntry>> listBackups();
  Future<BackendResult> deleteBackup(String path);
  Future<List<LibraryEntry>> listLibrary();
  Future<LibraryEntry?> importApk(String path);
  Future<BackendResult> deleteLibraryEntry(String path);
  Future<List<QuestFile>> listFiles(String serial, String path);
  Future<BackendResult> pushFile(String serial, String local, String remote);
  Future<BackendResult> pullFile(String serial, String remote, String local);
  Future<BackendResult> deleteFile(String serial, String remote);
  Future<BackendResult> screenshot(String serial, String outPath);
  Future<BackendResult> startMirror(String serial, String preset);
  Future<BackendResult> stopMirror(String serial);
  Future<BackendResult> startRecording(String serial);
  Future<List<GalleryEntry>> listGallery();
  Future<BackendResult> deleteGalleryEntry(String path);
  Future<BackendResult> openGalleryFile(String path);
  Future<BackendResult> openGalleryFolder();
  Future<Map<String, dynamic>> wivrnDetect();
  Future<Map<String, dynamic>> wivrnStatus();
  Future<BackendResult> wivrnStart();
  Future<BackendResult> wivrnStop();
  Future<BackendResult> wivrnConfig(String encoder, String codec);
  Future<String?> wivrnHeadsetClient(String serial);
  Future<Map<String, dynamic>> wivrnSetupState(String serial);
  Future<BackendResult> wivrnInstallClient(String serial);
  Future<BackendResult> wivrnSetupUsb(String serial);
  Future<BackendResult> wivrnInstallServer();
  Future<BackendResult> wivrnDecline(String serial);
  Future<BackendResult> wivrnUndecline(String serial);
  Future<List<HomeEntry>> homesList(String serial);
  Future<String?> homesCurrent(String serial);
  Future<BackendResult> homesSet(String serial, String component);
  Future<BackendResult> homesOpenSettings(String serial);
  Future<SingularityPreflight?> singularityPreflight(String serial);
  Future<Map<String, dynamic>> singularityDownload();
  Future<BackendResult> singularityInstall(String serial);
  Future<RootStatus> singularityVerify(String serial);
  Future<Map<String, dynamic>?> snapshotCreate(String serial, String name, {String? profile});
  Future<List<SnapshotEntry>> snapshotList();
  Future<RestoreReport?> snapshotRestore(String serial, String path, {bool dryRun = false, bool confirm = false});
  Future<BackendResult> snapshotDelete(String path);
  Future<HealthInfo?> deviceHealth(String serial);
  Future<ApkAnalysis?> analyzeApk(String path);
  Future<ShellResult?> runShell(String serial, String command);
  Future<DebugInfo?> debugInfo(String serial);
  Future<RootStatus> rootStatus(String serial);
  Future<ControllersInfo> controllers(String serial);
  Future<UpdateBlockStatus?> updateBlockStatus(String serial);
  Future<BackendResult> setUpdateBlock(String serial, bool block);
  Future<WifiSetupResult?> setupWifi(String serial);
  Future<List<String>> wifiReconnect();
  Future<String?> wifiIp(String serial);
  Future<BackendResult> reboot(String serial);
  Future<List<String>> logLines(String serial, {String filter = ''});
  Future<BackendResult> pairWifi(String ip, String port, String code);
  Future<BackendResult> disconnectWifi(String serial);
  Future<BackendResult> deviceBackup(String serial);
  Future<List<DeviceBackupEntry>> listDeviceBackups();
  Future<RestoreReport?> deviceRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false, bool skipApps = false, bool includeData = false});
  Future<BackendResult> setSetting(String serial, String key, String value);
  Future<BackendResult> applyProfile(String serial, SettingProfile profile);
  Future<bool> get scrcpyAvailable;
}

/// Gallery folder on this computer: ~/quest-recordings/ (screenshots
/// and recordings together). Mirrors the backend gallery root.
String galleryDir() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  return '$home/quest-recordings';
}

String _stamp() => DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');

// ------------------------- RealBackend --------------------------------------
// Spawns: questctl --json <command> [args...]
// Every command prints ONE JSON object: {"ok": true, ...} or {"ok": false, "error": "..."}
// If the binary is missing, every call returns ok:false with a plain message
// and the UI shows an error state (never demo data).

class RealBackend implements BackendService {
  final String cliPath;
  RealBackend(this.cliPath);
  @override
  String get label => 'Real backend';

  static List<String> defaultCandidates() => [
        '../backend/target/debug/questctl',
        '../backend/target/release/questctl',
        'questctl',
      ];

  /// Candidates in order: the configured path, a questctl sitting next
  /// to the Flutter executable (the AppImage bundles it there, so the
  /// app finds it no matter which folder it was started from), then
  /// the development-tree relative paths, then PATH.
  static Future<String?> findCli([String? configured]) async {
    if (configured != null && configured.isNotEmpty && await File(configured).exists()) return configured;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir/questctl';
      if (await File(bundled).exists()) return bundled;
    } catch (_) {}
    for (final c in defaultCandidates()) {
      if (c == 'questctl') continue;
      if (await File(c).exists()) return c;
    }
    return null;
  }

  Future<Map<String, dynamic>> _run(List<String> args) async {
    try {
      final result = await Process.run(cliPath, ['--json', ...args]);
      final text = (result.stdout as String).trim();
      if (text.isEmpty) return {'ok': false, 'error': 'The backend gave no answer. Is questctl built?'};
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': 'Could not run the backend ($cliPath). $e'};
    }
  }

  BackendResult _toResult(Map<String, dynamic> j) =>
      BackendResult(ok: j['ok'] == true, message: (j['error'] ?? j['message'] ?? '').toString(), data: j);

  @override
  Future<List<QuestDevice>> listDevices() async {
    final j = await _run(['devices', 'list']);
    final list = (j['devices'] as List?) ?? [];
    return list.map((e) => QuestDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<DeviceInfo?> deviceInfo(String serial) async {
    final j = await _run(['devices', 'info', '--serial', serial]);
    if (j['ok'] != true) return null;
    // Contract (backend/CONTRACT.md): battery is an OBJECT
    // {level, health, temperature_c, voltage_mv, status, plugged} and
    // storage is an OBJECT {total_kb, used_kb, free_kb, mount} in KiB.
    // Charging rule (documented in CONTRACT.md): status is "charging"
    // or "full", or a power source is plugged in (plugged is set).
    final battery = (j['battery'] as Map?) ?? {};
    final storage = (j['storage'] as Map?) ?? {};
    int kbToGb(dynamic kb) => (kb is num) ? (kb / 1024 / 1024).round() : 0;
    final status = (battery['status'] ?? '').toString().toLowerCase();
    final plugged = (battery['plugged'] ?? '').toString();
    return DeviceInfo(
      model: (j['model'] ?? '').toString(),
      serial: serial,
      firmware: (j['firmware'] ?? '').toString(),
      androidVersion: (j['android_version'] ?? '').toString(),
      resolution: (j['resolution'] ?? '').toString(),
      cpuAbi: (j['cpu_abi'] ?? '').toString(),
      batteryLevel: (battery['level'] is num) ? (battery['level'] as num).toInt() : 0,
      batteryTempC: (battery['temperature_c'] is num) ? (battery['temperature_c'] as num).round() : 0,
      storageUsedGb: kbToGb(storage['used_kb']),
      storageTotalGb: kbToGb(storage['total_kb']),
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
    );
  }

  @override
  Future<List<QuestApp>> listApps(String serial, {bool thirdPartyOnly = false, bool withIcons = false, bool withSizes = false}) async {
    final args = ['apps', 'list', '--serial', serial];
    if (thirdPartyOnly) args.add('--third-party');
    if (withIcons) args.add('--with-icons');
    if (withSizes) args.add('--with-sizes');
    final j = await _run(args);
    final list = (j['apps'] as List?) ?? [];
    return list.map((e) => QuestApp.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<AppIcon?> appIcon(String serial, String package) async {
    final j = await _run(['apps', 'icon', '--serial', serial, '--package', package]);
    if (j['ok'] != true) return null; // no launcher icon, or unreadable: caller falls back
    final path = (j['icon_path'] ?? '').toString();
    if (path.isEmpty) return null;
    return AppIcon.fromJson(j);
  }

  @override
  Future<AppDetails?> appDetails(String serial, String package) async {
    final j = await _run(['apps', 'details', '--serial', serial, '--package', package]);
    if (j['ok'] != true) return null;
    return AppDetails.fromJson(j);
  }

  @override
  Future<BackendResult> installApk(String serial, String path, {bool reinstall = true}) async {
    final args = ['apps', 'install', '--serial', serial, '--apk', path];
    if (reinstall) args.add('--reinstall');
    return _toResult(await _run(args));
  }

  @override
  Future<BackendResult> installMultiple(String serial, List<String> paths) async =>
      _toResult(await _run(['apps', 'install-multiple', '--serial', serial, '--apks', paths.join(',')]));

  @override
  Future<BackendResult> uninstallApp(String serial, String package, {bool keepData = false}) async {
    final args = ['apps', 'uninstall', '--serial', serial, '--package', package];
    if (keepData) args.add('-k');
    return _toResult(await _run(args));
  }

  @override
  Future<BackendResult> uninstallSystemApp(String serial, String package) async =>
      _toResult(await _run(['apps', 'uninstall-system', '--serial', serial, '--package', package]));

  @override
  Future<BackendResult> launchApp(String serial, String package) async =>
      _toResult(await _run(['apps', 'launch', '--serial', serial, '--package', package]));

  @override
  Future<BackendResult> forceStopApp(String serial, String package) async =>
      _toResult(await _run(['apps', 'force-stop', '--serial', serial, '--package', package]));

  @override
  Future<BackendResult> clearAppData(String serial, String package) async =>
      // Backend requires --confirm (CONTRACT.md). The UI already asks
      // the user in a confirm dialog before calling this, so passing it
      // here is correct, not a silent bypass.
      _toResult(await _run(['apps', 'clear-data', '--serial', serial, '--package', package, '--confirm']));

  @override
  Future<BackupReport?> backupApp(String serial, String package, {bool skipData = false}) async {
    final args = ['apps', 'backup', '--serial', serial, '--package', package];
    if (skipData) args.add('--skip-data');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return BackupReport.fromJson(j);
  }

  @override
  Future<BackupReport?> saveBackup(String serial, String package, {bool includeObb = false}) async {
    final args = ['apps', 'save-backup', '--serial', serial, '--package', package];
    if (includeObb) args.add('--include-obb');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return BackupReport.fromJson(j);
  }

  @override
  Future<RestoreReport?> restoreBackup(String serial, String backupPath, {bool includeData = false, bool dryRun = false, bool confirm = false}) async {
    final args = ['apps', 'restore', '--serial', serial, '--backup', backupPath];
    if (includeData) args.add('--include-data');
    if (dryRun) args.add('--dry-run');
    if (confirm) args.add('--confirm');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return RestoreReport.fromJson(j);
  }

  @override
  Future<RestoreReport?> saveRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false}) async {
    final args = ['apps', 'save-restore', '--serial', serial, '--backup', backupPath];
    if (dryRun) args.add('--dry-run');
    if (confirm) args.add('--confirm');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return RestoreReport.fromJson(j);
  }

  @override
  Future<List<BackupEntry>> listBackups() async {
    final j = await _run(['apps', 'backup-list']);
    final list = (j['backups'] as List?) ?? [];
    return list.map((e) => BackupEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<BackendResult> deleteBackup(String path) async =>
      _toResult(await _run(['apps', 'backup-delete', '--backup', path]));

  @override
  Future<List<LibraryEntry>> listLibrary() async {
    final j = await _run(['library', 'list']);
    final list = (j['entries'] as List?) ?? [];
    return list.map((e) => LibraryEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<LibraryEntry?> importApk(String path) async {
    final j = await _run(['library', 'import', '--file', path]);
    if (j['ok'] != true) return null;
    return LibraryEntry.fromJson(j);
  }

  @override
  Future<BackendResult> deleteLibraryEntry(String path) async =>
      _toResult(await _run(['library', 'delete', '--path', path]));

  @override
  Future<List<QuestFile>> listFiles(String serial, String path) async {
    final j = await _run(['files', 'list', '--serial', serial, '--path', path]);
    // Contract: the key is 'entries', not 'files'.
    final list = (j['entries'] as List?) ?? [];
    return list.map((e) => QuestFile.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<BackendResult> pushFile(String serial, String local, String remote) async =>
      _toResult(await _run(['files', 'push', '--serial', serial, '--local', local, '--remote', remote]));

  @override
  Future<BackendResult> pullFile(String serial, String remote, String local) async =>
      _toResult(await _run(['files', 'pull', '--serial', serial, '--remote', remote, '--local', local]));

  @override
  Future<BackendResult> deleteFile(String serial, String remote) async =>
      _toResult(await _run(['files', 'delete', '--serial', serial, '--remote', remote]));

  @override
  Future<BackendResult> screenshot(String serial, String outPath) async {
    // Default: save into the gallery folder with a timestamp name.
    final out = outPath.isEmpty ? '${galleryDir()}/shot-${_stamp()}.png' : outPath;
    final r = await _run(['device', 'screenshot', '--serial', serial, '--out', out]);
    if (r['ok'] == true) return BackendResult(ok: true, message: 'Screenshot saved to $out', data: {'path': out});
    return _toResult(r);
  }

  @override
  Future<BackendResult> startMirror(String serial, String preset) async =>
      // The preset is passed to the backend and sets real scrcpy
      // limits: Performance 1280/4M/30fps, Balanced 1920/8M/60fps,
      // Quality 2560/12M/90fps, all h265, no audio.
      _toResult(await _run(['device', 'mirror', '--serial', serial, '--preset', preset.toLowerCase()]));

  @override
  @override
  Future<BackendResult> stopMirror(String serial) async =>
      _toResult(await _run(['device', 'mirror-stop', '--serial', serial]));

  @override
  Future<BackendResult> startRecording(String serial) async {
    // Contract: `device record` requires --out <file.mp4> [--seconds].
    // Recordings go to ~/quest-recordings/rec-<timestamp>.mp4.
    final dir = Directory(galleryDir());
    await dir.create(recursive: true);
    final out = '${dir.path}/rec-${_stamp()}.mp4';
    final r = await _run(['device', 'record', '--serial', serial, '--out', out, '--seconds', '60']);
    if (r['ok'] == true) return BackendResult(ok: true, message: 'Recording saved to $out', data: {'path': out});
    return _toResult(r);
  }

  @override
  Future<List<GalleryEntry>> listGallery() async {
    final j = await _run(['device', 'gallery-list']);
    final list = (j['entries'] as List?) ?? [];
    return list.map((e) => GalleryEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<BackendResult> deleteGalleryEntry(String path) async =>
      _toResult(await _run(['device', 'gallery-delete', '--file', path]));

  @override
  Future<BackendResult> openGalleryFile(String path) async {
    // Linux: open with the system viewer. On Android there is no
    // xdg-open; the UI shows the path instead.
    if (!Platform.isLinux) {
      return BackendResult(ok: true, message: 'Saved at $path');
    }
    try {
      await Process.run('xdg-open', [path]);
      return const BackendResult(ok: true, message: 'Opened.');
    } catch (e) {
      return BackendResult(ok: false, message: 'Could not open the file: $e');
    }
  }

  @override
  Future<BackendResult> openGalleryFolder() async {
    // Linux: open ~/quest-recordings/ in the file manager.
    // On Android there is no xdg-open; the UI shows the path instead.
    final dir = galleryDir();
    if (!Platform.isLinux) {
      return BackendResult(ok: true, message: 'Saved in $dir');
    }
    try {
      await Directory(dir).create(recursive: true);
      await Process.run('xdg-open', [dir]);
      return const BackendResult(ok: true, message: 'Opened folder.');
    } catch (e) {
      return BackendResult(ok: false, message: 'Could not open the folder: $e');
    }
  }

  @override
  Future<Map<String, dynamic>> wivrnDetect() async => await _run(['wivrn', 'detect']);
  @override
  Future<Map<String, dynamic>> wivrnStatus() async => await _run(['wivrn', 'status']);
  @override
  Future<BackendResult> wivrnStart() async => _toResult(await _run(['wivrn', 'start']));
  @override
  Future<BackendResult> wivrnStop() async => _toResult(await _run(['wivrn', 'stop']));
  @override
  Future<BackendResult> wivrnConfig(String encoder, String codec) async => _toResult(await _run(['wivrn', 'config', '--encoder', encoder, '--codec', codec]));
  @override
  Future<String?> wivrnHeadsetClient(String serial) async {
    final j = await _run(['wivrn', 'headset-client', '--serial', serial]);
    final v = j['client_version'];
    return v == null ? null : v.toString();
  }

  @override
  Future<Map<String, dynamic>> wivrnSetupState(String serial) async => await _run(['wivrn', 'setup-state', '--serial', serial]);
  @override
  Future<BackendResult> wivrnInstallClient(String serial) async => _toResult(await _run(['wivrn', 'install-client', '--serial', serial]));
  @override
  Future<BackendResult> wivrnSetupUsb(String serial) async => _toResult(await _run(['wivrn', 'setup-usb', '--serial', serial]));
  @override
  Future<BackendResult> wivrnInstallServer() async => _toResult(await _run(['wivrn', 'install-server']));
  @override
  Future<BackendResult> wivrnDecline(String serial) async => _toResult(await _run(['wivrn', 'decline', '--serial', serial]));
  @override
  Future<BackendResult> wivrnUndecline(String serial) async => _toResult(await _run(['wivrn', 'undecline', '--serial', serial]));

  @override
  Future<List<HomeEntry>> homesList(String serial) async {
    final j = await _run(['homes', 'list', '--serial', serial]);
    final list = (j['homes'] as List?) ?? [];
    return list.map((e) => HomeEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<String?> homesCurrent(String serial) async {
    final j = await _run(['homes', 'current', '--serial', serial]);
    if (j['ok'] != true) return null;
    return (j['current'] as String?)?.isNotEmpty == true ? j['current'] as String : null;
  }

  @override
  Future<BackendResult> homesSet(String serial, String component) async =>
      _toResult(await _run(['homes', 'set', '--serial', serial, '--component', component]));

  @override
  Future<BackendResult> homesOpenSettings(String serial) async =>
      _toResult(await _run(['homes', 'open-settings', '--serial', serial]));

  @override
  Future<SingularityPreflight?> singularityPreflight(String serial) async {
    final j = await _run(['singularity', 'preflight', '--serial', serial]);
    if (j['ok'] != true) return null;
    return SingularityPreflight.fromJson(j);
  }

  @override
  Future<Map<String, dynamic>> singularityDownload() async => await _run(['singularity', 'download']);

  @override
  Future<BackendResult> singularityInstall(String serial) async =>
      _toResult(await _run(['singularity', 'install', '--serial', serial]));

  @override
  Future<RootStatus> singularityVerify(String serial) async {
    final j = await _run(['singularity', 'verify', '--serial', serial]);
    if (j['ok'] != true) return RootStatus.notRooted;
    return RootStatus.fromJson(j);
  }

  @override
  Future<Map<String, dynamic>?> snapshotCreate(String serial, String name, {String? profile}) async {
    final args = ['snapshot', 'create', '--serial', serial, '--name', name];
    if (profile != null && profile.isNotEmpty) args.addAll(['--profile', profile]);
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return j;
  }

  @override
  Future<List<SnapshotEntry>> snapshotList() async {
    final j = await _run(['snapshot', 'list']);
    final list = (j['snapshots'] as List?) ?? [];
    return list.map((e) => SnapshotEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<RestoreReport?> snapshotRestore(String serial, String path, {bool dryRun = false, bool confirm = false}) async {
    final args = ['snapshot', 'restore', '--serial', serial, '--snapshot', path];
    if (dryRun) args.add('--dry-run');
    if (confirm) args.add('--confirm');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return RestoreReport.fromJson(j);
  }

  @override
  Future<BackendResult> snapshotDelete(String path) async =>
      _toResult(await _run(['snapshot', 'delete', '--snapshot', path]));

  @override
  Future<HealthInfo?> deviceHealth(String serial) async {
    final j = await _run(['devices', 'health', '--serial', serial]);
    if (j['ok'] != true) return null;
    return HealthInfo.fromJson(j);
  }

  @override
  Future<ApkAnalysis?> analyzeApk(String path) async {
    final j = await _run(['apps', 'analyze', '--apk', path]);
    if (j['ok'] != true) return null;
    return ApkAnalysis.fromJson(j);
  }

  @override
  Future<ShellResult?> runShell(String serial, String command) async {
    final j = await _run(['devices', 'shell', '--serial', serial, '--command', command]);
    if (j['ok'] != true) return null;
    return ShellResult(
      stdout: (j['stdout'] ?? '').toString(),
      stderr: (j['stderr'] ?? '').toString(),
      code: (j['code'] is num) ? (j['code'] as num).toInt() : -1,
    );
  }

  @override
  Future<DebugInfo?> debugInfo(String serial) async {
    final j = await _run(['devices', 'debug-info', '--serial', serial]);
    if (j['ok'] != true) return null;
    final dev = (j['device'] as Map?) ?? {};
    final battery = (dev['battery'] as Map?) ?? {};
    final storage = (dev['storage'] as Map?) ?? {};
    int kbToGb(dynamic kb) => (kb is num) ? (kb / 1024 / 1024).round() : 0;
    final status = (battery['status'] ?? '').toString().toLowerCase();
    final plugged = (battery['plugged'] ?? '').toString();
    final info = DeviceInfo(
      model: (dev['model'] ?? '').toString(),
      serial: (dev['serial'] ?? serial).toString(),
      firmware: (dev['firmware'] ?? '').toString(),
      androidVersion: (dev['android_version'] ?? '').toString(),
      resolution: (dev['resolution'] ?? '').toString(),
      cpuAbi: (dev['cpu_abi'] ?? '').toString(),
      batteryLevel: (battery['level'] is num) ? (battery['level'] as num).toInt() : 0,
      batteryTempC: (battery['temperature_c'] is num) ? (battery['temperature_c'] as num).round() : 0,
      storageUsedGb: kbToGb(storage['used_kb']),
      storageTotalGb: kbToGb(storage['total_kb']),
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
    );
    return DebugInfo(
      questctlVersion: (j['questctl_version'] ?? '').toString(),
      adbVersion: (j['adb_version'] ?? '').toString(),
      backendPath: (j['backend_path'] ?? '').toString(),
      scrcpyAvailable: j['scrcpy_available'] == true,
      wifiIp: (j['wifi_ip'] as String?)?.isNotEmpty == true ? j['wifi_ip'] as String : null,
      root: RootStatus.fromJson((j['root'] as Map?)?.cast<String, dynamic>() ?? {}),
      device: info,
    );
  }

  @override
  Future<RootStatus> rootStatus(String serial) async {
    final j = await _run(['devices', 'root-status', '--serial', serial]);
    if (j['ok'] != true) return RootStatus.notRooted;
    return RootStatus.fromJson(j);
  }

  @override
  Future<ControllersInfo> controllers(String serial) async {
    final j = await _run(['devices', 'controllers', '--serial', serial]);
    if (j['ok'] != true) {
      return const ControllersInfo(names: [], note: 'Could not read controller info from the headset.');
    }
    return ControllersInfo.fromJson(j);
  }

  @override
  Future<UpdateBlockStatus?> updateBlockStatus(String serial) async {
    final j = await _run(['devices', 'update-block-status', '--serial', serial]);
    if (j['ok'] != true) return null;
    return UpdateBlockStatus.fromJson(j);
  }

  @override
  Future<BackendResult> setUpdateBlock(String serial, bool block) async => _toResult(await _run([
        'devices',
        'update-block',
        '--serial',
        serial,
        if (block) '--block' else '--unblock',
      ]));

  @override
  Future<WifiSetupResult?> setupWifi(String serial) async {
    final j = await _run(['devices', 'setup-wifi', '--serial', serial]);
    if (j['ok'] != true) return null;
    return WifiSetupResult.fromJson(j);
  }

  @override
  Future<List<String>> wifiReconnect() async {
    final j = await _run(['devices', 'wifi-reconnect']);
    final list = (j['connected'] as List?) ?? [];
    return list.map((e) => e.toString()).toList();
  }

  @override
  Future<String?> wifiIp(String serial) async {
    final j = await _run(['devices', 'wifi-ip', '--serial', serial]);
    final ip = (j['ip'] as String?)?.isNotEmpty == true ? j['ip'] as String : null;
    return ip;
  }

  @override
  Future<BackendResult> reboot(String serial) async =>
      _toResult(await _run(['device', 'reboot', '--serial', serial]));

  @override
  Future<List<String>> logLines(String serial, {String filter = ''}) async {
    final j = await _run(['device', 'logcat', '--serial', serial]);
    final list = (j['lines'] as List?) ?? [];
    final lines = list.map((e) => e.toString()).toList();
    if (filter.isEmpty) return lines;
    return lines.where((l) => l.toLowerCase().contains(filter.toLowerCase())).toList();
  }

  @override
  Future<BackendResult> pairWifi(String ip, String port, String code) async {
    // Contract: modern pairing/connecting is `devices connect-wifi
    // --ip <ip> --port <port> [--code <6-digit>]`. `devices pair-wifi`
    // is the legacy USB tcpip flow and takes --serial only, never --ip.
    // With a code this pairs; without one it connects to an
    // already-paired device.
    final args = ['devices', 'connect-wifi', '--ip', ip, '--port', port];
    if (code.trim().isNotEmpty) args.addAll(['--code', code.trim()]);
    return _toResult(await _run(args));
  }

  @override
  Future<BackendResult> disconnectWifi(String serial) async =>
      _toResult(await _run(['devices', 'disconnect-wifi', '--serial', serial]));

  @override
  Future<BackendResult> deviceBackup(String serial) async {
    final j = await _run(['device', 'backup', '--serial', serial]);
    final r = _toResult(j);
    if (r.ok && (j['path'] as String?)?.isNotEmpty == true) {
      return BackendResult(ok: true, message: 'Device backup saved to ${j['path']}', data: j);
    }
    return r;
  }

  @override
  Future<List<DeviceBackupEntry>> listDeviceBackups() async {
    final j = await _run(['device', 'backup-list']);
    final list = (j['backups'] as List?) ?? [];
    return list.map((e) => DeviceBackupEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<RestoreReport?> deviceRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false, bool skipApps = false, bool includeData = false}) async {
    final args = ['device', 'restore', '--serial', serial, '--backup', backupPath];
    if (dryRun) args.add('--dry-run');
    if (confirm) args.add('--confirm');
    if (skipApps) args.add('--skip-apps');
    if (includeData) args.add('--include-data');
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return RestoreReport.fromJson(j);
  }

  @override
  Future<BackendResult> setSetting(String serial, String key, String value) async =>
      _toResult(await _run(['settings', 'set', '--serial', serial, '--key', key, '--value', value]));

  /// Map a UI SettingProfile to a backend built-in profile name
  /// (CONTRACT.md: `settings profile apply --serial X --profile <name>`).
  /// The backend has no save-custom-profile CLI, so exact custom
  /// refresh/CPU/GPU values are NOT sent; the closest built-in is used:
  /// Balanced -> balanced, Smooth (120 Hz / 3 / 3) -> high-refresh
  /// (same rates, plus full-rate capture), Battery saver -> battery-saver,
  /// anything else -> balanced. A save-custom-profile command is a v1 item.
  static String profileNameFor(SettingProfile p) {
    final n = p.name.toLowerCase();
    if (n.contains('battery')) return 'battery-saver';
    if (n.contains('smooth') || n.contains('high')) return 'high-refresh';
    if (n.contains('performance')) return 'performance';
    return 'balanced';
  }

  @override
  Future<BackendResult> applyProfile(String serial, SettingProfile p) async => _toResult(await _run([
        'settings',
        'profile',
        'apply',
        '--serial',
        serial,
        '--profile',
        profileNameFor(p),
      ]));

  @override
  Future<bool> get scrcpyAvailable async {
    try {
      final r = await Process.run('which', ['scrcpy']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
