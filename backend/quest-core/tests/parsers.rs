//! Unit tests for the pure parsers in quest-core. No device needed.

use quest_core::apps::{
    detect_image_ext, extract_zip_entry, friendly_install_error, parse_badging,
    parse_dumpsys_versions, parse_pm_list, pick_badging_icon, scan_zip_for_icon,
};
use quest_core::devices::{
    parse_battery, parse_df, parse_getprop, parse_wm_density, parse_wm_size,
};
use quest_core::files::parse_ls_line;
use quest_core::transport::{parse_devices_output, DeviceState};

#[test]
fn devices_list_parses_states_and_models() {
    let text = "List of devices attached\n\
        TESTSERIAL000001\tdevice product:hollywood model:Quest_2 device:hollywood transport_id:1\n\
        192.168.1.42:5555\tunauthorized product:hollywood model:Quest_3 device:hollywood\n\
        ABC123\tno permissions\n\
        \n\
        * daemon started successfully *\n";
    let ds = parse_devices_output(text);
    assert_eq!(ds.len(), 3);
    assert_eq!(ds[0].serial, "TESTSERIAL000001");
    assert_eq!(ds[0].state, DeviceState::Device);
    assert_eq!(ds[0].model.as_deref(), Some("Quest 2"));
    assert_eq!(ds[0].transport, "usb");
    assert_eq!(ds[1].state, DeviceState::Unauthorized);
    assert_eq!(ds[1].transport, "wifi");
    assert_eq!(ds[2].state, DeviceState::NoPermissions);
}

#[test]
fn getprop_and_battery_and_df() {
    let props = parse_getprop("[ro.product.model]: [Quest 2]\n[ro.build.version.release]: [12]\n");
    assert_eq!(props.get("ro.product.model").map(|s| s.as_str()), Some("Quest 2"));
    let b = parse_battery("level: 87\nhealth: 2\ntemperature: 285\nvoltage: 4123\nstatus: 3\n");
    assert_eq!(b.level, Some(87));
    assert_eq!(b.health.as_deref(), Some("good"));
    assert_eq!(b.temperature_c, Some(28.5));
    assert_eq!(b.status.as_deref(), Some("discharging"));
    let s = parse_df("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/fuse 256000000 12000000 244000000 5% /sdcard\n");
    assert_eq!(s.total_kb, Some(256_000_000));
    assert_eq!(s.free_kb, Some(244_000_000));
    assert_eq!(parse_wm_size("Physical size: 1832x1920\n"), Some("1832x1920".into()));
    assert_eq!(parse_wm_density("Physical density: 538\n"), Some(538));
}

#[test]
fn pm_list_and_dumpsys_versions() {
    let list = parse_pm_list(
        "package:/data/app/com.example.foo/base.apk=com.example.foo\npackage:com.other.bar\n",
    );
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].0, "com.example.foo");
    assert_eq!(
        list[0].1.as_deref(),
        Some("/data/app/com.example.foo/base.apk")
    );
    let vers = parse_dumpsys_versions(
        "  Package [com.example.foo] (1):\n    versionName=1.2.3\n  Package [com.other.bar] (2):\n    versionName=4.5\n",
    );
    assert_eq!(vers.get("com.example.foo").map(|s| s.as_str()), Some("1.2.3"));
    assert_eq!(friendly_install_error("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n"), "INSTALL_FAILED_VERSION_DOWNGRADE (the installed version is newer)");
    assert!(friendly_install_error("Failure [INSTALL_FAILED_INVALID_APK]\n").contains("split APK"));
}

#[test]
fn badging_parsing() {
    // OpenBrush, live 2026-11-12: obfuscated icon file names, real label.
    let openbrush = "package: name='com.Icosa.OpenBrush' versionCode='20310001' versionName='2.31.0' platformBuildVersionName='14'\n\
        application-label:'Open Brush'\n\
        application-icon-120:'res/Ut.png'\n\
        application-icon-480:'res/Iw.png'\n\
        application-icon-640:'res/oj.png'\n";
    let b = parse_badging(openbrush);
    assert_eq!(b.label.as_deref(), Some("Open Brush"));
    assert_eq!(b.version.as_deref(), Some("2.31.0"));
    assert_eq!(b.icons.len(), 3);
    assert_eq!(pick_badging_icon(&b.icons).as_deref(), Some("res/oj.png"));
    // BONELAB: mipmap icons, highest density wins.
    let bonelab = "package: name='com.StressLevelZero.BONELAB' versionName='1.2974.57485'\n\
        application-label:'BONELAB'\n\
        application-icon-120:'res/mipmap-ldpi/app_icon.png'\n\
        application-icon-640:'res/mipmap-xxxhdpi/app_icon.png'\n";
    let b2 = parse_badging(bonelab);
    assert_eq!(b2.label.as_deref(), Some("BONELAB"));
    assert_eq!(
        pick_badging_icon(&b2.icons).as_deref(),
        Some("res/mipmap-xxxhdpi/app_icon.png")
    );
    // VrShell: label, but icon='' — no raster icon to pick.
    let vrshell = "application: label='Meta Horizon Shell' icon=''\n\
        launchable-activity: name='com.oculus.vrshell.HomeActivity'  label='' icon=''\n";
    let b3 = parse_badging(vrshell);
    assert_eq!(b3.label.as_deref(), Some("Meta Horizon Shell"));
    assert!(pick_badging_icon(&b3.icons).is_none());
    // Adaptive (XML) icons are skipped, not returned.
    let adaptive = "application-label:'Foo'\n\
        application-icon-640:'res/mipmap-xxxhdpi/ic_launcher.xml'\n\
        application-icon-480:'res/mipmap-xxhdpi/ic_launcher.png'\n";
    let b4 = parse_badging(adaptive);
    assert_eq!(
        pick_badging_icon(&b4.icons).as_deref(),
        Some("res/mipmap-xxhdpi/ic_launcher.png")
    );
    // Locale labels are ignored in favour of the plain one.
    let locale = "application-label:'Real Name'\n\
        application-label-af:'Real Name'\n\
        application-label-ar:'Real Name'\n";
    assert_eq!(parse_badging(locale).label.as_deref(), Some("Real Name"));
}

fn fake_apk_zip() -> (tempfile::TempDir, std::path::PathBuf) {
    // A tiny APK-shaped zip: a Beat Saber-style mipmap icon set plus
    // an unrelated file. Written with the zip crate, read back by the
    // same code the icon path uses.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fake.apk");
    let file = std::fs::File::create(&path).unwrap();
    let mut w = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored);
    let png: Vec<u8> = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
    for (name, data) in [
        ("res/mipmap-mdpi/app_icon.png", png.clone()),
        ("res/mipmap-xxxhdpi/app_icon.png", png.clone()),
        ("res/mipmap-xxxhdpi/app_icon_round.png", png.clone()),
        ("AndroidManifest.xml", b"<manifest/>".to_vec()),
    ] {
        w.start_file(name, opts).unwrap();
        use std::io::Write;
        w.write_all(&data).unwrap();
    }
    w.finish().unwrap();
    (dir, path)
}

#[test]
fn zip_icon_scan_and_extract() {
    let (_dir, apk) = fake_apk_zip();
    let file = std::fs::File::open(&apk).unwrap();
    let mut zip = zip::ZipArchive::new(file).unwrap();
    // Highest density, non-round wins (Beat Saber fallback path).
    assert_eq!(
        scan_zip_for_icon(&mut zip).as_deref(),
        Some("res/mipmap-xxxhdpi/app_icon.png")
    );
    let (bytes, ext) = extract_zip_entry(&apk, "res/mipmap-xxxhdpi/app_icon.png").unwrap();
    assert_eq!(ext, "png");
    assert_eq!(&bytes[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
    assert_eq!(detect_image_ext(&bytes, "x.png"), "png");
    assert!(extract_zip_entry(&apk, "res/nope.png").is_err());
    // WebP magic is recognised (kept as .webp, not converted).
    let webp: Vec<u8> = b"RIFF\x10\x00\x00\x00WEBPVP8 ".to_vec();
    assert_eq!(detect_image_ext(&webp, "x.webp"), "webp");
}

#[test]
fn ls_line_parsing() {
    let dir = parse_ls_line("drwxrwx--x  5 owner group  4096 Nov 11 12:00 Movies").unwrap();
    assert!(dir.is_dir);
    assert_eq!(dir.name, "Movies");
    assert_eq!(dir.size, 4096);
    let file = parse_ls_line("-rw-rw----  1 owner group  12345 Nov 10 09:30 test file.txt").unwrap();
    assert!(!file.is_dir);
    assert_eq!(file.name, "test file.txt");
    assert_eq!(file.size, 12345);
    // ISO date form, as the real Quest `ls` prints it (live bug 2026-11-12):
    // single-word names must survive, and multi-word names must not
    // lose their first word ("Open Brush" was coming back as "Brush").
    let iso = parse_ls_line("drwxrwx---  5 root everybody  3488 2026-11-11 19:39 Morrowind").unwrap();
    assert!(iso.is_dir);
    assert_eq!(iso.name, "Morrowind");
    assert_eq!(iso.modified, "2026-11-11 19:39");
    let iso_spaced = parse_ls_line("drwxrwx---  8 root everybody  3488 2026-11-09 20:27 Open Brush").unwrap();
    assert_eq!(iso_spaced.name, "Open Brush");
    let iso_file = parse_ls_line("-rw-rw----  1 root everybody  264 2026-11-01 23:02 boot_config.json").unwrap();
    assert_eq!(iso_file.name, "boot_config.json");
    assert_eq!(iso_file.size, 264);
    assert!(parse_ls_line("total 8").is_none());
    assert!(parse_ls_line("").is_none());
}

use quest_core::apk_analyzer::parse_apksigner_certs;
use quest_core::health::{format_uptime, parse_uptime};
use quest_core::homes::{is_home_component, parse_query_activities, parse_resolve_activity};
use quest_core::singularity::pick_release_assets;

#[test]
fn homes_parsing() {
    let comps = parse_query_activities(
        "com.oculus.home/.HomeActivity\ncom.itsmattkc.questhomeswitcher/.MainActivity\n",
    );
    assert_eq!(comps.len(), 2);
    assert_eq!(comps[1], "com.itsmattkc.questhomeswitcher/.MainActivity");
    assert_eq!(
        parse_resolve_activity("com.oculus.home/.HomeActivity\n"),
        Some("com.oculus.home/.HomeActivity".to_string())
    );
    assert_eq!(parse_resolve_activity(""), None);
    // The system UI panels that answer the HOME intent are not
    // homes, and neither is any dialog activity.
    assert!(is_home_component("com.oculus.vrshell/.HomeActivity"));
    assert!(is_home_component("com.threethan.launcher/com.threethan.LightningLauncher"));
    assert!(is_home_component("com.android.settings/.FallbackHome"));
    assert!(!is_home_component(
        "com.oculus.systemux/com.oculus.panelapp.library.LibraryActivity"
    ));
    assert!(!is_home_component(
        "com.oculus.systemux/com.oculus.panelapp.library.ShortcutCreationDialogActivity"
    ));
    assert!(!is_home_component("com.foo/.SomeDialogActivity"));
}

#[test]
fn health_uptime() {
    assert_eq!(parse_uptime("123456.78 98765.43\n"), Some(123456));
    assert_eq!(format_uptime(90061), "1 day 1 hour");
    assert_eq!(format_uptime(45), "45 seconds");
}

#[test]
fn singularity_release_picking() {
    let text = r#"{"tag_name":"v1.0.8","assets":[
        {"name":"Singularity-v1.0.8.apk","browser_download_url":"https://example.com/s.apk"},
        {"name":"checksums.sha256","browser_download_url":"https://example.com/c.txt"}
    ]}"#;
    let (version, pair, checksum) = pick_release_assets(text).unwrap();
    assert_eq!(version, "v1.0.8");
    assert!(pair.contains("Singularity-v1.0.8.apk"));
    assert_eq!(checksum.as_deref(), Some("https://example.com/c.txt"));
}

#[test]
fn badging_extended_fields() {
    let text = "package: name='com.example.foo' versionCode='42' versionName='1.2.3' platformBuildVersionCode='33'\n\
        sdkVersion:'21'\ntargetSdkVersion:'33'\nuses-permission: name='android.permission.INTERNET'\n\
        uses-permission: name='android.permission.INTERNET'\nuses-feature: name='android.hardware.vr.headtracking'\n\
        native-code: 'arm64-v8a' 'armeabi-v7a'\napplication-label:'Example Foo'\n";
    let b = parse_badging(text);
    assert_eq!(b.package.as_deref(), Some("com.example.foo"));
    assert_eq!(b.version.as_deref(), Some("1.2.3"));
    assert_eq!(b.version_code, Some(42));
    assert_eq!(b.sdk_version, Some(21));
    assert_eq!(b.target_sdk, Some(33));
    assert_eq!(b.permissions, vec!["android.permission.INTERNET"]);
    assert_eq!(b.features, vec!["android.hardware.vr.headtracking"]);
    assert_eq!(b.native_code, vec!["arm64-v8a", "armeabi-v7a"]);
}

#[test]
fn apksigner_certs_parsing() {
    let text = "Verifies\nSigner #1 certificate SHA-256 digest: ab12cd34\n";
    assert_eq!(parse_apksigner_certs(text).as_deref(), Some("ab12cd34"));
    assert_eq!(parse_apksigner_certs("no signer here\n"), None);
}
