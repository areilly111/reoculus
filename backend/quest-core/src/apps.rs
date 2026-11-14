//! App management: list / install (incl. split APKs, .apks/.xapk) /
//! uninstall / launch / force-stop / clear-data. Plain `pm`/`am` over ADB.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::Serialize;
use std::fs::File;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct AppInfo {
    pub package: String,
    pub label: String,
    pub version: String,
    pub system: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apk_path: Option<String>,
    /// Local icon file, only when `apps list --with-icons` found a
    /// cached icon for this package+version. Absent otherwise (the
    /// list stays fast and never pulls APKs).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_path: Option<String>,
    // ---- Sizes and details (see `apps details`, CONTRACT.md) ----
    // All optional: absent when the device could not report them
    // (e.g. data size needs root; unprivileged reads fail).
    // Sizes are bytes. `total_size_bytes` is apk + data + obb over
    // the sizes that were actually measured.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_code: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_sdk: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_sdk: Option<u32>,
    /// `firstInstallTime` from dumpsys, e.g. "2026-11-09 16:45:20".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_install_time: Option<String>,
    /// `lastUpdateTime` from dumpsys.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_update_time: Option<String>,
    /// Installer package, e.g. `com.oculus.ocms` (Store). Sideloaded
    /// apps report none; the backend maps those to "sideloaded (adb)"
    /// when the initiating package was the adb shell.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apk_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub obb_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_size_bytes: Option<u64>,
    /// Requested permissions from dumpsys (plain names). Empty when
    /// the list was taken without the details parse, or the app
    /// requests none.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub permissions: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AppIcon {
    pub package: String,
    pub label: String,
    pub version: String,
    /// Path to the extracted icon file (cache, or `--out` when given).
    pub icon_path: String,
    /// File name inside the APK the icon came from, e.g.
    /// `res/mipmap-xxxhdpi/app_icon.png` or `res/oj.png`.
    pub icon_file: String,
}

/// Parse `pm list packages [-3] [-f]` output.
/// Lines: `package:com.foo` or `package:/data/app/.../base.apk=com.foo`
pub fn parse_pm_list(text: &str) -> Vec<(String, Option<String>)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("package:") {
            if let Some((path, pkg)) = rest.rsplit_once('=') {
                out.push((pkg.to_string(), Some(path.to_string())));
            } else {
                out.push((rest.to_string(), None));
            }
        }
    }
    out
}

/// Everything `dumpsys package` reports about one app that is
/// worth showing. Parsed from the `Package [<pkg>]` section of a
/// full `dumpsys package packages` dump or a single-package dump.
/// Fields the device does not report stay `None` / empty; nothing
/// here is invented.
///
/// Honest limit: an APK / dumpsys carries **no developer or maker
/// name** (aapt `dump badging` gives label, version and icon, never
/// an author; Play/Store metadata is not on the device and this app
/// never calls Meta/Play APIs). There is deliberately no `maker`
/// field; the UI says "Maker: not stored in the APK".
#[derive(Debug, Clone, Default)]
pub struct PkgDetails {
    pub version: String,
    pub version_code: Option<i64>,
    pub min_sdk: Option<u32>,
    pub target_sdk: Option<u32>,
    pub first_install_time: Option<String>,
    pub last_update_time: Option<String>,
    /// `installerPackageName`, or "sideloaded (adb)" when it is null
    /// and the initiating package was the adb shell.
    pub installer: Option<String>,
    /// `requested permissions:` list (plain permission names).
    pub permissions: Vec<String>,
    /// `install permissions:` list (the full `dumpsys package
    /// packages` dump has no "requested permissions:" section, only
    /// this one). Used as the permissions fallback when no requested
    /// list was seen for the package.
    #[allow(dead_code)]
    pub install_permissions: Vec<String>,
}

/// Parse one full `dumpsys package` (or `dumpsys package <pkg>`) dump
/// into package -> full details. Section headers look like
/// `  Package [com.foo] (` and the fields live inside that section:
/// `    versionName=1.2.3`,
/// `    versionCode=123 minSdk=29 targetSdk=34`,
/// `    lastUpdateTime=2026-08-30 07:42:41`,
/// `    installerPackageName=com.oculus.ocms` (or `null`),
/// `    requested permissions:` followed by indented bare names,
/// and `      firstInstallTime=2026-11-09 16:45:20` in the `User 0:`
/// sub-block. Lines outside a `Package [...]` section are ignored.
pub fn parse_dumpsys_packages(text: &str) -> std::collections::HashMap<String, PkgDetails> {
    let mut map: std::collections::HashMap<String, PkgDetails> = std::collections::HashMap::new();
    let mut current: Option<String> = None;
    let mut in_requested = false;
    let mut in_install = false;
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("Package [") {
            if let Some(pkg) = rest.split(']').next() {
                current = Some(pkg.to_string());
                in_requested = false;
                in_install = false;
            }
            continue;
        }
        let Some(pkg) = &current else { continue };
        let d = map.entry(pkg.clone()).or_default();
        if t == "requested permissions:" {
            in_requested = true;
            in_install = false;
            continue;
        }
        if t == "install permissions:" {
            // The full `dumpsys package packages` dump does NOT
            // include "requested permissions:" at all; it only has
            // this section (`name: granted=true/false`). Collect the
            // names as a fallback; a "requested permissions:" section
            // later in the same package replaces them (single-app
            // dumps have both, requested first).
            in_install = true;
            in_requested = false;
            continue;
        }
        if in_requested {
            // Requested permissions are indented bare names with no
            // `=` and no spaces, e.g. `android.permission.INTERNET`.
            // Any other line ends the section.
            if !t.is_empty() && !t.contains(' ') && !t.contains('=') && !t.ends_with(':') {
                d.permissions.push(t.to_string());
                continue;
            }
            in_requested = false;
        }
        if in_install {
            // `android.permission.INTERNET: granted=true`
            if let Some((name, _)) = t.split_once(": granted=") {
                if !name.contains(' ') && !name.is_empty() {
                    d.install_permissions.push(name.to_string());
                    continue;
                }
            }
            in_install = false;
        }
        if let Some(v) = t.strip_prefix("versionName=") {
            d.version = v.trim().to_string();
        } else if let Some(rest) = t.strip_prefix("versionCode=") {
            // `versionCode=20310001 minSdk=29 targetSdk=34`: the code
            // itself is the bare first token, the SDKs are k=v pairs.
            let mut it = rest.split_whitespace();
            if let Some(code) = it.next() {
                d.version_code = code.parse().ok();
            }
            for kv in it {
                if let Some((k, v)) = kv.split_once('=') {
                    match k {
                        "minSdk" => d.min_sdk = v.parse().ok(),
                        "targetSdk" => d.target_sdk = v.parse().ok(),
                        _ => {}
                    }
                }
            }
        } else if let Some(v) = t.strip_prefix("lastUpdateTime=") {
            d.last_update_time = Some(v.trim().to_string());
        } else if let Some(v) = t.strip_prefix("firstInstallTime=") {
            d.first_install_time = Some(v.trim().to_string());
        } else if let Some(v) = t.strip_prefix("installerPackageName=") {
            let v = v.trim();
            if v != "null" && !v.is_empty() {
                d.installer = Some(v.to_string());
            }
        }
    }
    // Sideload mapping: installer null + the install was initiated
    // by the adb shell means sideloaded. `initiatingPackageName`
    // lives in the same `Package [...]` section, so collect it in a
    // second pass over the raw text.
    let mut cur: Option<String> = None;
    let mut init_map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("Package [") {
            cur = rest.split(']').next().map(|s| s.to_string());
        } else if let Some(v) = t.strip_prefix("initiatingPackageName=") {
            if let Some(p) = &cur {
                init_map.insert(p.clone(), v.trim().to_string());
            }
        }
    }
    for (pkg, d) in map.iter_mut() {
        if d.installer.is_none() {
            if init_map.get(pkg).map(|s| s.as_str()) == Some("com.android.shell") {
                d.installer = Some("sideloaded (adb)".to_string());
            }
        }
        // Permissions: the requested list when the dump has one
        // (single-app dumps), else the install list (full dumps).
        if d.permissions.is_empty() {
            d.permissions = std::mem::take(&mut d.install_permissions);
        }
    }
    map
}

/// Parse one full `dumpsys package` (or `dumpsys package <pkg>`) dump
/// into package -> versionName. Kept for callers that only need the
/// version; implemented on top of [`parse_dumpsys_packages`].
pub fn parse_dumpsys_versions(text: &str) -> std::collections::HashMap<String, String> {
    parse_dumpsys_packages(text)
        .into_iter()
        .map(|(p, d)| (p, d.version))
        .collect()
}

/// Parse `ls -l <apk path>` lines (one per APK) into apk path ->
/// size in bytes. Lines look like (toybox `ls` dates are one
/// `YYYY-MM-DD HH:MM` pair, so 8 fields, not the classic 9):
/// `-rw-r--r-- 1 system system 247256857 2026-08-30 07:42 /data/app/.../base.apk`
/// Android paths never contain spaces, so the last field is the path
/// and field 5 (0-based 4) is the size.
pub fn parse_ls_apk_sizes(text: &str) -> std::collections::HashMap<String, u64> {
    let mut map = std::collections::HashMap::new();
    for line in text.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 8 || !fields[0].starts_with('-') {
            continue;
        }
        if let Ok(size) = fields[4].parse::<u64>() {
            map.insert(fields[fields.len() - 1].to_string(), size);
        }
    }
    map
}

/// Parse `du -sb <path>` lines (bytes, tab-separated) into path ->
/// size in bytes. Used for `/data/data/*` (root `du`) and
/// `/sdcard/Android/obb/*`.
pub fn parse_du_sizes(text: &str) -> std::collections::HashMap<String, u64> {
    let mut map = std::collections::HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut it = line.splitn(2, |c: char| c.is_whitespace());
        if let (Some(size), Some(path)) = (it.next(), it.next()) {
            if let Ok(size) = size.parse::<u64>() {
                map.insert(path.trim().to_string(), size);
            }
        }
    }
    map
}

/// Map an adb install `Failure [CODE]` to a human sentence.
pub fn friendly_install_error(text: &str) -> String {
    let code = text
        .lines()
        .find_map(|l| {
            let l = l.trim();
            l.strip_prefix("Failure [")
                .and_then(|r| r.strip_suffix(']'))
                .map(|c| c.to_string())
        })
        .unwrap_or_else(|| text.trim().to_string());
    let hint = match code.as_str() {
        "INSTALL_FAILED_ALREADY_EXISTS" => " (already installed; use --reinstall)",
        "INSTALL_FAILED_INVALID_APK" => {
            " (invalid APK, or a split APK installed without its other splits)"
        }
        "INSTALL_FAILED_VERSION_DOWNGRADE" => " (the installed version is newer)",
        "INSTALL_FAILED_NO_MATCHING_ABIS" => " (APK is for a different CPU architecture)",
        "INSTALL_FAILED_INSUFFICIENT_STORAGE" => " (not enough storage on the headset)",
        "INSTALL_FAILED_USER_RESTRICTED" => {
            " (install blocked on the headset; check the in-headset prompt)"
        }
        "INSTALL_FAILED_TEST_ONLY" => " (test-only APK; install with -t)",
        _ => "",
    };
    format!("{code}{hint}")
}

// ---------------------------------------------------------------------------
// Listing apps
// ---------------------------------------------------------------------------

/// List the apps on the headset. `third_party` true lists only
/// user-installed apps, false lists everything including system apps.
/// Returns the light list (no APK sizes, no icons); use
/// `list_apps_with_icons` or `list_apps_with_details` when the UI needs
/// more. Runs on the headset over ADB.
pub fn list_apps(t: &dyn AdbTransport, serial: &str, third_party: bool) -> Result<Vec<AppInfo>> {
    list_apps_impl(t, serial, third_party, false, false)
}

/// List apps, and when `with_icons` is set, fill `icon_path` / the real
/// label from the **cache only** — it never pulls an APK. A first
/// `apps icon` call for an app populates the cache; later lists are
/// fast. Pulling all 235 APKs on every list would be slow and fill
/// storage, so it is deliberately not done here.
pub fn list_apps_with_icons(
    t: &dyn AdbTransport,
    serial: &str,
    third_party: bool,
) -> Result<Vec<AppInfo>> {
    list_apps_impl(t, serial, third_party, true, false)
}

/// List apps with APK / data / OBB sizes and the dumpsys details
/// (version code, SDK levels, install/update dates, installer,
/// requested permissions). Sizes come from three **batched** shell
/// calls, not one call per app, so the list stays fast:
/// one `ls -l` over every APK path, one `du -sb /sdcard/Android/obb/*`,
/// and one root `du -sb /data/data/*` (3 s on a Quest 2; data size
/// is skipped, not fatal, when the headset is not rooted).
/// `with_icons` behaves as in [`list_apps_with_icons`].
pub fn list_apps_with_sizes(
    t: &dyn AdbTransport,
    serial: &str,
    third_party: bool,
    with_icons: bool,
) -> Result<Vec<AppInfo>> {
    list_apps_impl(t, serial, third_party, with_icons, true)
}

fn list_apps_impl(
    t: &dyn AdbTransport,
    serial: &str,
    third_party: bool,
    with_icons: bool,
    with_sizes: bool,
) -> Result<Vec<AppInfo>> {
    let target = Target::serial(serial);
    let mut cmd = String::from("pm list packages -f");
    if third_party {
        cmd.push_str(" -3");
    } else {
        // Keep system apps distinguishable: list everything, then
        // re-list third-party only and mark the difference.
    }
    let listed = parse_pm_list(&t.shell(&target, &cmd)?.stdout);
    let third: std::collections::HashSet<String> = if third_party {
        listed.iter().map(|(p, _)| p.clone()).collect()
    } else {
        parse_pm_list(&t.shell(&target, "pm list packages -3")?.stdout)
            .into_iter()
            .map(|(p, _)| p)
            .collect()
    };
    // One full dumpsys for versions + details (a single call; the
    // parse below reads version code, SDK levels, dates, installer
    // and requested permissions out of the same output).
    let details = match t.shell(&target, "dumpsys package packages") {
        Ok(o) => parse_dumpsys_packages(&o.stdout),
        Err(_) => std::collections::HashMap::new(),
    };
    // Batched sizes (only when asked for): one `ls -l` over every
    // APK path, one `du` over every OBB dir, one root `du` over
    // every app data dir. No per-app calls.
    let (apk_sizes, data_sizes, obb_sizes) = if with_sizes {
        sized_maps(t, &target)
    } else {
        Default::default()
    };
    let mut apps: Vec<AppInfo> = listed
        .into_iter()
        .map(|(package, apk_path)| {
            let system = !third.contains(&package);
            let label = package.rsplit('.').next().unwrap_or(&package).to_string();
            let d = details.get(&package);
            let version = d.map(|d| d.version.clone()).unwrap_or_default();
            let apk_size_bytes = apk_path.as_ref().and_then(|p| apk_sizes.get(p).copied());
            // OBB / data dirs are keyed by package name.
            let data_size_bytes = data_sizes.get(&format!("/data/data/{package}")).copied();
            let obb_size_bytes = obb_sizes.get(&format!("/sdcard/Android/obb/{package}")).copied();
            let total_size_bytes = {
                let sum: u64 = [apk_size_bytes, data_size_bytes, obb_size_bytes]
                    .into_iter()
                    .flatten()
                    .sum();
                if apk_size_bytes.is_none() && data_size_bytes.is_none() && obb_size_bytes.is_none() {
                    None
                } else {
                    Some(sum)
                }
            };
            let mut info = AppInfo {
                version,
                package,
                label,
                system,
                apk_path,
                icon_path: None,
                version_code: d.and_then(|d| d.version_code),
                min_sdk: d.and_then(|d| d.min_sdk),
                target_sdk: d.and_then(|d| d.target_sdk),
                first_install_time: d.and_then(|d| d.first_install_time.clone()),
                last_update_time: d.and_then(|d| d.last_update_time.clone()),
                installer: d.and_then(|d| d.installer.clone()),
                apk_size_bytes,
                data_size_bytes,
                obb_size_bytes,
                total_size_bytes,
                permissions: d.map(|d| d.permissions.clone()).unwrap_or_default(),
            };
            if with_icons {
                if let Some((path, cached_label)) =
                    cached_icon(&info.package, &info.version)
                {
                    info.icon_path = Some(path.to_string_lossy().into_owned());
                    if !cached_label.is_empty() {
                        info.label = cached_label;
                    }
                }
            }
            info
        })
        .collect();
    apps.sort_by(|a, b| a.package.cmp(&b.package));
    Ok(apps)
}

/// The three batched size calls for [`list_apps_with_sizes`].
/// Each step is best-effort: a failure yields an empty map for that
/// size (the UI then shows the size as unknown, not an error).
/// Note the APK loop uses `ls -l` on the exact paths from
/// `pm list packages -f`, not a glob: the `/data/app/~~<hash>/`
/// dirs are not listable by the shell user, so a `*.apk` glob
/// there expands to nothing, while a direct `ls -l` of the file
/// works (the APKs themselves are world-readable). Split APKs
/// (rare on Quest) are not in the `pm list -f` output, so the list
/// APK size is the base APK only; `apps details` resolves all
/// splits with `pm path` and sizes them exactly.
fn sized_maps(
    t: &dyn AdbTransport,
    target: &Target,
) -> (
    std::collections::HashMap<String, u64>,
    std::collections::HashMap<String, u64>,
    std::collections::HashMap<String, u64>,
) {
    let apk_sizes = t
        .shell(
            target,
            // NOTE: do NOT extract the path with `cut -d= -f1`: the
            // /data/app/~~<hash>==/ dirs contain `==`, so cut would
            // truncate the path at the first `=`. sed strips only the
            // trailing `=<package>` instead.
            "for p in $(pm list packages -f | sed 's/^package://; s/=[^=]*$//'); do ls -l \"$p\" 2>/dev/null; done",
        )
        .map(|o| parse_ls_apk_sizes(&o.stdout))
        .unwrap_or_default();
    // App data: needs root (the shell user gets "Permission denied"
    // on /data/data/<other app>). `su` failing just means data sizes
    // stay unknown; the call takes ~3 s on a rooted Quest 2.
    let data_sizes = t
        .shell(target, "su -c \"du -sb /data/data/*\"")
        .map(|o| parse_du_sizes(&o.stdout))
        .unwrap_or_default();
    let obb_sizes = t
        .shell(target, "du -sb /sdcard/Android/obb/*")
        .map(|o| parse_du_sizes(&o.stdout))
        .unwrap_or_default();
    (apk_sizes, data_sizes, obb_sizes)
}

// ---------------------------------------------------------------------------
// App details (lazy, per app)
//
// `apps details` is the call the UI makes when the user opens one
// app: all the fields of [`AppInfo`] plus every split APK path and
// the OBB file list. It is deliberately separate from `apps list`
// so the list never pays for per-app calls (235 apps).
// ---------------------------------------------------------------------------

/// Full details for one app, returned by `apps details`.
#[derive(Debug, Clone, Serialize)]
pub struct AppDetails {
    pub package: String,
    pub label: String,
    pub version: String,
    pub system: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_code: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_sdk: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_sdk: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_install_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_update_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installer: Option<String>,
    /// Every APK path on the device (base + splits, from `pm path`).
    pub apk_paths: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apk_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub obb_size_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_size_bytes: Option<u64>,
    /// Set when the data size could not be measured (needs root);
    /// the UI shows this instead of a made-up zero.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_size_note: Option<String>,
    /// OBB file names in /sdcard/Android/obb/<package>/, if any.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub obb_files: Vec<String>,
    /// Requested permissions from dumpsys.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub permissions: Vec<String>,
    /// Local icon file, when one is cached for this package+version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_path: Option<String>,
}

/// All APK paths for one app: every `package:` line of `pm path`.
pub fn parse_pm_paths(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("package:").map(|p| p.trim().to_string()))
        .collect()
}

/// Full details for one installed app: every APK path (base plus splits),
/// sizes, version, SDK levels, install and update dates, installer, and
/// requested permissions. Errors when the package is not installed.
pub fn app_details(t: &dyn AdbTransport, serial: &str, package: &str) -> Result<AppDetails> {
    let target = Target::serial(serial);
    // 1. All APK paths (base + splits).
    let pm = t.shell(&target, &format!("pm path {package}"))?;
    let apk_paths = parse_pm_paths(&pm.stdout);
    if apk_paths.is_empty() {
        return Err(Error(format!(
            "no APK path for {package} (is it installed on the headset?)"
        )));
    }
    // 2. dumpsys for this one app: version code, SDK levels, dates,
    // installer, requested permissions.
    let d = t
        .shell(&target, &format!("dumpsys package {package}"))
        .ok()
        .and_then(|o| parse_dumpsys_packages(&o.stdout).remove(package))
        .unwrap_or_default();
    // 3. APK sizes: one `ls -l` over all the APK paths.
    let ls_cmd = format!(
        "ls -l {}",
        apk_paths
            .iter()
            .map(|p| format!("\"{p}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let apk_sizes = t
        .shell(&target, &ls_cmd)
        .map(|o| parse_ls_apk_sizes(&o.stdout))
        .unwrap_or_default();
    let apk_size_bytes = {
        let sum: u64 = apk_paths.iter().filter_map(|p| apk_sizes.get(p)).sum();
        if apk_paths.iter().any(|p| apk_sizes.contains_key(p)) {
            Some(sum)
        } else {
            None
        }
    };
    // 4. App data size: needs root. Without root the shell user gets
    // "Permission denied"; that is a note, not an error.
    let (data_size_bytes, data_size_note) = match t.shell(
        &target,
        &format!("su -c \"du -sb /data/data/{package}\""),
    ) {
        Ok(o) => {
            let sizes = parse_du_sizes(&o.stdout);
            match sizes.get(&format!("/data/data/{package}")) {
                Some(&s) => (Some(s), None),
                None => (
                    None,
                    Some("App data could not be measured on this headset.".to_string()),
                ),
            }
        }
        Err(_) => (
            None,
            Some("App data size needs root (this headset is rooted, but the root check failed).".to_string()),
        ),
    };
    // 5. OBB: size + file names (readable without root).
    let (obb_size_bytes, obb_files) = match t.shell(
        &target,
        &format!("du -sb /sdcard/Android/obb/{package}"),
    ) {
        Ok(o) => {
            let sizes = parse_du_sizes(&o.stdout);
            let size = sizes.get(&format!("/sdcard/Android/obb/{package}")).copied();
            let files = t
                .shell(&target, &format!("ls /sdcard/Android/obb/{package}"))
                .map(|l| {
                    l.stdout
                        .lines()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            (size, files)
        }
        Err(_) => (None, Vec::new()),
    };
    let total_size_bytes = {
        let sum: u64 = [apk_size_bytes, data_size_bytes, obb_size_bytes]
            .into_iter()
            .flatten()
            .sum();
        if apk_size_bytes.is_none() && data_size_bytes.is_none() && obb_size_bytes.is_none() {
            None
        } else {
            Some(sum)
        }
    };
    // 6. System or third-party, and the cached label/icon.
    let system = match t.shell(&target, &format!("pm list packages -3 {package}")) {
        Ok(o) => !o.stdout.contains(package),
        Err(_) => apk_paths
            .first()
            .map(|p| !p.starts_with("/data/app/"))
            .unwrap_or(false),
    };
    let (label, icon_path) = match cached_icon(package, &d.version) {
        Some((path, cached_label)) => (
            if cached_label.is_empty() {
                package.rsplit('.').next().unwrap_or(package).to_string()
            } else {
                cached_label
            },
            Some(path.to_string_lossy().into_owned()),
        ),
        None => (
            package.rsplit('.').next().unwrap_or(package).to_string(),
            None,
        ),
    };
    Ok(AppDetails {
        package: package.to_string(),
        label,
        version: d.version,
        system,
        version_code: d.version_code,
        min_sdk: d.min_sdk,
        target_sdk: d.target_sdk,
        first_install_time: d.first_install_time,
        last_update_time: d.last_update_time,
        installer: d.installer,
        apk_paths,
        apk_size_bytes,
        data_size_bytes,
        obb_size_bytes,
        total_size_bytes,
        data_size_note,
        obb_files,
        permissions: d.permissions,
        icon_path,
    })
}

// ---------------------------------------------------------------------------
// App icons
//
// Flow for `apps icon --package <pkg>`:
//   pm path -> base.apk path -> dumpsys version -> cache check
//   (package+version) -> pull base.apk to a temp file ->
//   aapt2/aapt `dump badging` for the real label + icon file ->
//   extract that file from the APK zip -> cache it.
//
// Two real-world findings (verified live on the Quest 2, 2026-11-12):
//   * Beat Saber's APK makes every aapt/aapt2 (Debian 2.19 and SDK
//     34/36) fail with "Bad string block" and exit 1, printing no
//     badging at all. Fallback: scan the APK zip for a mipmap icon.
//     That finds res/mipmap-xxxhdpi/app_icon.png (20,701 bytes, PNG).
//   * OpenBrush's icon is NOT under mipmap/ at all: badging says
//     application-icon-640:'res/oj.png' (17,281 bytes, PNG). So the
//     badging icon path is authoritative; the zip scan is only a
//     fallback for when badging itself fails.
//   * Some apps have no icon at all (VrShell: application icon='').
//     That is a clean error ("no launcher icon"), not a crash; the
//     UI falls back to initials.
// ---------------------------------------------------------------------------

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

/// Icon cache root: `$XDG_CACHE_HOME/quest-companion/icons`, else
/// `~/.cache/quest-companion/icons`.
pub fn icon_cache_root() -> Result<std::path::PathBuf> {
    if let Ok(x) = std::env::var("XDG_CACHE_HOME") {
        if !x.is_empty() {
            return Ok(std::path::PathBuf::from(x)
                .join("quest-companion")
                .join("icons"));
        }
    }
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate icon cache".into()))?;
    Ok(std::path::PathBuf::from(home)
        .join(".cache")
        .join("quest-companion")
        .join("icons"))
}

fn icon_cache_dir(package: &str, version: &str) -> Result<std::path::PathBuf> {
    let v = if version.is_empty() { "unknown" } else { version };
    Ok(icon_cache_root()?
        .join(sanitize(package))
        .join(sanitize(v)))
}

/// A cached icon for this package+version, if one exists.
/// Returns (icon file path, label from label.txt).
pub fn cached_icon(package: &str, version: &str) -> Option<(std::path::PathBuf, String)> {
    let dir = icon_cache_dir(package, version).ok()?;
    for name in ["icon.png", "icon.webp", "icon.jpg", "icon.jpeg"] {
        let p = dir.join(name);
        if p.is_file() {
            let label = std::fs::read_to_string(dir.join("label.txt"))
                .unwrap_or_default()
                .trim()
                .to_string();
            return Some((p, label));
        }
    }
    None
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IconEntry {
    pub density: u32,
    pub path: String,
}

#[derive(Debug, Clone, Default)]
pub struct Badging {
    pub package: Option<String>,
    pub label: Option<String>,
    pub version: Option<String>,
    /// `versionCode` from the `package:` line (None when aapt omits it).
    pub version_code: Option<u32>,
    pub sdk_version: Option<u32>,
    pub target_sdk: Option<u32>,
    /// `uses-permission:` names, in manifest order.
    pub permissions: Vec<String>,
    /// `uses-feature:` names, in manifest order.
    pub features: Vec<String>,
    /// `native-code:` ABIs (e.g. `arm64-v8a`), in manifest order.
    pub native_code: Vec<String>,
    pub icons: Vec<IconEntry>,
}

/// Value after a `key=` or `key:` marker: `key:'value'` / `key="value"`.
fn quoted_after(line: &str, marker: &str) -> Option<String> {
    let idx = line.find(marker)?;
    let rest = &line[idx + marker.len()..];
    let rest = rest.trim_start();
    let quote = rest.chars().next()?;
    if quote != '\'' && quote != '"' {
        return None;
    }
    rest[1..].split(quote).next().map(|s| s.to_string())
}

/// Parse `aapt[2] dump badging` output. Handles both forms:
///   application-label:'Open Brush'
///   application: label='Meta Horizon Shell' icon=''
///   application-icon-640:'res/oj.png'
/// A plain `application-label:` line wins over the `application:` line;
/// locale lines (`application-label-af:`) are ignored.
pub fn parse_badging(text: &str) -> Badging {
    let mut out = Badging::default();
    let mut app_line_label: Option<String> = None;
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("package:") {
            if out.version.is_none() {
                out.version = quoted_after(rest, "versionName=");
            }
            if out.package.is_none() {
                out.package = quoted_after(rest, "name=");
            }
            if out.version_code.is_none() {
                out.version_code = quoted_after(rest, "versionCode=")
                    .and_then(|v| v.parse::<u32>().ok());
            }
        } else if let Some(rest) = line.strip_prefix("sdkVersion:") {
            if out.sdk_version.is_none() {
                out.sdk_version = quoted_after(rest, "").and_then(|v| v.parse::<u32>().ok());
            }
        } else if let Some(rest) = line.strip_prefix("targetSdkVersion:") {
            if out.target_sdk.is_none() {
                out.target_sdk = quoted_after(rest, "").and_then(|v| v.parse::<u32>().ok());
            }
        } else if let Some(rest) = line.strip_prefix("uses-permission:") {
            if let Some(p) = quoted_after(rest, "name=") {
                if !out.permissions.contains(&p) {
                    out.permissions.push(p);
                }
            }
        } else if let Some(rest) = line.strip_prefix("uses-feature:") {
            if let Some(f) = quoted_after(rest, "name=") {
                if !out.features.contains(&f) {
                    out.features.push(f);
                }
            }
        } else if let Some(rest) = line.strip_prefix("native-code:") {
            for abi in rest.split_whitespace() {
                let abi = abi.trim_matches(|c| c == '\'' || c == '"');
                if !abi.is_empty() && !out.native_code.contains(&abi.to_string()) {
                    out.native_code.push(abi.to_string());
                }
            }
        } else if let Some(rest) = line.strip_prefix("application-label:") {
            if out.label.is_none() {
                out.label = quoted_after(rest, "");
            }
        } else if let Some(rest) = line.strip_prefix("application:") {
            if app_line_label.is_none() {
                app_line_label = quoted_after(rest, "label=");
            }
            if let Some(icon) = quoted_after(rest, "icon=") {
                if !icon.is_empty() {
                    out.icons.push(IconEntry { density: 0, path: icon });
                }
            }
        } else if let Some(rest) = line.strip_prefix("application-icon-") {
            if let Some((dens, value)) = rest.split_once(':') {
                if let Ok(d) = dens.trim().parse::<u32>() {
                    if let Some(path) = quoted_after(value, "") {
                        if !path.is_empty() {
                            out.icons.push(IconEntry { density: d, path });
                        }
                    }
                }
            }
        }
    }
    if out.label.is_none() {
        out.label = app_line_label;
    }
    out
}

/// Best raster icon from a badging list: highest density, PNG/WebP
/// (or JPEG) only. Adaptive icons are XML and cannot be shown as an
/// image file, so they are skipped, not returned.
pub fn pick_badging_icon(icons: &[IconEntry]) -> Option<String> {
    let mut best: Option<&IconEntry> = None;
    for e in icons {
        let lower = e.path.to_lowercase();
        if !(lower.ends_with(".png") || lower.ends_with(".webp") || lower.ends_with(".jpg") || lower.ends_with(".jpeg")) {
            continue;
        }
        match best {
            None => best = Some(e),
            Some(b) if e.density > b.density => best = Some(e),
            _ => {}
        }
    }
    best.map(|e| e.path.clone())
}

fn density_of_mipmap_folder(name: &str) -> Option<u32> {
    match name {
        "ldpi" => Some(120),
        "mdpi" => Some(160),
        "hdpi" => Some(240),
        "xhdpi" => Some(320),
        "xxhdpi" => Some(480),
        "xxxhdpi" => Some(640),
        _ => None,
    }
}

/// Fallback when badging fails: scan the APK zip for a launcher icon
/// under res/mipmap-<density>/ (e.g. res/mipmap-xxxhdpi/app_icon.png).
/// Prefers a non-round icon, then the highest density, then the
/// largest file. Returns the zip entry name.
pub fn scan_zip_for_icon<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
) -> Option<String> {
    let mut best: Option<(bool, u32, u64, String)> = None; // (non-round, density, size, name)
    for i in 0..zip.len() {
        let entry = zip.by_index(i).ok()?;
        let name = entry.name().to_string();
        let lower = name.to_lowercase();
        if !(lower.ends_with(".png") || lower.ends_with(".webp")) {
            continue;
        }
        // res/mipmap-<density>/<file>
        let parts: Vec<&str> = name.split('/').collect();
        if parts.len() != 3 || parts[0] != "res" || !parts[1].starts_with("mipmap-") {
            continue;
        }
        let density = density_of_mipmap_folder(parts[1].trim_start_matches("mipmap-"))?;
        let file = parts[2].to_lowercase();
        if !file.contains("icon") {
            continue;
        }
        let non_round = !file.contains("round");
        let size = entry.size();
        let cand = (non_round, density, size, name);
        let better = match &best {
            None => true,
            Some(b) => (cand.0, cand.1, cand.2) > (b.0, b.1, b.2),
        };
        if better {
            best = Some(cand);
        }
    }
    best.map(|b| b.3)
}

/// Read one entry out of an APK zip. Returns (bytes, extension
/// detected from the magic bytes, or from the entry name).
pub fn extract_zip_entry(
    apk: &Path,
    entry_name: &str,
) -> Result<(Vec<u8>, &'static str)> {
    let file = File::open(apk)?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|e| Error(format!("{} is not a valid APK zip: {e}", apk.display())))?;
    let mut entry = zip
        .by_name(entry_name)
        .map_err(|_| Error(format!("icon '{entry_name}' not found inside the APK")))?;
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    std::io::copy(&mut entry, &mut bytes)?;
    let ext = detect_image_ext(&bytes, entry_name);
    Ok((bytes, ext))
}

/// Detect an image format from magic bytes; falls back to the file
/// extension (PNG/WebP icons are the norm in APKs).
pub fn detect_image_ext(bytes: &[u8], name: &str) -> &'static str {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "png"
    } else if bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "webp"
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if name.to_lowercase().ends_with(".webp") {
        "webp"
    } else if name.to_lowercase().ends_with(".jpg") || name.to_lowercase().ends_with(".jpeg") {
        "jpg"
    } else {
        "png"
    }
}

/// Candidate aapt2 / aapt binaries: `aapt2` / `aapt` on PATH first,
/// then the Android SDK build-tools dirs (newest first), then the
/// VM's SDK copy. Returns (binary path, badging stdout) for the
/// first candidate that succeeds and prints a `package:` line.
fn run_badging(apk: &Path) -> Result<String> {
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    for name in ["aapt2", "aapt"] {
        candidates.push(std::path::PathBuf::from(name));
    }
    let mut sdk_roots: Vec<std::path::PathBuf> = Vec::new();
    for var in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                sdk_roots.push(std::path::PathBuf::from(v));
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        sdk_roots.push(std::path::PathBuf::from(&home).join("Android").join("Sdk"));
        sdk_roots.push(
            std::path::PathBuf::from(&home)
                .join("workspace")
                .join("android-sdk"),
        );
    }
    for root in sdk_roots {
        let bt = root.join("build-tools");
        if let Ok(rd) = std::fs::read_dir(&bt) {
            let mut versions: Vec<_> = rd.flatten().map(|e| e.path()).collect();
            versions.sort_by(|a, b| b.cmp(a)); // newest first, e.g. 36 > 34
            for v in versions {
                candidates.push(v.join("aapt2"));
                candidates.push(v.join("aapt"));
            }
        }
    }
    let mut last_err = String::from("no aapt/aapt2 found");
    for cand in candidates {
        let out = std::process::Command::new(&cand)
            .args(["dump", "badging"])
            .arg(apk)
            .output();
        let out = match out {
            Ok(o) => o,
            Err(_) => continue, // binary missing / not executable
        };
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        if out.status.success() && text.contains("package:") {
            return Ok(text);
        }
        if !text.is_empty() || !out.stderr.is_empty() {
            last_err = format!(
                "{}: exit {} (badging printed no package line)",
                cand.display(),
                out.status.code().unwrap_or(-1)
            );
        }
    }
    Err(Error(format!(
        "could not read the APK with aapt/aapt2 ({last_err}); the APK may use a resource format aapt cannot parse"
    )))
}

/// Read aapt badging for a local APK file (label, version, package,
/// icon paths). Used by the library import; the icon flow in
/// [`app_icon`] uses the same parser on a pulled APK.
pub fn badging_of(apk: &Path) -> Result<Badging> {
    Ok(parse_badging(&run_badging(apk)?))
}

fn best_effort_label(package: &str) -> String {
    package.rsplit('.').next().unwrap_or(package).to_string()
}

/// Get the real label and icon from a local APK file already on
/// this computer (a backup folder's base.apk, or an imported APK).
/// No headset, no ADB pull: the file is read in place. Shares the
/// cache with [`app_icon`] (package+version under
/// ~/.cache/quest-companion/icons/), the same badging parse, and
/// the same zip-scan fallback for APKs aapt cannot parse
/// (Beat Saber). Returns an error when the APK has no launcher
/// icon at all; the caller falls back to initials, it does not
/// invent an icon.
pub fn local_apk_icon(apk: &Path, package: &str, version: &str) -> Result<AppIcon> {
    if let Some((cached, label)) = cached_icon(package, version) {
        return Ok(AppIcon {
            package: package.to_string(),
            label: if label.is_empty() { best_effort_label(package) } else { label },
            version: version.to_string(),
            icon_path: cached.to_string_lossy().into_owned(),
            icon_file: cached
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "icon.png".into()),
        });
    }
    let mut label = best_effort_label(package);
    let icon_entry: Option<String> = match run_badging(apk) {
        Ok(text) => {
            let badging = parse_badging(&text);
            if let Some(l) = badging.label.filter(|l| !l.is_empty()) {
                label = l;
            }
            match pick_badging_icon(&badging.icons) {
                Some(p) => Some(p),
                None => {
                    let file = File::open(apk)?;
                    let mut zip = zip::ZipArchive::new(file)
                        .map_err(|e| Error(format!("APK is not a valid zip: {e}")))?;
                    scan_zip_for_icon(&mut zip)
                }
            }
        }
        Err(_) => {
            let file = File::open(apk)?;
            let mut zip = zip::ZipArchive::new(file)
                .map_err(|e| Error(format!("APK is not a valid zip: {e}")))?;
            scan_zip_for_icon(&mut zip)
        }
    };
    let icon_entry = icon_entry.ok_or_else(|| {
        Error(format!(
            "{package} ({label}) has no launcher icon in its APK"
        ))
    })?;
    let (bytes, ext) = extract_zip_entry(apk, &icon_entry)?;
    if bytes.is_empty() {
        return Err(Error(format!("icon '{icon_entry}' in {package} is empty")));
    }
    let cache_dir = icon_cache_dir(package, version)?;
    std::fs::create_dir_all(&cache_dir)?;
    let icon_name = format!("icon.{ext}");
    let cached_path = cache_dir.join(&icon_name);
    std::fs::write(&cached_path, &bytes)?;
    std::fs::write(cache_dir.join("label.txt"), &label)?;
    Ok(AppIcon {
        package: package.to_string(),
        label,
        version: version.to_string(),
        icon_path: cached_path.to_string_lossy().into_owned(),
        icon_file: icon_entry,
    })
}

/// Get the real label and icon for one app. Pulls base.apk to a temp
/// file (deleted afterwards) and caches the icon under
/// ~/.cache/quest-companion/icons/<package>/<version>/.
///
/// `out`: when given, the icon is also copied there and `icon_path`
/// in the result is that path instead of the cache path.
pub fn app_icon(
    t: &dyn AdbTransport,
    serial: &str,
    package: &str,
    out: Option<&Path>,
) -> Result<AppIcon> {
    let target = Target::serial(serial);
    // 1. APK path: first base.apk line of `pm path <pkg>`, else first.
    let pm = t.shell(&target, &format!("pm path {package}"))?;
    let mut apk_path: Option<String> = None;
    for line in pm.stdout.lines() {
        if let Some(p) = line.trim().strip_prefix("package:") {
            let p = p.trim().to_string();
            if apk_path.is_none() {
                apk_path = Some(p.clone());
            }
            if p.ends_with("base.apk") {
                apk_path = Some(p);
                break;
            }
        }
    }
    let apk_path = apk_path.ok_or_else(|| {
        Error(format!(
            "no APK path for {package} (is it installed on the headset?)"
        ))
    })?;
    // 2. Version, for the cache key.
    let version = t
        .shell(&target, &format!("dumpsys package {package}"))
        .ok()
        .and_then(|o| parse_dumpsys_versions(&o.stdout).remove(package))
        .unwrap_or_default();
    // 3. Cache hit: no pull, no aapt.
    if let Some((cached, label)) = cached_icon(package, &version) {
        let icon_path = if let Some(o) = out {
            if let Some(parent) = o.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)?;
                }
            }
            std::fs::copy(&cached, o)?;
            o.to_path_buf()
        } else {
            cached.clone()
        };
        return Ok(AppIcon {
            package: package.to_string(),
            label: if label.is_empty() { best_effort_label(package) } else { label },
            version,
            icon_path: icon_path.to_string_lossy().into_owned(),
            icon_file: cached
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "icon.png".into()),
        });
    }
    // 4. Pull base.apk to a temp file, then reuse the local-APK
    // icon flow (cache, badging, zip-scan fallback).
    let dir = tempfile::tempdir().map_err(|e| Error(format!("cannot create temp dir: {e}")))?;
    let apk_local = dir.path().join("base.apk");
    t.pull(&target, &apk_path, &apk_local)
        .map_err(|e| Error(format!("could not pull the APK for {package}: {e}")))?;
    let icon = local_apk_icon(&apk_local, package, &version)?;
    let icon_path = if let Some(o) = out {
        if let Some(parent) = o.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        std::fs::copy(&icon.icon_path, o)?;
        o.to_path_buf()
    } else {
        PathBuf::from(&icon.icon_path)
    };
    Ok(AppIcon {
        package: package.to_string(),
        label: icon.label,
        version,
        icon_path: icon_path.to_string_lossy().into_owned(),
        icon_file: icon.icon_file,
    })
}

/// Split a bundle file (.apks / .xapk = a zip of APKs) into a temp dir
/// and return the APK paths, base.apk first.
pub fn unpack_bundle(path: &Path) -> Result<(tempfile::TempDir, Vec<PathBuf>)> {
    let dir = tempfile::tempdir().map_err(|e| Error(format!("cannot create temp dir: {e}")))?;
    let file = File::open(path)?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|e| Error(format!("{} is not a valid .apks/.xapk zip: {e}", path.display())))?;
    let mut apks = Vec::new();
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| Error(e.to_string()))?;
        let name = entry.name().to_string();
        if name.to_lowercase().ends_with(".apk") {
            // Skip nested dirs; keep the file name only.
            let leaf = Path::new(&name)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or(name.clone());
            let out_path = dir.path().join(&leaf);
            let mut out = File::create(&out_path)?;
            std::io::copy(&mut entry, &mut out)?;
            apks.push(out_path);
        }
    }
    if apks.is_empty() {
        return Err(Error(format!(
            "no APKs found inside {}",
            path.display()
        )));
    }
    // base.apk first, then the rest in name order.
    apks.sort_by_key(|p| {
        let n = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
        (!n.eq_ignore_ascii_case("base.apk"), n)
    });
    Ok((dir, apks))
}

// ---------------------------------------------------------------------------
// Install and uninstall
// ---------------------------------------------------------------------------

/// Install one APK file. A .apks or .xapk bundle is unpacked first and
/// its APKs installed together. `reinstall` true keeps the app's data
/// when it is already installed. Returns the adb install output.
pub fn install_apk(
    t: &dyn AdbTransport,
    serial: &str,
    apk: &Path,
    reinstall: bool,
) -> Result<String> {
    if !apk.exists() {
        return Err(Error(format!("APK not found: {}", apk.display())));
    }
    let ext = apk
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if ext == "apks" || ext == "xapk" {
        let (_dir, apks) = unpack_bundle(apk)?;
        return t.install(&Target::serial(serial), &apks, reinstall);
    }
    t.install(&Target::serial(serial), &[apk.to_path_buf()], reinstall)
}

/// Install several APKs at once (the splits of one app), in a single adb
/// install call. Every file must exist first; a missing file fails the
/// whole call before anything is installed.
pub fn install_multiple(
    t: &dyn AdbTransport,
    serial: &str,
    apks: &[PathBuf],
    reinstall: bool,
) -> Result<String> {
    for a in apks {
        if !a.exists() {
            return Err(Error(format!("APK not found: {}", a.display())));
        }
    }
    t.install(&Target::serial(serial), apks, reinstall)
}

/// Uninstall a system app. Needs root: runs `su -c pm uninstall`
/// (a full removal, not the `--user 0` disable the plain uninstall
/// does for user apps). Without root this fails with a plain message
/// saying so; the UI only offers it in Rooted mode.
pub fn uninstall_system(t: &dyn AdbTransport, serial: &str, package: &str) -> Result<String> {
    let target = Target::serial(serial);
    let root = t.shell(&target, "su -c id")?;
    if !root.stdout.contains("uid=0") {
        return Err(Error(format!(
            "removing the system app {package} needs root, and this headset did not grant su"
        )));
    }
    let out = t.shell(&target, &format!("su -c \"pm uninstall {package}\""))?;
    let text = format!("{}{}", out.stdout, out.stderr);
    if text.contains("Success") {
        return Ok(format!("removed system app {package}"));
    }
    Err(Error(format!(
        "removing system app {package} failed: {}",
        text.trim()
    )))
}

/// Uninstall one app with `pm uninstall`. `keep_data` true passes `-k`,
/// so the app's data stays on the headset and comes back if the app is
/// reinstalled. User apps only; system apps need `uninstall_system`,
/// which needs root.
pub fn uninstall(
    t: &dyn AdbTransport,
    serial: &str,
    package: &str,
    keep_data: bool,
) -> Result<String> {
    let target = Target::serial(serial);
    let out = t.shell(&target, &format!("pm uninstall{} {}", if keep_data { " -k" } else { "" }, package))?;
    let text = format!("{}{}", out.stdout, out.stderr);
    if text.contains("Success") {
        return Ok(text.trim().to_string());
    }
    Err(Error(format!(
        "uninstall of {package} failed: {}",
        text.trim()
    )))
}

/// Resolve the launcher activity, fall back to `monkey` if none is exported.
pub fn launch(t: &dyn AdbTransport, serial: &str, package: &str) -> Result<String> {
    let target = Target::serial(serial);
    let resolve = t.shell(
        &target,
        &format!(
            "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER {package}"
        ),
    )?;
    let mut activity: Option<String> = None;
    for line in resolve.stdout.lines() {
        let line = line.trim();
        // resolve-activity --brief prints the component on its own line.
        if line.contains('/') && line.starts_with(package) {
            activity = Some(line.to_string());
            break;
        }
    }
    if let Some(comp) = activity {
        let out = t.shell(&target, &format!("am start -n {comp}"))?;
        let text = format!("{}{}", out.stdout, out.stderr);
        if text.contains("Error") && !text.contains("Starting:") {
            return Err(Error(format!("launch failed: {}", text.trim())));
        }
        return Ok(format!("launched {comp}"));
    }
    let out = t.shell(
        &target,
        &format!("monkey -p {package} -c android.intent.category.LAUNCHER 1"),
    )?;
    let text = format!("{}{}", out.stdout, out.stderr);
    if text.contains("Events injected: 1") || text.contains("Monkey finished") {
        Ok(format!("launched {package} via monkey"))
    } else {
        Err(Error(format!("launch failed: {}", text.trim())))
    }
}

/// Stop one app right now with `am force-stop`. The app is not
/// uninstalled and its data is kept; it just stops running until it is
/// opened again.
pub fn force_stop(t: &dyn AdbTransport, serial: &str, package: &str) -> Result<String> {
    let out = t.shell(&Target::serial(serial), &format!("am force-stop {package}"))?;
    if out.code != 0 {
        return Err(Error(format!("force-stop failed: {}", out.stderr.trim())));
    }
    Ok(format!("force-stopped {package}"))
}

/// Wipe one app's data with `pm clear` (saved games, settings, logins).
/// The app itself stays installed. This cannot be undone, so the UI
/// asks first.
pub fn clear_data(t: &dyn AdbTransport, serial: &str, package: &str) -> Result<String> {
    let out = t.shell(&Target::serial(serial), &format!("pm clear {package}"))?;
    let text = format!("{}{}", out.stdout, out.stderr);
    if text.contains("Success") {
        Ok(format!("cleared data for {package}"))
    } else {
        Err(Error(format!("clear-data failed: {}", text.trim())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real `dumpsys package <pkg>` output captured live from the owner's
    // Quest 2 (2026-11-12). Fixtures live in tests/fixtures/ so the
    // parser is tested against the real format, not a guess.
    const OPENBRUSH: &str = include_str!("../tests/fixtures/dumpsys-openbrush.txt");
    const BEATSABER: &str = include_str!("../tests/fixtures/dumpsys-beatsaber.txt");
    const BONELAB: &str = include_str!("../tests/fixtures/dumpsys-bonelab.txt");

    #[test]
    fn dumpsys_openbrush_fields() {
        let m = parse_dumpsys_packages(OPENBRUSH);
        let d = m.get("com.Icosa.OpenBrush").expect("openbrush entry");
        assert_eq!(d.version, "2.31.0");
        assert_eq!(d.version_code, Some(20310001));
        assert_eq!(d.min_sdk, Some(29));
        assert_eq!(d.target_sdk, Some(34));
        assert_eq!(d.first_install_time.as_deref(), Some("2025-03-03 01:38:59"));
        assert_eq!(d.last_update_time.as_deref(), Some("2026-08-30 07:42:41"));
        assert_eq!(d.installer.as_deref(), Some("com.oculus.ocms"));
        assert_eq!(d.permissions.len(), 13);
        assert!(d.permissions.contains(&"android.permission.RECORD_AUDIO".to_string()));
        assert!(d.permissions.contains(&"android.permission.INTERNET".to_string()));
    }

    #[test]
    fn dumpsys_beatsaber_sideloaded_and_permissions() {
        let m = parse_dumpsys_packages(BEATSABER);
        let d = m.get("com.beatgames.beatsaber").expect("beatsaber entry");
        assert_eq!(d.version, "1.45.3_30054");
        assert_eq!(d.version_code, Some(3237));
        assert_eq!(d.min_sdk, Some(32));
        assert_eq!(d.target_sdk, Some(32));
        assert_eq!(d.first_install_time.as_deref(), Some("2026-11-09 16:45:20"));
        // No installerPackageName + initiatingPackageName=com.android.shell
        // means sideloaded via adb: shown honestly, not guessed.
        assert_eq!(d.installer.as_deref(), Some("sideloaded (adb)"));
        assert_eq!(d.permissions.len(), 10);
        assert!(d.permissions.contains(&"android.permission.MANAGE_EXTERNAL_STORAGE".to_string()));
    }

    #[test]
    fn dumpsys_bonelab_fields() {
        let m = parse_dumpsys_packages(BONELAB);
        let d = m.get("com.StressLevelZero.BONELAB").expect("bonelab entry");
        assert_eq!(d.version, "1.2974.57485");
        assert_eq!(d.version_code, Some(2974));
        assert_eq!(d.min_sdk, Some(32));
        assert_eq!(d.target_sdk, Some(32));
        assert_eq!(d.first_install_time.as_deref(), Some("2026-11-10 17:48:33"));
        assert_eq!(d.installer.as_deref(), Some("sideloaded (adb)"));
        assert_eq!(d.permissions.len(), 9);
    }

    #[test]
    fn dumpsys_versions_still_works() {
        let m = parse_dumpsys_versions(OPENBRUSH);
        assert_eq!(m.get("com.Icosa.OpenBrush").map(|s| s.as_str()), Some("2.31.0"));
    }

    #[test]
    fn ls_apk_sizes_parse() {
        let text = "-rw-r--r-- 1 system system 247256857 2026-08-30 07:42 /data/app/~~7NHhy1Qev2eyS3rOxN9pfA==/com.Icosa.OpenBrush-B4gdM77_xXMzNZglckVWVA==/base.apk\n\
                    -rw-r--r-- 1 system system 90898439 2026-11-09 16:45 /data/app/~~KHOPEuhOIW1VlotuZxPM4g==/com.beatgames.beatsaber-_JnaboO-WnsmtKZHSkYPQw==/base.apk\n\
                    total 123\n";
        let m = parse_ls_apk_sizes(text);
        assert_eq!(m.len(), 2);
        assert_eq!(
            m.get("/data/app/~~7NHhy1Qev2eyS3rOxN9pfA==/com.Icosa.OpenBrush-B4gdM77_xXMzNZglckVWVA==/base.apk"),
            Some(&247256857)
        );
        assert_eq!(
            m.get("/data/app/~~KHOPEuhOIW1VlotuZxPM4g==/com.beatgames.beatsaber-_JnaboO-WnsmtKZHSkYPQw==/base.apk"),
            Some(&90898439)
        );
    }

    #[test]
    fn du_sizes_parse() {
        let text = "59144\t/data/data/com.Icosa.OpenBrush\n98445806\t/data/data/com.beatgames.beatsaber\n5505138130\t/sdcard/Android/obb/com.beatgames.beatsaber\n";
        let m = parse_du_sizes(text);
        assert_eq!(m.get("/data/data/com.Icosa.OpenBrush"), Some(&59144));
        assert_eq!(m.get("/sdcard/Android/obb/com.beatgames.beatsaber"), Some(&5505138130));
        assert_eq!(m.len(), 3);
    }

    #[test]
    fn pm_paths_parse() {
        let text = "package:/data/app/~~x/com.foo-abc/base.apk\npackage:/data/app/~~x/com.foo-abc/split_config.arm64_v8a.apk\n";
        assert_eq!(
            parse_pm_paths(text),
            vec![
                "/data/app/~~x/com.foo-abc/base.apk".to_string(),
                "/data/app/~~x/com.foo-abc/split_config.arm64_v8a.apk".to_string(),
            ]
        );
        assert!(parse_pm_paths("").is_empty());
    }
}
