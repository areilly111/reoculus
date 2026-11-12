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
  BackendService _backend = RealBackend('../backend/target/debug/questctl');
  String? backendPath; // null = auto-detect
  String? backendError; // set when Real mode cannot find/run questctl
  // PICKED 2026-11-12: C Dark VR Neon, blue instead of purple .
  DesignDirection design = DesignDirection.vrNeon;
  QuestDevice? selectedDevice;
  List<QuestDevice> devices = [];
  DeviceInfo? deviceInfo;
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
  String activeProfile = 'Balanced';

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

  void log(String entry) {
    activity.insert(0, entry);
    if (activity.length > 40) activity.removeLast();
    notifyListeners();
  }

  /// Find questctl (custom path from Setup, else the defaults) and
  /// use it. When it cannot be found, backendError is set and the UI
  /// shows an error state; nothing falls back to sample data.
  /// On Android there is no questctl binary to spawn yet (the Android
  /// Wi-Fi transport is being built; see flutter_app/README.md):
  /// say that plainly instead of the Linux build instructions.
  Future<void> initBackend({String? path}) async {
    if (Platform.isAndroid) {
      backendError =
          'The Android app cannot reach a headset yet. The Wi-Fi transport that talks to the Quest over Wi-Fi is being built; until then, use the Linux app on a PC. Everything offline in this app (Help, Setup) still works.';
      notifyListeners();
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
    notifyListeners();
    await refreshDevices();
  }

  /// Point the app at a different questctl path (from Setup).
  Future<void> setBackendPath(String path) async {
    await initBackend(path: path.trim().isEmpty ? null : path.trim());
  }

  void setDesign(DesignDirection d) {
    design = d;
    notifyListeners();
  }

  /// Rooted: include app data (/data/data) in app backups.
  /// On automatically when root is detected, no setting to change.
  bool backupDataByDefault = false;
  void setBackupDataByDefault(bool v) {
    backupDataByDefault = v;
    notifyListeners();
  }

  /// Apps view: false = list (default), true = tiles (grid).
  /// Swap with the List / Tiles toggle on the Apps screen.
  bool appsTiles = false;
  void setAppsTiles(bool tiles) {
    appsTiles = tiles;
    notifyListeners();
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

  Future<void> refreshDevices() async {
    try {
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
        await checkWivrnSetup();
        rootStatus = null;
        controllers = null;
        updateBlock = null;
        await _maybeSetupWifi(selectedDevice!);
      } else {
        deviceInfo = null;
      }
    } catch (e) {
      devices = [];
      deviceInfo = null;
    }
    notifyListeners();
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

  /// Check the WiVRn first-run state for the selected headset:
  /// is the client app on it, is the server on this PC, did the
  /// user already say no. Runs once per connection; the Home card
  /// and the PC VR screen read these three fields.
  Future<void> checkWivrnSetup() async {
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

  Future<void> declineWivrn() async {
    try {
      await _backend.wivrnDecline();
    } catch (_) {}
    wivrnDeclined = true;
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

  void selectDevice(QuestDevice d) {
    if (selectedDevice?.serial != d.serial) {
      _wivrnChecked = false;
      wivrnSetupKnown = false;
    }
    selectedDevice = d;
    notifyListeners();
    refreshDevices();
  }
}
