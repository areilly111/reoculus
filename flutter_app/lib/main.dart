import 'package:flutter/material.dart';
import 'services/app_state.dart';
import 'theme.dart';
import 'screens/home_devices.dart';
import 'screens/apps_files.dart';
import 'screens/device_mirror_logs_setup.dart';
import 'screens/help.dart';
import 'screens/pc_vr.dart';

void main() {
  runApp(const QuestCompanionApp());
}

class QuestCompanionApp extends StatefulWidget {
  const QuestCompanionApp({super.key});
  @override
  State<QuestCompanionApp> createState() => _QuestCompanionAppState();
}

class _QuestCompanionAppState extends State<QuestCompanionApp> {
  final AppState _state = AppState();
  int _index = 0;

  static const _destinations = [
    (Icons.home, 'Home'),
    (Icons.headset, 'Devices'),
    (Icons.apps, 'Apps'),
    (Icons.folder, 'Files'),
    (Icons.tune, 'Device'),
    (Icons.cast, 'Mirror'),
    (Icons.view_in_ar, 'PC VR'),
    (Icons.article, 'Logs'),
    (Icons.help_outline, 'Help'),
    (Icons.settings, 'Setup'),
  ];

  @override
  void initState() {
    super.initState();
    _state.initBackend();
  }

  @override
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
            final body = _screenFor(_index);
            if (isNarrow) {
              return Scaffold(
                body: SafeArea(child: body),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: _index,
                  onTap: (i) => setState(() => _index = i),
                  type: BottomNavigationBarType.fixed,
                  items: _destinations
                      .map((d) => BottomNavigationBarItem(icon: Icon(d.$1), label: d.$2))
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
                  destinations: _destinations
                      .map((d) => NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2)))
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

  Widget _screenFor(int i) {
    switch (i) {
      case 0:
        return HomeScreen(state: _state, goTo: (n) => setState(() => _index = n));
      case 1:
        return DevicesScreen(state: _state);
      case 2:
        return AppsScreen(state: _state);
      case 3:
        return FilesScreen(state: _state);
      case 4:
        return DeviceSettingsScreen(state: _state);
      case 5:
        return MirrorScreen(state: _state);
      case 6:
        return PcVrScreen(state: _state);
      case 7:
        return LogsScreen(state: _state);
      case 8:
        return HelpScreen(state: _state);
      case 9:
        return SetupScreen(state: _state);
      default:
        return HomeScreen(state: _state, goTo: (n) => setState(() => _index = n));
    }
  }
}
