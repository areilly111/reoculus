import 'dart:io';
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
  bool _healthLoading = false;

  @override
  void initState() {
    super.initState();
    widget.state.loadRooted();
    widget.state.loadHealth();
    _loadDeviceBackups();
    _loadHomes();
    _loadSnapshots();
  }

  Future<void> _loadDeviceBackups() async {
    _deviceBackups = await widget.state.backend.listDeviceBackups();
    if (mounted) setState(() {});
  }

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

  Future<void> _loadSnapshots() async {
    try {
      _snapshots = await widget.state.backend.snapshotList();
    } catch (_) {
      _snapshots = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadHealth() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _healthLoading = true);
    try {
      _health = await widget.state.backend.deviceHealth(serial);
    } catch (_) {
      _health = null;
    }
    if (mounted) setState(() => _healthLoading = false);
  }

  Future<void> _apply(String key, String value, String plain) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final r = await widget.state.backend.setSetting(serial, key, value);
    if (mounted) showResult(context, r.ok, r.ok ? plain : r.message);
  }

  List<int> get _refreshRates {
    final model = widget.state.deviceInfo?.model ?? '';
    if (model.toLowerCase().contains('quest 2')) return [60, 72, 80, 90, 96, 120];
    return [60, 72, 80, 90, 96, 120, 144, 180, 207];
  }

  @override
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
          const Text('Safe settings are at the top. Anything that can break the headset is in the closed Dangerous section below. Rooted settings are in their own closed section, and only show up when this headset is rooted. Most of these settings reset when the headset restarts. Your saved profile is applied again each time you connect.'),
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
                      Text('Model: ${info.model}'),
                      Text('Serial: ${info.serial}'),
                      Text('Firmware: ${info.firmware}'),
                      Text('Android: ${info.androidVersion}'),
                      Text('Screen: ${info.resolution}'),
                      Text('Processor: ${info.cpuAbi}'),
                    ]),
            ),
          ),
          if (s.controllers != null) ...[
            Row(children: [
              const Expanded(child: SectionTitle('Controllers')),
              OutlinedButton.icon(
                onPressed: () async {
                  await widget.state.loadRooted();
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ]),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (s.controllers!.names.isEmpty)
                    const Text('No controllers are awake right now. They sleep within seconds of being put down and vanish from what the headset reports. Pick them up, press a button to wake them, then tap Refresh here.')
                  else
                    ...s.controllers!.names.map((n) => Text('• $n')),
                  const SizedBox(height: 8),
                  Text(s.controllers!.note, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  const Text('Pair a controller: hold Menu + Y (left) or Menu + B (right) until the LED blinks, then pair it in the headset under Settings, Devices.', style: TextStyle(fontSize: 13)),
                ]),
              ),
            ),
          ],
          const SectionTitle('Saved profiles', subtitle: 'Pick one and it is applied now and again on every connect.'),
          Wrap(spacing: 8, children: s.profiles.map((p) => ChoiceChip(
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
          const SectionTitle('Screen speed', subtitle: 'Higher looks smoother but uses more battery. Quest 2 supports up to 120 Hz.'),
          DropdownButton<int>(
            value: _refreshRates.contains(_refresh) ? _refresh : _refreshRates.last,
            items: _refreshRates.map((v) => DropdownMenuItem(value: v, child: Text('$v Hz'))).toList(),
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _refresh = v);
              await _apply('debug.oculus.refreshRate', '$v', 'Screen speed set to $v Hz.');
            },
          ),
          const SectionTitle('Speed (CPU / GPU level)', subtitle: '0 is coolest and slowest, 4 is fastest and hottest. 2 is the normal setting.'),
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
          const SectionTitle('Render resolution', subtitle: 'Higher looks sharper but is slower and hotter. Default is what the headset normally uses. This resets on restart.'),
          DropdownButton<int>(
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
          const SectionTitle('Brightness'),
          Slider(value: _brightness, onChanged: (v) async {
            setState(() => _brightness = v);
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
          const SectionTitle('Screen timeout', subtitle: 'How long before the screen turns off when you are not using it.'),
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
          const SectionTitle('Device backups', subtitle: 'Settings, Guardian data, Wi-Fi configs, and an inventory of your apps. Apps themselves live in the library, not in the device backup.'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
          ),
          const SectionTitle('Headset snapshots', subtitle: 'A named save point for the whole headset: settings, Guardian data, Wi-Fi configs, an inventory of your apps, and the settings profile that was on. Apps reinstall from their library backups, they are not copied into the snapshot.'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
          ),
          const SectionTitle('Homes', subtitle: 'The home environments on this headset. The active one is marked. Switching uses the headset\u2019s own home command; if it refuses, open the headset\u2019s Home settings and pick there.'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_homes.isEmpty)
                  const Text('No home apps found, or the headset has not answered yet. Tap Refresh below.')
                else
                  ..._homes.map((h) => ListTile(
                        leading: const Icon(Icons.home),
                        title: Text(h.label),
                        subtitle: Text(h.component),
                        trailing: h.isCurrent
                            ? const Chip(label: Text('Active', style: TextStyle(color: Color(0xFF070B14), fontWeight: FontWeight.bold)), backgroundColor: Color(0xFF38BDF8))
                            : TextButton(
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
                                child: const Text('Set active'),
                              ),
                      )),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async => _loadHomes(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh homes'),
                ),
              ]),
            ),
          ),
          const SectionTitle('Battery and health', subtitle: 'Battery, storage, uptime, and when this headset was last backed up.'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async => _loadHealth(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh health'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
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
                      const Text('Pause Horizon OS updates', style: TextStyle(fontWeight: FontWeight.bold)),
                      const Text('Do not use the old toggle here: Android refuses to turn off com.oculus.updater, it is a protected package, and turning it off can break the home menu. To pause updates, use Singularity on the headset itself, its Update Engine disabler defers updates instead of turning the updater off.'),
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
    // Auto: no quality setting for the user to change. USB is fast
    // enough for Balanced (1920/8M/60), Wi-Fi uses Performance
    // (1280/4M/30) so it stays smooth instead of glitching.
    final transport = widget.state.selectedDevice?.transport ?? '';
    final preset = transport == 'wifi' ? 'Performance' : 'Balanced';
    final r = await widget.state.backend.startMirror(serial, preset);
    if (mounted) showResult(context, r.ok, r.message);
    widget.state.log('Mirror started');
  }

  Future<void> _stopMirror({bool silent = false}) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final r = await widget.state.backend.stopMirror(serial);
    if (mounted) setState(() => _mirroring = false);
    if (!silent && mounted) showResult(context, r.ok, r.message);
    widget.state.log('Mirror stopped');
  }

  Future<void> _restartMirror() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    await _stopMirror(silent: true);
    await Future.delayed(const Duration(milliseconds: 500));
    await _mirror();
  }

  @override
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
        const SectionTitle('Quality', subtitle: 'Picked automatically, no setting to change. USB uses Balanced, Wi-Fi uses Performance, so the mirror stays smooth instead of glitching.'),
        const SectionTitle('Record and screenshots'),
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
        const Text('Video has no sound. A recording stops after about 3 minutes; start it again for longer clips. Screenshots and recordings are saved in ~/quest-recordings/ and shown in Files, then Gallery.', style: TextStyle(fontSize: 13)),
        if (_lastSaved != null) ...[
          const SizedBox(height: 8),
          Card(child: ListTile(leading: const Icon(Icons.check_circle), title: Text('Saved: $_lastSaved'))),
        ],
      ]),
    );
  }
}

// ---- Logs: logcat + Terminal + Debug info ----------------------------------
class LogsScreen extends StatefulWidget {
  final AppState state;
  const LogsScreen({required this.state, super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  int _tab = 0; // 0 = Logs, 1 = Terminal, 2 = Debug info
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
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null || _paused) return;
    setState(() => _loading = true);
    _lines = await widget.state.backend.logLines(serial, filter: _filter);
    setState(() => _loading = false);
  }

  Future<void> _loadDebug() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _debugLoading = true);
    _debug = await widget.state.backend.debugInfo(serial);
    setState(() => _debugLoading = false);
  }

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
  Widget build(BuildContext context) {
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

  @override
  void initState() {
    super.initState();
  }

  Future<void> _openUrl(String url) async {
    try {
      await Process.run('xdg-open', [url]);
    } catch (_) {}
  }

  @override
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
          const SectionTitle('First run checklist'),
          _CheckTile(title: '1. Create a free Meta developer account', body: 'This is the one Meta step. It cannot be done inside this app and you do not sign in here. Open developers.meta.com in your browser and create a free developer organisation.', done: _devMode, onChanged: (v) => setState(() => _devMode = v ?? false), onOpen: () => _openUrl('https://developers.meta.com')),
          _CheckTile(title: '2. Turn on Developer Mode on the headset', body: 'In the Meta Horizon phone app: Menu, Devices, your headset, Headset Settings, Developer Mode ON.', done: _devMode, onChanged: (v) => setState(() => _devMode = v ?? false)),
          _CheckTile(title: '3. Allow USB debugging', body: 'Plug the headset in. Put it on. When it asks "Allow USB debugging?", tap Allow and tick "Always allow from this computer".', done: _allowed, onChanged: (v) => setState(() => _allowed = v ?? false)),
          _CheckTile(title: '4. Linux USB permission (udev rule)', body: 'On Ubuntu, install the Android udev rules so the headset is not listed as "no permissions": sudo apt install android-sdk-platform-tools-common, then unplug and plug the headset back in.', done: _udev, onChanged: (v) => setState(() => _udev = v ?? false)),
          const SectionTitle('Design'),
          const Text('Design picked: Dark VR Neon, blue instead of purple. You can preview the other looks here, but VR Neon stays the default.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: DesignDirection.values.map((d) => ChoiceChip(label: Text(d.name), selected: s.design == d, onSelected: (_) => s.setDesign(d))).toList()),
          const SizedBox(height: 8),
          Text(s.design.plainDescription),
          const SectionTitle('Backend'),
          const Row(children: [
            Text('Mode: ', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Real backend (questctl). No demo mode.'),
          ]),
          const SizedBox(height: 8),
          // The backend connects itself on launch: the AppImage
          // bundles questctl, otherwise the dev build next to the
          // app is used. Nothing to type and nothing to connect.
          // This is just so you can see where it lives.
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
          const SectionTitle('About'),
          const Text('ReOculus 0.2.17. A Quest 2 companion for Linux and Android. No account, no ads, no analytics. Everything runs on this computer.'),
          const Text('Linux first, Quest 2 first: this app is how you use your Quest on Linux, with no Windows and no Meta account needed.'),
          const Text('Meta ends Quest 2 feature updates in March 2027 and security patches in December 2027. This app keeps working offline after that.'),
          const Text('Sideloading uses Meta\'s official Developer Mode. Only install apps you own or that the developer gives away freely.'),
        ]),
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  final String title, body;
  final bool done;
  final ValueChanged<bool?> onChanged;
  final VoidCallback? onOpen;
  const _CheckTile({required this.title, required this.body, required this.done, required this.onChanged, this.onOpen});
  @override
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
