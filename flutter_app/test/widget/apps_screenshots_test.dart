// Screenshot goldens for the README: every screen rendered with
// Lorem Ipsum placeholder data, so the GitHub page can show the app
// without a real headset and without any real user data. Nothing here
// is a real serial, IP, firmware value, app, file, or log line.
// Regenerate with:
//   flutter test --update-goldens test/widget/apps_screenshots_test.dart
// The PNGs land in test/widget/goldens/; the README copies live in
// assets/screenshots/ (copy them there after regenerating).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quest_companion/models.dart';
import 'package:quest_companion/screens/apps_files.dart';
import 'package:quest_companion/screens/device_mirror_logs_setup.dart';
import 'package:quest_companion/screens/help.dart';
import 'package:quest_companion/screens/home_devices.dart';
import 'package:quest_companion/screens/pc_vr.dart';
import 'package:quest_companion/screens/singularity_wizard.dart';
import 'package:quest_companion/services/app_state.dart';
import 'package:quest_companion/services/backend.dart';
import 'package:quest_companion/theme.dart';

const _device = QuestDevice(
  serial: 'TESTSERIAL000001',
  state: 'device',
  model: 'Quest 2',
  transport: 'usb',
);

const _deviceInfo = DeviceInfo(
  model: 'Quest 2',
  serial: 'TESTSERIAL000001',
  firmware: 'Lorem ipsum 1.0.0',
  androidVersion: '14',
  resolution: '3664x1920',
  cpuAbi: 'arm64-v8a',
  batteryLevel: 87,
  batteryTempC: 31,
  storageUsedGb: 86,
  storageTotalGb: 112,
  charging: true,
);

// Fake apps, all Lorem Ipsum: the point is placeholder text, not
// pretending to be real apps.
const _apps = <QuestApp>[
  QuestApp(package: 'com.lorem.ipsum', label: 'Lorem Ipsum', version: '1.0.0', system: false, apkSizeBytes: 123456789, totalSizeBytes: 987654321),
  QuestApp(package: 'com.dolor.sit', label: 'Dolor Sit Amet', version: '2.3.1', system: false, apkSizeBytes: 234567890, totalSizeBytes: 876543210),
  QuestApp(package: 'com.consectetur.adipiscing', label: 'Consectetur Adipiscing', version: '0.9.4', system: false, apkSizeBytes: 34567890, totalSizeBytes: 123456789),
  QuestApp(package: 'com.sed.do', label: 'Sed Do Eiusmod', version: '3.1.0', system: false, apkSizeBytes: 456789012, totalSizeBytes: 765432109),
  QuestApp(package: 'com.tempor.incididunt', label: 'Tempor Incididunt', version: '1.2.3', system: false, apkSizeBytes: 56789012, totalSizeBytes: 234567890),
  QuestApp(package: 'com.ut.labore', label: 'Ut Labore Et', version: '4.0.0', system: false, apkSizeBytes: 67890123, totalSizeBytes: 345678901),
  QuestApp(package: 'com.dolore.magna', label: 'Dolore Magna Aliqua', version: '0.1.0', system: false, apkSizeBytes: 78901234, totalSizeBytes: 456789012),
];

const _files = <QuestFile>[
  QuestFile(name: 'Lorem ipsum', path: '/sdcard/Lorem ipsum', isDir: true, size: 0),
  QuestFile(name: 'Dolor sit amet', path: '/sdcard/Dolor sit amet', isDir: true, size: 0),
  QuestFile(name: 'Consectetur', path: '/sdcard/Consectetur', isDir: true, size: 0),
  QuestFile(name: 'Lorem ipsum dolor.txt', path: '/sdcard/Lorem ipsum dolor.txt', isDir: false, size: 123456),
  QuestFile(name: 'Sed do eiusmod.mp4', path: '/sdcard/Sed do eiusmod.mp4', isDir: false, size: 234567890),
  QuestFile(name: 'Ut labore.pdf', path: '/sdcard/Ut labore.pdf', isDir: false, size: 3456789),
  QuestFile(name: 'Dolore magna.png', path: '/sdcard/Dolore magna.png', isDir: false, size: 4567890),
];

const _gallery = <GalleryEntry>[
  GalleryEntry(name: 'Lorem ipsum.png', path: '/sdcard/Lorem ipsum.png', kind: 'screenshot', modified: 'Lorem ipsum', sizeBytes: 1234567),
  GalleryEntry(name: 'Dolor sit amet.mp4', path: '/sdcard/Dolor sit amet.mp4', kind: 'recording', modified: 'Dolor sit amet', sizeBytes: 234567890),
  GalleryEntry(name: 'Consectetur.mp4', path: '/sdcard/Consectetur.mp4', kind: 'recording', modified: 'Consectetur', sizeBytes: 345678901),
];

const _logLines = <String>[
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
  'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.',
  'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.',
  'Duis aute irure dolor in reprehenderit in voluptate velit esse.',
  'Excepteur sint occaecat cupidatat non proident, sunt in culpa.',
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
  'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.',
  'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.',
];

const _deviceBackups = <DeviceBackupEntry>[
  DeviceBackupEntry(serial: 'TESTSERIAL000001', backupDate: '2026-01-01 12:00', path: '/sdcard/LoremIpsum/lorem.zip', totalSizeBytes: 123456789, appCount: 7),
  DeviceBackupEntry(serial: 'TESTSERIAL000001', backupDate: '2026-01-02 12:00', path: '/sdcard/LoremIpsum/ipsum.zip', totalSizeBytes: 234567890, appCount: 7),
];

const _homes = <HomeEntry>[
  HomeEntry(component: 'com.lorem.ipsum/.HomeActivity', package: 'com.lorem.ipsum', label: 'Lorem Ipsum Home', isCurrent: true),
  HomeEntry(component: 'com.dolor.sit/.MainActivity', package: 'com.dolor.sit', label: 'Dolor Sit Amet Home', isCurrent: false),
];

const _snapshots = <SnapshotEntry>[
  SnapshotEntry(serial: 'TESTSERIAL000001', name: 'Before rooting', createdDate: '2026-01-01 12:00', path: '/sdcard/LoremIpsum/snap1', totalSizeBytes: 123456789, appCount: 7),
  SnapshotEntry(serial: 'TESTSERIAL000001', name: 'Lorem ipsum', createdDate: '2026-01-02 12:00', path: '/sdcard/LoremIpsum/snap2', totalSizeBytes: 234567890, appCount: 7),
];

const _health = HealthInfo(
  serial: 'TESTSERIAL000001',
  model: 'Quest 2',
  firmware: 'Lorem ipsum 1.0.0',
  batteryLevel: 87,
  batteryTempC: 31,
  batteryVoltageMv: 4123,
  batteryHealth: 'good',
  batteryStatus: 'discharging',
  charging: true,
  sdcardTotalKb: 117440512,
  sdcardUsedKb: 90177536,
  sdcardFreeKb: 27262976,
  dataTotalKb: 117440512,
  dataUsedKb: 41943040,
  dataFreeKb: 75563072,
  uptime: '1 day 2 hours',
  lastBackup: '2026-01-01 12:00',
);

/// Answers the calls the screens make at load; anything else is an
/// error, so a screen change that needs a new backend call fails
/// loudly here instead of silently rendering an empty screen.
class FakeBackend implements BackendService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #listApps) return Future<List<QuestApp>>.value(_apps);
    if (name == #listLibrary) return Future<List<LibraryEntry>>.value(const []);
    if (name == #listDevices) return Future<List<QuestDevice>>.value(const [_device]);
    if (name == #deviceInfo) return Future<DeviceInfo?>.value(_deviceInfo);
    if (name == #appIcon) return Future<AppIcon?>.value(null);
    if (name == #label) return 'Fake backend';
    if (name == #scrcpyAvailable) return Future<bool>.value(false);
    if (name == #listFiles) return Future<List<QuestFile>>.value(_files);
    if (name == #listGallery) return Future<List<GalleryEntry>>.value(_gallery);
    if (name == #logLines) return Future<List<String>>.value(_logLines);
    if (name == #rootStatus) {
      return Future<RootStatus>.value(const RootStatus(
        rooted: true, method: 'Magisk', suPresent: true, magiskPresent: true, singularityPresent: false));
    }
    if (name == #controllers) {
      return Future<ControllersInfo>.value(const ControllersInfo(
        names: ['Lorem Controller', 'Ipsum Controller'],
        note: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit.'));
    }
    if (name == #updateBlockStatus) {
      return Future<UpdateBlockStatus?>.value(const UpdateBlockStatus(
        blocked: false, rooted: true, disabledPackages: []));
    }
    if (name == #listDeviceBackups) return Future<List<DeviceBackupEntry>>.value(_deviceBackups);
    if (name == #homesList) return Future<List<HomeEntry>>.value(_homes);
    if (name == #homesCurrent) return Future<String?>.value('com.lorem.ipsum/.HomeActivity');
    if (name == #homesSet) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Home switched.'));
    if (name == #homesOpenSettings) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Home settings are open on the headset.'));
    if (name == #snapshotList) return Future<List<SnapshotEntry>>.value(_snapshots);
    if (name == #snapshotCreate) return Future<Map<String, dynamic>?>.value({'ok': true, 'name': 'Lorem ipsum'});
    if (name == #snapshotRestore) {
      return Future<RestoreReport?>.value(const RestoreReport(
        package: 'com.lorem.ipsum', backupPath: '/sdcard/LoremIpsum/snap1', dryRun: true, ready: true,
        steps: [StepResult(item: 'Lorem ipsum', message: 'dolor sit amet', ok: true)],
      ));
    }
    if (name == #snapshotDelete) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Deleted.'));
    if (name == #deviceHealth) return Future<HealthInfo?>.value(_health);
    if (name == #singularityPreflight) {
      return Future<SingularityPreflight?>.value(const SingularityPreflight(
        ready: true, summary: 'Lorem ipsum dolor sit amet.',
        checks: [
          PreflightCheck(name: 'Lorem ipsum', detail: 'dolor sit amet', ok: true),
          PreflightCheck(name: 'Consectetur adipiscing', detail: 'sed do eiusmod', ok: true),
        ],
      ));
    }
    if (name == #singularityDownload) {
      return Future<Map<String, dynamic>>.value({
        'ok': true, 'version': '1.0.8', 'file': '/tmp/Singularity.apk', 'size_bytes': 12345678,
        'sha256': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'package': 'com.lorem.singularity', 'label': 'Lorem Ipsum',
        'verification': 'Lorem ipsum dolor sit amet.',
      });
    }
    if (name == #singularityInstall) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Singularity installed on the headset.'));
    if (name == #singularityVerify) {
      return Future<RootStatus>.value(const RootStatus(
        rooted: true, method: 'Magisk', suPresent: true, magiskPresent: true, singularityPresent: true));
    }
    if (name == #singularityDownloads) {
      return Future<List<SingularityDownload>>.value(const [
        SingularityDownload(id: 'singularity', name: 'Singularity', detail: 'Lorem ipsum dolor sit amet.', source: 'Lorem ipsum', version: '1.0.8', onHeadset: 'installed 1.0.8', downloadable: true, downloaded: true, sizeBytes: 12345678, sha256: '0123456789abcdef0123456789abcdef'),
        SingularityDownload(id: 'frida', name: 'Frida server', detail: 'Lorem ipsum dolor sit amet.', source: 'Lorem ipsum', version: '17.17.0', onHeadset: 'not on headset', downloadable: true, downloaded: true, sizeBytes: 53539200, sha256: '0123456789abcdef0123456789abcdef'),
        SingularityDownload(id: 'hosts', name: 'Meta domain blocklist', detail: 'Lorem ipsum dolor sit amet.', source: 'Lorem ipsum', version: '74 domains', onHeadset: 'not applied', downloadable: true, downloaded: true, sizeBytes: 2305, sha256: '0123456789abcdef0123456789abcdef'),
        SingularityDownload(id: 'freexr', name: 'FreeXR safe-root-things', detail: 'Lorem ipsum dolor sit amet.', source: 'Lorem ipsum', version: 'no release', onHeadset: 'not checked', downloadable: false, downloaded: false, sizeBytes: 0),
      ]);
    }
    if (name == #singularityDownloadFrida) {
      return Future<Map<String, dynamic>>.value({'ok': true, 'version': '17.17.0', 'file': '/tmp/frida-server', 'size_bytes': 53539200, 'sha256': '0123456789abcdef0123456789abcdef'});
    }
    if (name == #singularityDownloadHosts) {
      return Future<Map<String, dynamic>>.value({'ok': true, 'file': '/tmp/hosts', 'domains': 74, 'sha256': '0123456789abcdef0123456789abcdef'});
    }
    if (name == #fridaStatus || name == #fridaPush || name == #fridaStart || name == #fridaStop) {
      return Future<FridaStatusInfo>.value(const FridaStatusInfo(downloaded: true, pushed: false, running: false, sizeBytes: 53539200));
    }
    if (name == #hostsStatus || name == #hostsApply || name == #hostsRemove) {
      return Future<HostsStatusInfo>.value(const HostsStatusInfo(downloaded: true, applied: false, domains: 74, sizeBytes: 2305, systemLines: 2, moduleDomains: 0));
    }
    if (name == #otaStatus || name == #otaSet) {
      return Future<OtaStatusInfo>.value(const OtaStatusInfo(blocked: true, updaterDisabled: true));
    }
    if (name == #uxpList) {
      return Future<List<UxpSetting>>.value(const [
        UxpSetting(key: 'uxpatcher_battery_percent', label: 'Battery percent in the dock', detail: 'Lorem ipsum dolor sit amet.', value: '1', isToggle: true, enabled: true),
        UxpSetting(key: 'uxpatcher_hide_passthrough', label: 'Hide the passthrough button', detail: 'Lorem ipsum dolor sit amet.', value: '0', isToggle: true, enabled: false),
        UxpSetting(key: 'uxpatcher_dock_order', label: 'Dock button order', detail: 'Lorem ipsum dolor sit amet.', value: 'profile,qs,notif,pt', isToggle: false, enabled: false),
      ]);
    }
    if (name == #uxpSet) {
      return Future<UxpSetting?>.value(const UxpSetting(key: 'uxpatcher_battery_percent', label: 'Battery percent in the dock', detail: 'Lorem ipsum dolor sit amet.', value: '1', isToggle: true, enabled: true));
    }
    if (name == #restartHome) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'The home screen was restarted.'));
    if (name == #analyzeApk) {
      return Future<ApkAnalysis?>.value(const ApkAnalysis(
        path: '/tmp/lorem.apk', file: 'lorem.apk', fileSizeBytes: 123456789,
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        package: 'com.lorem.ipsum', label: 'Lorem Ipsum', versionName: '1.0.0', versionCode: 1,
        minSdk: 29, targetSdk: 33,
        permissions: ['android.permission.INTERNET'], features: ['android.hardware.vr.headtracking'],
        abis: ['arm64-v8a'], is64Bit: true, signatureChecked: true,
        nativeLibBytes: 12345678, nativeLibCount: 3, dexBytes: 12345678, assetsBytes: 1234567, resBytes: 1234567,
        signatureSha256: 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
        notes: ['Lorem ipsum dolor sit amet.'],
      ));
    }
    if (name == #wivrnDecline) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Noted.'));
    if (name == #wivrnUndecline) return Future<BackendResult>.value(const BackendResult(ok: true, message: 'Decline cleared.'));
    if (name == #wivrnSetupState) {
      return Future<Map<String, dynamic>>.value({
        'client_version': '26.9', 'declined': false, 'server_installed': true,
      });
    }
    if (name == #wivrnDetect) {
      return Future<Map<String, dynamic>>.value({
        'installed': true, 'kind': 'flatpak', 'server_version': '26.9',
        'avahi_active': true, 'pipewire': true, 'port': 9757,
        'note': 'Lorem ipsum dolor sit amet.',
      });
    }
    if (name == #wivrnStatus) {
      return Future<Map<String, dynamic>>.value({
        'running': true, 'port_listening': true, 'active_runtime_is_wivrn': true,
        'pipewire_nodes': true,
        'log': 'Lorem ipsum dolor sit amet, consectetur adipiscing elit.\nSed do eiusmod tempor incididunt.',
      });
    }
    if (name == #wivrnHeadsetClient) return Future<String?>.value('26.9');
    if (name == #setupWifi) return Future<WifiSetupResult?>.value(null);
    if (name == #wifiReconnect) return Future<List<String>>.value(const []);
    if (name == #debugInfo) {
      return Future<DebugInfo?>.value(const DebugInfo(
        questctlVersion: 'Lorem ipsum',
        adbVersion: 'Lorem ipsum',
        backendPath: 'Fake backend',
        scrcpyAvailable: false,
        root: RootStatus(rooted: true, method: 'Magisk', suPresent: true, magiskPresent: true, singularityPresent: false),
        device: _deviceInfo,
      ));
    }
    return super.noSuchMethod(invocation);
  }
}

/// Golden tests render text with a block font unless the real fonts
/// are loaded, and icons as empty squares unless the icon font is
/// loaded. Load Roboto and MaterialIcons from the Flutter SDK so
/// the screenshots read like the real app. Tries the usual SDK
/// homes; if none is found the test still runs, just with block
/// text and square icons.
Future<void> _loadFonts() async {
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null) Platform.environment['FLUTTER_ROOT']!,
    '$home/workspace/flutter-sdk',
    '$home/flutter-sdk',
  ];
  for (final root in candidates) {
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (!dir.existsSync()) continue;
    for (final entry in {'Roboto-Regular.ttf': 400, 'Roboto-Medium.ttf': 500, 'Roboto-Bold.ttf': 700}.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
      await loader.load();
    }
    final iconsFile = File('${dir.path}/MaterialIcons-Regular.otf');
    if (iconsFile.existsSync()) {
      final bytes = await iconsFile.readAsBytes();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
      await loader.load();
    }
    // The Logs/Terminal screens use fontFamily 'monospace'. Without a
    // monospace font loaded the log lines render as solid blocks.
    // DejaVu Sans Mono ships with the system fonts.
    final monoFile = File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
    if (monoFile.existsSync()) {
      final bytes = await monoFile.readAsBytes();
      final loader = FontLoader('monospace')
        ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
      await loader.load();
    }
    return;
  }
}

Future<void> _pump(WidgetTester tester, AppState state, Widget screen) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeFor(DesignDirection.vrNeon),
    home: Scaffold(body: screen),
  ));
  await tester.pumpAndSettle();
}

AppState _state() {
  final state = AppState(backend: FakeBackend());
  state.selectedDevice = _device;
  state.devices = [_device];
  // Normally refreshDevices fills this in from the backend; the
  // golden pumps set the device directly, so set it here too.
  state.deviceInfo = _deviceInfo;
  state.log('Lorem ipsum dolor sit amet');
  state.log('Dolor sit amet, consectetur');
  state.log('Sed do eiusmod tempor');
  return state;
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('Home screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, HomeScreen(state: state, goTo: (_) {}));
    await expectLater(find.byType(HomeScreen), matchesGoldenFile('goldens/home.png'));
  });

  testWidgets('Devices screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, DevicesScreen(state: state));
    await expectLater(find.byType(DevicesScreen), matchesGoldenFile('goldens/devices.png'));
  });

  testWidgets('Apps screen, list view', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, AppsScreen(state: state));
    await expectLater(find.byType(AppsScreen), matchesGoldenFile('goldens/apps-list.png'));
  });

  testWidgets('Apps screen, tiles view', (WidgetTester tester) async {
    final state = _state();
    state.setAppsTiles(true);
    await _pump(tester, state, AppsScreen(state: state));
    await expectLater(find.byType(AppsScreen), matchesGoldenFile('goldens/apps-tiles.png'));
  });

  testWidgets('Files screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, FilesScreen(state: state));
    await expectLater(find.byType(FilesScreen), matchesGoldenFile('goldens/files.png'));
  });

  testWidgets('Device and Settings screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, DeviceSettingsScreen(state: state));
    await expectLater(find.byType(DeviceSettingsScreen), matchesGoldenFile('goldens/device-settings.png'));
  });

  testWidgets('Mirror screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, MirrorScreen(state: state));
    await expectLater(find.byType(MirrorScreen), matchesGoldenFile('goldens/mirror.png'));
  });

  testWidgets('PC VR screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, PcVrScreen(state: state));
    await expectLater(find.byType(PcVrScreen), matchesGoldenFile('goldens/pc-vr.png'));
  });

  testWidgets('Logs screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, LogsScreen(state: state));
    await expectLater(find.byType(LogsScreen), matchesGoldenFile('goldens/logs.png'));
  });

  testWidgets('Help screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, HelpScreen(state: state));
    await expectLater(find.byType(HelpScreen), matchesGoldenFile('goldens/help.png'));
  });

  testWidgets('Setup screen', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, SetupScreen(state: state));
    await expectLater(find.byType(SetupScreen), matchesGoldenFile('goldens/setup.png'));
  });

  testWidgets('Singularity wizard', (WidgetTester tester) async {
    final state = _state();
    await _pump(tester, state, SingularityWizardScreen(state: state));
    await expectLater(find.byType(SingularityWizardScreen), matchesGoldenFile('goldens/singularity-wizard.png'));
  });
}
