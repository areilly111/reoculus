# Building the Android APK and applying Android fixes

How to build the ReOculus Android app properly, and how to make and land
an Android fix. This is the Android companion to `docs/BUILDING.md`
(which covers the whole project, the Linux AppImage, and the shared
workflow). Read this one when the work is Android-only; it stands on its
own. The general rules still apply: verify before you commit, ship one
newest build per artifact, and Anthony's test on his own hardware is the
only thing that closes a fix.

## What the Android app is

One Flutter app, two targets in one codebase (`flutter_app/`). The Linux
build and the Android build share the Dart code and differ in the
platform layer:

- **Dart (shared):** the UI, the app state, the mirror service
  (`lib/services/h264_mirror.dart`), the recording service
  (`lib/services/recording.dart`), the backend service
  (`lib/services/backend.dart`). Platform differences are gated on
  `Platform.isAndroid` (dart:io). Do not gate on
  `defaultTargetPlatform` in tests: it lies (reports android) while
  `Platform.isAndroid` is false.
- **Backend (Rust, shared):** questctl. On Linux it runs as a separate
  `questctl` binary next to the app. On Android it is bundled as a
  native library (`libquestctl.so`) and the app spawns it as a child
  process. Same code, same flags, different packaging.
- **Android platform layer (Kotlin):** `MainActivity.kt` (the
  MethodChannels) and `H264Decoder.kt` (the MediaCodec H.264 decoder
  that renders the live mirror into a Flutter texture). This is where
  Android-only mirror bugs live.
- **Linux platform layer (C):** `flutter_app/linux/runner/h264_decoder_plugin.c`
  (ffmpeg via dlopen). Do not touch it for an Android fix.

The Android package name is `com.questcompanion.quest_companion`. That
is different from the Linux application ID (`com.reoculus.app`). Use the
Android one for `dumpsys` and `adb` on the tablet and phone.

## The Android build pipeline (in order)

1. Bump the version (see "Version bump" below).
2. Build the Android questctl binary (cross-compile for aarch64).
3. Copy it to BOTH asset locations and verify the SHAs match.
4. Build the APK with Flutter.
5. Install on hardware (tablet and/or phone) and verify.
6. Commit, and push/release only when Anthony asks.

Do not skip step 3. The APK build does not rebuild questctl; it bundles
whatever is in the two asset locations. If you skip the copy, the APK
ships a stale backend and the tablet runs old code while the source
says otherwise.

## Version bump (Android)

The version lives in four places (see `docs/BUILDING.md` for the full
list). The Android-specific one is the versionCode:

- `flutter_app/pubspec.yaml` — `version: 0.2.x+N`. The part after the
  `+` is the Android versionCode. **Bump it by 1 on every APK build.**
  Android treats an APK with a non-increasing versionCode as a
  downgrade and refuses to install it as an update; the user just sees
  a cryptic install failure. The versionName (`0.2.x`) and the
  versionCode (`N`) must both move together with the Rust version in
  `backend/quest-core/Cargo.toml` and `backend/questctl/Cargo.toml` and
  the About text in
  `flutter_app/lib/screens/device_mirror_logs_setup.dart`.

Current: version `0.2.36+38` (versionCode 38). The next APK is `+39`.

## 1. Building the Android questctl binary

```bash
cd ~/workspace/quest-companion
bash backend/scripts/build-android.sh
```

This cross-compiles questctl for aarch64-linux-android (NDK
27.0.12077973), strips it, and writes
`backend/target/aarch64-linux-android/release/questctl` (~5.4 MB, ELF
64-bit LSB pie executable, ARM aarch64). It applies the same remap flag
as the Linux build (`--remap-path-prefix=$HOME=/build`) so the build
machine's absolute paths never ship in the binary. Verify with:

```bash
strings backend/target/aarch64-linux-android/release/questctl | grep -c /home/hatch
# Expect 0.
file backend/target/aarch64-linux-android/release/questctl
```

**The script does NOT copy the binary.** You must copy it by hand to
BOTH places and verify the SHAs match:

```bash
cp backend/target/aarch64-linux-android/release/questctl flutter_app/assets/questctl-android-arm64
cp backend/target/aarch64-linux-android/release/questctl flutter_app/android/app/src/main/jniLibs/arm64-v8a/libquestctl.so
sha256sum flutter_app/assets/questctl-android-arm64 flutter_app/android/app/src/main/jniLibs/arm64-v8a/libquestctl.so
```

The two SHAs must be identical. The `assets/` copy is what the Dart
code extracts at runtime; the `jniLibs/` copy is what Android loads as
the native library. If they disagree, the tablet runs whichever one the
app actually loads, and you will chase a bug that is not in the source.

If the backend source changed (Rust) but you did not rebuild the
Android questctl, the APK still contains the old binary. Always rebuild
it after a Rust change, even a small one. The mirror-stream flags
(`--bit-rate`, `--size`) live in the Rust code, so a Dart-only change
does not need a questctl rebuild, but a Rust change always does.

## 2. Building the APK

```bash
cd ~/workspace/quest-companion/flutter_app
export PATH="$HOME/workspace/flutter-sdk/bin:$PATH"
export ANDROID_HOME=$HOME/workspace/android-sdk
export JAVA_HOME=$HOME/workspace/android-toolchain/jdk-17
export GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"
export GRADLE_USER_HOME=$HOME/.gradle
flutter build apk --release
```

The APK lands at
`flutter_app/build/app/outputs/flutter-apk/app-release.apk` (~29.5 MB).
Record its SHA-256; that is what you report to Anthony.

### Rules that will bite you if you skip them

- **Never `flutter clean` before a VM APK build.** It wipes the
  cargokit pre-seed, and the drag plugin's Rust build
  (`super_drag_and_drop` -> `irondash_engine_context`) then runs `dart
  pub get` in a temp dir and 407s through the egress proxy, killing
  the whole build. Warm build is ~3.5 min, cold is ~16 min. If a build
  fails with `407 Proxy Authentication Required` for pub.dev, the
  pre-seed is gone; re-seed it by hand (see "Fixing a broken build"
  below) instead of cleaning again.
- **No proxy lines in gradle.properties.** This sandbox reaches Maven
  Central and Google Maven directly. Proxy lines break dependency
  downloads: the proxy password rotates, and a stale one surfaces as
  a connection reset that looks like an SSL error. Keep
  `~/.gradle/gradle.properties` free of `systemProp.{http,https}.proxy*`
  lines. (If a JVM ever must go through the proxy, import
  `/usr/local/share/ca-certificates/hatch-egress-ca.crt` into that
  JDK's `lib/security/cacerts` first, or it fails as a PKIX error.)
- **Gradle daemon vs IPv6.** This sandbox blackholes AF_INET6 loopback
  TCP (a connect to ::ffff:127.0.0.1 "succeeds" but data never arrives),
  which silently kills the Gradle client-daemon handshake ("first
  result from the daemon was empty").
  `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"` is what lands the
  flag on the client JVM. Passing it as a gradle program arg does NOT
  work: the `gradle` shell script puts user args after `GradleMain`,
  so it never becomes a JVM property (verified with strace). If
  daemons wedge, kill with `pkill -f "[G]radleDaemon"` (the brackets
  keep it from matching your own shell) and `rm -rf /root/.gradle/daemon`.
- **Kotlin compile daemon.** `gradle.properties` must have
  `kotlin.compiler.execution.strategy=in-process`, or the Kotlin
  compile daemon dies on the same IPv6 loopback blackhole ("Could not
  connect to Kotlin compile daemon").
- **`ANDROID_HOME` must be exported.** The env does not carry it by
  default. Without it the build fails looking for the SDK.
- **uid 0's Gradle home is /root/.gradle (ephemeral).** Pin
  `GRADLE_USER_HOME=$HOME/.gradle` so the dependency cache persists
  across VM replacements.
- **Do not edit `flutter_app/` during an APK build.** The build reads
  the tree as it goes; an edit mid-build produces a mixed artifact.
  Wait for the build to finish, then edit.

### Fixing a broken build

- **`407 Proxy Authentication Required` for pub.dev** (usually from
  the drag plugin's cargokit step): the pre-seed is gone. Re-seed it
  by hand: `cd` into the temp dir
  (`flutter_app/build/irondash_engine_context/build/build_tool/`),
  run `dart pub get --no-precompile` with the Flutter SDK's dart,
  write the hash with
  `ls -lR --full-time <that dir> | shasum > .package_hash`, and
  `dart compile kernel bin/build_tool_runner.dart`. After that the
  Gradle step skips pub get and the build proceeds. Direct (proxyless)
  pub.dev does NOT work, so do not unset the proxy for this step. The
  proxy works again once the password rotates; retrying the whole build
  sometimes lands in a good window, but the pre-seed is deterministic.
- **Gradle daemon handshake empty / Kotlin daemon cannot connect:**
  the IPv6 loopback blackhole. Check that `GRADLE_OPTS` and
  `kotlin.compiler.execution.strategy=in-process` are set (above),
  kill wedged daemons, and retry.
- **A stale questctl in the APK:** you forgot step 3 (the copy) or the
  SHAs do not match. Rebuild the Android questctl, copy to both
  locations, verify the SHAs, then rebuild the APK.

## 3. Signing (do not break this)

The APK is signed with a persistent keystore at
`flutter_app/android/keystore/reoculus.keystore` (alias `reoculus`,
RSA 2048), wired via `flutter_app/android/keystore.properties` (mode
600, gitignored) into a signing config used by the release build.
Certificate SHA-256:
`c0a2a5407ea6ce0ab2790705ca46268b00416fca1bf9e4870674ad85d4ec4b75`.

- **Never print the keystore passwords. Never lose the keystore.**
  If it is lost, sideloaded apps can never be updated in place again;
  the user would have to uninstall and reinstall, losing app data.
- **Never install the debug-signed 0.2.33 build again** (SHA
  `4cc402ed...`). The debug keystore lives in `/root/.android/` (uid
  0's home, NOT $HOME) and is wiped on VM replacement, so a fresh key
  gets generated per VM and updates fail with "signatures do not
  match".
- **Bump the versionCode on every APK build** (see "Version bump"),
  or Android refuses the update as a downgrade.

## 4. Installing on hardware

The APK is installed over adb from the PC. The relay dies often; check
it first (`ss -tlnp | grep 22224`, restart
`~/workspace/relay-desktop.py` if it is down).

Devices (as of 2026-11-16):

- **Tablet:** Galaxy Tab S6 Lite 2024 (SM-P620, Android 16), adb serial
  `R52Y403392Y` (USB to the PC), also on Wi-Fi adb at
  `192.168.100.132:5555`. This is the main Android test device.
- **Phone:** Galaxy S23 Ultra (SM-S918W), on Wi-Fi adb at
  `192.168.100.199:5555`. Installed 2026-11-16, 0.2.36.
- **Quest 2:** serial `1WMHHB630X1464`, USB to the PC and Wi-Fi adb at
  `192.168.100.112:5555`. The headset the app talks to.

```bash
# Copy the APK to the PC first (scp from the VM).
scp -i /home/hatch/.ssh/id_ed25519_mainpc -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o BatchMode=yes -P 22224 \
  ~/workspace/quest-companion/flutter_app/build/app/outputs/flutter-apk/app-release.apk \
  anthony@127.0.0.1:/tmp/ReOculus-Android-0.2.36.apk

# Install on the tablet (use the phone's address for the phone).
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

## How the Android mirror works (so you can fix it)

The live mirror is the part of the Android app that breaks most often.
Here is the pipeline, end to end, so a fix lands in the right place.

1. **Dart** (`lib/services/h264_mirror.dart`, `H264Mirror.start`)
   spawns the bundled questctl as a child process:
   `device mirror-stream --serial <addr> --bit-rate <N> --size <WxH>`.
   On Android it passes 4 Mbps and 960x540; on Linux 8 Mbps and
   1280x720. The PC values are frozen; do not change them.
2. **questctl** (Rust, `device mirror-stream`) runs `screenrecord
   --output-format=h264 --size <WxH> --bit-rate <N> --time-limit 180 -`
   on the headset in a loop and writes raw Annex B H.264 to stdout.
   Each 180 s run starts with SPS/PPS/IDR. Only ONE screenrecord can
   run on the headset at a time; a second one fails with exit code 218.
3. **Dart feed (Android only, paced).** adb delivers the stream in
   bursts over Wi-Fi. Incoming stdout chunks queue up, and a 33 ms
   timer drains the WHOLE queue each tick (not one chunk per tick;
   one per tick could not keep up at 4 Mbps and dropped keyframes,
   which left the picture blocky). The queue is capped at 90 chunks;
   past that the oldest is dropped. On Linux the chunks go straight
   to the decoder as they arrive.
4. **Kotlin** (`H264Decoder.kt`, via the `reoculus/h264`
   MethodChannel). `create(width, height)` makes the SurfaceTexture
   and returns the texture id. The decoder itself is NOT configured
   until the stream's SPS and PPS arrive; they are handed to it as
   codec config (`csd-0` and `csd-1`), the way a video player gets
   them from a file header, instead of relying on the in-band SPS/PPS
   alone. Bytes are held back until both are found, then fed along
   with the rest. `feed(bytes)` hands bytes to the MediaCodec
   (`c2.exynos.h264.decoder` on the Tab S6 Lite). When the decoder is
   busy, leftover bytes wait in a `pending` buffer (cap 512 KB) for
   the next feed; past the cap the oldest bytes go. `release()` stops
   and releases the decoder, surface, and texture.
5. **Render.** The decoder outputs to the Surface, Flutter shows it as
   a Texture on the Mirror screen. The View switch (Both eyes / Flat)
   is a Dart layout choice, not a decoder setting.

### The blockiness fixes, in order (do not redo them)

See `docs/session-notes-0.2.36.md` for the full story. Short version:

1. Bitrate 8 -> 4 Mbps (tablet only). Still blocky.
2. Resolution 720p -> 540p (tablet only). Still blocky.
3. Drain the whole queue each tick (was one chunk per tick). Still
   blocky.
4. Decoder gets SPS/PPS as codec config up front (current build).
   Verdict pending as of 2026-11-16.

What the diagnosis proved: the stream data arriving at the tablet is
good (a 12 s capture decoded with ffmpeg with zero errors, frames clean
and sharp), and the tablet's decoder hardware is fine (a high-motion
960x540 at 4 Mbps test clip plays fine in the tablet's video player).
So the problem is the app's decoder setup/feed path, not the Wi-Fi, the
encoder, or the decoder hardware. If the CSD build is still blocky, the
next things to try are in `docs/session-notes-0.2.36.md` ("If the CSD
build is still blocky, try next").

## Testing an Android fix

Run the shared checks before every commit (see `docs/BUILDING.md`):
`cargo test --release` (114 pass), `flutter analyze` (0 errors,
0 warnings), `flutter test` (only the pre-existing widget_test failure).
Then build the APK, install it, and verify on the device.

### Checking the tablet over adb

```bash
# Is the app running, and is the mirror streaming?
adb -s R52Y403392Y shell 'ps -A | grep -iE "quest|reoculus"'
# Expect: com.questcompanion.quest_companion, and a libquestctl.so
# child with the mirror-stream args (--bit-rate, --size).

# Is the tablet's Wi-Fi to the headset clean?
adb -s R52Y403392Y shell 'ping -c 20 -i 0.2 192.168.100.112'
# Expect: 0% packet loss.

# What is the decoder doing? (no errors is normal; the decoder does
# not report blockiness, it just decodes what it gets)
adb -s R52Y403392Y shell 'logcat -d -t 500 --pid=<app-pid> | grep -iE "mediacodec|CCodec|decoder" | grep -iE "error|fail|drop|corrupt"'
```

### Capturing the stream the tablet receives

This is the decisive test when the picture is bad: capture the exact
bytes the tablet gets over its Wi-Fi and decode them with ffmpeg on the
VM. If ffmpeg decodes them cleanly, the data is good and the problem is
the app's decoder path. If ffmpeg shows errors, the data itself is bad.

```bash
# Push a questctl binary to the tablet (the app's copy is not readable
# from the shell; /data/app is permission denied).
scp <questctl> anthony@127.0.0.1:/tmp/questctl   # from the VM
adb -s R52Y403392Y push /tmp/questctl /data/local/tmp/questctl
adb -s R52Y403392Y shell 'chmod 755 /data/local/tmp/questctl'

# Stop the app's stream first (only one screenrecord at a time).
# The shell user cannot kill the app's processes; use force-stop.
adb -s R52Y403392Y shell 'am force-stop com.questcompanion.quest_companion'

# The headset falls asleep fast once the stream stops. Wake it first
# (over USB to the Quest from the PC), or the capture fails with
# screenrecord exit 218.
adb -s 1WMHHB630X1464 shell input keyevent KEYCODE_WAKEUP

# Capture 12 s from the tablet shell. HOME must be writable or
# keypair creation fails. The direct-TLS port varies; read it from
# the running questctl command line first, do not assume 38933.
adb -s R52Y403392Y shell 'HOME=/data/local/tmp/qchome2 /data/local/tmp/questctl --transport direct --addr 192.168.100.112:<port> device mirror-stream --serial 192.168.100.112:<port> --bit-rate 4000000 --size 960x540 > /data/local/tmp/capture.h264 2>/data/local/tmp/capture.err & echo $! > /data/local/tmp/capture.pid; sleep 12; kill $(cat /data/local/tmp/capture.pid); ls -la /data/local/tmp/capture.h264'

# Pull it and decode it on the VM.
adb -s R52Y403392Y pull /data/local/tmp/capture.h264 /tmp/capture.h264
ffmpeg -v error -i /tmp/capture.h264 -f null -
# Empty output = zero decode errors = the data is good.
ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1 /tmp/capture.h264
```

A known-good high-motion test clip is already on the tablet at
`/sdcard/Movies/decoder-test.mp4` (960x540 at 4 Mbps, generated with
ffmpeg testsrc2). Play it in the tablet's video player to check the
decoder hardware in isolation: if it plays fine, the decoder is fine
and the problem is the app's path.

## Android gotchas (in one place)

- **The two questctl copies must match.** See step 3 above. This is
  the most common self-inflicted Android bug.
- **versionCode must increase every APK build**, or Android refuses
  the update as a downgrade.
- **Never `flutter clean` before a VM APK build.** It wipes the
  cargokit pre-seed and the build 407s on pub.dev.
- **Gradle needs `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"`**
  (client JVM) and `kotlin.compiler.execution.strategy=in-process`.
  Without them the daemons die on the IPv6 loopback blackhole.
- **No proxy lines in gradle.properties.** Direct Maven Central and
  Google Maven work; proxy lines break downloads.
- **The keystore is irreplaceable.** `flutter_app/android/keystore/reoculus.keystore`
  plus `keystore.properties` (mode 600, gitignored). Never print the
  passwords. Never install the debug-signed 0.2.33 build.
- **Only one screenrecord at a time.** A second stream fails with
  exit 218. Stop the app's stream (force-stop) before capturing from
  the shell, and wake the headset first or the capture fails the same
  way.
- **The shell user cannot kill the app's processes or read /data/app.**
  Use `am force-stop` to stop the app. Push binaries to
  `/data/local/tmp/` instead.
- **Running questctl from the tablet shell needs a writable HOME**
  (`HOME=/data/local/tmp/qchome2`).
- **The direct-TLS port varies.** Read it from the running questctl
  command line; do not hardcode it.
- **The tablet's Wi-Fi is the stream path.** The Quest being on USB to
  the PC does not change the tablet mirror; the tablet still gets the
  stream over Wi-Fi (tablet -> AP -> headset). The PC mirror is a
  separate path and is frozen.
- **Do not edit `flutter_app/` during an APK build.**
- **`Platform.isAndroid` is the gate in Dart; `defaultTargetPlatform`
  lies in tests.** `FakeBackend` needs a stub for every new
  `BackendService` member or the golden tests crash.
- **The app package name is `com.questcompanion.quest_companion`.**
  The Linux application ID (`com.reoculus.app`) is different. Use the
  Android one for `dumpsys` and `adb` on the tablet and phone.

## Rules that govern Android work (do not break them)

- No em dashes or en dashes anywhere, in chat or in anything written
  in his name.
- Only push working, completed code. Verification (cargo tests, flutter
  analyze, flutter test) must pass BEFORE `git push`.
- The PC mirror is frozen. Android fixes must not change the PC stream
  (1280x720 at 8 Mbps, direct feed).
- Safety: no install/uninstall/clear-data/delete/reboot on the real
  headset without his say-so; read-only live tests are fine. Never `pm
  disable-user com.oculus.updater`. Never run `ota allow` on the real
  headset.
- Ship one newest APK per build, version bumped. When he asks for an
  APK, send only the most recent build.
- USB support for Android is researched, not started, needs his go.
  (libadb has USB transports, but an Android app cannot open
  /dev/bus/usb directly and a child process cannot inherit the
  UsbManager fd. The real routes are FFI in-process Rust or the ADB
  protocol over UsbDeviceConnection in Dart/Kotlin.)
