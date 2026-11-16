/// Mirror quality settings, one preset per connection type, plus
/// which mirror to use: scrcpy in its own window, or the built-in
/// H.264 stream shown inside the app (the same stream the Android
/// app uses, decoded on this computer).
///
/// The mirror used to pick its own quality (USB = Balanced,
/// Wi-Fi = Performance) with no setting to change. Now the user
/// can pick each one. The choice is kept in
/// `~/.config/quest-companion/mirror.json` and read by the app
/// when it starts a mirror. The defaults are the old automatic
/// picks, so nothing changes until the user changes it.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const PRESET_PERFORMANCE: &str = "performance";
pub const PRESET_BALANCED: &str = "balanced";
pub const PRESET_QUALITY: &str = "quality";

/// scrcpy in its own window (the original mirror, low latency).
pub const METHOD_SCRCPY: &str = "scrcpy";
/// The built-in H.264 stream, decoded in the app window.
pub const METHOD_BUILTIN: &str = "builtin";

/// The old automatic picks, kept as the defaults.
pub const DEFAULT_USB_QUALITY: &str = PRESET_BALANCED;
pub const DEFAULT_WIFI_QUALITY: &str = PRESET_PERFORMANCE;
/// scrcpy stays the default: it is 35 to 70 ms behind, the
/// built-in stream is about a second behind.
pub const DEFAULT_METHOD: &str = METHOD_SCRCPY;

/// A mirror method name, lowercased, or an error naming the bad value.
pub fn normalize_method(value: &str) -> Result<String> {
    let v = value.trim().to_lowercase();
    match v.as_str() {
        METHOD_SCRCPY | METHOD_BUILTIN => Ok(v),
        _ => Err(Error(format!(
            "unknown mirror method '{value}': pick scrcpy or builtin"
        ))),
    }
}

/// A preset name, lowercased, or an error naming the bad value.
pub fn normalize_preset(value: &str) -> Result<String> {
    let v = value.trim().to_lowercase();
    match v.as_str() {
        PRESET_PERFORMANCE | PRESET_BALANCED | PRESET_QUALITY => Ok(v),
        _ => Err(Error(format!(
            "unknown mirror quality '{value}': pick performance, balanced or quality"
        ))),
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MirrorSettingsConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usb_quality: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wifi_quality: Option<String>,
    /// Restart the mirror by itself when a game or the menu opens.
    /// `None` means on (the default).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_restart: Option<bool>,
    /// Which mirror to use: scrcpy or builtin. `None` means
    /// scrcpy (the default).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
}

/// Auto-restart is on unless the user turned it off.
pub const DEFAULT_AUTO_RESTART: bool = true;

/// "on" / "off" from the command line, or an error naming the
/// bad value.
pub fn normalize_on_off(value: &str) -> Result<bool> {
    match value.trim().to_lowercase().as_str() {
        "on" => Ok(true),
        "off" => Ok(false),
        _ => Err(Error(format!(
            "unknown auto-restart '{value}': pick on or off"
        ))),
    }
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
    pub usb_quality: String,
    pub wifi_quality: String,
    pub auto_restart: bool,
    pub method: String,
}

/// The effective settings: the saved choice where there is one,
/// the old automatic pick where there is not. A saved value the
/// code no longer recognises falls back to the default instead
/// of failing, so a bad file never blocks mirroring.
pub fn get_mirror_settings() -> MirrorSettings {
    let cfg = read_config();
    let usb = cfg
        .usb_quality
        .as_deref()
        .and_then(|v| normalize_preset(v).ok())
        .unwrap_or_else(|| DEFAULT_USB_QUALITY.to_string());
    let wifi = cfg
        .wifi_quality
        .as_deref()
        .and_then(|v| normalize_preset(v).ok())
        .unwrap_or_else(|| DEFAULT_WIFI_QUALITY.to_string());
    let method = cfg
        .method
        .as_deref()
        .and_then(|v| normalize_method(v).ok())
        .unwrap_or_else(|| DEFAULT_METHOD.to_string());
    MirrorSettings {
        usb_quality: usb,
        wifi_quality: wifi,
        auto_restart: cfg.auto_restart.unwrap_or(DEFAULT_AUTO_RESTART),
        method,
    }
}

/// Save a new quality for USB and/or Wi-Fi, and/or turn
/// auto-restart on or off, and/or pick the mirror method.
/// Anything left out keeps its current value. Returns the
/// effective settings afterwards.
pub fn set_mirror_settings(
    usb_quality: Option<String>,
    wifi_quality: Option<String>,
    auto_restart: Option<bool>,
    method: Option<String>,
) -> Result<MirrorSettings> {
    let mut cfg = read_config();
    if let Some(u) = usb_quality {
        cfg.usb_quality = Some(normalize_preset(&u)?);
    }
    if let Some(w) = wifi_quality {
        cfg.wifi_quality = Some(normalize_preset(&w)?);
    }
    if let Some(a) = auto_restart {
        cfg.auto_restart = Some(a);
    }
    if let Some(m) = method {
        cfg.method = Some(normalize_method(&m)?);
    }
    write_config(&cfg)?;
    Ok(get_mirror_settings())
}

/// Go back to the old automatic picks (USB Balanced, Wi-Fi
/// Performance) and auto-restart back on.
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
    fn normalize_accepts_all_three_case_insensitively() {
        assert_eq!(normalize_preset("Performance").unwrap(), "performance");
        assert_eq!(normalize_preset("BALANCED").unwrap(), "balanced");
        assert_eq!(normalize_preset(" quality ").unwrap(), "quality");
    }

    #[test]
    fn normalize_refuses_unknown() {
        assert!(normalize_preset("ultra").is_err());
        assert!(normalize_preset("").is_err());
    }

    #[test]
    fn normalize_method_accepts_both_case_insensitively() {
        assert_eq!(normalize_method("Scrcpy").unwrap(), "scrcpy");
        assert_eq!(normalize_method("BUILTIN").unwrap(), "builtin");
    }

    #[test]
    fn normalize_method_refuses_unknown() {
        assert!(normalize_method("ffmpeg").is_err());
        assert!(normalize_method("").is_err());
    }

    #[test]
    fn defaults_are_the_old_automatic_picks() {
        assert_eq!(DEFAULT_USB_QUALITY, "balanced");
        assert_eq!(DEFAULT_WIFI_QUALITY, "performance");
        assert_eq!(DEFAULT_METHOD, "scrcpy");
    }
}
