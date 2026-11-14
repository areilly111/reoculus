import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models.dart';
import '../theme.dart';
import 'backend.dart';

// App-wide state: selected headset, design direction, backend path,
// activity log, root/controller state, Wi-Fi setup notes. Kept in one
// small ChangeNotifier so every screen reads the same state.
// Real mode only: there is no demo data. If the backend is missing
// or no headset is connected, the UI shows an error state.
// No account, no analytics, nothing leaves this computer.
// Quest 2 first: every feature targets the Quest 2 (Android 14,
// Horizon OS), offline, with no Meta account.
class AppState extends ChangeNotifier {
  BackendService _backend;

  /// Production uses the real backend. Tests pass a fake: the UI
  /// never talks to a headset except through this one object.
  AppState({BackendService? backend})
      : _backend = backend ?? RealBackend('../backend/target/debug/questctl');
  String? backendPath; // null = auto-detect
  String? backendError; // set when Real mode cannot find/run questctl
  // PICKED 2026-11-12: C Dark VR Neon, blue instead of purple .
  DesignDirection design = DesignDirection.vrNeon;
  QuestDevice? selectedDevice;
  List<QuestDevice> devices = [];
  DeviceInfo? deviceInfo;
  /// Android only: the headset's saved Wi-Fi address (`ip:port`).
  /// The phone has no adb server, so there is no discovery: the
  /// app probes this address directly. Saved to headset-addr.txt
  /// in the app's files dir on connect.
  String? androidAddr;
  /// The selected headset's own config file (headset.cfg on the
  /// headset), read on every refresh. Null when no headset is
  /// selected; HeadsetConfig.absent when it has never been synced.
  /// The custom name in here is what the UI shows for the headset.
  HeadsetConfig? headsetConfig;
  /// The name shown for the selected headset: the custom name from
  /// its config file when it has one, else the model name.
  String get headsetName =>
      headsetConfig?.name ?? deviceInfo?.displayName ?? selectedDevice?.displayName ?? 'No headset';
  /// In-memory icon cache: package -> AppIcon, or null when the app
  /// has no launcher icon / its icon could not be read (so the UI
  /// stops asking for it). Filled lazily as app rows appear on screen;
  /// the backend also caches icon files on disk per package+version.
  final Map<String, AppIcon?> iconCache = {};
  final Set<String> _iconLoading = {};
  final List<String> activity = [];
  final List<SettingProfile> profiles = const [
    SettingProfile(name: 'Balanced', refreshRate: 90, cpuLevel: 2, gpuLevel: 2, resolution: 'Default', guardianPaused: false),
    SettingProfile(name: 'Smooth', refreshRate: 120, cpuLevel: 3, gpuLevel: 3, resolution: 'Default', guardianPaused: false),
    SettingProfile(name: 'Battery saver', refreshRate: 72, cpuLevel: 1, gpuLevel: 1, resolution: 'Lower', guardianPaused: false),
  ];

  /// Profiles offered for one headset. Quest 1 tops out at 72 Hz, so
  /// Smooth (120 Hz) is not offered there; Balanced runs at 72 Hz.
  /// The backend clamps the matching built-in profile the same way,
  /// so the name the UI sends always applies cleanly.
  List<SettingProfile> profilesForHeadset(String headsetModel) {
    if (headsetModel == 'quest1') {
      return const [
        SettingProfile(name: 'Balanced', refreshRate: 72, cpuLevel: 2, gpuLevel: 2, resolution: 'Default', guardianPaused: false),
        SettingProfile(name: 'Battery saver', refreshRate: 72, cpuLevel: 1, gpuLevel: 1, resolution: 'Lower', guardianPaused: false),
      ];
    }
    return profiles;
  }
  String activeProfile = 'Balanced';

  /// Per-headset saved profile (serial -> profile name). A Quest 2
  /// and a Quest 3 keep their own settings: switching headsets
  /// applies the profile saved for the one you picked. Saved on
  /// Linux to ~/.config/quest-companion/device-profiles.json;
  /// in-memory only on Android (no questctl there yet).
  final Map<String, String> deviceProfiles = {};

  /// Battery / health for the selected headset (loaded lazily by
  /// the Device and Settings screen).
  HealthInfo? health;

  // ---- Profiles ----
  /// The per-headset profiles file on Linux, or null on Android (no
  /// file there yet).
  Future<File?> _deviceProfilesFile() async {
    if (!Platform.isLinux) return null;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return File('$home/.config/quest-companion/device-profiles.json');
  }

  /// Read the saved per-headset profiles from disk (Linux only;
  /// Android keeps them in memory). A missing file means no saved
  /// profiles yet.
  Future<void> loadDeviceProfiles() async {
    final f = await _deviceProfilesFile();
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      deviceProfiles.clear();
      for (final e in j.entries) {
        if (e.value is String) deviceProfiles[e.key] = e.value as String;
      }
    } catch (_) {}
  }

  /// Write the per-headset profiles to disk. Quietly does nothing
  /// on Android or when the file cannot be written.
  Future<void> _saveDeviceProfiles() async {
    final f = await _deviceProfilesFile();
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(deviceProfiles));
    } catch (_) {}
  }

  String? profileFor(String serial) => deviceProfiles[serial];

  /// Remember a profile for this headset and apply it now.
  Future<void> setDeviceProfile(String serial, SettingProfile p) async {
    activeProfile = p.name;
    deviceProfiles[serial] = p.name;
    await _saveDeviceProfiles();
    await _backend.applyProfile(serial, p);
    notifyListeners();
  }

  /// Root / controller state for the selected device (loaded lazily
  /// by the Devices screen; null until checked).
  RootStatus? rootStatus;
  ControllersInfo? controllers;
  // WiVRn first-run setup: headset client version (null = not
  // installed), whether the user said no, whether the server is
  // installed on this PC. Checked once per headset connection.
  // `wivrnSetupKnown` is only true after a check actually finished:
  // before that, a null client version means "not checked yet", not
  // "not installed". A failed check leaves it false so the next
  // refresh retries instead of showing the install card forever.
  String? wivrnClientVersion;
  bool wivrnDeclined = false;
  bool wivrnServerInstalled = false;
  bool wivrnSetupKnown = false;
  bool _wivrnChecked = false;
  UpdateBlockStatus? updateBlock;
  bool _rootLoading = false;

  /// Plain note about the automatic Wi-Fi setup ("Wi-Fi connection
  /// ready, you can unplug the USB cable" or the quiet failure note).
  String? wifiNote;
  bool wifiBusy = false;
  final Set<String> _wifiSetupDone = {};

  BackendService get backend => _backend;

  // ---- Activity log ----
  /// Add one line to the activity log, newest first, capped at 200 lines.
  void log(String entry) {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    activity.insert(0, '$time  $entry');
    if (activity.length > 200) activity.removeLast();
    notifyListeners();
  }

  /// Empty the activity log.
  void clearActivity() {
    activity.clear();
    notifyListeners();
  }

  // ---- Backend setup ----
  /// Find questctl (custom path from Setup) and
  /// use it. When it cannot be found, backendError is set and the UI
  /// shows an error state; nothing falls back to sample data.
  /// On Android the arm64 questctl bundled in the app is extracted
  /// to the app's files dir and used over Wi-Fi (direct transport);
  /// there is no adb server on a phone, so USB discovery does not
  /// exist there and the headset is found by its saved Wi-Fi address.
  Future<void> initBackend({String? path}) async {
    if (Platform.isAndroid) {
      final extracted = await RealBackend.extractAndroidCli();
      if (extracted == null) {
        backendError =
            'The Android backend could not be set up (the bundled questctl could not be extracted). Reinstall the app; if it still fails, use the Linux app on a PC.';
        notifyListeners();
        return;
      }
      final (cliPath, docsDir) = extracted;
      final backend = RealBackend(cliPath)..androidHome = docsDir;
      _backend = backend;
      backendPath = cliPath;
      backendError = null;
      log('Real backend connected ($cliPath)');
      // The headset's Wi-Fi address, saved from the last connect.
      final addrFile = File('$docsDir/headset-addr.txt');
      if (await addrFile.exists()) {
        final saved = (await addrFile.readAsString()).trim();
        if (saved.isNotEmpty) {
          androidAddr = saved;
          backend.directAddr = saved;
        }
      }
      notifyListeners();
      await refreshDevices();
      return;
    }
    backendPath = path ?? backendPath;
    final found = await RealBackend.findCli(backendPath);
    if (found == null) {
      backendError =
          'Backend not found at ${backendPath ?? '../backend/target/debug/questctl'}. Build the Rust backend first (cargo build in backend/), or check the backend path in Setup.';
      _backend = RealBackend(backendPath ?? '../backend/target/debug/questctl');
      notifyListeners();
      return;
    }
    backendPath = found;
    backendError = null;
    _backend = RealBackend(found);
    log('Real backend connected ($backendPath)');
    await loadDeviceProfiles();
    notifyListeners();
    await refreshDevices();
  }

  /// Point the app at a different questctl path (from Setup).
  Future<void> setBackendPath(String path) async {
    await initBackend(path: path.trim().isEmpty ? null : path.trim());
  }

  /// Switch the design direction (theme).
  void setDesign(DesignDirection d) {
    design = d;
    notifyListeners();
  }

  /// Rooted: include app data (/data/data) in app backups.
  /// On automatically when root is detected, no setting to change.
  bool backupDataByDefault = false;
  /// Turn on or off including app data in backups by default.
  void setBackupDataByDefault(bool v) {
    backupDataByDefault = v;
    notifyListeners();
  }

  /// Apps view: false = list (default), true = tiles (grid).
  /// Swap with the List / Tiles toggle on the Apps screen.
  bool appsTiles = false;
  /// Apps view: list (false) or tiles (true).
  void setAppsTiles(bool tiles) {
    appsTiles = tiles;
    notifyListeners();
  }

  /// Library view: false = list (default), true = tiles (grid).
  /// Same toggle as the Apps tab, on the Library tab.
  bool libraryTiles = false;
  /// Library view: list (false) or tiles (true).
  void setLibraryTiles(bool tiles) {
    libraryTiles = tiles;
    notifyListeners();
  }

  /// Library icons, keyed by the entry's path (one entry can share
  /// a package with another version, so package alone is not a
  /// key). Null means no launcher icon, so the UI stops asking.
  final Map<String, AppIcon?> libraryIconCache = {};
  final Set<String> _libraryIconLoading = {};

  // ---- Icons ----
  /// Load one library entry's icon from the APK already on this
  /// computer (backend `library icon`). No headset needed, and no
  /// re-extract on repeat loads: the backend caches the file on
  /// disk per package+version, and this cache holds the result
  /// in memory for the session.
  Future<AppIcon?> libraryIcon(LibraryEntry entry) async {
    if (libraryIconCache.containsKey(entry.path)) return libraryIconCache[entry.path];
    if (_libraryIconLoading.contains(entry.path)) return null;
    _libraryIconLoading.add(entry.path);
    AppIcon? icon;
    try {
      icon = await _backend.libraryIcon(entry);
    } catch (_) {
      icon = null;
    }
    _libraryIconLoading.remove(entry.path);
    libraryIconCache[entry.path] = icon;
    notifyListeners();
    return icon;
  }

  /// Load one app's icon (real label + local file), cached in memory
  /// and on disk by the backend. Returns null when the app has no
  /// launcher icon. Safe to call for every visible row: repeat calls
  /// for the same package return the cached result, and concurrent
  /// calls for one package share a single backend call.
  Future<AppIcon?> appIcon(String serial, String package) async {
    if (iconCache.containsKey(package)) return iconCache[package];
    if (_iconLoading.contains(package)) return null;
    _iconLoading.add(package);
    AppIcon? icon;
    try {
      icon = await _backend.appIcon(serial, package);
    } catch (_) {
      icon = null;
    }
    _iconLoading.remove(package);
    iconCache[package] = icon;
    notifyListeners();
    return icon;
  }

  // ---- Devices ----
  /// Re-read the headset list and the selected headset's info, config,
  /// WiVRn state and Wi-Fi setup. Android probes the saved Wi-Fi
  /// address; Linux lists adb devices and retries saved Wi-Fi IPs when
  /// USB finds nothing.
  Future<void> refreshDevices() async {
    try {
      if (Platform.isAndroid) {
        // No discovery on a phone: probe the saved Wi-Fi address
        // directly. A failed probe means no headset (or the wrong
        // address); the Connect dialog is the way back.
        if (androidAddr != null && androidAddr!.isNotEmpty) {
          final info = await _backend.deviceInfo(androidAddr!);
          if (info != null) {
            final d = QuestDevice(
              serial: androidAddr!,
              state: 'device',
              model: info.model,
              device: '',
              headsetModel: info.headsetModel,
              transport: 'wifi',
            );
            devices = [d];
            selectedDevice = d;
            deviceInfo = info;
            headsetConfig = await _backend.headsetConfig(androidAddr!);
            rootStatus = null;
            controllers = null;
            updateBlock = null;
            notifyListeners();
            return;
          }
        }
        devices = [];
        selectedDevice = null;
        deviceInfo = null;
        headsetConfig = null;
        notifyListeners();
        return;
      }
      devices = await _backend.listDevices();
      if (devices.isEmpty) {
        // No USB device: try the saved Wi-Fi IPs before giving up.
        final reconnected = await _backend.wifiReconnect();
        if (reconnected.isNotEmpty) {
          devices = await _backend.listDevices();
          wifiNote = 'Reconnected over Wi-Fi (${reconnected.join(', ')}).';
        }
      }
      // Prefer USB over Wi-Fi when both entries exist for the same
      // headset: the mirror is far more stable over USB than Wi-Fi.
      selectedDevice ??= devices.isNotEmpty
          ? devices.firstWhere((d) => d.transport == 'usb', orElse: () => devices.first)
          : null;
      if (selectedDevice != null && devices.isNotEmpty && !devices.any((d) => d.serial == selectedDevice!.serial)) {
        selectedDevice = devices.first;
      }
      if (selectedDevice != null) {
        deviceInfo = await _backend.deviceInfo(selectedDevice!.serial);
        headsetConfig = await _backend.headsetConfig(selectedDevice!.serial);
        await checkWivrnSetup();
        rootStatus = null;
        controllers = null;
        updateBlock = null;
        await _maybeSetupWifi(selectedDevice!);
      } else {
        deviceInfo = null;
        headsetConfig = null;
      }
    } catch (e) {
      devices = [];
      deviceInfo = null;
      headsetConfig = null;
    }
    notifyListeners();
  }

  /// Save a custom name for a headset (empty clears it). Targets
  /// the given serial, or the selected headset when none is given.
  /// The name lives in the headset's own config file, so every
  /// computer and phone sees it on the next connect. Returns the
  /// saved config, or null when the backend could not write it.
  Future<HeadsetConfig?> renameHeadset(String name, {String? serial}) async {
    final target = serial ?? selectedDevice?.serial;
    if (target == null) return null;
    final cfg = await _backend.headsetConfigSetName(target, name);
    if (cfg == null) return null;
    if (target == selectedDevice?.serial) {
      headsetConfig = cfg;
      notifyListeners();
    }
    return cfg;
  }

  // ---- Wi-Fi ----
  /// Android only: connect to the headset over Wi-Fi with the
  /// direct transport. Sets the address first (the pair/connect
  /// call itself needs it), then saves it on success so the next
  /// launch probes the same headset. The port is 5555 for plain
  /// wireless ADB, or the pairing port with a 6-digit code.
  Future<BackendResult> connectWifiDirect(String ip, String port, String code) async {
    final addr = '${ip.trim()}:${port.trim()}';
    androidAddr = addr;
    final backend = _backend;
    if (backend is RealBackend) backend.directAddr = addr;
    final r = await _backend.pairWifi(ip.trim(), port.trim(), code.trim());
    if (r.ok) {
      try {
        final home = (backend is RealBackend) ? backend.androidHome : null;
        if (home != null) await File('$home/headset-addr.txt').writeAsString(addr);
      } catch (_) {}
      await refreshDevices();
    }
    return r;
  }

  /// Automatic wireless setup, once per device per session: when a
  /// headset first connects over USB and no wireless entry is saved
  /// yet for it, set up Wi-Fi (tcpip 5555 + connect) so the user can
  /// unplug. A failure is a quiet note, never an error: USB still
  /// works. The backend saves the IP on success.
  Future<void> _maybeSetupWifi(QuestDevice d) async {
    if (d.transport != 'usb') return;
    if (_wifiSetupDone.contains(d.serial)) return;
    _wifiSetupDone.add(d.serial);
    wifiBusy = true;
    notifyListeners();
    try {
      final r = await _backend.setupWifi(d.serial);
      if (r != null && r.connected) {
        wifiNote = 'Wi-Fi connection ready, you can unplug the USB cable.';
        log('Wi-Fi ready on ${r.ip}');
        // Refresh the list: the device now also appears as its IP.
        devices = await _backend.listDevices();
      } else if (r != null && r.note != null) {
        wifiNote = r.note;
      }
    } catch (_) {
      // Quiet: USB still works.
    }
    wifiBusy = false;
    notifyListeners();
  }

  /// Retry the automatic Wi-Fi setup (Devices screen Retry button).
  Future<void> retryWifiSetup() async {
    final d = selectedDevice;
    if (d == null) return;
    _wifiSetupDone.remove(d.serial);
    wifiNote = null;
    await _maybeSetupWifi(d);
  }

  // ---- WiVRn ----
  /// Check the WiVRn first-run state for the selected headset:
  /// is the client app on it, is the server on this PC, did the
  /// user already say no. Runs once per connection; the Home card
  /// and the PC VR screen read these three fields.
  Future<void> checkWivrnSetup() async {
    // No PC VR on a phone: WiVRn is a Linux PC server, so there is
    // nothing to check and the first-run card never appears.
    if (Platform.isAndroid) return;
    final d = selectedDevice;
    if (d == null || _wivrnChecked) return;
    try {
      final st = await _backend.wivrnSetupState(d.serial);
      wivrnClientVersion = st['client_version'] as String?;
      wivrnDeclined = st['declined'] == true;
      wivrnServerInstalled = st['server_installed'] == true;
      _wivrnChecked = true;
      wivrnSetupKnown = true;
    } catch (_) {
      // Quiet: PC VR still works from its own screen. Do NOT mark
      // the check done: the next refresh retries it.
    }
    notifyListeners();
  }

  /// Shared first-run flow: install the bundled server if needed,
  /// install the client app on the headset, set up the USB link.
  /// Returns a plain message for the UI to show.
  Future<String> runWivrnSetup() async {
    final d = selectedDevice;
    if (d == null) return 'Connect a headset first.';
    try {
      if (!wivrnServerInstalled) {
        final r = await _backend.wivrnInstallServer();
        if (!r.ok) return r.message;
        wivrnServerInstalled = true;
      }
      final r = await _backend.wivrnInstallClient(d.serial);
      if (!r.ok) return r.message;
      if (d.transport == 'usb') {
        final u = await _backend.wivrnSetupUsb(d.serial);
        if (!u.ok) return u.message;
      }
      _wivrnChecked = false;
      await checkWivrnSetup();
      return 'WiVRn is ready. Open PC VR, start the server, then tap this computer in the WiVRn app on the headset.';
    } catch (e) {
      return 'WiVRn setup failed: $e';
    }
  }

  /// Remember that the user said no to WiVRn setup, so the
  /// first-run card stops appearing.
  Future<void> declineWivrn() async {
    final d = selectedDevice;
    if (d == null) return;
    try {
      await _backend.wivrnDecline(d.serial);
    } catch (_) {}
    wivrnDeclined = true;
    notifyListeners();
  }

  // ---- Health and root ----
  /// Load battery / health for the selected device.
  Future<void> loadHealth() async {
    final d = selectedDevice;
    if (d == null) return;
    try {
      health = await _backend.deviceHealth(d.serial);
    } catch (_) {
      health = null;
    }
    notifyListeners();
  }

  /// Load root / controller / update-block state for the selected
  /// device. Called by the Devices screen; cheap and read-only.
  Future<void> loadRooted() async {
    final d = selectedDevice;
    if (d == null || _rootLoading) return;
    _rootLoading = true;
    try {
      rootStatus = await _backend.rootStatus(d.serial);
      controllers = await _backend.controllers(d.serial);
      if (rootStatus?.rooted == true) {
        backupDataByDefault = true;
        updateBlock = await _backend.updateBlockStatus(d.serial);
      }
    } catch (_) {
      rootStatus = RootStatus.notRooted;
    }
    _rootLoading = false;
    notifyListeners();
  }

  /// Pick a headset, then refresh and apply the profile saved for
  /// it, if it has one.
  void selectDevice(QuestDevice d) {
    if (selectedDevice?.serial != d.serial) {
      _wivrnChecked = false;
      wivrnSetupKnown = false;
      health = null;
    }
    selectedDevice = d;
    notifyListeners();
    refreshDevices().then((_) async {
      // Apply the profile saved for this headset, if it has one.
      final saved = deviceProfiles[d.serial];
      if (saved != null && saved != activeProfile) {
        final p = profiles.where((p) => p.name == saved).firstOrNull;
        if (p != null) {
          activeProfile = p.name;
          try {
            await _backend.applyProfile(d.serial, p);
            log('Applied profile ${p.name} for ${d.model}');
          } catch (_) {}
          notifyListeners();
        }
      }
    });
  }
}
