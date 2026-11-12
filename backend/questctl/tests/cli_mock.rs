//! End-to-end questctl tests against the mock adb script.
//! No headset needed; the mock answers canned ADB output.

use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output};

fn mock_adb() -> PathBuf {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("quest-core")
        .join("tests")
        .join("mock_adb.sh");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755));
    }
    p
}

fn cli(args: &[&str]) -> (i32, Value) {
    let bin = env!("CARGO_BIN_EXE_questctl");
    let out: Output = Command::new(bin)
        .args(["--json"])
        .args(args)
        .env("QUEST_COMPANION_ADB", mock_adb())
        .output()
        .expect("run questctl");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let value: Value =
        serde_json::from_str(&stdout).unwrap_or_else(|_| panic!("not JSON: {stdout}"));
    (out.status.code().unwrap_or(-1), value)
}

fn ok(args: &[&str]) -> Value {
    let (code, v) = cli(args);
    assert_eq!(code, 0, "expected success for {args:?}, got: {v}");
    assert_eq!(v["ok"], true, "expected ok for {args:?}, got: {v}");
    v
}

fn fails(args: &[&str]) -> Value {
    let (code, v) = cli(args);
    assert_ne!(code, 0, "expected failure for {args:?}, got: {v}");
    assert_eq!(v["ok"], false);
    assert!(v["error"].is_string(), "error must be a string: {v}");
    v
}

#[test]
fn devices_list_and_info() {
    let v = ok(&["devices", "list"]);
    let ds = v["devices"].as_array().unwrap();
    assert_eq!(ds.len(), 2);
    assert_eq!(ds[0]["serial"], "TESTSERIAL000001");
    assert_eq!(ds[0]["state"], "device");
    assert_eq!(ds[0]["model"], "Quest 2");
    assert_eq!(ds[0]["transport"], "usb");
    assert_eq!(ds[1]["state"], "unauthorized");
    assert_eq!(ds[1]["transport"], "wifi");

    let info = ok(&["devices", "info", "--serial", "TESTSERIAL000001"]);
    assert_eq!(info["model"], "Quest 2");
    assert_eq!(info["android_version"], "12");
    assert_eq!(info["firmware"], "[redacted firmware]");
    assert_eq!(info["battery"]["level"], 87);
    assert_eq!(info["battery"]["temperature_c"], 28.5);
    assert_eq!(info["storage"]["total_kb"], 256_000_000);
    assert_eq!(info["storage"]["free_kb"], 244_000_000);
    assert_eq!(info["resolution"], "1832x1920");
    assert_eq!(info["density"], 538);
}

#[test]
fn apps_list_install_uninstall_launch() {
    let v = ok(&["apps", "list", "--serial", "TESTSERIAL000001"]);
    let apps = v["apps"].as_array().unwrap();
    assert_eq!(apps.len(), 2);
    let foo = apps.iter().find(|a| a["package"] == "com.example.foo").unwrap();
    assert_eq!(foo["version"], "1.2.3");
    assert_eq!(foo["system"], false);
    let sys = apps.iter().find(|a| a["package"] == "com.android.settings").unwrap();
    assert_eq!(sys["system"], true);
    // --with-icons is cache-only: nothing is cached for these mock
    // packages, so no icon_path appears and nothing is pulled.
    let v = ok(&["apps", "list", "--serial", "TESTSERIAL000001", "--with-icons"]);
    let apps = v["apps"].as_array().unwrap();
    assert!(apps.iter().all(|a| a.get("icon_path").is_none()));

    let dir = tempfile::tempdir().unwrap();
    let apk = dir.path().join("test.apk");
    std::fs::write(&apk, b"fake-apk").unwrap();
    let v = ok(&[
        "apps", "install", "--serial", "TESTSERIAL000001",
        "--apk", apk.to_str().unwrap(),
    ]);
    assert_eq!(v["installed"], true);

    let split = dir.path().join("split.apk");
    std::fs::write(&split, b"fake-split").unwrap();
    ok(&[
        "apps", "install-multiple", "--serial", "TESTSERIAL000001",
        "--apks", &format!("{},{}", apk.display(), split.display()),
    ]);

    ok(&["apps", "uninstall", "--serial", "TESTSERIAL000001", "--package", "com.example.foo"]);
    ok(&["apps", "launch", "--serial", "TESTSERIAL000001", "--package", "com.example.foo"]);
    ok(&["apps", "force-stop", "--serial", "TESTSERIAL000001", "--package", "com.example.foo"]);

    // clear-data refuses without --confirm, works with it.
    let e = fails(&["apps", "clear-data", "--serial", "TESTSERIAL000001", "--package", "com.example.foo"]);
    assert!(e["error"].as_str().unwrap().contains("--confirm"));
    ok(&["apps", "clear-data", "--serial", "TESTSERIAL000001", "--package", "com.example.foo", "--confirm"]);
}

#[test]
fn bundle_apks_install() {
    let dir = tempfile::tempdir().unwrap();
    let bundle = dir.path().join("game.apks");
    let status = Command::new("python3")
        .args([
            "-c",
            "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('base.apk',b'base'); z.writestr('split_config.arm64_v8a.apk',b'split'); z.close()",
            bundle.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(status.success());
    let v = ok(&[
        "apps", "install", "--serial", "TESTSERIAL000001",
        "--apk", bundle.to_str().unwrap(),
    ]);
    assert_eq!(v["installed"], true);
}

#[test]
fn files_list_push_pull() {
    let v = ok(&["files", "list", "--serial", "TESTSERIAL000001", "--path", "/sdcard/"]);
    let entries = v["entries"].as_array().unwrap();
    // 4 entries: 2 month-form lines + 2 ISO-date lines from the mock.
    // The ISO form is what the real Quest prints (live bug 2026-11-12:
    // single-word names vanished, "Open Brush" came back as "Brush").
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0]["is_dir"], true); // dirs sort first
    assert_eq!(entries[0]["name"], "Morrowind");
    assert!(entries.iter().any(|e| e["name"] == "Movies"));
    assert!(entries.iter().any(|e| e["name"] == "Open Brush"));
    let f = entries.iter().find(|e| e["name"] == "test file.txt").unwrap();
    assert_eq!(f["size"], 12345);

    fails(&["files", "list", "--serial", "TESTSERIAL000001", "--path", "/nonexistent"]);

    let dir = tempfile::tempdir().unwrap();
    let local = dir.path().join("up.txt");
    std::fs::write(&local, b"hello").unwrap();
    ok(&[
        "files", "push", "--serial", "TESTSERIAL000001",
        "--local", local.to_str().unwrap(), "--remote", "/sdcard/up.txt",
    ]);
    let down = dir.path().join("down.txt");
    ok(&[
        "files", "pull", "--serial", "TESTSERIAL000001",
        "--remote", "/sdcard/up.txt", "--local", down.to_str().unwrap(),
    ]);
    assert!(std::fs::read_to_string(&down).unwrap().contains("mock-pulled"));
}

#[test]
fn device_screenshot_record_logcat_mirror() {
    let dir = tempfile::tempdir().unwrap();
    let shot = dir.path().join("shot.png");
    ok(&[
        "device", "screenshot", "--serial", "TESTSERIAL000001",
        "--out", shot.to_str().unwrap(),
    ]);
    let bytes = std::fs::read(&shot).unwrap();
    assert_eq!(&bytes[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);

    let rec = dir.path().join("rec.mp4");
    let v = ok(&[
        "device", "record", "--serial", "TESTSERIAL000001",
        "--out", rec.to_str().unwrap(), "--seconds", "5",
    ]);
    assert_eq!(v["seconds"], 5);
    assert!(rec.exists());

    // 200 s clamps to 180 with a note.
    let rec2 = dir.path().join("rec2.mp4");
    let v = ok(&[
        "device", "record", "--serial", "TESTSERIAL000001",
        "--out", rec2.to_str().unwrap(), "--seconds", "200",
    ]);
    assert_eq!(v["seconds"], 180);
    assert!(v["note"].is_string());

    let v = ok(&["device", "logcat", "--serial", "TESTSERIAL000001"]);
    assert!(v["lines"].as_array().unwrap().len() >= 1);

    // Mirror depends on the host: scrcpy is not installed in the VM
    // sandbox (must fail cleanly with a hint), but it IS installed
    // on the main PC (2026-11-12), where this same test runs against
    // the mock adb and scrcpy stays alive long enough to count as
    // launched. Either outcome is a pass, as long as the result is
    // a clean JSON ok:false mentioning scrcpy, or ok:true launched.
    let scrcpy_present = std::path::Path::new("/usr/bin/scrcpy").exists()
        || std::path::Path::new("/usr/local/bin/scrcpy").exists()
        || std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).any(|d| d.join("scrcpy").exists()))
            .unwrap_or(false);
    let (code, v) = cli(&["device", "mirror", "--serial", "TESTSERIAL000001"]);
    if scrcpy_present {
        // Launched against the mock device (scrcpy survives the 900 ms
        // check), or it died right away on a headless host: both are
        // clean, documented outcomes, not a crash.
        if code == 0 {
            assert_eq!(v["launched"], true);
        } else {
            assert!(v["error"].as_str().unwrap().contains("scrcpy"));
        }
    } else {
        assert_ne!(code, 0, "expected failure for mirror, got: {v}");
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().contains("scrcpy"));
    }
}

#[test]
fn settings_and_profiles_and_wifi() {
    let v = ok(&["settings", "get", "--serial", "TESTSERIAL000001", "--key", "screen_brightness"]);
    assert_eq!(v["value"], "128");

    let v = ok(&[
        "settings", "set", "--serial", "TESTSERIAL000001",
        "--key", "debug.oculus.refreshRate", "--value", "90",
    ]);
    assert_eq!(v["value"], "90");
    assert!(v["warning"].is_string());

    // 240 Hz is above the Quest 2 supported max.
    let e = fails(&[
        "settings", "set", "--serial", "TESTSERIAL000001",
        "--key", "debug.oculus.refreshRate", "--value", "240",
    ]);
    assert!(e["error"].as_str().unwrap().contains("240"));

    // Unknown Quest keys are refused.
    fails(&[
        "settings", "set", "--serial", "TESTSERIAL000001",
        "--key", "debug.oculus.notARealKey", "--value", "1",
    ]);

    let v = ok(&["settings", "profile", "list"]);
    let names: Vec<&str> = v["profiles"].as_array().unwrap().iter().map(|n| n.as_str().unwrap()).collect();
    assert!(names.contains(&"balanced"));

    let v = ok(&[
        "settings", "profile", "apply", "--serial", "TESTSERIAL000001",
        "--profile", "balanced",
    ]);
    assert_eq!(v["profile"], "balanced");
    assert!(v["applied"].as_array().unwrap().len() >= 3);

    let v = ok(&["devices", "pair-wifi", "--serial", "TESTSERIAL000001"]);
    assert_eq!(v["ip"], "192.168.1.42");
    assert_eq!(v["port"], 5555);

    let v = ok(&[
        "devices", "connect-wifi", "--ip", "192.168.1.42", "--port", "37281", "--code", "123456",
    ]);
    assert_eq!(v["paired"], true);

    let v = ok(&["devices", "connect-wifi", "--ip", "192.168.1.42", "--port", "5555"]);
    assert_eq!(v["connected"], true);

    // New in the 2026-11-12 integration fix: disconnect-wifi + reboot.
    let v = ok(&["devices", "disconnect-wifi", "--serial", "192.168.1.42:5555"]);
    assert_eq!(v["disconnected"], true);
    let v = ok(&["device", "reboot", "--serial", "TESTSERIAL000001"]);
    assert_eq!(v["rebooted"], true);
}

#[test]
fn files_delete_guards() {
    // Happy path: delete a file under /sdcard/ (mock shell `rm` is a no-op).
    let v = ok(&[
        "files", "delete", "--serial", "TESTSERIAL000001",
        "--remote", "/sdcard/test file.txt",
    ]);
    assert_eq!(v["deleted"], true);

    // Refusals happen before any adb call: outside /sdcard/, /sdcard
    // itself, and paths containing `..`.
    fails(&["files", "delete", "--serial", "TESTSERIAL000001", "--remote", "/data/local/tmp/x"]);
    fails(&["files", "delete", "--serial", "TESTSERIAL000001", "--remote", "/sdcard"]);
    fails(&["files", "delete", "--serial", "TESTSERIAL000001", "--remote", "/sdcard/../etc/passwd"]);
}
