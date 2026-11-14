import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import '../services/app_state.dart';

// Shared small widgets: section headings, empty states, confirm dialogs,
// path picker (no external plugin: plain path field, works on Linux and
// Android file paths), snackbars. Plain language, no em dashes.

/// A section heading, with an optional smaller subtitle underneath.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionTitle(this.title, {this.subtitle, super.key});
  @override
  /// Title in large text, subtitle below it in small text when given.
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      );
}

/// A small "i" button next to a heading. Tapping it opens a plain
/// language note about that section, for anyone who is unsure what
/// it does. Use it wherever a setting or feature is not obvious.
class InfoButton extends StatelessWidget {
  final String title;
  final String body;
  const InfoButton(this.title, this.body, {super.key});
  @override
  /// A small "i" button that opens the note dialog.
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.info_outline, size: 20),
        tooltip: title,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.of(d).pop(), child: const Text('Got it')),
            ],
          ),
        ),
      );
}

/// A section heading with an info button. The button is the small
/// "i" that explains the section in plain language.
class SectionTitleWithInfo extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String infoTitle;
  final String infoBody;
  const SectionTitleWithInfo(this.title, {this.subtitle, required this.infoTitle, required this.infoBody, super.key});
  @override
  /// Title and info button on one row, subtitle below when given.
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
            InfoButton(infoTitle, infoBody),
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      );
}

/// Two cards per row when the window is wide enough, one per row on
/// a narrow screen (phone, small window). Each card keeps its own
/// height, so a tall card never stretches the one beside it.
class CardGrid extends StatelessWidget {
  final List<Widget> cards;
  final double spacing;
  const CardGrid({required this.cards, this.spacing = 12, super.key});
  @override
  /// One column on narrow screens, two flowing columns on wide ones.
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // One card on its own takes the full width; two or more
          // share the width when the window is wide enough. The
          // cards are split into two columns that flow on their
          // own, so a short card no longer leaves a gap below it
          // when its neighbour is taller (a Wrap row stretches to
          // the tallest card in the row, which left empty space
          // under every short card).
          if (constraints.maxWidth < 860 || cards.length < 2) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) SizedBox(height: spacing),
                  cards[i],
                ],
              ],
            );
          }
          final left = <Widget>[];
          final right = <Widget>[];
          for (var i = 0; i < cards.length; i++) {
            (i.isEven ? left : right).add(cards[i]);
          }
          // One flowing column of cards with spacing between them.
          Widget column(List<Widget> items) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) SizedBox(height: spacing),
                    items[i],
                  ],
                ],
              );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: column(left)),
              SizedBox(width: spacing),
              Expanded(child: column(right)),
            ],
          );
        },
      );
}

/// A centred icon, title and body for an empty list, with an optional
/// action button.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({required this.icon, required this.title, required this.body, this.actionLabel, this.onAction, super.key});
  @override
  /// Icon, title, body, and the action button when one was given.
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ]),
        ),
      );
}

/// Yes/no dialog. Returns true only when the user taps the confirm
/// button; false on Cancel or dismiss.
Future<bool> confirmDialog(BuildContext context, {required String title, required String body, String confirmLabel = 'Yes, do it', bool destructive = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Colors.red) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// Ask for a file path: type it or tap Browse to pick. Returns the
/// trimmed path, or null when cancelled.
Future<String?> pathDialog(BuildContext context, {required String title, required String hint, String initial = '', List<String>? extensions}) async {
  final ctrl = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hint, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Full file path'))),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await FilePicker.platform.pickFiles(
                type: extensions == null ? FileType.any : FileType.custom,
                allowedExtensions: extensions,
              );
              final path = picked?.files.single.path;
              if (path != null && path.isNotEmpty) {
                ctrl.text = path;
              }
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('Browse'),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('Tip: tap Browse to pick the file, or type the full path, for example ~/Downloads/game.apk', style: TextStyle(fontSize: 13)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Use this file')),
      ],
    ),
  );
  return result;
}

/// Short snackbar: green when ok, red when not. An empty message
/// becomes "Done." or "Something went wrong."
void showResult(BuildContext context, bool ok, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message.isEmpty ? (ok ? 'Done.' : 'Something went wrong.') : message),
    backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
  ));
}

/// Human size: 512 B, 1.5 KB, 2.0 MB, 1.25 GB.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// Coloured circle with the first letter of the label. The colour
/// comes from the label length, so one app always gets the same colour.
Widget avatarFor(String label, {double size = 40}) {
  final letter = label.isNotEmpty ? label[0].toUpperCase() : '?';
  final colors = [Colors.blue, Colors.teal, Colors.orange, Colors.purple, Colors.green, Colors.indigo];
  final color = colors[label.length % colors.length];
  return CircleAvatar(radius: size / 2, backgroundColor: color, child: Text(letter, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)));
}

/// An app's real launcher icon, loaded lazily through AppState's
/// in-memory cache (the backend caches the file on disk, so repeat
/// loads are cheap). While the icon loads, or when the app has no
/// launcher icon at all, it shows the initials avatar, never a
/// blank tile and never a crash if the icon file goes missing.
class AppIconTile extends StatefulWidget {
  final AppState state;
  final QuestApp app;
  final double size;
  final ValueChanged<AppIcon>? onIcon;
  const AppIconTile({required this.state, required this.app, this.size = 40, this.onIcon, super.key});
  @override
  State<AppIconTile> createState() => _AppIconTileState();
}

class _AppIconTileState extends State<AppIconTile> {
  @override
  /// Start loading the icon as soon as the tile appears.
  void initState() {
    super.initState();
    _load();
  }

  /// Ask AppState for the icon, unless it is already cached; report it
  /// through onIcon when it arrives.
  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    if (widget.state.iconCache.containsKey(widget.app.package)) return;
    final icon = await widget.state.appIcon(serial, widget.app.package);
    if (icon != null && mounted) widget.onIcon?.call(icon);
  }

  @override
  /// The real icon when loaded, the initials avatar while loading or
  /// when there is none.
  Widget build(BuildContext context) {
    final icon = widget.state.iconCache[widget.app.package];
    final path = icon?.iconPath ?? widget.app.iconPath;
    if (icon == null && path == null) return avatarFor(widget.app.label, size: widget.size);
    if (path == null) return avatarFor(widget.app.label, size: widget.size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size / 5),
      child: Image.file(
        File(path),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => avatarFor(widget.app.label, size: widget.size),
      ),
    );
  }
}

/// A library entry's real launcher icon, from the APK already on
/// this computer (backend `library icon`). Loaded lazily through
/// AppState's in-memory cache (the backend caches the file on
/// disk, so repeat loads are cheap). Save backups have no APK, so
/// they keep the save icon, never a fake one. While the icon loads,
/// or when the APK has no launcher icon at all, it shows the
/// initials avatar, never a blank tile.
class LibraryIconTile extends StatefulWidget {
  final AppState state;
  final LibraryEntry entry;
  final double size;
  const LibraryIconTile({required this.state, required this.entry, this.size = 40, super.key});
  @override
  State<LibraryIconTile> createState() => _LibraryIconTileState();
}

class _LibraryIconTileState extends State<LibraryIconTile> {
  @override
  /// Start loading the icon as soon as the tile appears.
  void initState() {
    super.initState();
    _load();
  }

  /// Save backups have no APK, so there is nothing to load; otherwise
  /// ask AppState for the icon.
  Future<void> _load() async {
    if (widget.entry.kind == 'save') return;
    if (widget.state.libraryIconCache.containsKey(widget.entry.path)) return;
    await widget.state.libraryIcon(widget.entry);
  }

  @override
  /// Save entries show a save icon; the rest show the real icon or
  /// the initials avatar.
  Widget build(BuildContext context) {
    if (widget.entry.kind == 'save') {
      return Icon(Icons.save, size: widget.size);
    }
    final icon = widget.state.libraryIconCache[widget.entry.path];
    final path = icon?.iconPath;
    if (path == null) return avatarFor(widget.entry.label, size: widget.size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size / 5),
      child: Image.file(
        File(path),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => avatarFor(widget.entry.label, size: widget.size),
      ),
    );
  }
}
