# Quest companion — backend (Rust core + `questctl` CLI)

Clean, no-ads, no-account, no-telemetry companion for Meta Quest 2.
Builds on **ADB, not Meta APIs**. Quest 2 is the first-class target:
the app exists to keep Quest 2 support alive on Linux and Android
after Meta ends Quest 2 updates (feature updates end March 2027,
security patches December 2027) — and to let users **use their Quest
on Linux**: manage it, back it up, keep it alive, and use it on a
Linux PC for desktop and PC VR, with no Windows and no Meta account
needed. Linux first, Quest 2 first. No Windows-only features, no
Windows machine assumed. Linux desktop first; the same core is
meant to be reused by the Android app later (see
`../flutter_app/README.md` for the Android path) and by the
Flutter UI, which talks to the backend only through the `questctl` JSON
CLI — see [CONTRACT.md](CONTRACT.md).

**This directory is the backend agent's. Do not edit
`../flutter_app/` (the UI agent owns it).**

## Layout

```
backend/
  Cargo.toml            # workspace: quest-core + questctl
  CONTRACT.md           # the questctl JSON contract (shared with the UI agent)
  quest-core/           # library: transport, devices, apps, files, settings, media, keys
    src/
      lib.rs  error.rs  keys.rs  transport.rs
      devices.rs  apps.rs  files.rs  settings.rs  media.rs
      backup.rs       # app backup/restore + save backup/restore
      wireless.rs     # wifi_ip, root_status, setup_wifi, known-wireless store
      library.rs      # APK library (backups + imported APKs, library-index.json)
      gallery.rs      # screenshot/recording gallery (~/quest-recordings/)
      device_backup.rs  # full device backup/restore
      update_block.rs   # rooted-only updater pause (disable/enable, reversible)
    tests/
      parsers.rs        # unit tests for the pure parsers
      mock_adb.sh       # canned adb for integration tests
      fixtures/         # real dumpsys samples captured live 2026-11-12
        dumpsys-openbrush.txt  dumpsys-beatsaber.txt  dumpsys-bonelab.txt
  questctl/             # the CLI binary the UI calls
    src/main.rs
    tests/cli_mock.rs   # end-to-end tests against mock_adb.sh
```

## Build

Rust is at `~/.cargo/bin` (rustc/cargo 1.99.0); it is **not** on PATH
by default in this VM, so prefix every cargo command:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cd ~/workspace/quest-companion/backend
cargo build            # debug, target/debug/questctl
cargo build --release  # release, target/release/questctl
cargo test
```

The `adb` binary is resolved as: `QUEST_COMPANION_ADB` env, then
`QUEST_ADB`, then `~/workspace/android-sdk/platform-tools/adb`, then
`~/Android/Sdk/platform-tools/adb`, then `adb` on PATH.

scrcpy is **not** installed in this sandbox. `device mirror` fails
cleanly with install instructions until it is
(`sudo apt install scrcpy`, or the GitHub releases).

## Phase 0 spike — libadb (result)

**Verdict: PASS for capability, with a scope note.**

- `libadb` 0.9.0 (crates.io, 2026-11-12) ships everything the report
  hoped for: `tls` feature (TLS 1.3 / `STLS`, `Connection::connect_tls`),
  `pairing` feature (SPAKE2, `pairing::pair`, 6-digit code, returns the
  device GUID), `keys` (`AdbKey` RSA-2048 generate / PKCS#8 load /
  public-key line), `sync` (STAT/LIST/SEND/RECV), shell v1/v2
  (`shell::v2::exec` with exit code), `exec:` (binary-clean), logcat,
  and `nusb`/`rusb` USB transports. Pre-1.0, API may break.
- **What it does NOT ship:** no high-level API (no `devices` list, no
  install, no USB device discovery helper — you enumerate USB yourself
  via nusb and open the bulk endpoints), no mDNS discovery, no adb
  server. It is a low-level protocol library; the app logic (device
  model, install sessions, `pm`/`am` command building) is ours.
- **Decision (this build):** the shipped CLI defaults to the
  **`adb`-binary transport** behind the `AdbTransport` trait — zero
  protocol risk, full pairing/install/sync for free. A real
  **`DirectTransport` (libadb, TCP/TLS)** is implemented alongside it
  for Wi-Fi shell / exec-out / TLS pairing, selectable with
  `--transport direct` (+ `--addr <ip>:<port>`) or `QUEST_TRANSPORT=direct`.
  Direct push/pull/install and USB-direct are not implemented yet and
  return a clear error pointing at the binary transport. That is the
  honest Phase 0 outcome: the direct path is proven to connect (API +
  compile verified), not yet the default.

## How to run each command

```sh
export PATH="$HOME/.cargo/bin:$PATH"
BIN=~/workspace/quest-companion/backend/target/debug/questctl

$BIN --json devices list
# {"devices":[],"ok":true}   (empty when no Quest is attached — not a crash)

$BIN --json devices info --serial TESTSERIAL000001
$BIN --json apps list --serial TESTSERIAL000001 [--third-party] [--with-icons]   # --with-icons: cached icons only, never pulls APKs
$BIN --json apps icon --serial TESTSERIAL000001 --package com.beatgames.beatsaber [--out ~/icon.png]   # real label + launcher icon, cached at ~/.cache/quest-companion/icons/<package>/<version>/
$BIN --json apps install --serial TESTSERIAL000001 --apk ~/Downloads/game.apk [--reinstall]
$BIN --json apps install --serial TESTSERIAL000001 --apk ~/Downloads/game.apks   # bundle, auto-unzipped
$BIN --json apps install-multiple --serial TESTSERIAL000001 --apks base.apk,split.apk
$BIN --json apps uninstall --serial TESTSERIAL000001 --package com.example.foo [-k]
$BIN --json apps launch --serial TESTSERIAL000001 --package com.example.foo
$BIN --json apps force-stop --serial TESTSERIAL000001 --package com.example.foo
$BIN --json apps clear-data --serial TESTSERIAL000001 --package com.example.foo --confirm

$BIN --json files list --serial TESTSERIAL000001 --path /sdcard/
$BIN --json files push --serial TESTSERIAL000001 --local ./x.apk --remote /sdcard/x.apk
$BIN --json files pull --serial TESTSERIAL000001 --remote /sdcard/x.apk --local ./x.apk

$BIN --json device screenshot --serial TESTSERIAL000001 --out ~/shot.png
$BIN --json device record --serial TESTSERIAL000001 --out ~/rec.mp4 --seconds 60   # max 180
$BIN --json device logcat --serial TESTSERIAL000001
$BIN --json device logcat --serial TESTSERIAL000001 --follow   # raw stream, no JSON
$BIN --json device mirror --serial TESTSERIAL000001           # needs scrcpy

$BIN --json settings get --serial TESTSERIAL000001 --key debug.oculus.refreshRate
$BIN --json settings set --serial TESTSERIAL000001 --key debug.oculus.refreshRate --value 90
$BIN --json settings profile list
$BIN --json settings profile apply --serial TESTSERIAL000001 --profile balanced

$BIN --json devices pair-wifi --serial TESTSERIAL000001        # legacy tcpip 5555
$BIN --json devices connect-wifi --ip 192.168.1.42 --port 37281 --code 123456   # TLS pair
$BIN --json devices connect-wifi --ip 192.168.1.42 --port 5555                  # connect
$BIN --json devices disconnect-wifi --serial 192.168.1.42:5555   # added 2026-11-12
$BIN --json device reboot --serial TESTSERIAL000001              # added 2026-11-12
$BIN --json files delete --serial TESTSERIAL000001 --remote /sdcard/old.txt   # /sdcard/ only, added 2026-11-12

# Sizes and details (added 2026-11-12):
$BIN --json apps list --serial TESTSERIAL000001 --third-party --with-sizes   # APK/data/OBB/total bytes, SDK levels, dates, installer, permissions
$BIN --json apps details --serial TESTSERIAL000001 --package com.beatgames.beatsaber   # one app, lazily

# App backup / restore (added 2026-11-12). Default root ~/.local/share/quest-companion/backups/:
$BIN --json apps backup --serial TESTSERIAL000001 --package com.limelight [--skip-data]
$BIN --json apps restore --serial TESTSERIAL000001 --backup <dir> --dry-run   # always dry-run first; real restore needs --confirm
$BIN --json apps restore --serial TESTSERIAL000001 --backup <dir> --confirm [--include-data]
$BIN --json apps backup-list
$BIN --json apps backup-delete --backup <dir>   # local files only
$BIN --json apps save-backup --serial TESTSERIAL000001 --package com.Icosa.OpenBrush   # saves only
$BIN --json apps save-restore --serial TESTSERIAL000001 --backup <dir> --dry-run
$BIN --json apps uninstall-system --serial TESTSERIAL000001 --package <pkg>   # rooted only

# Wireless / root / controllers / update block (added 2026-11-12):
$BIN --json devices wifi-ip --serial TESTSERIAL000001
$BIN --json devices setup-wifi --serial TESTSERIAL000001   # tcpip 5555 + connect, saves IP
$BIN --json devices wifi-reconnect   # try saved IPs when no USB device is present
$BIN --json devices root-status --serial TESTSERIAL000001
$BIN --json devices controllers --serial TESTSERIAL000001   # battery/firmware NOT readable offline; note says so
$BIN --json devices update-block-status --serial TESTSERIAL000001
$BIN --json devices update-block --serial TESTSERIAL000001 --block   # rooted only, off by default, reversible
$BIN --json devices shell --serial TESTSERIAL000001 --command 'ls /sdcard/'   # 120 s timeout
$BIN --json devices debug-info --serial TESTSERIAL000001

# Library / gallery (added 2026-11-12):
$BIN --json library list
$BIN --json library import --file ~/Downloads/game.apk   # .apk / .apks / .xapk, copied into the library
$BIN --json library delete --path <path>   # local files only
$BIN --json device gallery-list   # ~/quest-recordings/, newest first
$BIN --json device gallery-delete --file ~/quest-recordings/shot-....png   # local file only

# Full device backup (added 2026-11-12):
$BIN --json device backup --serial TESTSERIAL000001
$BIN --json device restore --serial TESTSERIAL000001 --backup <dir> --dry-run   # always dry-run first; real restore needs --confirm
$BIN --json device backup-list

# Direct (libadb) transport, Wi-Fi only:
$BIN --json --transport direct --addr 192.168.1.42:37281 devices info --serial 192.168.1.42:37281
```

## Security

- A fresh RSA-2048 ADB keypair is generated once per install at
  `~/.config/quest-companion/adbkey` (private, mode 0600) +
  `adbkey.pub`. Fingerprint is the base64 SHA-256 of the public key
  blob — the same fingerprint the headset shows in its
  "Allow USB debugging?" prompt. No shared key is shipped.
- If `~/.android/adbkey` does not exist yet, a copy of our key is
  installed there so the spawned `adb` actually authenticates as our
  key. An existing user adb key is never overwritten.
- Pairing codes are 6-digit, short-lived, and never logged.
- Local only: no network calls to Meta/SideQuest, no telemetry, no
  account. The only network traffic is ADB to the headset (USB or LAN).
- `debug.oculus.*` settings are volatile (clear on reboot) — profiles
  are meant to be reapplied on connect.

## App icons 2026-11-12

`apps icon` pulls an app's base.apk once, reads its real label and
launcher icon with `aapt2`/`aapt dump badging` (highest-density
`application-icon-*`), extracts that file from the APK zip, and
caches it at `~/.cache/quest-companion/icons/<package>/<version>/`
(`icon.png`/`icon.webp` + `label.txt`). A second call is a cache hit.
`apps list --with-icons` only attaches icons already in the cache —
it never pulls APKs, so a 235-app list stays fast. Verified live:
OpenBrush (label "Open Brush", icon `res/oj.png`, 17,281 bytes PNG),
BONELAB (label "BONELAB", `res/mipmap-xxxhdpi/app_icon.png`),
Beat Saber (aapt fails on its APK with "Bad string block" — the
mipmap zip-scan fallback finds `res/mipmap-xxxhdpi/app_icon.png`,
20,701 bytes PNG), VrShell (no launcher icon at all, clean error,
UI falls back to initials). WebP icons are returned as-is.

## Integration fix 2026-11-12 (contract vs UI audit)

The UI's RealBackend was checked call-by-call against CONTRACT.md and
`main.rs`. Three commands were missing and were added, with tests:
`devices disconnect-wifi --serial X` (`adb disconnect <serial>`,
no `-s` form), `device reboot --serial X` (`adb -s X reboot`), and
`files delete --serial X --remote <path>` (`rm -rf`, refused before
any adb call unless the path is under `/sdcard/`, never `/sdcard`
itself, no `..`). CONTRACT.md records all three plus the charging
rule (`battery.status` charging/full, or `plugged` set), the
`files list` `entries` key, and that `device mirror` takes no
`--preset` (presets are UI-only for now; scrcpy args mapping is v1).
On the UI side the same change fixed: `deviceInfo` battery-object /
storage-KiB parsing, `files list` `entries`, `clear-data --confirm`,
`device record --out ~/quest-recordings/rec-<timestamp>.mp4 --seconds 60`,
`settings profile apply --profile <name>` (UI names mapped to the
backend built-ins: Balanced→balanced, Smooth→high-refresh,
Battery saver→battery-saver), `devices connect-wifi` for pairing,
file delete wired with a confirm dialog, and `.apks`/`.xapk` bundles
now go through `apps install --apk` (the backend unzips them) instead
of `install-multiple` with a single bundle path.

**Live bug found during verification on the real Quest 2
(2026-11-12, same day):** `files list /sdcard/` returned only
2 entries ("Brush", "VR") while raw `adb shell ls -la /sdcard/`
shows ~30. Cause: the real Quest prints ISO dates
(`2026-11-11 19:39`, two tokens), but `parse_ls_line` always
consumed three tokens as the date, so it ate single-word names
entirely and mangled multi-word names ("Open Brush" → "Brush").
Fixed in `quest-core/src/files.rs` (date length detected from the
first date token; ISO = 2 tokens, month name = 3), with parser +
mock-adb regression tests. Re-verified live after the fix: the full
/sdcard/ listing comes back.

## What is tested

- `cargo test`: **31 tests, all passing** (2026-11-12, re-run after the
  sizes/backup/wireless/library/gallery/device-backup batch).
  - 18 parser unit tests (`quest-core/tests/parsers.rs`): devices output
    (incl. `no permissions` two-word state, Wi-Fi serials), getprop /
    battery / df / wm, pm list + dumpsys versions + install error
    mapping, `ls -la` lines (incl. names with spaces), dumpsys fields
    (versionCode/minSdk/targetSdk, install/update times, installer,
    requested permissions) against real dumpsys fixtures, controller
    parsing, update-block parsing.
  - 6 + 7 end-to-end CLI tests (`questctl/tests/cli_mock.rs` and
    others) against `quest-core/tests/mock_adb.sh`: devices list/info,
    apps list/install/install-multiple/bundle/uninstall/launch/force-stop/
    clear-data (incl. the `--confirm` refusal), files list/push/pull,
    files delete (happy path + refusals for outside /sdcard/,
    /sdcard itself, and `..`), screenshot (PNG magic verified), record
    (incl. 180 s clamp), logcat dump, mirror-missing-scrcpy error,
    settings get/set (incl. 240 Hz refusal on Quest 2, unknown-key
    refusal), profiles, pair-wifi / connect-wifi (pair + connect),
    disconnect-wifi, device reboot, backup manifest hash verification,
    backup folder layout, restore dry-run.
- Manual smoke: `cargo build` (debug + release; release finished in
  3m 22s, binary 6.0 MB), `questctl --json devices list` against the
  real SDK adb with no device attached → `{"devices":[],"ok":true}`,
  exit 0. `--transport direct devices list` → clean "no device
  discovery" error, exit 1. `settings profile list` on the release
  binary → all four built-in profiles. Unknown subcommand → clap
  error, exit 2.

## Live verification on the real Quest 2 (2026-11-12)

**Release 0.2.0 (shipped 2026-11-12):** quest-core + questctl 0.2.0.
`cargo build --release` on the PC; `questctl --version` prints
`questctl 0.2.0`. The AppImage bundles this binary with the Flutter
app (`scripts/build-appimage.sh`);
`QuestCompanion-0.2.0-x86_64.AppImage`, 19,872,248 bytes, in
`releases/` on the PC and in `~/workspace/your_files/`.

All of this was verified live against the owner's Quest 2 (serial
TESTSERIAL000001, USB, Android 14, firmware [redacted firmware], rooted
with Singularity/Magisk), from the PC build. Nothing destructive was
run on the headset: no install, uninstall, clear-data, delete, reboot
or restore; restores were `--dry-run` only.

- `devices list` / `info`: Quest 2, state `device`, usb; battery
  100% / 28.2 C / 4381 mV, storage 117,719,436 KB total / 90,542,600 KB
  used / 27,045,764 KB free, resolution 3664x1920, density 200.
- `apps list --with-sizes`: 70 third-party apps in 2.77 s, 70/70 with
  APK sizes, 70/70 with totals. `apps details` 0.28 s per app.
  - OpenBrush v2.31.0 (code 20310001), minSdk 29, targetSdk 34,
    installed 2025-03-03, updated 2026-08-30, installer
    `com.oculus.ocms`, 13 permissions; APK 247,256,857 B, data
    59,144 B, OBB 3,488 B, total 247,319,489 B.
  - Beat Saber v1.45.3_30054 (code 3237), minSdk/targetSdk 32,
    installed/updated 2026-11-09, installer "sideloaded (adb)", 10
    permissions; APK 90,898,439 B, data 98,445,806 B, OBB
    5,505,138,130 B (includes ~280 custom-song folders inside the OBB
    dir), total 5,694,482,375 B. Label stays "beatsaber".
  - BONELAB v1.2974.57485 (code 2974), minSdk/targetSdk 32,
    installed/updated 2026-11-10, installer "sideloaded (adb)", 9
    permissions; APK 74,791,924 B, data 10,464 B, OBB 6,769,656,377 B,
    total 6,844,458,765 B.
  - All sizes matched manual `ls`/`du` exactly. **Maker is not
    available offline** (no author field in APK/dumpsys/aapt); the UI
    shows "Maker: not stored in the APK". Data size needs root
    (shell user gets "Permission denied"; via `su -c` it works).
- App backup: Moonlight `com.limelight` v12.1 to a temp dir on the PC:
  base.apk 3,852,725 B + `split_config.arm64_v8a.apk` 2,421,165 B +
  data.tar.gz 513 B, manifest SHA-256s good, total 6,275,494 B.
  Restore `--dry-run` OK. Smallest-app scan picked Moonlight
  (3.87 MB total).
- Save backup: OpenBrush, 223 files, 75,565,625 B total, data tar
  18,380 B, OBB noted (3,488 B, not copied). Save-restore `--dry-run` OK.
- Device backup: settings 118 global / 101 secure / 38 system keys,
  getprop 126,240 B, Guardian tar 87,405,211 B, app inventory 235 apps,
  total ~87.57 MB in 6.2 s. Wi-Fi configs backed up as files (3 found);
  a tar of `/data/misc/wifi` fails on socket files and is not used.
  Restore `--dry-run` verified.
- Wireless: `devices setup-wifi` worked live. Headset IP
  192.168.1.50, `adb tcpip 5555`, `adb connect 192.168.1.50:5555`,
  wireless serial appeared in `adb devices`, shell over Wi-Fi returned
  "Quest 2". Saved to `~/.config/quest-companion/known-wireless.json`.
  Unplug persistence was NOT physically tested (cannot unplug remotely).
- Root: rooted=true, method "Magisk (su works)", su + Magisk +
  Singularity all detected. `su -c "magisk -v"` prints
  `1db2ceaf:MAGISK:D` (plain `magisk --version` as shell user fails;
  must go through su).
- Controllers: count 0 live. `dumpsys input` lists no Touch
  controllers (handled by the VR runtime, not the Android input
  stack); battery/firmware are NOT readable offline.
- Update block: `com.oculus.updater` was ALREADY disabled (likely by
  Singularity's update disabler), `com.oculus.nux.ota` enabled, so
  `blocked=false`. Telemetry: no standalone telemetry package found;
  not implemented, documented as such.
- Library: Moonlight base.apk imported live (label "Moonlight",
  version 12.1, SHA matches the backup manifest), stored in
  `~/.local/share/quest-companion/backups/imported/`.
- Debug info: adb 1.0.41, scrcpy available=true.

## What still needs the owner's real Quest test (NOT tested live)

- A real `apps restore` / `apps save-restore` / `device restore`
  onto the headset (dry-run only so far; needs his OK first, and a
  confirm in the UI).
- `apps install` of a real APK and a real `.apks` bundle.
- `device screenshot` / `record` / `mirror` live on hardware
  (scrcpy is present on the PC per debug-info; mirror not yet run).
- Wi-Fi: unplug persistence after `setup-wifi` (does the wireless
  connection survive unplugging the USB cable?), and modern TLS
  pairing (`connect-wifi --code`) against the headset's Wireless
  debugging screen.
- `settings set debug.oculus.refreshRate 90` + `profile apply balanced`
  — verify the keys exist on his firmware (Quest 2, Horizon OS build
  [redacted firmware]).
- `devices pair-wifi` (legacy tcpip) — IP detection via `ip route`.

## Quest 2 direction (2026-11-12)

This app is tailored to keeping **Quest 2** support alive on Linux and
Android after Meta ends Quest 2 updates (feature updates end March
2027 with Horizon OS v2.13, security patches December 2027). Quest 2
is first-class, not Quest 3; no Quest 3-only features as if general;
no assumption of Horizon OS v2.13+ / post-March-2027 Meta updates.
Offline, no Meta account, no Meta server, no new Meta app. Linux
first, Android second (same Flutter codebase; see
`../flutter_app/README.md` for the Android path).

**Beat Saber mods / song downloads: PARKED, do not build** (separate
parallel research; MBF current, BMBF dead). **Preservation research
(separate, parallel, do NOT start until it reports back):** copying
Meta Quest Link / Horizon Windows app management, installing
Singularity from the app, and eventually our OWN PC VR streaming
implementation for Linux (WiVRn-like / OpenXR / SteamVR runtime,
Linux only, Quest 2 client only, in our own code where possible,
learning from WiVRn / Monado / OpenXR, not launching the WiVRn
Flatpak and not copying WiVRn code wholesale). No runtime code in
this turn; a separate research agent maps what it takes first.

## Known limitations / deviations from the contract draft

- `device logcat --follow` streams raw lines with no JSON envelope.
  Documented in CONTRACT.md as the single exception (a stream cannot
  be one JSON object).
- `apps list` label is the last package segment (best effort); real
  display names need the APK's manifest. `apk_path` is included so the
  UI can pull the APK and read the label later.
- Direct transport: shell, exec-out (screenshot), logcat-dump and TLS
  pairing work; push/pull/install and device discovery do not yet and
  return a clear error. USB-direct is not implemented.
- `uninstall` uses `pm uninstall` (not `adb uninstall`); behaviour is
  equivalent for user apps. System-app removal is `apps
  uninstall-system` (rooted only, full removal, not just disable).
- `record` uses a fixed 1280x720 / 6 Mbps profile; presets are a v1 item.
- **Update check for sideloaded apps is deferred** (needs a proper
  database/index first); do not build a half version.
- **Beat Saber mods / song downloads are parked** (separate research).

**Preservation research reported 2026-11-12** (see CONTRACT.md):
own PC VR streaming is a thin layer on Monado (BSL-1.0) + own wire
protocol + own Quest client (NDK/Vulkan, not Flutter), 9-18 months
part-time solo; do NOT write an OpenXR runtime from scratch, do NOT
fork WiVRn (GPLv3). Singularity is closed-source; its home/dock and
update/telemetry mechanisms need a live before/after diff before the
app reimplements them. Do NOT hide `com.oculus.updater` (breaks the
home menu on v42+); the update pause uses `disable-user`, not hide.
- Debug binary is ~75 MB (tokio/libadb debug bloat); the release
  binary is 6.0 MB (`target/release/questctl`, verified 2026-11-12).
  Invalid usage (unknown subcommand) is clap's stderr + exit 2, not a
  JSON error — the UI should only ever call valid commands.
