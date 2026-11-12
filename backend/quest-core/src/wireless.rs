//! Wireless setup, root detection, and the known-wireless-device store.
//!
//! Quest 2 is the first-class target here (Android 14, Horizon OS,
//! rooted with Singularity/Magisk on the owner's headset). Everything
//! in this module is plain `adb` / shell: no Meta account, no Meta
//! server, nothing that stops working when Meta ends Quest 2 feature
//! updates (Horizon OS v2.13, March 2027).

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Parse a Wi-Fi IP out of `ip addr show wlan0` output:
/// `    inet 192.168.1.45/24 brd ... scope global wlan0`.
/// Also accepts `ip route get 1.1.1.1` output (`... src 1.2.3.4 ...`)
/// and `getprop dhcp.wlan0.ipaddress` output (a bare IP).
pub fn parse_wifi_ip(text: &str) -> Option<String> {
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("inet ") {
            if let Some(ip) = rest.split('/').next() {
                let ip = ip.trim();
                if !ip.starts_with("127.") && ip.contains('.') {
                    return Some(ip.to_string());
                }
            }
        }
        // `ip route get` form: `... src 192.168.1.42 uid ...`
        let cols: Vec<&str> = line.split_whitespace().collect();
        for w in cols.windows(2) {
            if w[0] == "src" && !w[1].starts_with("127.") && w[1].contains('.') {
                return Some(w[1].to_string());
            }
        }
        // Bare getprop output.
        if line.chars().filter(|c| *c == '.').count() == 3
            && line.chars().all(|c| c.is_ascii_digit() || c == '.')
            && !line.starts_with("127.")
        {
            return Some(line.to_string());
        }
    }
    None
}

/// The headset's Wi-Fi IP, trying `ip addr show wlan0`, then
/// `ip route get`, then the dhcp getprop. Returns None (not an
/// error) when the headset is not on Wi-Fi.
pub fn wifi_ip(t: &dyn AdbTransport, serial: &str) -> Option<String> {
    let target = Target::serial(serial);
    for cmd in [
        "ip addr show wlan0",
        "ip route get 1.1.1.1",
        "getprop dhcp.wlan0.ipaddress",
    ] {
        if let Ok(o) = t.shell(&target, cmd) {
            if let Some(ip) = parse_wifi_ip(&o.stdout) {
                return Some(ip);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Root detection
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct RootStatus {
    pub rooted: bool,
    /// Plain-language method, e.g. "Magisk (su works)".
    pub method: String,
    pub su_present: bool,
    pub magisk_present: bool,
    /// Singularity / Magisk app installed (package present).
    pub singularity_present: bool,
}

/// Detect root on the headset, read-only. Checks, in order:
/// `su -c id` prints uid=0 (the real test), `which su`,
/// Magisk files (`/sbin/.magisk`, `magisk --version`), and the
/// Singularity / Magisk apps being installed. Never flashes,
/// re-roots, or touches the bootloader.
pub fn root_status(t: &dyn AdbTransport, serial: &str) -> RootStatus {
    let target = Target::serial(serial);
    let su_works = t
        .shell(&target, "su -c id")
        .map(|o| o.stdout.contains("uid=0"))
        .unwrap_or(false);
    let su_present = t
        .shell(&target, "which su")
        .map(|o| !o.stdout.trim().is_empty())
        .unwrap_or(false);
    // Magisk: `magisk -v` prints e.g. `1db2ceaf:MAGISK:D` when the
    // daemon runs. It must go through su: the shell user cannot see
    // /sbin/.magisk or /data/adb. The Magisk app package is a second
    // signal (Singularity installs it as com.singularity.magisk).
    let magisk_present = t
        .shell(&target, "su -c \"magisk -v\"")
        .map(|o| o.stdout.contains("MAGISK"))
        .unwrap_or(false)
        || t
            .shell(&target, "ls /sbin/.magisk 2>/dev/null; magisk --version 2>/dev/null")
            .map(|o| !o.stdout.trim().is_empty())
            .unwrap_or(false)
        || t
            .shell(&target, "pm list packages com.singularity.magisk")
            .map(|o| o.stdout.contains("com.singularity.magisk"))
            .unwrap_or(false);
    let singularity_present = t
        .shell(&target, "pm list packages com.lumi.singularity com.singularity.magisk")
        .map(|o| o.stdout.contains("com.lumi.singularity") || o.stdout.contains("com.singularity.magisk"))
        .unwrap_or(false);
    let method = if su_works && magisk_present {
        "Magisk (su works)".to_string()
    } else if su_works {
        "Root via su".to_string()
    } else if magisk_present || singularity_present {
        "Magisk app present, but su did not answer (root may need granting in the Magisk app)".to_string()
    } else {
        "Not rooted".to_string()
    };
    RootStatus {
        rooted: su_works,
        method,
        su_present,
        magisk_present,
        singularity_present,
    }
}

// ---------------------------------------------------------------------------
// Automatic wireless setup
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct WifiSetup {
    /// The headset's Wi-Fi IP that was connected to.
    pub ip: Option<String>,
    /// The wireless serial as adb sees it, e.g. "192.168.1.42:5555".
    pub wireless_serial: Option<String>,
    /// True when the wireless device is in `adb devices`.
    pub connected: bool,
    pub steps: Vec<String>,
    /// Quiet note for the UI when it did not work (USB still works).
    pub note: Option<String>,
}

/// Set up wireless ADB automatically after a USB connection:
/// find the Wi-Fi IP, `adb tcpip 5555`, `adb connect <ip>:5555`,
/// verify the wireless device appears. This is the legacy wireless
/// flow: it needs no pairing code on the Quest, and it is what the
/// Quest 2 offers. (The modern TLS flow with a 6-digit code is the
/// `devices connect-wifi --code` path, used from the Wi-Fi dialog
/// when the headset asks for it.)
///
/// Never fails hard: on any failure it returns `connected: false`
/// with a quiet note, and USB keeps working. The caller decides
/// whether to save the IP (only on success).
pub fn setup_wifi(t: &dyn AdbTransport, serial: &str) -> WifiSetup {
    let mut steps: Vec<String> = Vec::new();
    let fail = |steps: Vec<String>, note: &str| WifiSetup {
        ip: None,
        wireless_serial: None,
        connected: false,
        steps,
        note: Some(note.to_string()),
    };
    let Some(ip) = wifi_ip(t, serial) else {
        return fail(
            steps,
            "Wi-Fi setup did not work this time: the headset has no Wi-Fi IP (is it on Wi-Fi?). USB still works.",
        );
    };
    steps.push(format!("Headset Wi-Fi IP is {ip}"));
    let target = Target::serial(serial);
    if let Err(e) = t.tcpip(&target, 5555) {
        return fail(
            steps,
            &format!("Wi-Fi setup did not work this time: adb tcpip 5555 was refused ({e}). USB still works."),
        );
    }
    steps.push("Enabled wireless ADB on port 5555".to_string());
    match t.connect_tcp(&ip, 5555) {
        Ok(_) => {
            steps.push(format!("Connected to {ip}:5555"));
        }
        Err(e) => {
            return fail(
                steps,
                &format!("Wi-Fi setup did not work this time: could not connect to {ip}:5555 ({e}). USB still works."),
            );
        }
    }
    let serial_wifi = format!("{ip}:5555");
    let connected = t
        .list_devices()
        .map(|ds| ds.iter().any(|d| d.serial == serial_wifi))
        .unwrap_or(false);
    if connected {
        WifiSetup {
            ip: Some(ip),
            wireless_serial: Some(serial_wifi),
            connected: true,
            steps,
            note: None,
        }
    } else {
        fail(
            steps,
            "Wi-Fi setup did not work this time: the wireless device did not appear in adb devices. USB still works.",
        )
    }
}

// ---------------------------------------------------------------------------
// Known wireless devices (saved IPs, so the next launch can try
// `adb connect <saved-ip>:5555` before showing "No headset").
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnownWireless {
    /// The USB serial the IP was learned from.
    pub serial: String,
    pub ip: String,
    pub port: u16,
    pub last_seen: String,
}

fn config_dir() -> Result<PathBuf> {
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() {
            return Ok(PathBuf::from(x).join("quest-companion"));
        }
    }
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate config dir".into()))?;
    Ok(PathBuf::from(home).join(".config").join("quest-companion"))
}

fn known_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("known-wireless.json"))
}

pub fn load_known_wireless() -> Vec<KnownWireless> {
    let Ok(path) = known_path() else { return vec![] };
    let Ok(text) = std::fs::read_to_string(path) else { return vec![] };
    serde_json::from_str(&text).unwrap_or_default()
}

pub fn save_known_wireless(serial: &str, ip: &str, port: u16) -> Result<()> {
    let dir = config_dir()?;
    std::fs::create_dir_all(&dir)?;
    let mut list = load_known_wireless();
    list.retain(|k| k.serial != serial && k.ip != ip);
    let now = crate::backup::format_unix_time(crate::backup::now_unix());
    list.insert(0, KnownWireless {
        serial: serial.to_string(),
        ip: ip.to_string(),
        port,
        last_seen: now,
    });
    list.truncate(5);
    std::fs::write(known_path()?, serde_json::to_string_pretty(&list)?)?;
    Ok(())
}

/// Try the saved wireless IPs (newest first) when no USB device is
/// present. Returns the IPs that are now connected.
pub fn try_saved_wireless(t: &dyn AdbTransport) -> Vec<String> {
    let mut connected = Vec::new();
    for k in load_known_wireless() {
        if t.connect_tcp(&k.ip, k.port).is_ok() {
            connected.push(format!("{}:{}", k.ip, k.port));
        }
    }
    connected
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wifi_ip_from_ip_addr() {
        let text = "3: wlan0: <UP> mtu 1500\n    inet 192.168.1.45/24 brd 192.168.1.255 scope global wlan0\n    inet6 fe80::1/64 scope link";
        assert_eq!(parse_wifi_ip(text).as_deref(), Some("192.168.1.45"));
    }

    #[test]
    fn wifi_ip_from_route_and_getprop() {
        assert_eq!(
            parse_wifi_ip("1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.45 uid 0").as_deref(),
            Some("192.168.1.45")
        );
        assert_eq!(parse_wifi_ip("192.168.1.45\n").as_deref(), Some("192.168.1.45"));
        assert_eq!(parse_wifi_ip("127.0.0.1\n"), None);
        assert_eq!(parse_wifi_ip(""), None);
    }
}
