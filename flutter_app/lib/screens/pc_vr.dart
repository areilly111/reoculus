// PC VR screen: WiVRn streaming from this computer to the headset.
// Starts and stops the wivrn-server, picks the encoder, lists the PC
// games that show in the headset launcher, and edits the WiVRn settings
// saved on the headset.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models.dart';
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
  int _bitDepth = 10;
  bool _tcpOnly = false;
  bool _busy = false;
  List<WivrnApp> _apps = [];
  WivrnClientSettings? _clientSettings;
  WivrnClientSettings? _edit;
  // SteamVR + Steam Link (experimental second runtime).
  Map<String, dynamic>? _steamvrDetect;
  Map<String, dynamic>? _steamvrStatus;
  String _runtime = 'wivrn';

  @override
  /// Loads detection, server status, headset client version, games, and
  /// headset settings when the screen opens.
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

  /// Reloads WiVRn detection, server status, the headset client version,
  /// the game list, and the headset settings. Also loads the SteamVR
  /// readiness check and this headset's runtime choice.
  Future<void> _refresh() async {
    final d = await widget.state.backend.wivrnDetect();
    final s = await widget.state.backend.wivrnStatus();
    final sd = await widget.state.backend.steamvrDetect();
    final ss = await widget.state.backend.steamvrStatus();
    String? cv;
    String runtime = 'wivrn';
    final dev = widget.state.selectedDevice;
    if (dev != null) {
      cv = await widget.state.backend.wivrnHeadsetClient(dev.serial);
      runtime = await widget.state.backend.steamvrChoice(dev.serial);
    }
    final apps = await widget.state.backend.wivrnAppsList();
    WivrnClientSettings? cs;
    if (dev != null) {
      cs = await widget.state.backend.wivrnClientSettings(dev.serial);
    }
    if (mounted) {
      setState(() {
        _detect = d;
        _status = s;
        _steamvrDetect = sd;
        _steamvrStatus = ss;
        _runtime = runtime;
        _clientVersion = cv;
        _apps = apps;
        _clientSettings = cs;
        if (cs == null) {
          _edit = null;
        } else {
          _edit ??= cs;
        }
      });
    }
  }

  /// Switches the PC VR runtime for the selected headset. Only
  /// records the choice; starting and stopping the runtimes is
  /// done from their own sections below.
  Future<void> _setRuntime(String runtime) async {
    final dev = widget.state.selectedDevice;
    if (dev == null) return;
    setState(() => _busy = true);
    final r = await widget.state.backend.steamvrSetChoice(dev.serial, runtime);
    if (mounted) {
      showResult(context, r.ok, r.message);
      setState(() => _busy = false);
    }
    await _refresh();
  }

  /// Runs a server action (start, stop, add, remove, save) with the busy
  /// spinner on, then refreshes.
  Future<void> _act(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  /// Add a game or app: pick its executable with Browse, name it,
  /// and the backend writes the WiVRn launcher entry for it.
  Future<void> _addApp() async {
    final nameCtrl = TextEditingController();
    final pathCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add game or app'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Name (as it shows in the headset)')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: pathCtrl, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Executable file'))),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await FilePicker.platform.pickFiles();
                final path = picked?.files.single.path;
                if (path != null && path.isNotEmpty) {
                  pathCtrl.text = path;
                  if (nameCtrl.text.isEmpty) {
                    nameCtrl.text = path.split('/').last.split('.').first;
                  }
                }
              },
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse'),
            ),
          ]),
          const SizedBox(height: 8),
          const Text('Pick the game or app executable, for example a Linux binary or an AppImage. It shows in the WiVRn launcher on the headset.', style: TextStyle(fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    if (result != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final path = pathCtrl.text.trim();
    if (name.isEmpty || path.isEmpty) {
      showResult(context, false, 'Give the game a name and pick its file first.');
      return;
    }
    await _act(() async {
      final r = await widget.state.backend.wivrnAppsAdd(name, path);
      if (mounted) showResult(context, r.ok, r.message);
    });
  }

  /// Removes a game from the WiVRn launcher on the headset, after
  /// confirming. The game itself stays on the computer.
  Future<void> _removeApp(WivrnApp app) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${app.name}?'),
        content: const Text('It will no longer show in the WiVRn launcher on the headset. The game itself stays on the computer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _act(() async {
      final r = await widget.state.backend.wivrnAppsRemove(app.file);
      if (mounted) showResult(context, r.ok, r.message);
    });
  }

  /// Saves the edited headset WiVRn settings to client.json on the
  /// headset. Takes effect next time WiVRn opens there.
  Future<void> _saveClientSettings() async {
    final dev = widget.state.selectedDevice;
    final e = _edit;
    if (dev == null || e == null) return;
    await _act(() async {
      final r = await widget.state.backend.wivrnClientSettingsSet(dev.serial, e);
      if (mounted) {
        showResult(context, r.ok, r.message);
        if (r.ok) _edit = null; // reload fresh on refresh
      }
    });
  }

  /// One labelled dropdown row in the headset settings.
  Widget _dropRow<T>(String label, T value, List<DropdownMenuItem<T>> items, ValueChanged<T?> onChanged) {
    return Row(children: [
      SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 13))),
      DropdownButton<T>(value: value, items: items, onChanged: _busy ? null : onChanged),
    ]);
  }

  /// One labelled switch row in the headset settings.
  Widget _switchRow(String label, String sub, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: _busy ? null : onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }

  /// The headset settings rows. The settings live on the headset
  /// (client.json), so there is nothing to edit until one is
  /// connected and WiVRn has saved its settings there once.
  List<Widget> _settingsChildren() {
    const pad = EdgeInsets.fromLTRB(16, 0, 16, 16);
    final cs = _clientSettings;
    if (cs == null) {
      return const [
        Padding(
          padding: pad,
          child: Text('Connect a headset to change its WiVRn settings. Bitrate, picture quality and the rest live on the headset, not on this computer.', style: TextStyle(fontSize: 13)),
        ),
      ];
    }
    if (!cs.available) {
      return [
        Padding(
          padding: pad,
          child: Text(cs.note, style: const TextStyle(fontSize: 13)),
        ),
      ];
    }
    final e = _edit ?? cs;
    return [
      Padding(
        padding: pad,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bitrate: ${e.bitrateMbps} Mbps', style: const TextStyle(fontSize: 13)),
          Slider(
            value: e.bitrateMbps.toDouble(),
            min: 5,
            max: 150,
            divisions: 29,
            label: '${e.bitrateMbps} Mbps',
            onChanged: _busy ? null : (v) => setState(() => _edit = e.copyWith(bitrateMbps: v.round())),
          ),
          Text('Picture quality: ${e.resolutionScale.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 13)),
          Slider(
            value: e.resolutionScale,
            min: 0.5,
            max: 2.0,
            divisions: 15,
            label: '${e.resolutionScale.toStringAsFixed(1)}x',
            onChanged: _busy ? null : (v) => setState(() => _edit = e.copyWith(resolutionScale: v)),
          ),
          _dropRow<double>(
            'Refresh rate',
            e.preferredRefreshRate,
            const [
              DropdownMenuItem(value: 0, child: Text('Auto')),
              DropdownMenuItem(value: 72, child: Text('72 Hz')),
              DropdownMenuItem(value: 80, child: Text('80 Hz')),
              DropdownMenuItem(value: 90, child: Text('90 Hz')),
              DropdownMenuItem(value: 120, child: Text('120 Hz')),
            ],
            (v) => setState(() => _edit = e.copyWith(preferredRefreshRate: v ?? 0)),
          ),
          _dropRow<String>(
            'Codec',
            e.codec,
            const [
              DropdownMenuItem(value: 'auto', child: Text('Auto')),
              DropdownMenuItem(value: 'h264', child: Text('H.264')),
              DropdownMenuItem(value: 'h265', child: Text('H.265')),
              DropdownMenuItem(value: 'av1', child: Text('AV1 (Quest 2 cannot decode it)')),
            ],
            (v) => setState(() => _edit = e.copyWith(codec: v ?? 'auto')),
          ),
          _dropRow<int>(
            'Bit depth',
            e.bitDepth,
            const [
              DropdownMenuItem(value: 8, child: Text('8-bit')),
              DropdownMenuItem(value: 10, child: Text('10-bit')),
            ],
            (v) => setState(() => _edit = e.copyWith(bitDepth: v ?? 10)),
          ),
          _switchRow('Passthrough', 'See the room around you while in VR.', e.passthroughEnabled, (v) => setState(() => _edit = e.copyWith(passthroughEnabled: v))),
          _switchRow('Foveated rendering', 'Sharp in the middle, softer at the edges. Saves speed.', e.overrideFoveationEnable, (v) => setState(() => _edit = e.copyWith(overrideFoveationEnable: v))),
          _switchRow('High power mode', 'Lets the headset run hotter for steadier speed.', e.highPowerMode, (v) => setState(() => _edit = e.copyWith(highPowerMode: v))),
          _switchRow('Forward keyboard', 'Send this computer keyboard into VR, if the server allows it.', e.forwardKeyboard, (v) => setState(() => _edit = e.copyWith(forwardKeyboard: v))),
          _switchRow('Forward mouse', 'Send this computer mouse into VR, if the server allows it.', e.forwardMouse, (v) => setState(() => _edit = e.copyWith(forwardMouse: v))),
          _switchRow('Forward gamepad', 'Send a gamepad on this computer into VR, if the server allows it.', e.forwardGamepad, (v) => setState(() => _edit = e.copyWith(forwardGamepad: v))),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _saveClientSettings,
            icon: const Icon(Icons.save),
            label: const Text('Save headset settings'),
          ),
          const SizedBox(height: 8),
          const Text('Takes effect next time you open WiVRn on the headset.', style: TextStyle(fontSize: 13)),
        ]),
      ),
    ];
  }

  /// The SteamVR + Steam Link section: readiness chips, the fix
  /// list, start/stop, and the prompt to open Steam Link on the
  /// headset once SteamVR is running.
  Widget _steamvrSection() {
    final sd = _steamvrDetect;
    final ss = _steamvrStatus;
    final running = ss?['running'] == true;
    final ready = sd?['ready'] == true;
    final issues = (sd?['issues'] as List?) ?? [];
    final version = (sd?['steamvr_version'] ?? '').toString();
    final branch = (sd?['steamvr_branch'] ?? '').toString();
    final driver = (sd?['nvidia_driver'] ?? '').toString();
    final kind = (sd?['steam_kind'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('SteamVR + Steam Link (experimental)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 8),
          const Text("ReOculus starts SteamVR on this computer. You connect with the free Steam Link app on the headset. SteamVR is Valve's own runtime: it comes from Steam, ReOculus never installs or changes it.", style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          if (sd == null)
            const Text('Checking SteamVR...')
          else ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              Chip(label: Text(kind == 'native' ? 'Native Steam' : kind == 'flatpak' ? 'Flatpak Steam' : 'Steam not found')),
              Chip(label: Text(sd['steamvr_present'] == true ? 'SteamVR $version ($branch)' : 'SteamVR not installed')),
              Chip(label: Text(driver.isEmpty ? 'NVIDIA driver unknown' : 'NVIDIA $driver')),
              if (sd['wivrn_running'] == true) const Chip(label: Text('WiVRn running')),
              if (running) const Chip(label: Text('SteamVR running')),
            ]),
            const SizedBox(height: 8),
            if (issues.isNotEmpty) ...[
              for (final issue in issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text(issue.toString(), style: const TextStyle(fontSize: 13))),
                  ]),
                ),
              const SizedBox(height: 4),
            ],
            Text(sd['note']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            if (running) ...[
              const Text('SteamVR is running. Open Steam Link on the Quest and connect to this PC.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
            ],
            Row(children: [
              FilledButton.icon(
                onPressed: _busy || !ready || running
                    ? null
                    : () => _act(() async {
                          final r = await widget.state.backend.steamvrStart();
                          if (mounted) showResult(context, r.ok, r.message);
                        }),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start SteamVR'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy || !running
                    ? null
                    : () => _act(() async {
                          final r = await widget.state.backend.steamvrStop();
                          if (mounted) showResult(context, r.ok, r.message);
                        }),
                icon: const Icon(Icons.stop),
                label: const Text('Stop SteamVR'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _act(() async {}),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  @override
  /// Builds the PC VR page: server status chips, encoder, headset,
  /// games, settings, log, and first test.
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
        const SectionTitleWithInfo('PC VR', infoTitle: 'PC VR', infoBody: 'PC VR streams games from this computer to the headset, over Wi-Fi or USB. WiVRn 26.9 is the default runtime: the server on this computer and the WiVRn app on the headset must be the same version (26.9). SteamVR + Steam Link is an experimental second runtime: ReOculus starts SteamVR on this computer and you connect with the free Steam Link app on the headset. The games themselves run on the PC, the headset just shows them.'),
        const Text(
          'Streams PC VR games from this computer to your Quest 2 over Wi-Fi or USB. WiVRn 26.9 is the default runtime. SteamVR + Steam Link is an experimental second runtime: ReOculus starts SteamVR, you connect with the Steam Link app on the headset.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('PC VR runtime', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 4),
              const Text('Which runtime streams PC VR to this headset. WiVRn is the default. SteamVR + Steam Link is experimental and saved per headset.', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: const Text('WiVRn (default)'),
                  selected: _runtime != 'steamvr',
                  onSelected: _busy ? null : (v) { if (v) _setRuntime('wivrn'); },
                ),
                ChoiceChip(
                  label: const Text('SteamVR + Steam Link (experimental)'),
                  selected: _runtime == 'steamvr',
                  onSelected: _busy ? null : (v) { if (v) _setRuntime('steamvr'); },
                ),
              ]),
              if (widget.state.selectedDevice == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Connect a headset first: the runtime choice is saved per headset.', style: TextStyle(fontSize: 13)),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        // Refused or not installed yet: the whole section is
        // greyed out except an Install button that reopens setup.
        // The "not installed" branch needs a finished check:
        // before the check runs, a null client version means
        // "not checked yet", and the check retried on failure.
        if (_runtime != 'steamvr' && d != null && (widget.state.wivrnDeclined || (widget.state.wivrnSetupKnown && widget.state.wivrnClientVersion == null && _clientVersion == null))) ...[
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
        if (_runtime == 'steamvr') ...[
          _steamvrSection(),
        ] else if (d == null)
          const Text('Checking for WiVRn...')
        else ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(label: Text(installed ? 'WiVRn ${d['kind']} $serverVersion' : 'WiVRn not installed')),
            Chip(label: Text(running ? 'Server running' : 'Server stopped')),
            Chip(label: Text(d['avahi_active'] == true ? 'Avahi on' : 'Avahi off')),
            Chip(label: Text(d['pipewire'] == true ? 'PipeWire on' : 'PipeWire off')),
            // 9757 is WiVRn's default server port.
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
          CardGrid(cards: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Expanded(child: Text('Server', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                    InfoButton('Server', 'The encoder turns the game picture into video to send to the headset. NVENC uses the NVIDIA card and is the best choice on this PC. The codec is the video format: H.265 is smaller and looks better, H.264 is the fallback. The Quest 2 cannot decode AV1. Bitrate and refresh rate are set in the WiVRn app on the headset, not here. Start at 72 Hz.'),
                  ]),
                  const SizedBox(height: 8),
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
                                final r = await widget.state.backend.wivrnConfig(_encoder, _codec, bitDepth: _bitDepth, tcpOnly: _tcpOnly);
                                if (mounted) showResult(context, r.ok, r.message);
                              }),
                      child: const Text('Save encoder'),
                    ),
                  ]),
                  const Text('H.265 first, H.264 fallback. The Quest 2 cannot decode AV1 and this PC cannot encode it. Bitrate and refresh rate are set in the WiVRn app on the headset, not here. Start at 72 Hz.', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('Bit depth'),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _bitDepth,
                      items: const [
                        DropdownMenuItem(value: 8, child: Text('8-bit')),
                        DropdownMenuItem(value: 10, child: Text('10-bit')),
                      ],
                      onChanged: (v) => setState(() => _bitDepth = v ?? 10),
                    ),
                    const SizedBox(width: 16),
                    const Text('TCP only'),
                    Switch(
                      value: _tcpOnly,
                      onChanged: (v) => setState(() => _tcpOnly = v),
                    ),
                  ]),
                  const Text('10-bit looks better on the Quest 2. TCP only helps on flaky Wi-Fi, at some cost to latency.', style: TextStyle(fontSize: 13)),
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
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Headset', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 8),
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
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Card(
            child: ExpansionTile(
              title: const Text('PC Games/Apps', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              subtitle: Text(_apps.isEmpty
                  ? 'No games added yet. They show in the WiVRn launcher on the headset.'
                  : '${_apps.length} ${_apps.length == 1 ? 'game' : 'games'} added. They show in the WiVRn launcher on the headset.'),
              children: [
                ..._apps.map((a) => ListTile(
                      title: Text(a.name),
                      subtitle: Text(a.exec, style: const TextStyle(fontSize: 12)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        tooltip: 'Remove from the headset launcher',
                        onPressed: _busy ? null : () => _removeApp(a),
                      ),
                    )),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('If a new game does not show up in the headset yet, restart the server.', style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _addApp,
                      icon: const Icon(Icons.add),
                      label: const Text('Add game or app'),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ExpansionTile(
              title: const Text('WiVRn settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              subtitle: const Text('Bitrate, picture quality and more, on the headset and the server.'),
              children: _settingsChildren(),
            ),
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
            'Phase 0: with the headset connected, run hello_xr -G Vulkan on this PC. Coloured cubes in the headset, and head tracking moves the view, means streaming works. Add games below in PC Games/Apps. Steam games need the launch option PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1 %command% set in Steam.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ]),
    );
  }
}
