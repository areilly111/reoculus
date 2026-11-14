//! SteamVR + Steam Link as an experimental second PC VR runtime.
//!
//! The simplified design Anthony picked (2026-11-14, from the
//! research report `steamvr-runtime-picker-reoculus-20261114-0254`):
//! ReOculus only starts SteamVR on the PC. The user opens the free
//! Steam Link app on the Quest and connects to the PC; SteamVR sees
//! the headset through its own `vrlink` driver. There is no
//! ReOculus-managed streaming client, no server/client version
//! matching, and no per-game launch options in v1.
//!
//! Boundaries, all deliberate:
//! - SteamVR is proprietary and comes through Steam (app 250820).
//!   ReOculus NEVER installs, bundles, downloads, copies, or
//!   modifies it. It only detects the user's own install and
//!   launches it with `steam -applaunch 250820`.
//! - WiVRn 26.9 stays the default PC VR path. SteamVR is an
//!   experimental opt-in, stored per headset.
//! - Before starting SteamVR, WiVRn is stopped first and the shared
//!   runtime config files are snapshotted (Monadeck pattern): the
//!   snapshot is restored when SteamVR stops, so the runtimes do
//!   not fight over `active_runtime.json` / `openvrpaths.vrpath`.
//! - Never switch while a headset is connected or a VR app is
//!   running: start() stops the WiVRn server and refuses when
//!   SteamVR is already running.
//! - Flatpak Steam is reportedly excluded from Steam Link VR, so
//!   the SteamVR path refuses Flatpak Steam and points the user
//!   at native Steam.
//! - Stable ALVR (20.14.1) is broken on SteamVR 2.16.7+ and is not
//!   offered anywhere here.
//!
//! Top open question from the research: Steam Link on a GTX 1050 Ti
//! Pascal is unverified, Vulkan Video encode may fail (error
//! 405/499). Detection reports the GPU and driver so the UI can
//! flag the test as the gate before promising this path works.

use crate::error::{Error, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const STEAMVR_APP_ID: u32 = 250820;
/// SteamVR 2.18 (2026-10-21) is the minimum: it added Quest USB
/// tethering and removed the `VK_KHR_maintenance9` requirement
/// that broke NVIDIA 580-driver machines.
pub const MIN_STEAMVR: (u32, u32, u32) = (2, 18, 0);
/// Steam Link VR on Linux needs Vulkan Video, NVIDIA 575.64.05+.
pub const MIN_NVIDIA_DRIVER: (u32, u32, u32) = (575, 64, 5);
pub const STEAM_FLATPAK_ID: &str = "com.valvesoftware.Steam";

fn home() -> PathBuf {
    // No username is ever hardcoded: $HOME wins, and the fallback
    // is only for environments without one set.
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

fn config_dir(home: &Path) -> PathBuf {
    home.join(".config").join("quest-companion")
}

fn run_output(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// First `N.N` or `N.N.N` version-like token in the text, if any.
/// Written by hand: quest-core has no regex dependency.
pub fn parse_version(text: &str) -> Option<(u32, u32, u32)> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let mut nums = Vec::new();
            let mut j = i;
            while nums.len() < 3 {
                let start = j;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                if start == j {
                    break;
                }
                nums.push(text[start..j].parse::<u32>().ok()?);
                if j < bytes.len() && bytes[j] == b'.' && nums.len() < 3 {
                    // Only continue if a digit follows the dot.
                    if j + 1 < bytes.len() && bytes[j + 1].is_ascii_digit() {
                        j += 1;
                        continue;
                    }
                }
                break;
            }
            if nums.len() >= 2 {
                return Some((nums[0], nums[1], *nums.get(2).unwrap_or(&0)));
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    None
}

fn version_at_least(v: (u32, u32, u32), min: (u32, u32, u32)) -> bool {
    v >= min
}

/// Pull the quoted value after a `"key"` on a VDF line, e.g.
/// `"buildid"		"23791826"` -> Some("23791826").
fn vdf_value_for(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim();
        let want = format!("\"{key}\"");
        let Some(rest) = t.strip_prefix(&want) else {
            continue;
        };
        let rest = rest.trim();
        if let Some(v) = rest.strip_prefix('"').and_then(|r| r.split('"').next()) {
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// Every `"path"` value in a `libraryfolders.vdf`.
pub fn parse_library_paths(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("\"path\"") {
            let rest = rest.trim();
            if let Some(v) = rest.strip_prefix('"').and_then(|r| r.split('"').next()) {
                if !v.is_empty() {
                    out.push(v.to_string());
                }
            }
        }
    }
    out
}

fn command_exists(cmd: &str) -> bool {
    run_output("which", &[cmd]).is_some()
}

fn flatpak_app_installed(id: &str) -> bool {
    Command::new("flatpak")
        .args(["info", id])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Steam library roots: the main Steam dir plus every extra
/// library folder listed in `libraryfolders.vdf`.
fn steam_library_roots(steam_root: &Path) -> Vec<PathBuf> {
    let mut roots = vec![steam_root.to_path_buf()];
    let vdf = steam_root.join("steamapps").join("libraryfolders.vdf");
    if let Ok(text) = std::fs::read_to_string(vdf) {
        for p in parse_library_paths(&text) {
            roots.push(PathBuf::from(p));
        }
    }
    roots
}

fn looks_like_steamvr(dir: &Path) -> bool {
    dir.join("bin").join("linux64").join("vrserver").exists()
        || dir.join("bin").join("linux64").join("vrpathreg").exists()
}

/// Read the installed SteamVR version from its `version.txt`
/// (root, then `bin/linux64/`), falling back to the Steam
/// `buildid` from the app manifest, which is not a version.
fn steamvr_version(dir: &Path, manifest: &Path) -> (Option<(u32, u32, u32)>, Option<String>) {
    for cand in [dir.join("version.txt"), dir.join("bin").join("linux64").join("version.txt")] {
        if let Ok(text) = std::fs::read_to_string(cand) {
            if let Some(v) = parse_version(&text) {
                return (Some(v), None);
            }
        }
    }
    let buildid = std::fs::read_to_string(manifest)
        .ok()
        .and_then(|t| vdf_value_for(&t, "buildid"));
    (None, buildid)
}

fn format_version(v: (u32, u32, u32)) -> String {
    format!("{}.{}.{}", v.0, v.1, v.2)
}

/// NVIDIA GPU name and driver version from nvidia-smi, if present.
fn nvidia_info() -> (Option<String>, Option<(u32, u32, u32)>) {
    let out = run_output(
        "nvidia-smi",
        &["--query-gpu=name,driver_version", "--format=csv,noheader"],
    )
    .unwrap_or_default();
    let first = out.lines().next().unwrap_or("").trim();
    if first.is_empty() {
        return (None, None);
    }
    let mut parts = first.splitn(2, ',');
    let name = parts.next().map(|s| s.trim().to_string());
    let version = parts.next().and_then(|s| parse_version(s.trim()));
    (name, version)
}

/// True when the loaded NVIDIA kernel module version differs from
/// the userspace driver version (the error-303 diagnostic from the
/// research: mismatched installs fall through to llvmpipe and
/// Vulkan breaks system-wide). None when the check cannot run.
fn nvidia_driver_mismatch(driver: (u32, u32, u32)) -> Option<bool> {
    let module = run_output("modinfo", &["-F", "version", "nvidia"])?;
    let module = module.trim();
    let mv = parse_version(module)?;
    Some(mv != driver)
}

/// A SteamVR server process is alive when a `vrserver`,
/// `vrcompositor` or `vrmonitor` cmdline exists (other than our
/// own questctl invocation).
pub fn steamvr_running() -> bool {
    let Ok(proc) = std::fs::read_dir("/proc") else {
        return false;
    };
    for entry in proc.flatten() {
        if entry.file_name().to_string_lossy().parse::<i32>().is_err() {
            continue;
        }
        let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else {
            continue;
        };
        let text = String::from_utf8_lossy(&cmdline).replace(char::from(0), " ");
        if text.contains("questctl") {
            continue;
        }
        if text.contains("vrserver") || text.contains("vrcompositor") || text.contains("vrmonitor") {
            return true;
        }
    }
    false
}

/// The environment probes detect() shells out to. Real by
/// default; tests pass stubs so the tests do not depend on the
/// machine they run on (the VM has no Steam or GPU, the PC has
/// both, and the same tests must pass on either).
pub struct Probes {
    pub command_exists: fn(&str) -> bool,
    pub flatpak_installed: fn(&str) -> bool,
    pub nvidia_info: fn() -> (Option<String>, Option<(u32, u32, u32)>),
    pub nvidia_driver_mismatch: fn((u32, u32, u32)) -> Option<bool>,
    pub wivrn_running: fn() -> bool,
    pub wivrn_active_runtime: fn() -> bool,
}

impl Probes {
    fn real() -> Self {
        Probes {
            command_exists,
            flatpak_installed: flatpak_app_installed,
            nvidia_info,
            nvidia_driver_mismatch,
            wivrn_running: || crate::wivrn::status().running,
            wivrn_active_runtime: || crate::wivrn::status().active_runtime_is_wivrn,
        }
    }

    #[cfg(test)]
    fn stub() -> Self {
        Probes {
            command_exists: |_| false,
            flatpak_installed: |_| false,
            nvidia_info: || (None, None),
            nvidia_driver_mismatch: |_| None,
            wivrn_running: || false,
            wivrn_active_runtime: || false,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SteamVrDetect {
    /// "native", "flatpak", or "" when Steam is not found.
    pub steam_kind: String,
    pub steam_path: String,
    pub steamvr_present: bool,
    pub steamvr_dir: String,
    /// e.g. "2.18.0", or null when it could not be read.
    pub steamvr_version: Option<String>,
    /// Steam buildid when the version file is missing.
    pub steamvr_buildid: Option<String>,
    /// "stable", "beta", or "unknown".
    pub steamvr_branch: String,
    /// null when the version could not be read.
    pub version_ok: Option<bool>,
    pub gpu_name: Option<String>,
    pub nvidia_driver: Option<String>,
    /// null when no NVIDIA driver was found.
    pub nvidia_ok: Option<bool>,
    pub driver_mismatch: bool,
    pub wivrn_running: bool,
    pub active_runtime_is_wivrn: bool,
    /// True when the SteamVR path is usable as-is.
    pub ready: bool,
    /// Plain-language problems, each with its fix.
    pub issues: Vec<String>,
    pub note: String,
}

/// Detect Steam (native vs Flatpak), the installed SteamVR, the
/// NVIDIA driver, and whether WiVRn is in the way. Read-only:
/// nothing here writes SteamVR config or installs anything.
pub fn detect() -> SteamVrDetect {
    detect_in(&home())
}

pub fn detect_in(home: &Path) -> SteamVrDetect {
    detect_with(home, &Probes::real())
}

pub fn detect_with(home: &Path, probes: &Probes) -> SteamVrDetect {
    let mut issues = Vec::new();
    // Steam install: native first, then Flatpak.
    let native_roots = [home.join(".local").join("share").join("Steam"), home.join(".steam").join("steam")];
    let native_root = native_roots.iter().find(|p| p.join("steamapps").exists());
    let flatpak_root = home
        .join(".var")
        .join("app")
        .join(STEAM_FLATPAK_ID)
        .join(".local")
        .join("share")
        .join("Steam");
    let (steam_kind, steam_root) = if let Some(r) = native_root {
        ("native".to_string(), r.clone())
    } else if (probes.flatpak_installed)(STEAM_FLATPAK_ID) || flatpak_root.join("steamapps").exists() {
        ("flatpak".to_string(), flatpak_root)
    } else if (probes.command_exists)("steam") {
        ("native".to_string(), native_roots[0].clone())
    } else {
        (String::new(), PathBuf::new())
    };

    // SteamVR install: scan every library root.
    let mut steamvr_dir = PathBuf::new();
    let mut manifest = PathBuf::new();
    if !steam_root.as_os_str().is_empty() {
        for lib in steam_library_roots(&steam_root) {
            let cand = lib.join("steamapps").join("common").join("SteamVR");
            if looks_like_steamvr(&cand) {
                steamvr_dir = cand;
                manifest = lib.join("steamapps").join(format!("appmanifest_{STEAMVR_APP_ID}.acf"));
                break;
            }
        }
    }
    let steamvr_present = !steamvr_dir.as_os_str().is_empty();
    let (version, buildid) = if steamvr_present {
        steamvr_version(&steamvr_dir, &manifest)
    } else {
        (None, None)
    };
    let version_ok = version.map(|v| version_at_least(v, MIN_STEAMVR));
    let branch = if steamvr_present {
        let beta = std::fs::read_to_string(&manifest)
            .ok()
            .and_then(|t| vdf_value_for(&t, "BetaKey"))
            .map(|b| !b.is_empty())
            .unwrap_or(false);
        if beta {
            "beta".to_string()
        } else {
            "stable".to_string()
        }
    } else {
        "unknown".to_string()
    };

    let (gpu_name, driver) = (probes.nvidia_info)();
    let nvidia_ok = driver.map(|v| version_at_least(v, MIN_NVIDIA_DRIVER));
    let driver_mismatch = driver.and_then(probes.nvidia_driver_mismatch).unwrap_or(false);

    let wivrn_running = (probes.wivrn_running)();
    let active_runtime_is_wivrn = (probes.wivrn_active_runtime)();

    if steam_kind.is_empty() {
        issues.push("Steam is not installed on this computer. Install Steam first, then install SteamVR inside Steam.".into());
    }
    if !steamvr_present {
        issues.push("SteamVR is not installed. In Steam, open the Store and install SteamVR (app 250820). ReOculus never installs it for you.".into());
    }
    if steam_kind == "flatpak" {
        issues.push("Steam here is the Flatpak version, and Steam Link VR reportedly does not work with Flatpak Steam. Install Steam from your distro's native package (.deb) instead, then install SteamVR there.".into());
    }
    if let Some(v) = version {
        if !version_at_least(v, MIN_STEAMVR) {
            issues.push(format!(
                "SteamVR {} is older than 2.18. Update SteamVR in Steam: 2.18 or newer is needed for the Linux Quest fixes.",
                format_version(v)
            ));
        }
    } else if steamvr_present {
        issues.push("Could not read the installed SteamVR version. Open Steam and check SteamVR is 2.18 or newer before starting it.".into());
    }
    if let Some(d) = driver {
        if !version_at_least(d, MIN_NVIDIA_DRIVER) {
            issues.push(format!(
                "NVIDIA driver {} is too old for Steam Link VR, which needs 575.64.05 or newer.",
                format_version(d)
            ));
        }
        if driver_mismatch {
            issues.push("The NVIDIA kernel module version does not match the userspace driver version. That mismatch breaks Vulkan for SteamVR (error 303). Reinstall the driver so all parts match.".into());
        }
    } else {
        // No NVIDIA driver found at all: that does not block
        // readiness (an AMD card on Mesa can still work), but the
        // user should check their GPU driver before starting.
        issues.push("No NVIDIA driver was found on this computer. Steam Link VR needs NVIDIA 575.64.05 or newer, or Mesa 25.2.2 or newer for AMD cards.".into());
    }
    if wivrn_running {
        issues.push("The WiVRn server is running. Stop it before starting SteamVR: the two runtimes fight over the same headset.".into());
    }

    let ready = steamvr_present
        && steam_kind == "native"
        && version_ok != Some(false)
        && nvidia_ok != Some(false)
        && !driver_mismatch;
    let mut note = if ready {
        "SteamVR looks ready. Start it, then open Steam Link on the headset and connect to this PC.".to_string()
    } else if steamvr_present {
        "SteamVR is installed but something above needs fixing first.".to_string()
    } else {
        "SteamVR is not installed yet. It comes from Steam, ReOculus never installs it.".to_string()
    };
    if gpu_name.as_deref().map(|g| g.contains("1050 Ti")).unwrap_or(false) {
        note.push_str(" This PC has a GTX 1050 Ti, and Steam Link on that card is untested: if video fails to start (errors 405/499), switch back to WiVRn.");
    }
    SteamVrDetect {
        steam_kind,
        steam_path: steam_root.display().to_string(),
        steamvr_present,
        steamvr_dir: steamvr_dir.display().to_string(),
        steamvr_version: version.map(format_version),
        steamvr_buildid: buildid,
        steamvr_branch: branch,
        version_ok,
        gpu_name,
        nvidia_driver: driver.map(format_version),
        nvidia_ok,
        driver_mismatch,
        wivrn_running,
        active_runtime_is_wivrn,
        ready,
        issues,
        note,
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SteamVrStatus {
    pub running: bool,
    pub wivrn_running: bool,
    pub active_runtime_is_wivrn: bool,
}

/// Live SteamVR status: is a SteamVR server process running, is
/// WiVRn running, is WiVRn the active OpenXR runtime.
pub fn status() -> SteamVrStatus {
    let wivrn = crate::wivrn::status();
    SteamVrStatus {
        running: steamvr_running(),
        wivrn_running: wivrn.running,
        active_runtime_is_wivrn: wivrn.active_runtime_is_wivrn,
    }
}

// ---- Runtime config backup / restore -------------------------------------
// Monadeck pattern, with ReOculus's own code: snapshot the two
// shared runtime files before switching, restore them when
// SteamVR stops. The snapshot is taken once and kept until a
// restore, so a crashed session cannot overwrite the original.

fn backup_dir(home: &Path) -> PathBuf {
    config_dir(home).join("runtime-backup")
}

fn active_runtime_path(home: &Path) -> PathBuf {
    home.join(".config").join("openxr").join("1").join("active_runtime.json")
}

fn openvrpaths_path(home: &Path) -> PathBuf {
    home.join(".config").join("openvr").join("openvrpaths.vrpath")
}

/// Snapshot the shared runtime files, if no snapshot exists yet.
/// Returns true when a fresh snapshot was taken.
pub fn snapshot_runtime_in(home: &Path) -> Result<bool> {
    let dir = backup_dir(home);
    if dir.join("backup.json").exists() {
        return Ok(false);
    }
    std::fs::create_dir_all(&dir)?;
    let mut manifest = BTreeMap::new();
    for (name, src) in [
        ("active_runtime.json", active_runtime_path(home)),
        ("openvrpaths.vrpath", openvrpaths_path(home)),
    ] {
        let existed = src.exists();
        if existed {
            std::fs::copy(&src, dir.join(name))?;
        }
        manifest.insert(name.to_string(), serde_json::json!(existed));
    }
    std::fs::write(
        dir.join("backup.json"),
        serde_json::to_string_pretty(&serde_json::json!({"files": manifest}))?,
    )?;
    Ok(true)
}

/// Restore the snapshotted runtime files and drop the snapshot.
/// A file that did not exist at snapshot time is deleted on
/// restore. Returns a short note for the UI.
pub fn restore_runtime_in(home: &Path) -> Result<String> {
    let dir = backup_dir(home);
    let manifest_path = dir.join("backup.json");
    if !manifest_path.exists() {
        return Ok("No runtime backup to restore.".into());
    }
    let text = std::fs::read_to_string(&manifest_path)?;
    let v: serde_json::Value = serde_json::from_str(&text)?;
    let mut restored = Vec::new();
    let mut removed = Vec::new();
    for (name, dst) in [
        ("active_runtime.json", active_runtime_path(home)),
        ("openvrpaths.vrpath", openvrpaths_path(home)),
    ] {
        let existed = v
            .get("files")
            .and_then(|f| f.get(name))
            .and_then(|b| b.as_bool())
            .unwrap_or(false);
        if existed {
            std::fs::copy(dir.join(name), &dst)?;
            restored.push(name);
        } else {
            let _ = std::fs::remove_file(&dst);
            removed.push(name);
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    Ok(format!(
        "Runtime config restored ({} back, {} removed).",
        restored.join(", "),
        removed.join(", ")
    ))
}

// ---- Start / stop ----------------------------------------------------------

fn steamvr_log(home: &Path) -> PathBuf {
    home.join(".local").join("state").join("quest-companion").join("steamvr.log")
}

#[derive(Debug, Clone, Serialize)]
pub struct SteamVrStart {
    pub message: String,
    pub wivrn_stopped: bool,
    pub runtime_cleared: bool,
    pub running: bool,
    pub log: String,
}

/// Start SteamVR: refuse when it is missing, Flatpak, too old, or
/// already running; stop the WiVRn server first; snapshot the
/// runtime config; clear a stale WiVRn runtime claim so SteamVR
/// can claim it; then launch with `steam -applaunch 250820` and
/// wait up to 20 s for vrserver to appear.
pub fn start() -> Result<SteamVrStart> {
    let home = home();
    let d = detect_in(&home);
    if !d.steamvr_present {
        return Err(Error(
            "SteamVR is not installed. In Steam, install SteamVR (app 250820) first. ReOculus never installs it for you.".into(),
        ));
    }
    if d.steam_kind == "flatpak" {
        return Err(Error(
            "Steam here is the Flatpak version, and Steam Link VR reportedly does not work with Flatpak Steam. Install native Steam, then SteamVR there.".into(),
        ));
    }
    if d.version_ok == Some(false) {
        return Err(Error(format!(
            "SteamVR {} is older than 2.18. Update SteamVR in Steam first.",
            d.steamvr_version.unwrap_or_default()
        )));
    }
    if steamvr_running() {
        return Err(Error("SteamVR is already running. Open Steam Link on the headset to connect.".into()));
    }
    let mut wivrn_stopped = false;
    if d.wivrn_running {
        crate::wivrn::stop()?;
        wivrn_stopped = true;
    }
    snapshot_runtime_in(&home)?;
    // WiVRn claims the OpenXR runtime while connected; if its
    // claim is still in the file after the server stopped, SteamVR
    // cannot claim the runtime. The snapshot above keeps the
    // original, and stop() restores it.
    let mut runtime_cleared = false;
    let runtime_file = active_runtime_path(&home);
    if let Ok(text) = std::fs::read_to_string(&runtime_file) {
        if text.to_lowercase().contains("wivrn") {
            std::fs::remove_file(&runtime_file)?;
            runtime_cleared = true;
        }
    }
    let log = steamvr_log(&home);
    if let Some(parent) = log.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log_f = std::fs::File::create(&log)?;
    let mut child = Command::new("steam")
        .args(["-applaunch", &STEAMVR_APP_ID.to_string()])
        .stdout(Stdio::from(log_f.try_clone()?))
        .stderr(Stdio::from(log_f))
        .stdin(Stdio::null())
        .spawn()
        .map_err(|e| Error(format!("failed to launch SteamVR through Steam: {e}")))?;
    std::mem::forget(child);
    let mut running = false;
    for _ in 0..40 {
        std::thread::sleep(std::time::Duration::from_millis(500));
        if steamvr_running() {
            running = true;
            break;
        }
    }
    let message = if running {
        "SteamVR is running. Open Steam Link on the headset and connect to this PC.".to_string()
    } else {
        "SteamVR was asked to start, but vrserver did not appear within 20 s. Open Steam and check SteamVR started, then try again.".to_string()
    };
    Ok(SteamVrStart {
        message,
        wivrn_stopped,
        runtime_cleared,
        running,
        log: log.display().to_string(),
    })
}

/// Stop SteamVR (SIGTERM vrserver/vrcompositor/vrmonitor, then
/// SIGKILL what is left) and restore the snapshotted runtime
/// config, so the next WiVRn session starts from a clean state.
pub fn stop() -> Result<String> {
    let home = home();
    let mut stopped = false;
    if let Ok(proc) = std::fs::read_dir("/proc") {
        for entry in proc.flatten() {
            let pid: i32 = match entry.file_name().to_string_lossy().parse() {
                Ok(v) => v,
                Err(_) => continue,
            };
            let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else {
                continue;
            };
            let text = String::from_utf8_lossy(&cmdline).replace(char::from(0), " ");
            if text.contains("questctl") {
                continue;
            }
            if text.contains("vrserver") || text.contains("vrcompositor") || text.contains("vrmonitor") {
                unsafe { libc::kill(pid, libc::SIGTERM) };
                stopped = true;
            }
        }
    }
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if !steamvr_running() {
            break;
        }
    }
    if steamvr_running() {
        if let Ok(proc) = std::fs::read_dir("/proc") {
            for entry in proc.flatten() {
                let pid: i32 = match entry.file_name().to_string_lossy().parse() {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else {
                    continue;
                };
                let text = String::from_utf8_lossy(&cmdline).replace(char::from(0), " ");
                if text.contains("questctl") {
                    continue;
                }
                if text.contains("vrserver") || text.contains("vrcompositor") || text.contains("vrmonitor") {
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    let restore_note = restore_runtime_in(&home).unwrap_or_else(|e| format!("Runtime restore failed: {e}"));
    if stopped && !steamvr_running() {
        Ok(format!("SteamVR stopped. {restore_note}"))
    } else if steamvr_running() {
        Err(Error(
            "SteamVR is still running after stopping. Close SteamVR from Steam, then try again.".into(),
        ))
    } else {
        Ok(format!("SteamVR was not running. {restore_note}"))
    }
}

// ---- Per-headset runtime choice --------------------------------------------
// WiVRn is the default. SteamVR + Steam Link is an experimental
// opt-in, stored per headset serial in one JSON file.

fn choice_file(home: &Path) -> PathBuf {
    config_dir(home).join("runtime-choice.json")
}

/// The selected PC VR runtime for one headset: "wivrn" (default)
/// or "steamvr".
pub fn runtime_choice(serial: &str) -> String {
    runtime_choice_in(&home(), serial)
}

pub fn runtime_choice_in(home: &Path, serial: &str) -> String {
    let Ok(text) = std::fs::read_to_string(choice_file(home)) else {
        return "wivrn".into();
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        return "wivrn".into();
    };
    v.get("choices")
        .and_then(|c| c.get(serial))
        .and_then(|r| r.as_str())
        .filter(|r| *r == "wivrn" || *r == "steamvr")
        .unwrap_or("wivrn")
        .to_string()
}

/// Record the PC VR runtime choice for one headset. This only
/// records the choice; starting and stopping the runtimes is a
/// separate step, from the PC VR screen.
pub fn set_runtime_choice(serial: &str, runtime: &str) -> Result<String> {
    set_runtime_choice_in(&home(), serial, runtime)
}

pub fn set_runtime_choice_in(home: &Path, serial: &str, runtime: &str) -> Result<String> {
    if runtime != "wivrn" && runtime != "steamvr" {
        return Err(Error(format!("unknown runtime '{runtime}': use wivrn or steamvr")));
    }
    let file = choice_file(home);
    let mut map: BTreeMap<String, String> = std::fs::read_to_string(&file)
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| v.get("choices").cloned())
        .and_then(|c| serde_json::from_value(c).ok())
        .unwrap_or_default();
    map.insert(serial.to_string(), runtime.to_string());
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        &file,
        serde_json::to_string_pretty(&serde_json::json!({"choices": map}))?,
    )?;
    Ok(if runtime == "steamvr" {
        "SteamVR + Steam Link is now the PC VR runtime for this headset (experimental). WiVRn stays the default for every other headset.".into()
    } else {
        "WiVRn is now the PC VR runtime for this headset.".into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_version_basics() {
        assert_eq!(parse_version("2.18"), Some((2, 18, 0)));
        assert_eq!(parse_version("2.18.0"), Some((2, 18, 0)));
        assert_eq!(parse_version("SteamVR 2.19.1 beta"), Some((2, 19, 1)));
        assert_eq!(parse_version("580.178.04"), Some((580, 178, 4)));
        assert_eq!(parse_version("no version here"), None);
        assert_eq!(parse_version("v1.2"), Some((1, 2, 0)));
    }

    #[test]
    fn version_at_least_checks() {
        assert!(version_at_least((2, 18, 0), MIN_STEAMVR));
        assert!(version_at_least((2, 19, 1), MIN_STEAMVR));
        assert!(!version_at_least((2, 17, 5), MIN_STEAMVR));
        assert!(version_at_least((575, 64, 5), MIN_NVIDIA_DRIVER));
        assert!(!version_at_least((575, 64, 4), MIN_NVIDIA_DRIVER));
        assert!(!version_at_least((535, 183, 1), MIN_NVIDIA_DRIVER));
    }

    #[test]
    fn parse_library_paths_vdf() {
        let vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/home/anthony/.local/share/Steam\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"/mnt/games/Steam\"\n\t}\n}\n";
        assert_eq!(
            parse_library_paths(vdf),
            vec!["/home/anthony/.local/share/Steam".to_string(), "/mnt/games/Steam".to_string()]
        );
    }

    #[test]
    fn vdf_value_for_buildid_and_beta() {
        let acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"250820\"\n\t\"buildid\"\t\t\"23791826\"\n\t\"UserConfig\"\n\t{\n\t\t\"BetaKey\"\t\t\"beta\"\n\t}\n}\n";
        assert_eq!(vdf_value_for(acf, "buildid"), Some("23791826".to_string()));
        assert_eq!(vdf_value_for(acf, "BetaKey"), Some("beta".to_string()));
        assert_eq!(vdf_value_for(acf, "missing"), None);
    }

    fn fake_steam_tree() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join(".local").join("share").join("Steam");
        let common = root.join("steamapps").join("common").join("SteamVR").join("bin").join("linux64");
        std::fs::create_dir_all(&common).unwrap();
        std::fs::write(common.join("vrserver"), b"fake").unwrap();
        std::fs::write(
            root.join("steamapps").join("common").join("SteamVR").join("version.txt"),
            b"2.18.0\n",
        )
        .unwrap();
        std::fs::write(
            root.join("steamapps").join("appmanifest_250820.acf"),
            "\"AppState\"\n{\n\t\"appid\"\t\t\"250820\"\n\t\"buildid\"\t\t\"24000000\"\n}\n",
        )
        .unwrap();
        dir
    }

    #[test]
    fn detect_in_fake_native_steamvr() {
        let dir = fake_steam_tree();
        let d = detect_with(dir.path(), &Probes::stub());
        assert_eq!(d.steam_kind, "native");
        assert!(d.steamvr_present);
        assert_eq!(d.steamvr_version.as_deref(), Some("2.18.0"));
        assert_eq!(d.version_ok, Some(true));
        assert_eq!(d.steamvr_branch, "stable");
        // The stub has no GPU at all, which is an informational
        // issue, not a readiness blocker (an AMD card on Mesa can
        // still work), so the fake install still reads as ready.
        assert!(d.issues.iter().any(|i| i.contains("No NVIDIA driver")));
        assert!(d.ready);
        assert!(!d.wivrn_running);
    }

    #[test]
    fn detect_in_old_steamvr_is_not_ok() {
        let dir = fake_steam_tree();
        let root = dir.path().join(".local").join("share").join("Steam");
        std::fs::write(
            root.join("steamapps").join("common").join("SteamVR").join("version.txt"),
            b"2.16.7\n",
        )
        .unwrap();
        let d = detect_with(dir.path(), &Probes::stub());
        assert_eq!(d.version_ok, Some(false));
        assert!(!d.ready);
        assert!(d.issues.iter().any(|i| i.contains("older than 2.18")));
    }

    #[test]
    fn detect_in_no_steam_at_all() {
        let dir = tempfile::tempdir().unwrap();
        let d = detect_with(dir.path(), &Probes::stub());
        assert_eq!(d.steam_kind, "");
        assert!(!d.steamvr_present);
        assert!(!d.ready);
        assert!(d.issues.iter().any(|i| i.contains("Steam is not installed")));
    }

    #[test]
    fn snapshot_restore_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let xr = home.join(".config").join("openxr").join("1");
        let vr = home.join(".config").join("openvr");
        std::fs::create_dir_all(&xr).unwrap();
        std::fs::create_dir_all(&vr).unwrap();
        std::fs::write(xr.join("active_runtime.json"), "{\"file_format_version\": \"1.0.0\", \"runtime\": {\"name\": \"WiVRn\"}}").unwrap();
        std::fs::write(vr.join("openvrpaths.vrpath"), "{\"runtime\": [\"/old\"]}").unwrap();
        assert!(snapshot_runtime_in(home).unwrap());
        // A second snapshot keeps the first one, it never
        // overwrites the original.
        assert!(!snapshot_runtime_in(home).unwrap());
        // Simulate SteamVR changing the files, then restore.
        std::fs::write(xr.join("active_runtime.json"), "{\"runtime\": {\"name\": \"SteamVR\"}}").unwrap();
        std::fs::remove_file(vr.join("openvrpaths.vrpath")).unwrap();
        let note = restore_runtime_in(home).unwrap();
        assert!(note.contains("restored"));
        assert!(std::fs::read_to_string(xr.join("active_runtime.json")).unwrap().contains("WiVRn"));
        assert!(std::fs::read_to_string(vr.join("openvrpaths.vrpath")).unwrap().contains("/old"));
        assert!(!backup_dir(home).exists());
    }

    #[test]
    fn snapshot_restore_missing_files() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        assert!(snapshot_runtime_in(home).unwrap());
        // Files created after the snapshot are removed on restore.
        let xr = home.join(".config").join("openxr").join("1");
        std::fs::create_dir_all(&xr).unwrap();
        std::fs::write(xr.join("active_runtime.json"), "{\"runtime\": {\"name\": \"SteamVR\"}}").unwrap();
        restore_runtime_in(home).unwrap();
        assert!(!xr.join("active_runtime.json").exists());
    }

    #[test]
    fn runtime_choice_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        assert_eq!(runtime_choice_in(home, "TESTSERIAL000001"), "wivrn");
        set_runtime_choice_in(home, "TESTSERIAL000001", "steamvr").unwrap();
        assert_eq!(runtime_choice_in(home, "TESTSERIAL000001"), "steamvr");
        // Other headsets stay on the default.
        assert_eq!(runtime_choice_in(home, "OTHER000000002"), "wivrn");
        set_runtime_choice_in(home, "TESTSERIAL000001", "wivrn").unwrap();
        assert_eq!(runtime_choice_in(home, "TESTSERIAL000001"), "wivrn");
        assert!(set_runtime_choice_in(home, "TESTSERIAL000001", "alvr").is_err());
    }
}
