//! Screenshots, screen recording, logcat and the built-in H.264
//! live mirror.
//!
//! Screenshots use `exec-out screencap -p` (binary-safe). Recording
//! uses `screenrecord` (video-only, max ~180 s per invocation).
//! The live mirror streams raw H.264 from `screenrecord` and the
//! app decodes it on this device. There is no scrcpy any more
//! (removed in 0.2.36): the built-in stream is the only mirror.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const PNG_MAGIC: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Take a screenshot on the headset (`screencap -p`) and save it as a
/// PNG at `out`, creating the parent folder first. Errors when the
/// headset returns bytes that are not a PNG (usually because it is
/// asleep). Returns the path written.
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

/// One-shot logcat dump from the headset: the recent log lines as text.
/// For a live stream use the CLI `logcat --follow` path instead.
pub fn logcat_dump(t: &dyn AdbTransport, serial: &str) -> Result<Vec<String>> {
    t.logcat_dump(&Target::serial(serial))
}

/// Stream the headset display as raw H.264 (Annex B) to `out`, for
/// the live view. Runs `screenrecord --output-format=h264 -` in a
/// loop: screenrecord caps at 180 s per run, and each run starts
/// with SPS/PPS/IDR, so the decoder re-syncs after every restart.
/// Returns when the reader goes away (the callback stops the stream)
/// or the transport fails (the headset disconnected). View only, no
/// input: the app shows the headset screen about a second behind.
/// The bitrate is the caller's choice: 8 Mbps on the PC (perfect
/// there, do not touch it) and 4 Mbps on Android, where the tablet
/// gets the stream over two Wi-Fi hops and the lower rate glitches
/// less while still looking good at 1280x720.
pub fn mirror_stream(
    t: &dyn AdbTransport,
    serial: &str,
    bit_rate: u32,
    out: &mut dyn std::io::Write,
) -> Result<()> {
    let target = Target::serial(serial);
    let cmd = format!(
        "screenrecord --output-format=h264 --size 1280x720 --bit-rate {bit_rate} --time-limit 180 -"
    );
    loop {
        let mut stopped = false;
        let code = t.shell_stream(&target, &cmd, &mut |chunk| {
            match out.write_all(chunk).and_then(|_| out.flush()) {
                Ok(()) => true,
                Err(_) => {
                    stopped = true;
                    false
                }
            }
        })?;
        if stopped {
            return Ok(());
        }
        if code != 0 {
            return Err(Error(format!(
                "screenrecord exited with code {code} (is the headset awake?)"
            )));
        }
        // screenrecord finished its 180 s; start it again.
    }
}

/// Long recording loop. Runs `screenrecord` in 180 s segments on the
/// headset, pulling each finished segment into `dir` and deleting the
/// remote copy, until the process is killed (the app's Stop button).
/// Each segment is raw H.264, named
/// `questcompanion_rec_<unix>_<n>.h264`, so `record_finish` can
/// stitch them in order by just joining the bytes. Prints one line
/// per saved segment. Returns only on a transport failure (the
/// headset disconnected); killing the process is the normal stop.
pub fn record_loop(t: &dyn AdbTransport, serial: &str, dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir).map_err(|e| Error(e.to_string()))?;
    let target = Target::serial(serial);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut n = 0u32;
    loop {
        n += 1;
        let remote = format!("/sdcard/questcompanion_rec_{stamp}_{n}.h264");
        let cmd = format!(
            "screenrecord --output-format=h264 --time-limit 180 --size 1280x720 --bit-rate 6000000 {remote}"
        );
        let r = t.shell(&target, &cmd)?;
        if r.code != 0 && !r.stderr.trim().is_empty() {
            return Err(Error(format!("screenrecord failed: {}", r.stderr.trim())));
        }
        let local = dir.join(format!("questcompanion_rec_{stamp}_{n}.h264"));
        t.pull(&target, &remote, &local)?;
        let _ = t.shell(&target, &format!("rm {remote}"));
        println!("segment {n} saved");
        use std::io::Write;
        let _ = std::io::stdout().flush();
    }
}

/// The (stamp, segment number) parsed out of a segment file name
/// like `questcompanion_rec_1794444000_2.h264`. Used to order
/// segments chronologically: a plain name sort puts `_10` before
/// `_2`, which would stitch the recording out of order.
fn segment_order(name: &str) -> Option<(u64, u32)> {
    let base = name.strip_suffix(".h264")?;
    let rest = base.strip_prefix("questcompanion_rec_")?;
    let (stamp, n) = rest.rsplit_once('_')?;
    Some((stamp.parse().ok()?, n.parse().ok()?))
}

/// The recording segments in `dir`, oldest first.
fn local_segments(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut segs: Vec<(u64, u32, PathBuf)> = Vec::new();
    let entries = std::fs::read_dir(dir).map_err(|e| Error(e.to_string()))?;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some((stamp, n)) = segment_order(&name) {
            segs.push((stamp, n, entry.path()));
        }
    }
    segs.sort();
    Ok(segs.into_iter().map(|(_, _, p)| p).collect())
}

/// Join the segment files into one raw H.264 file. Every segment
/// starts with SPS/PPS/IDR, so the joined bytes are one valid
/// Annex B stream.
fn stitch(segments: &[PathBuf], out: &Path) -> Result<()> {
    use std::io::Write;
    let mut f = std::fs::File::create(out).map_err(|e| Error(e.to_string()))?;
    for seg in segments {
        let bytes = std::fs::read(seg).map_err(|e| Error(e.to_string()))?;
        f.write_all(&bytes).map_err(|e| Error(e.to_string()))?;
    }
    Ok(())
}

/// Find an ffmpeg binary on PATH, then the usual locations.
fn find_ffmpeg() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let cand = dir.join("ffmpeg");
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    for cand in ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
        let p = PathBuf::from(cand);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

pub struct StitchedRecording {
    pub path: PathBuf,
    pub segments: usize,
    /// "mp4" when ffmpeg remuxed it, "h264" when it stayed raw.
    pub format: String,
    pub note: Option<String>,
}

/// Finish a long recording: stop any screenrecord still running on
/// the headset (the loop was killed mid-segment, so the last piece
/// is still being written there), pull any segments left on the
/// device, stitch everything in `dir` into one file, and remux it
/// to .mp4 with ffmpeg when one is installed. Returns the finished
/// file. The segment files stay in `dir`; the caller deletes them.
pub fn record_finish(
    t: &dyn AdbTransport,
    serial: &str,
    dir: &Path,
    out: &Path,
) -> Result<StitchedRecording> {
    let target = Target::serial(serial);
    // The loop was killed, usually mid-segment: stop the headset
    // screenrecord so the last piece finalises, then pull it.
    let _ = t.shell(&target, "pkill -x screenrecord");
    std::thread::sleep(Duration::from_millis(1000));
    if let Ok(list) = t.shell(&target, "ls /sdcard/questcompanion_rec_*.h264") {
        for name in list.stdout.lines().map(str::trim).filter(|s| !s.is_empty()) {
            let file = name.rsplit('/').next().unwrap_or(name);
            let local = dir.join(file);
            if !local.exists() {
                let _ = t.pull(&target, name, &local);
            }
            let _ = t.shell(&target, &format!("rm {name}"));
        }
    }
    let segments = local_segments(dir)?;
    if segments.is_empty() {
        return Err(Error("nothing was recorded".into()));
    }
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| Error(e.to_string()))?;
        }
    }
    let h264_path = out.with_extension("h264");
    stitch(&segments, &h264_path)?;
    if let Some(ffmpeg) = find_ffmpeg() {
        let ok = Command::new(ffmpeg)
            .args(["-y", "-v", "error", "-i"])
            .arg(&h264_path)
            .args(["-c", "copy"])
            .arg(out)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            let _ = std::fs::remove_file(&h264_path);
            return Ok(StitchedRecording {
                path: out.to_path_buf(),
                segments: segments.len(),
                format: "mp4".into(),
                note: None,
            });
        }
    }
    Ok(StitchedRecording {
        path: h264_path,
        segments: segments.len(),
        format: "h264".into(),
        note: Some(
            "ffmpeg is not installed on this device, so the recording is a raw .h264 file. VLC plays it; on a computer with ffmpeg it can be turned into an .mp4."
                .into(),
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_order_parses_stamp_and_number() {
        assert_eq!(
            segment_order("questcompanion_rec_1794444000_2.h264"),
            Some((1794444000, 2))
        );
        assert_eq!(segment_order("other.h264"), None);
        assert_eq!(segment_order("questcompanion_rec_abc_2.h264"), None);
    }

    #[test]
    fn local_segments_sort_numerically_not_lexically() {
        let dir = tempfile::tempdir().unwrap();
        for n in [2, 10, 1] {
            std::fs::write(
                dir.path().join(format!("questcompanion_rec_1794444000_{n}.h264")),
                [n as u8],
            )
            .unwrap();
        }
        std::fs::write(dir.path().join("unrelated.txt"), b"x").unwrap();
        let segs = local_segments(dir.path()).unwrap();
        let names: Vec<String> = segs
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            vec![
                "questcompanion_rec_1794444000_1.h264",
                "questcompanion_rec_1794444000_2.h264",
                "questcompanion_rec_1794444000_10.h264",
            ]
        );
    }

    #[test]
    fn stitch_joins_segment_bytes_in_order() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("questcompanion_rec_1794444000_1.h264"), b"AAA").unwrap();
        std::fs::write(dir.path().join("questcompanion_rec_1794444000_2.h264"), b"BBB").unwrap();
        let out = dir.path().join("combined.h264");
        let segs = local_segments(dir.path()).unwrap();
        stitch(&segs, &out).unwrap();
        assert_eq!(std::fs::read(&out).unwrap(), b"AAABBB");
    }
}
