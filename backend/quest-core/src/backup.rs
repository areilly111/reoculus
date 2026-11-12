//! App backup and restore. Local only, no cloud, no Meta/Play APIs.
//!
//! What a backup is: a folder on this computer holding the app's
//! APKs (base + splits, pulled with `pm path` + `adb pull`), its
//! OBB files from /sdcard/Android/obb/<pkg>/ when present, and —
//! when the headset is rooted — a tarball of /data/data/<pkg>.
//! A manifest.json in the folder records the package, label,
//! version, backup date, and a SHA-256 for every file, so a
//! restore can verify the backup before it installs anything.
//!
//! Honest limits (also in CONTRACT.md):
//! * `adb backup` is NOT used: it is deprecated, needs a tap on
//!   the headset to confirm, and most Quest apps opt out of it, so
//!   it usually backs up nothing. APK + OBB + (root) data tar is
//!   what actually works offline.
//! * App data backup needs root. Without root the backup still
//!   succeeds for APKs and OBB; the manifest records the data step
//!   as failed/skipped and the restore simply has no data to put back.
//! * Restoring app data is best-effort: the tarball is unpacked as
//!   root, ownership is fixed to the app's uid and SELinux labels
//!   are restored, but an app can still reject restored data. The
//!   UI asks for confirmation and restores data only with
//!   `--include-data`.

use crate::apps::app_details;
use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::fs::File;
use std::path::{Path, PathBuf};

/// Default backup root: `$XDG_DATA_HOME/quest-companion/backups`,
/// else `~/.local/share/quest-companion/backups`.
pub fn backup_root() -> Result<PathBuf> {
    if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() {
            return Ok(PathBuf::from(x).join("quest-companion").join("backups"));
        }
    }
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate backup dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("share")
        .join("quest-companion")
        .join("backups"))
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

/// "2026-11-12 00:46:11" (UTC) from a unix timestamp, without a
/// date crate. Days since epoch -> civil date (Howard Hinnant's
/// algorithm), seconds -> HH:MM:SS.
pub fn format_unix_time(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    let h = rem / 3600;
    let m = (rem % 3600) / 60;
    let s = rem % 60;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let yr = if mo <= 2 { y + 1 } else { y };
    format!("{yr:04}-{mo:02}-{d:02} {h:02}:{m:02}:{s:02}")
}

/// Folder-name timestamp: "20261112-004611" (UTC).
pub fn folder_stamp(secs: u64) -> String {
    let t = format_unix_time(secs);
    format!("{}-{}", &t[0..10].replace('-', ""), &t[11..19].replace(':', ""))
}

pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut f = File::open(path)?;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
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

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestFile {
    pub name: String,
    pub size_bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestStep {
    pub item: String,
    pub ok: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupManifest {
    pub package: String,
    pub label: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_code: Option<i64>,
    /// Backup date, "YYYY-MM-DD HH:MM:SS" UTC.
    pub backup_date: String,
    /// APK files in the backup folder (base.apk first).
    pub apks: Vec<ManifestFile>,
    /// OBB files in the `obb/` subfolder.
    #[serde(default)]
    pub obb: Vec<ManifestFile>,
    /// App-data tarball, when one was taken.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<ManifestFile>,
    /// Per-item outcome, including failures that did not stop the
    /// backup (e.g. data tar without root).
    #[serde(default)]
    pub steps: Vec<ManifestStep>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BackupReport {
    pub package: String,
    pub label: String,
    pub version: String,
    /// Full path of the backup folder on this computer.
    pub path: String,
    pub backup_date: String,
    pub total_size_bytes: u64,
    /// True only when every APK pulled and the manifest was written.
    pub ok: bool,
    pub steps: Vec<ManifestStep>,
}

/// One backup folder, as listed by `apps backup-list`.
#[derive(Debug, Clone, Serialize)]
pub struct BackupEntry {
    pub package: String,
    pub label: String,
    pub version: String,
    pub backup_date: String,
    /// Full path of the backup folder.
    pub path: String,
    pub total_size_bytes: u64,
    /// How many APK files the manifest lists.
    pub apk_count: usize,
    /// Was app data included in this backup?
    pub has_data: bool,
    /// How many OBB files the manifest lists.
    pub obb_count: usize,
}

// ---------------------------------------------------------------------------
// Backup
// ---------------------------------------------------------------------------

/// Back up one app to a new folder under the backup root (or
/// `out_dir` when given). Never fails the whole backup because one
/// piece failed: APKs are required (zero pulled APKs is an error),
/// OBB and app data are recorded per-item in the manifest.
pub fn backup_app(
    t: &dyn AdbTransport,
    serial: &str,
    package: &str,
    out_dir: Option<&Path>,
    skip_data: bool,
) -> Result<BackupReport> {
    let det = app_details(t, serial, package)?;
    let root = match out_dir {
        Some(d) => d.to_path_buf(),
        None => backup_root()?,
    };
    let stamp = folder_stamp(now_unix());
    let version = if det.version.is_empty() { "unknown".to_string() } else { det.version.clone() };
    let folder = root.join(format!(
        "{}-{}-{}",
        sanitize(package),
        sanitize(&version),
        stamp
    ));
    std::fs::create_dir_all(folder.join("obb"))?;
    let mut steps: Vec<ManifestStep> = Vec::new();
    let mut apk_files: Vec<ManifestFile> = Vec::new();
    // 1. APKs: base + splits, pulled with the existing transport.
    for remote in &det.apk_paths {
        let name = Path::new(remote)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "base.apk".to_string());
        let local = folder.join(&name);
        match t.pull(&Target::serial(serial), remote, &local) {
            Ok(()) => match sha256_file(&local) {
                Ok(hash) => {
                    let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                    apk_files.push(ManifestFile { name: name.clone(), size_bytes: size, sha256: hash });
                    steps.push(ManifestStep {
                        item: format!("APK {name}"),
                        ok: true,
                        message: format!("pulled {size} bytes"),
                    });
                }
                Err(e) => steps.push(ManifestStep {
                    item: format!("APK {name}"),
                    ok: false,
                    message: format!("pulled but could not hash: {e}"),
                }),
            },
            Err(e) => steps.push(ManifestStep {
                item: format!("APK {name}"),
                ok: false,
                message: format!("pull failed: {e}"),
            }),
        }
    }
    if apk_files.is_empty() {
        let _ = std::fs::remove_dir_all(&folder);
        return Err(Error(format!(
            "backup of {package} failed: no APK could be pulled ({})",
            steps.first().map(|s| s.message.clone()).unwrap_or_default()
        )));
    }
    // 2. OBB files, when the app has any.
    let mut obb_files: Vec<ManifestFile> = Vec::new();
    if !det.obb_files.is_empty() {
        for name in &det.obb_files {
            let remote = format!("/sdcard/Android/obb/{package}/{name}");
            let local = folder.join("obb").join(name);
            match t.pull(&Target::serial(serial), &remote, &local) {
                Ok(()) => match sha256_file(&local) {
                    Ok(hash) => {
                        let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                        obb_files.push(ManifestFile { name: name.clone(), size_bytes: size, sha256: hash });
                        steps.push(ManifestStep {
                            item: format!("OBB {name}"),
                            ok: true,
                            message: format!("pulled {size} bytes"),
                        });
                    }
                    Err(e) => steps.push(ManifestStep {
                        item: format!("OBB {name}"),
                        ok: false,
                        message: format!("pulled but could not hash: {e}"),
                    }),
                },
                Err(e) => steps.push(ManifestStep {
                    item: format!("OBB {name}"),
                    ok: false,
                    message: format!("pull failed: {e}"),
                }),
            }
        }
    } else {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: "no OBB files for this app".to_string(),
        });
    }
    // 3. App data (root only): tar /data/data/<pkg> on the device,
    // pull the tarball, delete the temp file. Any failure is
    // recorded; the backup still counts as done.
    let mut data_file: Option<ManifestFile> = None;
    if skip_data {
        steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "skipped (--skip-data)".to_string(),
        });
    } else {
        let target = Target::serial(serial);
        let tmp = "/sdcard/.quest-companion-tmp";
        let tar_remote = format!("{tmp}/{package}-data.tar.gz");
        let tar_cmd = format!(
            "su -c \"mkdir -p {tmp} && tar -czf {tar_remote} -C /data/data {package}\""
        );
        match t.shell(&target, &tar_cmd) {
            Ok(o) if o.code == 0 => {
                let local = folder.join("data.tar.gz");
                match t.pull(&target, &tar_remote, &local) {
                    Ok(()) => match sha256_file(&local) {
                        Ok(hash) => {
                            let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                            data_file = Some(ManifestFile {
                                name: "data.tar.gz".to_string(),
                                size_bytes: size,
                                sha256: hash,
                            });
                            steps.push(ManifestStep {
                                item: "App data".to_string(),
                                ok: true,
                                message: format!("backed up {size} bytes (needs root to restore)"),
                            });
                        }
                        Err(e) => steps.push(ManifestStep {
                            item: "App data".to_string(),
                            ok: false,
                            message: format!("tarball pulled but could not hash: {e}"),
                        }),
                    },
                    Err(e) => steps.push(ManifestStep {
                        item: "App data".to_string(),
                        ok: false,
                        message: format!("could not pull the data tarball: {e}"),
                    }),
                }
                let _ = t.shell(&target, &format!("rm -f {tar_remote}"));
            }
            Ok(o) => steps.push(ManifestStep {
                item: "App data".to_string(),
                ok: false,
                message: format!(
                    "needs root: the on-device tar failed ({}). APKs and OBB are still backed up.",
                    o.stderr.trim()
                ),
            }),
            Err(e) => steps.push(ManifestStep {
                item: "App data".to_string(),
                ok: false,
                message: format!("needs root: the on-device tar failed ({e}). APKs and OBB are still backed up."),
            }),
        }
    }
    let date = format_unix_time(now_unix());
    let manifest = BackupManifest {
        package: package.to_string(),
        label: det.label.clone(),
        version: det.version.clone(),
        version_code: det.version_code,
        backup_date: date.clone(),
        apks: apk_files,
        obb: obb_files,
        data: data_file,
        steps: steps.clone(),
    };
    let manifest_text = serde_json::to_string_pretty(&manifest)
        .map_err(|e| Error(format!("cannot write manifest: {e}")))?;
    std::fs::write(folder.join("manifest.json"), manifest_text)?;
    let total = dir_size(&folder);
    Ok(BackupReport {
        package: package.to_string(),
        label: det.label,
        version: det.version,
        path: folder.to_string_lossy().into_owned(),
        backup_date: date,
        total_size_bytes: total,
        ok: true,
        steps,
    })
}

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct RestoreReport {
    pub package: String,
    /// When true, nothing on the headset was touched.
    pub dry_run: bool,
    pub backup_path: String,
    pub ok: bool,
    pub steps: Vec<ManifestStep>,
}

pub fn read_manifest(dir: &Path) -> Result<BackupManifest> {
    let text = std::fs::read_to_string(dir.join("manifest.json")).map_err(|e| {
        Error(format!(
            "{} is not a backup folder (no manifest.json there: {e})",
            dir.display()
        ))
    })?;
    serde_json::from_str(&text)
        .map_err(|e| Error(format!("manifest.json in {} is invalid: {e}", dir.display())))
}

/// Verify every file listed in the manifest exists and matches its
/// SHA-256. Returns the list of problems (empty = all good).
pub fn verify_manifest(dir: &Path, manifest: &BackupManifest) -> Vec<String> {
    let mut problems = Vec::new();
    let check = |rel: &str, f: &ManifestFile, problems: &mut Vec<String>| {
        let p = dir.join(rel);
        match sha256_file(&p) {
            Ok(h) if h == f.sha256 => {}
            Ok(h) => problems.push(format!(
                "{}: hash mismatch (manifest {}, file {})",
                f.name, &f.sha256[..12.min(f.sha256.len())], &h[..12.min(h.len())]
            )),
            Err(e) => problems.push(format!("{}: cannot read: {e}", f.name)),
        }
    };
    for f in &manifest.apks {
        check(&f.name, f, &mut problems);
    }
    for f in &manifest.obb {
        check(&format!("obb/{}", f.name), f, &mut problems);
    }
    if let Some(f) = &manifest.data {
        check(&f.name, f, &mut problems);
    }
    problems
}

/// Restore a backup folder onto the headset.
///
/// * `--dry-run` only verifies hashes and lists what would happen;
///   it never installs, pushes, or changes anything.
/// * A real restore requires `--confirm` (the CLI enforces it):
///   it reinstalls the app, which replaces the installed version.
/// * App data is restored only with `include_data` (and only when
///   the backup actually has data.tar.gz). It needs root, and it
///   overwrites the app's current data: the UI confirms this
///   separately before calling. Ownership is fixed to the app's uid
///   afterwards and SELinux labels are restored; even so, restore
///   of app data is best-effort and an app may reject it.
pub fn restore_backup(
    t: &dyn AdbTransport,
    serial: &str,
    backup_dir: &Path,
    include_data: bool,
    dry_run: bool,
    confirm: bool,
) -> Result<RestoreReport> {
    if !dry_run && !confirm {
        return Err(Error(
            "restoring reinstalls the app on the headset. Re-run with --confirm to proceed."
                .into(),
        ));
    }
    let manifest = read_manifest(backup_dir)?;
    let problems = verify_manifest(backup_dir, &manifest);
    if !problems.is_empty() {
        return Err(Error(format!(
            "backup is damaged, refusing to restore: {}",
            problems.join("; ")
        )));
    }
    let target = Target::serial(serial);
    let mut steps: Vec<ManifestStep> = Vec::new();
    let apk_paths: Vec<PathBuf> = manifest
        .apks
        .iter()
        .map(|f| backup_dir.join(&f.name))
        .collect();
    // Install all APKs (base first: the manifest was written that way).
    let install_step = if dry_run {
        ManifestStep {
            item: "Install APKs".to_string(),
            ok: true,
            message: format!(
                "would install {} APK(s) with --reinstall ({})",
                apk_paths.len(),
                manifest.apks.iter().map(|f| f.name.clone()).collect::<Vec<_>>().join(", ")
            ),
        }
    } else {
        match t.install(&target, &apk_paths, true) {
            Ok(msg) => ManifestStep {
                item: "Install APKs".to_string(),
                ok: true,
                message: msg,
            },
            Err(e) => {
                steps.push(ManifestStep {
                    item: "Install APKs".to_string(),
                    ok: false,
                    message: format!("install failed: {e}"),
                });
                return Ok(RestoreReport {
                    package: manifest.package.clone(),
                    dry_run,
                    backup_path: backup_dir.to_string_lossy().into_owned(),
                    ok: false,
                    steps,
                });
            }
        }
    };
    steps.push(install_step);
    // OBB files back to /sdcard/Android/obb/<pkg>/.
    if manifest.obb.is_empty() {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: "no OBB files in this backup".to_string(),
        });
    } else if dry_run {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: format!(
                "would restore {} OBB file(s) to /sdcard/Android/obb/{}/",
                manifest.obb.len(),
                manifest.package
            ),
        });
    } else {
        let _ = t.shell(
            &target,
            &format!("mkdir -p /sdcard/Android/obb/{}", manifest.package),
        );
        for f in &manifest.obb {
            let local = backup_dir.join("obb").join(&f.name);
            let remote = format!("/sdcard/Android/obb/{}/{}", manifest.package, f.name);
            match t.push(&target, &local, &remote) {
                Ok(()) => steps.push(ManifestStep {
                    item: format!("OBB {}", f.name),
                    ok: true,
                    message: "restored".to_string(),
                }),
                Err(e) => steps.push(ManifestStep {
                    item: format!("OBB {}", f.name),
                    ok: false,
                    message: format!("push failed: {e}"),
                }),
            }
        }
    }
    // App data: only with --include-data, only when the backup has it.
    if !include_data {
        steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "not restored (pass --include-data to restore app data; it overwrites the app's current data)".to_string(),
        });
    } else if manifest.data.is_none() {
        steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "this backup has no app data to restore".to_string(),
        });
    } else if dry_run {
        steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "would restore app data (needs root; overwrites the app's current data)".to_string(),
        });
    } else {
        // Stop the app, unpack the tarball as root over
        // /data/data/<pkg>, fix ownership to the app's uid, fix
        // SELinux labels. Best-effort: every step is recorded.
        let pkg = &manifest.package;
        let _ = t.shell(&target, &format!("am force-stop {pkg}"));
        let tmp = "/sdcard/.quest-companion-tmp";
        let remote_tar = format!("{tmp}/{pkg}-restore.tar.gz");
        let local_tar = backup_dir.join("data.tar.gz");
        match t.push(&target, &local_tar, &remote_tar) {
            Ok(()) => {
                let extract = t.shell(&target, &format!(
                    "su -c \"tar -xzf {remote_tar} -C /data/data && rm -f {remote_tar}\""
                ));
                match extract {
                    Ok(o) if o.code == 0 => {
                        // Ownership: the app's uid from dumpsys appId.
                        // appId is not in PkgDetails; read it raw.
                        let app_id = t
                            .shell(&target, &format!("dumpsys package {pkg}"))
                            .ok()
                            .and_then(|out| {
                                out.stdout.lines().find_map(|l| {
                                    let l = l.trim();
                                    l.strip_prefix("appId=")
                                        .and_then(|v| v.trim().parse::<u32>().ok())
                                })
                            });
                        let mut msg = "app data restored".to_string();
                        match app_id {
                            Some(id) => {
                                let fix = t.shell(&target, &format!(
                                    "su -c \"chown -R {id}:{id} /data/data/{pkg} && restorecon -R /data/data/{pkg}\""
                                ));
                                match fix {
                                    Ok(o) if o.code == 0 => {}
                                    Ok(o) => msg.push_str(&format!(
                                        " (ownership fix reported: {})",
                                        o.stderr.trim()
                                    )),
                                    Err(e) => msg.push_str(&format!(" (ownership fix failed: {e})")),
                                }
                            }
                            None => msg.push_str(" (could not read the app uid, ownership left as restored)"),
                        }
                        steps.push(ManifestStep { item: "App data".to_string(), ok: true, message: msg });
                    }
                    Ok(o) => steps.push(ManifestStep {
                        item: "App data".to_string(),
                        ok: false,
                        message: format!("unpack failed: {}", o.stderr.trim()),
                    }),
                    Err(e) => steps.push(ManifestStep {
                        item: "App data".to_string(),
                        ok: false,
                        message: format!("unpack failed: {e}"),
                    }),
                }
            }
            Err(e) => steps.push(ManifestStep {
                item: "App data".to_string(),
                ok: false,
                message: format!("could not send the data tarball to the headset: {e}"),
            }),
        }
    }
    let ok = steps.iter().all(|s| s.ok);
    Ok(RestoreReport {
        package: manifest.package,
        dry_run,
        backup_path: backup_dir.to_string_lossy().into_owned(),
        ok,
        steps,
    })
}

// ---------------------------------------------------------------------------
// List / delete
// ---------------------------------------------------------------------------

pub fn list_backups() -> Result<Vec<BackupEntry>> {
    list_backups_in(&backup_root()?)
}

pub fn list_backups_in(root: &Path) -> Result<Vec<BackupEntry>> {
    let mut out = Vec::new();
    if !root.is_dir() {
        return Ok(out);
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(root)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
        .unwrap_or_default();
    dirs.sort();
    for dir in dirs {
        if let Ok(manifest) = read_manifest(&dir) {
            out.push(BackupEntry {
                package: manifest.package,
                label: manifest.label,
                version: manifest.version,
                backup_date: manifest.backup_date,
                path: dir.to_string_lossy().into_owned(),
                total_size_bytes: dir_size(&dir),
                apk_count: manifest.apks.len(),
                has_data: manifest.data.is_some(),
                obb_count: manifest.obb.len(),
            });
        }
    }
    // Newest backup first.
    out.sort_by(|a, b| b.backup_date.cmp(&a.backup_date));
    Ok(out)
}

/// Delete a backup folder (local files only; never touches the
/// headset). Refuses anything outside the backup root.
pub fn delete_backup(dir: &Path) -> Result<()> {
    let root = backup_root()?;
    let canon = dir.canonicalize().map_err(|e| Error(format!("backup not found: {e}")))?;
    let root_canon = root.canonicalize().unwrap_or(root.clone());
    if !canon.starts_with(&root_canon) {
        return Err(Error(format!(
            "refusing to delete {}: it is not inside the backup folder {}",
            dir.display(),
            root.display()
        )));
    }
    if read_manifest(&canon).is_err() {
        return Err(Error(format!(
            "{} does not look like a backup folder (no manifest.json)",
            dir.display()
        )));
    }
    std::fs::remove_dir_all(&canon)?;
    Ok(())
}

/// Is this headset rooted? A cheap `su -c id` that prints uid=0.
/// Used by the UI to explain why a data size / data backup is missing.
pub fn is_rooted(t: &dyn AdbTransport, serial: &str) -> bool {
    t.shell(&Target::serial(serial), "su -c id")
        .map(|o| o.stdout.contains("uid=0"))
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Save backup (game saves only, no APK)
// ---------------------------------------------------------------------------

/// A save backup is NOT an app backup: it holds no APK and cannot
/// reinstall anything. It holds the game's save data:
/// `/sdcard/Android/data/<pkg>/` (pulled as a file tree) and, on a
/// rooted headset, a tarball of /data/data/<pkg>/. OBB is
/// deliberately NOT copied (it can be gigabytes and is usually game
/// assets, not saves); the manifest notes its on-device size so the
/// user knows. Honest limits: some games keep saves server-side or
/// refuse access to their data; that shows up as a failed step in
/// the manifest, not as a silent success.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveManifest {
    pub kind: String,
    pub package: String,
    pub label: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_code: Option<i64>,
    pub backup_date: String,
    /// Files under `sdcard-data/`, paths relative to that folder.
    #[serde(default)]
    pub files: Vec<ManifestFile>,
    /// .obb files under `obb/`, only when --include-obb was used.
    #[serde(default)]
    pub obb: Vec<ManifestFile>,
    /// App-data tarball, when one was taken (root only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<ManifestFile>,
    /// On-device OBB size at backup time, when there was any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub obb_size_bytes: Option<u64>,
    #[serde(default)]
    pub steps: Vec<ManifestStep>,
}

fn hash_tree(root: &Path, base: &Path, out: &mut Vec<ManifestFile>) {
    if let Ok(rd) = std::fs::read_dir(root) {
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.path());
        for e in entries {
            let p = e.path();
            if p.is_dir() {
                hash_tree(&p, base, out);
            } else if let Ok(hash) = sha256_file(&p) {
                let size = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
                let rel = p.strip_prefix(base).unwrap_or(&p).to_string_lossy().into_owned();
                out.push(ManifestFile { name: rel, size_bytes: size, sha256: hash });
            }
        }
    }
}

/// Back up only one app's saves to a new folder under the backup
/// root (or `out_dir`). The folder is named
/// `<package>-save-<version>-<date>/` so it sorts next to app
/// backups but is clearly a save backup.
pub fn save_backup(
    t: &dyn AdbTransport,
    serial: &str,
    package: &str,
    out_dir: Option<&Path>,
    include_obb: bool,
) -> Result<BackupReport> {
    let det = app_details(t, serial, package)?;
    let root = match out_dir {
        Some(d) => d.to_path_buf(),
        None => backup_root()?,
    };
    let stamp = folder_stamp(now_unix());
    let version = if det.version.is_empty() { "unknown".to_string() } else { det.version.clone() };
    let folder = root.join(format!(
        "{}-save-{}-{}",
        sanitize(package),
        sanitize(&version),
        stamp
    ));
    std::fs::create_dir_all(folder.join("sdcard-data"))?;
    let target = Target::serial(serial);
    let mut steps: Vec<ManifestStep> = Vec::new();
    let mut files: Vec<ManifestFile> = Vec::new();
    // 1. /sdcard/Android/data/<pkg>/ as a file tree.
    match t.pull(&target, &format!("/sdcard/Android/data/{package}"), &folder.join("sdcard-data")) {
        Ok(()) => {
            hash_tree(&folder.join("sdcard-data"), &folder.join("sdcard-data"), &mut files);
            steps.push(ManifestStep {
                item: "Save files (/sdcard/Android/data)".to_string(),
                ok: true,
                message: format!("backed up {} file(s)", files.len()),
            });
        }
        Err(e) => steps.push(ManifestStep {
            item: "Save files (/sdcard/Android/data)".to_string(),
            ok: false,
            message: format!("nothing readable there ({e}); the game may keep saves elsewhere or server-side"),
        }),
    }
    // 2. OBB: noted, not copied, unless asked for.
    let mut obb_files: Vec<ManifestFile> = Vec::new();
    if include_obb && !det.obb_files.is_empty() {
        std::fs::create_dir_all(folder.join("obb"))?;
        for name in &det.obb_files {
            if !name.ends_with(".obb") {
                continue; // save backup: real .obb files only
            }
            let remote = format!("/sdcard/Android/obb/{package}/{name}");
            let local = folder.join("obb").join(name);
            match t.pull(&target, &remote, &local) {
                Ok(()) => {
                    if let Ok(hash) = sha256_file(&local) {
                        let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                        obb_files.push(ManifestFile { name: name.clone(), size_bytes: size, sha256: hash });
                    }
                }
                Err(e) => steps.push(ManifestStep {
                    item: format!("OBB {name}"),
                    ok: false,
                    message: format!("pull failed: {e}"),
                }),
            }
        }
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: format!("backed up {} .obb file(s) (--include-obb)", obb_files.len()),
        });
    } else if det.obb_size_bytes.is_some() {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: format!(
                "not copied ({} bytes on the device; use an app backup for OBB)",
                det.obb_size_bytes.unwrap_or(0)
            ),
        });
    }
    // 3. /data/data tarball (root only), same path as app backup.
    let mut data_file: Option<ManifestFile> = None;
    let tmp = "/sdcard/.quest-companion-tmp";
    let tar_remote = format!("{tmp}/{package}-save.tar.gz");
    match t.shell(&target, &format!(
        "su -c \"mkdir -p {tmp} && tar -czf {tar_remote} -C /data/data {package}\""
    )) {
        Ok(o) if o.code == 0 => {
            let local = folder.join("data.tar.gz");
            match t.pull(&target, &tar_remote, &local) {
                Ok(()) => match sha256_file(&local) {
                    Ok(hash) => {
                        let size = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(0);
                        data_file = Some(ManifestFile {
                            name: "data.tar.gz".to_string(),
                            size_bytes: size,
                            sha256: hash,
                        });
                        steps.push(ManifestStep {
                            item: "App data".to_string(),
                            ok: true,
                            message: format!("backed up {size} bytes (needs root to restore)"),
                        });
                    }
                    Err(e) => steps.push(ManifestStep {
                        item: "App data".to_string(),
                        ok: false,
                        message: format!("tarball pulled but could not hash: {e}"),
                    }),
                },
                Err(e) => steps.push(ManifestStep {
                    item: "App data".to_string(),
                    ok: false,
                    message: format!("could not pull the data tarball: {e}"),
                }),
            }
            let _ = t.shell(&target, &format!("rm -f {tar_remote}"));
        }
        _ => steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: false,
            message: "needs root: the on-device tar failed. Save files above are still backed up.".to_string(),
        }),
    }
    if files.is_empty() && data_file.is_none() {
        let _ = std::fs::remove_dir_all(&folder);
        return Err(Error(format!(
            "save backup of {package} found no save data to back up (no readable /sdcard/Android/data and no /data/data tarball)"
        )));
    }
    let date = format_unix_time(now_unix());
    let manifest = SaveManifest {
        kind: "save".to_string(),
        package: package.to_string(),
        label: det.label.clone(),
        version: det.version.clone(),
        version_code: det.version_code,
        backup_date: date.clone(),
        files,
        obb: obb_files,
        data: data_file,
        obb_size_bytes: det.obb_size_bytes,
        steps: steps.clone(),
    };
    std::fs::write(
        folder.join("manifest.json"),
        serde_json::to_string_pretty(&manifest)
            .map_err(|e| Error(format!("cannot write manifest: {e}")))?,
    )?;
    let total = dir_size(&folder);
    Ok(BackupReport {
        package: package.to_string(),
        label: det.label,
        version: det.version,
        path: folder.to_string_lossy().into_owned(),
        backup_date: date,
        total_size_bytes: total,
        ok: true,
        steps,
    })
}

pub fn read_save_manifest(dir: &Path) -> Result<SaveManifest> {
    let text = std::fs::read_to_string(dir.join("manifest.json")).map_err(|e| {
        Error(format!("{} is not a save backup folder (no manifest.json: {e})", dir.display()))
    })?;
    serde_json::from_str(&text)
        .map_err(|e| Error(format!("manifest.json in {} is invalid: {e}", dir.display())))
}

/// Restore a save backup. Verifies hashes first; refuses a damaged
/// backup. Requires --confirm (it overwrites the game's current
/// saves), --dry-run only lists the steps. The app itself is NOT
/// reinstalled (that is what an app backup restore does).
pub fn save_restore(
    t: &dyn AdbTransport,
    serial: &str,
    backup_dir: &Path,
    dry_run: bool,
    confirm: bool,
) -> Result<RestoreReport> {
    if !dry_run && !confirm {
        return Err(Error(
            "restoring a save overwrites the game's current saves. Re-run with --confirm to proceed.".into(),
        ));
    }
    let manifest = read_save_manifest(backup_dir)?;
    // Verify hashes of the sdcard files + data tarball.
    let mut problems = Vec::new();
    for f in &manifest.files {
        let p = backup_dir.join("sdcard-data").join(&f.name);
        match sha256_file(&p) {
            Ok(h) if h == f.sha256 => {}
            Ok(_) => problems.push(format!("{}: hash mismatch", f.name)),
            Err(e) => problems.push(format!("{}: cannot read: {e}", f.name)),
        }
    }
    if let Some(d) = &manifest.data {
        match sha256_file(&backup_dir.join("data.tar.gz")) {
            Ok(h) if h == d.sha256 => {}
            Ok(_) => problems.push("data.tar.gz: hash mismatch".to_string()),
            Err(e) => problems.push(format!("data.tar.gz: cannot read: {e}")),
        }
    }
    for f in &manifest.obb {
        let p = backup_dir.join("obb").join(&f.name);
        match sha256_file(&p) {
            Ok(h) if h == f.sha256 => {}
            Ok(_) => problems.push(format!("obb/{}: hash mismatch", f.name)),
            Err(e) => problems.push(format!("obb/{}: cannot read: {e}", f.name)),
        }
    }
    if !problems.is_empty() {
        return Err(Error(format!(
            "save backup is damaged, refusing to restore: {}",
            problems.join("; ")
        )));
    }
    let target = Target::serial(serial);
    let pkg = &manifest.package;
    let mut steps: Vec<ManifestStep> = Vec::new();
    // 1. sdcard save files back.
    if manifest.files.is_empty() {
        steps.push(ManifestStep {
            item: "Save files".to_string(),
            ok: true,
            message: "no save files in this backup".to_string(),
        });
    } else if dry_run {
        steps.push(ManifestStep {
            item: "Save files".to_string(),
            ok: true,
            message: format!(
                "would push {} file(s) back to /sdcard/Android/data/{pkg}/",
                manifest.files.len()
            ),
        });
    } else {
        let _ = t.shell(&target, &format!("am force-stop {pkg}"));
        match t.push(&target, &backup_dir.join("sdcard-data"), &format!("/sdcard/Android/data/{pkg}")) {
            Ok(()) => steps.push(ManifestStep {
                item: "Save files".to_string(),
                ok: true,
                message: format!("restored {} file(s)", manifest.files.len()),
            }),
            Err(e) => steps.push(ManifestStep {
                item: "Save files".to_string(),
                ok: false,
                message: format!("push failed: {e}"),
            }),
        }
    }
    // 1b. OBB files back (only when the save backup included them).
    if manifest.obb.is_empty() {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: "no OBB files in this save backup".to_string(),
        });
    } else if dry_run {
        steps.push(ManifestStep {
            item: "OBB".to_string(),
            ok: true,
            message: format!("would restore {} .obb file(s)", manifest.obb.len()),
        });
    } else {
        let _ = t.shell(&target, &format!("mkdir -p /sdcard/Android/obb/{pkg}"));
        for f in &manifest.obb {
            let local = backup_dir.join("obb").join(&f.name);
            let remote = format!("/sdcard/Android/obb/{pkg}/{}", f.name);
            match t.push(&target, &local, &remote) {
                Ok(()) => steps.push(ManifestStep {
                    item: format!("OBB {}", f.name),
                    ok: true,
                    message: "restored".to_string(),
                }),
                Err(e) => steps.push(ManifestStep {
                    item: format!("OBB {}", f.name),
                    ok: false,
                    message: format!("push failed: {e}"),
                }),
            }
        }
    }
    // 2. /data/data tarball (root only).
    match &manifest.data {
        None => steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "this save backup has no app data to restore".to_string(),
        }),
        Some(_) if dry_run => steps.push(ManifestStep {
            item: "App data".to_string(),
            ok: true,
            message: "would restore app data (needs root; overwrites the app's current data)".to_string(),
        }),
        Some(_) => {
            let tmp = "/sdcard/.quest-companion-tmp";
            let remote_tar = format!("{tmp}/{pkg}-save-restore.tar.gz");
            match t.push(&target, &backup_dir.join("data.tar.gz"), &remote_tar) {
                Ok(()) => {
                    let r = t.shell(&target, &format!(
                        "su -c \"tar -xzf {remote_tar} -C /data/data && rm -f {remote_tar}\""
                    ));
                    match r {
                        Ok(o) if o.code == 0 => steps.push(ManifestStep {
                            item: "App data".to_string(),
                            ok: true,
                            message: "app data restored (ownership may need the app to restart to take effect)".to_string(),
                        }),
                        Ok(o) => steps.push(ManifestStep {
                            item: "App data".to_string(),
                            ok: false,
                            message: format!("unpack failed: {}", o.stderr.trim()),
                        }),
                        Err(e) => steps.push(ManifestStep {
                            item: "App data".to_string(),
                            ok: false,
                            message: format!("unpack failed: {e}"),
                        }),
                    }
                }
                Err(e) => steps.push(ManifestStep {
                    item: "App data".to_string(),
                    ok: false,
                    message: format!("could not send the data tarball: {e}"),
                }),
            }
        }
    }
    let ok = steps.iter().all(|s| s.ok);
    Ok(RestoreReport {
        package: manifest.package,
        dry_run,
        backup_path: backup_dir.to_string_lossy().into_owned(),
        ok,
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{AdbTransport, CmdOutput, Device, Target};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::Mutex;

    #[test]
    fn unix_time_formats() {
        // 2026-11-12 00:00:00 UTC = 1794441600 (verified with date -u).
        assert_eq!(format_unix_time(1794441600), "2026-11-12 00:00:00");
        assert_eq!(format_unix_time(0), "1970-01-01 00:00:00");
        assert_eq!(format_unix_time(1794441600 + 86399), "2026-11-12 23:59:59");
        assert_eq!(folder_stamp(1794441600), "20261112-000000");
    }

    #[test]
    fn manifest_hash_verification() {
        let dir = tempfile::tempdir().unwrap();
        let apk = dir.path().join("base.apk");
        std::fs::write(&apk, b"fake apk bytes").unwrap();
        let hash = sha256_file(&apk).unwrap();
        let manifest = BackupManifest {
            package: "com.example.game".to_string(),
            label: "Game".to_string(),
            version: "1.0".to_string(),
            version_code: Some(42),
            backup_date: "2026-11-12 00:00:00".to_string(),
            apks: vec![ManifestFile {
                name: "base.apk".to_string(),
                size_bytes: 14,
                sha256: hash,
            }],
            obb: vec![],
            data: None,
            steps: vec![],
        };
        std::fs::write(
            dir.path().join("manifest.json"),
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let read = read_manifest(dir.path()).unwrap();
        assert_eq!(read.package, "com.example.game");
        assert!(verify_manifest(dir.path(), &read).is_empty());
        // Tamper with the APK: verification must catch it.
        std::fs::write(&apk, b"tampered bytes!!").unwrap();
        let problems = verify_manifest(dir.path(), &read);
        assert_eq!(problems.len(), 1);
        assert!(problems[0].contains("hash mismatch"));
    }

    #[test]
    fn backup_folder_layout_and_list() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("com.example.game-1.0-20261112-000000");
        std::fs::create_dir_all(folder.join("obb")).unwrap();
        let manifest = BackupManifest {
            package: "com.example.game".to_string(),
            label: "Game".to_string(),
            version: "1.0".to_string(),
            version_code: None,
            backup_date: "2026-11-12 00:00:00".to_string(),
            apks: vec![ManifestFile {
                name: "base.apk".to_string(),
                size_bytes: 3,
                sha256: "abc".to_string(),
            }],
            obb: vec![],
            data: None,
            steps: vec![],
        };
        std::fs::write(folder.join("base.apk"), b"apk").unwrap();
        std::fs::write(
            folder.join("manifest.json"),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        let entries = list_backups_in(root.path()).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].package, "com.example.game");
        assert_eq!(entries[0].apk_count, 1);
        assert!(!entries[0].has_data);
        assert!(entries[0].total_size_bytes > 0);
    }

    // -- A fake transport for restore dry-run tests -----------------------
    struct FakeTransport {
        shell_map: Mutex<HashMap<String, CmdOutput>>,
        pulled: Mutex<Vec<String>>,
    }

    fn ok_out(stdout: &str) -> CmdOutput {
        CmdOutput { stdout: stdout.to_string(), stderr: String::new(), code: 0 }
    }

    impl AdbTransport for FakeTransport {
        fn name(&self) -> &'static str {
            "fake"
        }
        fn list_devices(&self) -> Result<Vec<Device>> {
            Ok(vec![])
        }
        fn shell(&self, _t: &Target, cmd: &str) -> Result<CmdOutput> {
            let map = self.shell_map.lock().unwrap();
            for (k, v) in map.iter() {
                if cmd.contains(k) {
                    return Ok(v.clone());
                }
            }
            Ok(ok_out(""))
        }
        fn exec_out(&self, _t: &Target, _argv: &[&str]) -> Result<Vec<u8>> {
            Ok(vec![])
        }
        fn push(&self, _t: &Target, _l: &Path, _r: &str) -> Result<()> {
            Ok(())
        }
        fn pull(&self, _t: &Target, remote: &str, local: &Path) -> Result<()> {
            self.pulled.lock().unwrap().push(remote.to_string());
            std::fs::write(local, b"fake pulled bytes").map_err(crate::error::Error::from)?;
            Ok(())
        }
        fn install(&self, _t: &Target, _a: &[PathBuf], _r: bool) -> Result<String> {
            panic!("install must not be called in a dry run");
        }
        fn logcat_dump(&self, _t: &Target) -> Result<Vec<String>> {
            Ok(vec![])
        }
        fn pair_tls(&self, _i: &str, _p: u16, _c: &str) -> Result<String> {
            Ok(String::new())
        }
        fn connect_tcp(&self, _i: &str, _p: u16) -> Result<String> {
            Ok(String::new())
        }
        fn tcpip(&self, _t: &Target, _p: u16) -> Result<()> {
            Ok(())
        }
        fn reboot(&self, _t: &Target) -> Result<()> {
            Ok(())
        }
        fn disconnect(&self, _s: &str) -> Result<String> {
            Ok(String::new())
        }
    }

    fn fake_with_manifest(dir: &Path) -> FakeTransport {
        let mut shell_map = HashMap::new();
        // app_details() calls, in order: pm path, dumpsys, ls, su du, du obb.
        shell_map.insert(
            "pm path com.example.game".to_string(),
            ok_out("package:/data/app/~~x/com.example.game-abc/base.apk\n"),
        );
        shell_map.insert(
            "dumpsys package com.example.game".to_string(),
            ok_out(
                "  Package [com.example.game] (1):\n    versionCode=42 minSdk=29 targetSdk=34\n    versionName=1.0\n    lastUpdateTime=2026-11-12 00:00:00\n    installerPackageName=null\n    initiatingPackageName=com.android.shell\n",
            ),
        );
        shell_map.insert(
            "ls -l".to_string(),
            ok_out("-rw-r--r-- 1 system system 14 2026-11-12 00:00 /data/app/~~x/com.example.game-abc/base.apk\n"),
        );
        shell_map.insert(
            "du -sb /data/data/com.example.game".to_string(),
            ok_out("1024\t/data/data/com.example.game\n"),
        );
        shell_map.insert(
            "du -sb /sdcard/Android/obb/com.example.game".to_string(),
            ok_out(""),
        );
        shell_map.insert(
            "pm list packages -3 com.example.game".to_string(),
            ok_out("package:com.example.game\n"),
        );
        let _ = dir;
        FakeTransport { shell_map: Mutex::new(shell_map), pulled: Mutex::new(vec![]) }
    }

    #[test]
    fn restore_dry_run_lists_steps_and_touches_nothing() {
        // Build a real backup with the fake transport, then dry-run a
        // restore of it: no install call may happen (FakeTransport
        // panics if install is called).
        let out_root = tempfile::tempdir().unwrap();
        let fake = fake_with_manifest(out_root.path());
        let report = backup_app(&fake, "TESTSERIAL", "com.example.game", Some(out_root.path()), true)
            .expect("fake backup");
        assert!(report.ok);
        assert_eq!(report.steps.iter().filter(|s| s.ok).count(), report.steps.len());
        let dir = PathBuf::from(&report.path);
        assert!(dir.join("manifest.json").is_file());
        assert!(dir.join("base.apk").is_file());
        // Restore without --confirm must fail; dry-run needs none.
        let err = restore_backup(&fake, "TESTSERIAL", &dir, false, false, false)
            .expect_err("real restore without --confirm must fail");
        assert!(err.to_string().contains("--confirm"));
        let dry = restore_backup(&fake, "TESTSERIAL", &dir, true, true, false)
            .expect("dry run");
        assert!(dry.dry_run);
        assert!(dry.ok);
        assert!(dry.steps.iter().any(|s| s.item == "Install APKs" && s.message.contains("would install")));
        assert!(dry.steps.iter().any(|s| s.item == "App data" && s.message.contains("no app data")));
    }
}
