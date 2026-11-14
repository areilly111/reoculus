// Apps and Files screens.
// Apps: apps installed on the headset (list or tiles), plus the Library
// tab of local app backups, save backups, and imported APKs. Files:
// the headset's shared storage browser, plus the Gallery of screenshots
// and recordings saved on this computer. Also holds the APK analysis
// dialog shown before any install.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import '../models.dart';
import '../services/app_state.dart';
import '../services/backend.dart';
import '../widgets/common.dart';

/// Analyze an APK file and show what it is before installing it.
/// Returns true when the user taps Install after reading the
/// analysis, false otherwise. When the file cannot be read, the
/// dialog says so and there is no Install button.
Future<bool> showApkAnalysis(BuildContext context, BackendService backend, String path) async {
  final a = await backend.analyzeApk(path);
  if (a == null) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Could not read this APK'),
        content: Text('File: $path\n\nThe APK could not be read (it may be corrupt, or use a resource format this app cannot parse). It was not installed.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('OK'))],
      ),
    );
    return ok == true;
  }
  /// Shortens a SHA-256 hash for display: first 32 characters plus an ellipsis.
  String shortHash(String h) => h.length > 32 ? '${h.substring(0, 32)}…' : h;
  final lines = <Widget>[
    Text('File: ${a.file} (${formatBytes(a.fileSizeBytes)})'),
    Text('Package: ${a.package ?? 'unknown'}'),
    Text('Version: ${a.versionName ?? 'unknown'}${a.versionCode != null ? ' (code ${a.versionCode})' : ''}'),
    if (a.minSdk != null || a.targetSdk != null)
      Text('Android: min SDK ${a.minSdk ?? 'unknown'}  •  target SDK ${a.targetSdk ?? 'unknown'}'),
    Text('Native code: ${a.abis.isEmpty ? 'none (pure Java/Kotlin)' : '${a.abis.join(', ')}${a.is64Bit ? ' (64-bit)' : ' (32-bit only)'}'}'),
    Text('Code: ${formatBytes(a.dexBytes)}  •  Native libs: ${a.nativeLibCount} files, ${formatBytes(a.nativeLibBytes)}  •  Assets: ${formatBytes(a.assetsBytes)}  •  Resources: ${formatBytes(a.resBytes)}'),
    if (a.features.isNotEmpty) Text('Needs: ${a.features.join(', ')}'),
    Text('Permissions (${a.permissions.length}): ${a.permissions.isEmpty ? 'none' : a.permissions.take(8).join(', ')}${a.permissions.length > 8 ? '  •  +${a.permissions.length - 8} more' : ''}'),
    Text('File SHA-256: ${shortHash(a.sha256)}'),
    Text(a.signatureChecked
        ? 'Signer SHA-256: ${shortHash(a.signatureSha256!)}'
        : 'Signer: not checked (see the note below)'),
    for (final n in a.notes) Text(n, style: const TextStyle(fontSize: 13)),
    const SizedBox(height: 8),
    const Text('Only install apps you own or that the developer gives away freely. This app never uploads the file anywhere.', style: TextStyle(fontSize: 13)),
  ];
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(a.label ?? a.file),
      content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Install')),
      ],
    ),
  );
  return ok == true;
}

// ---- Apps -----------------------------------------------------------------
// Two tabs: Apps (installed on the headset, with sizes) and Library
// (app backups, save backups and imported APKs, all in the one
// library folder on this computer).
/// Apps screen: two tabs, Apps (installed on the headset) and Library
/// (local backups and imported APKs).
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
  /// Loads the installed apps and the library when the screen opens.
  void initState() {
    super.initState();
    _load();
  }

  /// Reloads the installed apps from the headset and the library from
  /// this computer. With no headset selected, only the library loads
  /// and the loading spinner stops.
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

  /// The installed apps filtered by the search box (matches name or package).
  List<QuestApp> get _filtered => _apps.where((a) => _query.isEmpty || a.label.toLowerCase().contains(_query.toLowerCase()) || a.package.toLowerCase().contains(_query.toLowerCase())).toList();

  /// Picks an APK on this computer, shows the APK analysis first, then
  /// installs it on the headset. Split apps use .apks or .xapk.
  Future<void> _install() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final path = await pathDialog(context, title: 'Install an app', hint: 'Pick an APK file on this computer. For split apps, pick a .apks or .xapk file instead and it will be installed in one go.', extensions: const ['apk', 'apks', 'xapk']);
    if (path == null || path.isEmpty) return;
    final proceed = await showApkAnalysis(context, widget.state.backend, path);
    if (proceed != true) return;
    setState(() {
      // Progress is a rough guess: the backend does not report install progress.
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

  /// Copies a picked APK into the library folder, so it can be
  /// installed later without the original file.
  Future<void> _importApk() async {
    final path = await pathDialog(context, title: 'Import an APK into the library', hint: 'Pick an APK, .apks or .xapk file on this computer. It is copied into the library folder, so you can install it later without the original file.', extensions: const ['apk', 'apks', 'xapk']);
    if (path == null || path.isEmpty) return;
    final e = await widget.state.backend.importApk(path);
    if (!mounted) return;
    showResult(context, e != null, e == null ? 'Could not import that file.' : 'Imported ${e.label} ${e.version} into the library.');
    await _load();
  }

  /// Size parts for an app: APK size, plus total size when it differs.
  /// The list view joins them on one line; tiles put each on its own
  /// line so nothing ever truncates on a narrow tile.
  List<String> _sizeParts(QuestApp a) {
    final parts = <String>[];
    if (a.apkSizeBytes != null) parts.add('APK ${formatBytes(a.apkSizeBytes!)}');
    if (a.totalSizeBytes != null && a.totalSizeBytes != a.apkSizeBytes) parts.add('Total ${formatBytes(a.totalSizeBytes!)}');
    return parts;
  }

  /// One-line size text for an app: APK size, plus total size when it differs.
  String _sizeText(QuestApp a) => _sizeParts(a).join('  •  ');

  @override
  /// Builds the Apps/Library tabs, list or tiles, with search and filters.
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
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.80),
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
                                              size: 56,
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
                                          Text('Version ${a.version}', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          for (final part in _sizeParts(a)) Text(part, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                                          const Spacer(),
                                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            IconButton(icon: const Icon(Icons.play_arrow), tooltip: 'Launch', iconSize: 20, padding: const EdgeInsets.all(4), constraints: const BoxConstraints(minWidth: 32, minHeight: 32), onPressed: () async {
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

  // ---- Library ----------------------------------------------------------
  /// Builds the Library tab: local backups and imported APKs, list or tiles.
  Widget _buildLibrary() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('One folder on this computer holds every backup and imported APK. Delete here only deletes local files, never anything on the headset.')),
        const SizedBox(width: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.view_list), label: Text('List')),
            ButtonSegment(value: true, icon: Icon(Icons.grid_view), label: Text('Tiles')),
          ],
          selected: {widget.state.libraryTiles},
          onSelectionChanged: (v) => widget.state.setLibraryTiles(v.first),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(onPressed: _importApk, icon: const Icon(Icons.add), label: const Text('Import APK')),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: _library.isEmpty
            ? const EmptyState(icon: Icons.folder_copy, title: 'Library is empty', body: 'Back up an app, or import an APK, and it will show up here.')
            : widget.state.libraryTiles
                ? GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.0),
                    itemCount: _library.length,
                    itemBuilder: (c, i) {
                      final e = _library[i];
                      final kindLabel = e.kind == 'save' ? 'Save backup' : e.kind == 'apk' ? 'Imported APK' : 'App backup';
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _primaryLibraryAction(e),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                              Center(child: LibraryIconTile(state: widget.state, entry: e, size: 56)),
                              const SizedBox(height: 6),
                              Text('${e.label} ${e.version}', maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text(kindLabel, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                              Text(formatBytes(e.sizeBytes), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                              const SizedBox(height: 4),
                              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                if (e.kind == 'apk')
                                  TextButton(onPressed: () => _installLibraryEntry(e), child: const Text('Install'))
                                else
                                  TextButton(onPressed: () => _restoreLibraryEntry(e), child: const Text('Restore')),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Delete from this computer',
                                  onPressed: () => _deleteLibraryEntry(e),
                                ),
                              ]),
                            ]),
                          ),
                        ),
                      );
                    },
                  )
                : ListView.builder(
                    itemCount: _library.length,
                    itemBuilder: (c, i) {
                      final e = _library[i];
                      final kindLabel = e.kind == 'save' ? 'Save backup' : e.kind == 'apk' ? 'Imported APK' : 'App backup';
                      return Card(
                        child: ListTile(
                          leading: LibraryIconTile(state: widget.state, entry: e, size: 40),
                          title: Text('${e.label} ${e.version}'),
                          subtitle: Text('$kindLabel  •  ${e.package}\n${e.dateAdded}  •  ${formatBytes(e.sizeBytes)}${e.hasData ? '  •  includes app data' : ''}'),
                          isThreeLine: true,
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (e.kind == 'apk') ...[
                              TextButton(
                                onPressed: () => _installLibraryEntry(e),
                                child: const Text('Install'),
                              ),
                            ],
                            if (e.kind != 'apk')
                              TextButton(
                                onPressed: () => _restoreLibraryEntry(e),
                                child: const Text('Restore'),
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Delete from this computer',
                              onPressed: () => _deleteLibraryEntry(e),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
      ),
    ]);
  }

  /// Primary action for a library entry: Install for an imported
  /// APK (with the APK analysis first), Restore for a backup or
  /// a save backup. Used by a tile tap; the list row buttons call
  /// the same two flows directly.
  Future<void> _primaryLibraryAction(LibraryEntry e) async {
    if (e.kind == 'apk') {
      await _installLibraryEntry(e);
    } else {
      await _restoreLibraryEntry(e);
    }
  }

  /// Installs a library APK on the headset, after the APK analysis dialog.
  Future<void> _installLibraryEntry(LibraryEntry e) async {
    final proceed = await showApkAnalysis(context, widget.state.backend, e.path);
    if (proceed != true) return;
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final r = await widget.state.backend.installApk(serial, e.path);
    if (mounted) showResult(context, r.ok, r.message);
  }

  /// Deletes a library entry from this computer only. Nothing on the
  /// headset is touched.
  Future<void> _deleteLibraryEntry(LibraryEntry e) async {
    final yes = await confirmDialog(context, title: 'Delete ${e.label}?', body: 'This deletes the backup from this computer only. The app on the headset is not touched.', confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    final r = await widget.state.backend.deleteLibraryEntry(e.path);
    if (mounted) showResult(context, r.ok, r.message);
    await _load();
  }

  /// Restores a library backup or save backup onto the headset. Runs a
  /// dry run first, asks whether to restore app data too (needs root),
  /// then asks for confirmation.
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
    if (!dry.ready) {
      if (mounted) showResult(context, false, 'Cannot restore yet:\n$lines');
      return;
    }
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
      showResult(context, r?.ready ?? false, r == null ? 'Restore failed.' : r.steps.map((st) => '${st.item}: ${st.message}').join('\n'));
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
        iconSize: 20,
        padding: const EdgeInsets.all(4),
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

  /// Runs one menu action for an app: info, backup, save, restore,
  /// force stop, clear data, remove system app, or uninstall.
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

  /// Opens the app detail dialog for one app.
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
/// App detail dialog: sizes, versions, permissions, and the backup,
/// force stop, clear data, and uninstall actions. Details load lazily
/// from the headset when the dialog opens.
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
  /// Loads the app details from the headset when the dialog opens.
  void initState() {
    super.initState();
    _loadDetails();
  }

  /// Fetches sizes, install dates, and permissions for this app from
  /// the headset. Shows a fallback if the headset does not answer.
  Future<void> _loadDetails() async {
    final d = await widget.state.backend.appDetails(widget.serial, widget.app.package);
    if (mounted) {
      setState(() {
        _details = d;
        _loadingDetails = false;
      });
    }
  }

  /// Formats a byte count, or "Unknown" when the headset did not report one.
  String _bytes(int? v) => v == null ? 'Unknown' : formatBytes(v);

  @override
  /// Builds the detail dialog, with a loading bar until the details arrive.
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
/// Files screen: the headset's shared storage browser, plus the Gallery
/// tab of screenshots and recordings saved on this computer.
///
/// The file list is a dense details view like Windows Explorer or
/// Dolphin: one compact row per file with name, type, size and
/// last-modified date, sortable by tapping a column header. On Linux
/// you can drag files in from the file manager to upload them, and
/// drag a file out to the file manager to download it.
class FilesScreen extends StatefulWidget {
  final AppState state;
  const FilesScreen({required this.state, super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

/// True when native drag and drop is available: Linux desktop only,
/// and never in widget tests (the drag plugin has no test backend).
bool get _dragEnabled =>
    Platform.isLinux && !Platform.environment.containsKey('FLUTTER_TEST');

class _FilesScreenState extends State<FilesScreen> {
  String _path = '/sdcard/';
  List<QuestFile> _files = [];
  List<GalleryEntry> _gallery = [];
  bool _loading = true;
  double? _progress;
  String _progressLabel = '';
  int _tab = 0; // 0 = Files, 1 = Gallery
  String _sortKey = 'name'; // name, type, size, date
  bool _sortAsc = true;
  bool _dragOver = false;
  String? _stagingName; // file currently being pulled for a drag-out

  @override
  /// Loads the current folder (or the gallery) when the screen opens.
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the current folder from the headset, or the local gallery
  /// when that tab is active. With no headset, the file list stays empty.
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

  /// Opens a folder by path, making sure the path ends with a slash.
  void _go(String p) {
    setState(() => _path = p.endsWith('/') ? p : '$p/');
    _load();
  }

  /// Goes up one folder. Does nothing at the top (/sdcard/).
  void _up() {
    if (_path == '/sdcard/') return;
    final trimmed = _path.substring(0, _path.length - 1);
    final idx = trimmed.lastIndexOf('/');
    _go(trimmed.substring(0, idx + 1));
  }

  List<String> get _crumbs => _path.split('/').where((s) => s.isNotEmpty).toList();

  /// File type from the extension: label + icon for the Type column.
  ({String label, IconData icon}) _fileType(QuestFile f) {
    if (f.isDir) return (label: 'Folder', icon: Icons.folder);
    final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'apk':
        return (label: 'APK', icon: Icons.android);
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
        return (label: 'Image', icon: Icons.image);
      case 'mp4':
      case 'mkv':
      case 'mov':
      case 'webm':
        return (label: 'Video', icon: Icons.movie);
      case 'mp3':
      case 'ogg':
      case 'flac':
      case 'wav':
      case 'm4a':
        return (label: 'Audio', icon: Icons.music_note);
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return (label: 'Archive', icon: Icons.archive);
      case 'obb':
        return (label: 'Game data', icon: Icons.videogame_asset);
      case 'txt':
      case 'md':
      case 'json':
      case 'xml':
      case 'log':
      case 'csv':
        return (label: 'Text', icon: Icons.description);
      default:
        return (label: 'File', icon: Icons.insert_drive_file);
    }
  }

  /// Parses the headset's last-modified text for sorting: ISO
  /// "2026-11-11 12:00", or "Nov 11 12:00" / "Nov 11 2025" from ls.
  /// Returns null when the date is missing or unparseable.
  DateTime? _parseModified(String m) {
    if (m.isEmpty) return null;
    final iso = DateTime.tryParse(m);
    if (iso != null) return iso;
    const months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    final timeMatch = RegExp(r'^([A-Z][a-z]{2}) (\d{1,2}) (\d{2}):(\d{2})$').firstMatch(m);
    if (timeMatch != null) {
      final month = months[timeMatch.group(1)];
      if (month == null) return null;
      var d = DateTime(DateTime.now().year, month, int.parse(timeMatch.group(2)!),
          int.parse(timeMatch.group(3)!), int.parse(timeMatch.group(4)!));
      // ls shows the time, not the year, for recent files; if that
      // lands in the future, it must be last year.
      if (d.isAfter(DateTime.now())) {
        d = DateTime(d.year - 1, d.month, d.day, d.hour, d.minute);
      }
      return d;
    }
    final yearMatch = RegExp(r'^([A-Z][a-z]{2}) (\d{1,2}) (\d{4})$').firstMatch(m);
    if (yearMatch != null) {
      final month = months[yearMatch.group(1)];
      if (month == null) return null;
      return DateTime(
          int.parse(yearMatch.group(3)!), month, int.parse(yearMatch.group(2)!));
    }
    return null;
  }

  /// The current folder, sorted: folders first, then the picked column.
  List<QuestFile> get _sorted {
    final list = List<QuestFile>.from(_files);
    int byKey(QuestFile a, QuestFile b) {
      switch (_sortKey) {
        case 'size':
          return a.size.compareTo(b.size);
        case 'date':
          final da = _parseModified(a.modified);
          final db = _parseModified(b.modified);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        case 'type':
          final t = _fileType(a).label.compareTo(_fileType(b).label);
          return t != 0 ? t : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final c = byKey(a, b);
      return _sortAsc ? c : -c;
    });
    return list;
  }

  /// Tapping a column header sorts by it; tapping again flips direction.
  void _setSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _sortAsc = !_sortAsc;
      } else {
        _sortKey = key;
        _sortAsc = true;
      }
    });
  }

  @override
  /// Builds the Files/Gallery tabs, breadcrumbs, and the details list.
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
          if (_dragEnabled)
            const Text('Drag files in from your file manager to upload them here. Drag a file out to your file manager to download it; it is pulled to this computer first, so a big file takes a moment before the drag starts.'),
          const SizedBox(height: 12),
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_upward), tooltip: 'Go up one folder', onPressed: _path == '/sdcard/' ? null : _up),
            Expanded(
              child: Wrap(spacing: 4, children: [
                for (var i = 0; i < _crumbs.length; i++)
                  ActionChip(label: Text(_crumbs[i]), onPressed: () {
                    _go('/${_crumbs.sublist(0, i + 1).join('/')}/');
                  }),
              ]),
            ),
            FilledButton.icon(onPressed: _upload, icon: const Icon(Icons.upload), label: const Text('Upload here')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: _newFolder, icon: const Icon(Icons.create_new_folder), label: const Text('New folder')),
          ]),
          if (_progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
            if (_progressLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_progressLabel, style: const TextStyle(fontSize: 12)),
            ],
          ],
          const SizedBox(height: 12),
          Expanded(
            child: widget.state.selectedDevice == null
                ? const EmptyState(icon: Icons.headset_off, title: 'No headset connected', body: 'Connect your Quest 2 to browse its files.')
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _files.isEmpty
                        ? const EmptyState(icon: Icons.folder_open, title: 'This folder is empty', body: 'Upload a file here, or drag one in from your file manager.')
                        : _buildFileList(),
          ),
        ] else
          Expanded(child: _buildGallery()),
      ]),
    );
  }

  /// The dense details list: column header plus one compact row per
  /// file. On Linux the whole list is a drop target for uploads.
  Widget _buildFileList() {
    final files = _sorted;
    final content = LayoutBuilder(
      builder: (ctx, constraints) {
        final width = constraints.maxWidth < 560 ? 560.0 : constraints.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              _buildHeaderRow(),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (c, i) => _fileRow(files[i]),
                ),
              ),
            ]),
          ),
        );
      },
    );
    if (!_dragEnabled) return content;
    return DropRegion(
      formats: Formats.standardFormats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        final hasFile = event.session.items
            .any((i) => i.dataReader?.canProvide(Formats.fileUri) == true);
        return hasFile ? DropOperation.copy : DropOperation.none;
      },
      onDropEnter: (_) => setState(() => _dragOver = true),
      onDropLeave: (_) => setState(() => _dragOver = false),
      onDropEnded: (_) => setState(() => _dragOver = false),
      onPerformDrop: _onPerformDrop,
      child: Stack(children: [
        content,
        if (_dragOver)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.08),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Text('Drop files here to upload them to this folder',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),
      ]),
    );
  }

  /// Column header row: tapping a label sorts by that column.
  Widget _buildHeaderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        const SizedBox(width: 28),
        Expanded(
          child: InkWell(
            onTap: () => _setSort('name'),
            child: _headerLabel('Name', 'name'),
          ),
        ),
        SizedBox(
          width: 110,
          child: InkWell(
            onTap: () => _setSort('type'),
            child: _headerLabel('Type', 'type'),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 90,
          child: InkWell(
            onTap: () => _setSort('size'),
            child: _headerLabel('Size', 'size', alignRight: true),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 130,
          child: InkWell(
            onTap: () => _setSort('date'),
            child: _headerLabel('Modified', 'date'),
          ),
        ),
        const SizedBox(width: 48),
      ]),
    );
  }

  /// One header label, with a direction arrow when it is the sort key.
  Widget _headerLabel(String label, String key, {bool alignRight = false}) {
    final active = _sortKey == key;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: active
                      ? Theme.of(context).colorScheme.primary
                      : null)),
          if (active) ...[
            const SizedBox(width: 2),
            Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 13, color: Theme.of(context).colorScheme.primary),
          ],
        ],
      ),
    );
  }

  /// One compact row: small type icon, name, type, size, date, and a
  /// single menu button. On Linux the row is also a drag source.
  Widget _fileRow(QuestFile f) {
    final t = _fileType(f);
    final staging = _stagingName == f.name;
    final row = InkWell(
      onTap: f.isDir ? () => _go(f.path) : () => _download(f),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color:
                        Theme.of(context).dividerColor.withOpacity(0.35)))),
        child: Row(children: [
          Icon(t.icon,
              size: 20,
              color: f.isDir ? Theme.of(context).colorScheme.primary : null),
          const SizedBox(width: 8),
          Expanded(
              child: Text(f.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          SizedBox(
              width: 110,
              child: Text(t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          SizedBox(
              width: 90,
              child: Text(f.isDir ? '' : formatBytes(f.size),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          SizedBox(
              width: 130,
              child: Text(f.modified,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13))),
          SizedBox(
            width: 48,
            child: staging
                ? const Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    tooltip: 'Actions for ${f.name}',
                    onSelected: (v) {
                      if (v == 'download') _download(f);
                      if (v == 'rename') _renameFile(f);
                      if (v == 'delete') _delete(f);
                    },
                    itemBuilder: (c) => [
                      if (!f.isDir)
                        const PopupMenuItem(
                            value: 'download',
                            child: Text('Download to this computer')),
                      const PopupMenuItem(
                          value: 'rename', child: Text('Rename')),
                      const PopupMenuItem(
                          value: 'delete', child: Text('Delete')),
                    ],
                  ),
          ),
        ]),
      ),
    );
    if (!_dragEnabled) return row;
    return DragItemWidget(
      dragItemProvider: (request) => _provideDragItem(f),
      allowedOperations: () => [DropOperation.copy],
      child: DraggableWidget(child: row),
    );
  }

  /// Drag-out: pulls the file to the staging folder first, because on
  /// Linux the file must exist on this computer when the drag starts.
  /// Returns null (and no drag starts) when the pull fails.
  Future<DragItem?> _provideDragItem(QuestFile f) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null || !mounted) return null;
    setState(() => _stagingName = f.name);
    try {
      final staged = await _stageForDrag(serial, f);
      if (staged == null) return null;
      final item = DragItem(localData: {'path': f.path});
      item.add(Formats.fileUri(Uri.file(staged)));
      return item;
    } finally {
      if (mounted) setState(() => _stagingName = null);
    }
  }

  /// Pulls a file (or a whole folder) into the drag-out staging area
  /// and returns the local path to offer to the file manager.
  Future<String?> _stageForDrag(String serial, QuestFile f) async {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory('${cache.path}/drag-out/$serial');
    await dir.create(recursive: true);
    await _pruneStaging(dir);
    if (f.isDir) {
      // adb pull of a folder copies it into the staging dir as <name>.
      final r = await widget.state.backend.pullFile(serial, f.path, dir.path);
      if (!r.ok) {
        if (mounted) showResult(context, false, r.message);
        return null;
      }
      final staged = Directory('${dir.path}/${f.name}');
      return await staged.exists() ? staged.path : null;
    }
    final stagedPath = '${dir.path}/${f.name}';
    final r = await widget.state.backend.pullFile(serial, f.path, stagedPath);
    if (!r.ok) {
      if (mounted) showResult(context, false, r.message);
      return null;
    }
    return await File(stagedPath).exists() ? stagedPath : null;
  }

  /// Staged drag-out files are cleaned up by age and size, never by
  /// drop success: on Linux the drag source is never told where the
  /// file was dropped, or whether the drop happened at all.
  Future<void> _pruneStaging(Directory dir) async {
    const maxAge = Duration(days: 7);
    const maxBytes = 1024 * 1024 * 1024; // 1 GB
    final now = DateTime.now();
    try {
      await for (final e in dir.list(recursive: true)) {
        try {
          final stat = await e.stat();
          if (now.difference(stat.modified) > maxAge) {
            await e.delete(recursive: true);
          }
        } catch (_) {}
      }
      final files = <File>[];
      await for (final e in dir.list(recursive: true)) {
        if (e is File) files.add(e);
      }
      files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      var total = 0;
      for (final f in files) {
        total += f.lengthSync();
      }
      for (final f in files) {
        if (total <= maxBytes) break;
        try {
          total -= f.lengthSync();
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Drag-in: collects the dropped files' paths, then uploads them.
  /// The values arrive through callbacks, so the counter waits until
  /// every item has answered (or failed) before starting the upload.
  Future<void> _onPerformDrop(PerformDropEvent event) async {
    final uris = <Uri>[];
    var pending = 0;
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
      pending++;
      reader.getValue<Uri>(Formats.fileUri, (value) {
        if (value != null) uris.add(value);
        pending--;
        if (pending == 0) _handleDroppedUris(uris);
      }, onError: (_) {
        pending--;
        if (pending == 0) _handleDroppedUris(uris);
      });
    }
  }

  /// Uploads dropped files (and whole dropped folders, keeping their
  /// structure) into the folder showing. Asks once when names clash.
  Future<void> _handleDroppedUris(List<Uri> uris) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null || uris.isEmpty || !mounted) return;
    final pairs = <({File file, String remote})>[];
    for (final uri in uris) {
      final type = FileSystemEntity.typeSync(uri.toFilePath());
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(uri.toFilePath());
        final base = dir.path.split('/').last;
        for (final e in dir.listSync(recursive: true)) {
          if (e is File) {
            final rel = e.path.substring(dir.path.length + 1);
            pairs.add((file: e, remote: '$_path$base/$rel'));
          }
        }
      } else if (type == FileSystemEntityType.file) {
        final file = File(uri.toFilePath());
        pairs.add(
            (file: file, remote: '$_path${file.path.split('/').last}'));
      }
    }
    if (pairs.isEmpty || !mounted) return;
    final existing = _files.map((f) => f.name).toSet();
    final conflicts = pairs
        .where((p) {
          final rel = p.remote.substring(_path.length);
          return !rel.contains('/') && existing.contains(rel);
        })
        .map((p) => p.remote.split('/').last)
        .toSet()
        .toList();
    var skip = <String>{};
    if (conflicts.isNotEmpty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Some files already exist'),
          content: Text(
              'These files are already in this folder:\n${conflicts.take(5).join(', ')}${conflicts.length > 5 ? '\n…and ${conflicts.length - 5} more' : ''}\n\nOverwrite them, or skip them?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, 'skip'),
                child: const Text('Skip those')),
            FilledButton(
                onPressed: () => Navigator.pop(c, 'overwrite'),
                child: const Text('Overwrite')),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'skip') skip = conflicts.toSet();
    }
    final todo = pairs
        .where((p) => !skip.contains(p.remote.split('/').last))
        .toList();
    final createdDirs = <String>{};
    var done = 0;
    final currentDir = _path.substring(0, _path.length - 1);
    for (final p in todo) {
      if (!mounted) return;
      final slash = p.remote.lastIndexOf('/');
      final remoteDir = p.remote.substring(0, slash);
      if (remoteDir != currentDir && !createdDirs.contains(remoteDir)) {
        await widget.state.backend.makeDir(serial, remoteDir);
        createdDirs.add(remoteDir);
      }
      final name = p.remote.split('/').last;
      setState(() {
        _progress = todo.isEmpty ? null : done / todo.length;
        _progressLabel = 'Uploading $name… (${done + 1} of ${todo.length})';
      });
      final r =
          await widget.state.backend.pushFile(serial, p.file.path, p.remote);
      if (!r.ok && mounted) {
        showResult(context, false, 'Could not upload $name: ${r.message}');
      }
      done++;
    }
    setState(() {
      _progress = null;
      _progressLabel = '';
    });
    if (mounted) {
      showResult(context, true,
          'Uploaded $done file${done == 1 ? '' : 's'} to $_path');
    }
    widget.state.log('Upload: $done file(s) dropped into $_path');
    await _load();
  }

  /// Builds the Gallery tab: screenshots and recordings saved in
  /// ~/quest-recordings/ on this computer.
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

  /// Uploads a picked file from this computer into the folder showing.
  Future<void> _upload() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final local = await pathDialog(context, title: 'Upload a file', hint: 'Type the full path of the file on this computer to send to the headset.');
    if (local == null || local.isEmpty) return;
    // Progress is a rough guess: the backend does not report transfer progress.
    setState(() {
      _progress = 0.5;
      _progressLabel = 'Uploading ${local.split('/').last}…';
    });
    final r = await widget.state.backend.pushFile(serial, local, '$_path${local.split('/').last}');
    setState(() {
      _progress = null;
      _progressLabel = '';
    });
    if (mounted) showResult(context, r.ok, r.message);
    widget.state.log('Upload: ${local.split('/').last}');
    await _load();
  }

  /// Downloads a headset file to /tmp on this computer.
  Future<void> _download(QuestFile f) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    // Progress is a rough guess: the backend does not report transfer progress.
    setState(() {
      _progress = 0.5;
      _progressLabel = 'Downloading ${f.name}…';
    });
    final r = await widget.state.backend.pullFile(serial, f.path, '/tmp/${f.name}');
    setState(() {
      _progress = null;
      _progressLabel = '';
    });
    if (mounted) showResult(context, r.ok, r.message);
  }

  /// Deletes a file from the headset, after confirming. Cannot be undone.
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

  /// Renames a file or folder in place. The new name stays in the
  /// same folder; a '/' in it is refused.
  Future<void> _renameFile(QuestFile f) async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final controller = TextEditingController(text: f.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Rename ${f.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'New name',
            helperText: 'The file stays in this folder.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Rename')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == f.name) return;
    if (name.contains('/')) {
      if (mounted) showResult(context, false, 'The name cannot contain a /.');
      return;
    }
    final parent = f.path.substring(0, f.path.length - f.name.length);
    final r = await widget.state.backend.renameFile(serial, f.path, '$parent$name');
    if (mounted) showResult(context, r.ok, r.message);
    if (r.ok) await _load();
  }

  /// Creates a folder inside the current folder.
  Future<void> _newFolder() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (name.contains('/')) {
      if (mounted) showResult(context, false, 'The folder name cannot contain a /.');
      return;
    }
    final r = await widget.state.backend.makeDir(serial, '$_path$name');
    if (mounted) showResult(context, r.ok, r.message);
    if (r.ok) await _load();
  }
}
