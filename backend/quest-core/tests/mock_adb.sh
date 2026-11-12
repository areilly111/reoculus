#!/bin/bash
# Mock `adb` for questctl / quest-core tests. Answers the canned commands
# the tests exercise; anything else exits 1 with "mock: unhandled".
# Usage: QUEST_COMPANION_ADB=/path/to/mock_adb.sh questctl ...

# Strip an optional "-s <serial>" prefix.
if [ "$1" = "-s" ]; then shift 2; fi

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
        echo "[ro.build.version.release]: [12]"
        echo "[ro.build.version.incremental]: [[redacted firmware]]"
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
        echo "/dev/fuse        256000000 12000000 244000000   5% /sdcard"
        ;;
      "wm size") echo "Physical size: 1832x1920" ;;
      "wm density") echo "Physical density: 538" ;;
      "pm list packages -f")
        echo "package:/data/app/com.example.foo/base.apk=com.example.foo"
        echo "package:/system/app/Settings/base.apk=com.android.settings"
        ;;
      "pm list packages -3")
        echo "package:com.example.foo"
        ;;
      "pm list packages -f -3")
        echo "package:/data/app/com.example.foo/base.apk=com.example.foo"
        ;;
      "dumpsys package packages")
        echo "  Package [com.example.foo] (1234567):"
        echo "    versionName=1.2.3"
        echo "  Package [com.android.settings] (7654321):"
        echo "    versionName=12"
        ;;
      "ls -la /sdcard/"*)
        echo "total 8"
        echo "drwxrwx--x  5 owner group  4096 Nov 11 12:00 Movies"
        echo "-rw-rw----  1 owner group  12345 Nov 10 09:30 test file.txt"
        # ISO date form, as the real Quest prints it (live bug 2026-11-12).
        echo "drwxrwx---  5 root everybody  3488 2026-11-11 19:39 Morrowind"
        echo "drwxrwx---  8 root everybody  3488 2026-11-09 20:27 Open Brush"
        ;;
      "ls -la /nonexistent")
        echo "ls: /nonexistent: No such file or directory"
        exit 1
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
      "pm uninstall -k"*) echo "Success" ;;
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
    # push <local> <remote>
    [ -f "$2" ] || { echo "mock: push source missing: $2" >&2; exit 1; }
    echo "[100%] $2"
    ;;
  pull)
    # pull <remote> <local>
    printf 'mock-pulled:%s' "$2" > "$3"
    echo "[100%] $3"
    ;;
  pair) echo "Successfully paired to $2" ;;
  connect) echo "connected to $2" ;;
  disconnect) echo "disconnected $2" ;;
  reboot) : ;;
  tcpip) echo "restarting in TCP mode port: $2" ;;
  logcat)
    # logcat -d -v threadtime
    echo "11-12 05:00:00.000  1234  1234 I Test    hello logcat"
    ;;
  *) echo "mock: unhandled: $*" >&2; exit 1 ;;
esac
exit 0
