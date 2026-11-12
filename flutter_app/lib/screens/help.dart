import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../widgets/common.dart';

// ---- Offline help ---------------------------------------------------------
// Plain, local guides for keeping a Quest 2 going. No web fetch, no
// Meta links as the only source. Quest 2 specific: this app exists to
// keep Quest 2 support alive after Meta ends it (feature updates end
// March 2027, security patches end December 2027).

class HelpScreen extends StatelessWidget {
  final AppState state;
  const HelpScreen({required this.state, super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Help', style: Theme.of(context).textTheme.headlineSmall),
        const Text('Offline guides for your Quest 2. Nothing here needs the internet, a Meta account, or a Meta server.'),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Meta is ending Quest 2 support'),
            subtitle: Text('Feature updates end March 2027 (Horizon OS v2.13 is the last). Security patches end December 2027. After that, this app keeps working offline: no Meta account, no Meta server, no new Meta app needed. Keep your backups on this computer.'),
          ),
        ),
        const SizedBox(height: 12),
        const CardGrid(cards: [
          _Guide(
            title: 'Battery care',
            body: 'Charge with the cable that came with the headset, or a good USB-C charger. Do not leave it at 0% for weeks, and do not leave it plugged in at 100% for weeks either. If the battery drains fast, lower the screen speed (Device screen, 72 or 90 Hz) and turn down brightness. A Quest 2 battery that will not hold a charge any more needs a battery swap, not a setting.',
          ),
          _Guide(
            title: 'Storage cleanup',
            body: 'Check storage on the Home screen. Free space by deleting apps you do not play (Apps, then Uninstall), clearing an app\'s cache from the app detail screen, and deleting old recordings and screenshots (Files, then Gallery, then Delete). Big games keep most of their size in OBB files; uninstalling removes those too. Back up an app first (Apps, then Backup) if you might want it back without downloading it again.',
          ),
          _Guide(
            title: 'It will not boot',
            body: 'Hold the power button for 30 seconds, then let go and press it once to turn it on. If it still does not boot, hold Power and Volume Down together until the boot menu appears, then use the volume buttons to pick "Factory reset" only as a last resort: a factory reset erases everything, so restore from a device backup afterwards (Devices, then Device backups). If the boot menu does not appear either, charge it for an hour and try again.',
          ),
          _Guide(
            title: 'Getting back into Developer Mode',
            body: 'Developer Mode is the one Meta gate, and it is free. In the Meta Horizon phone app: Menu, Devices, your headset, Headset Settings, Developer Mode, turn it on. If it turns itself off after an update, turn it on again the same way. Without Developer Mode there is no USB debugging prompt and this app cannot connect.',
          ),
          _Guide(
            title: 'Reconnecting USB or Wi-Fi',
            body: 'USB: use a data cable, not a charge-only cable. Put the headset on and tap Allow on "Allow USB debugging?", ticking "Always allow from this computer". If no prompt appears, check Developer Mode above. Wi-Fi: the headset and this computer must be on the same Wi-Fi network. In the headset, Settings, Wi-Fi, tap your network to see the IP address. In this app, Devices, "Connect a headset", then "Connect with Wi-Fi". The app also sets up Wi-Fi by itself the first time you plug in over USB.',
          ),
          _Guide(
            title: 'Pairing a controller',
            body: 'Hold the Menu button and Y together on the left controller, or Menu and B together on the right controller, until the LED blinks. Then, in the headset, go to Settings, Devices, Pair a controller. Controller battery is shown in the headset\'s quick settings; this app cannot read controller battery over USB or Wi-Fi, and it says so rather than guessing.',
          ),
          _Guide(
            title: 'Restoring from a device backup',
            body: 'On the Devices screen, under Device backups, pick a backup and tap Restore. The app first shows a dry run: what settings, Guardian data, Wi-Fi configs and apps it would put back. Read it, then confirm. Restoring overwrites the headset\'s current settings and saves, so back up the current state first if it matters. Apps come back from your library backups; an app with no library backup is listed, not reinstalled.',
          ),
          _Guide(
            title: 'What this app does not do',
            body: 'It never calls Meta or Play servers, never asks for a Meta account, and never uploads anything. Update blocking (Rooted section) only turns off the two updater apps on a rooted headset, and you can turn it back on the same way. Nothing here flashes the headset or changes the bootloader.',
          ),
          _Guide(
            title: 'Using your Quest on Linux',
            body: 'This app is the way to use a Quest 2 on Linux: manage it, back it up, keep it alive after Meta support ends, and use it on a Linux PC for desktop and PC VR, with no Windows and no Meta account needed. The pieces that do that are the ones in this app: management, backup, library, gallery, terminal, rooted mode, auto-wireless, and the Android Wi-Fi app. Later phases add home and dock switching, a Singularity install wizard, WiVRn management now, our own Linux-only PC VR streamer later, and a desktop-in-VR view where it fits.',
          ),
        ]),
        const SizedBox(height: 16),
        const Text('ReOculus: a Quest 2 companion for Linux and Android, offline and local-only.', style: TextStyle(fontSize: 13)),
      ]),
    );
  }
}

class _Guide extends StatelessWidget {
  final String title, body;
  const _Guide({required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(body),
          ]),
        ),
      );
}
