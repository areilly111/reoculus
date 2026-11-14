//! Headset snapshots: a named, whole-headset save point.
//!
//! A snapshot is a device backup (settings, Guardian data, Wi-Fi
//! configs, app inventory; see device_backup.rs) plus a small
//! `snapshot.json` on top of it recording the name, the headset it
//! came from, and the settings profile that was active at the time.
//! Restoring a snapshot is the device restore plus re-applying
//! that profile, so a replacement headset comes back how it was.
//!
//! The APKs themselves are NOT copied into a snapshot (same honest
//! limit as a device backup): apps reinstall from their library
//! backups. A snapshot folder is a device backup folder with one
//! extra file, so nothing here can be mistaken for a disk image.

use crate::backup::backup_root;
use crate::device_backup::{
    device_backup, device_restore, read_device_manifest, DeviceBackupReport,
};
use crate::error::{Error, Result};
use crate::settings::{apply_profile, load_profiles};
use crate::transport::AdbTransport;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapshotManifest {
    pub kind: String,
    pub name: String,
    pub serial: String,
    pub model: Option<String>,
    pub firmware: Option<String>,
    pub created_date: String,
    pub device_backup_path: String,
    /// Settings profile active when the snapshot was taken, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub app_count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct SnapshotEntry {
    pub serial: String,
    pub name: String,
    pub created_date: String,
    pub path: String,
    pub total_size_bytes: u64,
    pub app_count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct SnapshotReport {
    pub serial: String,
    pub name: String,
    pub path: String,
    pub created_date: String,
    pub total_size_bytes: u64,
    pub ready: bool,
    pub steps: Vec<crate::backup::ManifestStep>,
}

fn sanitize_name(s: &str) -> String {
    let s: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' || c == ' ' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let s = s.trim().to_string();
    if s.is_empty() {
        "snapshot".to_string()
    } else {
        s
    }
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

/// Save a named snapshot of the whole headset: runs a full device
/// backup, then writes a snapshot.json in that backup folder naming it,
/// so it can be found and restored later. `profile` is optional and is
/// just recorded in the manifest.
pub fn create_snapshot(
    t: &dyn AdbTransport,
    serial: &str,
    name: &str,
    profile: Option<&str>,
) -> Result<SnapshotReport> {
    let name = sanitize_name(name);
    let report: DeviceBackupReport = device_backup(t, serial, None)?;
    let manifest = read_device_manifest(Path::new(&report.path))?;
    let snap = SnapshotManifest {
        kind: "snapshot".to_string(),
        name: name.clone(),
        serial: serial.to_string(),
        model: manifest.model,
        firmware: manifest.firmware,
        created_date: report.backup_date.clone(),
        device_backup_path: report.path.clone(),
        profile: profile.map(|s| s.to_string()),
        app_count: manifest.apps.len(),
    };
    std::fs::write(
        Path::new(&report.path).join("snapshot.json"),
        serde_json::to_string_pretty(&snap)
            .map_err(|e| Error(format!("cannot write snapshot manifest: {e}")))?,
    )?;
    Ok(SnapshotReport {
        serial: serial.to_string(),
        name,
        path: report.path,
        created_date: report.backup_date,
        total_size_bytes: report.total_size_bytes,
        ready: report.ready,
        steps: report.steps,
    })
}

/// Read the snapshot.json of one snapshot folder. Errors when the
/// folder has no snapshot file or it is not valid JSON.
pub fn read_snapshot_manifest(dir: &Path) -> Result<SnapshotManifest> {
    let text = std::fs::read_to_string(dir.join("snapshot.json")).map_err(|e| {
        Error(format!(
            "{} is not a snapshot folder (no snapshot.json: {e})",
            dir.display()
        ))
    })?;
    serde_json::from_str(&text)
        .map_err(|e| Error(format!("snapshot.json in {} is invalid: {e}", dir.display())))
}

/// List snapshots in the backup root, newest first.
pub fn list_snapshots() -> Result<Vec<SnapshotEntry>> {
    let root = backup_root()?;
    let mut out: Vec<SnapshotEntry> = Vec::new();
    if root.is_dir() {
        if let Ok(rd) = std::fs::read_dir(&root) {
            for e in rd.flatten() {
                let dir = e.path();
                if !dir.is_dir() {
                    continue;
                }
                if let Ok(m) = read_snapshot_manifest(&dir) {
                    if m.kind == "snapshot" {
                        out.push(SnapshotEntry {
                            serial: m.serial,
                            name: m.name,
                            created_date: m.created_date,
                            path: dir.to_string_lossy().into_owned(),
                            total_size_bytes: dir_size(&dir),
                            app_count: m.app_count,
                        });
                    }
                }
            }
        }
    }
    out.sort_by(|a, b| b.created_date.cmp(&a.created_date));
    Ok(out)
}

/// Restore a snapshot: the device restore (dry-run first, real
/// restores need --confirm), then re-apply the settings profile
/// recorded in the snapshot, if one was recorded.
pub fn restore_snapshot(
    t: &dyn AdbTransport,
    serial: &str,
    snapshot_dir: &Path,
    dry_run: bool,
    confirm: bool,
) -> Result<crate::device_backup::DeviceRestoreReport> {
    let manifest = read_snapshot_manifest(snapshot_dir)?;
    if manifest.kind != "snapshot" {
        return Err(Error(format!(
            "{} is not a snapshot (manifest kind is {})",
            snapshot_dir.display(),
            manifest.kind
        )));
    }
    let mut report = device_restore(t, serial, snapshot_dir, true, false, dry_run, confirm)?;
    if dry_run {
        return Ok(report);
    }
    // Re-apply the recorded settings profile, if one exists.
    if let Some(profile_name) = &manifest.profile {
        if let Ok(profiles) = load_profiles() {
            if let Some(p) = profiles.get(profile_name) {
                let model = t
                    .shell(&crate::transport::Target::serial(serial), "getprop ro.product.model")
                    .map(|o| o.stdout.trim().to_string())
                    .unwrap_or_default();
                match apply_profile(t, serial, p, &model) {
                    Ok(applied) => {
                        let n = applied.applied.len();
                        let mut steps = report.steps.clone();
                        steps.push(crate::backup::ManifestStep {
                            item: "Settings profile".to_string(),
                            ok: true,
                            message: format!("re-applied profile '{profile_name}' ({n} setting(s))"),
                        });
                        report.steps = steps;
                    }
                    Err(e) => {
                        let mut steps = report.steps.clone();
                        steps.push(crate::backup::ManifestStep {
                            item: "Settings profile".to_string(),
                            ok: false,
                            message: format!("could not re-apply profile '{profile_name}': {e}"),
                        });
                        report.steps = steps;
                    }
                }
            }
        }
    }
    Ok(report)
}

/// Delete a snapshot folder (local files only, never the headset).
pub fn delete_snapshot(path: &Path) -> Result<()> {
    // Refuse anything outside the backup root.
    let root = backup_root()?;
    let canon = path
        .canonicalize()
        .unwrap_or_else(|_| path.to_path_buf());
    if !canon.starts_with(&root) {
        return Err(Error(format!(
            "refusing to delete {} (outside the backup folder)",
            path.display()
        )));
    }
    let _ = read_snapshot_manifest(path)?;
    std::fs::remove_dir_all(path)
        .map_err(|e| Error(format!("could not delete snapshot {}: {e}", path.display())))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backup::{format_unix_time, now_unix};

    #[test]
    fn sanitize_name_keeps_words() {
        assert_eq!(sanitize_name("Before rooting"), "Before rooting");
        assert_eq!(sanitize_name("a/b:c"), "a_b_c");
        assert_eq!(sanitize_name("   "), "snapshot");
        assert_eq!(sanitize_name("v1.2-final"), "v1.2-final");
    }

    #[test]
    fn snapshot_manifest_round_trips() {
        let m = SnapshotManifest {
            kind: "snapshot".into(),
            name: "Before rooting".into(),
            serial: "TESTSERIAL000001".into(),
            model: Some("Quest 2".into()),
            firmware: Some("52500000000000000".into()),
            created_date: "2026-11-12 12:00".into(),
            device_backup_path: "/tmp/x".into(),
            profile: Some("Balanced".into()),
            app_count: 235,
        };
        let text = serde_json::to_string(&m).unwrap();
        let back: SnapshotManifest = serde_json::from_str(&text).unwrap();
        assert_eq!(back.name, "Before rooting");
        assert_eq!(back.profile.as_deref(), Some("Balanced"));
        assert_eq!(back.app_count, 235);
    }

    #[test]
    fn format_unix_time_known() {
        assert_eq!(format_unix_time(0), "1970-01-01 00:00:00");
        assert_eq!(now_unix() > 0, true);
    }
}
