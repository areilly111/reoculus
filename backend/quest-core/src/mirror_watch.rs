//! Mirror auto-restart: watch the headset's foreground activity
//! and restart scrcpy when it changes, so opening a game or the
//! Quest menu over a game does not leave the mirror smeared.
//!
//! Why a restart is the fix: when the menu opens over a game (or
//! a game starts from the library) the picture changes completely
//! and the video decoder on this computer loses its key frame, so
//! it smears and then stalls. A fresh scrcpy gives it a fresh
//! stream. The 1-second keyframe setting does not fix the switch
//! itself. The cost is honest: the mirror window goes black for
//! a second or two while scrcpy reopens.
//!
//! The watcher is a loop in `device mirror-watch-run`, a
//! long-running questctl process spawned detached by `device
//! mirror-watch-start`, PID in
//! `~/.config/quest-companion/mirror-watch-<serial>.pid`.
//! Every poll it reads the resumed activity (`dumpsys activity
//! activities`, the `ResumedActivity:` line, verified live on the
//! owner's Quest 2) and restarts scrcpy when the activity
//! changes. It never restarts more than once per 5 seconds, it
//! only restarts for an activity that has been unchanged for a
//! full poll (2 s) so the screen has settled, and it ignores the
//! transient FocusPlaceholderActivity, so a flickering focus
//! cannot restart the mirror in a loop. Stopping the mirror
//! stops the watcher too (mirror_stop kills it first). If scrcpy
//! dies on its own, the watcher brings it back, within the same
//! 5-second floor.

use crate::error::{Error, Result};
use crate::media;
use crate::mirror_settings;
use crate::transport::{AdbTransport, Target};
use serde::Serialize;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Seconds between foreground-activity polls.
const POLL_SECS: u64 = 2;
/// Never restart the mirror more often than this.
const MIN_RESTART_SECS: u64 = 5;
/// How long the foreground activity must stay unchanged before a
/// restart counts it as settled. A restart that lands while the
/// menu is still opening or closing starts its new stream
/// mid-transition and smears again, which is why Restart used
/// to look like it did nothing while Stop, then Start a few
/// seconds later, worked. Waiting one full poll (2 s) means the
/// screen has settled.
const STABLE_SECS: u64 = 2;

#[derive(Debug, Clone, Serialize)]
pub struct WatchStatus {
    pub watching: bool,
    pub pid: Option<i32>,
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

fn config_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate config dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("quest-companion"))
}

fn pid_path(serial: &str) -> Result<PathBuf> {
    Ok(config_dir()?.join(format!("mirror-watch-{}.pid", sanitize(serial))))
}

fn log_path() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate state dir".into()))?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("state")
        .join("quest-companion")
        .join("mirror-watch.log"))
}

/// One line in the watcher log, stamped with unix seconds. The
/// log is only for debugging a restart that looked wrong.
fn log_line(msg: &str) {
    let Ok(path) = log_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "[{now}] {msg}");
    }
}

/// The resumed (foreground) activity from `dumpsys activity
/// activities`, e.g. `com.oculus.vrshell/.HomeActivity` from a
/// line like:
/// `  ResumedActivity: ActivityRecord{d64fe31 u0 com.oculus.vrshell/.HomeActivity t10228}`
pub fn parse_resumed_activity(text: &str) -> Option<String> {
    for line in text.lines() {
        if !line.contains("ResumedActivity:") {
            continue;
        }
        for tok in line.split_whitespace() {
            let tok = tok.trim_matches(|c| c == '{' || c == '}');
            if tok.contains('/') && tok.contains('.') {
                return Some(tok.to_string());
            }
        }
    }
    None
}

/// The transient focus holder the shell flickers through while
/// switching screens. It is not a real screen, so it must never
/// count as a change and never trigger a restart.
pub fn is_transient_activity(component: &str) -> bool {
    component.ends_with("FocusPlaceholderActivity")
}

/// The quality preset for this connection, re-read from the
/// settings file each time so a quality change applies on the
/// next auto-restart without stopping the mirror.
fn preset_for(connection: &str, fallback: &str) -> String {
    let s = mirror_settings::get_mirror_settings();
    match connection {
        "wifi" => s.wifi_quality,
        "usb" => s.usb_quality,
        _ => fallback.to_string(),
    }
}

fn cooldown_over(last_restart: Option<Instant>) -> bool {
    last_restart
        .map(|i| i.elapsed() >= Duration::from_secs(MIN_RESTART_SECS))
        .unwrap_or(true)
}

/// Stop scrcpy (if any) and start it again with the current
/// preset for this connection. Errors are logged, never fatal:
/// the loop keeps watching. The 5-second floor is applied by
/// the caller through `last_restart`, which is set on every
/// attempt, success or failure, so a dying scrcpy cannot be
/// respawned in a tight loop.
fn restart_mirror(
    t: &dyn AdbTransport,
    serial: &str,
    connection: &str,
    fallback_preset: &str,
    from: &str,
    to: &str,
    last_restart: &mut Option<Instant>,
) {
    let preset = preset_for(connection, fallback_preset);
    let _ = media::stop_scrcpy(serial);
    match media::mirror(t, serial, &preset) {
        Ok(_) => log_line(&format!(
            "restarted mirror for {serial}: {from} -> {to} (preset {preset})"
        )),
        Err(e) => log_line(&format!(
            "mirror restart for {serial} failed ({from} -> {to}): {e}"
        )),
    }
    *last_restart = Some(Instant::now());
}

/// Is this activity worth a restart right now? Only when it is
/// not the one the last restart was for, it has been unchanged
/// long enough to be settled, and the floor since the last
/// restart has passed. The settled check is what stops a
/// restart landing mid-transition (menu opening or closing) and
/// smearing again; the floor is only a backstop, because a
/// flickering activity never becomes settled and so never
/// restarts at all.
fn should_restart(
    current: &str,
    restarted_for: Option<&str>,
    stable: Duration,
    since_restart: Duration,
) -> bool {
    restarted_for != Some(current)
        && stable >= Duration::from_secs(STABLE_SECS)
        && since_restart >= Duration::from_secs(MIN_RESTART_SECS)
}

/// The watcher loop. Runs in the foreground until SIGTERM (the
/// default action ends the process; there is nothing to clean
/// up). Never returns.
pub fn run_watch(t: &dyn AdbTransport, serial: &str, preset: &str, connection: &str) -> ! {
    log_line(&format!("watcher started for {serial} (preset {preset}, {connection})"));
    let mut last: Option<String> = None;
    let mut last_change: Option<Instant> = None;
    let mut restarted_for: Option<String> = None;
    let mut last_restart: Option<Instant> = None;
    loop {
        let current = t
            .shell(&Target::serial(serial), "dumpsys activity activities")
            .ok()
            .and_then(|o| parse_resumed_activity(&o.stdout));
        if let Some(c) = current {
            if is_transient_activity(&c) {
                // Not a real screen; ignore it entirely.
            } else if last.as_deref() != Some(c.as_str()) {
                last = Some(c);
                last_change = Some(Instant::now());
            } else {
                let stable = last_change.map(|i| i.elapsed()).unwrap_or(Duration::MAX);
                let since_restart = last_restart
                    .map(|i| i.elapsed())
                    .unwrap_or(Duration::MAX);
                if should_restart(&c, restarted_for.as_deref(), stable, since_restart) {
                    let from = restarted_for.clone().unwrap_or_default();
                    restart_mirror(t, serial, connection, preset, &from, &c, &mut last_restart);
                    restarted_for = Some(c);
                }
            }
        }
        // scrcpy died on its own: bring it back, within the
        // same 5-second floor. No settled check here, a dead
        // mirror is dead whatever the screen is doing.
        if !media::mirror_running(serial) && cooldown_over(last_restart) {
            let to = last.clone().unwrap_or_default();
            restart_mirror(t, serial, connection, preset, "", &to, &mut last_restart);
            restarted_for = last.clone();
        }
        std::thread::sleep(Duration::from_secs(POLL_SECS));
    }
}

/// Start the watcher detached (a `mirror-watch-run` process that
/// outlives this call). Any watcher already running for this
/// serial is stopped first, so starting twice leaves one.
pub fn start_watch(serial: &str, preset: &str, connection: &str) -> Result<WatchStatus> {
    let _ = stop_watch(serial);
    let exe = std::env::current_exe().map_err(|e| Error(e.to_string()))?;
    let mut child = Command::new(exe)
        .arg("--json")
        .arg("device")
        .arg("mirror-watch-run")
        .arg("--serial")
        .arg(serial)
        .arg("--preset")
        .arg(preset)
        .arg("--connection")
        .arg(connection)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error(format!("failed to start the mirror watcher: {e}")))?;
    let pid = child.id() as i32;
    let _ = child.id(); // detached; the watcher owns itself now.
    let path = pid_path(serial)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error(e.to_string()))?;
    }
    std::fs::write(&path, pid.to_string()).map_err(|e| Error(e.to_string()))?;
    log_line(&format!("watcher started for {serial} (pid {pid})"));
    Ok(WatchStatus {
        watching: true,
        pid: Some(pid),
    })
}

/// Stop the watcher for this serial, if one is running. Returns
/// whether one was stopped. A stale PID file (process gone) is
/// removed and counts as not stopped.
pub fn stop_watch(serial: &str) -> Result<bool> {
    let Ok(path) = pid_path(serial) else {
        return Ok(false);
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(false);
    };
    let Ok(pid) = text.trim().parse::<i32>() else {
        let _ = std::fs::remove_file(&path);
        return Ok(false);
    };
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    if !alive {
        let _ = std::fs::remove_file(&path);
        return Ok(false);
    }
    unsafe { libc::kill(pid, libc::SIGTERM) };
    std::thread::sleep(Duration::from_millis(500));
    let _ = std::fs::remove_file(&path);
    log_line(&format!("watcher stopped for {serial} (pid {pid})"));
    Ok(true)
}

/// Is the watcher running for this serial?
pub fn watch_status(serial: &str) -> WatchStatus {
    let Ok(path) = pid_path(serial) else {
        return WatchStatus {
            watching: false,
            pid: None,
        };
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return WatchStatus {
            watching: false,
            pid: None,
        };
    };
    let Ok(pid) = text.trim().parse::<i32>() else {
        return WatchStatus {
            watching: false,
            pid: None,
        };
    };
    if unsafe { libc::kill(pid, 0) } == 0 {
        WatchStatus {
            watching: true,
            pid: Some(pid),
        }
    } else {
        let _ = std::fs::remove_file(&path);
        WatchStatus {
            watching: false,
            pid: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resumed_activity_parses_real_line() {
        let text = "  ResumedActivity: ActivityRecord{d64fe31 u0 com.oculus.vrshell/.HomeActivity t10228}\n";
        assert_eq!(
            parse_resumed_activity(text).as_deref(),
            Some("com.oculus.vrshell/.HomeActivity")
        );
    }

    #[test]
    fn resumed_activity_parses_menu_activity() {
        let text = "  ResumedActivity: ActivityRecord{a1b2c3 u0 com.oculus.panelapp.qam/.QuickActionsMenuActivity t10229}\n";
        assert_eq!(
            parse_resumed_activity(text).as_deref(),
            Some("com.oculus.panelapp.qam/.QuickActionsMenuActivity")
        );
    }

    #[test]
    fn resumed_activity_none_when_absent() {
        assert_eq!(parse_resumed_activity("nothing here\n"), None);
        assert_eq!(parse_resumed_activity(""), None);
    }

    #[test]
    fn placeholder_is_transient() {
        assert!(is_transient_activity(
            "com.oculus.vrshell/.FocusPlaceholderActivity"
        ));
        assert!(!is_transient_activity("com.oculus.vrshell/.HomeActivity"));
        assert!(!is_transient_activity("com.beatgames.beatsaber/.MainActivity"));
    }

    #[test]
    fn should_restart_needs_settled_new_activity_and_floor() {
        let game = "com.beatgames.beatsaber/.MainActivity";
        let home = "com.oculus.vrshell/.HomeActivity";
        // New activity, settled, floor passed: restart.
        assert!(should_restart(
            game,
            Some(home),
            Duration::from_secs(3),
            Duration::from_secs(60)
        ));
        // Same activity as the last restart: no restart.
        assert!(!should_restart(
            game,
            Some(game),
            Duration::from_secs(30),
            Duration::from_secs(60)
        ));
        // Not settled yet (changed a moment ago): no restart.
        assert!(!should_restart(
            game,
            Some(home),
            Duration::from_secs(1),
            Duration::from_secs(60)
        ));
        // Floor not passed since the last restart: no restart.
        assert!(!should_restart(
            game,
            Some(home),
            Duration::from_secs(30),
            Duration::from_secs(2)
        ));
    }
}
