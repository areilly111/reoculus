//! Quest settings: `debug.oculus.*` setprops (volatile — reapply on
//! connect/reboot) plus generic Android `settings get/put`.
//!
//! The per-model allowlist is deliberately conservative: `debug.oculus.*`
//! keys change or disappear per firmware. Unknown keys are refused
//! unless the caller passes them with an explicit `custom:` prefix,
//! which is the power-user escape hatch (documented, with a warning).

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Keys the UI may offer per model. Quest 2 supports up to 120 Hz;
/// Quest 3 / 3S up to 207 Hz supported, 240 Hz experimental with
/// forceDisplayScaling. Quest 1 tops out at 72 Hz and never had
/// forceDisplayScaling (Quest 3 only) or the experimental toggle
/// (Quest 2 wording), so both are hidden there.
pub fn allowed_keys(model: &str) -> &'static [&'static str] {
    if crate::headset::classify(model, "").is_quest1() {
        &[
            "debug.oculus.refreshRate",
            "debug.oculus.cpuLevel",
            "debug.oculus.gpuLevel",
            "debug.oculus.guardian_pause",
            "debug.oculus.fullRateCapture",
            "debug.oculus.textureWidth",
            "debug.oculus.textureHeight",
        ]
    } else {
        &[
            "debug.oculus.refreshRate",
            "debug.oculus.cpuLevel",
            "debug.oculus.gpuLevel",
            "debug.oculus.guardian_pause",
            "debug.oculus.fullRateCapture",
            "debug.oculus.textureWidth",
            "debug.oculus.textureHeight",
            "debug.oculus.forceDisplayScaling",
            "debug.oculus.experimentalEnabled",
        ]
    }
}

pub fn max_refresh_rate(model: &str) -> u32 {
    crate::headset::classify(model, "").max_refresh_rate()
}

pub fn is_quest_key(key: &str) -> bool {
    key.starts_with("debug.oculus.")
}

pub struct SettingResult {
    pub value: String,
    pub warning: Option<String>,
}

pub fn get_setting(
    t: &dyn AdbTransport,
    serial: &str,
    key: &str,
) -> Result<SettingResult> {
    let target = Target::serial(serial);
    if is_quest_key(key) {
        let out = t.shell(&target, &format!("getprop {key}"))?;
        return Ok(SettingResult {
            value: out.stdout.trim().to_string(),
            warning: None,
        });
    }
    // Generic Android settings: `namespace:key` selects the table,
    // default is `system` (e.g. screen_brightness).
    let (ns, k) = match key.split_once(':') {
        Some(("global", rest)) => ("global", rest),
        Some(("secure", rest)) => ("secure", rest),
        Some(("system", rest)) => ("system", rest),
        _ => ("system", key),
    };
    let out = t.shell(&target, &format!("settings get {ns} {k}"))?;
    Ok(SettingResult {
        value: out.stdout.trim().to_string(),
        warning: None,
    })
}

pub fn set_setting(
    t: &dyn AdbTransport,
    serial: &str,
    key: &str,
    value: &str,
    model: &str,
) -> Result<SettingResult> {
    let target = Target::serial(serial);
    if is_quest_key(key) {
        if !allowed_keys(model).contains(&key) && !key.starts_with("debug.oculus.custom.") {
            return Err(Error(format!(
                "refusing unknown Quest key '{key}' for model '{model}'. \
                 Allowed: {}. Use debug.oculus.custom.* only if you know \
                 the key exists on this firmware.",
                allowed_keys(model).join(", ")
            )));
        }
        if key == "debug.oculus.refreshRate" {
            if let Ok(rate) = value.parse::<u32>() {
                let max = max_refresh_rate(model);
                if rate > max {
                    return Err(Error(format!(
                        "refresh rate {rate} Hz is above the supported {max} Hz for {model} \
                         (240 Hz on Quest 3 is experimental and needs forceDisplayScaling)"
                    )));
                }
            }
        }
        let out = t.shell(&target, &format!("setprop {key} {value}"))?;
        if out.code != 0 {
            return Err(Error(format!("setprop failed: {}", out.stderr.trim())));
        }
        return Ok(SettingResult {
            value: value.to_string(),
            warning: Some(
                "debug.oculus.* settings are volatile and clear on reboot; reapply the profile on connect."
                    .into(),
            ),
        });
    }
    let (ns, k) = match key.split_once(':') {
        Some(("global", rest)) => ("global", rest),
        Some(("secure", rest)) => ("secure", rest),
        Some(("system", rest)) => ("system", rest),
        _ => ("system", key),
    };
    let out = t.shell(&target, &format!("settings put {ns} {k} {value}"))?;
    if out.code != 0 {
        return Err(Error(format!("settings put failed: {}", out.stderr.trim())));
    }
    Ok(SettingResult {
        value: value.to_string(),
        warning: None,
    })
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_rate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_level: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_level: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub texture_width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub texture_height: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guardian_pause: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub full_rate_capture: Option<u32>,
}

pub fn builtin_profiles() -> Vec<Profile> {
    vec![
        Profile {
            name: "balanced".into(),
            refresh_rate: Some(90),
            cpu_level: Some(2),
            gpu_level: Some(2),
            texture_width: None,
            texture_height: None,
            guardian_pause: Some(0),
            full_rate_capture: None,
        },
        Profile {
            name: "performance".into(),
            refresh_rate: Some(120),
            cpu_level: Some(4),
            gpu_level: Some(4),
            texture_width: Some(1536),
            texture_height: Some(1536),
            guardian_pause: Some(0),
            full_rate_capture: None,
        },
        Profile {
            name: "battery-saver".into(),
            refresh_rate: Some(72),
            cpu_level: Some(1),
            gpu_level: Some(1),
            texture_width: None,
            texture_height: None,
            guardian_pause: Some(0),
            full_rate_capture: None,
        },
        Profile {
            name: "high-refresh".into(),
            refresh_rate: Some(120),
            cpu_level: Some(3),
            gpu_level: Some(3),
            texture_width: None,
            texture_height: None,
            guardian_pause: Some(0),
            full_rate_capture: Some(1),
        },
    ]
}

fn profiles_path() -> Result<std::path::PathBuf> {
    Ok(crate::keys::config_dir()?.join("profiles.json"))
}

pub fn load_profiles() -> Result<HashMap<String, Profile>> {
    let mut map: HashMap<String, Profile> = builtin_profiles()
        .into_iter()
        .map(|p| (p.name.clone(), p))
        .collect();
    let path = profiles_path()?;
    if path.exists() {
        let text = std::fs::read_to_string(&path)?;
        let custom: HashMap<String, Profile> = serde_json::from_str(&text)?;
        map.extend(custom);
    }
    Ok(map)
}

/// Profiles for one headset model. Quest 1 drops high-refresh (it
/// only exists to push 120 Hz) and clamps every refresh rate to
/// 72 Hz, so applying a profile on a Quest 1 never fails the cap.
pub fn profiles_for(model: &str) -> Result<HashMap<String, Profile>> {
    let mut map = load_profiles()?;
    if crate::headset::classify(model, "").is_quest1() {
        map.remove("high-refresh");
        for p in map.values_mut() {
            if let Some(r) = p.refresh_rate {
                if r > 72 {
                    p.refresh_rate = Some(72);
                }
            }
        }
    }
    Ok(map)
}

pub fn save_profile(profile: &Profile) -> Result<()> {
    let path = profiles_path()?;
    let mut map: HashMap<String, Profile> = HashMap::new();
    if path.exists() {
        map = serde_json::from_str(&std::fs::read_to_string(&path)?)?;
    }
    map.insert(profile.name.clone(), profile.clone());
    std::fs::write(&path, serde_json::to_string_pretty(&map)?)?;
    Ok(())
}

pub struct AppliedProfile {
    pub applied: Vec<(String, String)>,
    pub warnings: Vec<String>,
}

pub fn apply_profile(
    t: &dyn AdbTransport,
    serial: &str,
    profile: &Profile,
    model: &str,
) -> Result<AppliedProfile> {
    let mut applied = Vec::new();
    let mut warnings = Vec::new();
    let mut set = |key: &str, value: String| -> Result<()> {
        let r = set_setting(t, serial, key, &value, model)?;
        applied.push((key.to_string(), value));
        if let Some(w) = r.warning {
            if !warnings.contains(&w) {
                warnings.push(w);
            }
        }
        Ok(())
    };
    if let Some(v) = profile.refresh_rate {
        set("debug.oculus.refreshRate", v.to_string())?;
    }
    if let Some(v) = profile.cpu_level {
        if v > 4 {
            return Err(Error("cpuLevel must be 0-4".into()));
        }
        set("debug.oculus.cpuLevel", v.to_string())?;
    }
    if let Some(v) = profile.gpu_level {
        if v > 4 {
            return Err(Error("gpuLevel must be 0-4".into()));
        }
        set("debug.oculus.gpuLevel", v.to_string())?;
    }
    if let Some(v) = profile.texture_width {
        set("debug.oculus.textureWidth", v.to_string())?;
    }
    if let Some(v) = profile.texture_height {
        set("debug.oculus.textureHeight", v.to_string())?;
    }
    if let Some(v) = profile.guardian_pause {
        set("debug.oculus.guardian_pause", v.to_string())?;
    }
    if let Some(v) = profile.full_rate_capture {
        set("debug.oculus.fullRateCapture", v.to_string())?;
    }
    Ok(AppliedProfile { applied, warnings })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quest1_caps_at_72() {
        assert_eq!(max_refresh_rate("Quest"), 72);
        assert_eq!(max_refresh_rate("Quest 2"), 120);
        assert_eq!(max_refresh_rate("Quest 3"), 207);
    }

    #[test]
    fn quest1_hides_quest3_only_keys() {
        let keys = allowed_keys("Quest");
        assert!(!keys.contains(&"debug.oculus.forceDisplayScaling"));
        assert!(!keys.contains(&"debug.oculus.experimentalEnabled"));
        assert!(keys.contains(&"debug.oculus.refreshRate"));
        assert!(allowed_keys("Quest 2").contains(&"debug.oculus.forceDisplayScaling"));
    }

    #[test]
    fn profiles_for_quest1_clamps_and_drops_high_refresh() {
        let map = profiles_for("Quest").unwrap();
        assert!(!map.contains_key("high-refresh"));
        assert_eq!(map["balanced"].refresh_rate, Some(72));
        assert_eq!(map["battery-saver"].refresh_rate, Some(72));
        let map2 = profiles_for("Quest 2").unwrap();
        assert!(map2.contains_key("high-refresh"));
        assert_eq!(map2["balanced"].refresh_rate, Some(90));
    }
}
