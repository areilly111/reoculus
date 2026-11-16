# Building ReOculus and applying fixes

How to build this app properly, and how to make and land a fix. Read this
before you change code. The short version: edit in the VM repo, verify with
the tests, commit, sync lean to the PC, build the AppImage on the PC,
build the APK in the VM, install both on hardware, and only then push.

For Android-only work, read `docs/BUILDING-ANDROID.md` instead: it is
the standalone Android build and fix guide (questctl cross-compile, APK
build, signing, installing, the mirror pipeline, and the tablet
diagnostics). This file covers the whole project and the Linux side.

## The two machines and the two repos

- **This VM** holds the working repo at `~/workspace/quest-companion/`.
  Rust and Flutter builds run here. The Android APK is built here.
- **The main PC** (Ubuntu 26.04.1 KDE, GTX 1050 Ti) holds the canonical
  repo at `/mnt/64D649ADD6498072/Programming/quest/` and the run copy at
  `/home/anthony/quest-app/`. The Linux AppImage is built here, because
  the Flutter Linux build and appimagetool live there.
- The PC's Projects drive is NTFS via FUSE. That matters (see Gotchas).

## Syncing VM to PC (lean rsync)

Never copy the whole tree. Use the lean rsync, or it copies 14+ GB and
takes forever. The relay dies often; check it first.

```bash
# Restart the relay if ssh fails with Connection refused.
nohup python3 ~/workspace/relay-desktop.py > /tmp/relay-22224.log 2>&1 &
ss -tlnp | grep 22224

# Lean sync VM -> PC canonical. Run from the VM.
rsync -av --delete \
  -e "ssh -i /home/hatch/.ssh/id_ed25519_mainpc -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o BatchMode=yes -p 22224" \
  --exclude 'releases/' \
  --exclude '/backend/target/' \
  --exclude '/flutter_app/build/' \
  --exclude '/flutter_app/.dart_tool/' \
  ~/workspace/quest-companion/ anthony@127.0.0.1:/mnt/64D649ADD6498072/Programming/quest/
```

The rsync excludes are load-bearing: `releases/` is PC-local artifacts,
`backend/target/` and `flutter_app/build/` are build outputs, and
`.dart_tool/` is generated. Without them the sync copies 14+ GB.

There is a per-version PC build script at `~/workspace/build-<ver>-pc.sh`
(e.g. `build-0.2.36-pc.sh`). Copy it to the PC as `/tmp/build-<ver>.sh`
and run it there. Make a new one per version; do not reuse an old one
blindly, the steps change. The script syncs canonical -> run copy
(no --delete, so caches survive), runs the tests and the build, packs
the AppDir, runs appimagetool, does an xvfb smoke test, and copies the
AppImage to the canonical `releases/` dir.

## Version bump (do this first, for every release)

A version lives in four places. Bump all four together, or the app
reports the wrong version somewhere.

1. `backend/quest-core/Cargo.toml` — `version = "0.2.x"`.
2. `backend/questctl/Cargo.toml` — same version.
3. `flutter_app/pubspec.yaml` — `version: 0.2.x+N` (N is the Android
   versionCode, bump it by 1 every APK build or Android refuses the
   update as a downgrade).
4. The About text in `flutter_app/lib/screens/device_mirror_logs_setup.dart`
   — the string `ReOculus 0.2.x. A Quest 2 and Quest 1 companion...`.

Then update the changelog: the `## 0.2.x` entry in `README.md` and the
matching entry in `backend/CONTRACT.md`. Keep both in sync; the README
is the human changelog, the CONTRACT is the backend contract plus
changelog.

## Making a fix (the workflow)

1. **Understand before you touch.** Read the relevant code and the
   contract (`backend/CONTRACT.md`). If the fix touches the mirror,
   read `docs/session-notes-0.2.36.md` first: it records what was
   already tried for the tablet blockiness and what is still open.
2. **Edit in the VM repo.** Small, focused changes. One concern per
   commit. Do not edit files in `flutter_app/` while an APK build is
   running.
3. **Verify before you commit.** Run the checks in "Testing" below.
   They must pass (except the one pre-existing failure). Never commit
   with known blockers, dead endpoints, or unverified claims. Never
   push with known-broken code.
4. **Commit.** Message format: `ReOculus 0.2.x: <what> (<why>)` with a
   body explaining the reasoning, not just the diff. Author the commit
   as Muse (`-c user.name="Muse" -c user.email="muse@local"`); the
   older history is authored with Anthony's name, but new work goes in
   as Muse. Stage only the files the fix touches; do not commit
   `scripts/figcraft_export.py` (untracked by design) or anything in
   `test/widget/failures/` (delete that dir before staging).
5. **Build the artifacts.** AppImage on the PC, APK in the VM (below).
6. **Install on hardware and get Anthony's verdict.** He tests on his
   own devices and his verdict is the only thing that closes a fix.
   State work as built and awaiting his test, never fixed, until he
   confirms it.
7. **Push and release.** Only when Anthony asks for it, or when the
   fix is verified and he has approved the release. See "Pushing and
   releasing" below.

## Building the Rust backend

Run from `backend/` (the workspace root). Cargo is not on the default
PATH in this VM.

```bash
cd ~/workspace/quest-companion/backend
export PATH="$HOME/.cargo/bin:$PATH"

# Tests. Expect 114 pass (96 + 11 + 7). Any failure is a blocker.
cargo test --release

# Release questctl. The remap flag keeps the build machine's absolute
# paths out of the binary (panic locations, registry paths).
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$HOME=/build"
cargo build --release -p questctl

# Verify the remap worked (expect 0).
strings target/release/questctl | grep -c /home/hatch
./target/release/questctl --version
```

The backend contract: `questctl --json <cmd>` prints one JSON object.
Payloads must not use a top-level key `ok` (main() clobbers it; use
`ready`). Raw commands that write to stdout are `device logcat
--follow`, `device mirror-stream`, and `device record-loop`. The direct
transport (`--transport direct --addr`) is shell-only; push/pull/install
/list error clearly on it. `QUEST_COMPANION_ADB` points at a mock adb
for tests. Rust tests that call environment probes must be hermetic
(injectable probes), or they fail on a machine without the hardware.

## Building the Linux AppImage (on the PC)

Use the per-version PC build script (see "Syncing" above). It does, in
order: sync canonical -> run copy, version check, cargo test, cargo
build release questctl, remap check, `flutter build linux --release`,
pack the AppDir, appimagetool, xvfb smoke test, copy to `releases/`.

The AppDir must carry the licence files, or the AppImage ships without
them (MIT requires the notice in all copies):
`usr/share/doc/reoculus/{LICENSE,CREDITS.md,GPL-3.0.txt}`. The script
copies LICENSE + CREDITS.md from the repo root and GPL-3.0.txt from
`licenses/`. It also copies `vendor/wivrn-server.flatpak` into
`usr/share/quest-companion/`.

The xvfb smoke test: `timeout 20 xvfb-run -a <AppImage>`; exit 124
means the app stayed alive, which is good. Exit 0 once is a known
flake; the script retries. A real crash is any other exit code.

The PC build script does NOT stop on cargo test failure. Read the log
yourself and grep for failures before you trust the AppImage.

Verify the built AppImage:

```bash
sha256sum ~/quest-appimage/ReOculus-0.2.36-x86_64.AppImage
ls -la ~/quest-appimage/ReOculus-0.2.36-x86_64.AppImage
# Expect ~31 MB. The SHA is what you report to Anthony.
```

## Building the Android APK (in the VM)

Two parts: the Android questctl binary, then the Flutter APK.

### 1. Android questctl

```bash
cd ~/workspace/quest-companion
bash backend/scripts/build-android.sh
```

This cross-compiles questctl for aarch64 (NDK 27.0.12077973), strips
it, and writes `backend/target/aarch64-linux-android/release/questctl`.
It applies the same remap flag as the Linux build. **The script does
NOT copy the binary.** You must copy it by hand to BOTH places and
verify the SHAs match, or the APK ships a stale backend:

```bash
cp backend/target/aarch64-linux-android/release/questctl flutter_app/assets/questctl-android-arm64
cp backend/target/aarch64-linux-android/release/questctl flutter_app/android/app/src/main/jniLibs/arm64-v8a/libquestctl.so
sha256sum flutter_app/assets/questctl-android-arm64 flutter_app/android/app/src/main/jniLibs/arm64-v8a/libquestctl.so
```

The two SHAs must be identical. If they are not, the APK and the
asset disagree and the tablet will run the old backend.

### 2. Flutter APK

```bash
cd ~/workspace/quest-companion/flutter_app
export PATH="$HOME/workspace/flutter-sdk/bin:$PATH"
export ANDROID_HOME=$HOME/workspace/android-sdk
export JAVA_HOME=$HOME/workspace/android-toolchain/jdk-17
export GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"
export GRADLE_USER_HOME=$HOME/.gradle
flutter build apk --release
```

Rules that will bite you if you skip them:

- **Never `flutter clean` before a VM APK build.** It wipes the
  cargokit pre-seed, and the drag plugin's Rust build then runs `dart
  pub get` in a temp dir and 407s through the egress proxy, killing
  the whole build. Warm build is ~3.5 min, cold is ~16 min.
- **No proxy lines in gradle.properties.** The sandbox reaches Maven
  Central and Google Maven directly. Proxy lines break dependency
  downloads (the proxy password rotates, and a stale one surfaces as
  a connection reset). Keep `~/.gradle/gradle.properties` free of
  proxy lines.
- **Gradle daemon vs IPv6.** This sandbox blackholes AF_INET6 loopback
  TCP, which silently kills the Gradle client-daemon handshake.
  `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"` is what lands the
  flag on the client JVM; passing it as a gradle program arg does NOT
  work. If daemons wedge, kill with `pkill -f "[G]radleDaemon"` and
  `rm -rf /root/.gradle/daemon`.
- **Kotlin compile daemon.** `gradle.properties` must have
  `kotlin.compiler.execution.strategy=in-process`, or the Kotlin
  compile daemon dies on the same IPv6 loopback blackhole.
- **uid 0's Gradle home is /root/.gradle (ephemeral).** Pin
  `GRADLE_USER_HOME=$HOME/.gradle` so the dependency cache persists
  across VM replacements.

The APK lands at `flutter_app/build/app/outputs/flutter-apk/app-release.apk`
(~29.5 MB). Record its SHA-256; that is what you report.

### 3. Signing (do not break this)

The APK is signed with a persistent keystore at
`flutter_app/android/keystore/reoculus.keystore` (alias `reoculus`),
wired via `flutter_app/android/keystore.properties` (mode 600,
gitignored). **Never print the passwords, never lose the keystore.**
If the keystore is lost, sideloaded apps can never be updated in place
again. Never install the debug-signed 0.2.33 build again (SHA
`4cc402ed...`); the debug keystore lives in /root/.android and is
wiped on VM replacement, so updates signed with it fail.

## Installing on hardware

The APK is installed over adb from the PC. The tablet is on USB to the
PC (serial R52Y403392Y) and also on Wi-Fi adb (192.168.100.132:5555).
Anthony's phone (S23 Ultra, SM-S918W) is on Wi-Fi adb
(192.168.100.199:5555). The Quest is on USB to the PC (serial
1WMHHB630X1464) and Wi-Fi adb (192.168.100.112:5555).

```bash
# Copy the APK to the PC first (scp from the VM).
scp -i /home/hatch/.ssh/id_ed25519_mainpc -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o BatchMode=yes -P 22224 \
  ~/workspace/quest-companion/flutter_app/build/app/outputs/flutter-apk/app-release.apk \
  anthony@127.0.0.1:/tmp/ReOculus-Android-0.2.36.apk

# Install on the tablet (or the phone: use its serial/address).
ssh -i /home/hatch/.ssh/id_ed25519_mainpc -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o BatchMode=yes -p 22224 anthony@127.0.0.1 \
  "adb -s R52Y403392Y install -r /tmp/ReOculus-Android-0.2.36.apk"

# Verify. Expect versionName 0.2.36 and the versionCode from pubspec.
ssh -i /home/hatch/.ssh/id_ed25519_mainpc -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o BatchMode=yes -p 22224 anthony@127.0.0.1 \
  "adb -s R52Y403392Y shell dumpsys package com.questcompanion.quest_companion | grep -iE 'versionName|versionCode'"
```

Ship one newest build per artifact. When he asks for an APK, send only
the most recent build, never multiple versions or older builds. The
deliverables live in
`~/workspace/goals/quest-companion-app-for-quest-2-on-linux-and-android/files/`
with symlinks from `~/workspace/your_files/`.

## Testing

Run these before every commit. All of them, not just the one you think
the change touches.

```bash
# Rust (from backend/).
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --release
# Expect: 96 + 11 + 7 = 114 pass, 0 fail.

# Flutter (from flutter_app/).
export PATH="$HOME/workspace/flutter-sdk/bin:$PATH"
flutter analyze
# Expect: 0 errors, 0 warnings (info-level notes are fine).

flutter test
# Expect: only ONE failure, the pre-existing widget_test.dart
# "App builds and shows navigation" (expects text "Devices"; verified
# pre-existing via git stash). Any other failure is a blocker.
```

Golden tests: `flutter test` compares screen renders against
`test/widget/goldens/`. If a screen changes, regenerate with
`--update-goldens` before committing, and delete
`test/widget/failures/` before staging (it holds diff images from
failed runs). Two gotchas:

- `Platform.isAndroid` (dart:io) is false in tests, but
  `defaultTargetPlatform` lies (reports android). Always gate on
  `Platform`.
- `FakeBackend` (in `test/widget/apps_screenshots_test.dart`) uses
  noSuchMethod, so every new `BackendService` member needs a stub
  there, or the golden tests crash.
- The Logs golden embeds clock timestamps. `AppState.log` takes an
  optional fixed timestamp and the test pins it, so the golden is
  deterministic. Do not regenerate it to "fix" a time drift; pin the
  time instead.

### xvfb live test (PC AppImage)

The PC AppImage can be driven under Xvfb to check the real UI. Recipe:

```bash
# On the PC. Xvfb displays die between sessions; check and start fresh.
Xvfb :98 -screen 0 1280x720x24 > /tmp/xvfb98.log 2>&1 &
WAYLAND_DISPLAY= GDK_BACKEND=x11 DISPLAY=:98 nohup ~/quest-appimage/ReOculus-0.2.36-x86_64.AppImage > /tmp/reoculus-xvfb98.log 2>&1 &
# Click with /tmp/xclick (XTest helper on the PC), screenshot with:
DISPLAY=:98 import -window root /tmp/xvfb98-home.png
```

`GDK_BACKEND=x11` and an empty `WAYLAND_DISPLAY` are required, or no
window ever maps. Kill the AppImage and Xvfb by exact PID when done;
never `pkill -f` on the PC (it matches your own ssh command line and
kills your session).

The live mirror will NOT start in xvfb if a screenrecord is already
running on the headset (his tablet mirror session, for example). Only
one screenrecord can hold the display; a second one fails with
"screenrecord exited with code 218 (is the headset awake?)". That is
expected, not a bug. Do not report it as a regression.

## Pushing and releasing

Only when Anthony asks for it, or when the fix is verified and he has
approved the release. The AppImage and APK are gitignored by design;
they go on GitHub as release assets, NOT committed into the repo.

```bash
cd ~/workspace/quest-companion
git fetch origin --tags
git push origin master
git tag v0.2.x
git push origin v0.2.x
gh release create v0.2.x --title "ReOculus 0.2.x" --notes "<plain-language changelog>" \
  ~/workspace/goals/quest-companion-app-for-quest-2-on-linux-and-android/files/ReOculus-0.2.36-x86_64.AppImage
```

`gh` is authenticated in this VM (account areilly111). GitHub tokens
are never stored in chat or files; the device flow is how auth was
established. The release notes should be plain language, no em dashes,
matching the README changelog entry for that version.

The last pushed+released version before this session was v0.2.28
(2026-11-13). 0.2.36 was pushed and released 2026-11-15 (AppImage
only on the release page; the APK is delivered to Anthony directly).

## Gotchas (the accumulated lessons)

- **The relay dies often.** `~/workspace/relay-desktop.py`
  (127.0.0.1:22224 -> 100.90.30.39:22) needs restarts. Check with
  `ss -tlnp` before assuming it is up.
- **SSH from this VM runs as root.** Always pass
  `-i /home/hatch/.ssh/id_ed25519_mainpc` and
  `-o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop`, or ssh
  looks in /root/.ssh and finds nothing. Laptop and homelab keys live
  in their own known_hosts files; do not mix them up.
- **`pkill -f` on the PC matches your own ssh command line.** It has
  killed the agent's own session twice. Kill by exact PID, captured
  first, and verify with `ps`.
- **NTFS FUSE `.fuse_hidden` files.** A file deleted while open becomes
  `.fuse_hidden*` and cannot be removed until the holder exits. If the
  holder is a running binary, find it via ps / `/proc/<pid>/exe`, not
  `fd/`. Moving the parent dir aside works as a workaround.
- **The headset sleeps fast.** Once a stream stops, the Quest can fall
  asleep within seconds, and a new screenrecord then fails with exit
  218. Wake it first: `adb shell input keyevent KEYCODE_WAKEUP` (works
  over USB and over Wi-Fi; Wi-Fi stays alive while it sleeps).
- **The direct-TLS port varies.** The headset's adbd direct port
  (was 38933) changes when it reconnects. Always read the current port
  from the running questctl command line (`ps`) instead of assuming it.
- **Running questctl from the tablet shell needs a writable HOME.**
  Set `HOME=/data/local/tmp/qchome2` or keypair creation fails with
  "Read-only file system (os error 30)". The shell user cannot kill the
  app's processes or read /data/app; use `am force-stop` to stop the
  app, and push a questctl binary to /data/local/tmp/ to run captures
  from the shell.
- **The PC mirror is frozen.** 1280x720 at 8 Mbps, chunks fed straight
  through. Do not change it without Anthony's explicit say-so. His
  words: "on pc it works perfect to where i dont wana mess with it
  further".
- **Do not edit `flutter_app/` during an APK build.** The build reads
  the tree as it goes; an edit mid-build produces a mixed artifact.
- **Cargo runs from `backend/` only.** The workspace root is
  `backend/`, not the repo root.
- **The PC build script does not stop on cargo test failure.** Read
  the log yourself and grep for failures.
- **Goldens are time-sensitive by design.** The Logs golden is pinned
  (see Testing). If a golden fails, check whether the screen actually
  changed before regenerating it.

## Rules that govern this repo (do not break them)

- No em dashes or en dashes anywhere, in chat or in anything written
  in his name (README and docs included).
- Only push working, completed code to git. Verification (tests green,
  analyze clean) must pass BEFORE `git push`. If it is not green, it
  stays local and gets reported as outstanding.
- Implement with our own code where possible. Learn from outside
  projects, do not copy or adopt them wholesale. No RiftLinux in
  ReOculus at all (his ruling): no code, bundle, or link.
- Safety: no install/uninstall/clear-data/delete/reboot on the real
  headset without his say-so; read-only live tests are fine. Never `pm
  disable-user com.oculus.updater` (use Singularity OTA defer in the
  headset). Never run `ota allow` on the real headset.
- PARKED, do not reopen without his word: ReOculus Home launcher, Beat
  Saber mods, real store + sideloaded-app update check, runtime from
  scratch / WiVRn fork. USB support for Android is researched, not
  started, needs his go.
- When fixing his post draft, fix only the mistakes, do not change his
  wording or structure. Public posts must sound 100% human, plain,
  amateur, not AI-like.
- Chat split: this chat builds. Research goes in the research chat.
  Reddit posts, GitHub pushes/releases, and public email go through the
  Public chat, unless Anthony asks for the push directly here.
