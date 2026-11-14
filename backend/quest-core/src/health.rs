//! Battery and health dashboard: battery, storage, uptime and the
//! date of the newest device backup for this headset. All read-only.
//!
//! Battery temperature comes from `dumpsys battery` (already the
//! only temperature the headset reports over adb); nothing here
//! reads the controller batteries, which are not readable offline.

use crate::devices::{device_info, parse_battery, parse_df, BatteryInfo, StorageInfo};
use crate::device_backup::list_device_backups;
use crate::error::Result;
use crate::transport::{AdbTransport, Target};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct HealthInfo {
    pub serial: String,
    pub model: Option<String>,
    pub firmware: Option<String>,
    pub battery: BatteryInfo,
    pub storage_sdcard: StorageInfo,
    pub storage_data: StorageInfo,
    pub uptime_seconds: Option<u64>,
    pub uptime: Option<String>,
    /// Date of the newest device backup for this headset, if any.
    pub last_backup: Option<String>,
}

/// Parse `/proc/uptime`: `123456.78 98765.43` (seconds idle first).
pub fn parse_uptime(text: &str) -> Option<u64> {
    text.split_whitespace()
        .next()
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse::<u64>().ok())
}

/// Plain-language uptime: "3 days 4 hours", "45 minutes", "20 seconds".
pub fn format_uptime(secs: u64) -> String {
    let days = secs / 86400;
    let hours = (secs % 86400) / 3600;
    let minutes = (secs % 3600) / 60;
    let seconds = secs % 60;
    if days > 0 {
        format!("{days} day{} {hours} hour{}", if days == 1 { "" } else { "s" }, if hours == 1 { "" } else { "s" })
    } else if hours > 0 {
        format!("{hours} hour{} {minutes} minute{}", if hours == 1 { "" } else { "s" }, if minutes == 1 { "" } else { "s" })
    } else if minutes > 0 {
        format!("{minutes} minute{} {seconds} second{}", if minutes == 1 { "" } else { "s" }, if seconds == 1 { "" } else { "s" })
    } else {
        format!("{seconds} second{}", if seconds == 1 { "" } else { "s" })
    }
}

/// Headset health in one call: battery, storage on /data, uptime, and
/// the device info from `device_info`. The battery reading is shared
/// with `device_info`, not read twice.
pub fn health(t: &dyn AdbTransport, serial: &str) -> Result<HealthInfo> {
    let target = Target::serial(serial);
    let info = device_info(t, serial)?;
    let storage_data = t
        .shell(&target, "df /data")
        .map(|o| {
            let mut s = parse_df(&o.stdout);
            s.mount = "/data".into();
            s
        })
        .unwrap_or_else(|_| StorageInfo {
            total_kb: None,
            used_kb: None,
            free_kb: None,
            mount: "/data".into(),
        });
    // `dumpsys battery` was already read by device_info; parse_df
    // needs a fresh battery read only if device_info failed, which
    // it did not (the `?` above). Keep battery from device_info.
    let uptime_seconds = t
        .shell(&target, "cat /proc/uptime")
        .ok()
        .and_then(|o| parse_uptime(&o.stdout));
    let uptime = uptime_seconds.map(format_uptime);
    // Record a battery sample for the history kept on this
    // computer. Best effort: a failure here never breaks health.
    if let Some(level) = info.battery.level {
        let charging = info.battery.status.as_deref() == Some("charging")
            || info.battery.status.as_deref() == Some("full")
            || info.battery.plugged.is_some();
        crate::battery_history::record_sample(serial, level, charging);
    }
    let last_backup = list_device_backups()
        .ok()
        .and_then(|entries| {
            entries
                .into_iter()
                .find(|e| e.serial == serial)
                .map(|e| e.backup_date)
        });
    Ok(HealthInfo {
        serial: serial.to_string(),
        model: info.model,
        firmware: info.firmware,
        battery: info.battery,
        storage_sdcard: info.storage,
        storage_data,
        uptime_seconds,
        uptime,
        last_backup,
    })
}

/// Re-exported so other modules can read the battery without
/// re-parsing; thin wrapper around devices::parse_battery.
pub fn battery_from_dumpsys(text: &str) -> BatteryInfo {
    parse_battery(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uptime_parses() {
        assert_eq!(parse_uptime("123456.78 98765.43\n"), Some(123456));
        assert_eq!(parse_uptime(""), None);
        assert_eq!(parse_uptime("garbage\n"), None);
    }

    #[test]
    fn uptime_formats() {
        assert_eq!(format_uptime(20), "20 seconds");
        assert_eq!(format_uptime(60), "1 minute 0 seconds");
        assert_eq!(format_uptime(3661), "1 hour 1 minute");
        assert_eq!(format_uptime(90061), "1 day 1 hour");
        assert_eq!(format_uptime(172800), "2 days 0 hours");
    }
}
