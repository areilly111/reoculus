//! WiVRn settings the user can change, from the WiVRn 26.9 source.
//!
//! Two places, two channels:
//! * Headset client settings live in `client.json` under the app's
//!   files dir (`/data/data/org.meumeu.wivrn/files/client.json`,
//!   or the `.github` package), a plain JSON object with
//!   snake_case keys (client/configuration.{h,cpp}). The client
//!   reads it at startup, so after writing it the client is
//!   force-stopped and the user reopens it. The headset is rooted,
//!   so `su -c` reads and writes the private files dir. The write
//!   goes through a base64 pipe (`echo .. | base64 -d | su -c 'cat
//!   > ...'`), which truncates the file in place and so keeps its
//!   owner and permissions. Unknown keys (the servers list, theme,
//!   etc.) are preserved: the file is read, the known keys are
//!   changed, and the whole object is written back.
//! * Server settings live in the PC config.json and are written by
//!   the existing `wivrn::write_config` (extended here with
//!   bit-depth and tcp-only, both top-level server keys per
//!   server/driver/configuration.cpp).
//!
//! What is NOT here: bitrate is headset-side, never a server key;
//! port/hostname are real server keys but changing them breaks the
//! headset's saved server entry, so they stay out of v1.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use serde::Serialize;

pub const WIVRN_PACKAGES: [&str; 2] = ["org.meumeu.wivrn", "org.meumeu.wivrn.github"];

fn client_json_path(package: &str) -> String {
    format!("/data/data/{package}/files/client.json")
}

fn shell(t: &dyn AdbTransport, serial: &str, cmd: &str) -> Result<String> {
    let out = t.shell(&Target::serial(serial), cmd)?;
    Ok(out.stdout)
}

fn package_installed(t: &dyn AdbTransport, serial: &str, package: &str) -> bool {
    shell(t, serial, &format!("pm list packages {package}"))
        .map(|s| s.contains(package))
        .unwrap_or(false)
}

/// The installed WiVRn client package, Store first.
pub fn client_package(t: &dyn AdbTransport, serial: &str) -> Option<String> {
    for pkg in WIVRN_PACKAGES {
        if package_installed(t, serial, pkg) {
            return Some(pkg.to_string());
        }
    }
    None
}

#[derive(Debug, Clone, Serialize)]
pub struct WivrnClientSettings {
    pub available: bool,
    pub package: String,
    pub note: String,
    /// Mbps, from bitrate_bps. Default 50.
    pub bitrate_mbps: u32,
    /// Render scale, 0.5-2.0. Default 1.2.
    pub resolution_scale: f32,
    /// 0 means Auto. Default 0.
    pub preferred_refresh_rate: f32,
    /// "auto" when the key is absent.
    pub codec: String,
    /// 8 or 10. Default 10.
    pub bit_depth: u8,
    pub passthrough_enabled: bool,
    pub override_foveation_enable: bool,
    pub high_power_mode: bool,
    pub forward_keyboard: bool,
    pub forward_mouse: bool,
    pub forward_gamepad: bool,
}

fn defaults(package: &str, available: bool, note: &str) -> WivrnClientSettings {
    WivrnClientSettings {
        available,
        package: package.to_string(),
        note: note.to_string(),
        bitrate_mbps: 50,
        resolution_scale: 1.2,
        preferred_refresh_rate: 0.0,
        codec: "auto".to_string(),
        bit_depth: 10,
        passthrough_enabled: false,
        override_foveation_enable: false,
        high_power_mode: true,
        forward_keyboard: false,
        forward_mouse: false,
        forward_gamepad: false,
    }
}

fn get_f(v: &serde_json::Value, key: &str) -> Option<f64> {
    v.get(key)?.as_f64()
}

fn get_b(v: &serde_json::Value, key: &str) -> Option<bool> {
    v.get(key)?.as_bool()
}

/// Read the headset's WiVRn client settings over adb. Missing file
/// means the client has never saved settings: defaults, with a
/// note, instead of an error.
pub fn read_client_settings(t: &dyn AdbTransport, serial: &str) -> Result<WivrnClientSettings> {
    let package = client_package(t, serial)
        .ok_or_else(|| Error("WiVRn is not installed on the headset yet.".into()))?;
    let path = client_json_path(&package);
    let text = shell(t, serial, &format!("su -c 'cat {path}'"))?;
    let text = text.trim();
    if text.is_empty() {
        return Ok(defaults(
            &package,
            false,
            "WiVRn has not saved settings on this headset yet. Open WiVRn on the headset once, then try again.",
        ));
    }
    let v: serde_json::Value = serde_json::from_str(text)
        .map_err(|e| Error(format!("WiVRn client.json is not valid JSON: {e}")))?;
    let mut s = defaults(&package, true, "");
    if let Some(bps) = get_f(&v, "bitrate_bps") {
        s.bitrate_mbps = (bps / 1_000_000.0).round() as u32;
    }
    if let Some(r) = get_f(&v, "resolution_scale") {
        s.resolution_scale = r as f32;
    }
    if let Some(r) = get_f(&v, "preferred_refresh_rate") {
        s.preferred_refresh_rate = r as f32;
    }
    if let Some(c) = v.get("codec").and_then(|c| c.as_str()) {
        s.codec = c.to_string();
    }
    if let Some(d) = get_f(&v, "bit_depth") {
        s.bit_depth = d as u8;
    }
    if let Some(b) = get_b(&v, "passthrough_enabled") {
        s.passthrough_enabled = b;
    }
    if let Some(b) = get_b(&v, "override_foveation_enable") {
        s.override_foveation_enable = b;
    }
    if let Some(b) = get_b(&v, "high_power_mode") {
        s.high_power_mode = b;
    }
    if let Some(b) = get_b(&v, "forward_keyboard") {
        s.forward_keyboard = b;
    }
    if let Some(b) = get_b(&v, "forward_mouse") {
        s.forward_mouse = b;
    }
    if let Some(b) = get_b(&v, "forward_gamepad") {
        s.forward_gamepad = b;
    }
    Ok(s)
}

/// One field of a settings write. Every field is optional: only
/// the ones given are changed, the rest keep their saved value.
#[derive(Debug, Default)]
pub struct ClientSettingsUpdate {
    pub bitrate_mbps: Option<u32>,
    pub resolution_scale: Option<f32>,
    pub preferred_refresh_rate: Option<f32>,
    /// "auto" clears the key; "h264"/"h265"/"av1" set it.
    pub codec: Option<String>,
    pub bit_depth: Option<u8>,
    pub passthrough_enabled: Option<bool>,
    pub override_foveation_enable: Option<bool>,
    pub high_power_mode: Option<bool>,
    pub forward_keyboard: Option<bool>,
    pub forward_mouse: Option<bool>,
    pub forward_gamepad: Option<bool>,
}

/// Parse an on/off word into a bool: on, true, 1, and yes are true;
/// off, false, 0, and no are false. Anything else is an error naming
/// the word given.
pub fn parse_on_off(s: &str) -> Result<bool> {
    match s.to_lowercase().as_str() {
        "on" | "true" | "1" | "yes" => Ok(true),
        "off" | "false" | "0" | "no" => Ok(false),
        _ => Err(Error(format!("'{s}' is not on or off."))),
    }
}

/// Write the given headset client settings over adb. Reads the
/// current file first so unknown keys survive, validates every
/// value, writes it back, verifies the write by reading it again,
/// and force-stops the client so the new settings are picked up
/// next time it opens.
pub fn write_client_settings(
    t: &dyn AdbTransport,
    serial: &str,
    update: &ClientSettingsUpdate,
) -> Result<String> {
    // Validate everything before touching the file.
    if let Some(m) = update.bitrate_mbps {
        if !(5..=150).contains(&m) {
            return Err(Error("Bitrate must be between 5 and 150 Mbps.".into()));
        }
    }
    if let Some(r) = update.resolution_scale {
        if !(0.5..=2.0).contains(&r) {
            return Err(Error("Resolution scale must be between 0.5 and 2.0.".into()));
        }
    }
    if let Some(r) = update.preferred_refresh_rate {
        if r != 0.0 && ![72.0, 80.0, 90.0, 120.0].contains(&r) {
            return Err(Error("Refresh rate must be Auto, 72, 80, 90 or 120 Hz.".into()));
        }
    }
    if let Some(c) = &update.codec {
        if !["auto", "h264", "h265", "av1"].contains(&c.as_str()) {
            return Err(Error("Codec must be Auto, H.264, H.265 or AV1.".into()));
        }
    }
    if let Some(d) = update.bit_depth {
        if d != 8 && d != 10 {
            return Err(Error("Bit depth must be 8 or 10.".into()));
        }
    }
    let package = client_package(t, serial)
        .ok_or_else(|| Error("WiVRn is not installed on the headset yet.".into()))?;
    let path = client_json_path(&package);
    let current = shell(t, serial, &format!("su -c 'cat {path}'"))?;
    let mut v: serde_json::Value = {
        let t = current.trim();
        if t.is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(t)
                .map_err(|e| Error(format!("WiVRn client.json is not valid JSON: {e}")))?
        }
    };
    let obj = v
        .as_object_mut()
        .ok_or_else(|| Error("WiVRn client.json is not a JSON object.".into()))?;
    if let Some(m) = update.bitrate_mbps {
        obj.insert(
            "bitrate_bps".to_string(),
            serde_json::json!(m as u64 * 1_000_000),
        );
    }
    if let Some(r) = update.resolution_scale {
        obj.insert("resolution_scale".to_string(), serde_json::json!(r));
    }
    if let Some(r) = update.preferred_refresh_rate {
        obj.insert("preferred_refresh_rate".to_string(), serde_json::json!(r));
    }
    if let Some(c) = &update.codec {
        if c == "auto" {
            obj.remove("codec");
        } else {
            obj.insert("codec".to_string(), serde_json::json!(c));
        }
    }
    if let Some(d) = update.bit_depth {
        obj.insert("bit_depth".to_string(), serde_json::json!(d));
    }
    for (key, val) in [
        ("passthrough_enabled", update.passthrough_enabled),
        ("override_foveation_enable", update.override_foveation_enable),
        ("high_power_mode", update.high_power_mode),
        ("forward_keyboard", update.forward_keyboard),
        ("forward_mouse", update.forward_mouse),
        ("forward_gamepad", update.forward_gamepad),
    ] {
        if let Some(b) = val {
            obj.insert(key.to_string(), serde_json::json!(b));
        }
    }
    let text = serde_json::to_string(&v).map_err(|e| Error(format!("could not write settings: {e}")))?;
    let b64 = B64.encode(text.as_bytes());
    let wrote = shell(
        t,
        serial,
        &format!("echo {b64} | base64 -d | su -c 'cat > {path}'"),
    )?;
    let _ = wrote;
    // Verify the write landed, then stop the client so it reads
    // the new file next time it opens. No auto-relaunch: with
    // autoconnect on, relaunching would start a VR session while
    // the headset sits unattended.
    let check = shell(t, serial, &format!("su -c 'cat {path}'"))?;
    let check_v: serde_json::Value = serde_json::from_str(check.trim())
        .map_err(|_| Error("Settings were written but the file could not be read back. Check WiVRn on the headset.".into()))?;
    if check_v != v {
        return Err(Error(
            "Settings were written but the file read back differently. Nothing was restarted.".into(),
        ));
    }
    let _ = shell(t, serial, &format!("am force-stop {package}"));
    Ok("Headset WiVRn settings saved. Open WiVRn on the headset to use them.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_on_off_cases() {
        assert!(parse_on_off("on").unwrap());
        assert!(!parse_on_off("off").unwrap());
        assert!(!parse_on_off("false").unwrap());
        assert!(parse_on_off("maybe").is_err());
    }

    #[test]
    fn client_settings_defaults_from_empty() {
        let v: serde_json::Value = serde_json::json!({});
        let mut s = defaults("org.meumeu.wivrn", true, "");
        if let Some(bps) = get_f(&v, "bitrate_bps") {
            s.bitrate_mbps = (bps / 1_000_000.0).round() as u32;
        }
        assert_eq!(s.bitrate_mbps, 50);
        assert_eq!(s.resolution_scale, 1.2);
        assert_eq!(s.codec, "auto");
        assert_eq!(s.bit_depth, 10);
        assert!(s.high_power_mode);
    }
}
