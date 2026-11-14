//! Home apps: Lightning Launcher and Quest Home Switcher v2.
//!
//! The two apps the user is told to use instead of a custom home:
//! Lightning Launcher replaces the apps menu (every app, store and
//! sideloaded, in one grid), Quest Home Switcher manages custom 3D
//! home environments. This module scans the headset to tell whether
//! each is installed and whether an update is available, downloads
//! the APK from the author's GitHub release, and installs, opens or
//! uninstalls it. Nothing is bundled; the APKs are downloaded at
//! runtime from the authors' own releases.
//!
//! Lightning Launcher is also on the Meta Quest Store (free), so
//! installing it from the Store is just as good. Quest Home
//! Switcher is NOT open source; only its published release APK is
//! used, never its code.

use crate::apps;
use crate::error::{Error, Result};
use crate::singularity::{curl, pick_release_assets, sha256_file};
use crate::singularity_settings::installed_version;
use crate::transport::AdbTransport;
use serde::Serialize;
use std::path::PathBuf;

/// One home app. `id` is the short name the CLI and UI use.
#[derive(Debug, Clone, Copy)]
pub struct HomeApp {
    pub id: &'static str,
    pub name: &'static str,
    pub package: &'static str,
    pub repo: &'static str,
    pub detail: &'static str,
    pub source: &'static str,
}

pub const HOME_APPS: &[HomeApp] = &[
    HomeApp {
        id: "lightning",
        name: "Lightning Launcher",
        package: "com.threethan.launcher",
        repo: "threethan/LightningLauncher",
        detail: "Replaces the apps menu: every app, store and sideloaded, in one grid. No root, no Unknown Sources split.",
        source: "GitHub releases (threethan/LightningLauncher)",
    },
    HomeApp {
        id: "qhs",
        name: "Quest Home Switcher",
        package: "app.questhomeswitcher",
        repo: "nikitat21/Quest-Home-Switcher",
        detail: "Manages custom 3D home environments (official + ~250 community homes). The homes catalogue lives inside the app.",
        source: "GitHub releases (nikitat21/Quest-Home-Switcher)",
    },
];

/// Look up one of the two home apps by id (`lightning` or `qhs`).
/// Errors on any other id, with the valid ids named in the message.
pub fn find_app(id: &str) -> Result<&'static HomeApp> {
    HOME_APPS
        .iter()
        .find(|a| a.id == id)
        .ok_or_else(|| Error(format!("unknown home app: {id} (lightning or qhs)")))
}

/// Cache folder for downloaded home-app APKs:
/// `~/.cache/quest-companion/home-apps/`.
pub fn home_apps_cache_dir() -> Result<PathBuf> {
    let base = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate cache dir".into()))?;
    let dir = PathBuf::from(base)
        .join(".cache")
        .join("quest-companion")
        .join("home-apps");
    std::fs::create_dir_all(&dir).map_err(|e| Error(e.to_string()))?;
    Ok(dir)
}

fn cached_file(app: &HomeApp) -> Result<PathBuf> {
    Ok(home_apps_cache_dir()?.join(format!("{}.apk", app.id)))
}

/// A release tag with a leading `v` removed, so `v2.3.0` compares
/// equal to the installed version name `2.3.0`.
pub fn normalize_version(tag: &str) -> &str {
    tag.strip_prefix('v').unwrap_or(tag)
}

#[derive(Debug, Clone, Serialize)]
pub struct HomeAppStatus {
    pub id: String,
    pub name: String,
    pub package: String,
    pub detail: String,
    pub source: String,
    pub installed: bool,
    pub installed_version: Option<String>,
    pub latest_version: Option<String>,
    pub update_available: bool,
    pub downloaded: bool,
    pub file: Option<String>,
    pub size_bytes: u64,
    pub sha256: Option<String>,
}

fn latest_release(app: &HomeApp) -> Result<(String, String, Option<String>)> {
    let url = format!("https://api.github.com/repos/{}/releases/latest", app.repo);
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "-A", "ReOculus", &url])
        .output()
        .map_err(|e| Error(format!("cannot run curl (is it installed?): {e}")))?;
    if !out.status.success() {
        return Err(Error(format!(
            "could not read the latest {} release from GitHub: {}",
            app.name,
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let (version, name_url, checksum) = pick_release_assets(&text)?;
    let (_name, apk_url) = name_url
        .split_once('|')
        .ok_or_else(|| Error("the release asset came back in a form we cannot read".into()))?;
    Ok((version, apk_url.to_string(), checksum))
}

fn file_sha256(path: &PathBuf) -> Option<String> {
    sha256_file(path).ok()
}

fn file_size(path: &PathBuf) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Scan the headset for both apps. The GitHub lookup is fail-soft
/// per app: when the network is down the installed state still
/// comes back, with no latest version and no update flag.
pub fn list(t: &dyn AdbTransport, serial: &str) -> Result<Vec<HomeAppStatus>> {
    // Quest Home Switcher only lists Quest 2 / 3 / 3S, so it is hidden
    // on Quest 1. Lightning Launcher works on Quest 1 (sideloaded).
    let quest1 = crate::devices::headset_of(t, serial).is_quest1();
    let mut out = Vec::new();
    for app in HOME_APPS {
        if quest1 && app.id == "qhs" {
            continue;
        }
        let installed_ver = installed_version(t, serial, app.package);
        let installed = installed_ver.is_some();
        let file = cached_file(app)?;
        let downloaded = file.exists();
        let (latest, update) = match latest_release(app) {
            Ok((tag, _url, _sum)) => {
                let latest = normalize_version(&tag).to_string();
                let update = installed_ver
                    .as_deref()
                    .map(|v| v != latest)
                    .unwrap_or(false);
                (Some(latest), update)
            }
            Err(_) => (None, false),
        };
        out.push(HomeAppStatus {
            id: app.id.to_string(),
            name: app.name.to_string(),
            package: app.package.to_string(),
            detail: app.detail.to_string(),
            source: app.source.to_string(),
            installed,
            installed_version: installed_ver,
            latest_version: latest,
            update_available: update,
            downloaded,
            file: if downloaded {
                Some(file.to_string_lossy().into_owned())
            } else {
                None
            },
            size_bytes: if downloaded { file_size(&file) } else { 0 },
            sha256: if downloaded {
                file_sha256(&file)
            } else {
                None
            },
        });
    }
    Ok(out)
}

#[derive(Debug, Clone, Serialize)]
pub struct HomeAppDownload {
    pub id: String,
    pub file: String,
    pub size_bytes: u64,
    pub sha256: String,
    pub version: String,
    pub verified: String,
}

/// Download the latest release APK for one app. The file is
/// verified: QHS publishes a SHA256SUMS.txt for the release, so its
/// checksum is checked against that file; Lightning Launcher
/// publishes no checksum, so its APK is checked with aapt badging
/// (package and version must match the release).
pub fn download(id: &str) -> Result<HomeAppDownload> {
    let app = find_app(id)?;
    let (tag, apk_url, checksum_url) = latest_release(app)?;
    let version = normalize_version(&tag).to_string();
    let file = cached_file(app)?;
    curl(&apk_url, &file)?;
    let size = file_size(&file);
    if size < 1_000_000 {
        return Err(Error(format!(
            "the downloaded {} APK is only {size} bytes; the download looks broken",
            app.name
        )));
    }
    let sha = sha256_file(&file)?;
    let verified = if let Some(sum_url) = checksum_url {
        let sums = std::process::Command::new("curl")
            .args(["-fsSL", "-A", "ReOculus", &sum_url])
            .output()
            .map_err(|e| Error(format!("cannot fetch the checksum file: {e}")))?;
        if !sums.status.success() {
            return Err(Error("could not read the release checksum file".into()));
        }
        let text = String::from_utf8_lossy(&sums.stdout).into_owned();
        let wanted = text
            .lines()
            .find(|l| l.contains(".apk"))
            .and_then(|l| l.split_whitespace().next())
            .unwrap_or("");
        if wanted.is_empty() || wanted != sha {
            return Err(Error(format!(
                "the downloaded {} APK does not match the checksum the author published; refusing to use it",
                app.name
            )));
        }
        "checksum (SHA256SUMS.txt)".to_string()
    } else {
        let badging = apps::badging_of(&file)?;
        if badging.package.as_deref() != Some(app.package) {
            return Err(Error(format!(
                "the downloaded APK is for {} ({}), not {}; refusing to use it",
                badging.label.as_deref().unwrap_or("unknown"),
                badging.package.as_deref().unwrap_or("unknown"),
                app.package
            )));
        }
        if badging.version.as_deref() != Some(version.as_str()) {
            return Err(Error(format!(
                "the downloaded APK reports version {}, but the release says {version}; refusing to use it",
                badging.version.as_deref().unwrap_or("unknown")
            )));
        }
        "aapt badging (package + version)".to_string()
    };
    Ok(HomeAppDownload {
        id: app.id.to_string(),
        file: file.to_string_lossy().into_owned(),
        size_bytes: size,
        sha256: sha,
        version,
        verified,
    })
}

/// Install one app on the headset, downloading it first when the
/// cache is empty. The transport already passes `-g` (grant all
/// runtime permissions), which is what Quest Home Switcher's own
/// install instructions ask for.
pub fn install(t: &dyn AdbTransport, serial: &str, id: &str) -> Result<String> {
    let app = find_app(id)?;
    if id == "qhs" && crate::devices::headset_of(t, serial).is_quest1() {
        return Err(Error(
            "Quest Home Switcher does not support Quest 1 (Quest 2 / 3 / 3S only).".into(),
        ));
    }
    let file = cached_file(app)?;
    if !file.exists() {
        download(id)?;
    }
    apps::install_apk(t, serial, &file, true)?;
    Ok(format!("installed {} {}", app.name, app.package))
}

/// Uninstall one home app (Lightning Launcher or Quest Home Switcher)
/// from the headset by its id. The stock Meta home is never touched.
pub fn uninstall(t: &dyn AdbTransport, serial: &str, id: &str) -> Result<String> {
    let app = find_app(id)?;
    apps::uninstall(t, serial, app.package, false)?;
    Ok(format!("uninstalled {} {}", app.name, app.package))
}

/// Open one app on the headset (its launcher activity, monkey
/// fallback). This shows the app now; it does not change the
/// default home, which this firmware will not let any app change.
pub fn open(t: &dyn AdbTransport, serial: &str, id: &str) -> Result<String> {
    let app = find_app(id)?;
    apps::launch(t, serial, app.package)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_version_strips_v() {
        assert_eq!(normalize_version("v2.3.0"), "2.3.0");
        assert_eq!(normalize_version("10.0.1"), "10.0.1");
    }

    #[test]
    fn find_app_known_and_unknown() {
        assert_eq!(find_app("lightning").unwrap().package, "com.threethan.launcher");
        assert_eq!(find_app("qhs").unwrap().package, "app.questhomeswitcher");
        assert!(find_app("nope").is_err());
    }

    #[test]
    fn table_has_two_apps() {
        assert_eq!(HOME_APPS.len(), 2);
        assert!(HOME_APPS.iter().all(|a| !a.repo.is_empty()));
    }
}
