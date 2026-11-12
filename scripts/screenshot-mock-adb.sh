#!/bin/bash
# Screenshot-only fake `adb` for ReOculus. All data is invented:
# fake serials, fake IPs, fake sizes. Nothing here is real.
# Usage: QUEST_COMPANION_ADB=/path/to/screenshot-mock-adb.sh <AppImage>
# It answers the same commands as backend/quest-core/tests/mock_adb.sh,
# but with a full, realistic-looking app list so the Apps screen can be
# photographed without a real headset. Never used by the shipped app.

if [ "$1" = "-s" ]; then shift 2; fi

APPS_F='package:/data/app/~~a1==/com.beatgames.beatsaber-x1==/base.apk=com.beatgames.beatsaber
package:/data/app/~~b2==/com.StressLevelZero.BONELAB-x2==/base.apk=com.StressLevelZero.BONELAB
package:/data/app/~~c3==/com.Icosa.OpenBrush-x3==/base.apk=com.Icosa.OpenBrush
package:/data/app/~~d4==/xyz.morrowind.tes3mpvr-x4==/base.apk=xyz.morrowind.tes3mpvr
package:/data/app/~~e5==/com.teambeef.questzdoom-x5==/base.apk=com.teambeef.questzdoom
package:/data/app/~~f6==/com.itsmattkc.questhomeswitcher-x6==/base.apk=com.itsmattkc.questhomeswitcher
package:/data/app/~~g7==/com.deovr-x7==/base.apk=com.deovr
package:/system/app/Settings/base.apk=com.android.settings
package:/system/app/VrShell/base.apk=com.oculus.vrshell'

APPS_3='package:com.beatgames.beatsaber
package:com.StressLevelZero.BONELAB
package:com.Icosa.OpenBrush
package:xyz.morrowind.tes3mpvr
package:com.teambeef.questzdoom
package:com.itsmattkc.questhomeswitcher
package:com.deovr'

DUMPSYS='  Package [com.beatgames.beatsaber] (1111111):
    versionName=1.40.8
  Package [com.StressLevelZero.BONELAB] (2222222):
    versionName=1.2974.57485
  Package [com.Icosa.OpenBrush] (3333333):
    versionName=2.31.0
  Package [xyz.morrowind.tes3mpvr] (4444444):
    versionName=0.47.0
  Package [com.teambeef.questzdoom] (5555555):
    versionName=1.4.8
  Package [com.itsmattkc.questhomeswitcher] (6666666):
    versionName=1.2.0
  Package [com.deovr] (7777777):
    versionName=1.16
  Package [com.android.settings] (8888888):
    versionName=14
  Package [com.oculus.vrshell] (9999999):
    versionName=14
  Package [org.meumeu.wivrn] (1010101):
    versionName=26.9'

LS_L='-rw-r--r-- 1 system system 1280000000 2026-11-10 09:30 /data/app/~~a1==/com.beatgames.beatsaber-x1==/base.apk
-rw-r--r-- 1 system system 2650000000 2026-11-09 14:12 /data/app/~~b2==/com.StressLevelZero.BONELAB-x2==/base.apk
-rw-r--r-- 1 system system 190000000 2026-11-08 20:01 /data/app/~~c3==/com.Icosa.OpenBrush-x3==/base.apk
-rw-r--r-- 1 system system 514000000 2026-11-07 18:44 /data/app/~~d4==/xyz.morrowind.tes3mpvr-x4==/base.apk
-rw-r--r-- 1 system system 420000000 2026-11-06 11:20 /data/app/~~e5==/com.teambeef.questzdoom-x5==/base.apk
-rw-r--r-- 1 system system 12000000 2026-11-05 08:15 /data/app/~~f6==/com.itsmattkc.questhomeswitcher-x6==/base.apk
-rw-r--r-- 1 system system 48000000 2026-11-04 22:10 /data/app/~~g7==/com.deovr-x7==/base.apk
-rw-r--r-- 1 system system 8200000 2026-01-01 00:00 /system/app/Settings/base.apk
-rw-r--r-- 1 system system 31000000 2026-01-01 00:00 /system/app/VrShell/base.apk'

DU_DATA='1280000000	/data/data/com.beatgames.beatsaber
3950000000	/data/data/com.StressLevelZero.BONELAB
45000000	/data/data/com.Icosa.OpenBrush
470000000	/data/data/xyz.morrowind.tes3mpvr
12000000	/data/data/com.teambeef.questzdoom
8000000	/data/data/com.itsmattkc.questhomeswitcher
15000000	/data/data/com.deovr'

DU_OBB='4100000000	/sdcard/Android/obb/com.StressLevelZero.BONELAB
900000000	/sdcard/Android/obb/com.beatgames.beatsaber'

case "$1" in
  devices)
    echo "List of devices attached"
    echo "TESTSERIAL000001	device product:hollywood model:Quest_2 device:hollywood transport_id:1"
    echo "192.168.1.42:5555	unauthorized product:hollywood model:Quest_3 device:hollywood transport_id:2"
    ;;
  shell)
    shift
    cmd="$*"
    case "$cmd" in
      getprop)
        echo "[ro.product.model]: [Quest 2]"
        echo "[ro.serialno]: [TESTSERIAL000001]"
        echo "[ro.build.version.release]: [14]"
        echo "[ro.build.version.incremental]: [52500000000000000]"
        echo "[ro.product.cpu.abi]: [arm64-v8a]"
        ;;
      "getprop ro.product.model") echo "Quest 2" ;;
      "getprop debug.oculus.refreshRate") echo "90" ;;
      "dumpsys battery")
        echo "Current Battery Service state:"
        echo "  AC powered: false"
        echo "  USB powered: true"
        echo "  status: 3"
        echo "  health: 2"
        echo "  level: 87"
        echo "  temperature: 285"
        echo "  voltage: 4123"
        ;;
      "df /sdcard")
        echo "Filesystem      1K-blocks     Used Available Use% Mounted on"
        echo "/dev/fuse        256000000 87000000 169000000  34% /sdcard"
        ;;
      "wm size") echo "Physical size: 3664x1920" ;;
      "wm density") echo "Physical density: 200" ;;
      "pm list packages -f") printf '%s\n' "$APPS_F" ;;
      "pm list packages -f -3") printf '%s\n' "$APPS_F" | grep -v '/system/app/' ;;
      "pm list packages -3") printf '%s\n' "$APPS_3" ;;
      "pm list packages -f -3"|"pm list packages -3 -f") printf '%s\n' "$APPS_F" | grep -v '/system/app/' ;;
      "dumpsys package packages") printf '%s\n' "$DUMPSYS" ;;
      "dumpsys package org.meumeu.wivrn"|"dumpsys package org.meumeu.wivrn.github"|"dumpsys package org.meumeu.wivrn | grep versionName"|"dumpsys package org.meumeu.wivrn.github | grep versionName")
        echo "versionName=26.9"
        ;;
      "for p in"*) printf '%s\n' "$LS_L" ;;
      "su -c \"du -sb /data/data/*\"") printf '%s\n' "$DU_DATA" ;;
      "du -sb /sdcard/Android/obb/*") printf '%s\n' "$DU_OBB" ;;
      "getevent -l"|"timeout 3 getevent -l")
        echo "add device 1: /dev/input/event2"
        echo "  name:     \"Device 0x96E85D950440DA86\""
        echo "add device 2: /dev/input/event3"
        echo "  name:     \"Device 0x1B08E898EA1F1CEA\""
        ;;
      "ls -la /sdcard/"*)
        echo "total 8"
        echo "drwxrwx--x  5 owner group  4096 Nov 11 12:00 Movies"
        echo "-rw-rw----  1 owner group  12345 Nov 10 09:30 test file.txt"
        echo "drwxrwx---  5 root everybody  3488 2026-11-11 19:39 Morrowind"
        ;;
      "ip route get 1.1.1.1")
        echo "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 0"
        ;;
      "cmd package resolve-activity"*)
        echo "com.example.foo/com.example.foo.MainActivity"
        ;;
      "am start -n"*) echo "Starting: Intent { cmp=com.example.foo/.MainActivity }" ;;
      "monkey -p"*) echo "Events injected: 1" ;;
      "am force-stop"*) : ;;
      "pm clear"*) echo "Success" ;;
      "pm uninstall"*) echo "Success" ;;
      "setprop"*) : ;;
      "settings get"*) echo "128" ;;
      "settings put"*) : ;;
      "screenrecord"*) : ;;
      "rm "*) : ;;
      "logcat"*) : ;;
      *) echo "mock: unhandled shell: $cmd" >&2; exit 1 ;;
    esac
    ;;
  exec-out)
    shift
    if [ "$1" = "screencap" ]; then
      python3 -c "import sys; sys.stdout.buffer.write(bytes([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A])+b'FAKEPNG')"
    else
      echo "mock: unhandled exec-out: $*" >&2; exit 1
    fi
    ;;
  install|install-multiple)
    echo "Performing Streamed Install"
    echo "Success"
    ;;
  uninstall) echo "Success" ;;
  push)
    [ -f "$2" ] || { echo "mock: push source missing: $2" >&2; exit 1; }
    echo "[100%] $2"
    ;;
  pull)
    printf 'mock-pulled:%s' "$2" > "$3"
    echo "[100%] $3"
    ;;
  pair) echo "Successfully paired to $2" ;;
  connect) echo "connected to $2" ;;
  disconnect) echo "disconnected $2" ;;
  reboot) : ;;
  reverse) : ;;
  tcpip) echo "restarting in TCP mode port: $2" ;;
  logcat)
    echo "11-12 05:00:00.000  1234  1234 I Test    hello logcat"
    ;;
  *) echo "mock: unhandled: $*" >&2; exit 1 ;;
esac
exit 0
