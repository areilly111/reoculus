import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

/// PC VR streaming via WiVRn 26.9 (separate, unmodified process).
/// The wrapper starts/stops wivrn-server, writes its config file
/// and checks status. It does not run SteamVR, and it cannot show
/// live latency or FPS: WiVRn has no API for that.
class PcVrScreen extends StatefulWidget {
  final AppState state;
  const PcVrScreen({super.key, required this.state});
  @override
  State<PcVrScreen> createState() => _PcVrScreenState();
}

class _PcVrScreenState extends State<PcVrScreen> {
  Map<String, dynamic>? _detect;
  Map<String, dynamic>? _status;
  String? _clientVersion;
  String _encoder = 'nvenc';
  String _codec = 'h265';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Shared install flow: clears a decline, installs the bundled
  /// server if needed, the headset app, and the USB link.
  Future<void> _install() async {
    setState(() => _busy = true);
    final msg = await widget.state.runWivrnSetup();
    if (mounted) {
      showResult(context, msg.startsWith('WiVRn is ready'), msg);
      setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final d = await widget.state.backend.wivrnDetect();
    final s = await widget.state.backend.wivrnStatus();
    String? cv;
    final dev = widget.state.selectedDevice;
    if (dev != null) {
      cv = await widget.state.backend.wivrnHeadsetClient(dev.serial);
    }
    if (mounted) {
      setState(() {
        _detect = d;
        _status = s;
        _clientVersion = cv;
      });
    }
  }

  Future<void> _act(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detect;
    final s = _status;
    final installed = d?['installed'] == true;
    final running = s?['running'] == true;
    final serverVersion = (d?['server_version'] ?? '').toString();
    final match = _clientVersion != null && _clientVersion == serverVersion && serverVersion.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionTitle('PC VR (WiVRn)'),
        const Text(
          'Streams PC VR games from this computer to your Quest 2 over Wi-Fi or USB, using WiVRn 26.9. Linux only, no Windows, no SteamVR. The server and the WiVRn app on the headset must be the same version.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        // Refused or not installed yet: the whole section is
        // greyed out except an Install button that reopens setup.
        // The "not installed" branch needs a finished check:
        // before the check runs, a null client version means
        // "not checked yet", and the check retried on failure.
        if (d != null && (widget.state.wivrnDeclined || (widget.state.wivrnSetupKnown && widget.state.wivrnClientVersion == null && _clientVersion == null))) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.view_in_ar),
              title: const Text('PC VR is off'),
              subtitle: Text(widget.state.wivrnDeclined
                  ? 'You said not now to the WiVRn app. Nothing here runs until you install it.'
                  : 'The WiVRn app is not on the headset yet. Install it and the server (bundled in this app) and the links are set up for you.'),
              trailing: FilledButton.icon(
                onPressed: _busy ? null : _install,
                icon: const Icon(Icons.download),
                label: const Text('Install WiVRn'),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (d == null)
          const Text('Checking for WiVRn...')
        else ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(label: Text(installed ? 'WiVRn ${d['kind']} $serverVersion' : 'WiVRn not installed')),
            Chip(label: Text(running ? 'Server running' : 'Server stopped')),
            Chip(label: Text(d['avahi_active'] == true ? 'Avahi on' : 'Avahi off')),
            Chip(label: Text(d['pipewire'] == true ? 'PipeWire on' : 'PipeWire off')),
            if (s?['port_listening'] == true) const Chip(label: Text('Port 9757 open')),
            if (s?['active_runtime_is_wivrn'] == true) const Chip(label: Text('Headset connected (runtime is WiVRn)')),
            if (s?['pipewire_nodes'] == true) const Chip(label: Text('WiVRn audio on')),
          ]),
          const SizedBox(height: 8),
          Text(d['note']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
          if (!installed) ...[
            const SizedBox(height: 8),
            const SelectableText(
              'flatpak install --user flathub io.github.wivrn.wivrn',
              style: TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            const Text('Install that in a terminal, then tap Refresh. The KDE runtime is already on this computer, so it is a small download.', style: TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 16),
          const SectionTitle('Server'),
          Row(children: [
            DropdownButton<String>(
              value: _encoder,
              items: const [
                DropdownMenuItem(value: 'nvenc', child: Text('NVENC (NVIDIA)')),
                DropdownMenuItem(value: 'vulkan', child: Text('Vulkan video')),
                DropdownMenuItem(value: 'vaapi', child: Text('VAAPI')),
                DropdownMenuItem(value: 'x264', child: Text('x264 (CPU)')),
              ],
              onChanged: (v) => setState(() => _encoder = v ?? 'nvenc'),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _codec,
              items: const [
                DropdownMenuItem(value: 'h265', child: Text('H.265')),
                DropdownMenuItem(value: 'h264', child: Text('H.264')),
              ],
              onChanged: (v) => setState(() => _codec = v ?? 'h265'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _busy || !installed
                  ? null
                  : () => _act(() async {
                        final r = await widget.state.backend.wivrnConfig(_encoder, _codec);
                        if (mounted) showResult(context, r.ok, r.message);
                      }),
              child: const Text('Save encoder'),
            ),
          ]),
          const Text('H.265 first, H.264 fallback. The Quest 2 cannot decode AV1 and this PC cannot encode it. Bitrate and refresh rate are set in the WiVRn app on the headset, not here. Start at 72 Hz.', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
              onPressed: _busy || !installed || running || widget.state.wivrnDeclined || (widget.state.wivrnSetupKnown && widget.state.wivrnClientVersion == null && _clientVersion == null)
                  ? null
                  : () => _act(() async {
                        final r = await widget.state.backend.wivrnStart();
                        if (mounted) showResult(context, r.ok, r.message);
                      }),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start WiVRn server'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy || !running
                  ? null
                  : () => _act(() async {
                        final r = await widget.state.backend.wivrnStop();
                        if (mounted) showResult(context, r.ok, r.message);
                      }),
              icon: const Icon(Icons.stop),
              label: const Text('Stop server'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _act(() async {}),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ]),
          const SizedBox(height: 16),
          const SectionTitle('Headset'),
          Text(
            _clientVersion == null
                ? 'No WiVRn app found on the headset yet. Install WiVRn 26.9 from the Horizon Store, or ask the app to install the matching APK.'
                : 'WiVRn app on headset: $_clientVersion. Server: ${serverVersion.isEmpty ? 'not installed' : serverVersion}. ${match ? 'Versions match, ready to connect.' : 'VERSIONS DO NOT MATCH. Update one side to $serverVersion before connecting.'}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          const Text(
            'To connect: start the server, open WiVRn on the headset, tap this computer in the server list, and enter the pairing PIN shown in the server log the first time. For USB, plug the cable in and turn Wi-Fi off on the headset.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          const SectionTitle('Server log'),
          if ((s?['log_tail'] as List?)?.isEmpty ?? true)
            const Text('No log yet. Start the server and its output shows here.', style: TextStyle(fontSize: 13))
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(
                ((s?['log_tail'] as List?) ?? []).join('\n'),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          const SizedBox(height: 16),
          const SectionTitle('First test'),
          const Text(
            'Phase 0: with the headset connected, run hello_xr -G Vulkan on this PC. Coloured cubes in the headset, and head tracking moves the view, means streaming works. Do not start with a Steam game. Steam games come next, one at a time, with the launch option PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1 %command%.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ]),
    );
  }
}
