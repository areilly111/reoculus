//! questctl — the JSON CLI the Flutter UI calls.
//!
//! Contract (see backend/CONTRACT.md): every command accepts `--json`
//! and prints ONE JSON object to stdout:
//!   `{"ok": true, ...data}` on success,
//!   `{"ok": false, "error": "..."}` on failure (exit code non-zero).
//! The single documented exception is `device logcat --follow`, which
//! streams raw logcat lines until killed.

use clap::{Args, Parser, Subcommand};
use quest_core::transport::{make_transport, resolve_adb_path, Target, TransportKind};
use quest_core::{apk_analyzer, apps, backup, battery_history, device_backup, devices, files, gallery, health, home_apps, homes, library, media, mirror_settings, paths, settings, singularity, singularity_settings, snapshot, update_block, wireless, wivrn};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "questctl", version, about = "Quest companion CLI (JSON interface for the Flutter UI)")]
struct Cli {
    /// Print exactly one JSON object (the UI contract).
    #[arg(long, global = true)]
    json: bool,
    /// Transport: binary (spawn adb, default) or direct (libadb, Wi-Fi only).
    #[arg(long, global = true, default_value = "binary")]
    transport: String,
    /// Address for the direct transport, e.g. 192.168.1.5:37281.
    #[arg(long, global = true)]
    addr: Option<String>,
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Device discovery, info and Wi-Fi pairing.
    Devices(DevicesArgs),
    /// App install / list / launch management.
    Apps(AppsArgs),
    /// File browsing and transfer.
    Files(FilesArgs),
    /// Screenshots, recording, logcat, mirroring.
    Device(DeviceArgs),
    /// Quest and Android settings, plus saved profiles.
    Settings(SettingsArgs),
    /// The local APK library (backups + imported APKs).
    Library(LibraryArgs),
    /// WiVRn PC VR streaming: detect, start/stop server, config.
    Wivrn(WivrnArgs),
    /// Home / environment apps: list, see the active one, switch.
    Homes(HomesArgs),
    /// Home apps: Lightning Launcher + Quest Home Switcher.
    HomeApps(HomeAppsArgs),
    /// Storage locations on this computer (backups, recordings).
    Paths(PathsArgs),
    /// Mirror quality per connection type (USB, Wi-Fi).
    MirrorSettings(MirrorSettingsArgs),
    /// Singularity root wizard: preflight, download, install, verify.
    Singularity(SingularityArgs),
    /// Named whole-headset snapshots (device backup + profile).
    Snapshot(SnapshotArgs),
}

#[derive(Args)]
struct WivrnArgs {
    #[command(subcommand)]
    cmd: WivrnCmd,
}
#[derive(Subcommand)]
enum WivrnCmd {
    /// Detect the installed WiVRn server, Avahi, PipeWire, ports.
    Detect,
    /// Live server status: running, port, runtime, audio nodes, log tail.
    Status,
    /// Start the WiVRn server (writes config first if --encoder given).
    Start,
    /// Stop the WiVRn server.
    Stop,
    /// Write encoder/codec into ~/.config/wivrn/config.json.
    Config {
        #[arg(long, default_value = "nvenc")]
        encoder: String,
        #[arg(long, default_value = "h265")]
        codec: String,
    },
    /// Installed WiVRn client version on the headset.
    HeadsetClient {
        #[arg(long)]
        serial: String,
    },
    /// First-run state: headset client, server, declined or not.
    SetupState {
        #[arg(long)]
        serial: String,
    },
    /// Install the matching WiVRn client APK on the headset.
    InstallClient {
        #[arg(long)]
        serial: String,
    },
    /// Set up the USB link (adb reverse 9757) and launch the client.
    SetupUsb {
        #[arg(long)]
        serial: String,
    },
    /// Install the WiVRn server from the bundle shipped in the app.
    InstallServer,
    /// Record that the user said no to PC VR setup (per headset).
    Decline {
        #[arg(long)]
        serial: String,
    },
    /// Clear a recorded decline (the Install button does this too).
    Undecline {
        #[arg(long)]
        serial: String,
    },
}

#[derive(Args)]
struct HomesArgs {
    #[command(subcommand)]
    cmd: HomesCmd,
}
#[derive(Subcommand)]
enum HomesCmd {
    /// List the home apps on the headset (current one first).
    List {
        #[arg(long)]
        serial: String,
    },
    /// The active home component, or null when none is set.
    Current {
        #[arg(long)]
        serial: String,
    },
    /// Switch the active home to this component (package/Activity).
    Set {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        component: String,
    },
    /// Open the headset's Home settings (the system home picker).
    OpenSettings {
        #[arg(long)]
        serial: String,
    },
    /// Open a home once, without changing the default (package/Activity).
    Open {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        component: String,
    },
    /// Open Meta's own home once (the stock launcher).
    OpenMeta {
        #[arg(long)]
        serial: String,
    },
    /// Open a settings screen on the headset (wifi, bluetooth,
    /// display, storage, apps, about, home, settings).
    OpenSettingsScreen {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        screen: String,
    },
}

#[derive(Args)]
struct HomeAppsArgs {
    #[command(subcommand)]
    cmd: HomeAppsCmd,
}
#[derive(Subcommand)]
enum HomeAppsCmd {
    /// Scan the headset for Lightning Launcher and Quest Home
    /// Switcher: installed, version, update available, downloaded.
    List {
        #[arg(long)]
        serial: String,
    },
    /// Download the latest release APK (lightning or qhs).
    Download {
        #[arg(long)]
        id: String,
    },
    /// Install one home app (lightning or qhs), downloading first.
    Install {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        id: String,
    },
    /// Uninstall one home app (lightning or qhs).
    Uninstall {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        id: String,
    },
    /// Open one home app on the headset (lightning or qhs).
    Open {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        id: String,
    },
}

#[derive(Args)]
struct PathsArgs {
    #[command(subcommand)]
    cmd: PathsCmd,
}
#[derive(Subcommand)]
enum PathsCmd {
    /// Show the backup/library and recordings folders in use.
    Get,
    /// Move the backup/library folder and/or the recordings folder.
    Set {
        #[arg(long)]
        backup_root: Option<String>,
        #[arg(long)]
        recordings_root: Option<String>,
    },
    /// Go back to the default folders.
    Reset,
}

#[derive(Args)]
struct MirrorSettingsArgs {
    #[command(subcommand)]
    cmd: MirrorSettingsCmd,
}
#[derive(Subcommand)]
enum MirrorSettingsCmd {
    /// Show the mirror quality picked for USB and for Wi-Fi.
    Get,
    /// Pick the mirror quality for USB and/or Wi-Fi
    /// (performance, balanced or quality).
    Set {
        #[arg(long)]
        usb: Option<String>,
        #[arg(long)]
        wifi: Option<String>,
    },
    /// Go back to the defaults (USB Balanced, Wi-Fi Performance).
    Reset,
}

#[derive(Args)]
struct SingularityArgs {
    #[command(subcommand)]
    cmd: SingularityCmd,
}
#[derive(Subcommand)]
enum SingularityCmd {
    /// Preflight checks before rooting: model, battery, root, space.
    Preflight {
        #[arg(long)]
        serial: String,
    },
    /// Download the author's latest Singularity release from GitHub
    /// and verify it (aapt + published checksum when one exists).
    Download,
    /// Install the downloaded APK on the headset (adb install).
    Install {
        #[arg(long)]
        serial: String,
    },
    /// Verify root after the user pressed Root Now in Singularity.
    Verify {
        #[arg(long)]
        serial: String,
    },
    /// List the Singularity downloads (APK, Frida, blocklist) and
    /// their state on this PC and on the headset.
    Downloads {
        #[arg(long)]
        serial: String,
    },
    /// Download the Frida server binary (17.17.0) from the
    /// Singularity repo and check its size.
    DownloadFrida,
    /// Download the Meta domain blocklist from the Singularity
    /// repo and count its domains.
    DownloadHosts,
    /// Frida server on the headset: status, push, start, stop.
    Frida {
        #[command(subcommand)]
        cmd: FridaCmd,
    },
    /// The Meta domain blocklist on the headset: status, apply,
    /// remove.
    Hosts {
        #[command(subcommand)]
        cmd: HostsCmd,
    },
    /// The update disabler: status, block, allow.
    Ota {
        #[command(subcommand)]
        cmd: OtaCmd,
    },
    /// Dock and UI (uxpatcher) settings: list, set.
    Uxp {
        #[command(subcommand)]
        cmd: UxpCmd,
    },
    /// Restart the home screen (vrshell) so new dock settings
    /// take effect.
    RestartHome {
        #[arg(long)]
        serial: String,
    },
}

#[derive(Subcommand)]
enum FridaCmd {
    /// Show the Frida state (downloaded, on the headset, running).
    Status {
        #[arg(long)]
        serial: String,
    },
    /// Push the downloaded Frida server to the headset.
    Push {
        #[arg(long)]
        serial: String,
    },
    /// Start the Frida server on the headset.
    Start {
        #[arg(long)]
        serial: String,
    },
    /// Stop the Frida server on the headset.
    Stop {
        #[arg(long)]
        serial: String,
    },
}

#[derive(Subcommand)]
enum HostsCmd {
    /// Show the blocklist state (downloaded, applied).
    Status {
        #[arg(long)]
        serial: String,
    },
    /// Apply the blocklist through the Magisk systemless-hosts
    /// module (takes effect after a reboot).
    Apply {
        #[arg(long)]
        serial: String,
    },
    /// Remove the blocklist from the Magisk hosts module.
    Remove {
        #[arg(long)]
        serial: String,
    },
}

#[derive(Subcommand)]
enum OtaCmd {
    /// Show whether updates are blocked.
    Status {
        #[arg(long)]
        serial: String,
    },
    /// Block updates (point the OTA settings at localhost).
    Block {
        #[arg(long)]
        serial: String,
    },
    /// Allow updates again (delete the OTA overrides).
    Allow {
        #[arg(long)]
        serial: String,
    },
}

#[derive(Subcommand)]
enum UxpCmd {
    /// List the dock and UI settings and their current values.
    List {
        #[arg(long)]
        serial: String,
    },
    /// Set one dock or UI toggle (value 0 or 1).
    Set {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        key: String,
        #[arg(long)]
        value: String,
    },
}

#[derive(Args)]
struct SnapshotArgs {
    #[command(subcommand)]
    cmd: SnapshotCmd,
}
#[derive(Subcommand)]
enum SnapshotCmd {
    /// Take a named snapshot of the whole headset (device backup +
    /// the active settings profile, if the UI passes --profile).
    Create {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        profile: Option<String>,
    },
    /// List snapshots, newest first.
    List,
    /// Restore a snapshot (device restore + recorded profile).
    /// Dry-run first; a real restore needs --confirm.
    Restore {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        snapshot: PathBuf,
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        confirm: bool,
    },
    /// Delete a snapshot folder (local files only).
    Delete {
        #[arg(long)]
        snapshot: PathBuf,
    },
}

#[derive(Args)]
struct DevicesArgs {
    #[command(subcommand)]
    cmd: DevicesCmd,
}

/// The local APK library: app backups, save backups, imported APKs.
/// One folder: the backup root (~/.local/share/quest-companion/backups/).
#[derive(Args)]
struct LibraryArgs {
    #[command(subcommand)]
    cmd: LibraryCmd,
}
#[derive(Subcommand)]
enum LibraryCmd {
    /// List everything in the library, newest first.
    List,
    /// Copy an APK / .apks / .xapk file into the library.
    Import {
        #[arg(long)]
        file: PathBuf,
    },
    /// Delete a library entry (local file only, never the headset).
    Delete {
        #[arg(long)]
        path: PathBuf,
    },
}
#[derive(Subcommand)]
enum DevicesCmd {
    /// List attached devices with state and model.
    List,
    /// Full info for one device.
    Info {
        #[arg(long)]
        serial: String,
    },
    /// Enable legacy ADB-over-Wi-Fi on a USB device (adb tcpip 5555).
    PairWifi {
        #[arg(long)]
        serial: String,
    },
    /// Pair (with --code) or connect to a Wi-Fi device.
    ConnectWifi {
        #[arg(long)]
        ip: String,
        #[arg(long)]
        port: u16,
        /// 6-digit pairing code shown on the headset. When given, this
        /// pairs; without it, this connects to an already-paired device.
        #[arg(long)]
        code: Option<String>,
    },
    /// Disconnect a Wi-Fi device from the adb server (`adb disconnect`).
    DisconnectWifi {
        #[arg(long)]
        serial: String,
    },
    /// Run one adb shell command on the headset and print its
    /// stdout/stderr/exit code as JSON. 120 s timeout. The UI shows
    /// the command before it runs and logs it; nothing is blocked
    /// (the user owns the headset), but the timeout stops a hung
    /// command from hanging the UI.
    Shell {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        command: String,
    },
    /// Host + headset debug info for the Terminal screen: questctl
    /// version, adb version, scrcpy, backend path, device info,
    /// Wi-Fi IP, root status. All read-only.
    DebugInfo {
        #[arg(long)]
        serial: String,
    },
    /// Read-only root detection (su / Magisk / Singularity).
    RootStatus {
        #[arg(long)]
        serial: String,
    },
    /// The headset's Wi-Fi IP, or null when it is not on Wi-Fi.
    WifiIp {
        #[arg(long)]
        serial: String,
    },
    /// Automatic wireless setup after a USB connection: find the
    /// Wi-Fi IP, `adb tcpip 5555`, `adb connect <ip>:5555`, verify.
    /// Never fails hard: on failure it returns connected:false with
    /// a quiet note (USB still works). Saves the IP on success.
    SetupWifi {
        #[arg(long)]
        serial: String,
    },
    /// Try the saved wireless IPs (from earlier USB setups) when no
    /// USB device is present. Returns the IPs now connected.
    WifiReconnect,
    /// Controllers the headset currently sees as input devices
    /// (pairing presence only; battery/firmware are not readable
    /// offline, see the note in the payload).
    Controllers {
        #[arg(long)]
        serial: String,
    },
    /// Update-block status (rooted only): are the updater packages
    /// currently disabled?
    UpdateBlockStatus {
        #[arg(long)]
        serial: String,
    },
    /// Battery, storage, uptime and last backup for the dashboard.
    Health {
        #[arg(long)]
        serial: String,
    },
    /// Battery now, battery samples recorded on this computer, and
    /// the most-used apps from the headset's own usage stats.
    BatteryHistory {
        #[arg(long)]
        serial: String,
    },
    /// Turn update blocking on (--block) or off (--unblock).
    /// Rooted only, off by default, reversible with --unblock.
    UpdateBlock {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        block: bool,
        #[arg(long)]
        unblock: bool,
    },
}

#[derive(Args)]
struct AppsArgs {
    #[command(subcommand)]
    cmd: AppsCmd,
}
#[derive(Subcommand)]
enum AppsCmd {
    List {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        third_party: bool,
        /// Also fill icon_path / the real label from the icon cache
        /// where present. Never pulls APKs; see CONTRACT.md.
        #[arg(long)]
        with_icons: bool,
        /// Also fill APK / data / OBB sizes and the dumpsys details
        /// (version code, SDK levels, dates, installer, permissions).
        /// Three batched shell calls; the list stays fast.
        #[arg(long)]
        with_sizes: bool,
    },
    /// Get one app's real label + launcher icon (pulls base.apk once,
    /// then caches it under ~/.cache/quest-companion/icons/).
    Icon {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
        /// Also copy the icon to this file (e.g. /tmp/icon.png).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Full details for one app: sizes (APK / data / OBB / total),
    /// version code, SDK levels, install/update dates, installer,
    /// split APK paths, OBB files, requested permissions. Lazy: the
    /// UI calls this when the user opens one app, never for the list.
    Details {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
    },
    /// Back up one app to a folder under the backup root
    /// (~/.local/share/quest-companion/backups/): APKs + OBB +
    /// app data when rooted (see CONTRACT.md for the honest limits).
    /// A manifest.json with SHA-256 hashes is written in the folder.
    Backup {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
        /// Backup root override (default: the standard backup dir).
        #[arg(long)]
        out: Option<PathBuf>,
        /// Skip the /data/data tarball even when root is available.
        #[arg(long)]
        skip_data: bool,
    },
    /// Restore a backup folder onto the headset. Verifies the
    /// manifest hashes first; refuses a damaged backup. Requires
    /// --confirm (reinstalls the app). --dry-run lists the steps
    /// without touching the headset.
    Restore {
        #[arg(long)]
        serial: String,
        /// The backup folder (the one holding manifest.json).
        #[arg(long)]
        backup: PathBuf,
        /// Also restore app data (needs root; overwrites the app's
        /// current data). Off by default.
        #[arg(long)]
        include_data: bool,
        /// List what would be done without doing it.
        #[arg(long)]
        dry_run: bool,
        /// Required for a real restore.
        #[arg(long)]
        confirm: bool,
    },
    /// List backup folders in the backup root, newest first.
    BackupList {
        /// Backup root override (default: the standard backup dir).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Delete a backup folder (local files only, never the headset).
    BackupDelete {
        /// The backup folder (the one holding manifest.json).
        #[arg(long)]
        backup: PathBuf,
    },
    /// Install one APK, or a .apks/.xapk bundle (unzipped first).
    Install {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        apk: PathBuf,
        #[arg(long)]
        reinstall: bool,
    },
    /// Install split APKs atomically: --apks base.apk,split1.apk,...
    InstallMultiple {
        #[arg(long)]
        serial: String,
        #[arg(long, value_delimiter = ',')]
        apks: Vec<PathBuf>,
    },
    Uninstall {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
        /// Keep app data/cache.
        #[arg(short = 'k', long)]
        keep_data: bool,
    },
    Launch {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
    },
    ForceStop {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
    },
    /// Back up only one app's saves (no APK): /sdcard/Android/data
    /// plus, when rooted, a /data/data tarball. OBB is noted, not
    /// copied, unless --include-obb. See CONTRACT.md.
    SaveBackup {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
        #[arg(long)]
        out: Option<PathBuf>,
        /// Also copy real .obb files into the save backup.
        #[arg(long)]
        include_obb: bool,
    },
    /// Restore a save backup (overwrites the game's current saves).
    /// Requires --confirm; --dry-run only lists the steps.
    SaveRestore {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        backup: PathBuf,
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        confirm: bool,
    },
    /// Uninstall a system app (rooted headsets only): `su -c pm
    /// uninstall`. Refuses without root. The normal `uninstall` is
    /// for user apps.
    UninstallSystem {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
    },
    /// Destructive: wipes the app's data. Requires --confirm.
    ClearData {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        package: String,
        #[arg(long)]
        confirm: bool,
    },
    /// Analyze a local APK file before installing it: label,
    /// version, SDK levels, permissions, native libraries (ABIs,
    /// 32/64-bit), size breakdown, file SHA-256 and signer.
    Analyze {
        #[arg(long)]
        apk: PathBuf,
    },
}

#[derive(Args)]
struct FilesArgs {
    #[command(subcommand)]
    cmd: FilesCmd,
}
#[derive(Subcommand)]
enum FilesCmd {
    List {
        #[arg(long)]
        serial: String,
        #[arg(long, default_value = "/sdcard/")]
        path: String,
    },
    Push {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        local: PathBuf,
        #[arg(long)]
        remote: String,
    },
    Pull {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        remote: String,
        #[arg(long)]
        local: PathBuf,
    },
    /// Delete a file or folder under /sdcard/ only (refuses anything
    /// outside /sdcard/, and /sdcard itself).
    Delete {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        remote: String,
    },
}

#[derive(Args)]
struct DeviceArgs {
    #[command(subcommand)]
    cmd: DeviceCmd,
}
#[derive(Subcommand)]
enum DeviceCmd {
    Screenshot {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        out: PathBuf,
    },
    Record {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        out: PathBuf,
        #[arg(long, default_value_t = 60)]
        seconds: u32,
    },
    Logcat {
        #[arg(long)]
        serial: String,
        /// Stream raw logcat lines until killed (no JSON envelope).
        #[arg(long)]
        follow: bool,
    },
    /// Stop a running scrcpy mirror for this serial.
    MirrorStop {
        #[arg(long)]
        serial: String,
    },
    /// Launch scrcpy in its own window.
    Mirror {
        #[arg(long)]
        serial: String,
        #[arg(long, default_value = "balanced")]
        preset: String,
    },
    /// Reboot the headset (`adb -s <serial> reboot`).
    Reboot {
        #[arg(long)]
        serial: String,
    },
    /// List the screenshot / recording gallery (~/quest-recordings/).
    GalleryList,
    /// Delete one gallery file (local file only).
    GalleryDelete {
        #[arg(long)]
        file: PathBuf,
    },
    /// Full device backup: settings, Guardian data, Wi-Fi configs,
    /// app inventory with library references, manifest.json. Apps
    /// themselves are NOT re-copied (see CONTRACT.md).
    Backup {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Restore a device backup. Dry-run first; a real restore needs
    /// --confirm (overwrites settings, Guardian, Wi-Fi, apps).
    Restore {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        backup: PathBuf,
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        confirm: bool,
        /// Do not reinstall apps from the library.
        #[arg(long)]
        skip_apps: bool,
        /// Also restore app data with the apps (rooted, overwrites data).
        #[arg(long)]
        include_data: bool,
    },
    /// List device backups in the library folder, newest first.
    BackupList,
}

#[derive(Args)]
struct SettingsArgs {
    #[command(subcommand)]
    cmd: SettingsCmd,
}
#[derive(Subcommand)]
enum SettingsCmd {
    Get {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        key: String,
    },
    Set {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        key: String,
        #[arg(long)]
        value: String,
    },
    Profile(ProfileArgs),
}

#[derive(Args)]
struct ProfileArgs {
    #[command(subcommand)]
    cmd: ProfileCmd,
}
#[derive(Subcommand)]
enum ProfileCmd {
    /// List built-in + saved profiles.
    List,
    /// Apply a profile (refresh rate, cpu/gpu level, guardian, ...).
    Apply {
        #[arg(long)]
        serial: String,
        #[arg(long)]
        profile: String,
    },
}

fn target(cli: &Cli, serial: &str) -> Target {
    let mut t = Target::serial(serial);
    t.addr = cli.addr.clone();
    t
}

fn model_of(t: &dyn quest_core::AdbTransport, serial: &str) -> String {
    match t.shell(&Target::serial(serial), "getprop ro.product.model") {
        Ok(o) => {
            let s = o.stdout.trim().to_string();
            if s.is_empty() {
                "unknown".to_string()
            } else {
                s
            }
        }
        Err(_) => "unknown".to_string(),
    }
}

fn device_ip(t: &dyn quest_core::AdbTransport, serial: &str) -> quest_core::Result<String> {
    let target = Target::serial(serial);
    let out = t.shell(&target, "ip route get 1.1.1.1")?;
    // `... src 192.168.1.42 uid ...`
    let cols: Vec<&str> = out.stdout.split_whitespace().collect();
    for w in cols.windows(2) {
        if w[0] == "src" {
            return Ok(w[1].to_string());
        }
    }
    let out2 = t.shell(&target, "ip addr show wlan0")?;
    for line in out2.stdout.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("inet ") {
            if let Some(ip) = rest.split('/').next() {
                let ip = ip.trim();
                if !ip.starts_with("127.") {
                    return Ok(ip.to_string());
                }
            }
        }
    }
    Err(quest_core::Error(
        "could not determine the headset's Wi-Fi IP address".into(),
    ))
}

/// Run one shell command with a 120 s timeout. The transport is
/// built inside the worker thread (the trait object is not Send),
/// the result comes back over a channel, and a timeout is a clean
/// error, not a hung CLI.
fn run_shell_timeout(
    transport: &str,
    serial: &str,
    command: &str,
) -> quest_core::Result<quest_core::transport::CmdOutput> {
    use std::sync::mpsc;
    let (tx, rx) = mpsc::channel();
    let transport = transport.to_string();
    let serial = serial.to_string();
    let command = command.to_string();
    std::thread::spawn(move || {
        let r = (|| -> quest_core::Result<quest_core::transport::CmdOutput> {
            let kind = TransportKind::from_str(&transport)?;
            let t = make_transport(&kind)?;
            t.shell(&Target::serial(&serial), &command)
        })();
        let _ = tx.send(r);
    });
    match rx.recv_timeout(std::time::Duration::from_secs(120)) {
        Ok(r) => r,
        Err(_) => Err(quest_core::Error(
            "shell command timed out after 120 s".into(),
        )),
    }
}

fn run(cli: &Cli) -> quest_core::Result<Value> {
    let kind = TransportKind::from_str(&cli.transport)?;
    let t = make_transport(&kind)?;
    match &cli.cmd {
        Commands::Wivrn(a) => match &a.cmd {
            WivrnCmd::Detect => Ok(serde_json::to_value(wivrn::detect())?),
            WivrnCmd::Status => Ok(serde_json::to_value(wivrn::status())?),
            WivrnCmd::Start => Ok(serde_json::to_value(wivrn::start()?)?),
            WivrnCmd::Stop => Ok(json!({ "message": wivrn::stop()? })),
            WivrnCmd::Config { encoder, codec } => {
                let path = wivrn::write_config(encoder, codec)?;
                Ok(json!({ "config": path, "encoder": encoder, "codec": codec }))
            }
            WivrnCmd::HeadsetClient { serial } => {
                let v = wivrn::headset_client_version(t.as_ref(), serial);
                Ok(json!({ "serial": serial, "client_version": v, "server_version": wivrn::WIVRN_VERSION }))
            }
            WivrnCmd::SetupState { serial } => Ok(serde_json::to_value(wivrn::setup_state(t.as_ref(), serial))?),
            WivrnCmd::InstallClient { serial } => Ok(json!({ "message": wivrn::install_client(t.as_ref(), serial)? })),
            WivrnCmd::SetupUsb { serial } => Ok(json!({ "message": wivrn::setup_usb(t.as_ref(), serial)? })),
            WivrnCmd::InstallServer => Ok(json!({ "message": wivrn::install_server()? })),
            WivrnCmd::Decline { serial } => Ok(json!({ "message": wivrn::set_declined(true, serial)? })),
            WivrnCmd::Undecline { serial } => Ok(json!({ "message": wivrn::set_declined(false, serial)? })),
        },
        Commands::Homes(a) => match &a.cmd {
            HomesCmd::List { serial } => {
                let hs = homes::list_homes(t.as_ref(), serial)?;
                Ok(json!({ "homes": hs }))
            }
            HomesCmd::Current { serial } => {
                let c = homes::current_home(t.as_ref(), serial)?;
                Ok(json!({ "current": c }))
            }
            HomesCmd::Set { serial, component } => {
                let m = homes::set_home(t.as_ref(), serial, component)?;
                Ok(json!({ "message": m, "component": component }))
            }
            HomesCmd::OpenSettings { serial } => {
                let m = homes::open_home_settings(t.as_ref(), serial)?;
                Ok(json!({ "message": m }))
            }
            HomesCmd::Open { serial, component } => {
                let m = homes::open_home(t.as_ref(), serial, component)?;
                Ok(json!({ "message": m, "component": component }))
            }
            HomesCmd::OpenMeta { serial } => {
                let m = homes::open_meta_home(t.as_ref(), serial)?;
                Ok(json!({ "message": m }))
            }
            HomesCmd::OpenSettingsScreen { serial, screen } => {
                let m = homes::open_settings_screen(t.as_ref(), serial, screen)?;
                Ok(json!({ "message": m, "screen": screen }))
            }
        },
        Commands::HomeApps(a) => match &a.cmd {
            HomeAppsCmd::List { serial } => {
                let list = home_apps::list(t.as_ref(), serial)?;
                Ok(json!({ "home_apps": list }))
            }
            HomeAppsCmd::Download { id } => {
                let d = home_apps::download(id)?;
                Ok(serde_json::to_value(d)?)
            }
            HomeAppsCmd::Install { serial, id } => {
                let m = home_apps::install(t.as_ref(), serial, id)?;
                Ok(json!({ "message": m, "id": id }))
            }
            HomeAppsCmd::Uninstall { serial, id } => {
                let m = home_apps::uninstall(t.as_ref(), serial, id)?;
                Ok(json!({ "message": m, "id": id }))
            }
            HomeAppsCmd::Open { serial, id } => {
                let m = home_apps::open(t.as_ref(), serial, id)?;
                Ok(json!({ "message": m, "id": id }))
            }
        },
        Commands::Paths(a) => match &a.cmd {
            PathsCmd::Get => Ok(serde_json::to_value(paths::get_paths()?)?),
            PathsCmd::Set { backup_root, recordings_root } => {
                Ok(serde_json::to_value(paths::set_paths(backup_root.clone(), recordings_root.clone())?)?)
            }
            PathsCmd::Reset => Ok(serde_json::to_value(paths::reset_paths()?)?),
        },
        Commands::MirrorSettings(a) => match &a.cmd {
            MirrorSettingsCmd::Get => {
                Ok(serde_json::to_value(mirror_settings::get_mirror_settings())?)
            }
            MirrorSettingsCmd::Set { usb, wifi } => Ok(serde_json::to_value(
                mirror_settings::set_mirror_settings(usb.clone(), wifi.clone())?,
            )?),
            MirrorSettingsCmd::Reset => Ok(serde_json::to_value(
                mirror_settings::reset_mirror_settings(),
            )?),
        },
        Commands::Singularity(a) => match &a.cmd {
            SingularityCmd::Preflight { serial } => {
                let p = singularity::preflight(t.as_ref(), serial)?;
                Ok(serde_json::to_value(p)?)
            }
            SingularityCmd::Download => {
                let r = singularity::download_latest()?;
                Ok(serde_json::to_value(r)?)
            }
            SingularityCmd::Install { serial } => {
                let m = singularity::install(t.as_ref(), serial)?;
                Ok(json!({ "message": m }))
            }
            SingularityCmd::Verify { serial } => {
                let r = singularity::verify(t.as_ref(), serial)?;
                Ok(serde_json::to_value(r)?)
            }
            SingularityCmd::Downloads { serial } => {
                let items = singularity_settings::downloads_list(t.as_ref(), serial)?;
                Ok(json!({ "downloads": items }))
            }
            SingularityCmd::DownloadFrida => {
                let r = singularity_settings::download_frida()?;
                Ok(serde_json::to_value(r)?)
            }
            SingularityCmd::DownloadHosts => {
                let r = singularity_settings::download_hosts()?;
                Ok(serde_json::to_value(r)?)
            }
            SingularityCmd::Frida { cmd } => match cmd {
                FridaCmd::Status { serial } => {
                    let r = singularity_settings::frida_status(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                FridaCmd::Push { serial } => {
                    let r = singularity_settings::frida_push(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                FridaCmd::Start { serial } => {
                    let r = singularity_settings::frida_start(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                FridaCmd::Stop { serial } => {
                    let r = singularity_settings::frida_stop(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
            },
            SingularityCmd::Hosts { cmd } => match cmd {
                HostsCmd::Status { serial } => {
                    let r = singularity_settings::hosts_status(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                HostsCmd::Apply { serial } => {
                    let r = singularity_settings::hosts_apply(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                HostsCmd::Remove { serial } => {
                    let r = singularity_settings::hosts_remove(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
            },
            SingularityCmd::Ota { cmd } => match cmd {
                OtaCmd::Status { serial } => {
                    let r = singularity_settings::ota_status(t.as_ref(), serial)?;
                    Ok(serde_json::to_value(r)?)
                }
                OtaCmd::Block { serial } => {
                    let r = singularity_settings::ota_set(t.as_ref(), serial, true)?;
                    Ok(serde_json::to_value(r)?)
                }
                OtaCmd::Allow { serial } => {
                    let r = singularity_settings::ota_set(t.as_ref(), serial, false)?;
                    Ok(serde_json::to_value(r)?)
                }
            },
            SingularityCmd::Uxp { cmd } => match cmd {
                UxpCmd::List { serial } => {
                    let items = singularity_settings::uxp_list(t.as_ref(), serial)?;
                    Ok(json!({ "settings": items }))
                }
                UxpCmd::Set { serial, key, value } => {
                    let r = singularity_settings::uxp_set(t.as_ref(), serial, key, value)?;
                    Ok(serde_json::to_value(r)?)
                }
            },
            SingularityCmd::RestartHome { serial } => {
                let m = singularity_settings::restart_home(t.as_ref(), serial)?;
                Ok(json!({ "message": m }))
            }
        },
        Commands::Snapshot(a) => match &a.cmd {
            SnapshotCmd::Create { serial, name, profile } => {
                let r = snapshot::create_snapshot(t.as_ref(), serial, name, profile.as_deref())?;
                Ok(serde_json::to_value(r)?)
            }
            SnapshotCmd::List => {
                let entries = snapshot::list_snapshots()?;
                Ok(json!({ "snapshots": entries }))
            }
            SnapshotCmd::Restore { serial, snapshot: path, dry_run, confirm } => {
                let r = snapshot::restore_snapshot(t.as_ref(), serial, path, *dry_run, *confirm)?;
                Ok(serde_json::to_value(r)?)
            }
            SnapshotCmd::Delete { snapshot: path } => {
                snapshot::delete_snapshot(path)?;
                Ok(json!({ "deleted": true, "snapshot": path }))
            }
        },
        Commands::Devices(a) => match &a.cmd {
            DevicesCmd::List => {
                let ds = devices::list_devices(t.as_ref())?;
                Ok(json!({ "devices": ds }))
            }
            DevicesCmd::Info { serial } => {
                let info = devices::device_info(t.as_ref(), serial)?;
                Ok(serde_json::to_value(info)?)
            }
            DevicesCmd::PairWifi { serial } => {
                t.tcpip(&target(cli, serial), 5555)?;
                let ip = device_ip(t.as_ref(), serial)?;
                Ok(json!({
                    "serial": serial,
                    "ip": ip,
                    "port": 5555,
                    "warning": "Legacy adb tcpip is unauthenticated beyond the RSA key and turns off on reboot. Prefer modern wireless debugging (TLS pairing) when the headset offers it.",
                    "next": format!("questctl --json devices connect-wifi --ip {ip} --port 5555"),
                }))
            }
            DevicesCmd::ConnectWifi { ip, port, code } => {
                if let Some(code) = code {
                    let msg = t.pair_tls(ip, *port, code)?;
                    return Ok(json!({
                        "paired": true,
                        "message": msg,
                        "note": "The pairing port is not the connect port. The headset shows a separate connect port (usually 3xxxx) under Wireless debugging; run connect-wifi again without --code against that port.",
                    }));
                }
                let msg = t.connect_tcp(ip, *port)?;
                Ok(json!({ "connected": true, "message": msg }))
            }
            DevicesCmd::DisconnectWifi { serial } => {
                let msg = t.disconnect(serial)?;
                Ok(json!({ "disconnected": true, "serial": serial, "message": msg }))
            }
            DevicesCmd::Shell { serial, command } => {
                // The UI shows the command before it runs; log it here too.
                eprintln!("shell on {serial}: {command}");
                let out = run_shell_timeout(&cli.transport, serial, command)?;
                Ok(json!({ "stdout": out.stdout, "stderr": out.stderr, "code": out.code }))
            }
            DevicesCmd::DebugInfo { serial } => {
                let info = devices::device_info(t.as_ref(), serial)?;
                let adb_version = std::process::Command::new(
                    quest_core::transport::resolve_adb_path().unwrap_or_else(|_| "adb".into()),
                )
                .arg("--version")
                .output()
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout).lines().next().unwrap_or("").to_string()
                })
                .unwrap_or_default();
                Ok(json!({
                    "questctl_version": env!("CARGO_PKG_VERSION"),
                    "adb_version": adb_version,
                    "scrcpy_available": media::find_scrcpy().is_some(),
                    "backend_path": std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
                    "device": info,
                    "wifi_ip": wireless::wifi_ip(t.as_ref(), serial),
                    "root": wireless::root_status(t.as_ref(), serial),
                }))
            }
            DevicesCmd::RootStatus { serial } => {
                Ok(serde_json::to_value(wireless::root_status(t.as_ref(), serial))?)
            }
            DevicesCmd::WifiIp { serial } => {
                Ok(json!({ "serial": serial, "ip": wireless::wifi_ip(t.as_ref(), serial) }))
            }
            DevicesCmd::SetupWifi { serial } => {
                let setup = wireless::setup_wifi(t.as_ref(), serial);
                if setup.connected {
                    if let Some(ip) = &setup.ip {
                        let _ = wireless::save_known_wireless(serial, ip, 5555);
                    }
                }
                Ok(serde_json::to_value(setup)?)
            }
            DevicesCmd::WifiReconnect => {
                let connected = wireless::try_saved_wireless(t.as_ref());
                Ok(json!({ "connected": connected }))
            }
            DevicesCmd::Controllers { serial } => {
                let c = devices::controllers(t.as_ref(), serial)?;
                Ok(serde_json::to_value(c)?)
            }
            DevicesCmd::UpdateBlockStatus { serial } => {
                Ok(serde_json::to_value(update_block::update_block_status(t.as_ref(), serial))?)
            }
            DevicesCmd::Health { serial } => {
                let h = health::health(t.as_ref(), serial)?;
                Ok(serde_json::to_value(h)?)
            }
            DevicesCmd::BatteryHistory { serial } => {
                let h = battery_history::battery_history(t.as_ref(), serial)?;
                Ok(serde_json::to_value(h)?)
            }
            DevicesCmd::UpdateBlock { serial, block, unblock } => {
                if *block == *unblock {
                    return Err(quest_core::Error(
                        "pass exactly one of --block or --unblock".into(),
                    ));
                }
                let pkgs = update_block::set_update_block(t.as_ref(), serial, *block)?;
                Ok(json!({ "blocked": *block, "packages": pkgs }))
            }
        },
        Commands::Apps(a) => match &a.cmd {
            AppsCmd::List { serial, third_party, with_icons, with_sizes } => {
                let list = if *with_sizes {
                    apps::list_apps_with_sizes(t.as_ref(), serial, *third_party, *with_icons)?
                } else if *with_icons {
                    apps::list_apps_with_icons(t.as_ref(), serial, *third_party)?
                } else {
                    apps::list_apps(t.as_ref(), serial, *third_party)?
                };
                Ok(json!({ "apps": list }))
            }
            AppsCmd::Icon { serial, package, out } => {
                let icon = apps::app_icon(t.as_ref(), serial, package, out.as_deref())?;
                Ok(serde_json::to_value(icon)?)
            }
            AppsCmd::Details { serial, package } => {
                let d = apps::app_details(t.as_ref(), serial, package)?;
                Ok(serde_json::to_value(d)?)
            }
            AppsCmd::Backup { serial, package, out, skip_data } => {
                let r = backup::backup_app(t.as_ref(), serial, package, out.as_deref(), *skip_data)?;
                Ok(serde_json::to_value(r)?)
            }
            AppsCmd::Restore { serial, backup, include_data, dry_run, confirm } => {
                let r = backup::restore_backup(t.as_ref(), serial, backup, *include_data, *dry_run, *confirm)?;
                Ok(serde_json::to_value(r)?)
            }
            AppsCmd::BackupList { out } => {
                let entries = match out {
                    Some(dir) => backup::list_backups_in(dir)?,
                    None => backup::list_backups()?,
                };
                Ok(json!({ "backups": entries }))
            }
            AppsCmd::BackupDelete { backup } => {
                backup::delete_backup(backup)?;
                Ok(json!({ "deleted": true, "backup": backup }))
            }
            AppsCmd::SaveBackup { serial, package, out, include_obb } => {
                let r = backup::save_backup(t.as_ref(), serial, package, out.as_deref(), *include_obb)?;
                Ok(serde_json::to_value(r)?)
            }
            AppsCmd::SaveRestore { serial, backup, dry_run, confirm } => {
                let r = backup::save_restore(t.as_ref(), serial, backup, *dry_run, *confirm)?;
                Ok(serde_json::to_value(r)?)
            }
            AppsCmd::UninstallSystem { serial, package } => {
                let msg = apps::uninstall_system(t.as_ref(), serial, package)?;
                Ok(json!({ "uninstalled": true, "message": msg }))
            }
            AppsCmd::Install { serial, apk, reinstall } => {
                let msg = apps::install_apk(t.as_ref(), serial, apk, *reinstall)?;
                Ok(json!({ "installed": true, "message": msg }))
            }
            AppsCmd::InstallMultiple { serial, apks } => {
                let msg = apps::install_multiple(t.as_ref(), serial, apks, true)?;
                Ok(json!({ "installed": true, "message": msg }))
            }
            AppsCmd::Uninstall { serial, package, keep_data } => {
                let msg = apps::uninstall(t.as_ref(), serial, package, *keep_data)?;
                Ok(json!({ "uninstalled": true, "message": msg }))
            }
            AppsCmd::Launch { serial, package } => {
                let msg = apps::launch(t.as_ref(), serial, package)?;
                Ok(json!({ "launched": true, "message": msg }))
            }
            AppsCmd::ForceStop { serial, package } => {
                let msg = apps::force_stop(t.as_ref(), serial, package)?;
                Ok(json!({ "message": msg }))
            }
            AppsCmd::ClearData { serial, package, confirm } => {
                if !confirm {
                    return Err(quest_core::Error(
                        "clear-data wipes the app's data. Re-run with --confirm to proceed."
                            .into(),
                    ));
                }
                let msg = apps::clear_data(t.as_ref(), serial, package)?;
                Ok(json!({ "message": msg }))
            }
            AppsCmd::Analyze { apk } => {
                let a = apk_analyzer::analyze_apk(apk)?;
                Ok(serde_json::to_value(a)?)
            }
        },
        Commands::Files(a) => match &a.cmd {
            FilesCmd::List { serial, path } => {
                let entries = files::list_files(t.as_ref(), serial, path)?;
                Ok(json!({ "path": path, "entries": entries }))
            }
            FilesCmd::Push { serial, local, remote } => {
                files::push(t.as_ref(), serial, local, remote)?;
                Ok(json!({ "pushed": true, "local": local, "remote": remote }))
            }
            FilesCmd::Pull { serial, remote, local } => {
                files::pull(t.as_ref(), serial, remote, local)?;
                Ok(json!({ "pulled": true, "remote": remote, "local": local }))
            }
            FilesCmd::Delete { serial, remote } => {
                files::delete(t.as_ref(), serial, remote)?;
                Ok(json!({ "deleted": true, "remote": remote }))
            }
        },
        Commands::Device(a) => match &a.cmd {
            DeviceCmd::Screenshot { serial, out } => {
                let path = media::screenshot(t.as_ref(), serial, out)?;
                Ok(json!({ "path": path }))
            }
            DeviceCmd::Record { serial, out, seconds } => {
                let rec = media::record(t.as_ref(), serial, out, *seconds)?;
                let mut v = json!({ "path": rec.path, "seconds": rec.seconds });
                if let Some(note) = rec.note {
                    v["note"] = json!(note);
                }
                Ok(v)
            }
            DeviceCmd::Logcat { serial, .. } => {
                let lines = media::logcat_dump(t.as_ref(), serial)?;
                Ok(json!({ "lines": lines }))
            }
            DeviceCmd::MirrorStop { serial } => {
                let n = media::mirror_stop(serial)?;
                Ok(json!({ "stopped": n, "serial": serial }))
            }
            DeviceCmd::Mirror { serial, preset } => {
                let m = media::mirror(t.as_ref(), serial, preset)?;
                Ok(json!({ "launched": true, "command": m.command, "note": m.note }))
            }
            DeviceCmd::Reboot { serial } => {
                t.reboot(&target(cli, serial))?;
                Ok(json!({ "rebooted": true, "serial": serial }))
            }
            DeviceCmd::GalleryList => {
                let entries = gallery::list_gallery()?;
                Ok(json!({ "entries": entries }))
            }
            DeviceCmd::GalleryDelete { file } => {
                gallery::delete_gallery_file(file)?;
                Ok(json!({ "deleted": true, "file": file }))
            }
            DeviceCmd::Backup { serial, out } => {
                let r = device_backup::device_backup(t.as_ref(), serial, out.as_deref())?;
                Ok(serde_json::to_value(r)?)
            }
            DeviceCmd::Restore { serial, backup, dry_run, confirm, skip_apps, include_data } => {
                let r = device_backup::device_restore(
                    t.as_ref(),
                    serial,
                    backup,
                    !*skip_apps,
                    *include_data,
                    *dry_run,
                    *confirm,
                )?;
                Ok(serde_json::to_value(r)?)
            }
            DeviceCmd::BackupList => {
                let entries = device_backup::list_device_backups()?;
                Ok(json!({ "backups": entries }))
            }
        },
        Commands::Library(a) => match &a.cmd {
            LibraryCmd::List => {
                let entries = library::list_library()?;
                Ok(json!({ "entries": entries }))
            }
            LibraryCmd::Import { file } => {
                let entry = library::import_apk(file)?;
                Ok(serde_json::to_value(entry)?)
            }
            LibraryCmd::Delete { path } => {
                library::delete_library_entry(path)?;
                Ok(json!({ "deleted": true, "path": path }))
            }
        },
        Commands::Settings(a) => match &a.cmd {
            SettingsCmd::Get { serial, key } => {
                let r = settings::get_setting(t.as_ref(), serial, key)?;
                let mut v = json!({ "key": key, "value": r.value });
                if let Some(w) = r.warning {
                    v["warning"] = json!(w);
                }
                Ok(v)
            }
            SettingsCmd::Set { serial, key, value } => {
                let model = model_of(t.as_ref(), serial);
                let r = settings::set_setting(t.as_ref(), serial, key, value, &model)?;
                let mut v = json!({ "key": key, "value": r.value, "model": model });
                if let Some(w) = r.warning {
                    v["warning"] = json!(w);
                }
                Ok(v)
            }
            SettingsCmd::Profile(p) => match &p.cmd {
                ProfileCmd::List => {
                    let profiles = settings::load_profiles()?;
                    let names: Vec<String> = profiles.keys().cloned().collect();
                    Ok(json!({ "profiles": names }))
                }
                ProfileCmd::Apply { serial, profile } => {
                    let profiles = settings::load_profiles()?;
                    let p = profiles.get(profile).ok_or_else(|| {
                        quest_core::Error(format!(
                            "unknown profile '{profile}'. Available: {}",
                            profiles.keys().cloned().collect::<Vec<_>>().join(", ")
                        ))
                    })?;
                    let model = model_of(t.as_ref(), serial);
                    let applied = settings::apply_profile(t.as_ref(), serial, p, &model)?;
                    Ok(json!({
                        "profile": profile,
                        "model": model,
                        "applied": applied.applied.iter().map(|(k, v)| json!({"key": k, "value": v})).collect::<Vec<_>>(),
                        "warnings": applied.warnings,
                    }))
                }
            },
        },
    }
}

/// `logcat --follow` streams raw lines; everything else is one JSON object.
fn logcat_follow(serial: &str) -> ExitCode {
    let adb = match resolve_adb_path() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(1);
        }
    };
    let status = std::process::Command::new(adb)
        .args(["-s", serial, "logcat", "-v", "threadtime"])
        .status();
    match status {
        Ok(s) => ExitCode::from(s.code().unwrap_or(0) as u8),
        Err(e) => {
            eprintln!("failed to start logcat: {e}");
            ExitCode::from(1)
        }
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    // Follow mode is the only non-JSON path, by design (see CONTRACT.md).
    if let Commands::Device(a) = &cli.cmd {
        if let DeviceCmd::Logcat { serial, follow } = &a.cmd {
            if *follow {
                return logcat_follow(serial);
            }
        }
    }
    match run(&cli) {
        Ok(value) => {
            let mut obj = match value {
                Value::Object(map) => map,
                other => {
                    let mut m = serde_json::Map::new();
                    m.insert("result".into(), other);
                    m
                }
            };
            obj.insert("ok".into(), Value::Bool(true));
            if cli.json {
                println!("{}", Value::Object(obj));
            } else {
                println!("{}", serde_json::to_string_pretty(&Value::Object(obj)).unwrap());
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            if cli.json {
                println!(
                    "{}",
                    json!({ "ok": false, "error": e.to_string() })
                );
            } else {
                eprintln!("error: {e}");
            }
            ExitCode::from(1)
        }
    }
}
