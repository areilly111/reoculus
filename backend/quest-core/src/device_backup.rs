//! Full device backup and restore. One folder on this computer
//! holding everything needed to get a Quest 2 back to how it was:
//! settings, Guardian data, Wi-Fi configs, and an inventory of the
//! installed apps with references to their library backups.
//!
//! What it is NOT: it does not re-pull every APK (that would copy
//! tens of gigabytes on every run). Apps and saves are backed up
//! separately from Apps (Backup app / Backup save) and live in the
//! same library folder; the device backup records which library
//! backup each app has, and `device restore` reinstalls from those.
//! The manifest says exactly this, so nobody mistakes the device
//! backup for a full disk image.
//!
//! Restore is dry-run first, and a real restore needs --confirm.
//! Settings restore is per-key with failures recorded (some
//! settings refuse to change); Guardian / Wi-Fi restore needs
//! root. Nothing here touches the bootloader or flashes anything.

use crate::apps::list_apps;
use crate::backup::{
    backup_root, folder_stamp, format_unix_time, now_unix, read_manifest, restore_backup,
    ManifestStep,
};
use crate::devices::device_info;
use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::fs::File;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceAppRef {
    pub package: String,
    pub label: String,
    pub version: String,
    /// Library backup folder for this app, when one exists.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub library_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceManifest {
    pub kind: String,
    pub serial: String,
    pub model: Option<String>,
    pub android_version: Option<String>,
    pub firmware: Option<String>,
    pub backup_date: String,
    /// Apps installed at backup time, with library references.
    pub apps: Vec<DeviceAppRef>,
    /// Files inside this folder with SHA-256 (settings dumps,
    /// tarballs). Paths relative to the folder.
    pub files: Vec<crate::backup::ManifestFile>,
    pub steps: Vec<ManifestStep>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceBackupReport {
    pub serial: String,
    pub path: String,
    pub backup_date: String,
    pub total_size_bytes: u64,
    pub ready: bool,
    pub steps: Vec<ManifestStep>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceRestoreReport {
    pub serial: String,
    pub dry_run: bool,
    pub backup_path: String,
    pub ready: bool,
    pub steps: Vec<ManifestStep>,
}

fn dir_size(path: &Path) -> u64 {
    fn walk(p: &Path, acc: &mut u64) {
        if let Ok(rd) = std::fs::read_dir(p) {
            for e in rd.flatten() {
                let ep = e.path();
                if ep.is_dir() {
                    walk(&ep, acc);
                } else if let Ok(m) = e.metadata() {
                    *acc += m.len();
                }
            }
        }
    }
    let mut total = 0;
    walk(path, &mut total);
    total
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut f = File::open(path)?;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// Library backup folders, keyed by package, newest first.
fn library_by_package() -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    if let Ok(root) = backup_root() {
        if let Ok(rd) = std::fs::read_dir(&root) {
            let mut dirs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            dirs.sort();
            for dir in dirs {
                if let Ok(m) = read_manifest(&dir) {
                    // Newest wins: dirs sort oldest-first by name stamp.
                    map.insert(m.package, dir.to_string_lossy().into_owned());
                }
            }
        }
    }
    map
}

pub fn device_backup(
    t: &dyn AdbTransport,
    serial: &str,
    out_dir: Option<&Path>,
) -> Result<DeviceBackupReport> {
    let target = Target::serial(serial);
    let root = match out_dir {
        Some(d) => d.to_path_buf(),
        None => backup_root()?,
    };
    let folder = root.join(format!(
        "{}-device-{}",
        sanitize(serial),
        folder_stamp(now_unix())
    ));
    std::fs::create_dir_all(&folder)?;
    let info = device_info(t, serial).unwrap_or_else(|_| crate::devices::DeviceInfo {
        serial: serial.to_string(),
        model: None,
        android_version: None,
        firmware: None,
        cpu_abi: None,
        battery: crate::devices::BatteryInfo {
            level: None,
            health: None,
            temperature_c: None,
            voltage_mv: None,
            status: None,
            plugged: None,
        },
        storage: crate::devices::StorageInfo {
            total_kb: None,
            used_kb: None,
            free_kb: None,
            mount: "/sdcard".into(),
        },
        resolution: None,
        density: None,
    });
    let mut steps: Vec<ManifestStep> = Vec::new();
    let mut files: Vec<crate::backup::ManifestFile> = Vec::new();
    let record_file = |path: &Path, display: &str, steps: &mut Vec<ManifestStep>, files: &mut Vec<crate::backup::ManifestFile>| {
        if path.is_file() {
            match sha256_file(path) {
                Ok(hash) => {
                    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
                    files.push(crate::backup::ManifestFile {
                        name: display.to_string(),
                        size_bytes: size,
                        sha256: hash,
                    });
                }
                Err(e) => steps.push(ManifestStep {
                    item: display.to_string(),
                    ok: false,
                    message: format!("written but could not hash: {e}"),
                }),
            }
        }
    };
    // 1. Settings dumps + device info (plain text, readable by hand).
    for (table, name) in [
        ("global", "settings-global.txt"),
        ("secure", "settings-secure.txt"),
        ("system", "settings-system.txt"),
    ] {
        match t.shell(&target, &format!("settings list {table}")) {
            Ok(o) => {
                let _ = std::fs::write(folder.join(name), &o.stdout);
                steps.push(ManifestStep {
                    item: format!("Settings ({table})"),
                    ok: true,
                    message: format!("{} bytes", o.stdout.len()),
                });
            }
            Err(e) => steps.push(ManifestStep {
                item: format!("Settings ({table})"),
                ok: false,
                message: format!("settings list failed: {e}"),
            }),
        }
        record_file(&folder.join(name), name, &mut steps, &mut files);
    }
    match t.shell(&target, "getprop") {
        Ok(o) => {
            let _ = std::fs::write(folder.join("getprop.txt"), &o.stdout);
            steps.push(ManifestStep {
                item: "Properties (getprop)".to_string(),
                ok: true,
                message: format!("{} bytes", o.stdout.len()),
            });
        }
        Err(e) => steps.push(ManifestStep {
            item: "Properties (getprop)".to_string(),
            ok: false,
            message: format!("getprop failed: {e}"),
        }),
    }
    record_file(&folder.join("getprop.txt"), "getprop.txt", &mut steps, &mut files);
    let _ = std::fs::write(
        folder.join("device-info.json"),
        serde_json::to_string_pretty(&info).unwrap_or_default(),
    );
    record_file(&folder.join("device-info.json"), "device-info.json", &mut steps, &mut files);
    // 2. Guardian data (root only, on-device tar) and Wi-Fi
    // configs (root only, known config files copied out: tar
    // chokes on the socket files in /data/misc/wifi/sockets).
    let tmp = "/sdcard/.quest-companion-tmp";
    // Guardian: tarball, as before.
    let guardian_tar = format!("{tmp}/guardian.tar.gz");
    match t.shell(&target, &format!(
        "su -c \"mkdir -p {tmp} && tar -czf {guardian_tar} -C /data/data com.oculus.guardian\""
    )) {
        Ok(o) if o.code == 0 => {
            let local = folder.join("guardian.tar.gz");
            match t.pull(&target, &guardian_tar, &local) {
                Ok(()) => {
                    let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                    if size == 0 {
                        let _ = std::fs::remove_file(&local);
                        steps.push(ManifestStep {
                            item: "Guardian data".to_string(),
                            ok: false,
                            message: "tarball came back empty (nothing readable there)".to_string(),
                        });
                    } else {
                        steps.push(ManifestStep {
                            item: "Guardian data".to_string(),
                            ok: true,
                            message: format!("backed up {size} bytes (needs root to restore)"),
                        });
                        record_file(&local, "guardian.tar.gz", &mut steps, &mut files);
                    }
                }
                Err(e) => steps.push(ManifestStep {
                    item: "Guardian data".to_string(),
                    ok: false,
                    message: format!("could not pull the tarball: {e}"),
                }),
            }
            let _ = t.shell(&target, &format!("rm -f {guardian_tar}"));
        }
        _ => steps.push(ManifestStep {
            item: "Guardian data".to_string(),
            ok: false,
            message: "needs root: the on-device tar failed".to_string(),
        }),
    }
    // Wi-Fi: the saved-network configs, copied file by file.
    // /data/vendor/wifi/wpa/*.conf holds the networks on this
    // build; WifiConfigStore.xml lives in apexdata on newer
    // Android and is copied when present. Socket files are not
    // configs and are skipped by copying files, not dirs.
    let wifi_files: [(&str, &str); 3] = [
        ("/data/vendor/wifi/wpa/wpa_supplicant.conf", "wpa_supplicant.conf"),
        ("/data/vendor/wifi/wpa/p2p_supplicant.conf", "p2p_supplicant.conf"),
        ("/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml", "WifiConfigStore.xml"),
    ];
    let _ = std::fs::create_dir_all(folder.join("wifi"));
    let mut wifi_ok = 0;
    for (remote, name) in wifi_files {
        let staged = format!("{tmp}/wifi-{name}");
        let pulled = match t.shell(&target, &format!("su -c \"cp {remote} {staged} 2>/dev/null\"")) {
            Ok(_) => t.pull(&target, &staged, &folder.join("wifi").join(name)).is_ok(),
            Err(_) => false,
        };
        let _ = t.shell(&target, &format!("rm -f {staged}"));
        if pulled {
            wifi_ok += 1;
            record_file(&folder.join("wifi").join(name), &format!("wifi/{name}"), &mut steps, &mut files);
        }
    }
    steps.push(ManifestStep {
        item: "Wi-Fi configs".to_string(),
        ok: wifi_ok > 0,
        message: if wifi_ok > 0 {
            format!("backed up {wifi_ok} config file(s) (needs root to restore)")
        } else {
            "no Wi-Fi config files were readable (needs root; the files may live elsewhere on this build)".to_string()
        },
    });
    // 3. App inventory with library references (no APKs copied here).
    let library = library_by_package();
    let mut app_refs: Vec<DeviceAppRef> = Vec::new();
    match list_apps(t, serial, false) {
        Ok(apps) => {
            for a in apps {
                app_refs.push(DeviceAppRef {
                    package: a.package.clone(),
                    label: a.label,
                    version: a.version,
                    library_path: library.get(&a.package).cloned(),
                });
            }
            let with_lib = app_refs.iter().filter(|a| a.library_path.is_some()).count();
            steps.push(ManifestStep {
                item: "App inventory".to_string(),
                ok: true,
                message: format!(
                    "{} apps installed, {} have a library backup (APKs are not copied into device backups)",
                    app_refs.len(),
                    with_lib
                ),
            });
        }
        Err(e) => steps.push(ManifestStep {
            item: "App inventory".to_string(),
            ok: false,
            message: format!("app list failed: {e}"),
        }),
    }
    let date = format_unix_time(now_unix());
    let manifest = DeviceManifest {
        kind: "device".to_string(),
        serial: serial.to_string(),
        model: info.model.clone(),
        android_version: info.android_version.clone(),
        firmware: info.firmware.clone(),
        backup_date: date.clone(),
        apps: app_refs,
        files,
        steps: steps.clone(),
    };
    std::fs::write(
        folder.join("manifest.json"),
        serde_json::to_string_pretty(&manifest)
            .map_err(|e| Error(format!("cannot write manifest: {e}")))?,
    )?;
    let total = dir_size(&folder);
    Ok(DeviceBackupReport {
        serial: serial.to_string(),
        path: folder.to_string_lossy().into_owned(),
        backup_date: date,
        total_size_bytes: total,
        ready: true,
        steps,
    })
}

pub fn read_device_manifest(dir: &Path) -> Result<DeviceManifest> {
    let text = std::fs::read_to_string(dir.join("manifest.json")).map_err(|e| {
        Error(format!("{} is not a device backup folder (no manifest.json: {e})", dir.display()))
    })?;
    serde_json::from_str(&text)
        .map_err(|e| Error(format!("manifest.json in {} is invalid: {e}", dir.display())))
}

/// List device backups in the library root (folders whose manifest
/// has kind "device"), newest first.
pub fn list_device_backups() -> Result<Vec<DeviceBackupEntry>> {
    let root = backup_root()?;
    let mut out: Vec<DeviceBackupEntry> = Vec::new();
    if root.is_dir() {
        if let Ok(rd) = std::fs::read_dir(&root) {
            for e in rd.flatten() {
                let dir = e.path();
                if !dir.is_dir() {
                    continue;
                }
                if let Ok(m) = read_device_manifest(&dir) {
                    if m.kind == "device" {
                        out.push(DeviceBackupEntry {
                            serial: m.serial,
                            backup_date: m.backup_date,
                            path: dir.to_string_lossy().into_owned(),
                            total_size_bytes: dir_size(&dir),
                            app_count: m.apps.len(),
                        });
                    }
                }
            }
        }
    }
    out.sort_by(|a, b| b.backup_date.cmp(&a.backup_date));
    Ok(out)
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceBackupEntry {
    pub serial: String,
    pub backup_date: String,
    pub path: String,
    pub total_size_bytes: u64,
    pub app_count: usize,
}

/// Restore a device backup. Dry-run first: it lists the settings
/// keys it would put, the tarballs it would unpack, and the apps it
/// would reinstall from the library. A real restore needs
/// --confirm. Settings are applied per key (failures recorded);
/// tarballs need root; apps reinstall from their library backups
/// (APKs only, never app data, unless --include-data).
pub fn device_restore(
    t: &dyn AdbTransport,
    serial: &str,
    backup_dir: &Path,
    include_apps: bool,
    include_data: bool,
    dry_run: bool,
    confirm: bool,
) -> Result<DeviceRestoreReport> {
    if !dry_run && !confirm {
        return Err(Error(
            "restoring a device backup overwrites settings, Guardian, Wi-Fi and apps. Re-run with --confirm to proceed.".into(),
        ));
    }
    let manifest = read_device_manifest(backup_dir)?;
    if manifest.kind != "device" {
        return Err(Error(format!(
            "{} is not a device backup (manifest kind is {})",
            backup_dir.display(),
            manifest.kind
        )));
    }
    // Verify hashes of the files in the folder.
    let mut problems = Vec::new();
    for f in &manifest.files {
        match sha256_file(&backup_dir.join(&f.name)) {
            Ok(h) if h == f.sha256 => {}
            Ok(_) => problems.push(format!("{}: hash mismatch", f.name)),
            Err(e) => problems.push(format!("{}: cannot read: {e}", f.name)),
        }
    }
    if !problems.is_empty() {
        return Err(Error(format!(
            "device backup is damaged, refusing to restore: {}",
            problems.join("; ")
        )));
    }
    let target = Target::serial(serial);
    let mut steps: Vec<ManifestStep> = Vec::new();
    // 1. Settings: put each key back (per-key, failures recorded).
    for (table, name) in [
        ("global", "settings-global.txt"),
        ("secure", "settings-secure.txt"),
        ("system", "settings-system.txt"),
    ] {
        let path = backup_dir.join(name);
        let Ok(text) = std::fs::read_to_string(&path) else {
            steps.push(ManifestStep {
                item: format!("Settings ({table})"),
                ok: true,
                message: "no dump in this backup".to_string(),
            });
            continue;
        };
        // `settings list` prints `key=value` lines; values may
        // contain `=`, so split on the first one. Skip blank lines
        // and lines that are not key=value.
        let pairs: Vec<(String, String)> = text
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, v)| (k.trim().to_string(), v.to_string())))
            .filter(|(k, _)| !k.is_empty() && !k.contains(' '))
            .collect();
        if dry_run {
            steps.push(ManifestStep {
                item: format!("Settings ({table})"),
                ok: true,
                message: format!("would restore {} setting(s)", pairs.len()),
            });
            continue;
        }
        let mut ok_count = 0;
        let mut fail_count = 0;
        for (k, v) in &pairs {
            // Quote the value for the shell: single-quote it, escape
            // embedded single quotes the shell way.
            let safe = v.replace('\'', "'\\''");
            match t.shell(&target, &format!("settings put {table} {k} '{safe}'")) {
                Ok(o) if o.code == 0 => ok_count += 1,
                _ => fail_count += 1,
            }
        }
        steps.push(ManifestStep {
            item: format!("Settings ({table})"),
            ok: fail_count == 0,
            message: format!("restored {ok_count} setting(s), {fail_count} refused"),
        });
    }
    // 2a. Guardian tarball (root only).
    {
        let local = backup_dir.join("guardian.tar.gz");
        if !local.is_file() {
            steps.push(ManifestStep {
                item: "Guardian data".to_string(),
                ok: true,
                message: "not in this backup".to_string(),
            });
        } else if dry_run {
            steps.push(ManifestStep {
                item: "Guardian data".to_string(),
                ok: true,
                message: "would unpack the tarball on the headset (needs root)".to_string(),
            });
        } else {
            let tmp = "/sdcard/.quest-companion-tmp";
            let remote = format!("{tmp}/guardian.tar.gz");
            match t.push(&target, &local, &remote) {
                Ok(()) => {
                    match t.shell(&target, &format!("su -c \"tar -xzf {remote} -C /data/data && rm -f {remote}\"")) {
                        Ok(o) if o.code == 0 => steps.push(ManifestStep {
                            item: "Guardian data".to_string(),
                            ok: true,
                            message: "restored".to_string(),
                        }),
                        Ok(o) => steps.push(ManifestStep {
                            item: "Guardian data".to_string(),
                            ok: false,
                            message: format!("unpack failed: {}", o.stderr.trim()),
                        }),
                        Err(e) => steps.push(ManifestStep {
                            item: "Guardian data".to_string(),
                            ok: false,
                            message: format!("unpack failed: {e}"),
                        }),
                    }
                }
                Err(e) => steps.push(ManifestStep {
                    item: "Guardian data".to_string(),
                    ok: false,
                    message: format!("could not send the tarball: {e}"),
                }),
            }
        }
    }
    // 2b. Wi-Fi config files (root only): copy each back to where
    // it came from, with the usual owner/mode for wpa configs.
    // The user then re-enables Wi-Fi in the headset; no reboot here.
    let wifi_files: Vec<&String> = manifest
        .files
        .iter()
        .map(|f| &f.name)
        .filter(|n| n.starts_with("wifi/"))
        .collect();
    if wifi_files.is_empty() {
        steps.push(ManifestStep {
            item: "Wi-Fi configs".to_string(),
            ok: true,
            message: "not in this backup".to_string(),
        });
    } else if dry_run {
        steps.push(ManifestStep {
            item: "Wi-Fi configs".to_string(),
            ok: true,
            message: format!(
                "would restore {} Wi-Fi config file(s) (needs root)",
                wifi_files.len()
            ),
        });
    } else {
        let tmp = "/sdcard/.quest-companion-tmp";
        let mut ok_count = 0;
        let mut fail_count = 0;
        for name in &wifi_files {
            let leaf = name.trim_start_matches("wifi/");
            let dest = if leaf == "WifiConfigStore.xml" {
                "/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml".to_string()
            } else {
                format!("/data/vendor/wifi/wpa/{leaf}")
            };
            let local = backup_dir.join(name);
            let remote = format!("{tmp}/wifi-restore-{leaf}");
            let done = t
                .push(&target, &local, &remote)
                .and_then(|_| {
                    t.shell(&target, &format!(
                        "su -c \"cp {remote} {dest} && chmod 660 {dest} && chown wifi:wifi {dest}; r=$?; rm -f {remote}; exit $r\""
                    ))
                });
            match done {
                Ok(_) => ok_count += 1,
                Err(_) => fail_count += 1,
            }
        }
        steps.push(ManifestStep {
            item: "Wi-Fi configs".to_string(),
            ok: fail_count == 0,
            message: format!("restored {ok_count} config file(s), {fail_count} failed (toggle Wi-Fi in the headset afterwards)"),
        });
    }
    // 3. Apps from the library (APKs only unless --include-data).
    if !include_apps {
        steps.push(ManifestStep {
            item: "Apps".to_string(),
            ok: true,
            message: "skipped (--skip-apps)".to_string(),
        });
    } else {
        let refs: Vec<&DeviceAppRef> = manifest
            .apps
            .iter()
            .filter(|a| a.library_path.is_some())
            .collect();
        if dry_run {
            steps.push(ManifestStep {
                item: "Apps".to_string(),
                ok: true,
                message: format!(
                    "would reinstall {} app(s) from their library backups{}",
                    refs.len(),
                    if include_data { " (with app data)" } else { " (APKs only)" }
                ),
            });
        } else {
            let mut restored = 0;
            let mut failed = 0;
            for r in refs {
                let dir = PathBuf::from(r.library_path.as_deref().unwrap_or(""));
                match restore_backup(t, serial, &dir, include_data, false, true) {
                    Ok(rep) if rep.ready => restored += 1,
                    Ok(_) => failed += 1,
                    Err(_) => failed += 1,
                }
            }
            steps.push(ManifestStep {
                item: "Apps".to_string(),
                ok: failed == 0,
                message: format!("reinstalled {restored} app(s), {failed} failed"),
            });
        }
    }
    let ok = steps.iter().all(|s| s.ok);
    Ok(DeviceRestoreReport {
        serial: serial.to_string(),
        dry_run,
        backup_path: backup_dir.to_string_lossy().into_owned(),
        ready: ok,
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_pairs_parse() {
        let text = "wifi_on=1\nvolume_music=11\nkey with space=bad\nempty=\n# comment line\n";
        let pairs: Vec<(String, String)> = text
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, v)| (k.trim().to_string(), v.to_string())))
            .filter(|(k, _)| !k.is_empty() && !k.contains(' '))
            .collect();
        // "# comment line" has no '=', "key with space" is filtered out.
        assert_eq!(pairs.len(), 3);
        assert_eq!(pairs[0], ("wifi_on".to_string(), "1".to_string()));
        assert_eq!(pairs[2], ("empty".to_string(), "".to_string()));
    }
}
