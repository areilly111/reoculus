# Credits and third-party notices

ReOculus's own code (the Rust backend, the Flutter UI, the app
itself) is MIT licensed, see `LICENSE`. This project stands on the work
below. Nothing in this file changes the licence of any of those projects.
Where a component ships with a release, its licence travels with it:
the AppImage carries `LICENSE`, this file, and the full GPLv3 text
(`licenses/GPL-3.0.txt`) under `usr/share/doc/reoculus/`.

## Bundled with the AppImage

| Component | Licence | Source | How it is used |
| --- | --- | --- | --- |
| **WiVRn 26.9** (server Flatpak bundle, `wivrn-server.flatpak`) | **GPLv3** | https://github.com/WiVRn/WiVRn (this release: https://github.com/WiVRn/WiVRn/releases/tag/v26.9) | The PC VR server. Shipped as the unmodified upstream Flatpak bundle and installed with `flatpak install --user` on first use. It runs as a separate process; ReOculus never links to it and does not fork it. The full GPLv3 text is in `licenses/GPL-3.0.txt` and at https://www.gnu.org/licenses/gpl-3.0.txt. The corresponding source for the bundled build is the WiVRn repository at the v26.9 tag above. |
| **WiVRn client APK** (`WiVRn-release.apk`, downloaded on first setup, not stored in git) | **GPLv3** | https://github.com/WiVRn/WiVRn/releases | Installed on the headset over ADB when the user sets up PC VR. Same GPLv3 terms as the server. |

## Used at runtime, not bundled

| Component | Licence | Source | How it is used |
| --- | --- | --- | --- |
| **scrcpy** | Apache 2.0 | https://github.com/Genymobile/scrcpy | Screen mirroring. Runs as the system `scrcpy` binary; ReOculus spawns it and never embeds it. |
| **Android platform tools (adb)** | Apache 2.0 | https://developer.android.com/tools/adb | The transport to the headset. Runs as the system `adb` binary. |
| **Singularity** (APK, Frida server binary, domain blocklist) | Closed source (no open-source licence granted) | https://github.com/Lumince/singularity | Downloaded at runtime only when the user asks: the Singularity APK from its GitHub releases, the Frida server binary and the `hosts` blocklist from the repo. Nothing is bundled with ReOculus and nothing is stored in git. Singularity itself is never copied or reimplemented, only its published downloads and settings are used. |
| **Frida** (the Frida server binary, as shipped in the Singularity repo) | wxWindows Library Licence 3.1 | https://github.com/frida/frida | A researcher tool for inspecting processes on the headset. Downloaded at runtime from the Singularity repo when the user asks for it, never bundled. |
| **Lightning Launcher** (APK, from its GitHub releases) | GPL-3.0 | https://github.com/threethan/LightningLauncher | A launcher that replaces the apps menu. Downloaded at runtime when the user asks for it, never bundled. Also free on the Meta Quest Store. |
| **Quest Home Switcher** (APK, from its GitHub releases) | Closed source (no open-source licence granted) | https://github.com/nikitat21/Quest-Home-Switcher | Manages custom 3D home environments. Downloaded at runtime when the user asks for it, never bundled. Its homes catalogue lives inside the app. |
| **xrizer** (bundled inside the WiVRn Flatpak) | GPL-3.0 | https://github.com/Supreeeme/xrizer | OpenVR-to-OpenXR translation for SteamVR games under Proton. Part of the WiVRn Flatpak, not our code. |
| **Monado** (the base of WiVRn) | BSL-1.0 | https://monado.freedesktop.org | OpenXR runtime that WiVRn builds on. Not our code. |

## Learned from (no code copied)

| Project | Licence | Source | What we learned from it |
| --- | --- | --- | --- |
| **SideQuest** (desktop app) | MIT | https://github.com/SideQuestVR | The feature model for a Quest companion: apps, files, sideloading, settings, streaming. The desktop app is open source, the store and backend are not. ReOculus reimplements the idea from scratch; no SideQuest code is used, and nothing is scraped from SideQuest. |
| **Quest Home Switcher** (itsmattkc's, a different project from the nikitat21 app above) | (see its repo) | https://github.com/itsmattkc/quest-home-switcher | How custom Quest homes are packaged. Used as a reference only. |
| **Envision** | GPL-3.0 | https://github.com/WiVRn/envision | Prior art for launching and driving a Monado/WiVRn runtime from a GUI. |
| **Monadeck** | (see its site) | https://monadeck.eidenz.com/ | Prior art for a SteamVR-style dashboard and launcher for Monado. No code used. |

## Frameworks and libraries

**Rust crates** (the exact set and versions at each release are pinned in
`backend/Cargo.lock`, which is tracked in git):

| Crate | Licence | Version at 0.2.24 |
| --- | --- | --- |
| base64 | MIT OR Apache-2.0 | 0.22.1 |
| clap | MIT OR Apache-2.0 | 4.6.7 |
| libadb | MIT | 0.9.0 |
| libc | MIT OR Apache-2.0 | 0.2.191 |
| serde | MIT OR Apache-2.0 | 1.0.229 |
| serde_json | MIT OR Apache-2.0 | 1.0.154 |
| sha2 | MIT OR Apache-2.0 | 0.10.9 |
| tempfile | MIT OR Apache-2.0 | 3.27.0 |
| tokio | MIT | 1.54.1 |
| zip | MIT | 2.6.1 |

**Flutter and Dart packages:**

| Package | Licence |
| --- | --- |
| Flutter and Dart SDK | BSD 3-Clause, https://flutter.dev |
| file_picker | MIT (Copyright 2018 Miguel Ruivo), https://pub.dev/packages/file_picker |
| flutter_lints (dev only) | BSD 3-Clause |

**Android Open Source Project** (the headset's OS) — Apache 2.0.

## Trademarks

Meta, Quest, Oculus, and Horizon are trademarks of Meta Platforms, Inc.
SideQuest is a trademark of its owners. This project is not affiliated
with, endorsed by, or connected to Meta, SideQuest, or WiVRn. The name
ReOculus is our own name for this independent companion app, a nod to the
old Oculus branding, not a claim of any connection to Meta.
