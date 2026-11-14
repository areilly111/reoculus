//! Battery and usage history for the Headset Health section.
//!
//! Two honest sources, and one clear limit:
//! - The headset's own battery level is read live
//!   (`dumpsys battery`).
//! - The app records a battery sample on this computer every
//!   time it checks the headset's health, so a history builds
//!   up over days of use. It can only see the headset while it
//!   is connected, so the first days are sparse.
//! - Most-used apps come from the headset's own usage stats
//!   (`dumpsys usagestats`, last-24-hours event log): total time
//!   in the foreground and when each app was last used. The
//!   headset keeps this even when the PC is not watching.
//!
//! Nothing here reads the controller batteries: they are not
//! readable offline via adb.

use crate::devices::{parse_battery, BatteryInfo};
use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_SAMPLES: usize = 500;
/// Record a new sample at most this often, unless the level moved
/// a lot or the charging state flipped.
const MIN_SECONDS_BETWEEN_SAMPLES: i64 = 1800;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatterySample {
    pub time: i64,
    pub level: i32,
    pub charging: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct AppUsage {
    pub package: String,
    pub total_foreground_ms: u64,
    pub last_used_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BatteryHistory {
    pub serial: String,
    pub battery: BatteryInfo,
    pub samples: Vec<BatterySample>,
    pub top_apps: Vec<AppUsage>,
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn data_dir() -> Result<PathBuf> {
    if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() {
            return Ok(PathBuf::from(x).join("quest-companion"));
        }
    }
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate data dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("share")
        .join("quest-companion"))
}

fn history_path(serial: &str) -> Result<PathBuf> {
    Ok(data_dir()?.join(format!("battery-history-{}.json", sanitize(serial))))
}

/// Load the saved battery samples from a JSON file on this computer.
/// Returns an empty list (not an error) when the file is missing or
/// unreadable, so a fresh install just starts with no history.
pub fn load_samples(path: &PathBuf) -> Vec<BatterySample> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_samples(path: &PathBuf, samples: &[BatterySample]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error(e.to_string()))?;
    }
    let text =
        serde_json::to_string_pretty(samples).map_err(|e| Error(e.to_string()))?;
    std::fs::write(path, text).map_err(|e| Error(e.to_string()))?;
    Ok(())
}

/// Should a new sample be recorded after `last`? Yes when there is
/// no last sample, when enough time passed, when the level moved
/// by 2 or more, or when charging flipped.
pub fn should_record(last: Option<&BatterySample>, time: i64, level: i32, charging: bool) -> bool {
    let Some(last) = last else {
        return true;
    };
    if time - last.time >= MIN_SECONDS_BETWEEN_SAMPLES {
        return true;
    }
    if (level - last.level).abs() >= 2 {
        return true;
    }
    if charging != last.charging {
        return true;
    }
    false
}

/// Best effort: a failure here must never break the health check
/// that called it, so errors are swallowed.
pub fn record_sample(serial: &str, level: i32, charging: bool) {
    let Ok(path) = history_path(serial) else {
        return;
    };
    let mut samples = load_samples(&path);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    if !should_record(samples.last(), now, level, charging) {
        return;
    }
    samples.push(BatterySample {
        time: now,
        level,
        charging,
    });
    if samples.len() > MAX_SAMPLES {
        let drop = samples.len() - MAX_SAMPLES;
        samples.drain(..drop);
    }
    let _ = save_samples(&path, &samples);
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's
/// algorithm), so wall times from the headset convert to epoch
/// seconds without a date library.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Parse a wall time from the event log, `2026-11-11 17:33:38`,
/// as epoch seconds pretending it is UTC. The caller adds the
/// headset's UTC offset (from `date`) to get real epoch seconds.
fn parse_wall_time(s: &str) -> Option<i64> {
    let (date, time) = s.split_once(' ')?;
    let mut d = date.split('-');
    let y: i64 = d.next()?.parse().ok()?;
    let m: i64 = d.next()?.parse().ok()?;
    let day: i64 = d.next()?.parse().ok()?;
    let mut t = time.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let min: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.parse().ok()?;
    Some(days_from_civil(y, m, day) * 86400 + h * 3600 + min * 60 + sec)
}

/// Parse one `date "+%s %Y-%m-%d %H:%M:%S"` line from the headset,
/// `1794522526 2026-11-12 17:28:46`, into (now epoch, UTC offset in
/// seconds). The offset turns event wall times into real epoch
/// seconds; without it, durations are still right but last-used
/// times render hours off.
pub fn parse_date_line(line: &str) -> Option<(i64, i64)> {
    let line = line.trim();
    let (epoch, wall) = line.split_once(' ')?;
    let epoch: i64 = epoch.trim().parse().ok()?;
    let wall = parse_wall_time(wall.trim())?;
    Some((epoch, epoch - wall))
}

fn event_field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    for part in line.split_whitespace() {
        if let Some(v) = part.strip_prefix(key) {
            return Some(v.trim_matches('"'));
        }
    }
    None
}

/// The time value is quoted and holds a space
/// (`time="2026-11-11 17:33:38"`), so splitting on whitespace
/// breaks it; take everything between the quotes instead.
fn event_time(line: &str) -> Option<&str> {
    let start = line.find("time=\"")? + 6;
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

/// Parse the "Last 24 hour events" section of `dumpsys usagestats`.
/// Event lines look like:
/// `    time="2026-11-11 17:33:38" type=ACTIVITY_RESUMED package=com.foo.bar class=...`
/// Foreground time per package is summed from ACTIVITY_RESUMED to
/// the matching ACTIVITY_PAUSED / STOPPED / DESTROYED, counting
/// overlapping activities of one package once (a counter, not a
/// single open interval). `last_used_ms` is the last RESUMED time.
/// Parsing stops at the next section (the dump goes on to longer
/// ranges), and anything that does not look like an event line is
/// skipped, so a format change gives an empty list instead of a
/// wrong one. `offset_seconds` comes from `parse_date_line`;
/// `now_epoch` closes intervals still open at the end.
pub fn parse_usagestats(text: &str, offset_seconds: i64, now_epoch: i64) -> Vec<AppUsage> {
    struct Open {
        count: u32,
        start: i64,
        total_ms: u64,
        last_resumed_ms: Option<u64>,
    }
    let mut apps: std::collections::HashMap<String, Open> = std::collections::HashMap::new();
    let mut in_section = false;
    for line in text.lines() {
        if !in_section {
            if line.contains("Last 24 hour events") {
                in_section = true;
            }
            continue;
        }
        // Section headers start with two spaces; event lines with
        // four. A two-space line ends this section.
        if line.starts_with("  ") && !line.starts_with("    ") {
            break;
        }
        if !line.starts_with("    time=") {
            continue;
        }
        let Some(time) = event_time(line) else {
            continue;
        };
        let Some(t) = parse_wall_time(time).map(|w| w + offset_seconds) else {
            continue;
        };
        let Some(kind) = event_field(line, "type=") else {
            continue;
        };
        let Some(package) = event_field(line, "package=") else {
            continue;
        };
        match kind {
            "ACTIVITY_RESUMED" => {
                let e = apps.entry(package.to_string()).or_insert(Open {
                    count: 0,
                    start: t,
                    total_ms: 0,
                    last_resumed_ms: None,
                });
                if e.count == 0 {
                    e.start = t;
                }
                e.count += 1;
                e.last_resumed_ms = Some((t * 1000) as u64);
            }
            "ACTIVITY_PAUSED" | "ACTIVITY_STOPPED" | "ACTIVITY_DESTROYED" => {
                if let Some(e) = apps.get_mut(package) {
                    if e.count > 0 {
                        e.count -= 1;
                        if e.count == 0 {
                            e.total_ms += ((t - e.start).max(0) * 1000) as u64;
                        }
                    }
                }
            }
            // The screen going off ends every open session: an app
            // left open while the headset sleeps must not count
            // the whole sleep as use. Waking the screen emits a
            // fresh ACTIVITY_RESUMED for the foreground app.
            "SCREEN_NON_INTERACTIVE" => {
                for e in apps.values_mut() {
                    if e.count > 0 {
                        e.total_ms += ((t - e.start).max(0) * 1000) as u64;
                        e.count = 0;
                    }
                }
            }
            _ => {}
        }
    }
    let mut out: Vec<AppUsage> = apps
        .into_iter()
        .map(|(package, mut e)| {
            if e.count > 0 {
                e.total_ms += ((now_epoch - e.start).max(0) * 1000) as u64;
            }
            AppUsage {
                package,
                total_foreground_ms: e.total_ms,
                last_used_ms: e.last_resumed_ms,
            }
        })
        .filter(|a| a.total_foreground_ms > 0)
        .collect();
    out.sort_by(|a, b| b.total_foreground_ms.cmp(&a.total_foreground_ms));
    out.truncate(8);
    out
}

/// Battery history for the Headset Health section: the live level from
/// `dumpsys battery`, the samples recorded on this computer over time,
/// and the most-used apps from the headset's last-24-hours usage stats.
/// A headset that was never connected has no samples yet, so early
/// history is sparse.
pub fn battery_history(t: &dyn AdbTransport, serial: &str) -> Result<BatteryHistory> {
    let target = Target::serial(serial);
    let battery = t
        .shell(&target, "dumpsys battery")
        .map(|o| parse_battery(&o.stdout))
        .unwrap_or_else(|_| parse_battery(""));
    let samples = history_path(serial)
        .map(|p| load_samples(&p))
        .unwrap_or_default();
    // Wall times in the event log need the headset's UTC offset;
    // without it durations are still right but last-used times
    // render hours off. Fails soft to offset 0.
    // parse_date_line returns (now, offset), in that order.
    let (now_epoch, offset_seconds) = t
        .shell(&target, "date \"+%s %Y-%m-%d %H:%M:%S\"")
        .ok()
        .and_then(|o| parse_date_line(&o.stdout))
        .unwrap_or((0, 0));
    let top_apps = t
        .shell(&target, "dumpsys usagestats")
        .map(|o| parse_usagestats(&o.stdout, offset_seconds, now_epoch))
        .unwrap_or_default();
    Ok(BatteryHistory {
        serial: serial.to_string(),
        battery,
        samples,
        top_apps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn should_record_rules() {
        let last = BatterySample {
            time: 1000,
            level: 80,
            charging: false,
        };
        assert!(!should_record(Some(&last), 1100, 80, false));
        assert!(should_record(Some(&last), 1100, 82, false));
        assert!(should_record(Some(&last), 1100, 80, true));
        assert!(should_record(Some(&last), 1000 + MIN_SECONDS_BETWEEN_SAMPLES, 80, false));
        assert!(should_record(None, 1000, 80, false));
    }

    #[test]
    fn usagestats_parses_real_event_format() {
        // Lines copied from the real dump on the owner's Quest 2
        // (2026-11-12): the first section is the last 24 hours of
        // events; the next section must not leak into it.
        let text = "user=0 \n  Last 24 hour events (timeRange=\"11/11/2026, 5:27 PM – 11/12/2026, 5:27 PM\" )\n    time=\"2026-11-11 17:33:38\" type=ACTIVITY_RESUMED package=com.example.game class=com.example.game.Main instanceId=1 flags=0x0 \n    time=\"2026-11-11 17:33:40\" type=ACTIVITY_PAUSED package=com.example.game class=com.example.game.Main instanceId=1 flags=0x0 \n    time=\"2026-11-11 17:34:00\" type=ACTIVITY_RESUMED package=com.example.other class=com.example.other.Main instanceId=2 flags=0x0 \n    time=\"2026-11-11 17:35:00\" type=ACTIVITY_RESUMED package=com.example.other class=com.example.other.Other instanceId=3 flags=0x0 \n    time=\"2026-11-11 17:36:00\" type=ACTIVITY_PAUSED package=com.example.other class=com.example.other.Main instanceId=2 flags=0x0 \n    time=\"2026-11-11 17:37:00\" type=ACTIVITY_STOPPED package=com.example.other class=com.example.other.Other instanceId=3 flags=0x0 \n    time=\"2026-11-11 17:38:00\" type=ACTIVITY_RESUMED package=com.example.open class=com.example.open.Main instanceId=4 flags=0x0 \n  timeRange=\"11/12/2026, 1:09 – 5:29 PM\" \n    time=\"2026-11-12 13:09:00\" type=ACTIVITY_RESUMED package=com.example.late class=com.example.late.Main instanceId=5 flags=0x0 \n";
        // Offset 0, now at 17:40: the still-open app gets 2 minutes.
        let now = parse_wall_time("2026-11-11 17:40:00").unwrap();
        let apps = parse_usagestats(text, 0, now);
        assert_eq!(apps.len(), 3);
        assert_eq!(apps[0].package, "com.example.other");
        assert_eq!(apps[0].total_foreground_ms, 180_000);
        assert_eq!(apps[1].package, "com.example.open");
        assert_eq!(apps[1].total_foreground_ms, 120_000);
        assert_eq!(apps[2].package, "com.example.game");
        assert_eq!(apps[2].total_foreground_ms, 2_000);
        assert_eq!(
            apps[2].last_used_ms,
            Some((parse_wall_time("2026-11-11 17:33:38").unwrap() * 1000) as u64)
        );
    }

    #[test]
    fn usagestats_screen_off_closes_open_sessions() {
        let text = "  Last 24 hour events (timeRange=\"x\" )\n    time=\"2026-11-11 17:33:38\" type=ACTIVITY_RESUMED package=com.example.game class=com.example.game.Main instanceId=1 flags=0x0 \n    time=\"2026-11-11 17:34:38\" type=SCREEN_NON_INTERACTIVE package=android flags=0x0 \n    time=\"2026-11-11 17:35:38\" type=ACTIVITY_RESUMED package=com.example.game class=com.example.game.Main instanceId=1 flags=0x0 \n    time=\"2026-11-11 17:36:38\" type=ACTIVITY_PAUSED package=com.example.game class=com.example.game.Main instanceId=1 flags=0x0 \n";
        let now = parse_wall_time("2026-11-11 17:40:00").unwrap();
        let apps = parse_usagestats(text, 0, now);
        assert_eq!(apps.len(), 1);
        // 60 s before the screen went off, 60 s after waking.
        // Without the screen-off close it would be 180 s or more.
        assert_eq!(apps[0].total_foreground_ms, 120_000);
    }

    #[test]
    fn usagestats_empty_on_garbage() {
        assert!(parse_usagestats("nothing here\n", 0, 0).is_empty());
    }

    #[test]
    fn date_line_gives_offset() {
        // The live sample time 1794522526 was 16:28:46 CST
        // (22:28:46 UTC), so wall-as-UTC is 6 hours behind.
        let (now, offset) = parse_date_line("1794522526 2026-11-12 16:28:46").unwrap();
        assert_eq!(now, 1794522526);
        assert_eq!(offset, 21600);
    }

    #[test]
    fn samples_round_trip_through_a_temp_file() {
        let dir = std::env::temp_dir().join("reoculus-battery-history-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("samples.json");
        let _ = std::fs::remove_file(&path);
        let samples = vec![
            BatterySample { time: 1000, level: 80, charging: false },
            BatterySample { time: 2000, level: 78, charging: false },
        ];
        save_samples(&path, &samples).unwrap();
        let back = load_samples(&path);
        assert_eq!(back.len(), 2);
        assert_eq!(back[1].level, 78);
        let _ = std::fs::remove_file(&path);
    }
}
