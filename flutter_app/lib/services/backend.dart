import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:path_provider/path_provider.dart';
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
  // ---- Devices ----
  /// Short name for this backend ("Real backend"). Shown in Setup.
  String get label;
  /// Path of the questctl binary this backend spawns. The Android
  /// live mirror spawns it directly for the raw H.264 stream.
  String get cliPath;
  /// Android only: the headset's Wi-Fi address for the direct
  /// transport. Null on Linux and before the first Android connect.
  String? get directAddr;
  /// Android only: the app's files dir, passed to questctl as HOME.
  /// Null on Linux.
  String? get androidHome;
  /// Every headset adb can see right now, USB and Wi-Fi. Empty list
  /// when none is connected, never null.
  Future<List<QuestDevice>> listDevices();
  /// Model, firmware, battery and storage for one headset. Null when
  /// the headset is gone or the call fails.
  Future<DeviceInfo?> deviceInfo(String serial);
  // ---- Headset config ----
  /// The headset's own config file (headset.cfg on the headset).
  /// Returns HeadsetConfig.absent when it has never been synced.
  Future<HeadsetConfig> headsetConfig(String serial);
  /// Write the headset's info, settings and apps to its config file.
  Future<HeadsetConfig?> headsetConfigWrite(String serial, {String? name});
  /// Set just the custom headset name (empty clears it).
  Future<HeadsetConfig?> headsetConfigSetName(String serial, String name);
  // ---- Apps ----
  /// Apps installed on the headset. thirdPartyOnly skips system apps;
  /// withIcons and withSizes cost extra backend calls, so the UI only
  /// asks for them when it needs them.
  Future<List<QuestApp>> listApps(String serial, {bool thirdPartyOnly = false, bool withIcons = false, bool withSizes = false});
  /// Real label + local icon file for one app, or null when the app
  /// has no launcher icon / the icon could not be read. The backend
  /// caches icons, so repeat calls are cheap.
  Future<AppIcon?> appIcon(String serial, String package);
  /// Full details for one app: split APK paths, OBB files, sizes,
  /// SDK levels, install dates, installer. Null when the app is not
  /// installed or the call fails.
  Future<AppDetails?> appDetails(String serial, String package);
  /// Sideload one APK. reinstall (on by default) lets it update an
  /// app that is already installed.
  Future<BackendResult> installApk(String serial, String path, {bool reinstall = true});
  /// Sideload several APKs in one backend call. One result covers
  /// the whole batch.
  Future<BackendResult> installMultiple(String serial, List<String> paths);
  /// Uninstall one app. keepData keeps its saved data, so
  /// reinstalling later picks up where it left off.
  Future<BackendResult> uninstallApp(String serial, String package, {bool keepData = false});
  /// Uninstall a system app. Needs root; on a stock headset the
  /// backend refuses.
  Future<BackendResult> uninstallSystemApp(String serial, String package);
  /// Start an app on the headset.
  Future<BackendResult> launchApp(String serial, String package);
  /// Force stop an app on the headset.
  Future<BackendResult> forceStopApp(String serial, String package);
  /// Wipe one app's saved data. The app itself stays installed. The
  /// backend needs --confirm; the UI already asked the user, so passing
  /// it here is not a silent bypass.
  Future<BackendResult> clearAppData(String serial, String package);
  // ---- Backups ----
  /// Back up one app (APK plus, when rooted, its data) into the library
  /// folder. skipData backs up the APK only. Null when the backup fails.
  Future<BackupReport?> backupApp(String serial, String package, {bool skipData = false});
  /// Save a play-session backup: the app's save data, not the APK.
  /// includeObb also copies OBB files. Null when it fails.
  Future<BackupReport?> saveBackup(String serial, String package, {bool includeObb = false});
  /// Restore an app backup. includeData restores saved data too,
  /// dryRun only reports what would happen, confirm is the final
  /// go-ahead. Null when the restore fails.
  Future<RestoreReport?> restoreBackup(String serial, String backupPath, {bool includeData = false, bool dryRun = false, bool confirm = false});
  /// Restore a save backup (save data only, no APK). dryRun reports
  /// first, confirm goes ahead. Null when it fails.
  Future<RestoreReport?> saveRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false});
  /// Every app backup in the library folder. Empty list when there
  /// are none.
  Future<List<BackupEntry>> listBackups();
  /// Delete one backup folder from the library.
  Future<BackendResult> deleteBackup(String path);
  // ---- Library ----
  /// Everything in the library: app backups, save backups, and imported APKs.
  Future<List<LibraryEntry>> listLibrary();
  /// Launcher icon for one library entry, from the APK already on
  /// this computer. Null for save backups (no APK in the folder)
  /// and when the APK has no launcher icon.
  Future<AppIcon?> libraryIcon(LibraryEntry entry);
  /// Copy an APK file into the library so it can be installed later.
  /// Null when the file is not a readable APK.
  Future<LibraryEntry?> importApk(String path);
  /// Delete one library entry (a backup folder or an imported APK).
  Future<BackendResult> deleteLibraryEntry(String path);
  // ---- Files ----
  /// Files and folders in one headset folder. Empty list when the folder
  /// is empty or unreadable.
  Future<List<QuestFile>> listFiles(String serial, String path);
  /// Copy a file from this computer onto the headset.
  Future<BackendResult> pushFile(String serial, String local, String remote);
  /// Copy a file from the headset onto this computer.
  Future<BackendResult> pullFile(String serial, String remote, String local);
  /// Delete one file on the headset.
  Future<BackendResult> deleteFile(String serial, String remote);
  /// Rename (or move) one file or folder on the headset. `to` is the
  /// full new path, not just the new name.
  Future<BackendResult> renameFile(String serial, String from, String to);
  /// Create a folder on the headset (parents included).
  Future<BackendResult> makeDir(String serial, String remote);
  // ---- Mirror and gallery ----
  /// Take a screenshot. An empty outPath saves into the gallery folder
  /// with a timestamp name.
  Future<BackendResult> screenshot(String serial, String outPath);
  /// Finish a long recording started with record-loop: stitch the
  /// segments in `dir` into one video at `out`. The backend remuxes
  /// to .mp4 when ffmpeg is installed.
  Future<BackendResult> finishRecording(String serial, String dir, String out);
  /// Screenshots and recordings in the gallery folder on this computer.
  Future<List<GalleryEntry>> listGallery();
  /// Delete one screenshot or recording from the gallery folder.
  Future<BackendResult> deleteGalleryEntry(String path);
  /// Open one gallery file in the system viewer. Linux only: on
  /// Android there is no viewer, so it returns the path for the UI to show.
  Future<BackendResult> openGalleryFile(String path);
  /// Open the gallery folder in the file manager. Linux only: on
  /// Android it returns the path for the UI to show.
  Future<BackendResult> openGalleryFolder();
  // ---- WiVRn ----
  /// Is a WiVRn server installed on this PC, and which one. Raw backend
  /// JSON; ok is false when none is found.
  Future<Map<String, dynamic>> wivrnDetect();
  /// Is the WiVRn server running right now. Raw backend JSON.
  Future<Map<String, dynamic>> wivrnStatus();
  /// Start the WiVRn server on this PC.
  Future<BackendResult> wivrnStart();
  /// Stop the WiVRn server on this PC.
  Future<BackendResult> wivrnStop();
  /// Set the server encoder and codec. bitDepth defaults to 10;
  /// tcpOnly forces TCP instead of UDP.
  Future<BackendResult> wivrnConfig(String encoder, String codec, {int bitDepth = 10, bool tcpOnly = false});
  /// PC games and apps registered with WiVRn on this computer.
  Future<List<WivrnApp>> wivrnAppsList();
  /// Register a PC game or app with WiVRn. name is shown in the
  /// headset, exec is the command that starts it. launchOptions
  /// are extra command line options after the executable, icon is
  /// an image file or a theme icon name, comment is a one-line
  /// description. The three are empty when not given.
  Future<BackendResult> wivrnAppsAdd(String name, String exec, {String launchOptions = '', String icon = '', String comment = ''});
  /// Change a PC game or app in WiVRn. file is the desktop entry
  /// the backend listed; the file keeps its name.
  Future<BackendResult> wivrnAppsUpdate(String file, String name, String exec, {String launchOptions = '', String icon = '', String comment = ''});
  /// Remove a PC game or app from WiVRn. file is the desktop entry
  /// the backend listed.
  Future<BackendResult> wivrnAppsRemove(String file);
  /// The headset's WiVRn client settings (bitrate, resolution,
  /// codec). Null when the client is not installed or the call fails.
  Future<WivrnClientSettings?> wivrnClientSettings(String serial);
  /// Write the headset's WiVRn client settings.
  Future<BackendResult> wivrnClientSettingsSet(String serial, WivrnClientSettings settings);
  /// WiVRn client version on the headset, or null when it is not
  /// installed.
  Future<String?> wivrnHeadsetClient(String serial);
  /// First-run state in one call: client version, whether the user
  /// declined setup, whether the server is installed. Raw backend JSON.
  Future<Map<String, dynamic>> wivrnSetupState(String serial);
  /// Install the WiVRn client app on the headset.
  Future<BackendResult> wivrnInstallClient(String serial);
  /// Set up the USB link for WiVRn (reverse port forward). Only
  /// meaningful over USB.
  Future<BackendResult> wivrnSetupUsb(String serial);
  /// Install the WiVRn server on this PC.
  Future<BackendResult> wivrnInstallServer();
  /// Remember that the user said no to WiVRn setup, so the
  /// first-run card stops appearing.
  Future<BackendResult> wivrnDecline(String serial);
  /// Undo a decline, so the WiVRn first-run card appears again.
  Future<BackendResult> wivrnUndecline(String serial);
  // ---- SteamVR + Steam Link (experimental second runtime) ----
  /// SteamVR readiness in one call: Steam install (native vs
  /// Flatpak), SteamVR version/branch, NVIDIA driver, whether
  /// WiVRn is in the way, and plain-language fix instructions.
  /// Raw backend JSON.
  Future<Map<String, dynamic>> steamvrDetect();
  /// Is SteamVR running right now. Raw backend JSON.
  Future<Map<String, dynamic>> steamvrStatus();
  /// Stop WiVRn first, snapshot the runtime config, then start
  /// SteamVR through Steam. The user connects with Steam Link.
  Future<BackendResult> steamvrStart();
  /// Stop SteamVR and restore the snapshotted runtime config.
  Future<BackendResult> steamvrStop();
  /// The PC VR runtime choice for one headset: 'wivrn' (default)
  /// or 'steamvr' (experimental).
  Future<String> steamvrChoice(String serial);
  /// Set the PC VR runtime choice for one headset.
  Future<BackendResult> steamvrSetChoice(String serial, String runtime);
  // ---- Homes ----
  /// Home launchers installed on the headset (Meta Home, Lightning,
  /// Quest Home Switcher, and any other).
  Future<List<HomeEntry>> homesList(String serial);
  /// The component of the home launcher in use now, or null when the
  /// headset will not say.
  Future<String?> homesCurrent(String serial);
  /// Switch the home launcher. component is the full activity
  /// component name. The headset restarts its home screen.
  Future<BackendResult> homesSet(String serial, String component);
  /// Open the home launcher settings on the headset.
  Future<BackendResult> homesOpenSettings(String serial);
  /// Open one home launcher on the headset, once, without changing
  /// the default.
  Future<BackendResult> homesOpen(String serial, String component);
  /// Open the stock Meta Home on the headset.
  Future<BackendResult> homesOpenMeta(String serial);
  /// Open one Android settings screen on the headset. screen is one
  /// of wifi, bluetooth, display, storage, apps, about, home, settings.
  Future<BackendResult> homesOpenSettingsScreen(String serial, String screen);
  /// Downloadable home apps (launchers and helpers) with their
  /// install state.
  Future<List<HomeAppStatus>> homeAppsList(String serial);
  /// Download a home app to this computer. Raw backend JSON with
  /// the file path.
  Future<Map<String, dynamic>> homeAppDownload(String id);
  /// Install a downloaded home app on the headset. id is the home
  /// app id, not a package name.
  Future<BackendResult> homeAppInstall(String serial, String id);
  /// Uninstall a home app from the headset.
  Future<BackendResult> homeAppUninstall(String serial, String id);
  /// Open a home app on the headset.
  Future<BackendResult> homeAppOpen(String serial, String id);
  // ---- Paths and mirror settings ----
  /// The Setup checklist state, detected on this machine. Empty
  /// when the backend cannot be reached; each item carries its
  /// own done/detail, including "cannot check" as done null.
  Future<List<SetupCheck>> setupStatus();
  /// Where backups and recordings live on this computer. Null when the
  /// backend cannot read its paths file.
  Future<PathsInfo?> pathsGet();
  /// Change the backup and/or recordings folder. Only the folders
  /// passed in change; the rest stay as they are.
  Future<PathsInfo?> pathsSet({String? backupRoot, String? recordingsRoot});
  /// Put the backup and recordings folders back to their defaults.
  Future<PathsInfo?> pathsReset();
  /// Saved mirror view (stereo or flat). Null when unreadable.
  Future<MirrorSettings?> mirrorSettings();
  /// Save the mirror view. Only the value passed in changes.
  Future<MirrorSettings?> setMirrorSettings({String? view});
  /// Put the mirror view back to its default (both eyes).
  Future<MirrorSettings?> resetMirrorSettings();
  // ---- Singularity (root) ----
  /// Preflight checks before rooting with Singularity: is the headset
  /// ready, and what is missing. Null when the check itself fails.
  Future<SingularityPreflight?> singularityPreflight(String serial);
  /// Download the Singularity files to this computer. Raw backend
  /// JSON with paths.
  Future<Map<String, dynamic>> singularityDownload();
  /// Root the headset with Singularity. Needs the downloads first;
  /// takes a while.
  Future<BackendResult> singularityInstall(String serial);
  /// Check whether the headset is rooted. Never null: notRooted
  /// when the check fails.
  Future<RootStatus> singularityVerify(String serial);
  /// The Singularity files for this headset (Magisk, frida, hosts,
  /// and the rest) and whether each one is already downloaded.
  Future<List<SingularityDownload>> singularityDownloads(String serial);
  /// Download the frida server to this computer. Raw backend JSON.
  Future<Map<String, dynamic>> singularityDownloadFrida();
  /// Download the ad-blocking hosts file to this computer. Raw
  /// backend JSON.
  Future<Map<String, dynamic>> singularityDownloadHosts();
  /// Is frida downloaded, pushed to the headset, and running. Never
  /// null: all false when the check fails.
  Future<FridaStatusInfo> fridaStatus(String serial);
  /// Push the frida server onto the headset.
  Future<FridaStatusInfo> fridaPush(String serial);
  /// Start frida on the headset. Needs root.
  Future<FridaStatusInfo> fridaStart(String serial);
  /// Stop frida on the headset.
  Future<FridaStatusInfo> fridaStop(String serial);
  /// Is the ad-blocking hosts file downloaded and applied on the
  /// headset. Never null: all false when the check fails.
  Future<HostsStatusInfo> hostsStatus(String serial);
  /// Apply the ad-blocking hosts file on the headset. Needs root.
  Future<HostsStatusInfo> hostsApply(String serial);
  /// Remove the ad-blocking hosts file from the headset, back to stock.
  Future<HostsStatusInfo> hostsRemove(String serial);
  /// Is the system update blocked on the headset. Never null:
  /// unblocked when the check fails.
  Future<OtaStatusInfo> otaStatus(String serial);
  /// Block (true) or allow (false) system updates on the headset.
  /// Needs root; reversible, nothing is deleted.
  Future<OtaStatusInfo> otaSet(String serial, bool blocked);
  /// Singularity UXP settings on the headset (the extra toggles
  /// Singularity adds).
  Future<List<UxpSetting>> uxpList(String serial);
  /// Change one UXP setting. Returns the new value, or null when
  /// it fails.
  Future<UxpSetting?> uxpSet(String serial, String key, String value);
  /// Restart the headset's home screen (the launcher is force
  /// stopped so it relaunches).
  Future<BackendResult> restartHome(String serial);
  // ---- Snapshots ----
  /// Snapshot the whole headset: a device backup plus a snapshot file
  /// with the name and the active settings profile. profile is optional.
  /// Null when it fails.
  Future<Map<String, dynamic>?> snapshotCreate(String serial, String name, {String? profile});
  /// Every saved headset snapshot on this computer.
  Future<List<SnapshotEntry>> snapshotList();
  /// Restore a whole-headset snapshot, then re-apply the settings
  /// profile it recorded. dryRun reports first, confirm goes ahead.
  /// Null when it fails.
  Future<RestoreReport?> snapshotRestore(String serial, String path, {bool dryRun = false, bool confirm = false});
  /// Delete one snapshot from this computer.
  Future<BackendResult> snapshotDelete(String path);
  // ---- Device health and debug ----
  /// Battery, storage and uptime for the headset. Null when the headset
  /// cannot be read.
  Future<HealthInfo?> deviceHealth(String serial);
  /// Battery level over time, plus the apps that used the most
  /// foreground time. Null when unreadable.
  Future<BatteryHistory?> batteryHistory(String serial);
  /// Read an APK file on this computer: package, version,
  /// permissions, native libs, signature. Null when the file is not a
  /// readable APK.
  Future<ApkAnalysis?> analyzeApk(String path);
  /// Run one shell command on the headset and get its stdout, stderr
  /// and exit code. Null when the command cannot run. The backend gives
  /// up after 120 seconds.
  Future<ShellResult?> runShell(String serial, String command);
  /// Everything the Help screen shows about this setup: questctl and
  /// adb versions, backend path, root state, device info. Null when the
  /// headset is gone.
  Future<DebugInfo?> debugInfo(String serial);
  /// Is the headset rooted, and how. Never null: notRooted when the
  /// check fails.
  Future<RootStatus> rootStatus(String serial);
  /// The paired controllers and whether they are awake. Never null:
  /// an empty list with a note when they cannot be read. Controllers
  /// sleep fast and report nothing while asleep.
  Future<ControllersInfo> controllers(String serial);
  /// Is the system updater disabled on the headset. Null when
  /// unreadable.
  Future<UpdateBlockStatus?> updateBlockStatus(String serial);
  /// Block (true) or allow (false) system updates. Rooted only;
  /// reversible, nothing is deleted or flashed.
  Future<BackendResult> setUpdateBlock(String serial, bool block);
  // ---- Wi-Fi ----
  /// Set up wireless ADB automatically: find the headset's Wi-Fi IP,
  /// turn on tcpip, connect. A failure is quiet (connected false with
  /// a note); USB still works.
  Future<WifiSetupResult?> setupWifi(String serial);
  /// Reconnect to every saved Wi-Fi headset address. Returns the
  /// addresses that answered.
  Future<List<String>> wifiReconnect();
  /// The headset's Wi-Fi IP address, or null when it has none or
  /// is not on Wi-Fi.
  Future<String?> wifiIp(String serial);
  /// Reboot the headset.
  Future<BackendResult> reboot(String serial);
  /// Recent logcat lines from the headset. filter is applied here
  /// in the app, not by the backend; an empty filter returns everything.
  Future<List<String>> logLines(String serial, {String filter = ''});
  /// Pair or connect over Wi-Fi. With a 6-digit code this pairs
  /// (pairing port); without one it connects to an already-paired headset.
  Future<BackendResult> pairWifi(String ip, String port, String code);
  /// Drop the Wi-Fi adb connection to this headset. Wireless
  /// debugging stays on in the headset until turned off there.
  Future<BackendResult> disconnectWifi(String serial);
  // ---- Device backup ----
  /// Back up the whole headset (apps, saves, settings) to this computer.
  /// The result message carries the folder path.
  Future<BackendResult> deviceBackup(String serial);
  /// Every whole-headset backup on this computer.
  Future<List<DeviceBackupEntry>> listDeviceBackups();
  /// Restore a whole-headset backup. dryRun reports first, confirm
  /// goes ahead; skipApps skips the apps, includeData restores saved
  /// data. Null when it fails.
  Future<RestoreReport?> deviceRestore(String serial, String backupPath, {bool dryRun = false, bool confirm = false, bool skipApps = false, bool includeData = false});
  // ---- Settings ----
  /// Change one headset setting. key and value are the backend setting
  /// names (refresh rate, CPU/GPU level, and the rest).
  Future<BackendResult> setSetting(String serial, String key, String value);
  /// Apply a named settings profile (Balanced, Smooth, Battery
  /// saver). The backend maps it to its closest built-in profile.
  Future<BackendResult> applyProfile(String serial, SettingProfile profile);
}

/// Gallery folder on this computer: ~/quest-recordings/ (screenshots
/// and recordings together). Mirrors the backend gallery root.
String galleryDir() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  return '$home/quest-recordings';
}

/// Timestamp safe for file names (colons and dots replaced with dashes).
String _stamp() => DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');

// ------------------------- RealBackend --------------------------------------
// Spawns: questctl --json <command> [args...]
// Every command prints ONE JSON object: {"ok": true, ...} or {"ok": false, "error": "..."}
// If the binary is missing, every call returns ok:false with a plain message
// and the UI shows an error state (never demo data).

class RealBackend implements BackendService {
  final String cliPath;
  RealBackend(this.cliPath);

  /// Android only: the headset's Wi-Fi address (`ip:port`) once the
  /// user has connected. When set, every call runs with
  /// `--transport direct --addr <addr>` (libadb over Wi-Fi; the
  /// phone has no adb server, so the binary transport cannot work).
  /// Null on Linux and before the first Android connect.
  String? directAddr;

  /// Android only: the app's files dir, passed to questctl as HOME
  /// (Android apps have no HOME set; questctl needs one for its adb
  /// key and per-headset files). Null on Linux.
  String? androidHome;

  /// Android only: copy the bundled arm64 questctl out of the app
  /// assets into the app's files dir and make it executable.
  /// Returns (binary path, files dir), or null when it failed.
  /// Re-extracts when the bundled copy is newer than the one on
  /// disk, so an app update picks up a new backend.
  static Future<(String, String)?> extractAndroidCli() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      // Preferred path: questctl ships as a native library
      // (libquestctl.so in the APK's lib/arm64-v8a, installed to the
      // app's native library dir). Android 10 and later refuse to run
      // a binary out of the app's writable files dir, which is why
      // 0.2.32 failed on first connect with "Permission denied" even
      // though the extracted file had its execute bit set. The native
      // library dir is made to be run from, so use it when it is there.
      try {
        const channel = MethodChannel('reoculus/native');
        final libDir =
            await channel.invokeMethod<String>('nativeLibraryDir');
        if (libDir != null && libDir.isNotEmpty) {
          final native = File('$libDir/libquestctl.so');
          if (await native.exists()) return (native.path, dir.path);
        }
      } catch (_) {
        // No channel, or no native library on this device: fall
        // through to the extracted copy below.
      }
      final bytes = await rootBundle.load('assets/questctl-android-arm64');
      final file = File('${dir.path}/questctl');
      var rewrite = true;
      if (await file.exists()) {
        final old = await file.readAsBytes();
        rewrite = old.length != bytes.lengthInBytes;
      }
      if (rewrite) {
        await file.writeAsBytes(bytes.buffer.asUint8List());
        await Process.run('chmod', ['755', file.path]);
      }
      return (file.path, dir.path);
    } catch (_) {
      return null;
    }
  }
  @override
  String get label => 'Real backend';

  /// Paths to try for questctl when no path is configured: the dev
  /// tree, then PATH.
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

  // ---- Running questctl ----
  /// Run questctl --json with these args and parse the one JSON object
  /// it prints. Never throws: a missing binary or an empty answer comes
  /// back as ok:false.
  Future<Map<String, dynamic>> _run(List<String> args) async {
    try {
      final fullArgs = <String>['--json'];
      // Android: libadb direct transport to the headset's Wi-Fi
      // address. Linux: the binary transport (spawned adb) stays
      // the default; --addr is only passed when a direct address is
      // set, so Linux behaviour does not change.
      if (directAddr != null && directAddr!.isNotEmpty) {
        fullArgs.addAll(['--transport', 'direct', '--addr', directAddr!]);
      }
      fullArgs.addAll(args);
      final result = await Process.run(
        cliPath,
        fullArgs,
        // Android apps have no HOME; questctl needs one for its adb
        // key (~/.config/quest-companion/adbkey) and per-headset files.
        environment: androidHome != null ? {'HOME': androidHome!} : null,
      );
      final text = (result.stdout as String).trim();
      if (text.isEmpty) return {'ok': false, 'error': 'The backend gave no answer. Is questctl built?'};
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': 'Could not run the backend ($cliPath). $e'};
    }
  }

  /// Turn a backend JSON reply into a BackendResult: ok from the
  /// envelope, message from error or message.
  BackendResult _toResult(Map<String, dynamic> j) =>
      BackendResult(ok: j['ok'] == true, message: (j['error'] ?? j['message'] ?? '').toString(), data: j);

  @override
  // ---- Devices ----
  Future<List<QuestDevice>> listDevices() async {
    final j = await _run(['devices', 'list']);
    final list = (j['devices'] as List?) ?? [];
    return list.map((e) => QuestDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  /// Charging comes from the battery status or a plugged power
  /// source, and storage is converted from KiB to GB.
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
    // KiB to GB, rounded.
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
      headsetModel: (j['headset_model'] ?? 'unknown').toString(),
      supportsSingularity: j['supports_singularity'] != false,
      supportsHomeSwitcher: j['supports_home_switcher'] != false,
      batteryLevel: (battery['level'] is num) ? (battery['level'] as num).toInt() : 0,
      batteryTempC: (battery['temperature_c'] is num) ? (battery['temperature_c'] as num).round() : 0,
      batteryHealth: (battery['health'] ?? '').toString(),
      batteryVoltageMv: (battery['voltage_mv'] is num) ? (battery['voltage_mv'] as num).toInt() : 0,
      densityDpi: (j['density'] is num) ? (j['density'] as num).toInt() : 0,
      wifiIp: (j['wifi_ip'] as String?)?.isNotEmpty == true ? j['wifi_ip'] as String : null,
      storageUsedGb: kbToGb(storage['used_kb']),
      storageTotalGb: kbToGb(storage['total_kb']),
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
    );
  }

  @override
  // ---- Headset config ----
  /// The headset's own config file: name only, read on connect.
  /// There is nothing to sync by hand; settings and apps are read
  /// live from the headset, and the name is written only on rename.
  Future<HeadsetConfig> headsetConfig(String serial) async {
    final j = await _run(['devices', 'config-read', '--serial', serial]);
    if (j['ok'] != true) return HeadsetConfig.absent;
    return HeadsetConfig.fromJson(j);
  }

  @override
  /// Only sends --name when a non-empty name is given.
  Future<HeadsetConfig?> headsetConfigWrite(String serial, {String? name}) async {
    final args = ['devices', 'config-write', '--serial', serial];
    if (name != null && name.isNotEmpty) args.addAll(['--name', name]);
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return HeadsetConfig.fromJson(j);
  }

  @override
  Future<HeadsetConfig?> headsetConfigSetName(String serial, String name) async {
    final j = await _run(['devices', 'config-set-name', '--serial', serial, '--name', name]);
    if (j['ok'] != true) return null;
    return HeadsetConfig.fromJson(j);
  }

  @override
  // ---- Apps ----
  /// The --third-party, --with-icons and --with-sizes flags are only
  /// passed when asked; icon and size lookups cost extra time.
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
  /// Adds --reinstall unless told otherwise, so installing over an
  /// existing app updates it instead of failing.
  Future<BackendResult> installApk(String serial, String path, {bool reinstall = true}) async {
    final args = ['apps', 'install', '--serial', serial, '--apk', path];
    if (reinstall) args.add('--reinstall');
    return _toResult(await _run(args));
  }

  @override
  Future<BackendResult> installMultiple(String serial, List<String> paths) async =>
      _toResult(await _run(['apps', 'install-multiple', '--serial', serial, '--apks', paths.join(',')]));

  @override
  /// keepData adds -k, so the app's saved data survives the uninstall.
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
  /// Passes --confirm because the UI already asked the user; not a
  /// silent bypass.
  Future<BackendResult> clearAppData(String serial, String package) async =>
      // Backend requires --confirm (CONTRACT.md). The UI already asks
      // the user in a confirm dialog before calling this, so passing it
      // here is correct, not a silent bypass.
      _toResult(await _run(['apps', 'clear-data', '--serial', serial, '--package', package, '--confirm']));

  @override
  // ---- Backups ----
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
  // ---- Library ----
  Future<List<LibraryEntry>> listLibrary() async {
    final j = await _run(['library', 'list']);
    final list = (j['entries'] as List?) ?? [];
    return list.map((e) => LibraryEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<AppIcon?> libraryIcon(LibraryEntry entry) async {
    final j = await _run(['library', 'icon', '--path', entry.path, '--package', entry.package, '--version', entry.version, '--kind', entry.kind]);
    if (j['ok'] != true) return null; // save backup, or no launcher icon: caller falls back
    final path = (j['icon_path'] ?? '').toString();
    if (path.isEmpty) return null;
    return AppIcon.fromJson(j);
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
  // ---- Files ----
  /// The backend answers under the key 'entries', not 'files'.
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
  Future<BackendResult> renameFile(String serial, String from, String to) async =>
      _toResult(await _run(['files', 'rename', '--serial', serial, '--from', from, '--to', to]));

  @override
  Future<BackendResult> makeDir(String serial, String remote) async =>
      _toResult(await _run(['files', 'mkdir', '--serial', serial, '--remote', remote]));

  @override
  // ---- Mirror and gallery ----
  /// An empty outPath saves into the gallery folder with a timestamp name.
  Future<BackendResult> screenshot(String serial, String outPath) async {
    // Default: save into the gallery folder with a timestamp name.
    final out = outPath.isEmpty ? '${galleryDir()}/shot-${_stamp()}.png' : outPath;
    final r = await _run(['device', 'screenshot', '--serial', serial, '--out', out]);
    if (r['ok'] == true) return BackendResult(ok: true, message: 'Screenshot saved to $out', data: {'path': out});
    return _toResult(r);
  }

  @override
  /// Stitches the segments from a long recording into one video
  /// at `out`. Contract: `device record-finish --serial X --dir
  /// <dir> --out <file.mp4>`. The backend remuxes to .mp4 when
  /// ffmpeg is installed, otherwise the result is a raw .h264.
  Future<BackendResult> finishRecording(String serial, String dir, String out) async {
    final r = await _run(['device', 'record-finish', '--serial', serial, '--dir', dir, '--out', out]);
    if (r['ok'] == true) {
      final path = (r['path'] as String?) ?? out;
      final n = r['segments'];
      final note = r['note'] as String?;
      final msg = note != null
          ? 'Recording saved to $path ($n parts). $note'
          : 'Recording saved to $path ($n parts)';
      return BackendResult(ok: true, message: msg, data: {'path': path});
    }
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
  /// Linux only: on Android there is no file viewer, so it returns
  /// the path for the UI to show.
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
  /// Linux only: on Android there is no file manager, so it returns
  /// the path for the UI to show.
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
  // ---- WiVRn ----
  Future<Map<String, dynamic>> wivrnDetect() async => await _run(['wivrn', 'detect']);
  @override
  Future<Map<String, dynamic>> wivrnStatus() async => await _run(['wivrn', 'status']);
  @override
  Future<BackendResult> wivrnStart() async => _toResult(await _run(['wivrn', 'start']));
  @override
  Future<BackendResult> wivrnStop() async => _toResult(await _run(['wivrn', 'stop']));
  @override
  Future<BackendResult> wivrnConfig(String encoder, String codec, {int bitDepth = 10, bool tcpOnly = false}) async => _toResult(await _run(['wivrn', 'config', '--encoder', encoder, '--codec', codec, '--bit-depth', '$bitDepth', '--tcp-only', tcpOnly ? 'on' : 'off']));
  @override
  Future<List<WivrnApp>> wivrnAppsList() async {
    final j = await _run(['wivrn', 'apps-list']);
    final list = (j['apps'] as List?) ?? [];
    return list.map((e) => WivrnApp.fromJson(e as Map<String, dynamic>)).toList();
  }
  @override
  Future<BackendResult> wivrnAppsAdd(String name, String exec, {String launchOptions = '', String icon = '', String comment = ''}) async => _toResult(await _run([
        'wivrn',
        'apps-add',
        '--name',
        name,
        '--exec',
        exec,
        if (launchOptions.isNotEmpty) '--launch-options',
        if (launchOptions.isNotEmpty) launchOptions,
        if (icon.isNotEmpty) '--icon',
        if (icon.isNotEmpty) icon,
        if (comment.isNotEmpty) '--comment',
        if (comment.isNotEmpty) comment,
      ]));
  @override
  Future<BackendResult> wivrnAppsUpdate(String file, String name, String exec, {String launchOptions = '', String icon = '', String comment = ''}) async => _toResult(await _run([
        'wivrn',
        'apps-update',
        '--file',
        file,
        '--name',
        name,
        '--exec',
        exec,
        if (launchOptions.isNotEmpty) '--launch-options',
        if (launchOptions.isNotEmpty) launchOptions,
        if (icon.isNotEmpty) '--icon',
        if (icon.isNotEmpty) icon,
        if (comment.isNotEmpty) '--comment',
        if (comment.isNotEmpty) comment,
      ]));
  @override
  Future<BackendResult> wivrnAppsRemove(String file) async => _toResult(await _run(['wivrn', 'apps-remove', '--file', file]));
  @override
  Future<WivrnClientSettings?> wivrnClientSettings(String serial) async {
    final j = await _run(['wivrn', 'client-settings', '--serial', serial]);
    if (j['ok'] != true) return null;
    return WivrnClientSettings.fromJson(j);
  }
  @override
  /// Every setting is passed as its own flag; on/off settings become
  /// 'on'/'off' strings.
  Future<BackendResult> wivrnClientSettingsSet(String serial, WivrnClientSettings s) async => _toResult(await _run([
        'wivrn',
        'client-settings-set',
        '--serial',
        serial,
        '--bitrate-mbps',
        '${s.bitrateMbps}',
        '--resolution-scale',
        '${s.resolutionScale}',
        '--refresh-rate',
        '${s.preferredRefreshRate}',
        '--codec',
        s.codec,
        '--bit-depth',
        '${s.bitDepth}',
        '--passthrough',
        s.passthroughEnabled ? 'on' : 'off',
        '--foveation',
        s.overrideFoveationEnable ? 'on' : 'off',
        '--high-power',
        s.highPowerMode ? 'on' : 'off',
        '--forward-keyboard',
        s.forwardKeyboard ? 'on' : 'off',
        '--forward-mouse',
        s.forwardMouse ? 'on' : 'off',
        '--forward-gamepad',
        s.forwardGamepad ? 'on' : 'off',
      ]));
  @override
  /// Null when the client is not installed.
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
  Future<Map<String, dynamic>> steamvrDetect() async => await _run(['steamvr', 'detect']);

  @override
  Future<Map<String, dynamic>> steamvrStatus() async => await _run(['steamvr', 'status']);

  @override
  Future<BackendResult> steamvrStart() async => _toResult(await _run(['steamvr', 'start']));

  @override
  Future<BackendResult> steamvrStop() async => _toResult(await _run(['steamvr', 'stop']));

  @override
  Future<String> steamvrChoice(String serial) async {
    final j = await _run(['steamvr', 'choice', '--serial', serial]);
    return (j['runtime'] ?? 'wivrn').toString();
  }

  @override
  Future<BackendResult> steamvrSetChoice(String serial, String runtime) async =>
      _toResult(await _run(['steamvr', 'set-choice', '--serial', serial, '--runtime', runtime]));

  @override
  // ---- Homes ----
  Future<List<HomeEntry>> homesList(String serial) async {
    final j = await _run(['homes', 'list', '--serial', serial]);
    final list = (j['homes'] as List?) ?? [];
    return list.map((e) => HomeEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  /// An empty answer means no home launcher could be read, so it
  /// returns null.
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
  Future<BackendResult> homesOpen(String serial, String component) async =>
      _toResult(await _run(['homes', 'open', '--serial', serial, '--component', component]));

  @override
  Future<BackendResult> homesOpenMeta(String serial) async =>
      _toResult(await _run(['homes', 'open-meta', '--serial', serial]));

  @override
  Future<BackendResult> homesOpenSettingsScreen(String serial, String screen) async =>
      _toResult(await _run(['homes', 'open-settings-screen', '--serial', serial, '--screen', screen]));

  @override
  Future<List<HomeAppStatus>> homeAppsList(String serial) async {
    final j = await _run(['home-apps', 'list', '--serial', serial]);
    final list = (j['home_apps'] as List?) ?? [];
    return list.map((e) => HomeAppStatus.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Map<String, dynamic>> homeAppDownload(String id) async =>
      await _run(['home-apps', 'download', '--id', id]);

  @override
  Future<BackendResult> homeAppInstall(String serial, String id) async =>
      _toResult(await _run(['home-apps', 'install', '--serial', serial, '--id', id]));

  @override
  Future<BackendResult> homeAppUninstall(String serial, String id) async =>
      _toResult(await _run(['home-apps', 'uninstall', '--serial', serial, '--id', id]));

  @override
  Future<BackendResult> homeAppOpen(String serial, String id) async =>
      _toResult(await _run(['home-apps', 'open', '--serial', serial, '--id', id]));

  @override
  // ---- Paths and mirror settings ----
  Future<List<SetupCheck>> setupStatus() async {
    final j = await _run(['setup', 'status']);
    final list = (j['checks'] as List?) ?? [];
    return list.map((e) => SetupCheck.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<PathsInfo?> pathsGet() async {
    final j = await _run(['paths', 'get']);
    if (j['ok'] != true) return null;
    return PathsInfo.fromJson(j);
  }

  @override
  Future<PathsInfo?> pathsSet({String? backupRoot, String? recordingsRoot}) async {
    final args = ['paths', 'set'];
    if (backupRoot != null) args.addAll(['--backup-root', backupRoot]);
    if (recordingsRoot != null) args.addAll(['--recordings-root', recordingsRoot]);
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return PathsInfo.fromJson(j);
  }

  @override
  Future<PathsInfo?> pathsReset() async {
    final j = await _run(['paths', 'reset']);
    if (j['ok'] != true) return null;
    return PathsInfo.fromJson(j);
  }

  @override
  Future<MirrorSettings?> mirrorSettings() async {
    final j = await _run(['mirror-settings', 'get']);
    if (j['ok'] != true) return null;
    return MirrorSettings.fromJson(j);
  }

  @override
  Future<MirrorSettings?> setMirrorSettings({String? view}) async {
    final args = ['mirror-settings', 'set'];
    if (view != null) args.addAll(['--view', view]);
    final j = await _run(args);
    if (j['ok'] != true) return null;
    return MirrorSettings.fromJson(j);
  }

  @override
  Future<MirrorSettings?> resetMirrorSettings() async {
    final j = await _run(['mirror-settings', 'reset']);
    if (j['ok'] != true) return null;
    return MirrorSettings.fromJson(j);
  }

  @override
  // ---- Singularity (root) ----
  // Frida, hosts and OTA calls below return an all-false default when
  // the backend says no, never null, so the UI can always read the fields.
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
  Future<List<SingularityDownload>> singularityDownloads(String serial) async {
    final j = await _run(['singularity', 'downloads', '--serial', serial]);
    final list = (j['downloads'] as List?) ?? [];
    return list.map((e) => SingularityDownload.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Map<String, dynamic>> singularityDownloadFrida() async =>
      await _run(['singularity', 'download-frida']);

  @override
  Future<Map<String, dynamic>> singularityDownloadHosts() async =>
      await _run(['singularity', 'download-hosts']);

  @override
  Future<FridaStatusInfo> fridaStatus(String serial) async {
    final j = await _run(['singularity', 'frida', 'status', '--serial', serial]);
    if (j['ok'] != true) return const FridaStatusInfo(downloaded: false, pushed: false, running: false, sizeBytes: 0);
    return FridaStatusInfo.fromJson(j);
  }

  @override
  Future<FridaStatusInfo> fridaPush(String serial) async {
    final j = await _run(['singularity', 'frida', 'push', '--serial', serial]);
    if (j['ok'] != true) return const FridaStatusInfo(downloaded: false, pushed: false, running: false, sizeBytes: 0);
    return FridaStatusInfo.fromJson(j);
  }

  @override
  Future<FridaStatusInfo> fridaStart(String serial) async {
    final j = await _run(['singularity', 'frida', 'start', '--serial', serial]);
    if (j['ok'] != true) return const FridaStatusInfo(downloaded: false, pushed: false, running: false, sizeBytes: 0);
    return FridaStatusInfo.fromJson(j);
  }

  @override
  Future<FridaStatusInfo> fridaStop(String serial) async {
    final j = await _run(['singularity', 'frida', 'stop', '--serial', serial]);
    if (j['ok'] != true) return const FridaStatusInfo(downloaded: false, pushed: false, running: false, sizeBytes: 0);
    return FridaStatusInfo.fromJson(j);
  }

  @override
  Future<HostsStatusInfo> hostsStatus(String serial) async {
    final j = await _run(['singularity', 'hosts', 'status', '--serial', serial]);
    if (j['ok'] != true) return const HostsStatusInfo(downloaded: false, applied: false, domains: 0, sizeBytes: 0, systemLines: 0, moduleDomains: 0);
    return HostsStatusInfo.fromJson(j);
  }

  @override
  Future<HostsStatusInfo> hostsApply(String serial) async {
    final j = await _run(['singularity', 'hosts', 'apply', '--serial', serial]);
    if (j['ok'] != true) return const HostsStatusInfo(downloaded: false, applied: false, domains: 0, sizeBytes: 0, systemLines: 0, moduleDomains: 0);
    return HostsStatusInfo.fromJson(j);
  }

  @override
  Future<HostsStatusInfo> hostsRemove(String serial) async {
    final j = await _run(['singularity', 'hosts', 'remove', '--serial', serial]);
    if (j['ok'] != true) return const HostsStatusInfo(downloaded: false, applied: false, domains: 0, sizeBytes: 0, systemLines: 0, moduleDomains: 0);
    return HostsStatusInfo.fromJson(j);
  }

  @override
  Future<OtaStatusInfo> otaStatus(String serial) async {
    final j = await _run(['singularity', 'ota', 'status', '--serial', serial]);
    if (j['ok'] != true) return const OtaStatusInfo(blocked: false, updaterDisabled: false);
    return OtaStatusInfo.fromJson(j);
  }

  @override
  Future<OtaStatusInfo> otaSet(String serial, bool blocked) async {
    final j = await _run(['singularity', 'ota', blocked ? 'block' : 'allow', '--serial', serial]);
    if (j['ok'] != true) return const OtaStatusInfo(blocked: false, updaterDisabled: false);
    return OtaStatusInfo.fromJson(j);
  }

  @override
  Future<List<UxpSetting>> uxpList(String serial) async {
    final j = await _run(['singularity', 'uxp', 'list', '--serial', serial]);
    final list = (j['settings'] as List?) ?? [];
    return list.map((e) => UxpSetting.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<UxpSetting?> uxpSet(String serial, String key, String value) async {
    final j = await _run(['singularity', 'uxp', 'set', '--serial', serial, '--key', key, '--value', value]);
    if (j['ok'] != true) return null;
    return UxpSetting.fromJson(j);
  }

  @override
  Future<BackendResult> restartHome(String serial) async =>
      _toResult(await _run(['singularity', 'restart-home', '--serial', serial]));

  @override
  // ---- Snapshots ----
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
  // ---- Device health and debug ----
  Future<HealthInfo?> deviceHealth(String serial) async {
    final j = await _run(['devices', 'health', '--serial', serial]);
    if (j['ok'] != true) return null;
    return HealthInfo.fromJson(j);
  }

  @override
  Future<BatteryHistory?> batteryHistory(String serial) async {
    final j = await _run(['devices', 'battery-history', '--serial', serial]);
    if (j['ok'] != true) return null;
    return BatteryHistory.fromJson(j);
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
  /// Rebuilds the device info from the nested 'device' object, with
  /// the same charging and KiB rules as deviceInfo.
  Future<DebugInfo?> debugInfo(String serial) async {
    final j = await _run(['devices', 'debug-info', '--serial', serial]);
    if (j['ok'] != true) return null;
    final dev = (j['device'] as Map?) ?? {};
    final battery = (dev['battery'] as Map?) ?? {};
    final storage = (dev['storage'] as Map?) ?? {};
    // KiB to GB, rounded.
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
      batteryHealth: (battery['health'] ?? '').toString(),
      batteryVoltageMv: (battery['voltage_mv'] is num) ? (battery['voltage_mv'] as num).toInt() : 0,
      densityDpi: (dev['density'] is num) ? (dev['density'] as num).toInt() : 0,
      wifiIp: (dev['wifi_ip'] as String?)?.isNotEmpty == true ? dev['wifi_ip'] as String : null,
      storageUsedGb: kbToGb(storage['used_kb']),
      storageTotalGb: kbToGb(storage['total_kb']),
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
    );
    return DebugInfo(
      questctlVersion: (j['questctl_version'] ?? '').toString(),
      adbVersion: (j['adb_version'] ?? '').toString(),
      backendPath: (j['backend_path'] ?? '').toString(),
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
  /// Never null: on failure it returns an empty list with a note, so
  /// the UI shows a message instead of crashing.
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
  /// Sends --block or --unblock. Rooted headsets only.
  Future<BackendResult> setUpdateBlock(String serial, bool block) async => _toResult(await _run([
        'devices',
        'update-block',
        '--serial',
        serial,
        if (block) '--block' else '--unblock',
      ]));

  @override
  // ---- Wi-Fi ----
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
  /// The filter is applied here in the app, after the full logcat
  /// dump; the backend gets no filter.
  Future<List<String>> logLines(String serial, {String filter = ''}) async {
    final j = await _run(['device', 'logcat', '--serial', serial]);
    final list = (j['lines'] as List?) ?? [];
    final lines = list.map((e) => e.toString()).toList();
    if (filter.isEmpty) return lines;
    return lines.where((l) => l.toLowerCase().contains(filter.toLowerCase())).toList();
  }

  @override
  /// Modern flow only: with a code it pairs, without one it
  /// connects. The legacy pair-wifi command is never used here.
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
  // ---- Device backup ----
  /// On success the message carries the folder path the backup was saved to.
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
}
