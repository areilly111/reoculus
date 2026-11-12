#!/bin/bash
# Mock `adb` for questctl / quest-core tests. Answers the canned commands
# the tests exercise; anything else exits 1 with "mock: unhandled".
# Usage: QUEST_COMPANION_ADB=/path/to/mock_adb.sh questctl ...

# Strip an optional "-s <serial>" prefix.
if [ "$1" = "-s" ]; then shift 2; fi

# Stateful mock state (settings puts/deletes, hosts module, frida).
# One file per key, so parallel tests using different keys do not
# race. Tests clean their own key file before starting.
STATE_DIR="/tmp/questcompanion-mock-state"
state_get() { # $1=key $2=default
  local f="$STATE_DIR/settings_$1"
  if [ -f "$f" ]; then cat "$f"; else printf '%s\n' "$2"; fi
}
state_put() { # $1=key $2=value
  mkdir -p "$STATE_DIR"; printf '%s' "$2" > "$STATE_DIR/settings_$1"
}
state_del() { # $1=key
  rm -f "$STATE_DIR/settings_$1"
}

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
      "pm resolve-activity --brief"*)
        echo "com.example.home/com.example.home.HomeActivity"
        ;;
      "pm query-activities --components"*)
        echo "com.example.home/com.example.home.HomeActivity"
        echo "com.example.other/com.example.other.MainActivity"
        ;;
      "cmd package set-home-activity"*) : ;;
      "am start -a android.settings.HOME_SETTINGS") echo "Starting: Intent { act=android.settings.HOME_SETTINGS }" ;;
      "am start -a android.settings."*) echo "Starting: Intent { act=$cmd }" ;;
      "cat /proc/uptime") echo "123456.78 98765.43" ;;
      "df /data")
        echo "Filesystem      1K-blocks     Used Available Use% Mounted on"
        echo "/dev/block/dm-3   256000000 80000000 176000000  32% /data"
        ;;
      "am start -n"*) echo "Starting: Intent { cmp=com.example.foo/.MainActivity }" ;;
      "monkey -p"*) echo "Events injected: 1" ;;
      "am force-stop"*) : ;;
      "pm clear"*) echo "Success" ;;
      "pm uninstall"*) echo "Success" ;;
      "pm uninstall -k"*) echo "Success" ;;
      "setprop"*) : ;;
      "settings get global ota_download_url") state_get ota_download_url "null" ;;
      "settings get global ota_update_server_url") state_get ota_update_server_url "null" ;;
      "settings get global uxpatcher_battery_percent") state_get uxpatcher_battery_percent "1" ;;
      "settings get global uxpatcher_hide_passthrough") state_get uxpatcher_hide_passthrough "0" ;;
      "settings get global uxpatcher_hide_profile") state_get uxpatcher_hide_profile "0" ;;
      "settings get global uxpatcher_hide_battery_icon") state_get uxpatcher_hide_battery_icon "0" ;;
      "settings get global uxpatcher_hide_notif_badge") state_get uxpatcher_hide_notif_badge "0" ;;
      "settings get global uxpatcher_dock_library_first") state_get uxpatcher_dock_library_first "0" ;;
      "settings get global uxpatcher_dock_apps_left") state_get uxpatcher_dock_apps_left "0" ;;
      "settings get global uxpatcher_bg_enabled") state_get uxpatcher_bg_enabled "1" ;;
      "settings get global uxpatcher_dock_order") state_get uxpatcher_dock_order "profile,qs,notif,pt" ;;
      "settings get global uxpatcher_accent_color") state_get uxpatcher_accent_color "off" ;;
      "settings get global uxpatcher_text_color") state_get uxpatcher_text_color "off" ;;
      "settings get global uxpatcher_bg_color") state_get uxpatcher_bg_color "0" ;;
      "settings get global uxpatcher_pin_limit") state_get uxpatcher_pin_limit "1" ;;
      "settings get global uxpatcher_gamepad_unlock") state_get uxpatcher_gamepad_unlock "0" ;;
      "settings get global uxpatcher_unknown_tab") state_get uxpatcher_unknown_tab "1" ;;
      "settings put global"*) state_put "$(echo "$cmd" | awk '{print $4}')" "$(echo "$cmd" | awk '{print $5}')" ;;
      "settings delete global"*) state_del "$(echo "$cmd" | awk '{print $4}')" ;;
      "settings get"*) echo "128" ;;
      "settings put"*) : ;;
      "pm list packages -d")
        echo "package:com.meta.credentialsmanager"
        echo "package:com.oculus.updater"
        ;;
      "dumpsys package com.lumi.singularity")
        echo "  Package [com.lumi.singularity] (1):"
        echo "    versionName=1.0.8"
        ;;
      "dumpsys package com.singularity.magisk")
        echo "  Package [com.singularity.magisk] (1):"
        echo "    versionName=1db2ceaf"
        ;;
      "wc -l /system/etc/hosts") echo "2 /system/etc/hosts" ;;
      "test -f /data/local/tmp/frida-server"*)
        if [ -f "$STATE_DIR/frida_pushed" ]; then echo "yes"; else echo "no"; fi ;;
      "pidof frida-server")
        if [ -f "$STATE_DIR/frida_running" ]; then echo "1234"; fi ;;
      "su -c \"test -f /data/adb/modules/hosts/system/etc/hosts"*)
        if [ -f "$STATE_DIR/hosts_applied" ]; then echo "yes"; else echo "no"; fi ;;
      "su -c \"grep -c 0.0.0.0 /data/adb/modules/hosts/system/etc/hosts"*)
        if [ -f "$STATE_DIR/hosts_applied" ]; then echo "74"; else echo "0"; fi ;;
      "su -c \"mkdir -p /data/adb/modules/hosts/system/etc"*)
        mkdir -p "$STATE_DIR"; touch "$STATE_DIR/hosts_applied" ;;
      "su -c \"rm -f /data/adb/modules/hosts/system/etc/hosts\"")
        rm -f "$STATE_DIR/hosts_applied" ;;
      "su -c \"nohup /data/local/tmp/frida-server"*)
        mkdir -p "$STATE_DIR"; touch "$STATE_DIR/frida_running" ;;
      "su -c \"pkill -x frida-server\"")
        rm -f "$STATE_DIR/frida_running" ;;
      "chmod 755 /data/local/tmp/frida-server") : ;;
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
    if [ "$3" = "/data/local/tmp/frida-server" ]; then
      mkdir -p "$STATE_DIR"; touch "$STATE_DIR/frida_pushed"
    fi
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
