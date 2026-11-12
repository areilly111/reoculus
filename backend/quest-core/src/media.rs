//! Screenshots, screen recording, logcat and scrcpy mirroring.
//!
//! Screenshots use `exec-out screencap -p` (binary-safe). Recording
//! uses `screenrecord` (video-only, max ~180 s per invocation).
//! Live mirroring is scrcpy as a subprocess; the MVP does NOT
//! reimplement video streaming.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const PNG_MAGIC: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

pub fn screenshot(t: &dyn AdbTransport, serial: &str, out: &Path) -> Result<PathBuf> {
    let png = t.exec_out(&Target::serial(serial), &["screencap", "-p"])?;
    if png.len() < 8 || png[..8] != PNG_MAGIC {
        return Err(Error(format!(
            "screencap returned {} bytes that are not a PNG (is the headset awake / unlocked?)",
            png.len()
        )));
    }
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(out, &png)?;
    Ok(out.to_path_buf())
}

pub struct Recording {
    pub path: PathBuf,
    pub seconds: u32,
    pub note: Option<String>,
}

/// Record the display for `seconds` (clamped to 180, the screenrecord
/// limit), pull the file down, delete the remote copy.
pub fn record(t: &dyn AdbTransport, serial: &str, out: &Path, seconds: u32) -> Result<Recording> {
    let mut secs = seconds;
    let mut note = None;
    if secs == 0 {
        secs = 60;
    }
    if secs > 180 {
        secs = 180;
        note = Some("screenrecord caps at 180 s per invocation; recording was clamped to 180 s".into());
    }
    let remote = format!("/sdcard/questcompanion_rec_{}.mp4", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0));
    let cmd = format!(
        "screenrecord --time-limit {secs} --size 1280x720 --bit-rate 6000000 {remote}"
    );
    let target = Target::serial(serial);
    let r = t.shell(&target, &cmd)?;
    if r.code != 0 && !r.stderr.trim().is_empty() {
        return Err(Error(format!("screenrecord failed: {}", r.stderr.trim())));
    }
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    t.pull(&target, &remote, out)?;
    let _ = t.shell(&target, &format!("rm {remote}"));
    Ok(Recording {
        path: out.to_path_buf(),
        seconds: secs,
        note,
    })
}

pub fn logcat_dump(t: &dyn AdbTransport, serial: &str) -> Result<Vec<String>> {
    t.logcat_dump(&Target::serial(serial))
}

/// Find a scrcpy binary: PATH, then common install locations.
pub fn find_scrcpy() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let cand = dir.join("scrcpy");
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    for cand in [
        "/usr/bin/scrcpy",
        "/usr/local/bin/scrcpy",
        "/snap/bin/scrcpy",
    ] {
        let p = PathBuf::from(cand);
        if p.exists() {
            return Some(p);
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let p = PathBuf::from(home).join(".local").join("bin").join("scrcpy");
        if p.exists() {
            return Some(p);
        }
    }
    None
}

pub struct Mirror {
    pub scrcpy: PathBuf,
    pub command: String,
    pub note: String,
}

/// Launch scrcpy in its own window and return immediately. The process
/// is detached; closing it is done from the scrcpy window itself.
pub fn mirror(t: &dyn AdbTransport, serial: &str, preset: &str) -> Result<Mirror> {
    // Presets actually change scrcpy: before this, the UI preset was
    // ignored and scrcpy ran at full 3664x1920 with no bitrate limit,
    // which stutters and tears, especially over Wi-Fi.
    let (max_size, bit_rate, max_fps) = match preset.to_lowercase().as_str() {
        "performance" => ("1280", "4M", "30"),
        "quality" => ("2560", "12M", "90"),
        _ => ("1920", "8M", "60"), // balanced, the default
    };
    let scrcpy = find_scrcpy().ok_or_else(|| {
        Error(
            "scrcpy is not installed. Install it with `sudo apt install scrcpy` \
             or from https://github.com/Genymobile/scrcpy/releases, then try again."
                .into(),
        )
    })?;
    // The serial must be a live device for scrcpy to attach.
    let devices = t.list_devices().unwrap_or_default();
    if !devices.iter().any(|d| d.serial == serial) {
        return Err(Error(format!(
            "device {serial} is not visible to adb; connect it over USB or Wi-Fi first"
        )));
    }
    let mut cmd = Command::new(&scrcpy);
    cmd.arg("-s").arg(serial)
        .arg("--max-size").arg(max_size)
        .arg("--video-bit-rate").arg(bit_rate)
        .arg("--max-fps").arg(max_fps)
        .arg("--video-codec").arg("h265")
        .arg("--video-codec-options").arg("i-frame-interval=1")
        .arg("--video-buffer").arg("100")
        .arg("--no-audio");
    cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| Error(format!("failed to start scrcpy: {e}")))?;
    // If scrcpy dies immediately (no display, device gone), report its stderr.
    std::thread::sleep(std::time::Duration::from_millis(900));
    if let Ok(Some(status)) = child.try_wait() {
        let mut err = String::new();
        if let Some(mut stderr) = child.stderr.take() {
            use std::io::Read;
            let _ = stderr.read_to_string(&mut err);
        }
        return Err(Error(format!(
            "scrcpy exited immediately (status {status}): {}",
            err.trim()
        )));
    }
    let _ = child.id(); // detached; the window owns the process now.
    Ok(Mirror {
        command: format!("{} -s {} --max-size {} --video-bit-rate {} --max-fps {} --video-codec h265 --video-codec-options i-frame-interval=1 --video-buffer 100 --no-audio", scrcpy.display(), serial, max_size, bit_rate, max_fps),
        scrcpy,
        note: "scrcpy is running in its own window. Close that window to stop mirroring."
            .into(),
    })
}

/// PIDs of scrcpy processes mirroring this serial, found by
/// scanning /proc for a scrcpy command line naming the serial.
fn scrcpy_pids(serial: &str) -> Result<Vec<i32>> {
    let mut pids = Vec::new();
    let proc = std::fs::read_dir("/proc").map_err(|e| Error(format!("cannot list /proc: {e}")))?;
    for entry in proc.flatten() {
        let pid: i32 = match entry.file_name().to_string_lossy().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let cmdline = match std::fs::read(entry.path().join("cmdline")) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let parts: Vec<&str> = cmdline
            .split(|b| *b == 0)
            .filter_map(|b| std::str::from_utf8(b).ok())
            .filter(|s| !s.is_empty())
            .collect();
        if parts.is_empty() || !parts[0].ends_with("scrcpy") {
            continue;
        }
        if !parts.iter().any(|a| *a == serial) {
            continue;
        }
        pids.push(pid);
    }
    Ok(pids)
}

/// Is a scrcpy mirror running for this serial? Same /proc scan as
/// the stop, without killing anything.
pub fn mirror_running(serial: &str) -> bool {
    scrcpy_pids(serial).map(|p| !p.is_empty()).unwrap_or(false)
}

/// Stop scrcpy for this serial (SIGTERM, no SIGKILL follow-up).
/// Returns how many were stopped. This does NOT touch the
/// auto-restart watcher: the watcher calls this itself when it
/// restarts the mirror, and stopping the watcher there would
/// kill the watcher mid-restart.
pub fn stop_scrcpy(serial: &str) -> Result<usize> {
    let pids = scrcpy_pids(serial)?;
    for pid in &pids {
        unsafe { libc::kill(*pid, libc::SIGTERM) };
    }
    if !pids.is_empty() {
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Ok(pids.len())
}

/// Stop a running scrcpy mirror for this serial. Also stops the
/// auto-restart watcher first, so it does not bring the mirror
/// back a moment later. (The watcher itself stops scrcpy through
/// `stop_scrcpy`, never through this, or it would kill itself
/// mid-restart.)
pub fn mirror_stop(serial: &str) -> Result<usize> {
    let _ = crate::mirror_watch::stop_watch(serial);
    stop_scrcpy(serial)
}
