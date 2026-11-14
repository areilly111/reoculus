// Home and Devices screens, plus the shared "Connect a headset" dialog.
// Home: the dashboard with headset status, quick actions, and recent
// activity. Devices: the list of connected headsets, rename, and sync.
// The connect dialog is used from both, with USB and Wi-Fi tabs.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../models.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

// ---- Shared "Connect a headset" dialog ------------------------------------
// Used from Home and Devices, any time, whether a device is connected
// or not (so a second headset or a Wi-Fi switch is easy). Two clear
// choices, plain language, no jargon. Developer Mode help is inside
// both tabs: it is the one Meta gate, and it is free.

/// Shows the "Connect a headset" dialog: USB and Wi-Fi tabs on Linux,
/// Wi-Fi only on Android (a phone cannot run an adb server to the headset).
Future<void> showConnectHeadsetDialog(BuildContext context, AppState state) async {
  // Android has no USB path: a phone cannot run an adb server to the
  // headset, so the dialog is Wi-Fi only there. Linux keeps both tabs.
  if (Platform.isAndroid) {
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Connect a headset'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: _WifiTab(state: state)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ],
      ),
    );
    return;
  }
  await showDialog(
    context: context,
    builder: (c) => DefaultTabController(
      length: 2,
      child: AlertDialog(
        title: const Text('Connect a headset'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const TabBar(tabs: [Tab(text: 'Connect with USB'), Tab(text: 'Connect with Wi-Fi')]),
            const SizedBox(height: 12),
            Flexible(
              child: TabBarView(children: [
                _UsbTab(state: state),
                _WifiTab(state: state),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ],
      ),
    ),
  );
}

/// USB tab: the three steps to plug in and allow USB debugging, plus
/// Developer Mode help.
class _UsbTab extends StatelessWidget {
  final AppState state;
  const _UsbTab({required this.state});
  @override
  /// Builds the USB instructions and the Check again button.
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('1. Plug the Quest into this computer with a USB-C cable. Use a data cable, not a charge-only cable.'),
          const SizedBox(height: 8),
          const Text('2. Put the headset on. When it asks "Allow USB debugging?", tap Allow, and tick "Always allow from this computer" if you trust this computer.'),
          const SizedBox(height: 8),
          const Text('3. If you do not see that prompt, Developer Mode may be off. See below.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              await state.refreshDevices();
              if (context.mounted) {
                showResult(context, state.devices.isNotEmpty, state.devices.isNotEmpty ? 'Headset found.' : 'Still no headset. Check the steps above, then try again.');
              }
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
          const SizedBox(height: 16),
          const _DevModeHelp(),
        ]),
      );
}

/// Wi-Fi tab: IP, port, and pairing code fields, plus Developer Mode help.
class _WifiTab extends StatefulWidget {
  final AppState state;
  const _WifiTab({required this.state});
  @override
  State<_WifiTab> createState() => _WifiTabState();
}

class _WifiTabState extends State<_WifiTab> {
  final _ip = TextEditingController();
  // Android has no USB setup step, so the usual port there is 5555
  // (plain wireless ADB, already listening on most headsets). On
  // Linux the default stays the pairing port: the app sets up Wi-Fi
  // over USB first, and pairing is the first step there.
  final _port = TextEditingController(text: Platform.isAndroid ? '5555' : '37857');
  final _code = TextEditingController();
  bool _busy = false;

  @override
  /// Builds the Wi-Fi form and the Pair / Connect button.
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('The headset and this computer must be on the same Wi-Fi network.'),
          const SizedBox(height: 8),
          const Text('Where to find the IP: on the headset, Settings, Wi-Fi, tap your network. The IP is shown there.'),
          const SizedBox(height: 12),
          TextField(controller: _ip, decoration: const InputDecoration(labelText: 'Headset IP address', hintText: '192.168.1.45', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port', hintText: '37857 for pairing, 5555 for plain wireless ADB', border: OutlineInputBorder()), keyboardType: TextInputType.number),
          const SizedBox(height: 8),
          TextField(controller: _code, decoration: const InputDecoration(labelText: '6 digit pairing code (only when pairing)', hintText: 'Leave empty if the headset is already paired', border: OutlineInputBorder()), keyboardType: TextInputType.number, maxLength: 6),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    // Android: the direct transport needs the address
                    // before the pair/connect call runs, and the
                    // address is saved on success for the next launch.
                    // Linux: the existing backend pair/connect flow.
                    final r = Platform.isAndroid
                        ? await widget.state.connectWifiDirect(_ip.text.trim(), _port.text.trim(), _code.text.trim())
                        : await widget.state.backend.pairWifi(_ip.text.trim(), _port.text.trim(), _code.text.trim());
                    if (!mounted) return;
                    setState(() => _busy = false);
                    showResult(context, r.ok, r.message);
                    widget.state.log('Wi-Fi connect: ${r.ok ? 'connected' : r.message}');
                    if (r.ok && !Platform.isAndroid) await widget.state.refreshDevices();
                  },
            icon: const Icon(Icons.wifi),
            label: const Text('Pair / Connect'),
          ),
          const SizedBox(height: 16),
          const _DevModeHelp(),
          const SizedBox(height: 8),
          if (!Platform.isAndroid) const Text('Tip: the first time you plug in over USB, the app sets up Wi-Fi by itself, so you can unplug after that.'),
        ]),
      );
}

/// Developer Mode help card: the free Meta developer account and where
/// to turn Developer Mode on.
class _DevModeHelp extends StatelessWidget {
  const _DevModeHelp();
  @override
  /// Builds the Developer Mode help card.
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Developer Mode help', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('Developer Mode is the one Meta gate, and it is free:'),
            const SizedBox(height: 4),
            const Text('1. Create a free Meta developer account (developers.meta.com, in your browser). The text is a link to copy, not a button: this app does not open a browser by itself.'),
            const Text('2. Turn on Developer Mode in the Meta Horizon phone app: Menu, Devices, your headset, Headset Settings, Developer Mode ON.'),
            const Text('3. Then the USB prompt appears in the headset.'),
          ]),
        ),
      );
}

// ---- Home / Dashboard -----------------------------------------------------
/// Home screen: the dashboard. Headset status, quick actions, and
/// recent activity.
class HomeScreen extends StatefulWidget {
  final AppState state;
  final void Function(int) goTo;
  const HomeScreen({required this.state, required this.goTo, super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  /// Battery/storage per headset, for the Headsets list below.
  final Map<String, DeviceInfo> _infos = {};
  /// Custom name per headset, read from each headset's own config
  /// file. Each headset card has its own rename button, and the
  /// name syncs itself on connect, so there is no name card.
  final Map<String, HeadsetConfig> _configs = {};

  @override
  /// Refreshes the device list when Home opens, then loads each
  /// headset's info and custom name for the Headsets list.
  void initState() {
    super.initState();
    widget.state.refreshDevices().then((_) => _loadInfos());
  }

  /// Loads model, battery, storage and the custom name for each
  /// connected headset, skipping ones already loaded. Fails soft
  /// per headset.
  Future<void> _loadInfos() async {
    for (final d in widget.state.devices) {
      if (!_infos.containsKey(d.serial)) {
        try {
          final info = await widget.state.backend.deviceInfo(d.serial);
          if (info != null) _infos[d.serial] = info;
        } catch (_) {}
      }
      if (!_configs.containsKey(d.serial)) {
        try {
          _configs[d.serial] = await widget.state.backend.headsetConfig(d.serial);
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  /// Re-scans for headsets, then reloads their info and names.
  Future<void> _refresh() async {
    setState(() => _busy = true);
    await widget.state.refreshDevices();
    _infos.clear();
    _configs.clear();
    await _loadInfos();
    setState(() => _busy = false);
  }

  /// Rename dialog: type a name, Save writes it to the headset's
  /// config file. Saving an empty name clears the custom name and
  /// the app goes back to showing the model (Quest 2, Quest 1...).
  /// The name is read back on the next connect, so Linux and
  /// Android stay in step without a sync button.
  Future<void> _renameHeadset(BuildContext context, AppState s, String serial) async {
    final controller = TextEditingController(text: _configs[serial]?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Name this headset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. My Quest 2',
            helperText: 'Saved on the headset, so every computer and phone shows the same name. Leave it empty to go back to the model name.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    final cfg = await s.renameHeadset(name, serial: serial);
    if (cfg != null && mounted) {
      setState(() => _configs[serial] = cfg);
    }
    if (context.mounted) showResult(context, cfg != null, cfg != null ? (name.isEmpty ? 'Custom name cleared.' : 'Headset renamed to "$name".') : 'Could not rename the headset.');
  }

  /// Group the raw adb list into one card per headset. A USB entry
  /// and a Wi-Fi entry are the SAME headset when the USB headset's
  /// own Wi-Fi address matches the Wi-Fi entry's address; a Wi-Fi
  /// entry with no USB twin (or no readable address) stays its own
  /// card, so a second real headset is never folded into the first.
  List<_DeviceGroup> _groups(AppState s) {
    final usb = s.devices.where((d) => d.transport != 'wifi').toList();
    final wifi = s.devices.where((d) => d.transport == 'wifi').toList();
    final paired = <QuestDevice>{};
    final groups = <_DeviceGroup>[];
    for (final u in usb) {
      QuestDevice? twin;
      final ip = _infos[u.serial]?.wifiIp;
      if (ip != null) {
        for (final w in wifi) {
          if (!paired.contains(w) && w.serial.split(':').first == ip) {
            twin = w;
            paired.add(w);
            break;
          }
        }
      }
      groups.add(_DeviceGroup(primary: u, secondary: twin));
    }
    for (final w in wifi) {
      if (!paired.contains(w)) groups.add(_DeviceGroup(primary: w));
    }
    return groups;
  }

  /// One headset's card: name (with its own rename button), serial,
  /// battery and storage, and a chip per connection showing how it
  /// is hooked up right now. When the same headset is on USB and
  /// Wi-Fi at once, the card says the USB cable can come out.
  Widget _deviceCard(BuildContext context, AppState s, _DeviceGroup g) {
    final primary = g.primary;
    final secondary = g.secondary;
    final selected = s.selectedDevice?.serial == primary.serial ||
        (secondary != null && s.selectedDevice?.serial == secondary.serial);
    final info = _infos[primary.serial] ?? (secondary != null ? _infos[secondary.serial] : null);
    final profile = s.profileFor(primary.serial);
    final name = _configs[primary.serial]?.name ?? primary.displayName;
    String stateLabel(String state) => state == 'device'
        ? 'Ready'
        : state == 'offline'
            ? 'Offline'
            : state == 'unauthorized'
                ? 'Waiting for approval'
                : state;
    final bothReady = secondary != null && primary.state == 'device' && secondary.state == 'device';
    final lines = [
      primary.serial,
      if (secondary != null) secondary.serial,
      if (info != null) 'Battery ${info.batteryLevel}%  •  ${info.storageUsedGb} / ${info.storageTotalGb} GB used',
      if (profile != null) 'Profile: $profile',
    ].join('\n');
    return Card(
      child: ListTile(
        leading: Icon(primary.transport == 'wifi' ? Icons.wifi : Icons.usb, size: 32),
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          IconButton(
            icon: const Icon(Icons.edit, size: 20),
            tooltip: 'Rename this headset',
            onPressed: () => _renameHeadset(context, s, primary.serial),
          ),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(lines),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final d in [primary, if (secondary != null) secondary])
              Chip(
                avatar: Icon(d.transport == 'wifi' ? Icons.wifi : Icons.usb, size: 16),
                label: Text('${d.transport == 'wifi' ? 'Wi-Fi' : 'USB'} • ${stateLabel(d.state)}'),
                backgroundColor: d.state == 'device' ? const Color(0xFF38BDF8) : const Color(0xFFF59E0B),
                labelStyle: const TextStyle(color: Color(0xFF070B14), fontWeight: FontWeight.bold),
              ),
          ]),
          if (bothReady) ...[
            const SizedBox(height: 6),
            const Row(children: [
              Icon(Icons.info_outline, size: 16),
              SizedBox(width: 6),
              Expanded(child: Text('You can unplug the USB cable, this headset stays connected over Wi-Fi.')),
            ]),
          ],
        ]),
        trailing: selected ? const Icon(Icons.check_circle, color: Colors.green) : null,
        onTap: () => s.selectDevice(primary),
      ),
    );
  }

  @override
  /// Builds the dashboard: backend error card, headset card, the
  /// Headsets list (the old Devices page, folded in), quick
  /// actions, and the WiVRn setup prompt. Recent activity lives on
  /// the Logs screen now, under App logs.
  Widget build(BuildContext context) {
    final s = widget.state;
    final info = s.deviceInfo;
    final dev = s.selectedDevice;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s.backendError != null)
            Card(
              color: Colors.orange.shade100,
              child: ListTile(
                leading: const Icon(Icons.warning, color: Colors.black87),
                title: const Text('Backend not found', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
                subtitle: Text(s.backendError!, style: const TextStyle(color: Colors.black87)),
                trailing: TextButton(
                  onPressed: () => widget.goTo(9),
                  child: const Text('Setup'),
                ),
              ),
            ),
          Text('Your headset', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(dev == null ? 'No headset connected.' : 'Connected and ready.', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (s.wifiNote != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(s.wifiNote!),
                trailing: s.wifiNote!.startsWith('Wi-Fi setup did not work')
                    ? TextButton(onPressed: () => s.retryWifiSetup(), child: const Text('Retry'))
                    : null,
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: dev == null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const EmptyState(
                        icon: Icons.headset_off,
                        title: 'No headset connected',
                        body: 'Nothing here is sample data. Connect your Quest over USB or Wi-Fi to see it here.',
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 12, children: [
                        if (!Platform.isAndroid)
                          FilledButton.icon(onPressed: () => showConnectHeadsetDialog(context, s), icon: const Icon(Icons.usb), label: const Text('Connect with USB')),
                        OutlinedButton.icon(onPressed: () => showConnectHeadsetDialog(context, s), icon: const Icon(Icons.wifi), label: const Text('Connect with Wi-Fi')),
                        OutlinedButton.icon(onPressed: () => s.refreshDevices(), icon: const Icon(Icons.refresh), label: const Text('Check again')),
                      ]),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(Icons.headset, size: 40),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.headsetName, style: Theme.of(context).textTheme.titleLarge),
                          Text(
                            '${dev.serial}  •  ${dev.transport == 'wifi' ? 'Wi-Fi' : 'USB'}${s.headsetConfig?.name != null ? '  •  ${dev.displayName}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ])),
                        Chip(
                          label: Text(
                            dev.state == 'device' ? 'Ready' : dev.state == 'offline' ? 'Offline' : dev.state == 'unauthorized' ? 'Waiting for approval' : dev.state,
                            style: const TextStyle(color: Color(0xFF070B14), fontWeight: FontWeight.bold),
                          ),
                          backgroundColor: dev.state == 'device' ? const Color(0xFF38BDF8) : const Color(0xFFF59E0B),
                        ),
                      ]),
                      const SizedBox(height: 16),
                      if (info != null) ...[
                        Row(children: [
                          const Icon(Icons.battery_full, size: 20),
                          const SizedBox(width: 8),
                          Text('Battery ${info.batteryLevel}%${info.charging ? ' (charging)' : ''}'),
                          const SizedBox(width: 24),
                          const Icon(Icons.memory, size: 20),
                          const SizedBox(width: 8),
                          Text('Firmware ${info.firmware}'),
                        ]),
                        const SizedBox(height: 12),
                        Text('Storage: ${info.storageUsedGb} GB used of ${info.storageTotalGb} GB'),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: info.storageTotalGb > 0 ? info.storageUsedGb / info.storageTotalGb : 0),
                      ],
                      if (s.controllers != null && s.controllers!.names.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text('Controllers: ${s.controllers!.names.join(', ')}'),
                      ],
                      if (info != null && info.isQuest1) ...[
                        const SizedBox(height: 12),
                        const Text('Quest 1: Singularity root features and Quest Home Switcher are not available on this headset. Everything else works the same.'),
                      ],
                    ]),
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle('Headsets', subtitle: 'USB is the most reliable. Wi-Fi is handy once it is paired. Both need Developer Mode turned on first.'),
          Row(children: [
            FilledButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => showConnectHeadsetDialog(context, s), icon: const Icon(Icons.headset), label: const Text('Connect a headset')),
          ]),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (s.devices.isEmpty)
            const EmptyState(
              icon: Icons.headset_off,
              title: 'No headset connected',
              body: 'Nothing here is sample data. Plug the headset in with USB, or connect it over Wi-Fi, then tap Refresh.',
            )
          else
            CardGrid(cards: _groups(s).map((g) => _deviceCard(context, s, g)).toList()),
          if (s.devices.any((d) => d.state == 'unauthorized'))
            Card(
              color: Colors.orange.shade100,
              child: const ListTile(
                leading: Icon(Icons.warning, color: Colors.black87),
                title: Text('Headset is waiting for your OK', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
                subtitle: Text('Put the headset on and tap Allow on the "Allow USB debugging?" message. Then tap Refresh.', style: TextStyle(color: Colors.black87)),
              ),
            ),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: s.selectedDevice == null ? null : () async {
                final r = await s.backend.disconnectWifi(s.selectedDevice!.serial);
                if (mounted) showResult(context, r.ok, r.message);
              },
              icon: const Icon(Icons.wifi_off),
              label: const Text('Disconnect Wi-Fi / turn wireless ADB off'),
            ),
          ]),
          const Text('Tip: wireless debugging turns off when the headset restarts. If Wi-Fi stops working, pair again from this screen.', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 16),
          const SectionTitle('Quick actions', subtitle: 'The things you will use most.'),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _QuickAction(icon: Icons.cast, label: 'Mirror screen', onTap: () => widget.goTo(5)),
            _QuickAction(icon: Icons.camera_alt, label: 'Screenshot', onTap: () async {
              if (dev == null) return;
              final r = await s.backend.screenshot(dev.serial, '');
              if (mounted) showResult(context, r.ok, r.message);
              s.log('Screenshot: ${r.ok ? 'saved' : r.message}');
            }),
            _QuickAction(icon: Icons.file_download, label: 'Install APK', onTap: () => widget.goTo(2)),
            _QuickAction(icon: Icons.folder, label: 'Open Files', onTap: () => widget.goTo(3)),
            _QuickAction(icon: Icons.backup, label: 'Back up headset', onTap: () => widget.goTo(4)),
            _QuickAction(icon: Icons.refresh, label: 'Refresh', onTap: () => s.refreshDevices()),
          ]),
          const SizedBox(height: 16),
          CardGrid(cards: [
            if (dev != null && s.wivrnSetupKnown && s.wivrnClientVersion == null && !s.wivrnDeclined)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.view_in_ar),
                  title: const Text('Set up PC VR (WiVRn)?'),
                  subtitle: const Text('Installs the WiVRn app on the headset and sets up the USB and Wi-Fi links, so afterwards you just press Start and tap this computer in the headset.'),
                  trailing: Wrap(spacing: 8, children: [
                    TextButton(onPressed: () => s.declineWivrn(), child: const Text('Not now')),
                    FilledButton(
                      onPressed: () async {
                        final msg = await s.runWivrnSetup();
                        if (mounted) showResult(context, msg.startsWith('WiVRn is ready'), msg);
                      },
                      child: const Text('Install'),
                    ),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          const Text('No account. No ads. Nothing is uploaded anywhere. Everything here runs on this computer.', style: TextStyle(fontSize: 13)),
        ]),
      ),
    );
  }
}

/// One quick-action tile on Home: an icon, a label, and a tap target.
class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickAction({required this.icon, required this.label, required this.onTap});
  @override
  /// Builds one quick-action tile.
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 150,
            height: 96,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 30, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
        ),
      );
}

/// One headset as the Home screen's Headsets list shows it: the
/// primary entry (USB when there is one) plus the Wi-Fi entry when
/// it is the SAME headset, matched by the headset's own Wi-Fi address.
class _DeviceGroup {
  final QuestDevice primary;
  final QuestDevice? secondary;
  const _DeviceGroup({required this.primary, this.secondary});
}

