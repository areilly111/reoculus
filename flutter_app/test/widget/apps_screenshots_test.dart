// Screenshot goldens for the README: the Apps screen rendered with
// fake (invented) data, so the GitHub page can show the app without
// a real headset and without any real user data. Nothing here is a
// real serial, IP, or firmware value.
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
import 'package:quest_companion/services/app_state.dart';
import 'package:quest_companion/services/backend.dart';
import 'package:quest_companion/theme.dart';

const _device = QuestDevice(
  serial: 'TESTSERIAL000001',
  state: 'device',
  model: 'Quest 2',
  transport: 'usb',
);

// Fake apps, all invented: same set as
// scripts/screenshot-mock-adb.sh, so the README shots and the
// (unused) live mock agree.
const _apps = <QuestApp>[
  QuestApp(package: 'com.beatgames.beatsaber', label: 'Beat Saber', version: '1.40.8', system: false, apkSizeBytes: 1280000000, totalSizeBytes: 3460000000),
  QuestApp(package: 'com.StressLevelZero.BONELAB', label: 'BONELAB', version: '1.2974.57485', system: false, apkSizeBytes: 2650000000, totalSizeBytes: 10700000000),
  QuestApp(package: 'com.Icosa.OpenBrush', label: 'Open Brush', version: '2.31.0', system: false, apkSizeBytes: 190000000, totalSizeBytes: 235000000),
  QuestApp(package: 'xyz.morrowind.tes3mpvr', label: 'TES3MP VR', version: '0.47.0', system: false, apkSizeBytes: 514000000, totalSizeBytes: 984000000),
  QuestApp(package: 'com.teambeef.questzdoom', label: 'QuestZDoom', version: '1.4.8', system: false, apkSizeBytes: 420000000, totalSizeBytes: 432000000),
  QuestApp(package: 'com.itsmattkc.questhomeswitcher', label: 'Quest Home Switcher', version: '1.2.0', system: false, apkSizeBytes: 12000000, totalSizeBytes: 20000000),
  QuestApp(package: 'com.deovr', label: 'DeoVR', version: '1.16', system: false, apkSizeBytes: 48000000, totalSizeBytes: 63000000),
];

/// Answers only the calls the Apps screen makes; anything else is
/// an error, so a screen change that needs a new backend call fails
/// loudly here instead of silently rendering an empty screen.
class FakeBackend implements BackendService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #listApps) return Future<List<QuestApp>>.value(_apps);
    if (name == #listLibrary) return Future<List<LibraryEntry>>.value(const []);
    if (name == #listDevices) return Future<List<QuestDevice>>.value(const [_device]);
    if (name == #deviceInfo) return Future<DeviceInfo?>.value(null);
    if (name == #appIcon) return Future<AppIcon?>.value(null);
    if (name == #label) return 'Fake backend';
    if (name == #scrcpyAvailable) return Future<bool>.value(false);
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
    return;
  }
}

Future<void> _pumpApps(WidgetTester tester, {bool tiles = false}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(backend: FakeBackend());
  state.selectedDevice = _device;
  state.devices = [_device];
  if (tiles) state.setAppsTiles(true);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.themeFor(DesignDirection.vrNeon),
    home: Scaffold(body: AppsScreen(state: state)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('Apps screen, list view', (WidgetTester tester) async {
    await _pumpApps(tester);
    await expectLater(find.byType(AppsScreen), matchesGoldenFile('goldens/apps-list.png'));
  });

  testWidgets('Apps screen, tiles view', (WidgetTester tester) async {
    await _pumpApps(tester, tiles: true);
    await expectLater(find.byType(AppsScreen), matchesGoldenFile('goldens/apps-tiles.png'));
  });
}
