//! File browsing / push / pull over the ADB sync protocol (via the
//! `adb` binary, which speaks sync itself; the direct transport will
//! use libadb's sync module when it lands).
//!
//! Scoped storage honesty: `/sdcard/Android/data/<pkg>/` is NOT readable
//! for other apps' data on Android 11+ without root. The UI must say so.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: String,
}

/// Parse one `ls -la` line. Toybox/Android format:
/// `-rw-r--r-- 1 owner group 1234 2026-11-11 12:00 name with spaces`
/// or the short form `... Oct 12  2021 name`. Returns None for
/// `total ...`, `.` / `..`, and unparsable lines.
///
/// BUG FOUND LIVE 2026-11-12: the real Quest `ls` uses the ISO date
/// form (`2026-11-11 12:00`, TWO tokens), not the month form
/// (`Nov 11 12:00`, THREE tokens). The old code always consumed three
/// tokens as the date, so it ate single-word file names entirely (the
/// whole entry vanished) and mangled multi-word names ("Open Brush"
/// came back as "Brush"). The date length is now detected from the
/// first date token: `YYYY-MM-DD` = 2 tokens, month name = 3 tokens.
pub fn parse_ls_line(line: &str) -> Option<FileEntry> {
    let line = line.trim_end();
    if line.is_empty() || line.starts_with("total ") {
        return None;
    }
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 8 {
        return None;
    }
    let perms = cols[0];
    if !perms.starts_with(['-', 'd', 'l']) || perms.len() < 10 {
        return None;
    }
    let is_dir = perms.starts_with('d');
    let size: u64 = cols[4].parse().ok()?;
    // Date/time: ISO "2026-11-11 12:00" (2 tokens) or month form
    // "Nov 11 12:00" / "Nov 11  2025" (3 tokens).
    let d1 = cols[5];
    let is_iso_date = d1.len() == 10
        && d1.as_bytes().get(4) == Some(&b'-')
        && d1.as_bytes().get(7) == Some(&b'-')
        && d1[..4].chars().all(|c| c.is_ascii_digit());
    let (modified, name_cols): (String, &[&str]) = if is_iso_date {
        if cols.len() < 8 {
            return None;
        }
        (format!("{} {}", cols[5], cols[6]), &cols[7..])
    } else {
        if cols.len() < 9 {
            return None;
        }
        (
            format!("{} {} {}", cols[5], cols[6], cols[7]),
            &cols[8..],
        )
    };
    if name_cols.is_empty() {
        return None;
    }
    let name = name_cols.join(" ");
    if name == "." || name == ".." {
        return None;
    }
    // Symlink target: "name -> target" — keep the link name.
    let name = name.split(" -> ").next().unwrap_or(&name).to_string();
    Some(FileEntry {
        name,
        path: String::new(), // filled in by list_files
        is_dir,
        size,
        modified,
    })
}

pub fn list_files(t: &dyn AdbTransport, serial: &str, path: &str) -> Result<Vec<FileEntry>> {
    let out = t.shell(&Target::serial(serial), &format!("ls -la {path}"))?;
    if out.code != 0 {
        let msg = out.stderr.trim();
        if !msg.is_empty() {
            return Err(Error(format!("cannot list {path}: {msg}")));
        }
    }
    // `ls` prints "ls: <path>: No such file or directory" on stdout
    // on some Android builds.
    let mut entries = Vec::new();
    for line in out.stdout.lines() {
        if line.contains("No such file or directory") || line.contains("Permission denied") {
            return Err(Error(format!("cannot list {path}: {}", line.trim())));
        }
        if let Some(mut e) = parse_ls_line(line) {
            let base = path.trim_end_matches('/');
            e.path = format!("{base}/{}", e.name);
            entries.push(e);
        }
    }
    entries.sort_by(|a, b| (!a.is_dir, a.name.to_lowercase()).cmp(&(!b.is_dir, b.name.to_lowercase())));
    Ok(entries)
}

pub fn push(t: &dyn AdbTransport, serial: &str, local: &Path, remote: &str) -> Result<()> {
    if !local.exists() {
        return Err(Error(format!("local file not found: {}", local.display())));
    }
    t.push(&Target::serial(serial), local, remote)
}

/// Delete a file or folder on the headset. Only paths under /sdcard/
/// are accepted, and never /sdcard itself — a delete outside shared
/// storage (or of the whole of shared storage) is refused before any
/// adb call is made.
pub fn delete(t: &dyn AdbTransport, serial: &str, remote: &str) -> Result<()> {
    let clean = remote.trim();
    if clean == "/sdcard" || clean == "/sdcard/" {
        return Err(Error("refusing to delete /sdcard itself".into()));
    }
    if !clean.starts_with("/sdcard/") {
        return Err(Error(format!(
            "refusing to delete '{clean}': only paths under /sdcard/ can be deleted"
        )));
    }
    if clean.split('/').any(|part| part == "..") {
        return Err(Error(format!(
            "refusing to delete '{clean}': '..' is not allowed in the path"
        )));
    }
    // Single-quote the path for the device shell (escape embedded quotes).
    let quoted = format!("'{}'", clean.replace('\'', "'\\''"));
    let out = t.shell(&Target::serial(serial), &format!("rm -rf -- {quoted}"))?;
    if out.code != 0 {
        return Err(Error(format!(
            "delete failed: {}",
            out.stderr.trim()
        )));
    }
    Ok(())
}

pub fn pull(t: &dyn AdbTransport, serial: &str, remote: &str, local: &Path) -> Result<()> {
    if let Some(parent) = local.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    t.pull(&Target::serial(serial), remote, local)
}
