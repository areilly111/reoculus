import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

// ---- Shared "Connect a headset" dialog ------------------------------------
// Used from Home and Devices, any time, whether a device is connected
// or not (so a second headset or a Wi-Fi switch is easy). Two clear
// choices, plain language, no jargon. Developer Mode help is inside
// both tabs: it is the one Meta gate, and it is free.

Future<void> showConnectHeadsetDialog(BuildContext context, AppState state) async {
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

class _UsbTab extends StatelessWidget {
  final AppState state;
  const _UsbTab({required this.state});
  @override
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

class _WifiTab extends StatefulWidget {
  final AppState state;
  const _WifiTab({required this.state});
  @override
  State<_WifiTab> createState() => _WifiTabState();
}

class _WifiTabState extends State<_WifiTab> {
  final _ip = TextEditingController();
  final _port = TextEditingController(text: '37857');
  final _code = TextEditingController();
  bool _busy = false;

  @override
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
                    final r = await widget.state.backend.pairWifi(_ip.text.trim(), _port.text.trim(), _code.text.trim());
                    if (!mounted) return;
                    setState(() => _busy = false);
                    showResult(context, r.ok, r.message);
                    widget.state.log('Wi-Fi connect: ${r.ok ? 'connected' : r.message}');
                    if (r.ok) await widget.state.refreshDevices();
                  },
            icon: const Icon(Icons.wifi),
            label: const Text('Pair / Connect'),
          ),
          const SizedBox(height: 16),
          const _DevModeHelp(),
          const SizedBox(height: 8),
          const Text('Tip: the first time you plug in over USB, the app sets up Wi-Fi by itself, so you can unplug after that.'),
        ]),
      );
}

class _DevModeHelp extends StatelessWidget {
  const _DevModeHelp();
  @override
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
class HomeScreen extends StatefulWidget {
  final AppState state;
  final void Function(int) goTo;
  const HomeScreen({required this.state, required this.goTo, super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    widget.state.refreshDevices();
  }

  @override
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
                  onPressed: () => widget.goTo(8),
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
                        body: 'Nothing here is sample data. Connect your Quest 2 over USB or Wi-Fi to see it here.',
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 12, children: [
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
                          Text(dev.model, style: Theme.of(context).textTheme.titleLarge),
                          Text('${dev.serial}  •  ${dev.transport == 'wifi' ? 'Wi-Fi' : 'USB'}', style: Theme.of(context).textTheme.bodySmall),
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
                    ]),
            ),
          ),
          // First-run PC VR prompt: first headset connection, no
          // WiVRn app on it yet, user has not said no. Install sets
          // up the server (bundled in the app), the headset app,
          // and the USB link, so afterwards it is just Start + tap.
          if (dev != null && s.wivrnClientVersion == null && !s.wivrnDeclined)
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
            _QuickAction(icon: Icons.backup, label: 'Back up headset', onTap: () => widget.goTo(1)),
            _QuickAction(icon: Icons.refresh, label: 'Refresh', onTap: () => s.refreshDevices()),
          ]),
          const SectionTitle('Recent activity'),
          Card(
            child: s.activity.isEmpty
                ? const ListTile(title: Text('Nothing yet. Install an app or take a screenshot and it will show up here.'))
                : Column(children: s.activity.take(8).map((a) => ListTile(leading: const Icon(Icons.check_circle_outline), title: Text(a))).toList()),
          ),
          const SizedBox(height: 16),
          const Text('No account. No ads. Nothing is uploaded anywhere. Everything here runs on this computer.', style: TextStyle(fontSize: 13)),
        ]),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _QuickAction({required this.icon, required this.label, required this.onTap});
  @override
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

// ---- Devices --------------------------------------------------------------
class DevicesScreen extends StatefulWidget {
  final AppState state;
  const DevicesScreen({required this.state, super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _busy = false;

  @override
  @override
  void initState() {
    super.initState();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await widget.state.refreshDevices();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Devices', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              FilledButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
              const SizedBox(width: 8),
              OutlinedButton.icon(onPressed: () => showConnectHeadsetDialog(context, s), icon: const Icon(Icons.headset), label: const Text('Connect a headset')),
            ]),
            const SizedBox(height: 8),
            const Text('USB is the most reliable. Wi-Fi is handy once it is paired. Both need Developer Mode turned on first.'),
            if (s.backendError != null) ...[
              const SizedBox(height: 8),
              Card(
                color: Colors.orange.shade100,
                child: ListTile(leading: const Icon(Icons.warning, color: Colors.black87), title: Text(s.backendError!, style: const TextStyle(color: Colors.black87))),
              ),
            ],
            if (s.wifiNote != null) ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.wifi),
                  title: Text(s.wifiNote!),
                  trailing: s.wifiNote!.startsWith('Wi-Fi setup did not work')
                      ? TextButton(onPressed: () => s.retryWifiSetup(), child: const Text('Retry'))
                      : null,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            if (s.devices.isEmpty)
              const EmptyState(
                icon: Icons.headset_off,
                title: 'No headset connected',
                body: 'Nothing here is sample data. Plug the headset in with USB, or connect it over Wi-Fi, then tap Check again.',
              )
            else
              ...s.devices.map((d) {
                final selected = s.selectedDevice?.serial == d.serial;
                return Card(
                  child: ListTile(
                    leading: Icon(d.transport == 'wifi' ? Icons.wifi : Icons.usb, size: 32),
                    title: Text('${d.model}  •  ${d.transport == 'wifi' ? 'Wi-Fi' : 'USB'}'),
                    subtitle: Text(d.serial),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Chip(
                        label: Text(
                          d.state == 'device' ? 'Ready' : d.state == 'offline' ? 'Offline' : d.state == 'unauthorized' ? 'Waiting for approval' : d.state,
                          style: const TextStyle(color: Color(0xFF070B14), fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: d.state == 'device' ? const Color(0xFF38BDF8) : const Color(0xFFF59E0B),
                      ),
                      const SizedBox(width: 8),
                      if (selected) const Icon(Icons.check_circle, color: Colors.green),
                    ]),
                    onTap: () => s.selectDevice(d),
                  ),
                );
              }),
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
          ]),
        ),
      ),
    );
  }

}
