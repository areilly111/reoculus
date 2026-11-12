import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models.dart';
import '../services/app_state.dart';

// Shared small widgets: section headings, empty states, confirm dialogs,
// path picker (no external plugin: plain path field, works on Linux and
// Android file paths), snackbars. Plain language, no em dashes.

class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionTitle(this.title, {this.subtitle, super.key});
  @override
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

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({required this.icon, required this.title, required this.body, this.actionLabel, this.onAction, super.key});
  @override
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

void showResult(BuildContext context, bool ok, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message.isEmpty ? (ok ? 'Done.' : 'Something went wrong.') : message),
    backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
  ));
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

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
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final serial = widget.state.selectedDevice?.serial;
    if (serial == null) return;
    if (widget.state.iconCache.containsKey(widget.app.package)) return;
    final icon = await widget.state.appIcon(serial, widget.app.package);
    if (icon != null && mounted) widget.onIcon?.call(icon);
  }

  @override
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
