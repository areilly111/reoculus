//! ADB transport behind one trait.
//!
//! Two implementations:
//! * [`AdbBinaryTransport`] (default): spawns the system `adb` binary.
//!   This is the pragmatic MVP transport: zero protocol risk, full
//!   `adb pair` / TLS pairing support, sync push/pull/install for free
//!   (the binary speaks the sync protocol itself). Cost: needs an adb
//!   binary on the host, which Android cannot rely on.
//! * [`DirectTransport`]: speaks the ADB wire protocol directly with
//!   `libadb` 0.9 (tokio TCP + TLS + SPAKE2 pairing, no adb binary).
//!   TCP/Wi-Fi only in this build: shell + exec-out + TLS pairing.
//!   Device discovery and sync push/pull/install over direct transport
//!   are not implemented yet and return a clear error telling the
//!   caller to use the binary transport.
//!
//! The Flutter UI / `questctl` only ever talks to [`AdbTransport`].

use crate::error::{Error, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceState {
    Device,
    Unauthorized,
    Offline,
    #[serde(rename = "no permissions")]
    NoPermissions,
    Unknown,
}

impl DeviceState {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeviceState::Device => "device",
            DeviceState::Unauthorized => "unauthorized",
            DeviceState::Offline => "offline",
            DeviceState::NoPermissions => "no permissions",
            DeviceState::Unknown => "unknown",
        }
    }
}

impl From<&str> for DeviceState {
    fn from(s: &str) -> Self {
        match s {
            "device" => DeviceState::Device,
            "unauthorized" => DeviceState::Unauthorized,
            "offline" => DeviceState::Offline,
            "no permissions" => DeviceState::NoPermissions,
            _ => DeviceState::Unknown,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Device {
    pub serial: String,
    pub state: DeviceState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Device codename from `adb devices -l` (`monterey`, `hollywood`, ...).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Classified headset slug (`quest1`, `quest2`, ...).
    pub headset_model: String,
    pub transport: String, // "usb" | "wifi"
}

#[derive(Debug, Clone)]
pub struct CmdOutput {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

impl CmdOutput {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
}

/// What a command targets. Binary transport uses `serial`; direct
/// transport uses `addr` (`ip:port`).
#[derive(Debug, Clone, Default)]
pub struct Target {
    pub serial: Option<String>,
    pub addr: Option<String>,
}

impl Target {
    pub fn serial(s: &str) -> Self {
        Target {
            serial: Some(s.to_string()),
            addr: None,
        }
    }
    pub fn addr(a: &str) -> Self {
        Target {
            serial: None,
            addr: Some(a.to_string()),
        }
    }
    /// For direct transport: explicit addr, or a serial that is already
    /// an `ip:port` (as `adb devices` shows Wi-Fi devices).
    pub fn addr_or_serial(&self) -> Option<String> {
        if let Some(a) = &self.addr {
            return Some(a.clone());
        }
        match &self.serial {
            Some(s) if s.contains(':') => Some(s.clone()),
            _ => None,
        }
    }
}

pub trait AdbTransport {
    fn name(&self) -> &'static str;
    fn list_devices(&self) -> Result<Vec<Device>>;
    fn shell(&self, target: &Target, cmd: &str) -> Result<CmdOutput>;
    /// Binary-safe: no PTY, no CR/LF mangling (used for screencap).
    fn exec_out(&self, target: &Target, argv: &[&str]) -> Result<Vec<u8>>;
    fn push(&self, target: &Target, local: &Path, remote: &str) -> Result<()>;
    fn pull(&self, target: &Target, remote: &str, local: &Path) -> Result<()>;
    /// Install APKs in one session. Returns the raw adb output on success.
    fn install(&self, target: &Target, apks: &[PathBuf], reinstall: bool) -> Result<String>;
    fn logcat_dump(&self, target: &Target) -> Result<Vec<String>>;
    /// Modern wireless pairing: `adb pair ip:port` + 6-digit code.
    /// Returns the device GUID reported by the device.
    fn pair_tls(&self, ip: &str, port: u16, code: &str) -> Result<String>;
    /// Plain `adb connect ip:port` (used after pairing).
    fn connect_tcp(&self, ip: &str, port: u16) -> Result<String>;
    /// Legacy `adb tcpip 5555` over a USB connection.
    fn tcpip(&self, target: &Target, port: u16) -> Result<()>;
    /// Reboot the device (`adb -s <serial> reboot`).
    fn reboot(&self, target: &Target) -> Result<()>;
    /// Disconnect a Wi-Fi device from the adb server
    /// (`adb disconnect <serial>`). Returns the adb message.
    fn disconnect(&self, serial: &str) -> Result<String>;
}

// ---------------------------------------------------------------------------
// Parsing (pure, unit-tested)
// ---------------------------------------------------------------------------

/// Parse `adb devices -l` output. Line format:
/// `<serial>\t<state> [product:...] [model:...] [device:...] [transport_id:...]`
pub fn parse_devices_output(text: &str) -> Vec<Device> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with("List of devices") || line.starts_with('*') {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.is_empty() {
            continue;
        }
        let serial = parts[0].to_string();
        // State is one token, except "no permissions" (two words).
        let (state, rest) = if parts.len() > 2 && parts[1] == "no" && parts[2] == "permissions" {
            (DeviceState::NoPermissions, &parts[3..])
        } else {
            (DeviceState::from(parts.get(1).copied().unwrap_or("unknown")), &parts[2..])
        };
        let mut model = None;
        let mut device = None;
        for kv in rest {
            if let Some(m) = kv.strip_prefix("model:") {
                model = Some(m.replace('_', " "));
            }
            if let Some(d) = kv.strip_prefix("device:") {
                device = Some(d.to_string());
            }
        }
        let headset_model = crate::headset::classify(
            model.as_deref().unwrap_or(""),
            device.as_deref().unwrap_or(""),
        )
        .slug()
        .to_string();
        // Wi-Fi devices show as ip:port serials.
        let transport = if serial.contains(':') && serial.split(':').next().map_or(false, |h| h.chars().next().map_or(false, |c| c.is_ascii_digit())) {
            "wifi".to_string()
        } else {
            "usb".to_string()
        };
        out.push(Device {
            serial,
            state,
            model,
            device,
            headset_model,
            transport,
        });
    }
    out
}

/// Resolve the adb binary to run, in priority order:
/// `QUEST_COMPANION_ADB`, `QUEST_ADB`, the Android SDK platform-tools
/// bundled on this machine, then `adb` on PATH.
pub fn resolve_adb_path() -> Result<PathBuf> {
    for var in ["QUEST_COMPANION_ADB", "QUEST_ADB"] {
        if let Ok(p) = std::env::var(var) {
            let p = PathBuf::from(p);
            if p.exists() {
                return Ok(p);
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let sdk = PathBuf::from(&home)
            .join("workspace")
            .join("android-sdk")
            .join("platform-tools")
            .join("adb");
        if sdk.exists() {
            return Ok(sdk);
        }
        let local = PathBuf::from(&home)
            .join("Android")
            .join("Sdk")
            .join("platform-tools")
            .join("adb");
        if local.exists() {
            return Ok(local);
        }
    }
    // PATH lookup.
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let cand = dir.join("adb");
            if cand.exists() {
                return Ok(cand);
            }
        }
    }
    Err(Error(
        "adb not found. Install Android platform-tools (e.g. `sudo apt install adb`) \
         or set QUEST_COMPANION_ADB to the adb binary path."
            .into(),
    ))
}

// ---------------------------------------------------------------------------
// Binary transport
// ---------------------------------------------------------------------------

pub struct AdbBinaryTransport {
    adb: PathBuf,
}

impl AdbBinaryTransport {
    pub fn new() -> Result<Self> {
        let _key = crate::keys::ensure_keypair()?;
        Ok(AdbBinaryTransport {
            adb: resolve_adb_path()?,
        })
    }

    pub fn with_path(adb: PathBuf) -> Result<Self> {
        let _key = crate::keys::ensure_keypair()?;
        Ok(AdbBinaryTransport { adb })
    }

    pub fn adb_path(&self) -> &Path {
        &self.adb
    }

    fn scoped(&self, target: &Target) -> Vec<String> {
        match &target.serial {
            Some(s) => vec!["-s".to_string(), s.clone()],
            None => vec![],
        }
    }

    fn run(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<Output> {
        let mut cmd = Command::new(&self.adb);
        cmd.args(args);
        if stdin.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| {
            Error(format!("failed to run adb ({}): {e}", self.adb.display()))
        })?;
        if let Some(data) = stdin {
            use std::io::Write;
            if let Some(mut w) = child.stdin.take() {
                let _ = w.write_all(data);
            }
        }
        child.wait_with_output().map_err(Error::from)
    }

    fn run_scoped(&self, target: &Target, args: &[&str], stdin: Option<&[u8]>) -> Result<Output> {
        let scope = self.scoped(target);
        let mut full: Vec<String> = scope;
        full.extend(args.iter().map(|s| s.to_string()));
        let refs: Vec<&str> = full.iter().map(|s| s.as_str()).collect();
        self.run(&refs, stdin)
    }

    fn out_to_cmd(out: Output) -> CmdOutput {
        CmdOutput {
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            code: out.status.code().unwrap_or(-1),
        }
    }
}

impl AdbTransport for AdbBinaryTransport {
    fn name(&self) -> &'static str {
        "adb-binary"
    }

    fn list_devices(&self) -> Result<Vec<Device>> {
        let out = self.run(&["devices", "-l"], None)?;
        Ok(parse_devices_output(&String::from_utf8_lossy(&out.stdout)))
    }

    fn shell(&self, target: &Target, cmd: &str) -> Result<CmdOutput> {
        let out = self.run_scoped(target, &["shell", cmd], None)?;
        Ok(Self::out_to_cmd(out))
    }

    fn exec_out(&self, target: &Target, argv: &[&str]) -> Result<Vec<u8>> {
        let mut args = vec!["exec-out"];
        args.extend(argv);
        let out = self.run_scoped(target, &args, None)?;
        if !out.status.success() {
            return Err(Error(format!(
                "exec-out {:?} failed: {}",
                argv,
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(out.stdout)
    }

    fn push(&self, target: &Target, local: &Path, remote: &str) -> Result<()> {
        let local_s = local.to_string_lossy().into_owned();
        let out = self.run_scoped(target, &["push", &local_s, remote], None)?;
        if !out.status.success() {
            return Err(Error(format!(
                "adb push failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(())
    }

    fn pull(&self, target: &Target, remote: &str, local: &Path) -> Result<()> {
        let local_s = local.to_string_lossy().into_owned();
        let out = self.run_scoped(target, &["pull", remote, &local_s], None)?;
        if !out.status.success() {
            return Err(Error(format!(
                "adb pull failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(())
    }

    fn install(&self, target: &Target, apks: &[PathBuf], reinstall: bool) -> Result<String> {
        if apks.is_empty() {
            return Err(Error("no APKs given to install".into()));
        }
        let paths: Vec<String> = apks
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let mut args: Vec<String> = vec![if apks.len() == 1 {
            "install".to_string()
        } else {
            "install-multiple".to_string()
        }];
        if reinstall {
            args.push("-r".to_string());
        }
        args.push("-g".to_string());
        args.extend(paths);
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let out = self.run_scoped(target, &refs, None)?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if text.contains("Success") {
            Ok(text.trim().to_string())
        } else {
            Err(Error(format!(
                "install failed: {}",
                crate::apps::friendly_install_error(&text)
            )))
        }
    }

    fn logcat_dump(&self, target: &Target) -> Result<Vec<String>> {
        let out = self.run_scoped(target, &["logcat", "-d", "-v", "threadtime"], None)?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.to_string())
            .collect())
    }

    fn pair_tls(&self, ip: &str, port: u16, code: &str) -> Result<String> {
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
            return Err(Error("pairing code must be exactly 6 digits".into()));
        }
        let target = format!("{ip}:{port}");
        let stdin = format!("{code}\n");
        let out = self.run(&["pair", &target], Some(stdin.as_bytes()))?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if text.to_lowercase().contains("successfully paired") {
            Ok(text.trim().to_string())
        } else {
            Err(Error(format!("adb pair failed: {}", text.trim())))
        }
    }

    fn connect_tcp(&self, ip: &str, port: u16) -> Result<String> {
        let target = format!("{ip}:{port}");
        let out = self.run(&["connect", &target], None)?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if text.contains("connected to") || text.contains("already connected") {
            Ok(text.trim().to_string())
        } else {
            Err(Error(format!("adb connect failed: {}", text.trim())))
        }
    }

    fn tcpip(&self, target: &Target, port: u16) -> Result<()> {
        let port_s = port.to_string();
        let out = self.run_scoped(target, &["tcpip", &port_s], None)?;
        if !out.status.success() {
            return Err(Error(format!(
                "adb tcpip failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(())
    }

    fn reboot(&self, target: &Target) -> Result<()> {
        let out = self.run_scoped(target, &["reboot"], None)?;
        if !out.status.success() {
            return Err(Error(format!(
                "adb reboot failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(())
    }

    fn disconnect(&self, serial: &str) -> Result<String> {
        // `adb disconnect <serial>` takes the serial as a plain argument,
        // not under -s (adb disconnect has no -s form).
        let out = self.run(&["disconnect", serial], None)?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if out.status.success() && (text.contains("disconnected") || text.trim().is_empty()) {
            Ok(format!("disconnected {serial}"))
        } else if out.status.success() {
            Ok(text.trim().to_string())
        } else {
            Err(Error(format!("adb disconnect failed: {}", text.trim())))
        }
    }
}

// ---------------------------------------------------------------------------
// Direct transport (libadb, no adb binary)
// ---------------------------------------------------------------------------

pub struct DirectTransport;

impl DirectTransport {
    fn addr(target: &Target) -> Result<String> {
        target.addr_or_serial().ok_or_else(|| {
            Error(
                "direct transport needs an address: pass --addr <ip>:<port> \
                 (or a Wi-Fi serial such as 192.168.1.5:37281)"
                    .into(),
            )
        })
    }
}

/// A live direct (libadb) connection.
type DirectConn =
    libadb::Connection<libadb::transport::tls::MaybeTls<libadb::TokioTcp>>;

/// One direct TCP/TLS connection, owning its tokio runtime so the
/// caller stays synchronous (the CLI / UI call blocking functions).
struct DirectSession {
    rt: tokio::runtime::Runtime,
    conn: DirectConn,
}

impl DirectSession {
    fn connect(addr: &str) -> Result<Self> {
        let key = crate::keys::load_keypair()?;
        let addr = addr.to_string();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| Error(format!("cannot start async runtime: {e}")))?;
        let conn = rt.block_on(async move {
            use libadb::transport::tls::MaybeTls;
            use libadb::{Connection, ConnectionConfig, Feature, HostBanner, TlsClientConfig, TlsIdentity, TokioTcp};
            let identity = TlsIdentity::from_key(&key, &mut libadb::keys::rsa::rand_core::OsRng)
                .map_err(|e| Error(format!("cannot build TLS identity: {e}")))?;
            let tls = TlsClientConfig::adb(&identity)
                .map_err(|e| Error(format!("cannot build TLS config: {e}")))?;
            let tcp = tokio::net::TcpStream::connect(&addr)
                .await
                .map_err(|e| Error(format!("cannot connect to {addr}: {e}")))?;
            let _ = tcp.set_nodelay(true);
            let transport = MaybeTls::plain(TokioTcp::new(tcp));
            Connection::connect_tls(
                transport,
                key,
                HostBanner::Features(&[Feature::ShellV2]),
                ConnectionConfig::new(),
                &tls,
            )
            .await
            .map_err(|e| {
                Error(format!(
                    "ADB handshake with {addr} failed (is wireless debugging on? is the key paired?): {e}"
                ))
            })
        })?;
        Ok(DirectSession { rt, conn })
    }

    fn shell(&mut self, cmd: &str) -> Result<CmdOutput> {
        let cmd = cmd.to_string();
        self.rt.block_on(async {
            let mut rx = vec![0u8; 1024 * 1024];
            match libadb::shell::v2::exec(&mut self.conn, &cmd, &mut rx).await {
                Ok(o) => Ok(CmdOutput {
                    stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
                    code: o.exit_code as i32,
                }),
                Err(e) => Err(Error(format!("direct shell failed: {e}"))),
            }
        })
    }

    /// Binary-clean `exec:` (used for screencap). Output buffer is
    /// 16 MiB, enough for a Quest display capture.
    fn exec_out(&mut self, cmd: &str) -> Result<Vec<u8>> {
        let cmd = cmd.to_string();
        self.rt.block_on(async {
            let mut buf = vec![0u8; 16 * 1024 * 1024];
            let n = libadb::exec::exec(&mut self.conn, &cmd, &mut buf)
                .await
                .map_err(|e| Error(format!("direct exec failed: {e}")))?;
            Ok(buf[..n].to_vec())
        })
    }
}

impl DirectTransport {
    fn shell_direct(addr: &str, cmd: &str) -> Result<CmdOutput> {
        DirectSession::connect(addr)?.shell(cmd)
    }
}

impl AdbTransport for DirectTransport {
    fn name(&self) -> &'static str {
        "libadb-direct"
    }

    fn list_devices(&self) -> Result<Vec<Device>> {
        Err(Error(
            "direct transport has no device discovery (no adb server to ask). \
             Use the binary transport for `devices list`, or pass --addr <ip>:<port> \
             for a known Wi-Fi device."
                .into(),
        ))
    }

    fn shell(&self, target: &Target, cmd: &str) -> Result<CmdOutput> {
        let addr = Self::addr(target)?;
        Self::shell_direct(&addr, cmd)
    }

    fn exec_out(&self, target: &Target, argv: &[&str]) -> Result<Vec<u8>> {
        let addr = Self::addr(target)?;
        let cmd = argv.join(" ");
        // `exec:` is binary-clean. The output buffer must hold the whole
        // screenshot; 16 MiB covers Quest display captures.
        DirectSession::connect(&addr)?.exec_out(&cmd)
    }

    fn push(&self, _t: &Target, _l: &Path, _r: &str) -> Result<()> {
        Err(Error(
            "push is not implemented on the direct transport yet; use the binary transport"
                .into(),
        ))
    }

    fn pull(&self, _t: &Target, _r: &str, _l: &Path) -> Result<()> {
        Err(Error(
            "pull is not implemented on the direct transport yet; use the binary transport"
                .into(),
        ))
    }

    fn install(&self, _t: &Target, _a: &[PathBuf], _r: bool) -> Result<String> {
        Err(Error(
            "install is not implemented on the direct transport yet; use the binary transport"
                .into(),
        ))
    }

    fn logcat_dump(&self, target: &Target) -> Result<Vec<String>> {
        let out = self.shell(target, "logcat -d -v threadtime")?;
        Ok(out.stdout.lines().map(|l| l.to_string()).collect())
    }

    fn pair_tls(&self, ip: &str, port: u16, code: &str) -> Result<String> {
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
            return Err(Error("pairing code must be exactly 6 digits".into()));
        }
        let key = crate::keys::load_keypair()?;
        let addr = format!("{ip}:{port}");
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| Error(format!("cannot start async runtime: {e}")))?;
        rt.block_on(async move {
            use libadb::transport::tls::MaybeTls;
            use libadb::{TlsClientConfig, TlsIdentity, TokioTcp};
            let identity = TlsIdentity::from_key(&key, &mut libadb::keys::rsa::rand_core::OsRng)
                .map_err(|e| Error(format!("cannot build TLS identity: {e}")))?;
            let tls = TlsClientConfig::adb(&identity)
                .map_err(|e| Error(format!("cannot build TLS config: {e}")))?;
            let tcp = tokio::net::TcpStream::connect(&addr)
                .await
                .map_err(|e| Error(format!("cannot connect to pairing port {addr}: {e}")))?;
            let _ = tcp.set_nodelay(true);
            let mut transport = MaybeTls::plain(TokioTcp::new(tcp));
            let paired = libadb::pairing::pair(
                &mut transport,
                &tls,
                &key,
                code,
                &mut libadb::keys::rsa::rand_core::OsRng,
            )
            .await
            .map_err(|e| Error(format!("SPAKE2 pairing failed (wrong/expired code?): {e}")))?;
            Ok::<String, Error>(format!("paired, device GUID {}", paired.guid))
        })
    }

    fn connect_tcp(&self, ip: &str, port: u16) -> Result<String> {
        let addr = format!("{ip}:{port}");
        let out = Self::shell_direct(&addr, "getprop ro.serialno")?;
        if out.code == 0 && !out.stdout.trim().is_empty() {
            Ok(format!("connected to {addr} (direct TLS), serial {}", out.stdout.trim()))
        } else {
            Err(Error(format!(
                "direct connect to {addr} failed: {}",
                out.stderr.trim()
            )))
        }
    }

    fn tcpip(&self, _t: &Target, _p: u16) -> Result<()> {
        Err(Error(
            "tcpip needs a USB connection through the adb server; use the binary transport"
                .into(),
        ))
    }

    fn reboot(&self, target: &Target) -> Result<()> {
        // No adb server on the direct transport: reboot via a shell command.
        let out = self.shell(target, "reboot")?;
        if out.code != 0 {
            return Err(Error(format!(
                "direct reboot failed: {}",
                out.stderr.trim()
            )));
        }
        Ok(())
    }

    fn disconnect(&self, _serial: &str) -> Result<String> {
        // Direct transport opens one TCP/TLS connection per command and
        // closes it when the command ends; there is no adb server
        // connection to disconnect.
        Ok("direct transport has no adb server connection to disconnect; the connection is closed when each command ends".into())
    }
}

pub enum TransportKind {
    Binary,
    Direct,
}

impl TransportKind {
    pub fn from_str(s: &str) -> Result<Self> {
        match s {
            "binary" | "adb" => Ok(TransportKind::Binary),
            "direct" | "libadb" => Ok(TransportKind::Direct),
            other => Err(Error(format!(
                "unknown transport '{other}' (want binary or direct)"
            ))),
        }
    }
    pub fn from_env() -> TransportKind {
        match std::env::var("QUEST_TRANSPORT").as_deref() {
            Ok("direct") | Ok("libadb") => TransportKind::Direct,
            _ => TransportKind::Binary,
        }
    }
}

pub fn make_transport(kind: &TransportKind) -> Result<Box<dyn AdbTransport>> {
    match kind {
        TransportKind::Binary => Ok(Box::new(AdbBinaryTransport::new()?)),
        TransportKind::Direct => Ok(Box::new(DirectTransport)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_devices_quest1() {
        let text = "List of devices attached\n1WMHHB630X0001\tdevice product:monterey model:Quest device:monterey transport_id:1\n";
        let devices = parse_devices_output(text);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].model.as_deref(), Some("Quest"));
        assert_eq!(devices[0].device.as_deref(), Some("monterey"));
        assert_eq!(devices[0].headset_model, "quest1");
    }

    #[test]
    fn parse_devices_quest2() {
        let text = "List of devices attached\n1WMHHB630X1464\tdevice product:hollywood model:Quest_2 device:hollywood transport_id:2\n";
        let devices = parse_devices_output(text);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].model.as_deref(), Some("Quest 2"));
        assert_eq!(devices[0].headset_model, "quest2");
    }
}
