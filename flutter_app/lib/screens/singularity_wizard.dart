import 'package:flutter/material.dart';
import '../models.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

// Singularity install wizard: guided rooting for a Quest 2.
//
// Singularity is closed source and never bundled: the wizard
// downloads the author's latest release from GitHub at the user's
// request, checks it, and installs it. The rooting itself happens
// in Singularity's own UI on the headset, with the user watching;
// this screen only prepares, checks, and verifies.
//
// Steps: 1 preflight checks, 2 back up the headset, 3 download
// Singularity, 4 install it on the headset, 5 root in the headset
// and verify. A step only opens when the one before it is done.
class SingularityWizardScreen extends StatefulWidget {
  final AppState state;
  const SingularityWizardScreen({required this.state, super.key});
  @override
  State<SingularityWizardScreen> createState() => _SingularityWizardScreenState();
}

class _SingularityWizardScreenState extends State<SingularityWizardScreen> {
  int _step = 0;
  SingularityPreflight? _preflight;
  bool _backupDone = false;
  Map<String, dynamic>? _download;
  bool _installDone = false;
  bool _verified = false;
  bool _busy = false;
  String? _error;

  String get _serial => widget.state.selectedDevice?.serial ?? '';

  Future<void> _runPreflight() async {
    setState(() { _busy = true; _error = null; });
    try {
      _preflight = await widget.state.backend.singularityPreflight(_serial);
      if (_preflight?.ready == true) setState(() => _step = 1);
    } catch (e) {
      _error = 'Checks failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runBackup() async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.state.backend.deviceBackup(_serial);
      if (r.ok) {
        _backupDone = true;
        widget.state.log('Wizard backup done before Singularity.');
        setState(() => _step = 2);
      } else {
        _error = r.message;
      }
    } catch (e) {
      _error = 'Backup failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runDownload() async {
    setState(() { _busy = true; _error = null; });
    try {
      final j = await widget.state.backend.singularityDownload();
      if (j['ok'] == true) {
        _download = j;
        setState(() => _step = 3);
      } else {
        _error = (j['error'] ?? 'Download failed.').toString();
      }
    } catch (e) {
      _error = 'Download failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runInstall() async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.state.backend.singularityInstall(_serial);
      if (r.ok) {
        _installDone = true;
        setState(() => _step = 4);
      } else {
        _error = r.message;
      }
    } catch (e) {
      _error = 'Install failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runVerify() async {
    setState(() { _busy = true; _error = null; });
    try {
      final root = await widget.state.backend.singularityVerify(_serial);
      if (root.rooted) {
        _verified = true;
        widget.state.log('Singularity root verified (${root.method}).');
        await widget.state.loadRooted();
      } else {
        _error = 'Root is not on yet. Press Root Now in Singularity on the headset and let it finish, then try again.';
      }
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void initState() {
    super.initState();
    _runPreflight();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      appBar: AppBar(title: const Text('Install Singularity (root wizard)')),
      body: s.selectedDevice == null
          ? const Padding(padding: EdgeInsets.all(20), child: Text('Connect a headset first, then open the wizard.'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Singularity roots the Quest 2 so its support can be kept alive after Meta stops updating it. Nothing here roots anything by itself: you press Root Now on the headset, in Singularity, and this wizard only checks, backs up, downloads, installs, and verifies. Singularity is closed source; it is downloaded from the author\u2019s GitHub release, never bundled with this app.'),
                const SizedBox(height: 8),
                const Text('Before you start: charge the headset past 50%, and do not unplug it or turn it off while Singularity is working.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Card(color: Colors.orange.shade100, child: ListTile(leading: const Icon(Icons.warning, color: Colors.black87), title: Text(_error!, style: const TextStyle(color: Colors.black87)))),
                  const SizedBox(height: 12),
                ],
                Stepper(
                  currentStep: _step,
                  onStepTapped: (i) {
                    if (i == 0 || (i == 1 && _preflight?.ready == true) || (i == 2 && _backupDone) || (i == 3 && _download != null) || (i == 4 && _installDone)) {
                      setState(() => _step = i);
                    }
                  },
                  controlsBuilder: (context, details) => const SizedBox.shrink(),
                  steps: [
                    Step(
                      title: const Text('1. Check the headset is ready'),
                      subtitle: const Text('Quest 2, battery, not already rooted, free space.'),
                      isActive: _step == 0,
                      state: _preflight?.ready == true ? StepState.complete : StepState.indexed,
                      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_preflight == null)
                          const Text('Running checks\u2026')
                        else ...[
                          ..._preflight!.checks.map((c) => ListTile(
                                leading: Icon(c.ok ? Icons.check_circle : Icons.cancel, color: c.ok ? Colors.green : Colors.red),
                                title: Text(c.name),
                                subtitle: Text(c.detail),
                              )),
                          Text(_preflight!.summary, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runPreflight,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Run checks again'),
                        ),
                      ]),
                    ),
                    Step(
                      title: const Text('2. Back up the headset'),
                      subtitle: const Text('Settings, Guardian data, Wi-Fi configs, app list. Do this first: rooting can go wrong.'),
                      isActive: _step == 1,
                      state: _backupDone ? StepState.complete : StepState.indexed,
                      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_backupDone) const Text('Backed up. The backup is in the library under Device backups.'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runBackup,
                          icon: const Icon(Icons.backup),
                          label: Text(_backupDone ? 'Back up again' : 'Back up this headset now'),
                        ),
                      ]),
                    ),
                    Step(
                      title: const Text('3. Download Singularity'),
                      subtitle: const Text('The latest release from the author\u2019s GitHub, checked before it is installed.'),
                      isActive: _step == 2,
                      state: _download != null ? StepState.complete : StepState.indexed,
                      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_download != null) ...[
                          Text('Version: ${_download!['version'] ?? 'unknown'}'),
                          Text('Package: ${_download!['package'] ?? 'unknown'}'),
                          Text('Size: ${formatBytes((_download!['size_bytes'] is num) ? (_download!['size_bytes'] as num).toInt() : 0)}'),
                          Text('SHA-256: ${(_download!['sha256'] ?? '').toString()}'),
                          Text('Check: ${_download!['verification'] ?? ''}'),
                        ],
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runDownload,
                          icon: const Icon(Icons.download),
                          label: Text(_download != null ? 'Download again' : 'Download the latest release'),
                        ),
                      ]),
                    ),
                    Step(
                      title: const Text('4. Install it on the headset'),
                      subtitle: const Text('A normal app install over ADB. Nothing is rooted yet.'),
                      isActive: _step == 3,
                      state: _installDone ? StepState.complete : StepState.indexed,
                      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_installDone) const Text('Singularity is on the headset.'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runInstall,
                          icon: const Icon(Icons.install_mobile),
                          label: const Text('Install Singularity on the headset'),
                        ),
                      ]),
                    ),
                    Step(
                      title: const Text('5. Root on the headset, then verify'),
                      subtitle: const Text('You press Root Now in Singularity. This only checks the result.'),
                      isActive: _step == 4,
                      state: _verified ? StepState.complete : StepState.indexed,
                      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('1. Put the headset on and open Singularity.\n2. Press Root Now and let it finish. The headset may restart; that is normal.\n3. When it is done, come back here and tap Verify root.'),
                        const SizedBox(height: 8),
                        if (_verified) const Text('Root verified. This headset is rooted, and the Rooted settings in Device and Settings are now open.', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runVerify,
                          icon: const Icon(Icons.verified),
                          label: const Text('Verify root'),
                        ),
                      ]),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_verified)
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.check),
                    label: const Text('Done, back to Device and Settings'),
                  ),
              ]),
            ),
    );
  }
}
