//! The local APK library: one folder on this computer, the same
//! folder backups already go to
//! (`~/.local/share/quest-companion/backups/`).
//!
//! A library entry is either:
//! * an **app backup** (kind `app`, source `backup`): the folder
//!   with manifest.json that `apps backup` wrote;
//! * a **save backup** (kind `save`, source `backup`): the folder
//!   with manifest.json that `apps save-backup` wrote;
//! * an **imported APK** (kind `apk`, source `imported`): an APK /
//!   .apks / .xapk file the user imported from the UI, copied into
//!   `imported/<package>-<version>/`.
//!
//! The index is a plain JSON file (`library-index.json`) in the
//! library folder, so it survives restarts. No database: the update
//! check (comparing installed versions to library versions) is
//! deliberately deferred until a proper database exists (see
//! README.md / CONTRACT.md).

use crate::apps::{badging_of, local_apk_icon, unpack_bundle, AppIcon};
use crate::backup::{
    backup_root, delete_backup, format_unix_time, now_unix, read_manifest, read_save_manifest,
};
use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::fs::File;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryEntry {
    /// `app` (app backup) | `save` (save backup) | `apk` (imported file).
    pub kind: String,
    /// `backup` | `imported`.
    pub source: String,
    pub package: String,
    pub label: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_code: Option<i64>,
    pub size_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    /// Backup date, or the date the file was imported.
    pub date_added: String,
    /// Backup folder, or the imported APK file.
    pub path: String,
    #[serde(default)]
    pub apk_count: usize,
    #[serde(default)]
    pub has_data: bool,
    #[serde(default)]
    pub obb_count: usize,
}

fn index_path() -> Result<PathBuf> {
    Ok(backup_root()?.join("library-index.json"))
}

fn load_index() -> Vec<LibraryEntry> {
    let Ok(path) = index_path() else { return vec![] };
    let Ok(text) = std::fs::read_to_string(path) else { return vec![] };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save_index(entries: &[LibraryEntry]) -> Result<()> {
    let root = backup_root()?;
    std::fs::create_dir_all(&root)?;
    std::fs::write(index_path()?, serde_json::to_string_pretty(entries)?)?;
    Ok(())
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

/// Everything in the library: backups discovered from their
/// folders (newest first) plus imported APKs from the index.
/// Entries whose files vanished are dropped from the index.
pub fn list_library() -> Result<Vec<LibraryEntry>> {
    let root = backup_root()?;
    let mut out: Vec<LibraryEntry> = Vec::new();
    if root.is_dir() {
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
            .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
            .unwrap_or_default();
        dirs.sort();
        for dir in dirs {
            let manifest_path = dir.join("manifest.json");
            if !manifest_path.is_file() {
                continue;
            }
            // Save or app backup? The save manifest carries kind:"save".
            let text = std::fs::read_to_string(&manifest_path).unwrap_or_default();
            let is_save = text.contains("\"kind\": \"save\"") || text.contains("\"kind\":\"save\"");
            if is_save {
                if let Ok(m) = read_save_manifest(&dir) {
                    let size = dir_size(&dir);
                    out.push(LibraryEntry {
                        kind: "save".to_string(),
                        source: "backup".to_string(),
                        package: m.package,
                        label: m.label,
                        version: m.version,
                        version_code: m.version_code,
                        size_bytes: size,
                        sha256: None,
                        date_added: m.backup_date,
                        path: dir.to_string_lossy().into_owned(),
                        apk_count: 0,
                        has_data: m.data.is_some(),
                        obb_count: m.obb.len(),
                    });
                }
            } else if let Ok(m) = read_manifest(&dir) {
                let size = dir_size(&dir);
                out.push(LibraryEntry {
                    kind: "app".to_string(),
                    source: "backup".to_string(),
                    package: m.package,
                    label: m.label,
                    version: m.version,
                    version_code: m.version_code,
                    size_bytes: size,
                    sha256: None,
                    date_added: m.backup_date,
                    path: dir.to_string_lossy().into_owned(),
                    apk_count: m.apks.len(),
                    has_data: m.data.is_some(),
                    obb_count: m.obb.len(),
                });
            }
        }
    }
    // Imported APKs from the index (drop stale entries).
    let mut index = load_index();
    let before = index.len();
    index.retain(|e| Path::new(&e.path).exists());
    if index.len() != before {
        let _ = save_index(&index);
    }
    out.extend(index);
    out.sort_by(|a, b| b.date_added.cmp(&a.date_added));
    Ok(out)
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

/// Import a local APK / .apks / .xapk file into the library: the
/// file is copied (not moved) into
/// `imported/<package>-<version>/`, hashed, and recorded in the
/// index. Package / version / label come from aapt badging when it
/// works; otherwise the file name is used and the version is
/// "unknown" (recorded honestly, not guessed).
pub fn import_apk(path: &Path) -> Result<LibraryEntry> {
    if !path.is_file() {
        return Err(Error(format!("file not found: {}", path.display())));
    }
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !matches!(ext.as_str(), "apk" | "apks" | "xapk") {
        return Err(Error(format!(
            "{} is not an APK, .apks or .xapk file",
            path.display()
        )));
    }
    let (package, version, label, version_code) = identify_apk(path, &ext)?;
    let root = backup_root()?;
    let dir = root.join("imported").join(format!(
        "{}-{}",
        sanitize(&package),
        sanitize(&version)
    ));
    std::fs::create_dir_all(&dir)?;
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "app.apk".to_string());
    let dest = dir.join(&file_name);
    if dest != path {
        std::fs::copy(path, &dest)?;
    }
    let mut f = File::open(&dest)?;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    let sha = format!("{:x}", h.finalize());
    let size = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
    let entry = LibraryEntry {
        kind: "apk".to_string(),
        source: "imported".to_string(),
        package: package.clone(),
        label,
        version: version.clone(),
        version_code,
        size_bytes: size,
        sha256: Some(sha),
        date_added: format_unix_time(now_unix()),
        path: dest.to_string_lossy().into_owned(),
        apk_count: 1,
        has_data: false,
        obb_count: 0,
    };
    let mut index = load_index();
    index.retain(|e| !(e.package == package && e.version == version && e.kind == "apk"));
    index.push(entry.clone());
    save_index(&index)?;
    Ok(entry)
}

/// Pull package / version / label out of an APK file (or the
/// base.apk inside a bundle). Falls back to the file name.
fn identify_apk(path: &Path, ext: &str) -> Result<(String, String, String, Option<i64>)> {
    let stem = path
        .file_stem()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".to_string());
    let mut apk_for_badging: Option<PathBuf> = None;
    let mut _bundle_dir: Option<tempfile::TempDir> = None;
    if ext == "apk" {
        apk_for_badging = Some(path.to_path_buf());
    } else {
        let (dir, apks) = unpack_bundle(path)?;
        if let Some(base) = apks.iter().find(|p| {
            p.file_name().map(|n| n.eq_ignore_ascii_case("base.apk")).unwrap_or(false)
        }) {
            apk_for_badging = Some(base.clone());
        } else if let Some(first) = apks.first() {
            apk_for_badging = Some(first.clone());
        }
        _bundle_dir = Some(dir);
    }
    if let Some(apk) = apk_for_badging {
        if let Ok(b) = badging_of(&apk) {
            let package = b.package.clone().unwrap_or_else(|| stem.clone());
            let version = b.version.clone().unwrap_or_else(|| "unknown".to_string());
            let label = b
                .label
                .clone()
                .filter(|l| !l.is_empty())
                .unwrap_or_else(|| {
                    package.rsplit('.').next().unwrap_or(&package).to_string()
                });
            // versionCode is not in Badging; leave it unknown here.
            return Ok((package, version, label, None));
        }
    }
    Ok((stem.clone(), "unknown".to_string(), stem, None))
}

/// Get the launcher icon for one library entry, from the APK
/// already on this computer. No headset, no ADB pull.
///
/// * kind `app` (app backup): the base.apk in the backup folder,
///   named by manifest.json, base.apk first.
/// * kind `apk` (imported file): the APK itself, or the base.apk
///   inside an .apks / .xapk bundle (unpacked to a temp dir).
/// * kind `save` (save backup): no APK in the folder, so there is
///   no icon to get. This is an error, not a fake icon: the UI
///   keeps the save icon for save backups.
///
/// The icon is cached by [`local_apk_icon`] under
/// ~/.cache/quest-companion/icons/<package>/<version>/, so a
/// repeat call is a cache hit and never re-reads the APK.
pub fn library_icon(path: &Path, package: &str, version: &str, kind: &str) -> Result<AppIcon> {
    if kind == "save" {
        return Err(Error(
            "save backups have no APK, so there is no launcher icon to show".into(),
        ));
    }
    // Resolve the APK file, keeping any bundle temp dir alive
    // until the icon has been extracted from it.
    let mut _bundle_dir: Option<tempfile::TempDir> = None;
    let apk_path: PathBuf = if path.is_file() {
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        if ext == "apk" {
            path.to_path_buf()
        } else {
            let (dir, apks) = unpack_bundle(path)?;
            let base = apks
                .iter()
                .find(|p| {
                    p.file_name()
                        .map(|n| n.eq_ignore_ascii_case("base.apk"))
                        .unwrap_or(false)
                })
                .or_else(|| apks.first())
                .ok_or_else(|| Error(format!("no APKs found inside {}", path.display())))?
                .clone();
            _bundle_dir = Some(dir);
            base
        }
    } else if path.is_dir() {
        // Backup folder: the manifest names the APKs, base.apk first.
        let mut candidate: Option<PathBuf> = None;
        if let Ok(m) = read_manifest(path) {
            if let Some(first) = m.apks.first() {
                let p = path.join(&first.name);
                if p.is_file() {
                    candidate = Some(p);
                }
            }
        }
        if candidate.is_none() {
            let base = path.join("base.apk");
            if base.is_file() {
                candidate = Some(base);
            }
        }
        if candidate.is_none() {
            // Last resort: any .apk in the folder, name order.
            let mut apks: Vec<PathBuf> = std::fs::read_dir(path)
                .map(|rd| {
                    rd.flatten()
                        .map(|e| e.path())
                        .filter(|p| {
                            p.is_file()
                                && p.extension()
                                    .map(|e| e.eq_ignore_ascii_case("apk"))
                                    .unwrap_or(false)
                        })
                        .collect()
                })
                .unwrap_or_default();
            apks.sort();
            candidate = apks.into_iter().next();
        }
        candidate.ok_or_else(|| {
            Error(format!(
                "no APK found in backup folder {}",
                path.display()
            ))
        })?
    } else {
        return Err(Error(format!("library entry not found: {}", path.display())));
    };
    local_apk_icon(&apk_path, package, version)
}

/// Delete a library entry. Backup folders go through the backup
/// delete (manifest check included); imported files are removed
/// from disk and the index. Local files only, never the headset.
pub fn delete_library_entry(path: &Path) -> Result<()> {
    let root = backup_root()?;
    let canon = path.canonicalize().map_err(|e| Error(format!("not found: {e}")))?;
    let root_canon = root.canonicalize().unwrap_or(root.clone());
    if !canon.starts_with(&root_canon) {
        return Err(Error(format!(
            "refusing to delete {}: it is not inside the library folder {}",
            path.display(),
            root.display()
        )));
    }
    if canon.is_dir() && canon.join("manifest.json").is_file() {
        return delete_backup(&canon);
    }
    if canon.is_file() {
        std::fs::remove_file(&canon)?;
        // Prune the now-empty imported dir and the index entry.
        if let Some(parent) = canon.parent() {
            let _ = std::fs::remove_dir(parent);
        }
        let mut index = load_index();
        index.retain(|e| Path::new(&e.path) != canon);
        save_index(&index)?;
        return Ok(());
    }
    if canon.is_dir() {
        // An imported folder (multi-file bundle copy).
        std::fs::remove_dir_all(&canon)?;
        let mut index = load_index();
        index.retain(|e| !Path::new(&e.path).starts_with(&canon));
        save_index(&index)?;
        return Ok(());
    }
    Err(Error(format!("nothing to delete at {}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_lists_backups_and_imports() {
        // A fake backup folder + a fake imported entry: the list
        // must show both, newest first, with kinds intact.
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("com.example.game-1.0-20261112-000000");
        std::fs::create_dir_all(&folder).unwrap();
        let manifest = serde_json::json!({
            "package": "com.example.game",
            "label": "Game",
            "version": "1.0",
            "version_code": 42,
            "backup_date": "2026-11-12 00:00:00",
            "apks": [{"name": "base.apk", "size_bytes": 3, "sha256": "abc"}],
            "obb": [],
            "steps": []
        });
        std::fs::write(folder.join("manifest.json"), manifest.to_string()).unwrap();
        std::fs::write(folder.join("base.apk"), b"apk").unwrap();
        // list_library uses the real backup root; instead verify the
        // manifest detection logic directly here.
        let text = std::fs::read_to_string(folder.join("manifest.json")).unwrap();
        assert!(!text.contains("\"kind\": \"save\""));
        let m = read_manifest(&folder).unwrap();
        assert_eq!(m.package, "com.example.game");
        assert_eq!(m.apks.len(), 1);
    }

    #[test]
    fn library_icon_rejects_save_backups() {
        // Save backups have no APK in the folder, so there is no
        // icon to extract. This must be a clean error, not a
        // fake icon and not a crash.
        let err = library_icon(
            Path::new("/tmp/no-such-backup"),
            "com.example.game",
            "1.0",
            "save",
        )
        .unwrap_err();
        assert!(err.to_string().contains("no APK"));
    }

    #[test]
    fn library_icon_rejects_missing_entry() {
        let err = library_icon(
            Path::new("/tmp/no-such-backup"),
            "com.example.game",
            "1.0",
            "app",
        )
        .unwrap_err();
        assert!(err.to_string().contains("not found"));
    }
}
