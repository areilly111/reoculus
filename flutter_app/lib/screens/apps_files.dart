import 'dart:io';
import 'package:flutter/material.dart';
import '../models.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

// ---- Apps -----------------------------------------------------------------
// Two tabs: Apps (installed on the headset, with sizes) and Library
// (app backups, save backups and imported APKs, all in the one
// library folder on this computer).
class AppsScreen extends StatefulWidget {
  final AppState state;
  const AppsScreen({required this.state, super.key});
  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  List<QuestApp> _apps = [];
  List<LibraryEntry> _library = [];
  bool _loading = true;
  bool _thirdPartyOnly = true;
  String _query = '';
  int _tab = 0; // 0 = Apps, 1 = Library
  double? _progress; // install/backup in progress
  String _progressLabel = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    _apps = await widget.state.backend.listApps(serial, thirdPartyOnly: _thirdPartyOnly, withIcons: true, withSizes: true);
    _library = await widget.state.backend.listLibrary();
    setState(() => _loading = false);
  }

  List<QuestApp> get _filtered => _apps.where((a) => _query.isEmpty || a.label.toLowerCase().contains(_query.toLowerCase()) || a.package.toLowerCase().contains(_query.toLowerCase())).toList();

  Future<void> _install() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final path = await pathDialog(context, title: 'Install an app', hint: 'Pick an APK file on this computer. For split apps, pick a .apks or .xapk file instead and it will be installed in one go.', extensions: const ['apk', 'apks', 'xapk']);
    if (path == null || path.isEmpty) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Before you install'),
        content: Text('File: $path\n\nOnly install apps you own or that the developer gives away freely. This app never uploads the file anywhere.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Install')),
        ],
      ),
    );
    if (proceed != true) return;
    setState(() {
      _progress = 0.2;
      _progressLabel = 'Installing... please wait.';
    });
    final r = await widget.state.backend.installApk(serial, path);
    setState(() => _progress = null);
    if (!mounted) return;
    showResult(context, r.ok, r.message);
    widget.state.log('Install: ${r.ok ? path.split('/').last : r.message}');
    await _load();
  }

  Future<void> _importApk() async {
    final path = await pathDialog(context, title: 'Import an APK into the library', hint: 'Pick an APK, .apks or .xapk file on this computer. It is copied into the library folder, so you can install it later without the original file.', extensions: const ['apk', 'apks', 'xapk']);
    if (path == null || path.isEmpty) return;
    final e = await widget.state.backend.importApk(path);
    if (!mounted) return;
    showResult(context, e != null, e == null ? 'Could not import that file.' : 'Imported ${e.label} ${e.version} into the library.');
    await _load();
  }

  String _sizeText(QuestApp a) {
    final parts = <String>[];
    if (a.apkSizeBytes != null) parts.add('APK ${formatBytes(a.apkSizeBytes!)}');
    if (a.totalSizeBytes != null && a.totalSizeBytes != a.apkSizeBytes) parts.add('Total ${formatBytes(a.totalSizeBytes!)}');
    return parts.join('  •  ');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Apps', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          FilledButton.icon(onPressed: _install, icon: const Icon(Icons.file_download), label: const Text('Install APK')),
        ]),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Apps')),
            ButtonSegment(value: 1, label: Text('Library')),
          ],
          selected: {_tab},
          onSelectionChanged: (v) => setState(() => _tab = v.first),
        ),
        const SizedBox(height: 12),
        if (_tab == 0) ...[
          Row(children: [
            Expanded(child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search apps by name', border: OutlineInputBorder()), onChanged: (v) => setState(() => _query = v))),
            const SizedBox(width: 12),
            FilterChip(label: const Text('My apps only'), selected: _thirdPartyOnly, onSelected: (v) { setState(() => _thirdPartyOnly = v); _load(); }),
            const SizedBox(width: 8),
            FilterChip(label: const Text('Show system apps'), selected: !_thirdPartyOnly, onSelected: (v) { setState(() => _thirdPartyOnly = !v); _load(); }),
            const SizedBox(width: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.view_list), label: Text('List')),
                ButtonSegment(value: true, icon: Icon(Icons.grid_view), label: Text('Tiles')),
              ],
              selected: {widget.state.appsTiles},
              onSelectionChanged: (v) => widget.state.setAppsTiles(v.first),
            ),
          ]),
          if (_progress != null) ...[const SizedBox(height: 12), LinearProgressIndicator(value: _progress), Text(_progressLabel)],
          const SizedBox(height: 12),
          Expanded(
            child: widget.state.selectedDevice == null
                ? const EmptyState(icon: Icons.headset_off, title: 'No headset connected', body: 'Connect your Quest 2 from Home or Devices to see its apps. Nothing here is sample data.')
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _filtered.isEmpty
                        ? const EmptyState(icon: Icons.apps, title: 'No apps match', body: 'Try a different search, or turn off "My apps only" to see system apps.')
                        : widget.state.appsTiles
                            ? GridView.builder(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.78),
                                itemCount: _filtered.length,
                                itemBuilder: (c, i) {
                                  final a = _filtered[i];
                                  return Card(
                                    clipBehavior: Clip.antiAlias,
                                    child: Builder(
                                      builder: (tileCtx) => InkWell(
                                      onTap: () => _showAppMenuAt(tileCtx, a),
                                      borderRadius: BorderRadius.circular(16),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                          Center(
                                            child: AppIconTile(
                                              state: widget.state,
                                              app: a,
                                              size: 64,
                                              onIcon: (icon) {
                                                if (icon.label.isNotEmpty && icon.label != a.label) {
                                                  final idx = _apps.indexWhere((x) => x.package == a.package);
                                                  if (idx >= 0 && mounted) {
                                                    setState(() => _apps[idx] = _apps[idx].copyWith(label: icon.label, iconPath: icon.iconPath));
                                                  }
                                                }
                                              },
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(a.label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                                          Text(a.package, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          Text('Version ${a.version}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          if (_sizeText(a).isNotEmpty) Text(_sizeText(a), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          const Spacer(),
                                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            IconButton(icon: const Icon(Icons.play_arrow), tooltip: 'Launch', onPressed: () async {
                                              final r = await widget.state.backend.launchApp(widget.state.selectedDevice!.serial, a.package);
                                              if (mounted) showResult(context, r.ok, r.message);
                                            }),
                                            _appMenuButton(a),
                                          ]),
                                        ]),
                                      ),
                                    ),
                                  ),
                                );
                                },
                              )
                            : ListView.builder(
                            itemCount: _filtered.length,
                            itemBuilder: (c, i) {
                              final a = _filtered[i];
                              return Card(
                                child: Builder(
                                  builder: (tileCtx) => ListTile(
                                  leading: AppIconTile(
                                    state: widget.state,
                                    app: a,
                                    size: 40,
                                    onIcon: (icon) {
                                      if (icon.label.isNotEmpty && icon.label != a.label) {
                                        final idx = _apps.indexWhere((x) => x.package == a.package);
                                        if (idx >= 0 && mounted) {
                                          setState(() => _apps[idx] = _apps[idx].copyWith(label: icon.label, iconPath: icon.iconPath));
                                        }
                                      }
                                    },
                                  ),
                                  title: Text(a.label),
                                  subtitle: Text('${a.package}\nVersion ${a.version}${_sizeText(a).isNotEmpty ? '  •  ${_sizeText(a)}' : ''}'),
                                  isThreeLine: true,
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(icon: const Icon(Icons.play_arrow), tooltip: 'Launch', onPressed: () async {
                                      final r = await widget.state.backend.launchApp(widget.state.selectedDevice!.serial, a.package);
                                      if (mounted) showResult(context, r.ok, r.message);
                                    }),
                                    _appMenuButton(a),
                                  ]),
                                  onTap: () => _showAppMenuAt(tileCtx, a),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ] else
          Expanded(child: _buildLibrary()),
      ]),
    );
  }

  Widget _buildLibrary() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('One folder on this computer holds every backup and imported APK. Delete here only deletes local files, never anything on the headset.')),
        const SizedBox(width: 12),
        OutlinedButton.icon(onPressed: _importApk, icon: const Icon(Icons.add), label: const Text('Import APK')),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: _library.isEmpty
            ? const EmptyState(icon: Icons.folder_copy, title: 'Library is empty', body: 'Back up an app, or import an APK, and it will show up here.')
            : ListView.builder(
                itemCount: _library.length,
                itemBuilder: (c, i) {
                  final e = _library[i];
                  final kindLabel = e.kind == 'save' ? 'Save backup' : e.kind == 'apk' ? 'Imported APK' : 'App backup';
                  return Card(
                    child: ListTile(
                      leading: Icon(e.kind == 'save' ? Icons.save : e.kind == 'apk' ? Icons.file_present : Icons.backup, size: 32),
                      title: Text('${e.label} ${e.version}'),
                      subtitle: Text('$kindLabel  •  ${e.package}\n${e.dateAdded}  •  ${formatBytes(e.sizeBytes)}${e.hasData ? '  •  includes app data' : ''}'),
                      isThreeLine: true,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (e.kind == 'apk')
                          TextButton(
                            onPressed: () async {
                              final serial = widget.state.selectedDevice?.serial;
                              if (serial == null) return;
                              final r = await widget.state.backend.installApk(serial, e.path);
                              if (mounted) showResult(context, r.ok, r.message);
                            },
                            child: const Text('Install'),
                          ),
                        if (e.kind != 'apk')
                          TextButton(
                            onPressed: () => _restoreLibraryEntry(e),
                            child: const Text('Restore'),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete from this computer',
                          onPressed: () async {
                            final yes = await confirmDialog(context, title: 'Delete ${e.label}?', body: 'This deletes the backup from this computer only. The app on the headset is not touched.', confirmLabel: 'Delete', destructive: true);
                            if (!yes) return;
                            final r = await widget.state.backend.deleteLibraryEntry(e.path);
                            if (mounted) showResult(context, r.ok, r.message);
                            await _load();
                          },
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _restoreLibraryEntry(LibraryEntry e) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final isSave = e.kind == 'save';
    // Dry run first, so the user sees what would happen.
    final dry = isSave
        ? await widget.state.backend.saveRestore(serial, e.path, dryRun: true)
        : await widget.state.backend.restoreBackup(serial, e.path, dryRun: true);
    if (dry == null || !mounted) return;
    final lines = dry.steps.map((st) => '• ${st.item}: ${st.message}').join('\n');
    final includeData = !isSave &&
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Restore app data too?'),
            content: const Text('Only tick this if the backup has app data and you want the app\'s saved data put back. It overwrites the app\'s current data, and it needs root.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('APK only')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore data too')),
            ],
          ),
        ) ==
            true;
    final yes = await confirmDialog(
      context,
      title: 'Restore ${e.label}?',
      body: 'This reinstalls the app on the headset${isSave ? ' and overwrites its current saves' : ''}.\n\n$lines',
      confirmLabel: 'Restore',
      destructive: true,
    );
    if (!yes) return;
    final r = isSave
        ? await widget.state.backend.saveRestore(serial, e.path, confirm: true)
        : await widget.state.backend.restoreBackup(serial, e.path, includeData: includeData, confirm: true);
    if (mounted) {
      showResult(context, r?.ok ?? false, r == null ? 'Restore failed.' : r.steps.map((st) => '${st.item}: ${st.message}').join('\n'));
    }
    await _load();
  }


  /// Menu entries for one app. Used by the three-dot button
  /// (PopupMenuButton anchors it to the button) and by a row tap
  /// (anchored to the row's right edge).
  List<PopupMenuEntry<String>> _appMenuItems(QuestApp a) => [
        const PopupMenuItem(value: 'info', child: Text('Info')),
        const PopupMenuItem(value: 'backup', child: Text('Backup app')),
        const PopupMenuItem(value: 'save', child: Text('Backup save')),
        const PopupMenuItem(value: 'restore', child: Text('Restore backup')),
        const PopupMenuItem(value: 'force_stop', child: Text('Force stop')),
        const PopupMenuItem(value: 'clear_data', child: Text('Clear data')),
        if (a.system && widget.state.rootStatus?.rooted == true)
          const PopupMenuItem(value: 'remove_system', child: Text('Remove system app')),
        const PopupMenuItem(value: 'uninstall', child: Text('Uninstall')),
      ];

  /// The three-dot button: PopupMenuButton anchors the dropdown to
  /// the button itself, so it always opens in the right place.
  Widget _appMenuButton(QuestApp a) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        tooltip: 'More actions',
        itemBuilder: (_) => _appMenuItems(a),
        onSelected: (value) => _doAppAction(a, value),
      );

  /// Row tap: open the same menu, anchored to the row's right edge
  /// (above the three-dot button), never at the tap point.
  Future<void> _showAppMenuAt(BuildContext ctx, QuestApp a) async {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = MediaQuery.sizeOf(ctx);
    final value = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.right - 200, rect.top + 8, 0, 0),
        Offset.zero & screen,
      ),
      items: _appMenuItems(a),
    );
    if (value == null || !mounted) return;
    await _doAppAction(a, value);
  }

  Future<void> _doAppAction(QuestApp a, String action) async {
    final serial = widget.state.selectedDevice?.serial ?? '';
    switch (action) {
      case 'info':
        _showAppDetail(a);
        return;
      case 'backup':
        final rep = await widget.state.backend.backupApp(serial, a.package, skipData: !widget.state.backupDataByDefault);
        if (mounted) showResult(context, rep != null, rep == null ? 'Backup failed.' : 'Backed up ${rep.label} to ${rep.path} (${formatBytes(rep.totalSizeBytes)}).');
        await _load();
        return;
      case 'save':
        final rep = await widget.state.backend.saveBackup(serial, a.package);
        if (mounted) showResult(context, rep != null, rep == null ? 'Save backup failed: nothing readable to back up.' : 'Saved ${rep.label} saves to ${rep.path} (${formatBytes(rep.totalSizeBytes)}).');
        await _load();
        return;
      case 'restore':
        await _pickRestoreBackup(a);
        return;
      case 'force_stop':
        final r = await widget.state.backend.forceStopApp(serial, a.package);
        if (mounted) showResult(context, r.ok, r.message);
        return;
      case 'clear_data':
        final yes = await confirmDialog(context, title: 'Clear app data?', body: 'This deletes the app\'s saved data and settings. The app itself stays installed. This cannot be undone.', confirmLabel: 'Clear data', destructive: true);
        if (!yes) return;
        final r = await widget.state.backend.clearAppData(serial, a.package);
        if (mounted) showResult(context, r.ok, r.message);
        return;
      case 'remove_system':
        final yes = await confirmDialog(context, title: 'Remove system app ${a.label}?', body: 'This fully removes a system app. It needs root, and the app can only come back by reinstalling it. This cannot be undone from here.', confirmLabel: 'Remove system app', destructive: true);
        if (!yes) return;
        final r = await widget.state.backend.uninstallSystemApp(serial, a.package);
        if (mounted) showResult(context, r.ok, r.message);
        await _load();
        return;
      case 'uninstall':
        final keep = await showDialog<bool>(
          context: context,
          builder: (cc) => AlertDialog(
            title: Text('Remove ${a.label}?'),
            content: const Text('The app will be removed from the headset.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Keep it')),
              FilledButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Remove')),
              FilledButton(onPressed: () => Navigator.pop(cc, true), child: const Text('Remove, keep saved data')),
            ],
          ),
        );
        if (keep == null) return;
        final r = await widget.state.backend.uninstallApp(serial, a.package, keepData: keep);
        if (mounted) showResult(context, r.ok, r.message);
        await _load();
        return;
    }
  }

  /// Pick one of this app's backups from the library to restore.
  Future<void> _pickRestoreBackup(QuestApp a) async {
    final backups = _library.where((e) => e.package == a.package && e.kind != 'apk').toList();
    if (backups.isEmpty) {
      if (mounted) showResult(context, false, 'No backup for ${a.label} yet. Back it up first, then it shows up here to restore.');
      return;
    }
    final picked = await showDialog<LibraryEntry>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Restore ${a.label}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: backups.length,
            itemBuilder: (cc, i) {
              final e = backups[i];
              final kindLabel = e.kind == 'save' ? 'Save backup' : 'App backup';
              return ListTile(
                title: Text('$kindLabel  •  ${e.dateAdded}'),
                subtitle: Text('${formatBytes(e.sizeBytes)}${e.hasData ? '  •  includes app data' : ''}'),
                onTap: () => Navigator.pop(c, e),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
      ),
    );
    if (picked != null) await _restoreLibraryEntry(picked);
  }

  void _showAppDetail(QuestApp a) {
    final serial = widget.state.selectedDevice?.serial ?? '';
    final state = widget.state;
    showDialog(
      context: context,
      builder: (c) => _AppDetailDialog(app: a, serial: serial, state: state, onChanged: _load, showResult: (ok, msg) {
        if (mounted) showResult(context, ok, msg);
      }),
    );
  }
}

// ---- App detail dialog (loads details lazily) -----------------------------
class _AppDetailDialog extends StatefulWidget {
  final QuestApp app;
  final String serial;
  final AppState state;
  final Future<void> Function() onChanged;
  final void Function(bool ok, String message) showResult;
  const _AppDetailDialog({required this.app, required this.serial, required this.state, required this.onChanged, required this.showResult});
  @override
  State<_AppDetailDialog> createState() => _AppDetailDialogState();
}

class _AppDetailDialogState extends State<_AppDetailDialog> {
  AppDetails? _details;
  bool _loadingDetails = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    final d = await widget.state.backend.appDetails(widget.serial, widget.app.package);
    if (mounted) {
      setState(() {
        _details = d;
        _loadingDetails = false;
      });
    }
  }

  String _bytes(int? v) => v == null ? 'Unknown' : formatBytes(v);

  @override
  Widget build(BuildContext context) {
    final a = widget.app;
    final d = _details;
    return AlertDialog(
      title: Text(a.label),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            AppIconTile(state: widget.state, app: a, size: 72),
            const SizedBox(width: 12),
            Expanded(child: Text(a.label, style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 12),
          if (_loadingDetails)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else if (d != null) ...[
            Text('Package: ${d.package}'),
            Text('Version: ${d.version}${d.versionCode != null ? ' (${d.versionCode})' : ''}'),
            const Text('Maker: not stored in the APK'),
            Text('APK size: ${_bytes(d.apkSizeBytes)}'),
            Text('App data: ${_bytes(d.dataSizeBytes)}${d.dataSizeNote != null ? ' (${d.dataSizeNote})' : ''}'),
            Text('OBB: ${_bytes(d.obbSizeBytes)}${d.obbFiles.isNotEmpty ? ' (${d.obbFiles.where((f) => f.endsWith('.obb')).length} .obb file(s))' : ''}'),
            Text('Total: ${_bytes(d.totalSizeBytes)}'),
            if (d.minSdk != null || d.targetSdk != null) Text('SDK: min ${d.minSdk ?? '?'} / target ${d.targetSdk ?? '?'}'),
            if (d.firstInstallTime != null) Text('Installed: ${d.firstInstallTime}'),
            if (d.lastUpdateTime != null) Text('Updated: ${d.lastUpdateTime}'),
            if (d.installer != null) Text('Installed from: ${d.installer}'),
            Text(a.system ? 'System app (came with the headset)' : 'App you installed'),
            const SizedBox(height: 12),
            const Text('Permissions:', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(d.permissions.isEmpty ? 'None listed.' : d.permissions.join(', ')),
          ] else ...[
            Text('Package: ${a.package}'),
            Text('Version: ${a.version}'),
            if (a.totalSizeBytes != null) Text('Total size: ${formatBytes(a.totalSizeBytes!)}'),
            Text(a.system ? 'System app (came with the headset)' : 'App you installed'),
            const Text('Could not read the full details for this app.'),
          ],
          const SizedBox(height: 12),
          const Text('Sideloaded apps appear in the headset under Unknown Sources.', style: TextStyle(fontSize: 13)),
          if (_busy) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  final rep = await widget.state.backend.backupApp(widget.serial, a.package, skipData: !widget.state.backupDataByDefault);
                  setState(() => _busy = false);
                  if (!mounted) return;
                  Navigator.pop(context);
                  widget.showResult(rep != null, rep == null ? 'Backup failed.' : 'Backed up ${rep.label} to ${rep.path} (${formatBytes(rep.totalSizeBytes)}).');
                  widget.state.log('Backup: ${a.label}');
                  await widget.onChanged();
                },
          child: const Text('Backup app'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  final rep = await widget.state.backend.saveBackup(widget.serial, a.package);
                  setState(() => _busy = false);
                  if (!mounted) return;
                  Navigator.pop(context);
                  widget.showResult(rep != null, rep == null ? 'Save backup failed: nothing readable to back up.' : 'Saved ${rep.label} saves to ${rep.path} (${formatBytes(rep.totalSizeBytes)}).');
                  widget.state.log('Save backup: ${a.label}');
                  await widget.onChanged();
                },
          child: const Text('Backup save'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            final r = await widget.state.backend.forceStopApp(widget.serial, a.package);
            if (mounted) widget.showResult(r.ok, r.message);
          },
          child: const Text('Force stop'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            final yes = await confirmDialog(context, title: 'Clear app data?', body: 'This deletes the app\'s saved data and settings. The app itself stays installed. This cannot be undone.', confirmLabel: 'Clear data', destructive: true);
            if (!yes) return;
            final r = await widget.state.backend.clearAppData(widget.serial, a.package);
            if (mounted) widget.showResult(r.ok, r.message);
          },
          child: const Text('Clear data'),
        ),
        if (a.system && widget.state.rootStatus?.rooted == true)
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final yes = await confirmDialog(context, title: 'Remove system app ${a.label}?', body: 'This fully removes a system app. It needs root, and the app can only come back by reinstalling it. This cannot be undone from here.', confirmLabel: 'Remove system app', destructive: true);
              if (!yes) return;
              final r = await widget.state.backend.uninstallSystemApp(widget.serial, a.package);
              if (mounted) widget.showResult(r.ok, r.message);
              await widget.onChanged();
            },
            child: const Text('Remove system app'),
          ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () async {
            Navigator.pop(context);
            final keep = await showDialog<bool>(
              context: context,
              builder: (cc) => AlertDialog(
                title: Text('Remove ${a.label}?'),
                content: const Text('The app will be removed from the headset.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Keep it')),
                  FilledButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Remove')),
                  FilledButton(onPressed: () => Navigator.pop(cc, true), child: const Text('Remove, keep saved data')),
                ],
              ),
            );
            if (keep == null) return;
            final r = await widget.state.backend.uninstallApp(widget.serial, a.package, keepData: keep);
            if (mounted) widget.showResult(r.ok, r.message);
            widget.state.log('Removed ${a.label}');
            await widget.onChanged();
          },
          child: const Text('Uninstall'),
        ),
      ],
    );
  }
}

// ---- Files ----------------------------------------------------------------
class FilesScreen extends StatefulWidget {
  final AppState state;
  const FilesScreen({required this.state, super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String _path = '/sdcard/';
  List<QuestFile> _files = [];
  List<GalleryEntry> _gallery = [];
  bool _loading = true;
  double? _progress;
  int _tab = 0; // 0 = Files, 1 = Gallery
  bool _tiles = false; // false = list (default), true = tiles (grid)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (_tab == 1) {
      _gallery = await widget.state.backend.listGallery();
      setState(() => _loading = false);
      return;
    }
    if (serial == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    _files = await widget.state.backend.listFiles(serial, _path);
    setState(() => _loading = false);
  }

  void _go(String p) {
    setState(() => _path = p.endsWith('/') ? p : '$p/');
    _load();
  }

  void _up() {
    if (_path == '/sdcard/') return;
    final trimmed = _path.substring(0, _path.length - 1);
    final idx = trimmed.lastIndexOf('/');
    _go(trimmed.substring(0, idx + 1));
  }

  List<String> get _crumbs => _path.split('/').where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Files', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Files')),
              ButtonSegment(value: 1, label: Text('Gallery')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) {
              setState(() => _tab = v.first);
              _load();
            },
          ),
        ]),
        if (_tab == 0) ...[
          const Text('Your headset\'s shared storage. App private data is not shown here: Android keeps each app\'s private files separate. On a rooted headset, the backend can also read app data for backups.'),
          const SizedBox(height: 12),
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_upward), tooltip: 'Go up one folder', onPressed: _path == '/sdcard/' ? null : _up),
            Expanded(
              child: Wrap(spacing: 4, children: [
                ActionChip(label: const Text('sdcard'), onPressed: () => _go('/sdcard/')),
                for (var i = 0; i < _crumbs.length; i++)
                  ActionChip(label: Text(_crumbs[i]), onPressed: () {
                    _go('/${_crumbs.sublist(0, i + 1).join('/')}/');
                  }),
              ]),
            ),
            FilledButton.icon(onPressed: _upload, icon: const Icon(Icons.upload), label: const Text('Upload here')),
            const SizedBox(width: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.view_list), label: Text('List')),
                ButtonSegment(value: true, icon: Icon(Icons.grid_view), label: Text('Tiles')),
              ],
              selected: {_tiles},
              onSelectionChanged: (v) => setState(() => _tiles = v.first),
            ),
          ]),
          if (_progress != null) ...[const SizedBox(height: 8), LinearProgressIndicator(value: _progress)],
          const SizedBox(height: 12),
          Expanded(
            child: widget.state.selectedDevice == null
                ? const EmptyState(icon: Icons.headset_off, title: 'No headset connected', body: 'Connect your Quest 2 to browse its files.')
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _files.isEmpty
                        ? const EmptyState(icon: Icons.folder_open, title: 'This folder is empty', body: 'Upload a file here, or go back to another folder.')
                        : _tiles
                            ? GridView.builder(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.85),
                                itemCount: _files.length,
                                itemBuilder: (c, i) {
                                  final f = _files[i];
                                  return Card(
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: f.isDir ? () => _go(f.path) : () => _download(f),
                                      onLongPress: f.isDir ? null : () => _delete(f),
                                      borderRadius: BorderRadius.circular(16),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                          Center(child: Icon(f.isDir ? Icons.folder : Icons.insert_drive_file, size: 48)),
                                          const SizedBox(height: 8),
                                          Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                                          Text(f.isDir ? 'Folder' : formatBytes(f.size), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          const Spacer(),
                                          if (!f.isDir)
                                            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                              IconButton(icon: const Icon(Icons.download), tooltip: 'Download to this computer', onPressed: () => _download(f)),
                                              IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete from the headset', onPressed: () => _delete(f)),
                                            ])
                                          else
                                            const Center(child: Icon(Icons.chevron_right)),
                                        ]),
                                      ),
                                    ),
                                  );
                                },
                              )
                            : ListView.builder(
                            itemCount: _files.length,
                            itemBuilder: (c, i) {
                              final f = _files[i];
                              return Card(
                                child: ListTile(
                                  leading: Icon(f.isDir ? Icons.folder : Icons.insert_drive_file, size: 32),
                                  title: Text(f.name),
                                  subtitle: Text(f.isDir ? 'Folder' : formatBytes(f.size)),
                                  trailing: f.isDir
                                      ? const Icon(Icons.chevron_right)
                                      : IconButton(icon: const Icon(Icons.download), tooltip: 'Download to this computer', onPressed: () => _download(f)),
                                  onTap: f.isDir ? () => _go(f.path) : () => _download(f),
                                  onLongPress: f.isDir ? null : () => _delete(f),
                                ),
                              );
                            },
                          ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Game data (OBB)'),
              subtitle: Text('Game data files go in Android/obb, in a folder named after the app. File names must match the game version, for example main.123.com.game.app.obb.'),
            ),
          ),
        ] else
          Expanded(child: _buildGallery()),
      ]),
    );
  }

  Widget _buildGallery() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Screenshots and recordings saved on this computer (~/quest-recordings/). Screenshots are PNG, recordings are MP4 video without sound.'),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () async {
          final r = await widget.state.backend.openGalleryFolder();
          if (context.mounted) showResult(context, r.ok, r.message);
        },
        icon: const Icon(Icons.folder_open),
        label: const Text('Open folder'),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: _gallery.isEmpty
            ? const EmptyState(icon: Icons.photo_library, title: 'Gallery is empty', body: 'Take a screenshot or record a video from the Mirror screen and it will show up here.')
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.85),
                itemCount: _gallery.length,
                itemBuilder: (c, i) {
                  final g = _gallery[i];
                  return Card(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: g.kind == 'screenshot'
                            ? ClipRRect(
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                child: Image.file(
                                  File(g.path),
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  errorBuilder: (_, e, __) => const Center(child: Icon(Icons.image, size: 48)),
                                ),
                              )
                            : const Center(child: Icon(Icons.videocam, size: 48)),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text('${g.modified}  •  ${formatBytes(g.sizeBytes)}', style: const TextStyle(fontSize: 12)),
                          Row(children: [
                            TextButton(onPressed: () async {
                              final r = await widget.state.backend.openGalleryFile(g.path);
                              if (mounted) showResult(context, r.ok, r.message);
                            }, child: const Text('Open')),
                            TextButton(onPressed: () async {
                              final yes = await confirmDialog(context, title: 'Delete ${g.name}?', body: 'This deletes the file from this computer only.', confirmLabel: 'Delete', destructive: true);
                              if (!yes) return;
                              final r = await widget.state.backend.deleteGalleryEntry(g.path);
                              if (mounted) showResult(context, r.ok, r.message);
                              await _load();
                            }, child: const Text('Delete')),
                          ]),
                        ]),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _upload() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final local = await pathDialog(context, title: 'Upload a file', hint: 'Type the full path of the file on this computer to send to the headset.');
    if (local == null || local.isEmpty) return;
    setState(() => _progress = 0.5);
    final r = await widget.state.backend.pushFile(serial, local, '$_path${local.split('/').last}');
    setState(() => _progress = null);
    if (mounted) showResult(context, r.ok, r.message);
    widget.state.log('Upload: ${local.split('/').last}');
    await _load();
  }

  Future<void> _download(QuestFile f) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    setState(() => _progress = 0.5);
    final r = await widget.state.backend.pullFile(serial, f.path, '/tmp/${f.name}');
    setState(() => _progress = null);
    if (mounted) showResult(context, r.ok, r.message);
  }

  Future<void> _delete(QuestFile f) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final yes = await confirmDialog(context, title: 'Delete ${f.name}?', body: 'This deletes the file from the headset. This cannot be undone.', confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    final r = await widget.state.backend.deleteFile(serial, f.path);
    if (mounted) showResult(context, r.ok, r.message);
    if (r.ok) {
      widget.state.log('Deleted ${f.name}');
      await _load();
    }
  }
}
