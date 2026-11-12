# questctl JSON CLI contract

This is the exact interface between the Flutter UI and the Rust backend.
Both agents share it. **Do not change it unilaterally** — any change needs
both agents (backend + UI) to agree first.

## Envelope

Every command accepts `--json` and prints **one JSON object** to stdout:

- Success: `{"ok": true, ...data}` — exit code 0.
- Failure: `{"ok": false, "error": "human readable message"}` — exit code non-zero.

Without `--json` the same object is printed pretty-printed (for humans in a
terminal); errors go to stderr with exit code 1.

**One documented exception:** `device logcat --follow` streams raw logcat
lines to stdout until killed, with no JSON envelope (a follow stream cannot
be one JSON object). Without `--follow`, logcat returns
`{"ok": true, "lines": [...]}` like everything else.

## Global flags

- `--json` — JSON envelope (above).
- `--transport binary|direct` — default `binary`. `direct` is the libadb
  transport (no adb binary; Wi-Fi only, needs `--addr`). Also selectable
  via env `QUEST_TRANSPORT=direct`.
- `--addr <ip>:<port>` — address for the direct transport, e.g. `192.168.1.5:37281`.

The adb binary is resolved as: `QUEST_COMPANION_ADB` env, then `QUEST_ADB`
env, then `~/workspace/android-sdk/platform-tools/adb`, then `~/Android/Sdk/...`,
then `adb` on PATH.

## Commands

Serial is always `--serial <serial>` where relevant. Wi-Fi devices show
in `devices list` with serials like `192.168.1.42:5555`.

### Devices

| Command | Success payload |
|---|---|
| `questctl --json devices list` | `{"devices": [{"serial": "...", "state": "device\|unauthorized\|offline\|no permissions", "model": "Quest 2", "transport": "usb\|wifi"}]}` — empty list when nothing is attached, never a crash |
| `questctl --json devices info --serial X` | `{"serial", "model", "android_version", "firmware", "cpu_abi", "battery": {"level", "health", "temperature_c", "voltage_mv", "status", "plugged"}, "storage": {"total_kb", "used_kb", "free_kb", "mount"}, "resolution", "density"}`. Note: `battery` is an object, not a number, and `storage` is in KiB, not GB. The UI derives `charging` as: `battery.status` is `charging` or `full`, or `battery.plugged` is set (not null/empty) — i.e. the headset is on mains/USB power. `temperature_c` is already in °C (dumpsys reports tenths of a degree; the backend divides by 10). |
| `questctl --json devices pair-wifi --serial X` | Legacy `adb tcpip 5555` over USB. `{"serial", "ip", "port": 5555, "warning": "...", "next": "questctl --json devices connect-wifi --ip <ip> --port 5555"}` — the warning says this mode is unauthenticated beyond the RSA key and turns off on reboot |
| `questctl --json devices connect-wifi --ip <ip> --port <port> [--code <6-digit>]` | With `--code`: pairs (TLS/SPAKE2) → `{"paired": true, "message": "...", "note": "pairing port is not the connect port..."}`. Without `--code`: connects → `{"connected": true, "message": "..."}` |
| `questctl --json devices disconnect-wifi --serial X` | Added 2026-11-12 (integration fix). `adb disconnect <serial>` (no `-s` form). `{"disconnected": true, "serial", "message"}`. Note: this drops the adb-server connection; wireless debugging on the headset stays on until turned off there. On the direct (libadb) transport there is no server connection, so it returns `disconnected: true` with a message saying so. |

### Apps

| Command | Notes |
|---|---|
| `apps list --serial X [--third-party] [--with-icons]` | `{"apps": [{"package", "label", "version", "system", "apk_path", "icon_path"?}]}`. `label` is best-effort (last package segment) unless a cached icon already has the real label (see App icons below). Without `--with-icons`, `icon_path` is never present and the list stays fast. With it, `icon_path` / the real label come from the **cache only** — the list never pulls APKs. |
| `apps icon --serial X --package <pkg> [--out <file.png>]` | `{"package", "label", "version", "icon_path", "icon_file"}`. Pulls base.apk once, reads the real label + launcher icon, caches it, and returns the local icon file. `--out` copies the icon there and `icon_path` is that path instead. Fails with `ok: false` when the app has no launcher icon (e.g. VrShell), when aapt cannot read the APK and no mipmap icon is found, or when the APK cannot be pulled. |
| `apps install --serial X --apk <path> [--reinstall]` | Single APK, or a `.apks`/`.xapk` bundle (unzipped, base first, `install-multiple`). `{"installed": true, "message": "Success..."}`. Install failures name the code, e.g. `INSTALL_FAILED_VERSION_DOWNGRADE (the installed version is newer)` |
| `apps install-multiple --serial X --apks base.apk,split.apk,...` | Atomic split install. `--apks` is comma-separated |
| `apps uninstall --serial X --package <pkg> [-k]` | `-k` keeps data. `{"uninstalled": true, ...}` |
| `apps launch --serial X --package <pkg>` | Resolves the launcher activity first, falls back to `monkey` |
| `apps force-stop --serial X --package <pkg>` | |
| `apps clear-data --serial X --package <pkg> --confirm` | **Requires `--confirm`**; without it the command fails with an error telling you so |

### Files

| Command | Notes |
|---|---|
| `files list --serial X --path /sdcard/` | `{"path", "entries": [{"name", "path", "is_dir", "size", "modified"}]}`. Directories sort first |
| `files push --serial X --local <path> --remote <path>` | `{"pushed": true, ...}` |
| `files pull --serial X --remote <path> --local <path>` | `{"pulled": true, ...}` |
| `files delete --serial X --remote <path>` | Added 2026-11-12 (integration fix). `rm -rf` of the path on the headset. **Only `/sdcard/` paths, never `/sdcard` itself, no `..`.** Anything else is refused before any adb call. `{"deleted": true, "remote"}` |

Honest scope: `/sdcard/Android/data/<pkg>/` is not readable for other
apps' data on Android 11+ without root. The UI must not promise it.

### App icons (added 2026-11-12)

- **Cache:** `~/.cache/quest-companion/icons/<package>/<version>/icon.png`
  (or `icon.webp` / `icon.jpg` when that is what the APK stores) plus
  `label.txt` with the real label. Cache key is package + version, so
  an app update re-fetches its icon. A second `apps icon` call for the
  same app is a cache hit: no APK pull, no aapt.
- **How the icon is found:** `pm path <pkg>` gives base.apk (split
  APKs: icon lives in base.apk), the APK is pulled to a temp file,
  then `aapt2` / `aapt` `dump badging` is run for the real label and
  the `application-icon-<density>` file (highest density wins, e.g.
  xxxhdpi 640). aapt candidates are tried in order: `aapt2`/`aapt` on
  PATH, then the Android SDK build-tools dirs newest first.
- **Fallbacks, verified live:** Beat Saber's APK makes every aapt
  (Debian 2.19 and SDK 34/36) fail with "Bad string block", exit 1,
  no badging at all — the backend then scans the APK zip for a
  `res/mipmap-<density>/app_icon.png` (xxxhdpi wins) and uses that.
  OpenBrush's icon is not under mipmap/ at all
  (`application-icon-640:'res/oj.png'`), so the badging path is
  authoritative and the zip scan is only a fallback. Adaptive icons
  (XML) are skipped, not returned. Apps with no launcher icon at all
  (VrShell, `icon=''`) return `ok: false` and the UI falls back to
  initials — that is expected, not a bug.
- **Formats:** icons are stored as extracted (usually PNG, sometimes
  WebP). WebP is returned as-is with its real extension; the UI
  renders it directly, nothing is converted.
- **Performance:** `apps list` without `--with-icons` does no icon
  work at all. With it, only cached icons are attached. Pulling all
  235 APKs on every list would take minutes and fill storage, so it
  is deliberately not done. First display of an app's icon pulls its
  base.apk once (a few seconds for a large game); after that it is
  cached.

### Device (media)

| Command | Notes |
|---|---|
| `device screenshot --serial X --out <file.png>` | `exec-out screencap -p`, binary-safe, PNG magic verified. `{"path": ...}` |
| `device record --serial X --out <file.mp4> [--seconds 60]` | `screenrecord`, video-only, max 180 s per invocation (clamped, with a `note` in the payload). `{"path", "seconds", "note"?}` |
| `device logcat --serial X [--follow]` | Dump: `{"lines": [...]}`. `--follow`: raw stream, no JSON (see above) |
| `device mirror-stop --serial X` | Stops a running scrcpy mirror for this serial (finds it in /proc by command line). `{"stopped": n}`. |
| `device mirror --serial X [--preset performance|balanced|quality]` | Launches scrcpy in its own window. `{"launched": true, "command", "note"}`. Preset sets real scrcpy limits (2026-11-12): Performance 1280/4M/30fps, Balanced 1920/8M/60fps, Quality 2560/12M/90fps, all h264, no audio. Default balanced. |
| `device reboot --serial X` | Added 2026-11-12 (integration fix). `adb -s <serial> reboot`. `{"rebooted": true, "serial"}` |

### Settings

| Command | Notes |
|---|---|
| `settings get --serial X --key <key>` | `{"key", "value"}`. `debug.oculus.*` → `getprop`; other keys → `settings get system <key>` (prefix `global:` / `secure:` / `system:` selects the table) |
| `settings set --serial X --key <key> --value <v>` | `{"key", "value", "model", "warning"?}`. Unknown `debug.oculus.*` keys are **refused** with the allowlist in the error. Refresh rate is capped per model (Quest 2: 120, Quest 3: 207). Quest settings carry a `warning` that they are volatile and clear on reboot |
| `settings profile list` | `{"profiles": ["balanced", "performance", "battery-saver", "high-refresh", ...]}` (built-ins + saved in `~/.config/quest-companion/profiles.json`) |
| `settings profile apply --serial X --profile <name>` | `{"profile", "model", "applied": [{"key", "value"}], "warnings": [...]}`. Applies refresh rate, cpu/gpu level, texture size, guardian pause, full-rate capture |
| `devices shell --serial X --command <cmd>` | Shell passthrough, 120 s timeout. `{"stdout", "stderr", "code"}`. The command is logged to stderr before it runs. No blocklist: the owner owns the headset. The UI shows the command before running it |
| `devices debug-info --serial X` | `{"questctl_version", "adb_version", "scrcpy_available", "backend_path", "device": <devices info object>, "wifi_ip", "root": <root-status object>}`. All read-only |
| `devices root-status --serial X` | `{"rooted", "method", "su_present", "magisk_present", "singularity_present"}`. `method` is plain text, e.g. "Magisk (su works)". Detection is read-only: `su -c id` uid=0 (real test), `su -c "magisk -v"`, Singularity/Magisk packages installed |
| `devices wifi-ip --serial X` | `{"serial", "ip"}`. IP from `ip addr show wlan0` / `ip route get` / `getprop dhcp.wlan0.ipaddress` |
| `devices setup-wifi --serial X` | Automatic wireless: finds the Wi-Fi IP, `adb tcpip 5555`, `adb connect <ip>:5555`, verifies the wireless serial appears. `{"ip", "wireless_serial", "connected", "steps", "note?"}`. Saves the IP to `~/.config/quest-companion/known-wireless.json` on success. On failure `connected: false` with a quiet `note` — USB still works, the UI must not show it as an error |
| `devices wifi-reconnect` | Tries every saved IP: `adb connect <ip>:5555`. `{"connected": ["192.168.1.42:5555", ...]}` |
| `devices controllers --serial X` | `{"controllers": [{"name"}], "count", "note"}`. **Battery level and firmware are NOT readable offline via adb on Quest 2** (Touch controllers are not in the Android input stack; `dumpsys input` shows no controller batteries). The `note` says so in plain language; the UI must show it, never invent battery numbers. Pairing help: hold Menu + Y (left) or Menu + B (right) until the LED blinks, pair in headset Settings > Devices |
| `devices update-block-status --serial X` | `{"blocked", "rooted", "packages": [{"package", "disabled"}]}`. Packages: `com.oculus.updater`, `com.oculus.nux.ota`. `blocked` is true only when both are disabled |
| `devices update-block --serial X --block \| --unblock` | Rooted only, **off by default, never auto-enabled**. `pm disable-user --user 0 <pkg>` / `pm enable`. Reversible, nothing deleted or flashed. **Disable, never hide:** `pm hide com.oculus.updater` breaks the home menu on v42+ (research 2026-11-12); `disable-user` is what Singularity's own update disabler does, and the owner's headset already has the updater disabled with a working home menu. Telemetry is NOT blocked by this command: no standalone telemetry package was found on the Quest 2 (Singularity ships its own in-headset telemetry disabler) |

### Apps: sizes and details (added 2026-11-12)

| Command | Notes |
|---|---|
| `apps list --serial X [--with-sizes]` | Adds optional fields to each app: `apk_size_bytes`, `data_size_bytes`, `obb_size_bytes`, `total_size_bytes`, `version_code`, `min_sdk`, `target_sdk`, `first_install_time`, `last_update_time`, `installer`, `permissions`. Sizes come from 3 batched shell calls (one `ls -l` loop over APK paths, one root `du -sb /data/data/*`, one `du -sb /sdcard/Android/obb/*`), never one dumpsys per app: 70 third-party apps in 2.77 s live. Data size needs root (shell user gets "Permission denied"); without root the field is null and the list still works |
| `apps details --serial X --package <pkg>` | One app, lazily: `{"package", "label", "version", "system", "version_code", "min_sdk", "target_sdk", "first_install_time", "last_update_time", "installer", "apk_paths", "obb_files", "permissions", "apk_size_bytes", "data_size_bytes", "obb_size_bytes", "total_size_bytes", "data_size_note"}`. `apk_paths` is all splits from `pm path`. `obb_files` is the OBB-dir contents (Beat Saber has ~280 entries; the UI shows the count + `.obb` names only). **Maker/developer is deliberately absent: an APK stores no maker name** (aapt badging gives label, version, icon only) and this app never calls Meta/Play APIs. The UI shows "Maker: not stored in the APK" as plain text, never a guessed name |
| `apps uninstall-system --serial X --package <pkg>` | Rooted only. Fully removes a system app (`pm uninstall`). The UI gates it behind root detection + a confirm dialog |

### App backup and restore (added 2026-11-12)

Default backup root (one folder, also the library folder, also the
device-backup folder): `~/.local/share/quest-companion/backups/` (or
`$XDG_DATA_HOME/quest-companion/backups`).

| Command | Notes |
|---|---|
| `apps backup --serial X --package <pkg> [--out <dir>] [--skip-data]` | Folder `<package>-<version>-<YYYYMMDD-HHMMSS>/` with base.apk + split APKs (via `pm path`, pulled with the existing transport), OBB files from `/sdcard/Android/obb/<pkg>/`, `data.tar.gz` (root `tar -czf` of `/data/data/<pkg>`, needs root), `manifest.json`. Never fails the whole backup because one piece failed; fails only if zero APKs were pulled. `adb backup` is deliberately NOT used (deprecated, in-headset tap, most Quest apps opt out). Optional `--include-adb-backup` was NOT added: it needs an in-headset confirmation tap and most apps opt out, so it is not a reliable path |
| `apps restore --serial X --backup <dir> [--include-data] [--dry-run] [--confirm]` | Verifies manifest hashes first (refuses a damaged backup), installs APKs via install-multiple with `--reinstall`, pushes OBB back, restores data only with `--include-data` (requires root, overwrites data, fixes ownership to the app uid from dumpsys `appId`, `restorecon -R`). Real restore requires `--confirm`; `--dry-run` lists steps without touching the headset. Returns `{"package", "backup_path", "dry_run", "ok", "steps": [{"item", "ok", "message"}]}` |
| `apps backup-list [--out <dir>]` | `{"backups": [{"package", "label", "version", "backup_date", "path", "total_size_bytes", "apk_count", "obb_count", "has_data"}]}` |
| `apps backup-delete --backup <dir>` | Local files only. Refuses paths outside the backup root. `{"deleted": true, "backup"}` |

Manifest (`manifest.json`, kind `"app"`): package, label, version,
versionCode, backup date (UTC), APK list with SHA-256 hashes, OBB
list, data entry, per-item `steps` with success/failure. Live test
2026-11-12: Moonlight `com.limelight` v12.1, base.apk 3,852,725 B +
`split_config.arm64_v8a.apk` 2,421,165 B + data.tar.gz 513 B,
manifest hashes good, total 6,275,494 B. Restore `--dry-run` OK.

### Save backup (added 2026-11-12)

| Command | Notes |
|---|---|
| `apps save-backup --serial X --package <pkg> [--out <dir>] [--include-obb]` | Folder `<package>-save-<version>-<date>/`, manifest kind `"save"`. Backs up ONLY saves: `/sdcard/Android/data/<pkg>/` file tree (pulled, hashed per file), root tarball of `/data/data/<pkg>`, OBB **not** copied by default (noted with its on-device size; `--include-obb` copies only real `.obb` files). Fails only if no save data at all was found |
| `apps save-restore --serial X --backup <dir> [--dry-run] [--confirm]` | Hash-verify, push the sdcard tree back, restore the data tar (root). The app is NOT reinstalled. Real restore requires `--confirm`. Returns a `RestoreReport` like app restore |

Honest limit: some games keep saves server-side or refuse access;
recorded per-item in the manifest, and the UI says so. Live test
2026-11-12: OpenBrush save backup, 223 files, 75,565,625 B total,
data tar 18,380 B, OBB noted (3,488 B on device, not copied).

### Library (added 2026-11-12)

| Command | Notes |
|---|---|
| `library list` | `{"entries": [{"kind", "source", "package", "label", "version", "version_code?", "size_bytes", "sha256?", "date_added", "path", "apk_count", "obb_count", "has_data"}]}`. `kind` is `app` (app backup) \| `save` (save backup) \| `apk` (imported file); `source` is `backup` \| `imported` |
| `library import --file <apk/apks/xapk>` | Copies the file into `backups/imported/<package>-<version>/` (never moves the original), reads package/version/label from aapt badging, records SHA-256 in `library-index.json` (plain JSON in the library folder, no database). Returns the entry |
| `library delete --path <path>` | Local files only (backup folder via `delete_backup` with a manifest check, imported files removed + index pruned) |

**DEFERRED, do not build:** update check for sideloaded apps
(compare installed version to the library version). Needs a proper
database/index first; a half version now would mislead. Recorded as
planned, not implemented.

### Gallery (added 2026-11-12)

Root: `~/quest-recordings/` (screenshots and recordings together).

| Command | Notes |
|---|---|
| `device gallery-list` | `{"entries": [{"name", "path", "kind", "size_bytes", "modified"}]}`, newest first. `kind` is `screenshot` (`.png/.jpg/.webp`) or `recording` (`.mp4/.mkv/.webm`) |
| `device gallery-delete --file <path>` | Local file only; refuses files outside the gallery folder or non-media files |

### Full device backup (added 2026-11-12)

| Command | Notes |
|---|---|
| `device backup --serial X [--out <dir>]` | Folder `<serial>-device-<date>/` in the library root. Contents: `settings-global.txt`, `settings-secure.txt`, `settings-system.txt` (`settings list`), `getprop.txt`, `device-info.json`, `guardian.tar.gz` (root tar of `/data/data/com.oculus.guardian`), `wifi/` config files, `manifest.json` (kind `"device"`, serial, model, Android/firmware, backup date, `apps` inventory with `library_path` refs, file list with SHA-256, per-item steps). **APKs are NOT re-copied** (apps/saves come from library backups; the manifest and UI must say so). Wi-Fi configs are copied as files (`/data/vendor/wifi/wpa/wpa_supplicant.conf`, `p2p_supplicant.conf`, `/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml`); a tar of `/data/misc/wifi` fails on socket files and is not used. Returns `{"serial", "path", "backup_date", "total_size_bytes", "ok", "steps"}` |
| `device restore --serial X --backup <dir> [--dry-run] [--confirm] [--skip-apps] [--include-data]` | Dry-run first: lists the settings keys, Guardian tar, Wi-Fi files and apps it would put back. Real restore requires `--confirm`; settings applied per-key (failures recorded); Guardian/Wi-Fi need root; apps reinstall from the library (APKs only unless `--include-data`). Returns `{"serial", "dry_run", "backup_path", "ok", "steps"}` |
| `device backup-list` | `{"backups": [{"serial", "backup_date", "path", "total_size_bytes", "app_count"}]}`, newest first |

Live test 2026-11-12: settings 118 global / 101 secure / 38 system
keys, getprop 126,240 B, Guardian tar 87,405,211 B, app inventory 235
apps, total ~87.57 MB in 6.2 s. Restore `--dry-run` verified.

## Quest 2 framing (direction, 2026-11-12)

This app is tailored to keeping **Quest 2** support alive on Linux and
Android after Meta ends Quest 2 updates (feature updates end March
2027 with Horizon OS v2.13, security patches December 2027). Quest 2
is first-class, not Quest 3. No Quest 3-only feature (240 Hz, Quest
3-only settings) as if general; no assumption of Horizon OS v2.13+ /
post-March-2027 Meta updates. The app must keep working offline with
no Meta account, no Meta server, no new Meta app. Linux first,
Android second: same Flutter single codebase on Android as a
phone-as-host companion (Wi-Fi first on Android, USB OTG where
possible); no desktop-only dependency that breaks the Android build.
No ads, no account, no telemetry, no Meta/Play API, ever.

**Beat Saber mods / song downloads: PARKED, do not build.**
Separate parallel research (MBF is current, BMBF dead, BeatSaver API
verified); do not start mod code until that research reports back.

**Preservation research (separate, parallel; research REPORTED
2026-11-12, report in `research_notes/own-vr-runtime-20261112/report.md`):
do NOT write an OpenXR runtime from scratch and do NOT fork WiVRn
(GPLv3).** The path the research found is a thin streaming layer on
Monado (BSL-1.0) + our own wire protocol + our own Quest client
(NDK/Vulkan, not Flutter), 9-18 months part-time solo to usable.
That work is a later phase (P3), not this turn: copying Meta Quest
Link / Horizon Windows app management (homes, old vs new home, old
vs new taskbar), installing Singularity from the app to start root,
and the own-PC-VR-streamer above. Singularity customization research
also reported 2026-11-12
(`research_notes/singularity-customization-20261112/report.md`):
Singularity is CLOSED-source (README + proprietary licence + hosts
file only, no app source); DockUI/NavUI, Loft install, and the
update/telemetry disabler mechanisms are NOT publicly documented and
must be found by a live before/after diff on the owner's Quest before
the app reimplements them. Do NOT start any of those three until the
live-diff work is done. No Windows, no Link.

## Versioning

`questctl --version` prints the backend version. Contract changes are
recorded here with a date and a note in both agents' READMEs.

### Changelog

- **2026-11-12 — sizes, backup, wireless, library, gallery, terminal, rooted mode, device backup, controllers, update block.** Added `apps list --with-sizes` and `apps details` (sizes, SDK levels, dates, installer, permissions; maker deliberately absent), `apps backup/restore/backup-list/backup-delete`, `apps save-backup/save-restore`, `apps uninstall-system` (rooted only), `devices shell` (120 s timeout), `devices debug-info`, `devices root-status`, `devices wifi-ip/setup-wifi/wifi-reconnect`, `devices controllers`, `devices update-block-status/update-block`, `library list/import/delete`, `device gallery-list/gallery-delete`, `device backup/restore/backup-list`. Default backup/library/device-backup root `~/.local/share/quest-companion/backups/`; gallery `~/quest-recordings/`. Honest limits documented in place: maker not available offline, data size needs root, controller battery/firmware not readable, telemetry not blocked by this app (no telemetry package found; Singularity has its own disabler), `adb backup` not used (deprecated, per-app opt-in). Update check for sideloaded apps deferred (needs a proper database first). Quest 2 framing and the parked Beat Saber / own-PC-VR-runtime direction recorded in the "Quest 2 framing" section.
- **2026-11-12 — app icons.** Added `apps icon --serial X --package <pkg> [--out <file>]`
  (`{"package", "label", "version", "icon_path", "icon_file"}`) and
  `apps list --with-icons` (cache-only `icon_path` + real label).
  Icon cache is `~/.cache/quest-companion/icons/<package>/<version>/`.
  Badging first (aapt2/aapt), mipmap zip-scan fallback (Beat Saber),
  no-icon apps return `ok: false` (VrShell). See "App icons" above.
- **2026-11-12 — integration fix.** Added `devices disconnect-wifi --serial X`
  (`{"disconnected": true}`), `device reboot --serial X`
  (`{"rebooted": true}`), and `files delete --serial X --remote <path>`
  (`{"deleted": true}`, /sdcard/ only). Documented that `device mirror`
  takes no `--preset` (presets are UI-only for now), that `devices info`
  returns `battery` as an object and `storage` in KiB with the UI's
  charging rule, and that `files list` returns `entries` (not `files`).
  UI fixes in the same change: `deviceInfo` parsing, `files list`
  `entries`, `clear-data --confirm`, `record --out/--seconds`,
  `settings profile apply --profile <name>` (UI profile names mapped to
  the backend built-ins), `devices connect-wifi` for pairing, and file
  delete wired with a confirm dialog.
- **2026-11-12 — homes, snapshots, health, Singularity wizard, APK analyzer, multi-headset (0.2.17).**
  Added `homes list/current/set/open-settings --serial X` (home apps from
  `pm query-activities`, the active one from `pm resolve-activity`;
  switching uses `cmd package set-home-activity` and verifies the
  switch landed, otherwise the UI opens the headset's Home settings);
  `snapshot create/list/restore/delete` (a device backup plus a
  `snapshot.json` with the name and the active settings profile, which
  the restore re-applies); `devices health --serial X` (battery,
  storage, uptime, last backup); `singularity preflight/download/
  install/verify --serial X` (preflight checks, download of the
  author's latest release from GitHub with aapt + checksum
  verification when the release publishes one, install, root
  verification; Singularity itself is never bundled and the rooting
  happens in the headset); `apps analyze --apk <path>` (badging +
  native libs + size breakdown + file SHA-256 + signer SHA-256 via
  apksigner, when Java is available); and per-headset WiVRn declines
  (`wivrn decline/undecline --serial X`; the old shared file is still
  honored as a legacy fallback). The UI saves settings profiles per
  headset (`~/.config/quest-companion/device-profiles.json`) and
  applies the saved profile when switching headsets.

### Homes (added 2026-11-12)

| Command | Notes |
|---|---|
| `homes list --serial X` | `{"homes": [{"component": "pkg/Activity", "package", "label", "is_current"}]}` (current first). Labels come from the installed-app list. |
| `homes current --serial X` | `{"current": "pkg/Activity"}` or `{"current": null}` when the headset has no home picked yet. |
| `homes set --serial X --component <pkg/Activity>` | `cmd package set-home-activity`, then verifies with `resolve-activity`. Fails with a clear error when the build refuses it (the UI then offers the Home settings screen). |
| `homes open-settings --serial X` | Opens `android.settings.HOME_SETTINGS` on the headset (the system home picker). |

### Snapshots (added 2026-11-12)

| Command | Notes |
|---|---|
| `snapshot create --serial X --name <name> [--profile <name>]` | A device backup plus `snapshot.json` (name, serial, model, firmware, profile). Same honest limit as a device backup: APKs are not copied, apps reinstall from their library backups. |
| `snapshot list` | `{"snapshots": [{"serial", "name", "created_date", "path", "total_size_bytes", "app_count"}]}`, newest first. |
| `snapshot restore --serial X --snapshot <path> [--dry-run] [--confirm]` | The device restore, then the recorded settings profile is re-applied. A real restore needs `--confirm`. |
| `snapshot delete --snapshot <path>` | Local files only, and only inside the backup root. |

### Singularity wizard (added 2026-11-12)

| Command | Notes |
|---|---|
| `singularity preflight --serial X` | `{"checks": [{"name", "ok", "detail"}], "ok", "summary"}`. Checks: Quest 2, battery 50%+, not already rooted, Singularity not installed, 500 MB free, firmware (the known-good build is named in the detail). |
| `singularity download` | Fetches `api.github.com/repos/Lumince/singularity/releases/latest`, downloads the .apk asset to `~/.cache/quest-companion/singularity/`, verifies it is a real APK (aapt badging) and, when the release publishes a checksum file, verifies the SHA-256 against it. Returns `{"version", "file", "size_bytes", "sha256", "package", "label", "verification"}`. |
| `singularity install --serial X` | Installs the newest downloaded APK over ADB. |
| `singularity verify --serial X` | Root status after the user pressed Root Now in Singularity; fails with a plain message when root is not on yet. |

### APK analyzer (added 2026-11-12)

| Command | Notes |
|---|---|
| `apps analyze --apk <path>` | `{"path", "file", "file_size_bytes", "sha256", "package", "label", "version_name", "version_code", "min_sdk", "target_sdk", "permissions", "features", "abis", "is_64_bit", "native_lib_bytes", "native_lib_count", "dex_bytes", "assets_bytes", "res_bytes", "signature_sha256", "signature_checked", "notes"}`. A `.apks` / `.xapk` bundle is analyzed through its largest inner APK (noted). The signer check needs apksigner + Java; when Java is missing the note says so instead of claiming the signature is bad. |
