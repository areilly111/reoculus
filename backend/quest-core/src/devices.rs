//! Device discovery and device info, built from `getprop` / `dumpsys
//! battery` / `df` / `wm size`. No Meta API, no account.

use crate::error::Result;
use crate::transport::{AdbTransport, Device, Target};
use serde::Serialize;
use std::collections::HashMap;

pub fn list_devices(t: &dyn AdbTransport) -> Result<Vec<Device>> {
    t.list_devices()
}

#[derive(Debug, Clone, Serialize)]
pub struct BatteryInfo {
    pub level: Option<i32>,
    pub health: Option<String>,
    pub temperature_c: Option<f32>,
    pub voltage_mv: Option<i32>,
    pub status: Option<String>,
    pub plugged: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StorageInfo {
    pub total_kb: Option<u64>,
    pub used_kb: Option<u64>,
    pub free_kb: Option<u64>,
    pub mount: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceInfo {
    pub serial: String,
    pub model: Option<String>,
    /// Device codename from `ro.product.device` (`monterey`, `hollywood`, ...).
    pub device: Option<String>,
    /// Classified headset (`quest1`, `quest2`, `quest3`, `quest3s`, `questpro`, `unknown`).
    pub headset_model: String,
    /// False on Quest 1: Singularity only supports Quest 2, Pro, 3, 3S.
    pub supports_singularity: bool,
    /// False on Quest 1: Quest Home Switcher only lists Quest 2 / 3 / 3S.
    pub supports_home_switcher: bool,
    pub android_version: Option<String>,
    pub firmware: Option<String>,
    pub cpu_abi: Option<String>,
    pub battery: BatteryInfo,
    pub storage: StorageInfo,
    pub resolution: Option<String>,
    pub density: Option<i32>,
}

/// Light headset classification: one `getprop` dump, no battery/df/wm
/// calls. Used where only the model matters (mirror codec, home apps,
/// Singularity install gate).
pub fn headset_of(t: &dyn AdbTransport, serial: &str) -> crate::headset::Headset {
    let target = Target::serial(serial);
    let props = match t.shell(&target, "getprop") {
        Ok(o) => parse_getprop(&o.stdout),
        Err(_) => HashMap::new(),
    };
    crate::headset::classify(
        props.get("ro.product.model").map(|s| s.as_str()).unwrap_or(""),
        props.get("ro.product.device").map(|s| s.as_str()).unwrap_or(""),
    )
}

/// Parse `getprop` output: lines like `[ro.product.model]: [Quest 3]`.
pub fn parse_getprop(text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix('[') {
            if let Some((k, v)) = rest.split_once("]: [") {
                if let Some(v) = v.strip_suffix(']') {
                    map.insert(k.to_string(), v.to_string());
                }
            }
        }
    }
    map
}

/// Parse `dumpsys battery` output.
pub fn parse_battery(text: &str) -> BatteryInfo {
    let mut b = BatteryInfo {
        level: None,
        health: None,
        temperature_c: None,
        voltage_mv: None,
        status: None,
        plugged: None,
    };
    for line in text.lines() {
        let line = line.trim();
        let (k, v) = match line.split_once(':') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => continue,
        };
        match k {
            "level" => b.level = v.parse().ok(),
            "health" => b.health = Some(map_battery_health(v)),
            "temperature" => {
                if let Ok(t) = v.parse::<i32>() {
                    b.temperature_c = Some(t as f32 / 10.0);
                }
            }
            "voltage" => b.voltage_mv = v.parse().ok(),
            "status" => b.status = Some(map_battery_status(v)),
            "AC powered" | "USB powered" | "Wireless powered" if v == "true" => {
                b.plugged = Some(k.to_string())
            }
            _ => {}
        }
    }
    b
}

fn map_battery_health(v: &str) -> String {
    match v {
        "2" => "good".into(),
        "3" => "overheat".into(),
        "4" => "dead".into(),
        "5" => "over voltage".into(),
        "6" => "unspecified failure".into(),
        "7" => "cold".into(),
        other => other.to_string(),
    }
}

fn map_battery_status(v: &str) -> String {
    match v {
        "1" => "unknown".into(),
        "2" => "charging".into(),
        "3" => "discharging".into(),
        "4" => "not charging".into(),
        "5" => "full".into(),
        other => other.to_string(),
    }
}

/// Parse `df /sdcard` output (1K blocks).
pub fn parse_df(text: &str) -> StorageInfo {
    let mut s = StorageInfo {
        total_kb: None,
        used_kb: None,
        free_kb: None,
        mount: "/sdcard".into(),
    };
    for line in text.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 6 && cols[0] != "Filesystem" {
            s.total_kb = cols[1].parse().ok();
            s.used_kb = cols[2].parse().ok();
            s.free_kb = cols[3].parse().ok();
            s.mount = cols[5].to_string();
            break;
        }
    }
    s
}

/// Parse `wm size` output: `Physical size: 1832x1920`.
pub fn parse_wm_size(text: &str) -> Option<String> {
    for line in text.lines() {
        if let Some(rest) = line.trim().strip_prefix("Physical size:") {
            return Some(rest.trim().to_string());
        }
    }
    None
}

/// Parse `wm density` output: `Physical density: 538`.
pub fn parse_wm_density(text: &str) -> Option<i32> {
    for line in text.lines() {
        if let Some(rest) = line.trim().strip_prefix("Physical density:") {
            return rest.trim().parse().ok();
        }
    }
    None
}

pub fn device_info(t: &dyn AdbTransport, serial: &str) -> Result<DeviceInfo> {
    let target = Target::serial(serial);
    let props = parse_getprop(&t.shell(&target, "getprop")?.stdout);
    let battery = parse_battery(&t.shell(&target, "dumpsys battery")?.stdout);
    let storage = parse_df(&t.shell(&target, "df /sdcard")?.stdout);
    let resolution = parse_wm_size(&t.shell(&target, "wm size")?.stdout);
    let density = parse_wm_density(&t.shell(&target, "wm density")?.stdout);
    let headset = crate::headset::classify(
        props.get("ro.product.model").map(|s| s.as_str()).unwrap_or(""),
        props.get("ro.product.device").map(|s| s.as_str()).unwrap_or(""),
    );
    Ok(DeviceInfo {
        serial: serial.to_string(),
        model: props.get("ro.product.model").cloned(),
        device: props.get("ro.product.device").cloned(),
        headset_model: headset.slug().to_string(),
        supports_singularity: headset.supports_singularity(),
        supports_home_switcher: headset.supports_home_switcher(),
        android_version: props.get("ro.build.version.release").cloned(),
        firmware: props.get("ro.build.version.incremental").cloned(),
        cpu_abi: props.get("ro.product.cpu.abi").cloned(),
        battery,
        storage,
        resolution,
        density,
    })
}

// ---------------------------------------------------------------------------
// Controllers
//
// Checked live on the owner's Quest 2 (2026-11-12): `dumpsys input`
// lists NO input devices at all, even with both controllers awake
// in his hands, and /proc/bus/input/devices only has the power
// button, gpio-keys and the headphone jack. The Touch controllers
// are NOT Android input devices. They appear only in `getevent -l`
// as dynamic devices named "Device 0x<hex>" (two of them, one per
// controller), and they vanish again when they sleep. So this reads
// `timeout 3 getevent -l` and counts "Device 0x..." entries.
// Battery level and firmware version are still NOT readable
// offline via adb (no dumpsys service reports them); this reports
// presence only, and says plainly what it cannot read.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct ControllerInfo {
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ControllersInfo {
    pub controllers: Vec<ControllerInfo>,
    pub count: usize,
    /// Plain-language note about what is and is not readable.
    pub note: String,
    /// True when the listed controllers are not awake right now:
    /// they are the last ones seen, not the ones awake. The card
    /// says so, so a sleeping controller never looks missing.
    pub asleep: bool,
    /// When the listed controllers were last seen awake, plain
    /// "YYYY-MM-DD HH:MM:SS" (UTC), or null when never seen.
    pub last_seen: Option<String>,
}

pub const CONTROLLER_NOTE: &str = "Touch controllers show up in getevent as 'Device 0x...' entries (one per controller); left and right cannot be told apart from adb, and battery level and firmware version are not readable offline via adb. Check battery in the headset (quick settings shows the controller batteries).";

/// Parse `getevent -l` output for Touch controllers: lines like
/// `  name:     "Device 0x96E85D950440DA86"` (one per controller).
/// Also accepts the older `dumpsys input` form
/// `Device 3: Oculus Touch Controller - Left` as a fallback.
/// Deduplicated, in first-seen order.
pub fn parse_controllers(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        let lower = t.to_lowercase();
        // getevent -l form: name: "Device 0x<hex>"
        if lower.starts_with("name:") && lower.contains("device 0x") {
            let name = t
                .split_once(':')
                .map(|(_, rest)| rest.trim().trim_matches('"').trim().to_string())
                .unwrap_or_default();
            if !name.is_empty() && !out.contains(&name) {
                out.push(format!("Touch Controller ({name})"));
            }
            continue;
        }
        if lower.contains("controller") && !lower.contains("batterycontroller") && !lower.contains("kbdbacklight") {
            let name = t
                .split_once(':')
                .map(|(_, rest)| rest.trim())
                .filter(|r| !r.is_empty())
                .unwrap_or(t);
            let name = name.trim().to_string();
            let lower_name = name.to_lowercase();
            if (lower_name.contains("controller") || lower_name.contains("touch"))
                && !name.is_empty()
                && !out.contains(&name)
            {
                out.push(name);
            }
        }
    }
    out
}

pub fn controllers(t: &dyn AdbTransport, serial: &str) -> Result<ControllersInfo> {
    let target = Target::serial(serial);
    // getevent -l streams forever; timeout 3 s captures the device
    // list (the "add device" lines) then kills it.
    let names = match t.shell(&target, "timeout 3 getevent -l") {
        Ok(o) => parse_controllers(&o.stdout),
        Err(_) => Vec::new(),
    };
    let names = if names.is_empty() {
        // Fallback: older firmware / named devices via dumpsys input.
        match t.shell(&target, "dumpsys input") {
            Ok(o) => parse_controllers(&o.stdout),
            Err(_) => Vec::new(),
        }
    } else {
        names
    };
    if !names.is_empty() {
        // Awake right now: remember them, so the next check (when
        // they have slept, seconds later) can still show them.
        save_last_seen(serial, &names);
        let controllers = names.into_iter().map(|name| ControllerInfo { name }).collect::<Vec<_>>();
        let count = controllers.len();
        return Ok(ControllersInfo {
            controllers,
            count,
            note: CONTROLLER_NOTE.to_string(),
            asleep: false,
            last_seen: None,
        });
    }
    // Nothing awake. Show the last ones seen, marked asleep, so the
    // card never looks broken just because both controllers slept.
    if let Some((seen_names, seen_at)) = read_last_seen(serial) {
        let controllers = seen_names
            .into_iter()
            .map(|name| ControllerInfo { name })
            .collect::<Vec<_>>();
        let count = controllers.len();
        return Ok(ControllersInfo {
            controllers,
            count,
            note: CONTROLLER_NOTE.to_string(),
            asleep: true,
            last_seen: Some(crate::backup::format_unix_time(seen_at)),
        });
    }
    Ok(ControllersInfo {
        controllers: Vec::new(),
        count: 0,
        note: CONTROLLER_NOTE.to_string(),
        asleep: false,
        last_seen: None,
    })
}

/// Last-seen controllers, kept on this computer (never on the
/// headset) at `~/.cache/quest-companion/controllers-last-seen-<serial>.json`.
fn last_seen_path(serial: &str) -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let safe: String = serial
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    Some(
        std::path::PathBuf::from(home)
            .join(".cache")
            .join("quest-companion")
            .join(format!("controllers-last-seen-{safe}.json")),
    )
}

fn save_last_seen(serial: &str, names: &[String]) {
    let Some(path) = last_seen_path(serial) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let text = serde_json::json!({
        "serial": serial,
        "controllers": names,
        "seen_at": now,
    })
    .to_string();
    let _ = std::fs::write(path, text);
}

fn read_last_seen(serial: &str) -> Option<(Vec<String>, u64)> {
    let path = last_seen_path(serial)?;
    let text = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let names: Vec<String> = v
        .get("controllers")?
        .as_array()?
        .iter()
        .filter_map(|x| x.as_str().map(|s| s.to_string()))
        .collect();
    let seen_at = v.get("seen_at")?.as_u64()?;
    if names.is_empty() {
        return None;
    }
    Some((names, seen_at))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controllers_parse_dedupes() {
        let text = "add device 4: /dev/input/event3\n  name:     \"Device 0x96E85D950440DA86\"\nadd device 5: /dev/input/event4\n  name:     \"Device 0x1B08E898EA1F1CEA\"\nadd device 1: /dev/input/event2\n  name:     \"kona-cm710x-snd-card AK4331 Headphone\"";
        let names = parse_controllers(text);
        assert_eq!(names.len(), 2);
        assert!(names.iter().any(|n| n.contains("0x96E85D950440DA86")));
        assert!(names.iter().any(|n| n.contains("0x1B08E898EA1F1CEA")));
        assert!(!names.iter().any(|n| n.contains("Headphone")));
    }
}
