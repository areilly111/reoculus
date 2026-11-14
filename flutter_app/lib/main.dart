// ReOculus entry point: builds the app shell, the navigation rail
// (or bottom bar on phones), and picks which screen to show.
// All headset state lives in AppState; this file only wires it up.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'services/app_state.dart';
import 'theme.dart';
import 'screens/home_devices.dart';
import 'screens/apps_files.dart';
import 'screens/device_mirror_logs_setup.dart';
import 'screens/help.dart';
import 'screens/pc_vr.dart';

/// Start the app.
void main() {
  runApp(const QuestCompanionApp());
}

/// The app widget. Owns the one AppState every screen shares.
class QuestCompanionApp extends StatefulWidget {
  const QuestCompanionApp({super.key});
  @override
  State<QuestCompanionApp> createState() => _QuestCompanionAppState();
}

class _QuestCompanionAppState extends State<QuestCompanionApp> {
  final AppState _state = AppState();
  int _index = 0;

  // Screen ids. Stable across platforms: the visible nav on Android
  // drops PC VR (a phone cannot host VR streaming), so visible
  // positions shift but the ids never do. HomeScreen's goTo takes an
  // id, not a position, so its quick actions keep working on both.
  // Id 1 was Devices; it was folded into Home in 0.2.26 (the
  // Headsets list), so 1 stays unused rather than renumbering.
  static const _home = 0;
  static const _apps = 2;
  static const _files = 3;
  static const _device = 4;
  static const _mirror = 5;
  static const _pcvr = 6;
  static const _logs = 7;
  static const _help = 8;
  static const _setup = 9;

  static const _allDestinations = [
    (_home, Icons.home, 'Home'),
    (_apps, Icons.apps, 'Apps'),
    (_files, Icons.folder, 'Files'),
    (_device, Icons.tune, 'Device'),
    (_mirror, Icons.cast, 'Mirror'),
    (_pcvr, Icons.view_in_ar, 'PC VR'),
    (_logs, Icons.article, 'Logs'),
    (_help, Icons.help_outline, 'Help'),
    (_setup, Icons.settings, 'Setup'),
  ];

  /// The nav entries shown on this platform. Android drops PC VR:
  /// no phone can host a VR game for a Quest (the research in
  /// research_notes/phone-to-quest-vr-streaming-20261113/ found no
  /// shipping phone-as-host streamer; the one demo needs a rooted
  /// phone two generations newer than an S23 Ultra). The PC VR
  /// screen code stays for Linux; it is just not reachable here.
  List<(int, IconData, String)> get _destinations =>
      _allDestinations.where((d) => d.$1 != _pcvr || !Platform.isAndroid).toList();

  /// Visible nav position for a screen id, or -1 when hidden.
  int _positionFor(int id) => _destinations.indexWhere((d) => d.$1 == id);

  /// Show the screen with this id. Ids never move, even when Android
  /// hides PC VR, so quick actions keep working on both platforms.
  void _goTo(int id) {
    final i = _positionFor(id);
    if (i >= 0) setState(() => _index = i);
  }

  @override
  /// Find questctl and list headsets as soon as the app opens.
  void initState() {
    super.initState();
    _state.initBackend();
  }

  @override
  /// App shell: theme, navigation rail or bottom bar, and the current screen.
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => MaterialApp(
        title: 'ReOculus',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(_state.design),
        home: LayoutBuilder(
          builder: (context, constraints) {
            // Phones (Android companion) get a bottom bar; wide
            // screens keep the desktop navigation rail. Same screens,
            // same features, no shrunken desktop layout.
            final isNarrow = constraints.maxWidth < 700;
            final destinations = _destinations;
            final body = _screenFor(destinations[_index].$1);
            if (isNarrow) {
              return Scaffold(
                body: SafeArea(child: body),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: _index,
                  onTap: (i) => setState(() => _index = i),
                  type: BottomNavigationBarType.fixed,
                  items: destinations
                      .map((d) => BottomNavigationBarItem(icon: Icon(d.$2), label: d.$3))
                      .toList(),
                ),
              );
            }
            return Scaffold(
              body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: destinations
                      .map((d) => NavigationRailDestination(icon: Icon(d.$2), label: Text(d.$3)))
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ]),
            );
          },
        ),
      ),
    );
  }

  /// The screen widget for one navigation id. Unknown ids fall back
  /// to Home.
  Widget _screenFor(int id) {
    switch (id) {
      case _home:
        return HomeScreen(state: _state, goTo: _goTo);
      case _apps:
        return AppsScreen(state: _state);
      case _files:
        return FilesScreen(state: _state);
      case _device:
        return DeviceSettingsScreen(state: _state);
      case _mirror:
        return MirrorScreen(state: _state);
      case _pcvr:
        return PcVrScreen(state: _state);
      case _logs:
        return LogsScreen(state: _state);
      case _help:
        return HelpScreen(state: _state);
      case _setup:
        return SetupScreen(state: _state);
      default:
        return HomeScreen(state: _state, goTo: _goTo);
    }
  }
}
