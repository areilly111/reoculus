/// Mirror view setting: the headset display is two eye views side
/// by side, and the app can show both or a flat single-eye view.
///
/// The choice is kept in `~/.config/quest-companion/mirror.json`
/// and read by the app when the Mirror screen opens. The default
/// is both eyes. This file used to hold scrcpy quality presets,
/// an auto-restart flag and a mirror method; scrcpy is gone
/// (0.2.36), the built-in H.264 stream is the only mirror now,
/// so the view is all that is left. An old file with the removed
/// keys still loads: unknown keys are ignored and the view falls
/// back to the default.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Both eye views side by side, as the headset sees them.
pub const VIEW_STEREO: &str = "stereo";
/// One eye only, at its own aspect, flat.
pub const VIEW_FLAT: &str = "flat";

/// Both eyes is the default: it is what the headset shows.
pub const DEFAULT_VIEW: &str = VIEW_STEREO;

/// A view name, lowercased, or an error naming the bad value.
pub fn normalize_view(value: &str) -> Result<String> {
    let v = value.trim().to_lowercase();
    match v.as_str() {
        VIEW_STEREO | VIEW_FLAT => Ok(v),
        _ => Err(Error(format!(
            "unknown mirror view '{value}': pick stereo or flat"
        ))),
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MirrorSettingsConfig {
    /// Which view to show: stereo or flat. `None` means stereo.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<String>,
}

fn config_path() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate config dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("quest-companion")
        .join("mirror.json"))
}

/// Read the saved mirror settings from the config file on this computer.
/// Missing file, unreadable file, or bad JSON all fall back to the
/// defaults instead of erroring, so a first run just works.
pub fn read_config() -> MirrorSettingsConfig {
    let Ok(path) = config_path() else {
        return MirrorSettingsConfig::default();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return MirrorSettingsConfig::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn write_config(cfg: &MirrorSettingsConfig) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error(e.to_string()))?;
    }
    let text = serde_json::to_string_pretty(cfg).map_err(|e| Error(e.to_string()))?;
    std::fs::write(&path, text).map_err(|e| Error(e.to_string()))?;
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
pub struct MirrorSettings {
    pub view: String,
}

/// The effective settings: the saved choice where there is one,
/// the default where there is not. A saved value the code no
/// longer recognises falls back to the default instead of
/// failing, so a bad file never blocks mirroring.
pub fn get_mirror_settings() -> MirrorSettings {
    let cfg = read_config();
    let view = cfg
        .view
        .as_deref()
        .and_then(|v| normalize_view(v).ok())
        .unwrap_or_else(|| DEFAULT_VIEW.to_string());
    MirrorSettings { view }
}

/// Save a new view. Returns the effective settings afterwards.
pub fn set_mirror_settings(view: Option<String>) -> Result<MirrorSettings> {
    let mut cfg = read_config();
    if let Some(v) = view {
        cfg.view = Some(normalize_view(&v)?);
    }
    write_config(&cfg)?;
    Ok(get_mirror_settings())
}

/// Go back to the default view (both eyes).
pub fn reset_mirror_settings() -> MirrorSettings {
    if let Ok(path) = config_path() {
        let _ = std::fs::remove_file(path);
    }
    get_mirror_settings()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_view_accepts_both_case_insensitively() {
        assert_eq!(normalize_view("Stereo").unwrap(), "stereo");
        assert_eq!(normalize_view(" FLAT ").unwrap(), "flat");
    }

    #[test]
    fn normalize_view_refuses_unknown() {
        assert!(normalize_view("side-by-side").is_err());
        assert!(normalize_view("").is_err());
    }

    #[test]
    fn default_view_is_stereo() {
        assert_eq!(DEFAULT_VIEW, "stereo");
    }
}
