# ReOculus - Flutter UI

Clean, no-ads, no-account, no-telemetry companion app for Meta Quest 2.
Linux desktop first, Android second (same codebase, phone-as-host
companion over Wi-Fi). Flutter + Dart, no external Dart packages
(only the Flutter SDK), so it builds offline once Flutter is
installed.

**Quest 2 is the first-class target.** This app exists to keep Quest 2
support alive on Linux and Android after Meta ends Quest 2 updates
(feature updates end March 2027 with Horizon OS v2.13, security
patches December 2027), and to let users **use their Quest on Linux**:
manage it, back it up, keep it alive, and use it on a Linux PC for
desktop and PC VR, with no Windows and no Meta account needed.
Everything works offline with no Meta account, no Meta server, and
no new Meta app. No Quest 3-only
features as if general; where a feature differs by model it is
labelled (e.g. refresh rate: Quest 2 up to 120 Hz).

**Canonical home:** `~/quest/flutter_app/`
on the main PC. This copy in `~/workspace/quest-companion/flutter_app/`
is the VM build copy; after each batch of edits it is synced to the PC with
rsync (excluding `build/`, `.dart_tool/`, etc.). The backend path in
RealBackend is relative (`../backend/target/...`), so it works in both
locations. Do not hardcode the VM path anywhere.

**Status: design picked, Real mode only.** The structure, all 9
screens, BackendService and RealBackend wiring are built, and the
contract mismatches found on 2026-11-12 are fixed (see "Backend contract"
below). **Picked 2026-11-12: C Dark VR Neon, blue instead of purple.**
That is now the default theme in `lib/theme.dart` / `AppState`.
Other visual edits still need the owner's approval in small batches.

## Run it

### The AppImage (Linux, standalone, recommended)

Version 0.2.0 ships as a single file that bundles the Flutter app
AND the questctl backend, so it runs on its own with nothing else
to build:

```bash
chmod +x QuestCompanion-0.2.0-x86_64.AppImage
./QuestCompanion-0.2.0-x86_64.AppImage
```

It finds its bundled questctl next to the app binary, no matter
which folder you start it from. You still need Developer Mode on the
headset and the USB prompt allowed (see Setup in the app). The
AppImage is built on the main PC from the release backend
(`cargo build --release`) and the release Flutter build
(`flutter build linux --release`); see `releases/` in the canonical
folder on the PC.

### From source (developers)

On the main PC (canonical location):

```bash
cd ~/quest/flutter_app
flutter pub get
flutter run -d linux
```

On this VM (build copy):

```bash
export PATH="$HOME/workspace/flutter-sdk/bin:$PATH"
cd ~/workspace/quest-companion/flutter_app
flutter pub get
flutter run -d linux
```

### The Android APK (phone-as-host companion, Wi-Fi first)

Version 0.2.26 ships as `ReOculus-Android-0.2.26.apk`
(debug-signed, fine for sideload; no persistent release keystore
was created). On your phone:

1. Copy the APK to the phone (USB, or any file transfer you trust).
2. Tap it to install. Android will ask you to allow installs from
   unknown sources for the app you open it with (Files, Chrome,
   etc.): allow it just for that install.
3. Open ReOculus. On Home, under Headsets, tap "Connect a headset",
   then "Connect with Wi-Fi": the headset and the phone must be on the same Wi-Fi, and
   you enter the headset IP and port. If the headset already listens
   on the classic wireless debugging port (5555), leave the pairing
   code empty. The first connect shows an "Allow USB debugging?"
   prompt inside the headset for the phone's new key: tap Allow.
   The app remembers the headset address on the phone, so the next
   launch connects straight away.
4. Do NOT install the APK on the Quest itself: the companion is a
   phone app, and installing test builds on the headset needs
   the owner's say-so each time.

**What works on Android in 0.2.26 vs desktop-only:** the app bundles
the questctl Rust binary built for Android aarch64
(`backend/scripts/build-android.sh`, copied to
`assets/questctl-android-arm64` before `flutter build apk`) and
runs it with the libadb DirectTransport over Wi-Fi, so the same
shell-based headset features work from a phone: Home (Headsets), Apps,
Files, Device and Settings, Logs, Terminal, backup/restore/library/
gallery, the headset config file, and custom headset names. PC VR
and WiVRn are hidden on Android: no phone can host VR streaming
for a Quest (the research in
`research_notes/phone-to-quest-vr-streaming-20261113/` found no
shipping phone-as-host streamer). Mirror needs scrcpy, which does
not exist on a phone, so it shows an honest error. Features that
need adb push/pull/install return the backend's clear "not
implemented on the direct transport" error instead of silently
failing; discovery (listing attached devices) does not exist on the
direct transport, so Android connects by saved address only.
The APK was verified with `aapt dump badging` (package, version,
SDK levels, permissions). Live Wi-Fi testing against the real
Quest 2 still needs a phone.

The app starts in **Real mode** and stays there. There is no Demo
mode any more (removed 2026-11-12): no demo toggle, no demo banner,
no sample data anywhere. If questctl is missing or no headset is
connected, Home shows a clear error state ("Backend not
found at <path>" / "No headset connected") with what to do, never
sample data. Connect a headset from the "Connect a headset" button
(USB steps + Wi-Fi pairing, with Developer Mode help inside).

## Frontend to backend

The ONLY link between the Flutter UI and the Rust backend is
`RealBackend` spawning the `questctl` CLI as a local process. There is
no HTTP server, no Meta API, and no SideQuest backend involved.

```
Flutter UI
  -> RealBackend._run() : Process.run(cliPath, ['--json', ...args])
  -> questctl --json <command>   (Rust, ADB over USB / Wi-Fi)
  -> ONE JSON object on stdout: {"ok": true, ...} or {"ok": false, "error": "..."}
  -> parsed into models.dart (QuestDevice, DeviceInfo, QuestApp, QuestFile)
```

- Default questctl path: `../backend/target/debug/questctl`
- Fallback: `../backend/target/release/questctl`
- Or set a custom path in Setup. Paths are **relative only** — no
  hardcoded VM path and no hardcoded PC path — so the same code works
  in `~/workspace/quest-companion/` (this VM) and in
  `~/quest/` (the main PC).
- `RealBackend.findCli()` checks the configured path first, then a
  questctl bundled next to the Flutter executable (the AppImage
  layout), then the two relative candidates, in that order.
- The AppImage bundles questctl next to the Flutter binary; the
  Android build extracts the bundled aarch64 questctl asset into
  the app documents dir on first launch and runs it with the
  libadb direct transport over Wi-Fi (see "The Android APK"
  above).
- Contract: every call is checked against
  `../backend/CONTRACT.md` (2026-11-12 integration fix: `deviceInfo`
  reads `battery.level` / `battery.temperature_c` /
  `storage.total_kb` / `used_kb` in KiB converted to GB, charging =
  `battery.status` is `charging`/`full` or `plugged` is set;
  `files list` reads `entries`; `clear-data` passes `--confirm`;
  `record` passes `--out ~/quest-recordings/rec-<timestamp>.mp4
  --seconds 60`; `mirror` passes no `--preset`; profiles are mapped
  to backend built-in names; pairing uses `devices connect-wifi`).

## Real mode only (no Demo mode)

The app always uses the Real backend (`RealBackend`, spawning the
Rust `questctl` CLI). The Demo mode, `MockBackend`, demo toggle,
demo banner and all "In Demo mode..." text were removed 2026-11-12.

- Default questctl path: `../backend/target/debug/questctl`
- Fallback: `../backend/target/release/questctl`
- Or set a custom path in Setup (stored in `AppState`, applied with
  "Connect to the backend").
- If the binary is missing, the app shows "Backend not found at
  <path>" and tells you to build the backend or check the path in
  Setup. It never falls back to sample data.

How to tell it is really connected: Home shows the real
serial (`TESTSERIAL000001` for the owner's Quest 2), and Home shows the
real battery level and storage numbers from `devices info`.

## Backend contract (shared with the Rust backend agent)

Every command: `questctl --json <command>` prints ONE JSON object:
`{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

- `apps list --serial X [--third-party] [--with-icons] [--with-sizes]`
- `apps details --serial X --package <pkg>` (SDK levels, dates,
  installer, permissions, split APK paths, OBB files; maker is NOT
  stored in the APK, the UI says so in plain text)
- `apps backup/restore/backup-list/backup-delete`,
  `apps save-backup/save-restore`, `apps uninstall-system` (rooted
  only), `devices shell`, `devices debug-info`, `devices root-status`,
  `devices wifi-ip/setup-wifi/wifi-reconnect`,
  `devices controllers`, `devices update-block-status/update-block`,
  `library list/import/delete`, `device gallery-list/gallery-delete`,
  `device backup/restore/backup-list`
- `apps install --serial X --apk <path> [--reinstall]`
- `apps install-multiple --serial X --apks a.apk,b.apk`
- `apps uninstall --serial X --package <pkg> [-k]`
- `apps launch --serial X --package <pkg>`
- `files list --serial X --path /sdcard/`
- `files push/pull --serial X --local/--remote <paths>`
- `device screenshot --serial X --out <file>`
- `device record`, `settings get/set`, `settings profile apply`,
  `device logcat`, `device mirror` (spawns scrcpy)

The UI never calls ADB directly. Only `RealBackend` spawns `questctl`.

## App icons (added 2026-11-12)

The Apps screen shows each app's real launcher icon, loaded lazily:
when a row first appears, `AppState.appIcon()` asks the backend
(`apps icon --serial X --package <pkg>`), which pulls the app's
base.apk once and caches the icon under
`~/.cache/quest-companion/icons/<package>/<version>/`. The icon is
kept in an in-memory cache too, so scrolling never re-calls the
backend for the same app, and the real label from the APK replaces
the best-effort name in that row and in the app detail dialog (icon
shown at 72px). While an icon loads, or when an app has no launcher
icon at all, the row shows the initials avatar as before, never a
blank tile. First display of a big game's icon takes a few seconds
while its APK is pulled; after that it is instant from the cache.

## What was added 2026-11-12 (preservation batch)

- **App sizes and details:** Apps list shows APK size + total size
  per app; the detail dialog loads `apps details` lazily and shows
  version code, SDK levels, install/update dates, installer,
  permissions, OBB files, and "Maker: not stored in the APK" (honest:
  no maker field exists offline). `apps list --with-sizes` stays fast
  (70 apps in 2.77 s live, batched shell calls, no per-app dumpsys).
- **App backup and restore:** "Backup app" in the detail dialog
  (APKs + splits + OBB + root data tar, manifest with SHA-256);
  Backups live in the Library tab with Restore (dry-run shown first,
  confirm dialog, data restore only if asked) and Delete (local only).
- **Save backup:** "Backup save" next to "Backup app"; saves only
  (`/sdcard/Android/data/<pkg>/` + root data tar, OBB not copied by
  default). Shown separately in the Library (type: App vs Save).
- **No-connection help + auto-wireless:** "No headset connected" card
  on Home with "Connect with USB" / "Connect with Wi-Fi"
  (step-by-step dialogs, Developer Mode help inside, Refresh /
  Check again). "Connect a headset" is always reachable from Home.
  When a headset first connects over USB, the app runs
  `devices setup-wifi` once (tcpip 5555 + connect, IP saved) and
  shows "Wi-Fi connection ready, you can unplug the USB cable"; on
  failure a quiet note ("Wi-Fi setup did not work this time, USB
  still works") with Retry. Next launch with no USB device tries
  `devices wifi-reconnect` (saved IPs) first.
- **Library:** one folder (`~/.local/share/quest-companion/backups/`)
  holds app backups, save backups and imported APKs (`.apk` /
  `.apks` / `.xapk`, copied not moved, index is `library-index.json`,
  no database). Library tab: Install (APK entries), Restore
  (backups), Delete (local only).
- **Gallery:** Files screen has a Files / Gallery toggle.
  Screenshots and recordings land in `~/quest-recordings/` (both),
  shown as a grid with filename/date/size, Open (system viewer on
  Linux) and Delete (local only). Mirror Record/Screenshot buttons
  show the saved path.
- **Terminal and debug info:** Logs screen has Logs / Terminal /
  Debug info. Terminal runs `adb shell` on the selected headset
  (command shown before it runs, scrollable monospace output,
  history, Stop/Clear, warning that commands run as the shell user;
  no blocklist, the owner owns the headset). Debug info shows questctl
  version, adb version, scrcpy present/absent, backend path, device
  serial/state/transport, Android version, firmware, battery,
  storage, Wi-Fi IP, root status, with Copy debug info and Copy
  output buttons.
- **Rooted mode:** auto-detected on the connected headset
  (`devices root-status`: Magisk/su/Singularity). "Rooted mode: on"
  with the method, or "Not rooted" with a plain explanation and the
  rooted buttons hidden. Rooted features: full `/data/data` backup,
  system-app removal, `/data` file access for backups. Nothing
  flashes, re-roots or touches the bootloader. Short Singularity note
  in the docs (see backend/CONTRACT.md).
- **Update / telemetry pause (rooted only, optional, OFF by
  default):** in the Rooted section; turns off `com.oculus.updater`
  and `com.oculus.nux.ota` (reversible, nothing deleted). Telemetry
  is NOT blocked by this app (no standalone telemetry package was
  found on the Quest 2; Singularity has its own disabler) and the UI
  says so.
- **Full device backup:** Device screen, "Back up this headset now"
  (settings, Guardian data, Wi-Fi configs, app inventory; APKs are
  NOT re-copied, apps come from library backups), list of device
  backups, Restore (dry-run shown first, confirm warning) and Delete
  (local only).
- **Controllers:** Home shows controller pairing presence
  from `devices controllers`; battery and firmware are NOT readable
  offline and the UI says so, with pair-help steps (Menu + Y / Menu +
  B until the LED blinks, pair in headset Settings > Devices).
- **Offline Help:** Help screen with local plain-text Quest 2 guides
  (battery care, storage cleanup, will not boot, back into Developer
  Mode, reconnect USB/Wi-Fi, restore from a device backup, pair a
  controller), plus the note that Meta ends Quest 2 feature updates
  March 2027 / security patches December 2027. No web fetch, no Meta
  links as the only source.

**DEFERRED, do not build:** update check for sideloaded apps
(compare installed version to the library version). Needs a proper
database/index first.

**PARKED, do not build:** Beat Saber mods / song downloads
(separate parallel research; MBF current, BMBF dead).

**Later (P3, research reported 2026-11-12, no code in this turn):**
our OWN PC VR streaming implementation for Linux (WiVRn-like /
OpenXR / SteamVR runtime, Linux only, Quest 2 client only). The
research (`research_notes/own-vr-runtime-20261112/report.md`) says:
do NOT write an OpenXR runtime from scratch and do NOT fork WiVRn
(GPLv3); build a thin streaming layer on Monado (BSL-1.0) + our own
wire protocol + our own Quest client (NDK/Vulkan, not Flutter),
9-18 months part-time solo to usable. The other two later phases are
copying Meta Quest Link / Horizon Windows app management (homes, old
vs new home, old vs new taskbar) and a Singularity install wizard;
Singularity customization research
(`research_notes/singularity-customization-20261112/report.md`) says
Singularity is CLOSED-source and its DockUI/NavUI, Loft install, and
update/telemetry disabler mechanisms are NOT publicly documented, so
they must be found by a live before/after diff on the owner's Quest
before the app reimplements them. Do NOT start any of those three
until the live-diff work is done.

## Screens (all 9: left rail on desktop, bottom bar on phones)

1. Home / Dashboard: headset card, battery, storage bar, Wi-Fi setup
   note, controller names, quick actions, recent activity. "No
   headset connected" card with USB / Wi-Fi connect buttons when
   nothing is attached. Never sample data.
2. Home (Headsets): list, refresh, USB vs Wi-Fi, unauthorized guidance in plain
   words, "Connect a headset" any time, disconnect Wi-Fi, controllers
   section, Rooted section (root status + update pause), device
   backups (Backup now, list, Restore with dry-run first, Delete).
3. Apps: Apps tab (search, My apps / system filter, APK + total size
   in each row, detail dialog with full details grid, Backup app,
   Backup save, force stop, clear data, uninstall, system-app removal
   when rooted) and Library tab (app backups, save backups, imported
   APKs; Install / Restore / Delete, local only).
4. Files: /sdcard browser, breadcrumbs, upload/download with progress,
   OBB helper note. App private data is honestly not shown. Gallery
   toggle: screenshots + recordings grid (`~/quest-recordings/`).
5. Device and Settings: device info, refresh rate (Quest 2 capped at
   120 Hz; higher rates only offered for non-Quest-2 headsets), CPU/GPU
   level, guardian pause, brightness, saveable profiles, reboot
   (confirm). Warns settings reset on reboot and are reapplied on connect.
6. Mirror: big Mirror button (scrcpy via backend), quality presets
   (Performance / Balanced / Quality), Record, Screenshot, saved path
   shown. Recordings go to `~/quest-recordings/`.
7. Logs: live logcat viewer, filter, pause/clear, export to file;
   Terminal tab (adb shell with history, Stop/Clear, Copy output);
   Debug info tab (questctl/adb/scrcpy/backend path/device/battery/
   storage/Wi-Fi IP/root, Copy debug info).
8. Help: offline Quest 2 guides (battery, storage, will not boot,
   Developer Mode, reconnect, restore, pair a controller, Meta
   end-of-support note).
9. Setup / Onboarding: first-run checklist (Developer Mode link-out, no
   login in-app, udev rule), backend path + "Connect to the backend",
   design direction picker (Dark VR Neon picked, blue). No demo
   toggle: Real mode only.

## Android path (phone-as-host companion, Wi-Fi first)

Same Flutter single codebase, same features, on Android as a
phone-as-host companion, **Wi-Fi ADB only** (no USB OTG host;
a phone cannot run an adb server over USB to the headset).
Pair/connect over Wi-Fi (modern TLS pairing with the 6-digit code
where needed, plus legacy tcpip 5555 where the Quest accepts it).
Coverage: devices, apps (list/icons/sizes; install/uninstall are
blocked by the direct transport, which has no push/pull yet),
files (read-only listing where the transport allows), device
settings, logs, backup/restore/library/gallery/terminal/debug,
rooted mode, no-connection help + auto-wireless (on Android,
auto-wireless means: once paired, remember the Quest IP and
reconnect automatically), offline help. PC VR and WiVRn are hidden
on Android (no phone can host VR streaming for a Quest); mirror
needs scrcpy, which does not exist on a phone.

**What is ready:** the Android transport is built (0.2.26): the
bundled aarch64 questctl asset is extracted on first launch and run
with the libadb direct transport. The UI is already responsive:
`lib/main.dart` uses a bottom navigation bar on narrow screens
(< 700 px) and the desktop NavigationRail on wide screens, same
screens, same features.
No desktop-only dependency is in the Dart code except `Process.run`
calls in `RealBackend` (questctl spawn), `xdg-open` (gallery open,
Linux only, falls back to showing the path on Android), and the
`dart:io` `File` reads for gallery thumbnails and log export
(works on Android too, paths differ). The backend path is relative
and settable in Setup.

**What still needs the android/ platform added and tested:**
`flutter create --platforms=android` (project name
`quest_companion`, package id `com.questcompanion.app` or similar,
document it when chosen), then the architecture decision: on Linux
the UI spawns the questctl Rust binary, which does NOT work on
Android. Options: (a) embed Rust quest-core via
flutter_rust_bridge / JNI, (b) build questctl as an Android
executable bundled in the APK and run it, or (c) a Dart ADB client
for Wi-Fi (TLS/SPAKE2 pairing is the hard part; the backend's
libadb DirectTransport spike is the knowledge to reuse). Do not
invent a new protocol; reuse quest-core transport where possible. If
(a) is too big for one turn, deliver a working v1 with the transport
that works (Wi-Fi list/info/apps/files) and clearly list the
desktop-only screens, rather than a broken full port. Debug APK
first, then release APK (unsigned debug-signed is fine for sideload;
do NOT create a persistent release keystore without asking the owner).
Test live vs the real Quest 2 over Wi-Fi from a real Android device
if one is available; otherwise test what is possible (build, `aapt
dump badging`, emulator start) and state clearly what was and was
not live-tested on a real phone. Deliver the APK to
`~/workspace/your_files/QuestCompanion-Android-<version>.apk` AND
the PC canonical folder.

## Design directions

See `DESIGN_OPTIONS.md` and `design-options/*.webp`. The app already
supports all three via `lib/theme.dart` (`DesignDirection`) and the
Setup screen switcher, so picking one later is a one-setting change,
not a rewrite.

## Files

- `lib/main.dart` - app shell, NavigationRail (desktop) / bottom
  bar (phones), 9 screens
- `lib/models.dart` - QuestDevice, DeviceInfo, QuestApp, AppDetails,
  BackupEntry/Report, RestoreReport, LibraryEntry, GalleryEntry,
  ShellResult, RootStatus, ControllersInfo, UpdateBlockStatus,
  WifiSetupResult, DebugInfo, DeviceBackupEntry, QuestFile, profiles
- `lib/theme.dart` - the 3 design directions as ThemeData
- `lib/services/backend.dart` - BackendService, RealBackend only
  (no MockBackend any more)
- `lib/services/app_state.dart` - selected device, Real-only backend,
  design, activity, root/controller state, auto-wireless note
- `lib/screens/home_devices.dart` - Home + Devices + connect dialog
- `lib/screens/apps_files.dart` - Apps + Library + Files + Gallery
- `lib/screens/device_mirror_logs_setup.dart` - Device, Mirror, Logs
  (logcat + Terminal + Debug info), Setup
- `lib/screens/help.dart` - offline Quest 2 help guides
- `lib/widgets/common.dart` - shared cards, dialogs, snackbars, path picker

## Verification status (VM + main PC, 2026-11-12)

- **Version 0.2.0 (shipped 2026-11-12).** pubspec 0.2.0+2,
  quest-core + questctl 0.2.0, About screen says 0.2.0.
- Flutter SDK 3.35.7 installed at `~/workspace/flutter-sdk`, Dart 3.9.2.
- `flutter analyze` (PC, 2026-11-12): **19 issues, all info-level**
  (`use_build_context_synchronously` around `mounted` guards, in
  the pre-existing style), **zero warnings, zero errors**.
- `flutter build linux --release` (PC, 2026-11-12): **built**
  `build/linux/x64/release/bundle/quest_companion` (23,888 bytes).
- `cargo build --release` (PC, 2026-11-12): **built**, questctl
  0.2.0 (`questctl --version` prints `questctl 0.2.0`), ~6.7 MB.
- Backend `cargo test`: **31 tests pass** (18 + 6 + 7) in this VM.
- **AppImage 0.2.0 (PC, 2026-11-12):**
  `QuestCompanion-0.2.0-x86_64.AppImage`, 19,872,248 bytes,
  SHA-256
  `7244e77ac1e2f8d1eb54dac4de0ccb3ab46c8414392beba6a5451835cd06c1c4`.
  Built with `scripts/build-appimage.sh` (appimagetool, installed at
  `~/appimagetool-x86_64.AppImage` on the PC). Bundles the Flutter
  app AND questctl 0.2.0 side by side; the extracted AppImage's
  `usr/bin/questctl --version` prints 0.2.0 and `--json devices
  list` shows the real Quest 2 over USB and Wi-Fi. Launched under
  `xvfb-run` with a 25 s timeout: stayed running, no crash (exit
  124 = timeout kill), only a harmless Gdk cursor-theme message.
  The app finds its bundled questctl next to its own executable.
  Delivered to `~/workspace/your_files/` and to
  `~/quest/releases/` on the PC
  (same file, same SHA-256).
- **Android APK 0.2.0 (PC, 2026-11-12):**
  `QuestCompanion-Android-0.2.0.apk`, 48,813,995 bytes, SHA-256
  `068e3bbec279d5f6171a46682d7e48bd5985512c66a31b369d09151d8b34b01b`.
  `flutter build apk --release`, debug-signed (no persistent
  release keystore created). `aapt2 dump badging`: package
  `com.questcompanion.quest_companion`, versionCode 2, versionName
  0.2.0, compileSdk/targetSdk 36, INTERNET + ACCESS_NETWORK_STATE
  permissions, label "ReOculus", launchable MainActivity.
  Delivered to `~/workspace/your_files/` and to `releases/` on the
  PC (same SHA-256). **Not install-tested**: no Android device or
  emulator was available, and installing it on the Quest itself is
  not allowed without the owner's say-so. Live Wi-Fi testing against
  the real Quest 2 still needs his phone.
- `flutter build linux`: **not run in this VM**. It needs `libgtk-3-dev`,
  and apt in this VM currently refuses it: `libzstd-dev` depends on
  `libzstd1 (= 1.5.5+dfsg2-2build1.1)` but `1.5.5+dfsg2-2build1.1+hatch1`
  is installed ("held broken packages"). Do not downgrade libzstd1 blindly.
  Linux builds happen on the main PC (see above).
- Backend `cargo test`: **31 tests pass** (18 + 6 + 7) in this VM
  after the sizes/backup/wireless/library/gallery/device-backup
  batch, zero warnings at last check.
- Real mode verified end to end, 2026-11-12, against the live Quest 2
  (serial `TESTSERIAL000001`, USB, on the main PC) via the PC release
  binary: `devices list` -> Quest 2, state `device`, usb;
  `devices info` -> Android 14, firmware [redacted firmware], battery
  100% / status full / USB powered, 27.7 C, storage 86 GB used /
  112 GB total (26 GB free), resolution 3664x1920; `apps list` ->
  235 apps with real names (BONELAB, Beat Saber, OpenBrush...);
  `files list /sdcard/` -> 30 entries with real names (Morrowind,
  Open Brush, Bully VR, tes3mpvr...). Sizes verified live (see
  backend/README.md): OpenBrush 236 MB APK, Beat Saber 5.30 GB total,
  BONELAB 6.37 GB total, all matched `ls`/`du`. App backup (Moonlight,
  6,275,494 B, manifest hashes good), save backup (OpenBrush, 223
  files, 75,565,625 B), device backup (~87.57 MB in 6.2 s),
  auto-wireless (`setup-wifi` worked: IP 192.168.1.50, wireless
  serial appeared, shell over Wi-Fi returned "Quest 2"), root
  detection (Magisk, su, Singularity), controllers (count 0,
  battery/firmware not readable, as documented), update block
  (`com.oculus.updater` already disabled, likely by Singularity),
  library import (Moonlight, SHA matches). No install / uninstall /
  clear-data / delete / reboot / restore was run on the real headset;
  restores were `--dry-run` only.
- Live bug found and fixed the same day: `files list` returned only
  2 mangled entries on the real Quest because its `ls` prints ISO
  dates (`2026-11-11 19:39`); see backend/README.md. After the fix
  the live listing is the full 30 entries above.
- Minor known cosmetic issue (not fixed here): commands that return
  no `message` field (record, screenshot, delete, profile apply,
  reboot) produce an empty snackbar message in the UI. A v1 polish
  item: fall back to a summary of the returned data in
  `RealBackend._toResult`.

## What still needs the owner

- Run the AppImage on the main PC (`chmod +x
  QuestCompanion-0.2.0-x86_64.AppImage`, then run it), tap Apps,
  try Backup on an app, and confirm he is OK with the restore
  warning before ever restoring (restores were dry-run only so far).
- Tap through the new screens on the real Quest 2: no-connection
  dialog wording, auto-wireless note, Library, Gallery, Terminal,
  Rooted section, device backup list, Help. No demo banner should
  appear anywhere, and Setup should have no demo toggle.
- Unplug test: after the first USB connect sets up Wi-Fi, unplug the
  cable and check the wireless connection stays up.
- Android: install the APK on his phone, pair over Wi-Fi, tap
  through it (see "The Android APK" above). The Android Wi-Fi
  transport is the next build; in 0.2.0 the app honestly says it is
  not ready yet.
- Live tests still open: a real `apps restore` / `apps save-restore`
  / `device restore` onto the headset (needs his OK first), a real
  APK / `.apks` install, screenshot / record / mirror on hardware,
  TLS pairing with the 6-digit code against the headset's Wireless
  debugging screen.
