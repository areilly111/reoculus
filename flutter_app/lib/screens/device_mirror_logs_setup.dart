// Device, Mirror, Logs, and Setup screens.
// Device and Settings: safe, dangerous, and rooted headset settings,
// backups, snapshots, home launchers, and headset health. Mirror: the
// scrcpy screen mirror with quality and recording. Logs: app logs,
// headset logcat, terminal, and debug info. Setup: first-run checklist,
// storage locations, and the Support Countdown.
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'singularity_wizard.dart';

// ---- Device & Settings ----------------------------------------------------
// Safe settings on top (all changeable over adb, reversible, and
// explained in plain words). Dangerous settings live in a closed
// collapsible section. Rooted settings live in their own closed
// collapsible section, only shown when root is detected.
/// Device and Settings screen: headset info, safe settings, backups,
/// home launchers, health, plus the closed Dangerous and Rooted sections.
class DeviceSettingsScreen extends StatefulWidget {
  final AppState state;
  const DeviceSettingsScreen({required this.state, super.key});
  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  int _refresh = 90;
  int _cpu = 2;
  int _gpu = 2;
  bool _guardianPaused = false;
  double _brightness = 0.7;
  bool _autoBrightness = false;
  int _texture = 0; // 0 = default, else square texture size
  // 30 seconds, the default screen timeout.
  int _timeout = 30000;
  bool _stayAwake = false;
  bool _fullRate = false;
  bool _experimental = false;
  bool _scaling = false;
  final _customKey = TextEditingController();
  final _customValue = TextEditingController();
  final _snapshotName = TextEditingController();
  List<DeviceBackupEntry> _deviceBackups = [];
  List<HomeEntry> _homes = [];
  List<SnapshotEntry> _snapshots = [];
  HealthInfo? _health;
  BatteryHistory? _batteryHistory;
  bool _healthLoading = false;
  List<SingularityDownload> _downloads = [];
  OtaStatusInfo? _ota;
  List<UxpSetting> _uxp = [];
  bool _singExtrasLoading = false;
  List<HomeAppStatus> _homeApps = [];
  bool _homeAppsLoading = false;

  @override
  /// Loads root status, health, device backups, homes, snapshots,
  /// Singularity extras, and home apps when the screen opens.
  void initState() {
    super.initState();
    widget.state.loadRooted();
    widget.state.loadHealth();
    _loadDeviceBackups();
    _loadHomes();
    _loadSnapshots();
    _loadSingularityExtras();
    _loadHomeApps();
  }

  /// Reloads the device backups stored on this computer.
  Future<void> _loadDeviceBackups() async {
    _deviceBackups = await widget.state.backend.listDeviceBackups();
    if (mounted) setState(() {});
  }

  /// Reloads the installed home launchers from the headset. Fails soft:
  /// an empty list when the headset does not answer.
  Future<void> _loadHomes() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    try {
      _homes = await widget.state.backend.homesList(serial);
    } catch (_) {
      _homes = [];
    }
    if (mounted) setState(() {});
  }

  /// Reloads the headset snapshots stored on this computer. Fails soft.
  Future<void> _loadSnapshots() async {
    try {
      _snapshots = await widget.state.backend.snapshotList();
    } catch (_) {
      _snapshots = [];
    }
    if (mounted) setState(() {});
  }

  /// Reloads battery, storage, uptime, and battery history from the
  /// headset. Fails soft, one missing answer does not hide the other.
  Future<void> _loadHealth() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _healthLoading = true);
    try {
      _health = await widget.state.backend.deviceHealth(serial);
    } catch (_) {
      _health = null;
    }
    try {
      _batteryHistory = await widget.state.backend.batteryHistory(serial);
    } catch (_) {
      _batteryHistory = null;
    }
    if (mounted) setState(() => _healthLoading = false);
  }

  /// Formats a Unix timestamp as "Jan 5, 3:04 PM" in local time.
  String _formatDayTime(int unixSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '${months[d.month - 1]} ${d.day}, $hour:${d.minute.toString().padLeft(2, '0')} $ampm';
  }

  /// Formats milliseconds of app use as "45 min" or "2 h 15 min".
  String _formatUseTime(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }

  /// The app shows the last part of the package id as the name
  /// (the same fallback the Apps screen uses when an app has no
  /// launcher label on file).
  String _shortName(String package) {
    final last = package.split('.').last;
    return last.isEmpty ? package : last;
  }

  /// Singularity downloads, update blocker, and dock settings for
  /// the Rooted section. Each call fails soft, so one missing
  /// answer never hides the rest.
  Future<void> _loadSingularityExtras() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _singExtrasLoading = true);
    try {
      _downloads = await widget.state.backend.singularityDownloads(serial);
    } catch (_) {
      _downloads = [];
    }
    try {
      _ota = await widget.state.backend.otaStatus(serial);
    } catch (_) {
      _ota = null;
    }
    try {
      _uxp = await widget.state.backend.uxpList(serial);
    } catch (_) {
      _uxp = [];
    }
    if (mounted) setState(() => _singExtrasLoading = false);
  }

  /// Home apps (Lightning Launcher + Quest Home Switcher): scan the
  /// headset for what is installed and whether an update is out.
  Future<void> _loadHomeApps() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _homeAppsLoading = true);
    try {
      _homeApps = await widget.state.backend.homeAppsList(serial);
    } catch (_) {
      _homeApps = [];
    }
    if (mounted) setState(() => _homeAppsLoading = false);
  }

  /// Friendly name for a launcher. The headset reports Lightning
  /// Launcher with the plain label "launcher", so map the known
  /// packages to their real names instead of showing that.
  String _homeDisplayName(HomeEntry h) {
    if (h.package == 'com.threethan.launcher') return 'Lightning Launcher';
    if (h.package == 'com.itsmattkc.questhomeswitcher') return 'Quest Home Switcher';
    if (h.label.isEmpty) return h.package;
    return h.label[0].toUpperCase() + h.label.substring(1);
  }

  /// One home app row (Lightning Launcher or Quest Home Switcher) with
  /// Download, Install/Update, Open, and Uninstall.
  Widget _homeAppRow(HomeAppStatus a) {
    final serial = widget.state.selectedDevice?.serial;
    Future<void> reload() async => _loadHomeApps();
    final status = a.installed
        ? 'On headset: ${a.installedVersion ?? 'installed'}${a.updateAvailable ? '  •  Update available: ${a.latestVersion ?? ''}' : '  •  Up to date'}'
        : 'Not on headset. Latest: ${a.latestVersion ?? 'unknown'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(a.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(a.detail, style: const TextStyle(fontSize: 13)),
        Text(status, style: const TextStyle(fontSize: 13)),
        if (a.downloaded && a.sha256 != null)
          Text('Downloaded here: ${formatBytes(a.sizeBytes)}  •  SHA-256: ${a.sha256!.substring(0, 12)}…', style: const TextStyle(fontSize: 13)),
        Text('Source: ${a.source}', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(
            onPressed: () async {
              final d = await widget.state.backend.homeAppDownload(a.id);
              if (mounted) showResult(context, d['ok'] == true, d['ok'] == true ? 'Downloaded ${a.name} ${d['version'] ?? ''} (${formatBytes(d['size_bytes'] ?? 0)}).' : (d['error'] ?? 'Download failed.').toString());
              await reload();
            },
            child: const Text('Download'),
          ),
          FilledButton(
            onPressed: serial == null
                ? null
                : () async {
                    final r = await widget.state.backend.homeAppInstall(serial, a.id);
                    if (mounted) showResult(context, r.ok, r.message);
                    await reload();
                    await _loadHomes();
                  },
            child: Text(a.installed ? 'Update' : 'Install'),
          ),
          if (a.installed)
            OutlinedButton(
              onPressed: serial == null
                  ? null
                  : () async {
                      final r = await widget.state.backend.homeAppOpen(serial, a.id);
                      if (mounted) showResult(context, r.ok, r.message);
                    },
              child: const Text('Open'),
            ),
          if (a.installed)
            OutlinedButton(
              onPressed: serial == null
                  ? null
                  : () async {
                      final yes = await confirmDialog(context, title: 'Uninstall ${a.name}?', body: 'This removes ${a.name} from the headset. Its settings on the headset are removed too.', confirmLabel: 'Uninstall', destructive: true);
                      if (!yes) return;
                      final r = await widget.state.backend.homeAppUninstall(serial, a.id);
                      if (mounted) showResult(context, r.ok, r.message);
                      await reload();
                      await _loadHomes();
                    },
              child: const Text('Uninstall'),
            ),
        ]),
      ]),
    );
  }

  /// One section as a card in the two-column grid: a title row
  /// (with the small "i" when the section needs explaining), an
  /// optional subtitle, and the section's content.
  Widget _sectionCard({required String title, String? subtitle, String? infoTitle, String? infoBody, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            if (infoTitle != null && infoBody != null) InfoButton(infoTitle, infoBody),
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }

  /// A category header above a group of related cards, so the
  /// page reads as sections (Display and speed, Backups, Home,
  /// Health) instead of one long mixed list.
  Widget _categoryHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      );

  /// One labelled row in the About card: the label on the left in a
  /// muted tone, the value on the right. Long values wrap instead of
  /// overflowing.
  Widget _aboutRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color)),
          ),
          Expanded(child: Text(value)),
        ]),
      );

  /// A small subheading inside the About card (Headset, Display,
  /// Battery, ...). The first one sits right under the card title.
  Widget _aboutSection(String title) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  /// One Singularity download row (Singularity, Frida, or the hosts
  /// blocklist) with the right buttons for it: Download, Install or Push,
  /// and Start/Stop or Apply/Remove. Buttons are disabled until the file
  /// is downloaded and a headset is connected.
  Widget _downloadRow(SingularityDownload d) {
    final serial = widget.state.selectedDevice?.serial;
    final buttons = <Widget>[];
    Future<void> reload() async {
      await _loadSingularityExtras();
    }
    if (d.id == 'singularity') {
      buttons.add(FilledButton(
        onPressed: serial == null ? null : () async {
          final r = await widget.state.backend.singularityDownload();
          if (mounted) showResult(context, r['ok'] == true, r['ok'] == true ? 'Singularity ${(r['version'] ?? '').toString()} downloaded.' : (r['error'] ?? 'Download failed.').toString());
          await reload();
        },
        child: const Text('Download'),
      ));
      buttons.add(OutlinedButton(
        onPressed: (serial == null || !d.downloaded) ? null : () async {
          final r = await widget.state.backend.singularityInstall(serial);
          if (mounted) showResult(context, r.ok, r.ok ? 'Singularity installed. Open it on the headset and press Root Now.' : r.message);
          await reload();
        },
        child: const Text('Install'),
      ));
    } else if (d.id == 'frida') {
      buttons.add(FilledButton(
        onPressed: serial == null ? null : () async {
          final r = await widget.state.backend.singularityDownloadFrida();
          if (mounted) showResult(context, r['ok'] == true, r['ok'] == true ? 'Frida server ${(r['version'] ?? '').toString()} downloaded.' : (r['error'] ?? 'Download failed.').toString());
          await reload();
        },
        child: const Text('Download'),
      ));
      buttons.add(OutlinedButton(
        onPressed: (serial == null || !d.downloaded) ? null : () async {
          final st = await widget.state.backend.fridaPush(serial);
          if (mounted) showResult(context, st.pushed, st.pushed ? 'Frida server is on the headset.' : 'Push failed.');
          await reload();
        },
        child: const Text('Push to headset'),
      ));
      if (d.onHeadset.contains('running')) {
        buttons.add(OutlinedButton(
          onPressed: serial == null ? null : () async {
            await widget.state.backend.fridaStop(serial);
            await reload();
          },
          child: const Text('Stop'),
        ));
      } else {
        buttons.add(OutlinedButton(
          onPressed: (serial == null || !d.onHeadset.startsWith('on headset')) ? null : () async {
            final st = await widget.state.backend.fridaStart(serial);
            if (mounted) showResult(context, st.running, st.running ? 'Frida server is running.' : 'Frida did not start.');
            await reload();
          },
          child: const Text('Start'),
        ));
      }
    } else if (d.id == 'hosts') {
      buttons.add(FilledButton(
        onPressed: serial == null ? null : () async {
          final r = await widget.state.backend.singularityDownloadHosts();
          if (mounted) showResult(context, r['ok'] == true, r['ok'] == true ? 'Blocklist downloaded (${(r['domains'] ?? 0).toString()} domains).' : (r['error'] ?? 'Download failed.').toString());
          await reload();
        },
        child: const Text('Download'),
      ));
      if (d.onHeadset.startsWith('applied')) {
        buttons.add(OutlinedButton(
          onPressed: serial == null ? null : () async {
            await widget.state.backend.hostsRemove(serial);
            if (mounted) showResult(context, true, 'Blocklist removed. It stops applying after the next reboot.');
            await reload();
          },
          child: const Text('Remove blocker'),
        ));
      } else {
        buttons.add(OutlinedButton(
          onPressed: (serial == null || !d.downloaded) ? null : () async {
            final st = await widget.state.backend.hostsApply(serial);
            if (mounted) showResult(context, st.applied, st.applied ? 'Blocklist applied (${st.moduleDomains} domains). It takes effect after a reboot.' : 'Could not apply the blocklist.');
            await reload();
          },
          child: const Text('Apply blocker'),
        ));
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${d.name} (${d.version})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(d.detail, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          Text('On headset: ${d.onHeadset}. Source: ${d.source}', style: const TextStyle(fontSize: 13)),
          if (d.downloaded && d.sha256 != null) Text('SHA-256: ${d.sha256!.substring(0, 16)}...', style: const TextStyle(fontSize: 13)),
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: buttons),
          ],
        ]),
      ),
    );
  }

  /// Writes one setting to the headset by key, then shows the
  /// plain-language result.
  Future<void> _apply(String key, String value, String plain) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final r = await widget.state.backend.setSetting(serial, key, value);
    if (mounted) showResult(context, r.ok, r.ok ? plain : r.message);
  }

  /// Refresh rates this headset supports: Quest 1 caps at 72 Hz,
  /// Quest 2 at 120 Hz, Quest 3 and later up to 207 Hz.
  List<int> get _refreshRates {
    final info = widget.state.deviceInfo;
    if (info?.isQuest1 == true) return [60, 72];
    final model = info?.model ?? '';
    if (model.toLowerCase().contains('quest 2')) return [60, 72, 80, 90, 96, 120];
    return [60, 72, 80, 90, 96, 120, 144, 180, 207];
  }

  @override
  /// Builds the whole Device and Settings page: About, Display and
  /// speed, Backups, Home, Health, Rooted, and Dangerous sections.
  Widget build(BuildContext context) {
    final s = widget.state;
    final info = s.deviceInfo;
    final rooted = s.rootStatus?.rooted == true;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Device and settings', style: Theme.of(context).textTheme.headlineSmall),
          Text(info?.isQuest1 == true ? 'Safe settings are at the top. Anything that can break the headset is in the closed Dangerous section below. There are no rooted settings on a Quest 1: Singularity only supports Quest 2, Pro, 3, and 3S. Most of these settings reset when the headset restarts. Your saved profile is applied again each time you connect.' : 'Safe settings are at the top. Anything that can break the headset is in the closed Dangerous section below. Rooted settings are in their own closed section, and only show up when this headset is rooted. Most of these settings reset when the headset restarts. Your saved profile is applied again each time you connect.'),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: info == null
                  ? const Text('No headset selected.')
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('About this headset', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _aboutSection('Headset'),
                      _aboutRow('Name', s.headsetName),
                      _aboutRow('Model', info.displayName),
                      if (info.isQuest1) const Text('Singularity root features and Quest Home Switcher are not available on Quest 1.'),
                      _aboutRow('Serial', info.serial),
                      _aboutRow('Firmware', info.firmware),
                      _aboutRow('Android', info.androidVersion),
                      _aboutSection('Display'),
                      _aboutRow('Screen', info.resolution),
                      if (info.densityDpi > 0) _aboutRow('Density', '${info.densityDpi} dpi'),
                      _aboutSection('Battery'),
                      _aboutRow('Level', '${info.batteryLevel}%${info.charging ? ' (charging)' : ''}'),
                      if (info.batteryHealth.isNotEmpty) _aboutRow('Health', info.batteryHealth),
                      if (info.batteryTempC > 0) _aboutRow('Temperature', '${info.batteryTempC}°C'),
                      if (info.batteryVoltageMv > 0) _aboutRow('Voltage', '${(info.batteryVoltageMv / 1000).toStringAsFixed(2)} V'),
                      _aboutSection('Storage'),
                      _aboutRow('Used', '${info.storageUsedGb} GB of ${info.storageTotalGb} GB'),
                      _aboutRow('Free', '${info.storageFreeGb} GB'),
                      _aboutSection('Processor'),
                      _aboutRow('CPU', info.cpuAbi),
                    ]),
            ),
          ),
          const SizedBox(height: 16),
          _categoryHeader('Display and speed'),
          CardGrid(cards: [
            _sectionCard(
              title: 'Saved profiles',
              subtitle: 'Pick one and it is applied now and again on every connect.',
              infoTitle: 'Saved profiles',
              infoBody: 'A profile is a saved set of screen speed, CPU and GPU level. Pick one and it is applied to the headset now, and again every time you connect it. The profile is saved on this computer, per headset.',
              child: Wrap(spacing: 8, children: s.profilesForHeadset(info?.headsetModel ?? 'unknown').map((p) => ChoiceChip(
                label: Text('${p.name} (${p.refreshRate} Hz)'),
                selected: s.activeProfile == p.name,
                onSelected: (_) async {
                  setState(() { s.activeProfile = p.name; _refresh = p.refreshRate; _cpu = p.cpuLevel; _gpu = p.gpuLevel; });
                  final serial = s.selectedDevice?.serial;
                  if (serial != null) {
                    await s.setDeviceProfile(serial, p);
                    if (mounted) showResult(context, true, 'Profile ${p.name} applied and saved for this headset.');
                    s.log('Applied profile ${p.name}');
                  }
                },
              )).toList()),
            ),
            _sectionCard(
              title: 'Screen speed',
              subtitle: info?.isQuest1 == true ? 'Higher looks smoother but uses more battery. Quest 1 supports up to 72 Hz.' : info != null && info.model.toLowerCase().contains('quest 2') ? 'Higher looks smoother but uses more battery. Quest 2 supports up to 120 Hz.' : 'Higher looks smoother but uses more battery. Quest 3 supports up to 207 Hz.',
              child: DropdownButton<int>(
                value: _refreshRates.contains(_refresh) ? _refresh : _refreshRates.last,
                items: _refreshRates.map((v) => DropdownMenuItem(value: v, child: Text('$v Hz'))).toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _refresh = v);
                  await _apply('debug.oculus.refreshRate', '$v', 'Screen speed set to $v Hz.');
                },
              ),
            ),
            _sectionCard(
              title: 'Speed (CPU / GPU level)',
              subtitle: '0 is coolest and slowest, 4 is fastest and hottest. 2 is the normal setting.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Processor level: $_cpu'),
                Slider(value: _cpu.toDouble(), min: 0, max: 4, divisions: 4, label: '$_cpu', onChanged: (v) async {
                  setState(() => _cpu = v.toInt());
                  await _apply('debug.oculus.cpuLevel', '$_cpu', 'Processor level set to $_cpu.');
                }),
                Text('Graphics level: $_gpu'),
                Slider(value: _gpu.toDouble(), min: 0, max: 4, divisions: 4, label: '$_gpu', onChanged: (v) async {
                  setState(() => _gpu = v.toInt());
                  await _apply('debug.oculus.gpuLevel', '$_gpu', 'Graphics level set to $_gpu.');
                }),
              ]),
            ),
            _sectionCard(
              title: 'Render resolution',
              subtitle: 'Higher looks sharper but is slower and hotter. Default is what the headset normally uses. This resets on restart.',
              child: DropdownButton<int>(
                value: _texture,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Default')),
                  DropdownMenuItem(value: 1024, child: Text('1024 x 1024')),
                  DropdownMenuItem(value: 1280, child: Text('1280 x 1280')),
                  DropdownMenuItem(value: 1536, child: Text('1536 x 1536')),
                  DropdownMenuItem(value: 2048, child: Text('2048 x 2048')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _texture = v);
                  if (v == 0) {
                    showResult(context, true, 'Render resolution back to default on next app launch. Restart an app to see it.');
                    return;
                  }
                  await _apply('debug.oculus.textureWidth', '$v', 'Render width set to $v.');
                  await _apply('debug.oculus.textureHeight', '$v', 'Render resolution set to ${v}x$v.');
                },
              ),
            ),
            _sectionCard(
              title: 'Brightness',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Slider(value: _brightness, onChanged: (v) async {
                  setState(() => _brightness = v);
                  // Android brightness is 0-255; the slider is 0-1.
                  await _apply('system:screen_brightness', '${(v * 255).toInt()}', 'Brightness set.');
                }),
                SwitchListTile(
                  title: const Text('Automatic brightness'),
                  subtitle: const Text('Let the headset adjust brightness by itself.'),
                  value: _autoBrightness,
                  onChanged: (v) async {
                    setState(() => _autoBrightness = v);
                    await _apply('system:screen_brightness_mode', v ? '1' : '0', v ? 'Automatic brightness on.' : 'Automatic brightness off.');
                  },
                ),
              ]),
            ),
            _sectionCard(
              title: 'Screen timeout',
              subtitle: 'How long before the screen turns off when you are not using it.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButton<int>(
                  value: _timeout,
                  items: const [
                    DropdownMenuItem(value: 15000, child: Text('15 seconds')),
                    DropdownMenuItem(value: 30000, child: Text('30 seconds')),
                    DropdownMenuItem(value: 60000, child: Text('1 minute')),
                    DropdownMenuItem(value: 120000, child: Text('2 minutes')),
                    DropdownMenuItem(value: 300000, child: Text('5 minutes')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _timeout = v);
                    await _apply('system:screen_off_timeout', '$v', 'Screen timeout set.');
                  },
                ),
                SwitchListTile(
                  title: const Text('Keep screen on while charging'),
                  subtitle: const Text('The screen stays on while the headset is plugged in.'),
                  value: _stayAwake,
                  onChanged: (v) async {
                    setState(() => _stayAwake = v);
                    await _apply('global:stay_on_while_plugged_in', v ? '3' : '0', v ? 'Screen will stay on while charging.' : 'Screen will turn off as normal while charging.');
                  },
                ),
                SwitchListTile(
                  title: const Text('Full rate capture'),
                  subtitle: const Text('Record video at the full screen speed. Uses more battery and storage.'),
                  value: _fullRate,
                  onChanged: (v) async {
                    setState(() => _fullRate = v);
                    await _apply('debug.oculus.fullRateCapture', v ? '1' : '0', v ? 'Full rate capture on.' : 'Full rate capture off.');
                  },
                ),
                SwitchListTile(
                  title: const Text('Pause Guardian'),
                  subtitle: const Text('Turns the playspace boundary off for this session. Turn it back on before you play near walls or furniture.'),
                  value: _guardianPaused,
                  onChanged: (v) async {
                    setState(() => _guardianPaused = v);
                    await _apply('debug.oculus.guardian_pause', v ? '1' : '0', v ? 'Guardian paused.' : 'Guardian back on.');
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => showResult(context, true, 'Wi-Fi settings open on the headset. Put the headset on to pick a network there.'),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Open Wi-Fi settings on headset'),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          _categoryHeader('Backups'),
          CardGrid(cards: [
            _sectionCard(
              title: 'Device backups',
              subtitle: 'Settings, Guardian data, Wi-Fi configs, and an inventory of your apps. Apps themselves live in the library, not in the device backup.',
              infoTitle: 'Device backups',
              infoBody: 'A device backup saves the headset\'s settings, Guardian play area, Wi-Fi passwords, and a list of which apps are installed. The apps themselves are not copied into it. Restoring it puts the settings back; the apps come back from their own backups in the library.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FilledButton.icon(
                  onPressed: s.selectedDevice == null
                      ? null
                      : () async {
                          final r = await s.backend.deviceBackup(s.selectedDevice!.serial);
                          if (mounted) showResult(context, r.ok, r.message);
                          s.log('Device backup: ${r.ok ? 'done' : r.message}');
                          await _loadDeviceBackups();
                        },
                  icon: const Icon(Icons.backup),
                  label: const Text('Back up this headset now'),
                ),
                const SizedBox(height: 12),
                if (_deviceBackups.isEmpty)
                  const Text('No device backups yet.')
                else
                  ..._deviceBackups.map((b) => ListTile(
                        leading: const Icon(Icons.devices),
                        title: Text('${b.serial}  •  ${b.backupDate}'),
                        subtitle: Text('${formatBytes(b.totalSizeBytes)}  •  ${b.appCount} apps listed'),
                        trailing: TextButton(
                          onPressed: () => _restoreDeviceBackup(b),
                          child: const Text('Restore'),
                        ),
                      )),
              ]),
            ),
            _sectionCard(
              title: 'Headset snapshots',
              subtitle: 'A named save point for the whole headset: settings, Guardian data, Wi-Fi configs, an inventory of your apps, and the settings profile that was on. Apps reinstall from their library backups, they are not copied into the snapshot.',
              infoTitle: 'Headset snapshots',
              infoBody: 'A snapshot is a save point for the whole headset, like a save file in a game. It keeps the settings, Guardian area, Wi-Fi, the list of apps, and which settings profile was on. Restoring it puts all of that back. The apps themselves are reinstalled from the library, so keep your app backups too.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: TextField(controller: _snapshotName, decoration: const InputDecoration(labelText: 'Snapshot name, for example "Before rooting"', border: OutlineInputBorder()))),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: s.selectedDevice == null
                        ? null
                        : () async {
                            final name = _snapshotName.text.trim().isEmpty ? 'Snapshot' : _snapshotName.text.trim();
                            final r = await s.backend.snapshotCreate(s.selectedDevice!.serial, name, profile: s.activeProfile);
                            if (mounted) showResult(context, r != null, r == null ? 'Snapshot failed. Is the headset still connected?' : 'Snapshot "$name" saved.');
                            if (r != null) s.log('Snapshot "$name" saved.');
                            _snapshotName.clear();
                            await _loadSnapshots();
                          },
                    icon: const Icon(Icons.camera),
                    label: const Text('Take snapshot'),
                  ),
                ]),
                const SizedBox(height: 12),
                if (_snapshots.isEmpty)
                  const Text('No snapshots yet. Take one before a big change (rooting, a factory reset, trying a new home).')
                else
                  ..._snapshots.map((snap) => ListTile(
                        leading: const Icon(Icons.history),
                        title: Text('${snap.name}  •  ${snap.createdDate}'),
                        subtitle: Text('${snap.serial}  •  ${formatBytes(snap.totalSizeBytes)}  •  ${snap.appCount} apps listed'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          TextButton(onPressed: () => _restoreSnapshot(snap), child: const Text('Restore')),
                          TextButton(
                            onPressed: () async {
                              final yes = await confirmDialog(context, title: 'Delete this snapshot?', body: 'This deletes the snapshot files on this computer. The headset is not touched.', confirmLabel: 'Delete', destructive: true);
                              if (!yes) return;
                              final r = await s.backend.snapshotDelete(snap.path);
                              if (mounted) showResult(context, r.ok, r.message);
                              await _loadSnapshots();
                            },
                            child: const Text('Delete'),
                          ),
                        ]),
                      )),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          _categoryHeader('Home'),
          CardGrid(cards: [
            _sectionCard(
              title: 'Home launcher',
              subtitle: 'What you see when the headset starts. Meta Home is the stock one. Any other launcher you install shows up here.',
              infoTitle: 'Home launcher',
              infoBody: 'A home is the place you land in when the headset starts: the 3D room and the dock you launch apps from. Meta Home is the stock home, it is not in the list below, it is the default. Try once opens a launcher for this session only, it does not change the default. Make default tries the headset\u2019s own switch, on current firmware the headset refuses it, so the button opens the Home settings on the headset and you pick there.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _homes.any((h) => h.isCurrent)
                      ? 'Current home: ${_homeDisplayName(_homes.firstWhere((h) => h.isCurrent))}'
                      : 'Current home: Meta Home',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                if (_homes.isEmpty)
                  const Text('No other launcher installed yet. Meta Home is the only home. Install Lightning Launcher from the dropdown below to get another one.')
                else ...[
                  const Text('Your other launchers:'),
                  ..._homes.map((h) => ListTile(
                        leading: const Icon(Icons.home),
                        title: Text(_homeDisplayName(h)),
                        subtitle: Text(h.package, style: const TextStyle(fontSize: 12)),
                        trailing: h.isCurrent
                            ? const Chip(label: Text('Active', style: TextStyle(color: Color(0xFF070B14), fontWeight: FontWeight.bold)), backgroundColor: Color(0xFF38BDF8))
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                TextButton(
                                  onPressed: () async {
                                    final r = await s.backend.homesOpen(s.selectedDevice!.serial, h.component);
                                    if (mounted) showResult(context, r.ok, r.message);
                                  },
                                  child: const Text('Try once'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final r = await s.backend.homesSet(s.selectedDevice!.serial, h.component);
                                    if (!r.ok && mounted) {
                                      final open = await confirmDialog(context, title: 'The headset refused the switch', body: '${r.message}\n\nOpen the headset\u2019s Home settings instead and pick the home there?', confirmLabel: 'Open Home settings');
                                      if (open) {
                                        final r2 = await s.backend.homesOpenSettings(s.selectedDevice!.serial);
                                        if (mounted) showResult(context, r2.ok, r2.message);
                                      }
                                    } else if (mounted) {
                                      showResult(context, true, r.message);
                                    }
                                    await _loadHomes();
                                  },
                                  child: const Text('Make default'),
                                ),
                              ]),
                      )),
                ],
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: () async => _loadHomes(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh homes'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: s.selectedDevice == null
                        ? null
                        : () async {
                            final r = await s.backend.homesOpenMeta(s.selectedDevice!.serial);
                            if (mounted) showResult(context, r.ok, r.message);
                          },
                    icon: const Icon(Icons.home),
                    label: const Text('Try Meta Home once'),
                  ),
                ]),
                const SizedBox(height: 12),
                const Divider(),
                const Text('Headset settings shortcuts', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final entry in const [('Wi-Fi', 'wifi'), ('Display', 'display'), ('Storage', 'storage'), ('Apps', 'apps'), ('About', 'about')])
                    OutlinedButton(
                      onPressed: s.selectedDevice == null
                          ? null
                          : () async {
                              final r = await s.backend.homesOpenSettingsScreen(s.selectedDevice!.serial, entry.$2);
                              if (mounted) showResult(context, r.ok, r.message);
                            },
                      child: Text(entry.$1),
                    ),
                ]),
                const SizedBox(height: 12),
                const Divider(),
                ExpansionTile(
                  title: const Text('Get a home launcher', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Install Lightning Launcher or Quest Home Switcher.'),
                  initiallyExpanded: false,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(info?.isQuest1 == true ? 'Lightning Launcher replaces the apps menu on a Quest 1. Quest Home Switcher only lists Quest 2 / 3 / 3S, so it is not offered here.' : 'Lightning Launcher replaces the apps menu. Quest Home Switcher manages custom 3D home environments.', style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 8),
                        if (_homeAppsLoading)
                          const Text('Checking the headset…')
                        else if (_homeApps.isEmpty)
                          const Text('Could not read the home apps. Tap Refresh below.')
                        else
                          ..._homeApps.map((a) => _homeAppRow(a)),
                        OutlinedButton.icon(
                          onPressed: () async => _loadHomeApps(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh home apps'),
                        ),
                        if (info?.supportsHomeSwitcher == true) ...[
                          const SizedBox(height: 16),
                          Row(children: [
                            const Expanded(child: Text('Quest Home Switcher', style: TextStyle(fontWeight: FontWeight.bold))),
                            InfoButton('Quest Home Switcher', 'Quest Home Switcher manages custom 3D home environments: the official ones and about 250 community homes. The catalogue of homes lives inside the app itself, so browsing and viewing the homes happens on the headset, in Quest Home Switcher. The app is not open source; ReOculus only downloads its published release APK, never its code.'),
                          ]),
                          const SizedBox(height: 8),
                          const Text('Browse and view custom homes inside Quest Home Switcher on the headset: it has the full catalogue (official + about 250 community homes) with search, sorting and previews. Download and apply a home there; ReOculus just installs and opens the app.', style: TextStyle(fontSize: 13)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            FilledButton(
                              onPressed: s.selectedDevice == null
                                  ? null
                                  : () async {
                                      final r = await s.backend.homeAppOpen(s.selectedDevice!.serial, 'qhs');
                                      if (mounted) showResult(context, r.ok, r.message);
                                    },
                              child: const Text('Browse custom homes'),
                            ),
                            OutlinedButton(
                              onPressed: s.selectedDevice == null
                                  ? null
                                  : () async {
                                      final r = await s.backend.homeAppInstall(s.selectedDevice!.serial, 'qhs');
                                      if (mounted) showResult(context, r.ok, r.message);
                                      await _loadHomeApps();
                                    },
                              child: const Text('Install Quest Home Switcher'),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          const Text('Source: github.com/nikitat21/Quest-Home-Switcher', style: TextStyle(fontSize: 13)),
                        ],
                      ]),
                    ),
                  ],
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          _categoryHeader('Health'),
          CardGrid(cards: [
            _sectionCard(
              title: 'Headset Health',
              subtitle: 'Battery, storage, uptime, controllers, and when this headset was last backed up.',
              infoTitle: 'Headset Health',
              infoBody: 'A quick read of the headset: how much battery is left and how warm it is, how much storage is used, how long it has been on, which controllers were last seen, and when the last device backup was taken. Anything that looks wrong here is worth a look before you start a long session.',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_healthLoading)
                  const Text('Checking the headset\u2026')
                else if (_health == null)
                  const Text('No health data yet. Tap Refresh below.')
                else ...[
                  Text('Battery: ${_health!.batteryLevel}%${_health!.charging ? ' (charging)' : ''}'),
                  Text('Battery health: ${_health!.batteryHealth.isEmpty ? 'unknown' : _health!.batteryHealth}  •  Temperature: ${_health!.batteryTempC}\u00B0C  •  Voltage: ${_health!.batteryVoltageMv} mV'),
                  Text('Storage: ${_health!.sdcardUsedGb} GB used of ${_health!.sdcardTotalGb} GB (${formatBytes(_health!.sdcardFreeKb * 1024)} free)'),
                  Text('App data: ${_health!.dataUsedGb} GB used of ${_health!.dataTotalGb} GB'),
                  if (_health!.uptime != null) Text('Uptime: ${_health!.uptime}'),
                  Text('Last device backup: ${_health!.lastBackup ?? 'never'}'),
                ],
                const SizedBox(height: 12),
                const Text('Controllers', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                if (s.controllers == null)
                  const Text('Controller info is still loading.')
                else if (s.controllers!.names.isEmpty)
                  const Text('No controllers have been seen yet. Pick one up, press a button to wake it, then tap Refresh controllers below.')
                else if (s.controllers!.asleep)
                  Text('Asleep now. Last seen ${s.controllers!.lastSeen ?? 'a while ago'}: ${s.controllers!.names.join(', ')}. Pick one up, press a button to wake it, then tap Refresh controllers below.')
                else
                  ...s.controllers!.names.map((n) => Text('• $n (awake)')),
                const SizedBox(height: 8),
                const Text('Controller battery is not readable from this computer; check it in the headset (quick settings shows the controller batteries). Left and right cannot be told apart from here.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                const Text('Pair a controller: hold Menu + Y (left) or Menu + B (right) until the LED blinks, then pair it in the headset under Settings, Devices.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('Battery and usage history', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                if (_batteryHistory == null)
                  const Text('History is still loading.')
                else ...[
                  if (_batteryHistory!.samples.isEmpty)
                    const Text('ReOculus starts recording battery levels the first time it checks this headset, so the history fills in over the next few days. It can only see the headset while it is connected.')
                  else
                    ..._batteryHistory!.samples.reversed.take(6).map((s) => Text('• ${_formatDayTime(s.time)}: ${s.level}%${s.charging ? ' (charging)' : ''}')),
                  const SizedBox(height: 8),
                  if (_batteryHistory!.topApps.isEmpty)
                    const Text('Nothing used in the last 24 hours, or the headset did not share its usage stats.')
                  else ...[
                    const Text('Most used apps (last 24 hours)', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    ..._batteryHistory!.topApps.map((a) => Text('• ${_shortName(a.package)}: ${_formatUseTime(a.totalForegroundMs)} total${a.lastUsedMs == null ? '' : ', last used ${_formatDayTime(a.lastUsedMs! ~/ 1000)}'}')),
                  ],
                ],
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: () async => _loadHealth(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh health'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await widget.state.loadRooted();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh controllers'),
                  ),
                ]),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          if (info != null && !info.supportsSingularity)
            Card(
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Singularity is only for Quest 2, Pro, 3, and 3S, so there are no rooted settings on this Quest 1. Lightning Launcher in the Get a home launcher dropdown still works, and so do backups, files, and mirror.'),
              ),
            )
          else
            Card(
              child: ExpansionTile(
                title: Text(rooted ? 'Rooted settings' : 'Rooted settings (not rooted)', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(rooted ? 'Root is on this headset. These settings need root.' : 'This headset is not rooted, so these settings are hidden. Nothing here will root it for you.'),
              initiallyExpanded: false,
              children: [
                if (!rooted)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Rooted features (full app data backup, system app removal, reading an app\'s own data folders) stay hidden until root is detected.'),
                      const SizedBox(height: 12),
                      const Text('If you want to root this headset, the Singularity wizard checks the headset is ready, backs it up, downloads the latest Singularity release from GitHub, installs it, and then you press Root Now on the headset. Nothing is rooted without you watching it happen.', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: s.selectedDevice == null
                            ? null
                            : () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SingularityWizardScreen(state: s)));
                                await widget.state.loadRooted();
                                if (mounted) setState(() {});
                              },
                        icon: const Icon(Icons.key),
                        label: const Text('Install Singularity (root wizard)'),
                      ),
                    ]),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Rooted mode: on. Root method: ${s.rootStatus?.method ?? 'unknown'}. Singularity / Magisk is installed on this headset.'),
                      const SizedBox(height: 8),
                      const Text('Rooted features that are on: full /data/data backup in app backups, system app removal in the Apps screen, and reading the app\'s own data folders in Files.'),
                      const SizedBox(height: 12),
                      const Text('App data in backups: on, automatically. App backups in the Apps screen include the app\'s saved data (/data/data) when this headset is rooted. No setting to change, it is on because root is on.'),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () async {
                          await s.loadRooted();
                          if (mounted) showResult(context, s.rootStatus?.rooted == true, s.rootStatus?.rooted == true ? 'Root still works: ${s.rootStatus?.method ?? ''}.' : 'Root did not answer. The headset may need a restart, or Magisk may be off.');
                        },
                        icon: const Icon(Icons.verified),
                        label: const Text('Test root now'),
                      ),
                      const SizedBox(height: 8),
                      const Text('System app removal is in the Apps screen: open an app, tap More, then Remove system app. It needs root, and it fully removes that system app.'),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(child: Text('Pause Horizon OS updates', style: TextStyle(fontWeight: FontWeight.bold))),
                        InfoButton('Pause Horizon OS updates', 'Singularity pauses updates by pointing the update server at the headset itself, so no update can download. Nothing is turned off: the updater app stays as it is, because the home menu may need it. Turning this off deletes that setting and updates can download again.'),
                      ]),
                      SwitchListTile(
                        title: const Text('Pause updates'),
                        subtitle: Text(_ota == null ? 'Checking the update settings...' : (_ota!.blocked ? 'On. The headset cannot reach the update server.' : 'Off. The headset can download updates.')),
                        value: _ota?.blocked ?? false,
                        onChanged: (v) async {
                          final serial = widget.state.selectedDevice?.serial;
                          if (serial == null) return;
                          final st = await widget.state.backend.otaSet(serial, v);
                          setState(() => _ota = st);
                          if (mounted) showResult(context, true, v ? 'Updates are paused.' : 'Updates are allowed again.');
                        },
                      ),
                      if (_ota != null)
                        Text(_ota!.updaterDisabled ? 'Updater app: turned off by Singularity. ReOculus leaves it alone.' : 'Updater app: on.', style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 16),
                      Row(children: [
                        const Expanded(child: Text('Singularity downloads', style: TextStyle(fontWeight: FontWeight.bold))),
                        InfoButton('Singularity downloads', 'The files Singularity uses, downloaded from its own GitHub repo. Singularity is the root app. Frida is a researcher tool for inspecting apps on the headset. The blocklist is Singularity\'s list of Meta domains. Nothing here is bundled with ReOculus, it is downloaded when you tap Download.'),
                      ]),
                      const SizedBox(height: 4),
                      const Text('Singularity is closed source. ReOculus never bundles it or copies its code, it downloads what the author publishes.', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 8),
                      if (_singExtrasLoading) const Text('Loading downloads...'),
                      ..._downloads.map((d) => _downloadRow(d)),
                      const SizedBox(height: 16),
                      Row(children: [
                        const Expanded(child: Text('Dock and home settings (Singularity)', style: TextStyle(fontWeight: FontWeight.bold))),
                        InfoButton('Dock and home settings', 'These are the dock settings Singularity leaves on the headset. They change the home dock, like the battery percent and which buttons show. They usually take effect right away; if one does not show, restart the home screen below. The ones listed as info only are ones ReOculus does not change, because what values they accept is not written down anywhere public.'),
                      ]),
                      const SizedBox(height: 8),
                      ..._uxp.where((u) => u.isToggle).map((u) => SwitchListTile(
                            title: Text(u.label),
                            subtitle: Text(u.detail),
                            value: u.enabled,
                            onChanged: (v) async {
                              final serial = widget.state.selectedDevice?.serial;
                              if (serial == null) return;
                              final set = await widget.state.backend.uxpSet(serial, u.key, v ? '1' : '0');
                              if (set != null) {
                                setState(() {
                                  final i = _uxp.indexWhere((e) => e.key == u.key);
                                  if (i >= 0) _uxp[i] = set;
                                });
                              }
                            },
                          )),
                      ..._uxp.where((u) => !u.isToggle).map((u) => Text('${u.label}: ${u.value ?? 'not set'}', style: const TextStyle(fontSize: 13))),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final serial = widget.state.selectedDevice?.serial;
                          if (serial == null) return;
                          final go = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('Restart the home screen?'),
                              content: const Text('The home screen closes for a few seconds and comes back with the new dock settings.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Restart')),
                              ],
                            ),
                          );
                          if (go != true) return;
                          final r = await widget.state.backend.restartHome(serial);
                          if (mounted) showResult(context, r.ok, r.message);
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Restart home UI'),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              title: const Text('Dangerous settings', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('These can break the headset or make it unusable until you restart it. Only change them if you know what they do.'),
              initiallyExpanded: false,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (info?.isQuest1 == true)
                      const Text('Experimental features and force display scaling are not available on Quest 1.')
                    else ...[
                      SwitchListTile(
                        title: const Text('Experimental features'),
                        subtitle: const Text('Turns on experimental Quest features. They can be unfinished and unstable.'),
                        value: _experimental,
                        onChanged: (v) async {
                          setState(() => _experimental = v);
                          await _apply('debug.oculus.experimentalEnabled', v ? '1' : '0', v ? 'Experimental features on.' : 'Experimental features off.');
                        },
                      ),
                      SwitchListTile(
                        title: const Text('Force display scaling'),
                        subtitle: const Text('Needed for the highest screen speeds on Quest 3. Can make the picture look wrong on Quest 2.'),
                        value: _scaling,
                        onChanged: (v) async {
                          setState(() => _scaling = v);
                          await _apply('debug.oculus.forceDisplayScaling', v ? '1' : '0', v ? 'Display scaling forced on.' : 'Display scaling forced off.');
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text('Custom Quest setting', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('For a debug.oculus.* key you already know exists on this firmware. Unknown keys are refused by the backend. This is the power-user option, and a wrong value can break an app until you restart the headset.', style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 8),
                    TextField(controller: _customKey, decoration: const InputDecoration(labelText: 'Key, for example debug.oculus.custom.myKey', border: OutlineInputBorder())),
                    const SizedBox(height: 8),
                    TextField(controller: _customValue, decoration: const InputDecoration(labelText: 'Value', border: OutlineInputBorder())),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () async {
                        final k = _customKey.text.trim();
                        final v = _customValue.text.trim();
                        if (k.isEmpty) return;
                        await _apply(k, v, 'Custom setting $k set to $v.');
                      },
                      child: const Text('Apply custom setting'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () async {
                        final yes = await confirmDialog(context, title: 'Restart the headset?', body: 'The headset will turn off and back on. This takes about a minute. Any unsaved settings will reset.', confirmLabel: 'Restart', destructive: true);
                        if (!yes) return;
                        final serial = s.selectedDevice?.serial;
                        if (serial == null) return;
                        final r = await s.backend.reboot(serial);
                        if (mounted) showResult(context, r.ok, r.message);
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restart headset'),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  /// Restores a snapshot onto the headset. Dry run first, then confirm;
  /// overwrites settings, Guardian data, Wi-Fi configs, and apps.
  Future<void> _restoreSnapshot(SnapshotEntry snap) async {
    final s = widget.state;
    final serial = s.selectedDevice?.serial;
    if (serial == null) return;
    final dry = await s.backend.snapshotRestore(serial, snap.path, dryRun: true);
    if (dry == null || !mounted) return;
    final lines = dry.steps.map((st) => '• ${st.item}: ${st.message}').join('\n');
    if (!dry.ready) {
      if (mounted) showResult(context, false, 'Cannot restore yet:\n$lines');
      return;
    }
    final yes = await confirmDialog(
      context,
      title: 'Restore snapshot "${snap.name}"?',
      body: 'This will overwrite settings, Guardian data, Wi-Fi configs and apps on the headset, and re-apply the settings profile saved with the snapshot.\n\n$lines',
      confirmLabel: 'Restore',
      destructive: true,
    );
    if (!yes) return;
    final r = await s.backend.snapshotRestore(serial, snap.path, confirm: true);
    if (mounted) showResult(context, r?.ready ?? false, r == null ? 'Restore failed.' : r.steps.map((st) => '${st.item}: ${st.message}').join('\n'));
  }

  /// Restores a device backup onto the headset. Dry run first, then
  /// confirm; overwrites settings, Guardian data, Wi-Fi configs, and apps.
  Future<void> _restoreDeviceBackup(DeviceBackupEntry b) async {
    final s = widget.state;
    final serial = s.selectedDevice?.serial;
    if (serial == null) return;
    final dry = await s.backend.deviceRestore(serial, b.path, dryRun: true);
    if (dry == null || !mounted) return;
    final lines = dry.steps.map((st) => '• ${st.item}: ${st.message}').join('\n');
    if (!dry.ready) {
      if (mounted) showResult(context, false, 'Cannot restore yet:\n$lines');
      return;
    }
    final yes = await confirmDialog(
      context,
      title: 'Restore this device backup?',
      body: 'This will overwrite settings, Guardian data, Wi-Fi configs and apps on the headset.\n\n$lines',
      confirmLabel: 'Restore',
      destructive: true,
    );
    if (!yes) return;
    final r = await s.backend.deviceRestore(serial, b.path, confirm: true);
    if (mounted) showResult(context, r?.ready ?? false, r == null ? 'Restore failed.' : r.steps.map((st) => '${st.item}: ${st.message}').join('\n'));
  }
}

// ---- Mirror / Streaming ---------------------------------------------------
/// Mirror screen: live headset screen via scrcpy, quality presets,
/// recording, and screenshots.
class MirrorScreen extends StatefulWidget {
  final AppState state;
  const MirrorScreen({required this.state, super.key});
  @override
  State<MirrorScreen> createState() => _MirrorScreenState();
}

class _MirrorScreenState extends State<MirrorScreen> {
  bool _mirroring = false;
  bool _recording = false;
  String? _lastSaved;
  MirrorSettings _quality = const MirrorSettings(usbQuality: 'balanced', wifiQuality: 'performance');

  @override
  /// Loads the saved mirror quality when the screen opens.
  void initState() {
    super.initState();
    _loadQuality();
  }

  /// Loads the saved USB and Wi-Fi quality presets from the backend.
  Future<void> _loadQuality() async {
    final q = await widget.state.backend.mirrorSettings();
    if (q != null && mounted) setState(() => _quality = q);
  }

  /// Saves a changed quality preset. Rolls back to the old value on
  /// screen if the backend refuses it.
  Future<void> _saveQuality({String? usb, String? wifi, bool? autoRestart}) async {
    final before = _quality;
    setState(() => _quality = MirrorSettings(
          usbQuality: usb ?? _quality.usbQuality,
          wifiQuality: wifi ?? _quality.wifiQuality,
          autoRestart: autoRestart ?? _quality.autoRestart,
        ));
    final q = await widget.state.backend.setMirrorSettings(usbQuality: usb, wifiQuality: wifi, autoRestart: autoRestart);
    if (!mounted) return;
    if (q == null) {
      setState(() => _quality = before);
      showResult(context, false, 'Could not save the mirror quality. Is the backend still running?');
    } else {
      setState(() => _quality = q);
    }
  }

  /// Turn auto-restart on or off. When the mirror is running, the
  /// watcher starts or stops with it, so the change takes effect
  /// right away instead of on the next mirror start.
  Future<void> _setAutoRestart(bool v) async {
    await _saveQuality(autoRestart: v);
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null || !_mirroring) return;
    final transport = widget.state.selectedDevice?.transport ?? '';
    final preset = transport == 'wifi' ? _quality.wifiQuality : _quality.usbQuality;
    if (v) {
      await widget.state.backend.startMirrorWatch(serial, preset, transport == 'wifi' ? 'wifi' : 'usb');
    } else {
      await widget.state.backend.stopMirrorWatch(serial);
    }
  }

  /// One quality dropdown row (USB or Wi-Fi): Performance, Balanced, or Quality.
  Widget _qualityRow(String label, String value, ValueChanged<String> onChanged) => Row(children: [
        SizedBox(width: 48, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(
          child: DropdownButton<String>(
            value: const ['performance', 'balanced', 'quality'].contains(value) ? value : 'balanced',
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'performance', child: Text('Performance (1280, 4M, 30)')),
              DropdownMenuItem(value: 'balanced', child: Text('Balanced (1920, 8M, 60)')),
              DropdownMenuItem(value: 'quality', child: Text('Quality (2560, 12M, 90)')),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ]);

  /// Starts the mirror in its own scrcpy window, using the saved preset
  /// for the current transport (USB or Wi-Fi). Also starts the
  /// auto-restart watcher when that is on.
  Future<void> _mirror() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final scrcpy = await widget.state.backend.scrcpyAvailable;
    if (!scrcpy) {
      if (mounted) {
        showResult(context, false, 'scrcpy is not installed. Install it with: sudo apt install scrcpy, then try again.');
      }
      return;
    }
    await _stopMirror(silent: true);
    setState(() => _mirroring = true);
    // The quality comes from the saved settings: one preset for
    // USB, one for Wi-Fi. The defaults are the old automatic
    // picks (USB Balanced, Wi-Fi Performance).
    final transport = widget.state.selectedDevice?.transport ?? '';
    final preset = transport == 'wifi' ? _quality.wifiQuality : _quality.usbQuality;
    final r = await widget.state.backend.startMirror(serial, preset);
    if (mounted) showResult(context, r.ok, r.message);
    widget.state.log('Mirror started');
    // Auto-restart: a watcher on this computer checks which app
    // is in front about once a second and restarts the mirror
    // when a game or the menu opens, so it does not smear.
    // Stopping the mirror stops the watcher too.
    if (r.ok && _quality.autoRestart) {
      await widget.state.backend.startMirrorWatch(serial, preset, transport == 'wifi' ? 'wifi' : 'usb');
    }
  }

  /// Stops the mirror (and its watcher). Silent when called from inside
  /// a restart, so the user is not told twice.
  Future<void> _stopMirror({bool silent = false}) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final r = await widget.state.backend.stopMirror(serial);
    if (mounted) setState(() => _mirroring = false);
    if (!silent && mounted) showResult(context, r.ok, r.message);
    widget.state.log('Mirror stopped');
  }

  /// Restarts the mirror after a 2 second pause, so the headset finishes
  /// switching apps before the new stream starts.
  Future<void> _restartMirror() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    await _stopMirror(silent: true);
    // Give the headset a moment to settle before the new stream
    // starts. Restarting the instant the menu is still opening
    // or closing starts the new stream mid-transition and it
    // smears again, which is why Stop, wait a few seconds, then
    // Start used to work when Restart did not.
    await Future.delayed(const Duration(milliseconds: 2000));
    await _mirror();
  }

  @override
  /// Builds the mirror page: start/stop, quality, and record/screenshot cards.
  Widget build(BuildContext context) {
    final serial = widget.state.selectedDevice?.serial;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mirror the headset screen', style: Theme.of(context).textTheme.headlineSmall),
        const Text('See what the headset sees, live on this computer. Uses scrcpy: about 35 to 70 ms delay on USB, a bit more on Wi-Fi. No Meta account needed.'),
        const SizedBox(height: 16),
        if (serial == null)
          const EmptyState(icon: Icons.headset_off, title: 'No headset connected', body: 'Connect your Quest 2 from Home or Devices to mirror it.'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Icon(_mirroring ? Icons.cast_connected : Icons.cast, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(_mirroring ? 'Mirror is running in its own window.' : 'Mirror is off.', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('scrcpy opens in its own window.'),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                FilledButton.icon(
                  onPressed: serial == null ? null : (_mirroring ? () => _stopMirror() : _mirror),
                  icon: Icon(_mirroring ? Icons.stop : Icons.play_arrow),
                  label: Text(_mirroring ? 'Stop mirror' : 'Start mirror'),
                ),
                if (_mirroring)
                  OutlinedButton.icon(
                    onPressed: serial == null ? null : _restartMirror,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Restart mirror'),
                  ),
              ]),
              const SizedBox(height: 12),
              const Text('If the picture smears or goes black after you open the Quest menu over a game, tap Restart mirror. The menu switches what the headset is showing, and the video can lose its key frame, so restarting reattaches it.', textAlign: TextAlign.center),
            ]),
          ),
        ),
        CardGrid(cards: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Quality', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                  InfoButton('Mirror quality', 'Pick the mirror quality for USB and for Wi-Fi. Performance is the smoothest (1280, 4M, 30), Balanced is the middle (1920, 8M, 60), Quality is the sharpest (2560, 12M, 90) but needs a fast connection, so Wi-Fi usually glitches on it. The change applies the next time you start the mirror. If the picture smears after you open the Quest menu, tap Restart mirror.'),
                ]),
                const SizedBox(height: 4),
                _qualityRow('USB', _quality.usbQuality, (v) => _saveQuality(usb: v)),
                _qualityRow('Wi-Fi', _quality.wifiQuality, (v) => _saveQuality(wifi: v)),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () async {
                    final q = await widget.state.backend.resetMirrorSettings();
                    if (q != null && mounted) setState(() => _quality = q);
                  },
                  child: const Text('Reset to defaults (USB Balanced, Wi-Fi Performance)'),
                ),
                SwitchListTile(
                  title: const Text('Restart automatically'),
                  subtitle: const Text('When a game or the menu opens, the mirror restarts itself instead of smearing. The picture goes black for a second or two.'),
                  value: _quality.autoRestart,
                  onChanged: (v) => _setAutoRestart(v),
                ),
              ]),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Record and screenshots', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await widget.state.backend.openGalleryFolder();
                      if (mounted) showResult(context, r.ok, r.message);
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open folder'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: serial == null
                        ? null
                        : () async {
                            setState(() => _recording = !_recording);
                            if (_recording) {
                              final r = await widget.state.backend.startRecording(serial);
                              if (mounted) showResult(context, r.ok, r.message);
                              if (r.ok && mounted) {
                                setState(() => _lastSaved = (r.data['path'] as String?) ?? r.message);
                                widget.state.log('Recording saved');
                              }
                            }
                          },
                    icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                    label: Text(_recording ? 'Stop recording' : 'Record video'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: serial == null
                        ? null
                        : () async {
                            final r = await widget.state.backend.screenshot(serial, '');
                            if (mounted) showResult(context, r.ok, r.message);
                            if (r.ok && mounted) {
                              setState(() => _lastSaved = (r.data['path'] as String?) ?? r.message);
                              widget.state.log('Screenshot saved');
                            }
                          },
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Take screenshot'),
                  ),
                ]),
                const SizedBox(height: 8),
                const Text('Video has no sound. A recording stops after about 3 minutes; start it again for longer clips. Screenshots and recordings are saved in ~/quest-recordings/ and shown in Files, then Gallery.', style: TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ]),
        if (_lastSaved != null) ...[
          const SizedBox(height: 8),
          Card(child: ListTile(leading: const Icon(Icons.check_circle), title: Text('Saved: $_lastSaved'))),
        ],
      ]),
    );
  }
}

// ---- Logs: logcat + Terminal + Debug info ----------------------------------
/// Logs screen: App logs, Headset logs (logcat), Terminal, and Debug
/// info, under one tab bar.
class LogsScreen extends StatefulWidget {
  final AppState state;
  const LogsScreen({required this.state, super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  int _tab = 0; // 0 = Logs, 1 = Terminal, 2 = Debug info
  int _logSource = 0; // 0 = App logs, 1 = Headset logs
  // Logcat
  List<String> _lines = [];
  String _filter = '';
  bool _paused = false;
  bool _loading = false;
  // Terminal
  final _cmdCtrl = TextEditingController();
  String _termOut = '';
  bool _termBusy = false;
  bool _termCancelled = false;
  final List<String> _history = [];
  // Debug
  DebugInfo? _debug;
  bool _debugLoading = false;

  @override
  /// Loads the headset log lines when the screen opens.
  void initState() {
    super.initState();
    _load();
  }

  /// Reloads the headset log lines, filtered by the search text.
  /// Skipped while paused or with no headset.
  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null || _paused) return;
    setState(() => _loading = true);
    _lines = await widget.state.backend.logLines(serial, filter: _filter);
    setState(() => _loading = false);
  }

  /// Reloads the debug info (questctl and adb versions, device, root status).
  Future<void> _loadDebug() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _debugLoading = true);
    _debug = await widget.state.backend.debugInfo(serial);
    setState(() => _debugLoading = false);
  }

  /// Runs the typed shell command on the headset and shows its exit code
  /// and output. "Stop" only stops waiting; the command still finishes on
  /// the headset.
  Future<void> _runCommand() async {
    final serial = widget.state.selectedDevice?.serial;
    final cmd = _cmdCtrl.text.trim();
    if (serial == null || cmd.isEmpty || _termBusy) return;
    _history.insert(0, cmd);
    _termCancelled = false;
    setState(() {
      _termBusy = true;
      _termOut = 'Running: $cmd\n';
    });
    widget.state.log('Shell: $cmd');
    final r = await widget.state.backend.runShell(serial, cmd);
    if (_termCancelled) {
      setState(() => _termBusy = false);
      return;
    }
    if (mounted) {
      setState(() {
        _termBusy = false;
        _termOut = r == null
            ? 'Running: $cmd\nCommand failed to run.'
            : 'Command: $cmd\nExit code: ${r.code}\n${r.stdout}${r.stderr.isNotEmpty ? '\nError output:\n${r.stderr}' : ''}';
      });
    }
  }

  /// Builds the debug info as plain text, for copying.
  String _debugText() {
    final d = _debug;
    if (d == null) return 'No debug info loaded.';
    final dev = d.device;
    final b = StringBuffer();
    b.writeln('ReOculus debug info');
    b.writeln('questctl: ${d.questctlVersion}');
    b.writeln('adb: ${d.adbVersion}');
    b.writeln('scrcpy: ${d.scrcpyAvailable ? 'present' : 'not installed'}');
    b.writeln('backend: ${d.backendPath}');
    if (dev != null) {
      b.writeln('device: ${dev.model} ${dev.serial} (${dev.firmware}, Android ${dev.androidVersion})');
      b.writeln('battery: ${dev.batteryLevel}%${dev.charging ? ' (charging)' : ''}');
      b.writeln('storage: ${dev.storageUsedGb} GB used of ${dev.storageTotalGb} GB');
      b.writeln('resolution: ${dev.resolution}');
    }
    b.writeln('wifi ip: ${d.wifiIp ?? 'not connected over Wi-Fi'}');
    b.writeln('root: ${d.root.rooted ? d.root.method : 'not rooted'}');
    return b.toString();
  }

  @override
  /// Builds the Logs tabs: App logs, Headset logs, Terminal, or Debug info.
  Widget build(BuildContext context) {
    final s = widget.state;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Logs', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Logs')),
              ButtonSegment(value: 1, label: Text('Terminal')),
              ButtonSegment(value: 2, label: Text('Debug info')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) {
              setState(() => _tab = v.first);
              if (_tab == 2 && _debug == null) _loadDebug();
            },
          ),
        ]),
        const SizedBox(height: 8),
        if (_tab == 0) ...[
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('App logs')),
              ButtonSegment(value: 1, label: Text('Headset logs')),
            ],
            selected: {_logSource},
            onSelectionChanged: (v) => setState(() => _logSource = v.first),
          ),
          const SizedBox(height: 8),
          if (_logSource == 0) ...[
            Row(children: [
              OutlinedButton.icon(
                onPressed: s.activity.isEmpty
                    ? null
                    : () async {
                        final f = File('/tmp/reoculus-app-log.txt');
                        await f.writeAsString(s.activity.join('\n'));
                        if (mounted) showResult(context, true, 'App logs saved to /tmp/reoculus-app-log.txt');
                      },
                icon: const Icon(Icons.download),
                label: const Text('Export'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: s.activity.isEmpty ? null : () => widget.state.clearActivity(),
                icon: const Icon(Icons.delete),
                label: const Text('Clear'),
              ),
            ]),
            const SizedBox(height: 4),
            const Text('What ReOculus itself did on this computer in this session: installs, backups, mirror, shell commands. Not the headset log, and it is cleared when the app closes.'),
            const SizedBox(height: 12),
            Expanded(
              child: Card(
                child: s.activity.isEmpty
                    ? const EmptyState(icon: Icons.article, title: 'No app log yet', body: 'Do something in the app, like install an app or start the mirror, and it shows up here.')
                    : ListView.builder(
                        itemCount: s.activity.length,
                        itemBuilder: (c, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: SelectableText(s.activity[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                      ),
              ),
            ),
          ] else ...[
          Row(children: [
            FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => setState(() => _paused = !_paused), icon: Icon(_paused ? Icons.play_arrow : Icons.pause), label: Text(_paused ? 'Resume' : 'Pause')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final f = File('/tmp/quest-log.txt');
                await f.writeAsString(_lines.join('\n'));
                if (mounted) showResult(context, true, 'Logs saved to /tmp/quest-log.txt');
              },
              icon: const Icon(Icons.download),
              label: const Text('Export'),
            ),
          ]),
          const SizedBox(height: 4),
          const Text('Live messages from the headset. Useful when an app crashes or misbehaves. Logs can contain personal details, so only share them with someone you trust.'),
          const SizedBox(height: 12),
          TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter logs, for example "error" or an app name', border: OutlineInputBorder()), onChanged: (v) { _filter = v; _load(); }),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _lines.isEmpty
                      ? const EmptyState(icon: Icons.article, title: 'No log lines match', body: 'Clear the filter, or tap Refresh.')
                      : ListView.builder(
                          itemCount: _lines.length,
                          itemBuilder: (c, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: SelectableText(_lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                        ),
            ),
          ),
          ],
        ] else if (_tab == 1) ...[
          const Text('Commands run on the headset as the shell user. They can read almost everything, but writing outside shared storage needs root.'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _cmdCtrl,
                decoration: const InputDecoration(labelText: 'Command, for example: ls /sdcard/', border: OutlineInputBorder()),
                style: const TextStyle(fontFamily: 'monospace'),
                onSubmitted: (_) => _runCommand(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _termBusy ? null : _runCommand, child: const Text('Run')),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                _termCancelled = true;
                setState(() {
                  _termBusy = false;
                  _termOut = 'Stopped waiting. The command may still finish on the headset (it times out after 120 seconds on its own).';
                });
              },
              child: const Text('Stop'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => setState(() => _termOut = ''),
              child: const Text('Clear'),
            ),
          ]),
          const SizedBox(height: 8),
          if (_history.isNotEmpty)
            Wrap(spacing: 8, children: _history.take(6).map((h) => ActionChip(label: Text(h, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)), onPressed: () {
              _cmdCtrl.text = h;
              _runCommand();
            })).toList()),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: SelectableText(_termOut.isEmpty ? 'Nothing run yet. Try: ls /sdcard/' : _termOut, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _termOut.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _termOut));
                      if (mounted) showResult(context, true, 'Terminal output copied.');
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy output'),
            ),
          ]),
        ] else ...[
          Row(children: [
            FilledButton.icon(onPressed: _loadDebug, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _debug == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _debugText()));
                      if (mounted) showResult(context, true, 'Debug info copied.');
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy debug info'),
            ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _debugLoading
                ? const Center(child: CircularProgressIndicator())
                : _debug == null
                    ? const EmptyState(icon: Icons.bug_report, title: 'No debug info', body: 'Connect a headset, then tap Refresh.')
                    : SingleChildScrollView(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('questctl version: ${_debug!.questctlVersion}'),
                              Text('adb version: ${_debug!.adbVersion}'),
                              Text('scrcpy: ${_debug!.scrcpyAvailable ? 'present' : 'not installed'}'),
                              Text('backend path: ${_debug!.backendPath}'),
                              if (_debug!.device != null) ...[
                                const SizedBox(height: 8),
                                Text('Device: ${_debug!.device!.model} ${_debug!.device!.serial}'),
                                Text('Firmware: ${_debug!.device!.firmware}'),
                                Text('Android: ${_debug!.device!.androidVersion}'),
                                Text('Battery: ${_debug!.device!.batteryLevel}%${_debug!.device!.charging ? ' (charging)' : ''}'),
                                Text('Storage: ${_debug!.device!.storageUsedGb} GB used of ${_debug!.device!.storageTotalGb} GB'),
                                Text('Resolution: ${_debug!.device!.resolution}'),
                              ],
                              const SizedBox(height: 8),
                              Text('Wi-Fi IP: ${_debug!.wifiIp ?? 'not connected over Wi-Fi'}'),
                              Text('Root: ${_debug!.root.rooted ? _debug!.root.method : 'not rooted'}'),
                            ]),
                          ),
                        ),
                      ),
          ),
        ],
      ]),
    );
  }
}

// ---- Setup / Onboarding + Settings ---------------------------------------
// Real mode only: there is no demo toggle and no sample data. The app
// always uses the Real backend (questctl); if it is missing, Home and
// Devices show a plain error state instead of falling back.
/// Setup screen: first-run checklist, theme, backend info, storage
/// locations, About, and the Support Countdown.
class SetupScreen extends StatefulWidget {
  final AppState state;
  const SetupScreen({required this.state, super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _devMode = true;
  bool _udev = false;
  bool _allowed = true;
  PathsInfo? _paths;

  @override
  /// Loads the storage locations when the screen opens.
  void initState() {
    super.initState();
    _loadPaths();
  }

  /// Reloads the backup and recordings folder paths. Fails soft.
  Future<void> _loadPaths() async {
    try {
      _paths = await widget.state.backend.pathsGet();
    } catch (_) {
      _paths = null;
    }
    if (mounted) setState(() {});
  }

  /// Opens a URL in the system browser. Failures are ignored.
  Future<void> _openUrl(String url) async {
    try {
      await Process.run('xdg-open', [url]);
    } catch (_) {}
  }

  @override
  /// Builds the Setup page: checklist, design, backend, storage, About,
  /// and Support Countdown cards.
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Setup', style: Theme.of(context).textTheme.headlineSmall),
          const Text('First time here? Work through this list once. After that, just plug in and go.'),
          if (s.backendError != null)
            Card(
              color: Colors.orange.shade100,
              child: ListTile(leading: const Icon(Icons.warning, color: Colors.black87), title: Text(s.backendError!, style: const TextStyle(color: Colors.black87))),
            ),
          CardGrid(cards: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('First run checklist', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  _CheckTile(title: '1. Create a free Meta developer account', body: 'This is the one Meta step. It cannot be done inside this app and you do not sign in here. Open developers.meta.com in your browser and create a free developer organisation.', done: _devMode, onChanged: (v) => setState(() => _devMode = v ?? false), onOpen: () => _openUrl('https://developers.meta.com')),
                  _CheckTile(title: '2. Turn on Developer Mode on the headset', body: 'In the Meta Horizon phone app: Menu, Devices, your headset, Headset Settings, Developer Mode ON.', done: _devMode, onChanged: (v) => setState(() => _devMode = v ?? false)),
                  _CheckTile(title: '3. Allow USB debugging', body: 'Plug the headset in. Put it on. When it asks "Allow USB debugging?", tap Allow and tick "Always allow from this computer".', done: _allowed, onChanged: (v) => setState(() => _allowed = v ?? false)),
                  _CheckTile(title: '4. Linux USB permission (udev rule)', body: 'On Ubuntu, install the Android udev rules so the headset is not listed as "no permissions": sudo apt install android-sdk-platform-tools-common, then unplug and plug the headset back in.', done: _udev, onChanged: (v) => setState(() => _udev = v ?? false)),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Design', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text('Design picked: Dark VR Neon, blue instead of purple. You can preview the other looks here, but VR Neon stays the default.'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: DesignDirection.values.map((d) => ChoiceChip(label: Text(d.name), selected: s.design == d, onSelected: (_) => s.setDesign(d))).toList()),
                  const SizedBox(height: 8),
                  Text(s.design.plainDescription),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Backend', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  const Row(children: [
                    Text('Mode: ', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Real backend (questctl). No demo mode.'),
                  ]),
                  const SizedBox(height: 8),
                  Text('Backend location:', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
                  SelectableText(s.backendPath ?? 'Not connected yet', style: const TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  Wrap(spacing: 12, children: [
                    OutlinedButton.icon(
                      onPressed: s.backendPath == null
                          ? null
                          : () async {
                              final dir = File(s.backendPath!).parent.path;
                              try {
                                await Process.run('xdg-open', [dir]);
                              } catch (_) {}
                            },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Open backend folder'),
                    ),
                    OutlinedButton.icon(
                      onPressed: s.backendPath == null
                          ? null
                          : () async {
                              await Clipboard.setData(ClipboardData(text: s.backendPath!));
                              if (mounted) showResult(context, true, 'Backend path copied.');
                            },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy path'),
                    ),
                  ]),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Expanded(child: Text('Storage locations', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                    InfoButton('Storage locations', 'Backups and the APK library share one folder; screenshots and recordings have their own. Moving a location does not move the files already there: the new folder starts empty, and the old one is left alone, so nothing is lost. The library will look empty until backups are made or APKs are imported there.'),
                  ]),
                  const SizedBox(height: 4),
                  const Text('Where backups, the APK library, screenshots and recordings are kept on this computer. Move them if you keep your files somewhere else, like a bigger drive.', style: TextStyle(fontSize: 13)),
                if (_paths == null)
                  const Text('Storage locations are still loading.')
                else ...[
                  const Text('Backups and APK library', style: TextStyle(fontWeight: FontWeight.bold)),
                  SelectableText(_paths!.backupRoot, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  Text(_paths!.backupRootIsDefault ? 'Default location.' : 'Custom location.', style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Pick the backups and library folder');
                      if (picked == null) return;
                      final p = await widget.state.backend.pathsSet(backupRoot: picked);
                      if (mounted) {
                        if (p != null) {
                          setState(() => _paths = p);
                          showResult(context, true, 'Backups and library will go to $picked from now on. Files already there were not moved.');
                        } else {
                          showResult(context, false, 'Could not change the backup folder.');
                        }
                      }
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Change backups folder'),
                  ),
                  const SizedBox(height: 12),
                  const Text('Screenshots and recordings', style: TextStyle(fontWeight: FontWeight.bold)),
                  SelectableText(_paths!.recordingsRoot, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  Text(_paths!.recordingsRootIsDefault ? 'Default location.' : 'Custom location.', style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Pick the screenshots and recordings folder');
                      if (picked == null) return;
                      final p = await widget.state.backend.pathsSet(recordingsRoot: picked);
                      if (mounted) {
                        if (p != null) {
                          setState(() => _paths = p);
                          showResult(context, true, 'Screenshots and recordings will go to $picked from now on. Files already there were not moved.');
                        } else {
                          showResult(context, false, 'Could not change the recordings folder.');
                        }
                      }
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Change recordings folder'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final p = await widget.state.backend.pathsReset();
                      if (mounted) {
                        if (p != null) {
                          setState(() => _paths = p);
                          showResult(context, true, 'Back to the default folders.');
                        } else {
                          showResult(context, false, 'Could not reset the folders.');
                        }
                      }
                    },
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset to defaults'),
                  ),
                ],
              ]),
            ),
          ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('About', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text('ReOculus 0.2.26. A Quest 2 and Quest 1 companion for Linux and Android. No account, no ads, no analytics. Everything runs on this computer. Use it at your own risk, I am not responsible for anything that happens.'),
                  const Text('Linux first, Quest 2 first: this app is how you use your Quest on Linux, with no Windows and no Meta account needed.'),
                  const Text('Meta ends Quest 2 feature updates in March 2027 and security patches in December 2027. This app keeps working offline after that.'),
                  const Text('Sideloading uses Meta\'s official Developer Mode. Only install apps you own or that the developer gives away freely.'),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Support Countdown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 4),
                  const Text('When Meta stops updating each headset. The headset keeps working after that, it just stops getting new stuff.', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 12),
                  const Text('Quest 1: already ended', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Features ended: January 2023 (v50 was the last feature release)'),
                  const Text('Security patches ended: 31 August 2024'),
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 4),
                  const Text('Quest 2: counting down', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _CountdownRow(
                    label: 'Feature updates end',
                    detail: 'March 2027',
                    target: _quest2FeaturesEnd,
                  ),
                  const SizedBox(height: 12),
                  _CountdownRow(
                    label: 'Security patches end',
                    detail: 'December 2027',
                    target: _quest2SecurityEnd,
                  ),
                ]),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ---- Support Countdown --------------------------------------------------
/// Support Countdown dates. Meta only gives a month for Quest 2,
/// so the countdowns run to the end of that month: 31 March 2027
/// for the last feature release, 31 December 2027 for the final
/// security patch. Quest 1: features ended January 2023 (v50),
/// security patches ended 31 August 2024.
/// (final, not const: DateTime has no const constructor.)
final _quest2FeaturesEnd = DateTime(2027, 3, 31, 23, 59, 59);
final _quest2SecurityEnd = DateTime(2027, 12, 31, 23, 59, 59);

/// One countdown line: "Feature updates end, March 2027" then
/// "138 days left". Days only, no hours or seconds, so a future
/// date change is just a new target date above.
class _CountdownRow extends StatelessWidget {
  final String label, detail;
  final DateTime target;
  const _CountdownRow({required this.label, required this.detail, required this.target});
  /// Builds one countdown line: the label, then days left, or "Ended".
  @override
  Widget build(BuildContext context) {
    final left = target.difference(DateTime.now());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label, $detail', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      if (left.isNegative)
        const Text('Ended', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))
      else
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '${left.inDays}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const TextSpan(
              text: ' days left',
              style: TextStyle(fontSize: 20),
            ),
          ]),
        ),
    ]);
  }
}

// ---- Setup checklist tile -----------------------------------------------
/// One checklist row: a checkbox, a title, an explanation, and an
/// optional button to open the linked page.
class _CheckTile extends StatelessWidget {
  final String title, body;
  final bool done;
  final ValueChanged<bool?> onChanged;
  final VoidCallback? onOpen;
  const _CheckTile({required this.title, required this.body, required this.done, required this.onChanged, this.onOpen});
  @override
  /// Builds one checklist row.
  Widget build(BuildContext context) => Card(
        child: CheckboxListTile(
          value: done,
          onChanged: onChanged,
          title: Text(title),
          subtitle: Text(body),
          secondary: onOpen == null ? null : IconButton(icon: const Icon(Icons.open_in_new), onPressed: onOpen),
        ),
      );
}
