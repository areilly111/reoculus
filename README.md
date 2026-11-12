# ReOculus

**A clean companion app for Meta Quest 2 (and 3) on Linux and Android. No ads. No account. No telemetry. Nothing is uploaded anywhere.**

ReOculus (formerly Quest Companion) replaces the Meta PC app and SideQuest for everyday use: manage apps, back them up, browse files, mirror the screen, and run PC VR on Linux through WiVRn, all over USB or Wi-Fi. It is built to keep the Quest 2 alive on Linux after Meta ends its support (feature updates end with Horizon OS v2.13 in March 2027, security patches in December 2027).

![Linux](https://img.shields.io/badge/Linux-AppImage-blue) ![Android](https://img.shields.io/badge/Android-APK-green) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow) ![WiVRn](https://img.shields.io/badge/PC%20VR-WiVRn%2026.9-purple)

## What it does

| Area | What you get |
| --- | --- |
| **Apps** | List, search, launch, install (APK/APKS/XAPK), uninstall, force stop, clear data. Real icons and sizes, List or Tiles view. |
| **Backups** | Full app backup (APK + data when rooted), save-only backup, one-tap restore from the Library with a dry run first. |
| **Files** | Browse the headset storage, upload, download, delete. |
| **Mirror** | Live screen mirror over USB or Wi-Fi (scrcpy, quality picked automatically from the connection). Screenshot and on-device video recording. |
| **Device** | Battery, storage, firmware, controllers, refresh rate and performance settings, rooted-only settings in their own section. |
| **PC VR** | WiVRn 26.9 wrapper: start/stop the server, encoder and codec picker, headset client version check. The server is bundled in the AppImage, the headset app installs itself on first connect. |
| **Library** | One folder on your computer holds every backup and imported APK. |
| **Offline help** | The whole help section works with no internet. |

## Download

Grab the latest AppImage from the [Releases](../../releases) page and make it executable:

```sh
chmod +x QuestCompanion-*.AppImage
./QuestCompanion-*.AppImage
```

The AppImage bundles the whole app **and** the `questctl` backend and the WiVRn 26.9 server, so there is nothing else to install. (WiVRn installs through Flatpak on first use, so the PC needs Flatpak; the KDE runtime is fetched from Flathub the first time if it is not already installed.)

The Android APK is a full UI preview. Headset features on Android are not ready yet; the Rust backend still has to be embedded (see [Android transport](#android-transport)).

## First run

1. Put the headset in Developer Mode (free Meta developer account, toggle in the Meta Horizon phone app). This is the only step that touches Meta at all.
2. Plug the headset in over USB and tap **Connect with USB**, or tap **Connect with Wi-Fi**. The app sets up wireless ADB itself, so you can unplug after the first USB connection.
3. The first time a headset connects, the app asks to set up PC VR: it installs the WiVRn server from the bundled file, installs the WiVRn app on the headset, and sets up the USB and Wi-Fi links. After that it is just **Start** on the PC VR screen and tap the computer in the headset app. Say **Not now** and the PC VR section greys out with an **Install WiVRn** button that reopens the same setup.

## How it works

```
Flutter UI (Linux + Android)
        |
        |  one JSON object per call
        v
questctl  (Rust, quest-core)  --  spawned system adb / libadb DirectTransport
        |
        v
Meta Quest 2 / 3  (USB adb, Wi-Fi adb)
```

- **No Meta APIs, no SideQuest APIs, no account, no network calls** to anyone. The only thing that ever leaves the computer is whatever the user explicitly downloads (the WiVRn APK from GitHub Releases, on first setup).
- **Backend:** Rust workspace in `backend/` — `quest-core` library plus the `questctl` CLI. Every command prints one JSON object, `{"ok": true, ...}` or `{"ok": false, "error": "..."}`. The exact interface is in [`backend/CONTRACT.md`](backend/CONTRACT.md).
- **UI:** Flutter in `flutter_app/`. Design is **Dark VR Neon, blue** (near-black blue scaffold, bright blue accent). Other themes are in the code as options.
- **Streaming:** [scrcpy](https://github.com/Genymobile/scrcpy) for the mirror, on-device `screenrecord` for video recording.
- **PC VR:** [WiVRn 26.9](https://github.com/WiVRn/WiVRn), an OpenXR runtime and streamer built on Monado. The app drives the unmodified server (config file + process + `wivrnctl` + polling); it does not fork or embed WiVRn.

## Build from source

### Backend

```sh
cd backend
cargo test --release
cargo build --release
```

### Linux app

```sh
cd flutter_app
flutter pub get
flutter build linux --release
```

Package an AppImage with `scripts/build-appimage.sh` (see the script header for paths). It copies the Flutter bundle, `questctl`, and the bundled `wivrn-server.flatpak` into the AppDir. The WiVRn bundle itself is fetched by `scripts/fetch-wivrn.sh` and is not stored in git (it is ~7 MB of upstream binary).

### Android

```sh
cd flutter_app
flutter build apk --release
```

## Android transport

The APK today is the full UI, but headset features do not work on Android yet: there is no `questctl` binary to spawn there. The planned path is to bundle `questctl` built for Android aarch64 and use the existing libadb DirectTransport over Wi-Fi. Contributions on that piece are very welcome.

## What it deliberately does not do

- No store, no catalogue, no downloads of apps. A curated catalogue and a GitHub Releases update check are planned for a later phase, once a library database exists.
- No Beat Saber mods (parked, research only).
- No update blocking by disabling `com.oculus.updater`. That package is protected and root cannot disable it; the safe way to pause updates is Singularity's own OTA deferral, in the headset.
- It never writes home settings, never runs Singularity itself, and never touches a setting it cannot undo.

## Status

**0.2.13** (2026-11-12): app menu dropdown, anchored to the row; first-run WiVRn setup with bundled server; Browse button in the file picker dialogs; controllers read live from `getevent`; WiVRn over USB and Wi-Fi verified live on a Quest 2 with a GTX 1050 Ti. See the [Releases](../../releases) page for each version's notes.

## License and credits

This project's own code is **MIT**. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md) for the full list: WiVRn (GPLv3, bundled server only), scrcpy (Apache 2.0), SideQuest (reference only, no code used), and the other projects this app is built on or learned from.
