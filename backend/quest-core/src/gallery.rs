//! Screenshot / recording gallery. Screenshots and recordings are
//! saved on this computer under `~/quest-recordings/` (the folder the
//! record command already used); the gallery just lists what is
//! there. Files are local only; deleting one never touches the headset.

use crate::error::{Error, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// Gallery root: `~/quest-recordings/`.
pub fn gallery_root() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate gallery dir".into()))?;
    Ok(PathBuf::from(home).join("quest-recordings"))
}

#[derive(Debug, Clone, Serialize)]
pub struct GalleryEntry {
    /// File name, e.g. `shot-2026-11-12-120000.png`.
    pub name: String,
    pub path: String,
    /// `screenshot` or `recording`.
    pub kind: String,
    pub size_bytes: u64,
    /// Last-modified, "YYYY-MM-DD HH:MM:SS" local file time (UTC
    /// here; the UI shows the file date, not a capture timestamp).
    pub modified: String,
}

fn is_media(p: &Path) -> Option<&'static str> {
    match p.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref() {
        Some("png") | Some("jpg") | Some("jpeg") | Some("webp") => Some("screenshot"),
        Some("mp4") | Some("mkv") | Some("webm") => Some("recording"),
        _ => None,
    }
}

pub fn list_gallery() -> Result<Vec<GalleryEntry>> {
    list_gallery_in(&gallery_root()?)
}

pub fn list_gallery_in(root: &Path) -> Result<Vec<GalleryEntry>> {
    let mut out = Vec::new();
    if !root.is_dir() {
        return Ok(out);
    }
    let entries = std::fs::read_dir(root).map_err(|e| Error(e.to_string()))?;
    for e in entries.flatten() {
        let p = e.path();
        let Some(kind) = is_media(&p) else { continue };
        let Ok(m) = e.metadata() else { continue };
        let modified = m
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| crate::backup::format_unix_time(d.as_secs()))
            .unwrap_or_default();
        out.push(GalleryEntry {
            name: p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            path: p.to_string_lossy().into_owned(),
            kind: kind.to_string(),
            size_bytes: m.len(),
            modified,
        });
    }
    // Newest first.
    out.sort_by(|a, b| b.modified.cmp(&a.modified).then(b.name.cmp(&a.name)));
    Ok(out)
}

/// Delete one gallery file (local file only). Refuses anything
/// outside the gallery folder.
pub fn delete_gallery_file(path: &Path) -> Result<()> {
    let root = gallery_root()?;
    let canon = path.canonicalize().map_err(|e| Error(format!("file not found: {e}")))?;
    let root_canon = root.canonicalize().unwrap_or(root.clone());
    if !canon.starts_with(&root_canon) {
        return Err(Error(format!(
            "refusing to delete {}: it is not inside the gallery folder {}",
            path.display(),
            root.display()
        )));
    }
    if is_media(&canon).is_none() {
        return Err(Error(format!(
            "{} is not a screenshot or recording",
            path.display()
        )));
    }
    std::fs::remove_file(&canon)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gallery_lists_and_sorts() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("shot-a.png"), b"png").unwrap();
        std::fs::write(dir.path().join("rec-b.mp4"), b"mp4mp4").unwrap();
        std::fs::write(dir.path().join("notes.txt"), b"nope").unwrap();
        let list = list_gallery_in(dir.path()).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list.iter().filter(|e| e.kind == "screenshot").count(), 1);
        assert_eq!(list.iter().filter(|e| e.kind == "recording").count(), 1);
        // Delete refuses files outside the gallery dir.
        let outside = tempfile::tempdir().unwrap();
        let p = outside.path().join("shot-x.png");
        std::fs::write(&p, b"png").unwrap();
        assert!(delete_gallery_file(&p).is_err());
    }
}
