# Session notes: ReOculus 0.2.36 (2026-11-15)

Handoff for the next agent picking up ReOculus. This covers what was built,
fixed, and diagnosed in this session, and what is still open. For how to
build the app and apply a fix, read `docs/BUILDING.md` (it is the build
and fix guide; this file is the session log). The user
(Anthony) tests on his own hardware and his verdict is the only thing that
closes a request. State work as built and awaiting his test, never fixed,
until he confirms it.

## Where things stand

- Latest version: **0.2.36**, committed locally and **pushed + released on
  GitHub** (tag `v0.2.36`, AppImage on the release page). See "Git state"
  below.
- PC AppImage 0.2.36: built, SHA-256
  `9c1a398488b57258b5a7fd72567e4e3c0d745fb016abed61430eaa0bcad48613`,
  31,222,264 bytes. Anthony's verdict: **PC mirror works perfect, do not
  touch it further.** The PC mirror is FROZEN: 1280x720 at 8 Mbps, chunks
  fed straight through, exactly as it was in 0.2.35.
- Tablet APK 0.2.36 (versionCode 38): installed on his Galaxy Tab S6 Lite
  2024 (SM-P620, adb serial R52Y403392Y). Latest build has the CSD fix
  (see below), SHA-256
  `4d2045c2ef1244024887e42d0469acfe800ff80e8029c5248c9136b1f80a3c66`,
  29,549,278 bytes. **His verdict on the tablet mirror is still open:
  it is still very blocky.** The blockiness is the main unresolved thread.
- The user asked for this document so the next agent does not have to
  re-derive any of this. Read it before touching the mirror code.

## What 0.2.36 is (his four requests, 2026-11-15 21:08 CST)

1. Mirror "less glitchy and more stable, i dont mind if theres slight
   delay". Done: the Android feed is paced (queue + 33 ms tick) and the
   tablet stream was lowered; see the blockiness saga below.
2. "i like having both eyes like that but is there a way to have a flat
   image?" Done: the Mirror screen has a View switch, Both eyes (default)
   / Flat (one eye). Flat shows the left eye at native 8:9.
3. "lets also remove the scrcpy and any of its unneeded dependcies".
   Done: scrcpy is gone from the backend, the CLI, the Dart service, and
   the Mirror screen. The built-in H.264 stream is the only mirror now.
   (scrcpy 3.3.4 is still installed on his PC as a system package; the
   app just does not use it.)
4. "include a way to start recording after 3 mins again if user doesnt
   stop recording combining all videos togither at the end". Done:
   `device record-loop` records in 3-minute pieces and `device
   record-finish` joins them into one video (.mp4 when ffmpeg is
   installed, otherwise raw .h264). The Mirror Record button uses it.

## The tablet blockiness saga (in order, with verdicts)

The tablet mirror was blocky from 0.2.34 on. Each fix below was tried,
built, installed on the tablet, and tested by Anthony. All of them were
still blocky except the last one, whose verdict is pending.

1. **Bitrate 8 Mbps -> 4 Mbps (tablet only).** Commit `11c8077`.
   Reasoning: the tablet gets the stream over two Wi-Fi hops. Verdict:
   still blocky. So it is not the bitrate alone.
2. **Resolution 720p -> 540p (tablet only).** Commit `3519927`.
   `device mirror-stream` gained `--size` (default 1280x720); the app
   passes 960x540 on Android. The Android decoder is configured for the
   size it is given. Reasoning: same 4 Mbps over half the pixels, half
   the data to lose. Verdict: still blocky.
3. **Drain the whole queue each tick.** Commit `06b3ac4`.
   The Android paced feed used to feed ONE chunk per 33 ms tick, but adb
   delivers small chunks, so at 4 Mbps more chunks arrive per second than
   one per tick can drain. The queue (cap 90) filled and dropped the
   oldest bytes, keyframes included, which leaves the picture blocky
   until the next keyframe. The tick now drains the whole queue each time
   it fires. Verdict: still blocky.
4. **Give the decoder the SPS/PPS as codec config (csd-0/csd-1).**
   Commit `844e8e2`. This is the current build on the tablet.
   Reasoning: see "Decoder diagnosis" below. Verdict: PENDING, Anthony
   has not tested this build yet.

## Decoder diagnosis (2026-11-15, the evidence)

The question was whether the tablet's decoder is the problem. The
evidence says the decoder HARDWARE is fine, and the stream data is good,
so the problem is how the app sets up and feeds the decoder.

- Captured the exact stream the tablet receives over its Wi-Fi (12 s,
  960x540 at 4 Mbps, 711 frames) by running the tablet's own questctl
  from the tablet shell. ffmpeg decodes it with **zero errors**, and the
  frames are clean and sharp (checked one visually: the Quest home,
  sharp, no macroblocking). So the data arriving at the tablet is good.
  Not the Wi-Fi, not the encoder, not the feed.
- Tablet Wi-Fi to the headset: 0% packet loss, ~8 ms rtt (ping, 20
  packets). Clean.
- Put a high-motion test clip on the tablet
  (`/sdcard/Movies/decoder-test.mp4`, 960x540 at 4 Mbps, generated with
  ffmpeg testsrc2). Anthony played it in the tablet's video player:
  **it plays fine**. So the tablet's MediaCodec decoder
  (c2.exynos.h264.decoder) decodes the same codec, resolution, and
  bitrate cleanly. The hardware is fine.
- The difference is how the decoder is set up: a video player gets the
  SPS/PPS from the file header as codec config (csd-0/csd-1), while the
  app relied on them arriving in-band in the raw stream alone. That is
  what fix #4 above changes.
- The decoder reports no errors in logcat (only benign "query failed
  after returning 14 values (BAD_INDEX)" at setup and "Ignoring stale
  input buffer done callback" at stream start).

### If the CSD build is still blocky, try next (in order)

1. **Feed complete NAL units instead of arbitrary chunks.** The app
   feeds whatever adb delivers, split at arbitrary byte boundaries.
   The video player feeds complete access units (frames). Parse the
   Annex B stream for start codes in Kotlin and only queue complete
   NAL units to the decoder.
2. **Check the Kotlin pending buffer.** `H264Decoder.feed` holds bytes
   in `pending` (cap 512 KB) when the decoder is busy and drops the
   oldest past the cap. Add a log line when it drops, and see if it
   fires during a blocky moment. If it fires, the decoder is stalling
   (not the feed).
3. **Check the rendering, not the decode.** The decoder outputs to a
   SurfaceTexture that Flutter shows as a Texture. If the texture is
   being displayed at the wrong size or scaled badly it can look
   blocky even when the decode is fine. Compare the Mirror screen's
   texture box against the actual decoded frame size.
4. **Try a software decoder as a test.** If the picture is clean with
   a software decode (e.g. libavcodec on Android, or ffmpeg via the
   same dlopen approach as the Linux C plugin), the Exynos decoder's
   handling of this stream is the problem, and the fix is to work
   around it rather than to keep tuning the feed.

## Other fixes in this session

- **Personal-info scrub** (commit `11c8077`, his request). The working
  tree is verified clean by grep (no matches for his name, the real
  headset serial, the real headset IP, or /home/anthony). Changed:
  LICENSE (now "Copyright (c) 2026 ReOculus contributors"), the real
  headset serial in a transport.rs test (now a fake `1WMHHB630X0002`),
  the real headset IP in test fixtures and scripts (now `192.168.1.42`),
  /home/anthony to /home/user in fixtures/comments, "Anthony's Quest" to
  "My Quest" in a headset-config example, first-name mentions out of
  comments, and the real storage figure out of the README 0.2.26 entry.
  The `192.168.1.x` example addresses were left alone. **The pushed git
  history through v0.2.28 still carries all of this, and every commit
  except `11c8077` is authored with his name.** Scrubbing history needs
  a rewrite plus force push. That is HIS call; he has not answered it.
  Do not do it without his explicit go.
- **Logs golden test made deterministic.** `AppState.log` takes an
  optional fixed timestamp and the golden test pins it, so the Logs
  screen no longer fails whenever the minute changes. The only remaining
  test failure is the pre-existing `widget_test.dart` "App builds and
  shows navigation" (expects text "Devices"; verified pre-existing via
  git stash). Do not chase it; it predates this session.
- **PC AppImage built and smoke-tested under xvfb.** The live PC stream
  did not start in xvfb because a screenrecord was already running on
  the headset (his tablet mirror session); only one screenrecord can
  hold the display, and a second one fails with exit code 218. That is
  expected, not a bug. His own verdict (PC mirror works perfect) covers
  it.

## Git state

- Remote: `https://github.com/areilly111/reoculus.git` (origin).
- Local master HEAD: `844e8e2` (0.2.36 + CSD fix). **Pushed to origin
  2026-11-15.** The push included 26 commits (0.2.29 through 0.2.36).
  Tag `v0.2.36` pushed. GitHub release `v0.2.36` created with the
  AppImage as its only asset:
  https://github.com/areilly111/reoculus/releases/tag/v0.2.36
- The AppImage and APK are gitignored by design (`releases/`,
  `QuestCompanion-*-x86_64.AppImage`, `*.apk` in .gitignore). They go on
  GitHub as release assets, NOT committed into the repo. The v0.2.36
  release is AppImage-only; the APK is delivered to Anthony directly.
- `gh` is authenticated in this VM (account areilly111, token scopes
  gist/read:org/repo) and `git push` / `gh release create` work from
  here. GitHub tokens are never stored in chat or files.
- Untracked, intentionally NOT committed: `scripts/figcraft_export.py`
  (the FigCraft theme export generator).
- Chat split (Anthony, 2026-11-13): THIS chat builds. The Public chat
  owns Reddit posts, GitHub pushes/releases, and public email. The
  0.2.36 push/release was done from this chat because Anthony asked
  for it directly ("puth this appimage to the git"). Normally, pushes
  go through the Public chat.

## Files changed in this session (0.2.36)

- `backend/quest-core/src/media.rs`: `mirror_stream` takes `--bit-rate`
  and `--size`; `record_loop` / `record_finish` for long recordings;
  scrcpy functions removed.
- `backend/questctl/src/main.rs`: MirrorStream gains `--bit-rate` and
  `--size`; `device record-loop` (raw, non-JSON) and `device
  record-finish` (JSON); scrcpy CLI commands removed.
- `backend/quest-core/src/mirror_settings.rs`: rewritten view-only
  (stereo/flat, `normalize_view`, get/set/reset).
- `backend/quest-core/src/mirror_watch.rs`: deleted.
- `flutter_app/lib/services/h264_mirror.dart`: `start` takes
  `bitRate`, `width`, `height`; paced feed (Android only) drains the
  whole queue each tick; Linux feeds straight through.
- `flutter_app/lib/services/recording.dart`: new, `RecordingSession`
  for the long recordings.
- `flutter_app/lib/screens/device_mirror_logs_setup.dart`: Mirror
  screen View switch (Both eyes / Flat), Record Start/Stop, no scrcpy
  UI anywhere.
- `flutter_app/android/app/src/main/kotlin/.../H264Decoder.kt`:
  decoder configured only once the stream's SPS/PPS arrive, handed to
  it as csd-0/csd-1; holds bytes back until then; pending buffer for
  decoder-busy moments (cap 512 KB).
- `flutter_app/android/app/src/main/kotlin/.../MainActivity.kt`:
  'create' passes width/height to the decoder.
- `flutter_app/lib/services/app_state.dart`: `log` takes an optional
  fixed timestamp (for the golden test).
- `flutter_app/test/widget/apps_screenshots_test.dart`: log timestamps
  pinned in the golden test.
- `README.md`, `backend/CONTRACT.md`, `CREDITS.md`,
  `backend/README.md`: changelog + contract updates for 0.2.36, scrcpy
  references removed.
- `LICENSE`: copyright line scrubbed (see above).

## Hardware and access (for diagnosis)

- Quest 2: serial `1WMHHB630X1464`, rooted, offline, Wi-Fi
  192.168.100.112 (port 5555 classic; direct-TLS port varies, was 38933
  on 2026-11-15). Sleeps fast; a screenrecord already running blocks
  any second stream (exit 218). If a capture right after stopping the
  app fails with 218, wake it first: `adb shell input keyevent
  KEYCODE_WAKEUP` over USB.
- Tablet: Galaxy Tab S6 Lite 2024 (SM-P620, Android 16), adb serial
  R52Y403392Y, LAN 192.168.100.132, on USB to the PC. Android package
  `com.questcompanion.quest_companion`. The app runs questctl as
  libquestctl.so (native library dir). Running questctl from the tablet
  shell needs `HOME=/data/local/tmp/qchome2` or keypair creation fails.
  The shell user cannot kill the app's processes or read /data/app;
  use `am force-stop` to stop the app, and push a questctl binary to
  /data/local/tmp/ to run captures from the shell.
- PC access: relay `~/workspace/relay-desktop.py` (127.0.0.1:22224 ->
  100.90.30.39:22), dies often, restart it before assuming it is up.
  SSH: `ssh -i /home/hatch/.ssh/id_ed25519_mainpc -o
  UserKnownHostsFile=/home/hatch/.ssh/known_hosts_desktop -o
  BatchMode=yes -p 22224 anthony@127.0.0.1`. PC canonical repo:
  /mnt/64D649ADD6498072/Programming/quest/. VM repo:
  ~/workspace/quest-companion/. rsync VM->PC must use the relay ssh
  options and exclude `releases/`, `/backend/target/`,
  `/flutter_app/build/`, `/flutter_app/.dart_tool/`.
- Android signing (permanent since 0.2.33): keystore
  `flutter_app/android/keystore/reoculus.keystore`, passwords in
  `flutter_app/android/keystore.properties` (mode 600, gitignored).
  Never print them, never lose the keystore. Never install the
  debug-signed 0.2.33 build again.
- APK builds: `ANDROID_HOME=$HOME/workspace/android-sdk`,
  `JAVA_HOME=$HOME/workspace/android-toolchain/jdk-17`,
  `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"`,
  `GRADLE_USER_HOME=$HOME/.gradle`, NO proxy lines in gradle.properties.
  Never `flutter clean` before a VM APK build (wipes the cargokit
  pre-seed; pub.dev 407s through the proxy otherwise). Warm build
  ~3.5 min. `backend/scripts/build-android.sh` builds the Android
  questctl but does NOT copy it; manually copy to
  `flutter_app/assets/questctl-android-arm64` AND
  `flutter_app/android/app/src/main/jniLibs/arm64-v8a/libquestctl.so`
  and verify the SHAs match.

## Open items (not just the mirror)

- History scrub decision (see above): rewrite + force push, or leave
  the history as is. Awaiting Anthony.
- His verdicts still open: 0.2.29 SteamVR gate, 0.2.30 Files
  drag-drop, 0.2.31 games edit, 0.2.32 Setup checklist, S23 Ultra APK
  install, WiVRn Wi-Fi in-headset + settings-bitrate tests, FigCraft v3
  export open test, Quest 1 detection (needs a Reddit Quest 1 tester).
- USB connection support for Android: researched, verdict delivered in
  outline, NOT started, needs his go.
- PARKED, do not reopen without his word: ReOculus Home launcher, Beat
  Saber mods, real store + sideloaded-app update check, runtime from
  scratch / WiVRn fork. No RiftLinux in ReOculus at all (his ruling).

## FigCraft export v3 (2026-11-16, ReOculus 0.2.36)

- Generator: `scripts/figcraft_export.py` (uncommitted by design). Run
  `python3 scripts/figcraft_export.py [--outdir <dir>]`. It validates
  linkage and must report "problems: none".
- v3 updates the Mirror frame for 0.2.36: scrcpy is gone (Quality card,
  USB/Wi-Fi quality chips, auto-restart switch removed), the live view
  card has the View switch (Both eyes / Flat (one eye)) and Start live
  view, and the Record card says recordings keep going with 3-minute
  pieces joined into one video. Verified: 11 frames, 914 nodes,
  184 instances, 14 components, 21 styles, 0 problems; combined file
  524,401 bytes, SHA-256
  `5c726929c09cc28f70fdf5232204906458dc54ccb17985086a7bc14aed8e0de3`.
  No scrcpy anywhere in the export.
- Canonical home is the main PC folder:
  `/mnt/64D649ADD6498072/Programming/quest/figcraft/` (12 JSON files +
  README.md, with the generator and regen steps). Also in
  `~/workspace/your_files/` and the goal files dir (combined file +
  README). The export files are deliverables, not committed to git.

## Waking the Quest from sleep (verified 2026-11-16, main chat)

- The Quest 2 can be woken from sleep over USB adb AND over Wi-Fi adb, both
  tested live on his headset. Wi-Fi stays alive while it sleeps, so the
  Wi-Fi adb connection still answers.
- Command, either transport: `adb shell input keyevent 26` (power key
  toggle). Verified: `mWakefulness=Asleep` went to `Awake` on USB, then
  put back to sleep and woken again over Wi-Fi to 192.168.100.112:5555.
- Check state with: `adb shell dumpsys power | grep mWakefulness`.
- His Quest 2 USB serial is 1WMHHB630X1464, Wi-Fi adb is
  192.168.100.112:5555. (Tablet is 192.168.100.132, his S23 Ultra is
  192.168.100.199, do not mix them up.)

## Rules that govern this repo (do not break them)

- No em dashes or en dashes anywhere, chat or anything in his name.
- Ship one newest build per artifact, version bumped. Never push
  non-working code to git; verify before committing (cargo tests,
  flutter analyze, flutter test).
- PC mirror is frozen. Do not change the PC stream (1280x720 at 8 Mbps,
  direct feed) without his explicit say-so.
- Safety: no install/uninstall/clear-data/delete/reboot on the real
  headset without his say-so; read-only live tests are fine. Never `pm
  disable-user com.oculus.updater`. Never run `ota allow` on the real
  headset.
- When fixing his post draft, fix only the mistakes, do not change his
  wording or structure. Public posts must sound 100% human, plain,
  amateur, not AI-like.
