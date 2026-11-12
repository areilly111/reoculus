//! WiVRn GUI wrapper: control the unmodified WiVRn 26.9 server
//! from the companion app. WiVRn has no documented API (no D-Bus,
//! no REST), so control is config-file + process management +
//! polling, per the 2026-11-12 research report. WiVRn and xrizer
//! are GPLv3; the wrapper spawns the system/Flatpak binaries as
//! separate processes and never links or bundles their code.
//!
//! Server: `wivrn-server` (native) or
//! `flatpak run --command=wivrn-server io.github.wivrn.wivrn`.
//! Config: `~/.config/wivrn/config.json` (native) or
//! `~/.var/app/io.github.wivrn.wivrn/config/wivrn/config.json`
//! (Flatpak). Ports: 9757 TCP/UDP (WiVRn), 5353/UDP (Avahi).
//! Client and server must be the same version (26.9).

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::Serialize;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub const WIVRN_VERSION: &str = "26.9";
pub const WIVRN_FLATPAK_ID: &str = "io.github.wivrn.wivrn";

fn home() -> PathBuf {
    // No username is ever hardcoded: $HOME wins, and the fallback
    // is only for environments without one set.
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

/// User config path for the native install.
pub fn config_path_native() -> PathBuf {
    home().join(".config").join("wivrn").join("config.json")
}

/// User config path for the Flatpak install.
pub fn config_path_flatpak() -> PathBuf {
    home()
        .join(".var")
        .join("app")
        .join(WIVRN_FLATPAK_ID)
        .join("config")
        .join("wivrn")
        .join("config.json")
}

fn flatpak_installed() -> bool {
    Command::new("flatpak")
        .args(["info", WIVRN_FLATPAK_ID])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn native_server() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let cand = dir.join("wivrn-server");
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    None
}

/// Which server install is present, if any.
#[derive(Debug, Clone, Serialize)]
pub struct WivrnDetect {
    pub installed: bool,
    /// "native", "flatpak", or "" when not installed.
    pub kind: String,
    pub server_version: String,
    pub wivrnctl: bool,
    pub avahi_active: bool,
    pub pipewire: bool,
    pub port_listening: bool,
    pub config_exists: bool,
    pub config_path: String,
    pub note: String,
}

fn run_output(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

fn flatpak_version() -> String {
    let out = run_output("flatpak", &["info", WIVRN_FLATPAK_ID]).unwrap_or_default();
    for line in out.lines() {
        let t = line.trim();
        if let Some(v) = t.strip_prefix("Version:") {
            return v.trim().to_string();
        }
    }
    String::new()
}

fn port_listening(port: u16) -> bool {
    let out = run_output("ss", &["-tln"]).unwrap_or_default();
    out.lines().any(|l| l.contains(&format!(":{port}")))
}

fn avahi_active() -> bool {
    run_output("systemctl", &["is-active", "avahi-daemon"])
        .map(|s| s.trim() == "active")
        .unwrap_or(false)
}

fn pipewire_running() -> bool {
    run_output("pactl", &["info"]).map(|s| s.contains("PipeWire")).unwrap_or(false)
        || Command::new("pgrep")
            .args(["-x", "pipewire"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
}

pub fn detect() -> WivrnDetect {
    let native = native_server();
    let flat = flatpak_installed();
    let (installed, kind, version) = if native.is_some() {
        let v = run_output("wivrn-server", &["--version"])
            .unwrap_or_default()
            .trim()
            .to_string();
        (true, "native".to_string(), v)
    } else if flat {
        (true, "flatpak".to_string(), flatpak_version())
    } else {
        (false, String::new(), String::new())
    };
    let config_path = if kind == "flatpak" {
        config_path_flatpak()
    } else {
        config_path_native()
    };
    WivrnDetect {
        installed,
        kind,
        server_version: version,
        wivrnctl: run_output("which", &["wivrnctl"]).is_some(),
        avahi_active: avahi_active(),
        pipewire: pipewire_running(),
        port_listening: port_listening(9757),
        config_exists: config_path.exists(),
        config_path: config_path.display().to_string(),
        note: if installed {
            "WiVRn 26.9 server found. Start it, then connect from the WiVRn app on the headset (same version 26.9).".into()
        } else {
            "WiVRn is not installed. Install the Flatpak with: flatpak install --user flathub io.github.wivrn.wivrn".into()
        },
    }
}

/// Known config keys (WiVRn 26.9 docs/configuration.md). `bitrate`,
/// `scale` and `encoders` (plural) are NOT server keys: bitrate is a
/// headset-side setting, and `encoders` silently does nothing.
pub const KNOWN_KEYS: &[&str] = &[
    "bit-depth",
    "encoder",
    "application",
    "tcp-only",
    "publish-service",
    "openvr-compat-path",
    "hid-forwarding",
    "debug-gui",
    "use-steamvr-lh",
    "lh-max-extrapolation",
    "lh-stick-deadzone",
    "port",
    "hostname",
];

pub fn read_config() -> Result<serde_json::Value> {
    let d = detect();
    let path = PathBuf::from(&d.config_path);
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let text = std::fs::read_to_string(&path)?;
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| Error(format!("WiVRn config is not valid JSON: {e}")))?;
    Ok(v)
}

/// Write the encoder/codec into the user config, preserving every
/// other key (including pairing state in the same directory).
/// Rejects unknown keys and the stale `encoders`/`bitrate`/`scale`.
pub fn write_config(encoder: &str, codec: &str) -> Result<String> {
    let allowed_encoders = ["vulkan", "nvenc", "vaapi", "x264"];
    let allowed_codecs = ["h264", "h265", "av1", "raw"];
    if !allowed_encoders.contains(&encoder) {
        return Err(Error(format!(
            "unknown encoder '{encoder}': use vulkan, nvenc, vaapi or x264"
        )));
    }
    if !allowed_codecs.contains(&codec) {
        return Err(Error(format!(
            "unknown codec '{codec}': use h264, h265, av1 or raw"
        )));
    }
    let d = detect();
    let path = PathBuf::from(&d.config_path);
    let mut v = if path.exists() {
        let text = std::fs::read_to_string(&path)?;
        serde_json::from_str(&text).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };
    if let Some(obj) = v.as_object_mut() {
        for key in obj.keys() {
            if !KNOWN_KEYS.contains(&key.as_str()) {
                return Err(Error(format!(
                    "WiVRn config already has unknown key '{key}' (not a 26.9 server key). Remove it before the wrapper writes config."
                )));
            }
        }
        if obj.contains_key("encoders") || obj.contains_key("bitrate") || obj.contains_key("scale") {
            return Err(Error(
                "'encoders', 'bitrate' and 'scale' are not WiVRn 26.9 server keys; bitrate is set in the headset app.".into(),
            ));
        }
        obj.insert(
            "encoder".to_string(),
            serde_json::json!({"encoder": encoder, "codec": codec}),
        );
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap())?;
    Ok(path.display().to_string())
}

fn pid_file() -> PathBuf {
    home()
        .join(".config")
        .join("quest-companion")
        .join("wivrn.pid")
}

fn log_file() -> PathBuf {
    home()
        .join(".local")
        .join("state")
        .join("quest-companion")
        .join("wivrn-server.log")
}

fn pid_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

#[derive(Debug, Clone, Serialize)]
pub struct WivrnStatus {
    pub running: bool,
    pub pid: Option<i32>,
    pub port_listening: bool,
    pub active_runtime_is_wivrn: bool,
    pub pipewire_nodes: bool,
    pub log_tail: Vec<String>,
}

pub fn status() -> WivrnStatus {
    let pid = std::fs::read_to_string(pid_file())
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok());
    let running = pid.map(pid_alive).unwrap_or(false) || port_listening(9757);
    let runtime = home()
        .join(".config")
        .join("openxr")
        .join("1")
        .join("active_runtime.json");
    let active_runtime_is_wivrn = std::fs::read_to_string(runtime)
        .map(|s| s.contains("wivrn"))
        .unwrap_or(false);
    let pipewire_nodes = run_output("pactl", &["list", "sinks", "short"])
        .map(|s| s.to_lowercase().contains("wivrn"))
        .unwrap_or(false);
    let log_tail = std::fs::read_to_string(log_file())
        .map(|s| {
            s.lines()
                .rev()
                .take(30)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .map(|l| l.to_string())
                .collect()
        })
        .unwrap_or_default();
    WivrnStatus {
        running,
        pid: if running { pid } else { None },
        port_listening: port_listening(9757),
        active_runtime_is_wivrn,
        pipewire_nodes,
        log_tail,
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct WivrnStart {
    pub pid: u32,
    pub command: String,
    pub log: String,
}

/// Start the WiVRn server as a child process (separate process,
/// unmodified binary). Refuses to start a second copy.
pub fn start() -> Result<WivrnStart> {
    let st = status();
    if st.running {
        return Err(Error(
            "WiVRn server is already running (port 9757 is listening or the PID file is alive). Stop it first.".into(),
        ));
    }
    let d = detect();
    if !d.installed {
        return Err(Error(d.note));
    }
    if !d.avahi_active {
        return Err(Error(
            "avahi-daemon is not running; WiVRn needs it to publish the server. Run: sudo systemctl enable --now avahi-daemon".into(),
        ));
    }
    let log = log_file();
    if let Some(parent) = log.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log_f = std::fs::File::create(&log)?;
    let mut cmd: Command = if d.kind == "flatpak" {
        let mut c = Command::new("flatpak");
        c.args(["run", "--command=wivrn-server", WIVRN_FLATPAK_ID]);
        c
    } else {
        Command::new("wivrn-server")
    };
    cmd.stdout(Stdio::from(log_f.try_clone()?))
        .stderr(Stdio::from(log_f))
        .stdin(Stdio::null());
    let mut child = cmd
        .spawn()
        .map_err(|e| Error(format!("failed to start wivrn-server: {e}")))?;
    let pid = child.id();
    std::thread::sleep(std::time::Duration::from_millis(1500));
    if let Ok(Some(code)) = child.try_wait() {
        return Err(Error(format!(
            "wivrn-server exited immediately (status {code}). Exit 4 means avahi-daemon is not running. See the log: {}",
            log.display()
        )));
    }
    // Detach: the PID file is the handle; stop() kills it.
    std::mem::forget(child);
    if let Some(parent) = pid_file().parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(pid_file(), pid.to_string())?;
    Ok(WivrnStart {
        pid,
        command: if d.kind == "flatpak" {
            format!("flatpak run --command=wivrn-server {WIVRN_FLATPAK_ID}")
        } else {
            "wivrn-server".into()
        },
        log: log.display().to_string(),
    })
}

/// Stop the server we started (SIGTERM, then SIGKILL after 3 s).
///
/// Flatpak trap (verified live 2026-11-12): the recorded PID is the
/// `flatpak run` launcher, and SIGTERM to it does NOT kill the
/// `wivrn-server` inside the bwrap sandbox, so the port stays open.
/// After killing the recorded PID, also SIGTERM every process whose
/// cmdline contains `wivrn-server`, then SIGKILL what is left.
pub fn stop() -> Result<String> {
    let pid = std::fs::read_to_string(pid_file())
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok());
    let mut stopped = false;
    if let Some(pid) = pid {
        if pid_alive(pid) {
            unsafe { libc::kill(pid, libc::SIGTERM) };
            stopped = true;
        }
    }
    // Kill the actual server process, not just the launcher.
    if let Ok(proc) = std::fs::read_dir("/proc") {
        for entry in proc.flatten() {
            let pid2: i32 = match entry.file_name().to_string_lossy().parse() {
                Ok(v) => v,
                Err(_) => continue,
            };
            let cmdline = match std::fs::read(entry.path().join("cmdline")) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let text = String::from_utf8_lossy(&cmdline).replace(char::from(0), " ");
            if text.contains("wivrn-server") && !text.contains("questctl") {
                unsafe { libc::kill(pid2, libc::SIGTERM) };
                stopped = true;
            }
        }
    }
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if !port_listening(9757) {
            break;
        }
    }
    if port_listening(9757) {
        if let Ok(proc) = std::fs::read_dir("/proc") {
            for entry in proc.flatten() {
                let pid2: i32 = match entry.file_name().to_string_lossy().parse() {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let cmdline = match std::fs::read(entry.path().join("cmdline")) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let text = String::from_utf8_lossy(&cmdline).replace(char::from(0), " ");
                if text.contains("wivrn-server") && !text.contains("questctl") {
                    unsafe { libc::kill(pid2, libc::SIGKILL) };
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    let _ = std::fs::remove_file(pid_file());
    if stopped && !port_listening(9757) {
        Ok("WiVRn server stopped.".into())
    } else if port_listening(9757) {
        Err(Error(
            "Port 9757 is still listening after stopping; another wivrn-server (or the dashboard) is running. Close it first.".into(),
        ))
    } else {
        Ok("WiVRn server was not running.".into())
    }
}

/// Installed WiVRn client version on the headset, if any.
/// Checks the Store package first, then the GitHub APK package.
pub fn headset_client_version(t: &dyn AdbTransport, serial: &str) -> Option<String> {
    let target = Target::serial(serial);
    for pkg in ["org.meumeu.wivrn", "org.meumeu.wivrn.github"] {
        if let Ok(o) = t.shell(&target, &format!("dumpsys package {pkg} | grep versionName")) {
            let v = o.stdout.trim();
            if let Some(v) = v.strip_prefix("versionName=") {
                return Some(v.trim().to_string());
            }
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

// ---- First-run setup -----------------------------------------------------
// On the first headset connection the app offers to install the
// WiVRn client APK, then sets up USB (adb reverse + launch) and
// Wi-Fi (already handled by the app's auto-wireless) so the user
// just presses Connect. If the user says no, that is recorded in a
// `wivrn-declined` file; the PC VR screen greys out and offers an
// Install button that clears the decline and runs setup again.

pub const WIVRN_APK_URL: &str =
    "https://github.com/WiVRn/WiVRn/releases/download/v26.9/WiVRn-release.apk";
pub const WIVRN_APK_NAME: &str = "WiVRn-release.apk";

fn declined_file() -> PathBuf {
    home().join(".config").join("quest-companion").join("wivrn-declined")
}

pub fn is_declined() -> bool {
    declined_file().exists()
}

pub fn set_declined(declined: bool) -> Result<String> {
    let f = declined_file();
    if declined {
        if let Some(parent) = f.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&f, "declined")?;
        Ok("Noted: PC VR will stay off until you tap Install.".into())
    } else {
        let _ = std::fs::remove_file(&f);
        Ok("Decline cleared.".into())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct WivrnSetupState {
    pub client_version: Option<String>,
    pub client_package: Option<String>,
    pub server_installed: bool,
    pub server_version: String,
    pub declined: bool,
    pub matching: bool,
}

pub fn setup_state(t: &dyn AdbTransport, serial: &str) -> WivrnSetupState {
    let d = detect();
    let mut client_version = None;
    let mut client_package = None;
    for pkg in ["org.meumeu.wivrn", "org.meumeu.wivrn.github"] {
        if let Some(v) = headset_client_version_for(t, serial, pkg) {
            client_version = Some(v);
            client_package = Some(pkg.to_string());
            break;
        }
    }
    let matching = client_version.as_deref() == Some(WIVRN_VERSION) && d.installed;
    WivrnSetupState {
        client_version,
        client_package,
        server_installed: d.installed,
        server_version: d.server_version,
        declined: is_declined(),
        matching,
    }
}

fn headset_client_version_for(t: &dyn AdbTransport, serial: &str, pkg: &str) -> Option<String> {
    let target = Target::serial(serial);
    let o = t
        .shell(&target, &format!("dumpsys package {pkg} | grep versionName"))
        .ok()?;
    let v = o.stdout.trim();
    if let Some(v) = v.strip_prefix("versionName=") {
        return Some(v.trim().to_string());
    }
    if v.is_empty() {
        None
    } else {
        Some(v.to_string())
    }
}

fn adb_path() -> PathBuf {
    crate::transport::resolve_adb_path().unwrap_or_else(|_| PathBuf::from("adb"))
}

fn adb_run(args: &[&str]) -> Result<String> {
    let out = Command::new(adb_path())
        .args(args)
        .output()
        .map_err(|e| Error(format!("failed to run adb: {e}")))?;
    if !out.status.success() {
        return Err(Error(format!(
            "adb {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Download the matching GitHub client APK (26.9) and install it
/// over ADB. Verifies the download is a real APK (>10 MB) first.
pub fn install_client(t: &dyn AdbTransport, serial: &str) -> Result<String> {
    if let Some(v) = headset_client_version(t, serial) {
        if v == WIVRN_VERSION {
            let _ = set_declined(false);
            return Ok(format!("WiVRn {v} is already on the headset."));
        }
    }
    let dir = home().join(".cache").join("quest-companion").join("wivrn");
    std::fs::create_dir_all(&dir)?;
    let apk = dir.join(WIVRN_APK_NAME);
    if !apk.exists() || std::fs::metadata(&apk).map(|m| m.len()).unwrap_or(0) < 10_000_000 {
        let status = Command::new("curl")
            .args(["-fL", "--progress-bar", "-o"])
            .arg(&apk)
            .arg(WIVRN_APK_URL)
            .status()
            .map_err(|e| Error(format!("failed to run curl: {e}")))?;
        if !status.success() {
            return Err(Error(
                "Could not download the WiVRn 26.9 APK from GitHub. Check the PC is online and try again.".into(),
            ));
        }
    }
    if std::fs::metadata(&apk).map(|m| m.len()).unwrap_or(0) < 10_000_000 {
        return Err(Error("The downloaded WiVRn APK is too small to be real; the download failed.".into()));
    }
    t.install(&Target::serial(serial), &[apk.clone()], true)?;
    let _ = set_declined(false);
    Ok(format!(
        "WiVRn {} installed on the headset from {}.",
        WIVRN_VERSION,
        apk.display()
    ))
}

/// Set up the USB link for WiVRn: adb reverse 9757, then launch
/// the client pointed at the local tunnel. Returns the package
/// launched. On 26.9 the Store client also has a native USB mode;
/// the reverse tunnel is the fallback that always works.
pub fn setup_usb(t: &dyn AdbTransport, serial: &str) -> Result<String> {
    let devices = t.list_devices().unwrap_or_default();
    let is_usb = devices
        .iter()
        .any(|d| d.serial == serial && d.transport == "usb");
    if !is_usb {
        return Err(Error(
            "No USB headset found. Plug the headset in with the cable, then try again.".into(),
        ));
    }
    adb_run(&["-s", serial, "reverse", "tcp:9757", "tcp:9757"])?;
    let pkg = headset_client_version_for(t, serial, "org.meumeu.wivrn.github")
        .map(|_| "org.meumeu.wivrn.github".to_string())
        .or_else(|| {
            headset_client_version_for(t, serial, "org.meumeu.wivrn")
                .map(|_| "org.meumeu.wivrn".to_string())
        });
    let pkg = match pkg {
        Some(p) => p,
        None => {
            return Err(Error(
                "WiVRn is not installed on the headset yet. Install it first.".into(),
            ))
        }
    };
    let _ = t.shell(
        &Target::serial(serial),
        &format!("am start -a android.intent.action.VIEW -d \"wivrn+tcp://localhost\" {pkg}"),
    );
    Ok(format!(
        "USB link ready (adb reverse 9757) and WiVRn ({pkg}) launched on the headset. Tap the server in the WiVRn app to connect."
    ))
}

/// Find the WiVRn server Flatpak bundle shipped inside the app
/// (next to questctl in the AppImage), if present.
pub fn bundled_server_file() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        // AppImage layout: <mount>/usr/bin/questctl and
        // <mount>/usr/share/quest-companion/wivrn-server.flatpak.
        if let Some(bin) = exe.parent() {
            candidates.push(bin.join("..").join("share").join("quest-companion").join("wivrn-server.flatpak"));
            candidates.push(bin.join("wivrn-server.flatpak"));
        }
    }
    candidates.push(home().join(".local").join("share").join("quest-companion").join("wivrn-server.flatpak"));
    candidates.push(PathBuf::from("/usr/share/quest-companion/wivrn-server.flatpak"));
    for c in candidates {
        if c.exists() {
            return Some(c);
        }
    }
    None
}

/// Install the WiVRn server from the flatpak bundle shipped inside
/// the appimage (wivrn-server.flatpak, 26.9), if the server is not
/// installed yet. Runs `flatpak install --user` on the bundle file;
/// the KDE Platform runtime is still fetched from Flathub on first
/// install if it is not already on the PC.
pub fn install_server() -> Result<String> {
    let d = detect();
    if d.installed {
        return Ok(format!("WiVRn {} is already installed ({}).", d.server_version, d.kind));
    }
    let bundle = bundled_server_file().ok_or_else(|| {
        Error("The bundled WiVRn server was not found inside this app. Install it with: flatpak install --user flathub io.github.wivrn.wivrn".into())
    })?;
    let out = Command::new("flatpak")
        .args(["install", "--user", "-y"])
        .arg(&bundle)
        .output()
        .map_err(|e| Error(format!("failed to run flatpak: {e}")))?;
    if !out.status.success() {
        return Err(Error(format!(
            "flatpak install failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let d2 = detect();
    if !d2.installed {
        return Err(Error(
            "flatpak install finished but no WiVRn server was found afterwards. Try: flatpak install --user flathub io.github.wivrn.wivrn".into(),
        ));
    }
    Ok(format!("WiVRn {} server installed from the bundled file.", d2.server_version))
}
