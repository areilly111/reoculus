//! Storage locations on this computer.
//!
//! Backups and the APK library share one root folder (the library
//! index lives inside it), and screenshots/recordings live in their
//! own folder. Both used to be fixed; now the user can move them,
//! for example onto a bigger drive. The choice is kept in
//! `~/.config/quest-companion/paths.json` and read by every command
//! that touches those folders.
//!
//! Moving a location does NOT move the files already there; the new
//! folder starts empty, and the library will look empty until
//! backups are made or APKs are imported there. The old folder is
//! left alone, so nothing is lost.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PathsConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recordings_root: Option<String>,
}

fn config_path() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate config dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("quest-companion")
        .join("paths.json"))
}

/// Read the saved backup and recordings folders from the config file on
/// this computer. Missing file, unreadable file, or bad JSON all fall
/// back to the defaults instead of erroring.
pub fn read_config() -> PathsConfig {
    let Ok(path) = config_path() else {
        return PathsConfig::default();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return PathsConfig::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn write_config(cfg: &PathsConfig) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error(e.to_string()))?;
    }
    let text = serde_json::to_string_pretty(cfg).map_err(|e| Error(e.to_string()))?;
    std::fs::write(&path, text).map_err(|e| Error(e.to_string()))?;
    Ok(())
}

/// Default backup root: `$XDG_DATA_HOME/quest-companion/backups`,
/// else `~/.local/share/quest-companion/backups`.
pub fn default_backup_root() -> Result<PathBuf> {
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

/// The default recordings folder: `~/quest-recordings`. Errors when
/// HOME is not set.
pub fn default_recordings_root() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate gallery dir".into()))?;
    Ok(PathBuf::from(home).join("quest-recordings"))
}

/// The effective backup root: the `QUEST_COMPANION_BACKUP_ROOT`
/// environment variable wins, then the saved choice, then the
/// default. Same shape for the recordings root.
pub fn backup_root() -> Result<PathBuf> {
    if let Ok(x) = std::env::var("QUEST_COMPANION_BACKUP_ROOT") {
        if !x.is_empty() {
            return Ok(PathBuf::from(x));
        }
    }
    if let Some(p) = read_config().backup_root {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    default_backup_root()
}

/// The recordings folder in effect: the `QUEST_COMPANION_RECORDINGS_ROOT`
/// environment variable wins, then the saved choice, then the default.
/// Same shape as `backup_root`.
pub fn recordings_root() -> Result<PathBuf> {
    if let Ok(x) = std::env::var("QUEST_COMPANION_RECORDINGS_ROOT") {
        if !x.is_empty() {
            return Ok(PathBuf::from(x));
        }
    }
    if let Some(p) = read_config().recordings_root {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    default_recordings_root()
}

#[derive(Debug, Clone, Serialize)]
pub struct PathsInfo {
    pub backup_root: String,
    pub recordings_root: String,
    pub backup_root_is_default: bool,
    pub recordings_root_is_default: bool,
    pub config_file: String,
}

/// Both storage folders in effect, plus whether each one is still the
/// default and which config file they came from. What the UI shows on
/// the Paths screen.
pub fn get_paths() -> Result<PathsInfo> {
    let backup = backup_root()?;
    let rec = recordings_root()?;
    let cfg = read_config();
    Ok(PathsInfo {
        backup_root_is_default: cfg.backup_root.is_none()
            && std::env::var("QUEST_COMPANION_BACKUP_ROOT").is_err(),
        recordings_root_is_default: cfg.recordings_root.is_none()
            && std::env::var("QUEST_COMPANION_RECORDINGS_ROOT").is_err(),
        backup_root: backup.to_string_lossy().into_owned(),
        recordings_root: rec.to_string_lossy().into_owned(),
        config_file: config_path()?.to_string_lossy().into_owned(),
    })
}

fn check_dir(path: &str, what: &str) -> Result<PathBuf> {
    let p = PathBuf::from(path);
    if !p.is_absolute() {
        return Err(Error(format!("{what} must be a full path, like /home/user/backups")));
    }
    if p.exists() && !p.is_dir() {
        return Err(Error(format!("{what} exists but is not a folder: {path}")));
    }
    std::fs::create_dir_all(&p).map_err(|e| {
        Error(format!("could not create {what} at {path}: {e}"))
    })?;
    Ok(p)
}

/// Save new locations. Either may be left out to keep the current
/// one. Returns the effective paths afterwards.
pub fn set_paths(
    backup_root: Option<String>,
    recordings_root: Option<String>,
) -> Result<PathsInfo> {
    let mut cfg = read_config();
    if let Some(b) = backup_root {
        let p = check_dir(&b, "the backup folder")?;
        cfg.backup_root = Some(p.to_string_lossy().into_owned());
    }
    if let Some(r) = recordings_root {
        let p = check_dir(&r, "the recordings folder")?;
        cfg.recordings_root = Some(p.to_string_lossy().into_owned());
    }
    write_config(&cfg)?;
    get_paths()
}

/// Forget the saved backup and recordings folders (deletes the config
/// file) and return the defaults that now apply.
pub fn reset_paths() -> Result<PathsInfo> {
    if let Ok(path) = config_path() {
        let _ = std::fs::remove_file(path);
    }
    get_paths()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_backup_root_ends_with_backups() {
        let p = default_backup_root().unwrap();
        assert!(p.ends_with("quest-companion/backups"));
    }

    #[test]
    fn check_dir_rejects_relative() {
        assert!(check_dir("backups", "the backup folder").is_err());
    }
}
