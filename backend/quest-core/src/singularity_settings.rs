//! Singularity downloads and rooted settings, reimplemented with
//! our own code from what Singularity publishes and what it leaves
//! on a rooted headset. Checked 2026-11-12.
//!
//! What Singularity itself publishes:
//! - The README's feature list and the `hosts` blocklist (74
//!   domains) in https://github.com/Lumince/singularity, plus the
//!   Frida server binary in the same repo (version 17.17.0).
//! - Singularity is CLOSED source. Nothing here bundles it, copies
//!   its code, or roots anything. Downloads are fetched at runtime
//!   from the author's repo; the blocklist is applied through
//!   Magisk's systemless-hosts path, which we create ourselves.
//!
//! What a rooted headset already shows, live:
//! - The update disabler is two global settings:
//!   `ota_download_url` and `ota_update_server_url`, both set to
//!   `http://127.0.0.1/`. The update engine then has nowhere to
//!   download from. Deleting both settings restores the stock
//!   update server. `com.oculus.updater` itself is left alone:
//!   it is a protected package, an earlier attempt to disable it
//!   failed, and the home menu may depend on it, so ReOculus only
//!   reports whether it is disabled, it never touches it.
//! - The dock and UI tweaks are plain `uxpatcher_*` global
//!   settings (battery percent, hiding the passthrough, profile,
//!   battery and notification buttons, dock order). They read and
//!   write with the normal `settings` command. Only the ones
//!   whose meaning is clear are offered as toggles; the rest are
//!   shown read-only.
//! - The domain blocker is NOT on a headset that only ran
//!   Singularity: /system/etc/hosts is still the stock 2 lines
//!   and there is no Magisk hosts module. Applying it here means
//!   creating the Magisk systemless-hosts module ourselves, with
//!   the stock localhost lines kept at the top (without them,
//!   localhost lookups break). It takes effect after a reboot,
//!   because Magisk mounts it at boot.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, CmdOutput, Target};
use serde::Serialize;
use std::path::Path;

/// The Singularity repo's raw Frida server binary (arm64).
pub const FRIDA_URL: &str =
    "https://raw.githubusercontent.com/Lumince/singularity/main/frida/frida-server";
pub const FRIDA_VERSION: &str = "17.17.0";
/// The exact size of the binary in the repo (verified 2026-11-12).
pub const FRIDA_SIZE: u64 = 53_539_200;
pub const FRIDA_REMOTE: &str = "/data/local/tmp/frida-server";

/// The Singularity repo's published domain blocklist.
pub const HOSTS_URL: &str =
    "https://raw.githubusercontent.com/Lumince/singularity/main/hosts";
/// The Magisk systemless-hosts module file. Magisk mounts it over
/// /system/etc/hosts at boot; nothing under /system is written.
pub const HOSTS_MODULE_FILE: &str = "/data/adb/modules/hosts/system/etc/hosts";
pub const HOSTS_TMP_REMOTE: &str = "/data/local/tmp/reoculus-hosts";

/// The two global settings Singularity's update disabler sets.
pub const OTA_DOWNLOAD_URL_KEY: &str = "ota_download_url";
pub const OTA_UPDATE_SERVER_URL_KEY: &str = "ota_update_server_url";
pub const OTA_LOOPBACK: &str = "http://127.0.0.1/";

/// The package ReOculus never touches, only reports.
pub const UPDATER_PACKAGE: &str = "com.oculus.updater";

/// Dock/UI toggles whose meaning is clear (key, label, plain detail).
/// Values are 0 (off) or 1 (on).
pub const UXP_TOGGLES: &[(&str, &str, &str)] = &[
    (
        "uxpatcher_battery_percent",
        "Battery percent in the dock",
        "Shows the battery percentage next to the battery icon.",
    ),
    (
        "uxpatcher_hide_passthrough",
        "Hide the passthrough button",
        "Hides the passthrough shortcut in the dock.",
    ),
    (
        "uxpatcher_hide_profile",
        "Hide the profile button",
        "Hides the profile shortcut in the dock.",
    ),
    (
        "uxpatcher_hide_battery_icon",
        "Hide the battery icon",
        "Hides the battery icon in the dock.",
    ),
    (
        "uxpatcher_hide_notif_badge",
        "Hide the notification badge",
        "Hides the badge that counts unread notifications.",
    ),
    (
        "uxpatcher_dock_library_first",
        "Library first in the dock",
        "Puts the Library button first in the dock.",
    ),
    (
        "uxpatcher_dock_apps_left",
        "Dock apps on the left",
        "Moves the dock apps to the left side.",
    ),
    (
        "uxpatcher_bg_enabled",
        "Custom dock background",
        "Lets the dock use a custom background colour.",
    ),
];

/// The rest of the uxpatcher settings (key, label). Shown for
/// info only; ReOculus does not change them, because what values
/// they accept is not documented anywhere public.
pub const UXP_READONLY: &[(&str, &str)] = &[
    ("uxpatcher_dock_order", "Dock button order"),
    ("uxpatcher_accent_color", "Dock accent colour"),
    ("uxpatcher_text_color", "Dock text colour"),
    ("uxpatcher_bg_color", "Dock background colour"),
    ("uxpatcher_pin_limit", "Pinned apps limit"),
    ("uxpatcher_gamepad_unlock", "Gamepad unlock"),
    ("uxpatcher_unknown_tab", "Unknown tab"),
];

#[derive(Debug, Clone, Serialize)]
pub struct DownloadItem {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub source: String,
    pub version: String,
    pub downloadable: bool,
    pub file: Option<String>,
    pub downloaded: bool,
    pub size_bytes: u64,
    pub sha256: Option<String>,
    pub on_headset: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FridaDownload {
    pub file: String,
    pub version: String,
    pub size_bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct HostsDownload {
    pub file: String,
    pub domains: usize,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FridaStatus {
    pub downloaded: bool,
    pub file: Option<String>,
    pub size_bytes: u64,
    pub sha256: Option<String>,
    pub pushed: bool,
    pub running: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct HostsStatus {
    pub downloaded: bool,
    pub file: Option<String>,
    pub domains: usize,
    pub size_bytes: u64,
    pub sha256: Option<String>,
    /// Lines in /system/etc/hosts. The stock file has 2 lines.
    pub system_lines: u64,
    pub applied: bool,
    pub module_domains: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct OtaStatus {
    pub blocked: bool,
    pub download_url: Option<String>,
    pub update_server_url: Option<String>,
    pub updater_disabled: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct UxpItem {
    pub key: String,
    pub label: String,
    pub detail: String,
    pub value: Option<String>,
    pub is_toggle: bool,
    pub enabled: bool,
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested)
// ---------------------------------------------------------------------------

/// Count the `0.0.0.0 <host>` lines in a hosts file.
pub fn count_blocked_domains(text: &str) -> usize {
    text.lines()
        .filter(|l| l.trim_start().starts_with("0.0.0.0 "))
        .count()
}

/// The file that goes into the Magisk hosts module: the stock
/// localhost lines first, then Singularity's blocklist as
/// published. The localhost lines must stay, or lookups of
/// `localhost` on the headset break.
pub fn build_combined_hosts(blocklist: &str) -> String {
    let mut s = String::from("127.0.0.1 localhost\n::1 ip6-localhost\n");
    let body = blocklist.trim();
    if !body.is_empty() {
        s.push_str(body);
        s.push('\n');
    }
    s
}

/// `settings get` prints `null` when a setting is unset.
pub fn parse_settings_get(text: &str) -> Option<String> {
    let v = text.trim();
    if v.is_empty() || v == "null" {
        None
    } else {
        Some(v.to_string())
    }
}

/// The `versionName=` line of a `dumpsys package` dump.
pub fn parse_version_name(text: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim();
        if let Some(v) = t.strip_prefix("versionName=") {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// `pm list packages -d` lists one `package:<name>` per line.
pub fn is_package_disabled(text: &str, pkg: &str) -> bool {
    let want = format!("package:{pkg}");
    text.lines().any(|l| l.trim() == want)
}

/// First whitespace-separated token of `wc -l` output.
pub fn parse_wc_lines(text: &str) -> u64 {
    text.split_whitespace()
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Small transport helpers
// ---------------------------------------------------------------------------

fn shell_root(t: &dyn AdbTransport, serial: &str, cmd: &str) -> Result<CmdOutput> {
    t.shell(&Target::serial(serial), &format!("su -c \"{cmd}\""))
}

/// Read a global setting. None when it is unset.
fn settings_get(t: &dyn AdbTransport, serial: &str, key: &str) -> Option<String> {
    let out = t
        .shell(&Target::serial(serial), &format!("settings get global {key}"))
        .ok()?;
    parse_settings_get(&out.stdout)
}

/// Write a global setting, then read it back to prove it stuck.
fn settings_put(t: &dyn AdbTransport, serial: &str, key: &str, value: &str) -> Result<()> {
    t.shell(
        &Target::serial(serial),
        &format!("settings put global {key} {value}"),
    )?;
    match settings_get(t, serial, key) {
        Some(v) if v == value => Ok(()),
        _ => Err(Error(format!(
            "the headset did not keep the new value for {key}"
        ))),
    }
}

/// Delete a global setting (restores the stock default), then
/// prove it is gone.
fn settings_delete(t: &dyn AdbTransport, serial: &str, key: &str) -> Result<()> {
    t.shell(
        &Target::serial(serial),
        &format!("settings delete global {key}"),
    )?;
    match settings_get(t, serial, key) {
        None => Ok(()),
        Some(v) => Err(Error(format!("{key} is still set to {v}"))),
    }
}

fn installed_version(t: &dyn AdbTransport, serial: &str, pkg: &str) -> Option<String> {
    let out = t
        .shell(&Target::serial(serial), &format!("dumpsys package {pkg}"))
        .ok()?;
    parse_version_name(&out.stdout)
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

pub fn download_frida() -> Result<FridaDownload> {
    let dir = crate::singularity::cache_dir()?;
    let file = dir.join("frida-server");
    crate::singularity::curl(FRIDA_URL, &file)?;
    let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
    if size != FRIDA_SIZE {
        let _ = std::fs::remove_file(&file);
        return Err(Error(format!(
            "the Frida download is {size} bytes, not the {FRIDA_SIZE} bytes the repo lists. The file was removed."
        )));
    }
    let hash = crate::singularity::sha256_file(&file)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))?;
    Ok(FridaDownload {
        file: file.to_string_lossy().into_owned(),
        version: FRIDA_VERSION.to_string(),
        size_bytes: size,
        sha256: hash,
    })
}

pub fn download_hosts() -> Result<HostsDownload> {
    download_hosts_with_cache(&crate::singularity::cache_dir()?)
}

pub fn download_hosts_with_cache(cache: &Path) -> Result<HostsDownload> {
    let file = cache.join("hosts");
    crate::singularity::curl(HOSTS_URL, &file)?;
    let text = std::fs::read_to_string(&file)
        .map_err(|e| Error(format!("the downloaded blocklist could not be read: {e}")))?;
    let domains = count_blocked_domains(&text);
    if domains < 10 {
        let _ = std::fs::remove_file(&file);
        return Err(Error(format!(
            "the download only lists {domains} blocked domains, which is not the real blocklist"
        )));
    }
    let hash = crate::singularity::sha256_file(&file)?;
    Ok(HostsDownload {
        file: file.to_string_lossy().into_owned(),
        domains,
        sha256: hash,
    })
}

/// Every downloadable Singularity piece, with its state on this
/// PC and on the headset.
pub fn downloads_list(t: &dyn AdbTransport, serial: &str) -> Result<Vec<DownloadItem>> {
    let mut items = Vec::new();

    let apk = crate::singularity::cached_apk();
    let (downloaded, file, size_bytes, sha256, version) = match &apk {
        Some(p) => {
            let size = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let sha = crate::singularity::sha256_file(p).ok();
            let ver = crate::apps::badging_of(p)
                .ok()
                .and_then(|b| b.version)
                .unwrap_or_else(|| "downloaded".to_string());
            (true, Some(p.to_string_lossy().into_owned()), size, sha, ver)
        }
        None => (false, None, 0, None, "not downloaded".to_string()),
    };
    let installed = installed_version(t, serial, "com.lumi.singularity");
    let magisk = installed_version(t, serial, "com.singularity.magisk");
    let on_headset = match &installed {
        Some(v) => {
            let m = magisk
                .map(|x| format!(", Magisk {x}"))
                .unwrap_or_default();
            format!("installed {v}{m}")
        }
        None => "not installed".to_string(),
    };
    items.push(DownloadItem {
        id: "singularity".to_string(),
        name: "Singularity".to_string(),
        detail: "The root app itself. Download the latest release from GitHub, then install it. Rooting still happens in Singularity on the headset.".to_string(),
        source: "GitHub releases (Lumince/singularity)".to_string(),
        version,
        downloadable: true,
        file,
        downloaded,
        size_bytes,
        sha256,
        on_headset,
    });

    let f = frida_status(t, serial)?;
    items.push(DownloadItem {
        id: "frida".to_string(),
        name: "Frida server".to_string(),
        detail: "Lets a researcher attach Frida to processes on the headset. Not needed for normal use.".to_string(),
        source: "Lumince/singularity repo (frida/frida-server)".to_string(),
        version: FRIDA_VERSION.to_string(),
        downloadable: true,
        file: f.file,
        downloaded: f.downloaded,
        size_bytes: f.size_bytes,
        sha256: f.sha256,
        on_headset: if f.running {
            "on headset, running".to_string()
        } else if f.pushed {
            "on headset".to_string()
        } else {
            "not on headset".to_string()
        },
    });

    let h = hosts_status(t, serial)?;
    items.push(DownloadItem {
        id: "hosts".to_string(),
        name: "Meta domain blocklist".to_string(),
        detail: "Singularity's published list of Meta telemetry, store and social domains. Applying it blocks those domains on the headset. It needs a reboot to take effect.".to_string(),
        source: "Lumince/singularity repo (hosts)".to_string(),
        version: if h.downloaded {
            format!("{} domains", h.domains)
        } else {
            "not downloaded".to_string()
        },
        downloadable: true,
        file: h.file,
        downloaded: h.downloaded,
        size_bytes: h.size_bytes,
        sha256: h.sha256,
        on_headset: if h.applied {
            format!("applied ({} domains)", h.module_domains)
        } else {
            "not applied".to_string()
        },
    });

    items.push(DownloadItem {
        id: "freexr".to_string(),
        name: "FreeXR safe-root-things".to_string(),
        detail: "LED colour, UI tweaks and more from FreeXR. It publishes no release download, so ReOculus does not download it. Get it from its GitHub page.".to_string(),
        source: "https://github.com/FreeXR/safe-root-things".to_string(),
        version: "no release".to_string(),
        downloadable: false,
        file: None,
        downloaded: false,
        size_bytes: 0,
        sha256: None,
        on_headset: "not checked".to_string(),
    });
    Ok(items)
}

// ---------------------------------------------------------------------------
// Frida server on the headset
// ---------------------------------------------------------------------------

pub fn frida_status(t: &dyn AdbTransport, serial: &str) -> Result<FridaStatus> {
    let cache = crate::singularity::cache_dir()?;
    let file = cache.join("frida-server");
    let downloaded = file.exists();
    let size_bytes = if downloaded {
        std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };
    let sha256 = if downloaded {
        crate::singularity::sha256_file(&file).ok()
    } else {
        None
    };
    let target = Target::serial(serial);
    let chk = t.shell(
        &target,
        &format!("test -f {FRIDA_REMOTE} && echo yes || echo no"),
    )?;
    let pushed = chk.stdout.trim() == "yes";
    let pid = t.shell(&target, "pidof frida-server")?;
    let running = !pid.stdout.trim().is_empty();
    Ok(FridaStatus {
        downloaded,
        file: if downloaded {
            Some(file.to_string_lossy().into_owned())
        } else {
            None
        },
        size_bytes,
        sha256,
        pushed,
        running,
    })
}

pub fn frida_push(t: &dyn AdbTransport, serial: &str) -> Result<FridaStatus> {
    let cache = crate::singularity::cache_dir()?;
    let file = cache.join("frida-server");
    if !file.exists() {
        return Err(Error("Frida is not downloaded yet. Download it first.".into()));
    }
    let target = Target::serial(serial);
    t.push(&target, &file, FRIDA_REMOTE)?;
    t.shell(&target, &format!("chmod 755 {FRIDA_REMOTE}"))?;
    let st = frida_status(t, serial)?;
    if !st.pushed {
        return Err(Error(
            "the Frida server did not land on the headset".into(),
        ));
    }
    Ok(st)
}

pub fn frida_start(t: &dyn AdbTransport, serial: &str) -> Result<FridaStatus> {
    let st0 = frida_status(t, serial)?;
    if !st0.pushed {
        return Err(Error(
            "Frida is not on the headset yet. Push it first.".into(),
        ));
    }
    if st0.running {
        return Ok(st0);
    }
    shell_root(
        t,
        serial,
        &format!("nohup {FRIDA_REMOTE} >/data/local/tmp/frida-server.log 2>&1 &"),
    )?;
    for _ in 0..6 {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let st = frida_status(t, serial)?;
        if st.running {
            return Ok(st);
        }
    }
    Err(Error(
        "Frida did not start. Its log is at /data/local/tmp/frida-server.log on the headset."
            .into(),
    ))
}

pub fn frida_stop(t: &dyn AdbTransport, serial: &str) -> Result<FridaStatus> {
    shell_root(t, serial, "pkill -x frida-server")?;
    std::thread::sleep(std::time::Duration::from_millis(500));
    let st = frida_status(t, serial)?;
    if st.running {
        return Err(Error(
            "Frida is still running after the stop command".into(),
        ));
    }
    Ok(st)
}

// ---------------------------------------------------------------------------
// Domain blocklist (hosts)
// ---------------------------------------------------------------------------

pub fn hosts_status(t: &dyn AdbTransport, serial: &str) -> Result<HostsStatus> {
    hosts_status_with_cache(t, serial, &crate::singularity::cache_dir()?)
}

pub fn hosts_status_with_cache(
    t: &dyn AdbTransport,
    serial: &str,
    cache: &Path,
) -> Result<HostsStatus> {
    let target = Target::serial(serial);
    let file = cache.join("hosts");
    let downloaded = file.exists();
    let (domains, size_bytes, sha256) = if downloaded {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        let sha = crate::singularity::sha256_file(&file).ok();
        (count_blocked_domains(&text), size, sha)
    } else {
        (0, 0, None)
    };
    let wc = t.shell(&target, "wc -l /system/etc/hosts")?;
    let system_lines = parse_wc_lines(&wc.stdout);
    let chk = shell_root(
        t,
        serial,
        &format!("test -f {HOSTS_MODULE_FILE} && echo yes || echo no"),
    )?;
    let applied = chk.stdout.trim() == "yes";
    let module_domains = if applied {
        let g = shell_root(
            t,
            serial,
            &format!("grep -c 0.0.0.0 {HOSTS_MODULE_FILE}"),
        )?;
        g.stdout.trim().parse::<usize>().unwrap_or(0)
    } else {
        0
    };
    Ok(HostsStatus {
        downloaded,
        file: if downloaded {
            Some(file.to_string_lossy().into_owned())
        } else {
            None
        },
        domains,
        size_bytes,
        sha256,
        system_lines,
        applied,
        module_domains,
    })
}

/// Apply the blocklist through the Magisk systemless-hosts
/// module. Takes effect after a reboot. If the module already
/// has a hosts file, it is backed up first.
pub fn hosts_apply(t: &dyn AdbTransport, serial: &str) -> Result<HostsStatus> {
    hosts_apply_with_cache(t, serial, &crate::singularity::cache_dir()?)
}

pub fn hosts_apply_with_cache(
    t: &dyn AdbTransport,
    serial: &str,
    cache: &Path,
) -> Result<HostsStatus> {
    let hosts_file = cache.join("hosts");
    if !hosts_file.exists() {
        download_hosts_with_cache(cache)?;
    }
    let text = std::fs::read_to_string(&hosts_file)
        .map_err(|e| Error(format!("the downloaded blocklist could not be read: {e}")))?;
    let domains = count_blocked_domains(&text);
    let combined = build_combined_hosts(&text);
    let combined_file = cache.join("hosts-combined");
    std::fs::write(&combined_file, &combined)?;
    let target = Target::serial(serial);
    // Back up whatever module hosts file is already there.
    let _ = shell_root(
        t,
        serial,
        &format!(
            "test -f {HOSTS_MODULE_FILE} && cp {HOSTS_MODULE_FILE} /data/local/tmp/reoculus-hosts.bak"
        ),
    );
    t.push(&target, &combined_file, HOSTS_TMP_REMOTE)?;
    shell_root(
        t,
        serial,
        &format!(
            "mkdir -p /data/adb/modules/hosts/system/etc && cp {HOSTS_TMP_REMOTE} {HOSTS_MODULE_FILE} && chmod 644 {HOSTS_MODULE_FILE} && rm -f /data/adb/modules/hosts/disable"
        ),
    )?;
    let st = hosts_status_with_cache(t, serial, cache)?;
    if !st.applied {
        return Err(Error(
            "the blocklist file did not land in the Magisk hosts module".into(),
        ));
    }
    if st.module_domains != domains {
        return Err(Error(format!(
            "the blocklist landed but only lists {} domains (expected {})",
            st.module_domains, domains
        )));
    }
    Ok(st)
}

pub fn hosts_remove(t: &dyn AdbTransport, serial: &str) -> Result<HostsStatus> {
    shell_root(t, serial, &format!("rm -f {HOSTS_MODULE_FILE}"))?;
    let st = hosts_status(t, serial)?;
    if st.applied {
        return Err(Error("the blocklist file is still there".into()));
    }
    Ok(st)
}

// ---------------------------------------------------------------------------
// Update engine (OTA)
// ---------------------------------------------------------------------------

/// The update disabler, as it is found on a rooted headset: both
/// OTA server settings point at localhost, so the update engine
/// has nowhere to download from. Read-only about the updater app
/// itself, which ReOculus never touches.
pub fn ota_status(t: &dyn AdbTransport, serial: &str) -> Result<OtaStatus> {
    let download_url = settings_get(t, serial, OTA_DOWNLOAD_URL_KEY);
    let update_server_url = settings_get(t, serial, OTA_UPDATE_SERVER_URL_KEY);
    let blocked = download_url.as_deref() == Some(OTA_LOOPBACK)
        && update_server_url.as_deref() == Some(OTA_LOOPBACK);
    let out = t.shell(&Target::serial(serial), "pm list packages -d")?;
    let updater_disabled = is_package_disabled(&out.stdout, UPDATER_PACKAGE);
    Ok(OtaStatus {
        blocked,
        download_url,
        update_server_url,
        updater_disabled,
    })
}

/// Block updates (point both OTA settings at localhost) or allow
/// them again (delete both settings, restoring the stock server).
pub fn ota_set(t: &dyn AdbTransport, serial: &str, blocked: bool) -> Result<OtaStatus> {
    if blocked {
        settings_put(t, serial, OTA_DOWNLOAD_URL_KEY, OTA_LOOPBACK)?;
        settings_put(t, serial, OTA_UPDATE_SERVER_URL_KEY, OTA_LOOPBACK)?;
    } else {
        settings_delete(t, serial, OTA_DOWNLOAD_URL_KEY)?;
        settings_delete(t, serial, OTA_UPDATE_SERVER_URL_KEY)?;
    }
    ota_status(t, serial)
}

// ---------------------------------------------------------------------------
// Dock/UI (uxpatcher) settings
// ---------------------------------------------------------------------------

pub fn uxp_list(t: &dyn AdbTransport, serial: &str) -> Result<Vec<UxpItem>> {
    let mut out = Vec::new();
    for (key, label, detail) in UXP_TOGGLES {
        let value = settings_get(t, serial, key);
        let enabled = value.as_deref() == Some("1");
        out.push(UxpItem {
            key: key.to_string(),
            label: label.to_string(),
            detail: detail.to_string(),
            value,
            is_toggle: true,
            enabled,
        });
    }
    for (key, label) in UXP_READONLY {
        let value = settings_get(t, serial, key);
        out.push(UxpItem {
            key: key.to_string(),
            label: label.to_string(),
            detail: "Shown for info. ReOculus does not change this one.".to_string(),
            value,
            is_toggle: false,
            enabled: false,
        });
    }
    Ok(out)
}

pub fn uxp_set(t: &dyn AdbTransport, serial: &str, key: &str, value: &str) -> Result<UxpItem> {
    let found = UXP_TOGGLES.iter().find(|(k, _, _)| *k == key);
    let Some((_, label, detail)) = found else {
        return Err(Error(format!(
            "{key} is not a setting ReOculus changes (it is shown for info only)"
        )));
    };
    if value != "0" && value != "1" {
        return Err(Error("the value must be 0 (off) or 1 (on)".into()));
    }
    settings_put(t, serial, key, value)?;
    Ok(UxpItem {
        key: key.to_string(),
        label: label.to_string(),
        detail: detail.to_string(),
        value: Some(value.to_string()),
        is_toggle: true,
        enabled: value == "1",
    })
}

/// Restart the home screen (vrshell) so new dock settings take
/// effect. The home comes back on its own in a few seconds.
pub fn restart_home(t: &dyn AdbTransport, serial: &str) -> Result<String> {
    t.shell(&Target::serial(serial), "am force-stop com.oculus.vrshell")?;
    Ok("The home screen was restarted. It comes back in a few seconds with the new dock settings.".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosts_count_and_combined() {
        let text = "# Telemetry\n0.0.0.0 graph.oculus.com\n0.0.0.0 graph.facebook.com\n127.0.0.1 localhost\n\n0.0.0.0 api.oculus.com\n";
        assert_eq!(count_blocked_domains(text), 3);
        let combined = build_combined_hosts(text);
        assert!(combined.starts_with("127.0.0.1 localhost\n::1 ip6-localhost\n"));
        assert!(combined.contains("0.0.0.0 graph.oculus.com"));
        assert_eq!(count_blocked_domains(&combined), 3);
        assert!(combined.ends_with('\n'));
    }

    #[test]
    fn settings_get_parsing() {
        assert_eq!(parse_settings_get("http://127.0.0.1/\n"), Some("http://127.0.0.1/".into()));
        assert_eq!(parse_settings_get("null\n"), None);
        assert_eq!(parse_settings_get(""), None);
        assert_eq!(parse_settings_get("1\n"), Some("1".into()));
    }

    #[test]
    fn version_name_and_disabled() {
        let dump = "  Package [com.lumi.singularity] (1):\n    versionName=1.0.8\n    versionCode=108\n";
        assert_eq!(parse_version_name(dump).as_deref(), Some("1.0.8"));
        assert_eq!(parse_version_name("nothing here"), None);
        let d = "package:com.meta.credentialsmanager\npackage:com.oculus.updater\n";
        assert!(is_package_disabled(d, "com.oculus.updater"));
        assert!(!is_package_disabled(d, "com.oculus.vrshell"));
    }

    #[test]
    fn wc_lines_parsing() {
        assert_eq!(parse_wc_lines("2 /system/etc/hosts\n"), 2);
        assert_eq!(parse_wc_lines(""), 0);
    }

    #[test]
    fn uxp_tables_are_sane() {
        assert!(!UXP_TOGGLES.is_empty());
        for (key, _, _) in UXP_TOGGLES {
            assert!(key.starts_with("uxpatcher_"), "{key}");
        }
        for (key, _) in UXP_READONLY {
            assert!(key.starts_with("uxpatcher_"), "{key}");
        }
        // No key appears in both tables.
        for (key, _) in UXP_READONLY {
            assert!(!UXP_TOGGLES.iter().any(|(k, _, _)| k == key), "{key}");
        }
    }
}
