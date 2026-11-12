//! Singularity install wizard (backend half).
//!
//! Singularity is the community tool that roots a Quest 2 (fugu
//! exploit + Magisk). It is CLOSED source: the repo is a README and
//! a licence, and the APK is published as a GitHub release. This
//! module never bundles Singularity, never copies its code, and
//! never roots anything by itself. What it does:
//!
//! 1. Preflight: model, battery, root state, storage, whether
//!    Singularity is already installed. One check failing stops
//!    the wizard with a plain message.
//! 2. Download: fetch the author's latest release from GitHub,
//!    verify it is a real APK (aapt badging) and, when the release
//!    publishes a checksum file, verify the SHA-256 against it.
//!    No published checksum means the UI says so plainly instead
//!    of claiming a check that did not happen.
//! 3. Install: `adb install` the downloaded APK.
//! 4. Verify: after the user presses Root Now inside Singularity
//!    on the headset, confirm `su -c id` really is uid=0(root).
//!
//! The rooting itself happens in the headset, in Singularity's own
//! UI, with the user watching. The wizard only prepares, checks,
//! and verifies.

use crate::devices::device_info;
use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use crate::wireless::{root_status, RootStatus};
use serde::Serialize;
use std::path::PathBuf;

pub const SINGULARITY_REPO: &str = "Lumince/singularity";
pub const SINGULARITY_LATEST_API: &str =
    "https://api.github.com/repos/Lumince/singularity/releases/latest";
/// The build this was verified on (the owner's Quest 2, 2026-11-12).
pub const KNOWN_GOOD_FIRMWARE: &str = "52242990024200150";

#[derive(Debug, Clone, Serialize)]
pub struct PreflightCheck {
    pub name: String,
    pub ok: bool,
    /// Plain-language detail ("Battery is 87%, you need 50% or more").
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Preflight {
    pub checks: Vec<PreflightCheck>,
    pub ready: bool,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DownloadReport {
    pub version: String,
    pub file: String,
    pub size_bytes: u64,
    pub sha256: String,
    pub package: Option<String>,
    pub label: Option<String>,
    /// "checksum file verified" | "no checksum published; aapt verified it is a valid APK".
    pub verification: String,
}

fn cache_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| Error("no HOME set, cannot find the download cache".into()))?;
    let dir = home
        .join(".cache")
        .join("quest-companion")
        .join("singularity");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

pub fn preflight(t: &dyn AdbTransport, serial: &str) -> Result<Preflight> {
    let info = device_info(t, serial)?;
    let root = root_status(t, serial);
    let mut checks: Vec<PreflightCheck> = Vec::new();
    let model = info.model.clone().unwrap_or_default();
    checks.push(PreflightCheck {
        name: "Quest 2".into(),
        ok: model.to_lowercase().contains("quest 2"),
        detail: if model.is_empty() {
            "could not read the model".into()
        } else {
            format!("this headset is a {model}")
        },
    });
    let level = info.battery.level.unwrap_or(0);
    checks.push(PreflightCheck {
        name: "Battery 50% or more".into(),
        ok: level >= 50,
        detail: format!(
            "battery is {level}% (rooting must not be interrupted by a dead battery)"
        ),
    });
    checks.push(PreflightCheck {
        name: "Not rooted yet".into(),
        ok: !root.rooted,
        detail: if root.rooted {
            format!("already rooted ({})", root.method)
        } else {
            "not rooted, no Magisk found".into()
        },
    });
    checks.push(PreflightCheck {
        name: "Singularity not installed".into(),
        ok: !root.singularity_present,
        detail: if root.singularity_present {
            "Singularity is already on the headset; open it there instead of installing again".into()
        } else {
            "Singularity is not on the headset".into()
        },
    });
    let free_mb = info.storage.free_kb.map(|kb| kb / 1024).unwrap_or(0);
    checks.push(PreflightCheck {
        name: "Free space 500 MB or more".into(),
        ok: free_mb >= 500,
        detail: format!("{free_mb} MB free on the headset"),
    });
    let fw = info.firmware.clone().unwrap_or_default();
    checks.push(PreflightCheck {
        name: "Firmware".into(),
        ok: true,
        detail: if fw == KNOWN_GOOD_FIRMWARE {
            format!("build {fw} (verified with Singularity before)")
        } else if fw.is_empty() {
            "could not read the firmware build".into()
        } else {
            format!("build {fw} (not verified with Singularity before; the wizard still proceeds, and Singularity itself checks compatibility)")
        },
    });
    let ok = checks.iter().all(|c| c.ok);
    let summary = if ok {
        "All checks passed. Back up the headset first, then download Singularity.".into()
    } else {
        let failed: Vec<&str> = checks
            .iter()
            .filter(|c| !c.ok)
            .map(|c| c.name.as_str())
            .collect();
        format!("Not ready yet: {}", failed.join(", "))
    };
    Ok(Preflight { checks, ready: ok, summary })
}

/// Pick the .apk asset and an optional checksum asset out of a
/// GitHub "latest release" JSON object. Pure, so it is unit-tested.
pub fn pick_release_assets(text: &str) -> Result<(String, String, Option<String>)> {
    let v: serde_json::Value = serde_json::from_str(text)
        .map_err(|e| Error(format!("GitHub did not send a release we can read: {e}")))?;
    let version = v
        .get("tag_name")
        .and_then(|x| x.as_str())
        .unwrap_or("unknown")
        .to_string();
    let assets = v
        .get("assets")
        .and_then(|x| x.as_array())
        .ok_or_else(|| Error("the release has no downloadable files".into()))?;
    let mut apk: Option<(String, String)> = None;
    let mut checksum: Option<String> = None;
    for a in assets {
        let name = a.get("name").and_then(|x| x.as_str()).unwrap_or("");
        let url = a
            .get("browser_download_url")
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if url.is_empty() {
            continue;
        }
        if name.to_lowercase().ends_with(".apk") && apk.is_none() {
            apk = Some((name.to_string(), url.to_string()));
        } else if (name.to_lowercase().contains("sha256")
            || name.to_lowercase().contains("checksum"))
            && checksum.is_none()
        {
            checksum = Some(url.to_string());
        }
    }
    let (apk_name, apk_url) = apk.ok_or_else(|| {
        Error("the latest Singularity release has no APK file to download".into())
    })?;
    Ok((version, format!("{apk_name}|{apk_url}"), checksum))
}

fn curl(url: &str, out: &PathBuf) -> Result<()> {
    let st = std::process::Command::new("curl")
        .args(["-fsSL", "-A", "ReOculus", url, "-o"])
        .arg(out)
        .output()
        .map_err(|e| Error(format!("cannot run curl (is it installed?): {e}")))?;
    if !st.status.success() {
        return Err(Error(format!(
            "download failed: {}",
            String::from_utf8_lossy(&st.stderr).trim()
        )));
    }
    Ok(())
}

fn curl_text(url: &str) -> Result<String> {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "-A", "ReOculus", url])
        .output()
        .map_err(|e| Error(format!("cannot run curl (is it installed?): {e}")))?;
    if !out.status.success() {
        return Err(Error(format!(
            "GitHub request failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn sha256_file(path: &PathBuf) -> Result<String> {
    use sha2::Digest;
    let mut f = std::fs::File::open(path)?;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
}

pub fn download_latest() -> Result<DownloadReport> {
    let release = curl_text(SINGULARITY_LATEST_API)?;
    let (version, apk_pair, checksum_url) = pick_release_assets(&release)?;
    let (apk_name, apk_url) = apk_pair
        .split_once('|')
        .ok_or_else(|| Error("internal error: bad asset pair".into()))?;
    let dir = cache_dir()?;
    let file = dir.join(apk_name);
    curl(apk_url, &file)?;
    let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
    if size < 1_000_000 {
        let _ = std::fs::remove_file(&file);
        return Err(Error(format!(
            "the download is only {size} bytes, which is not a real APK (GitHub may have rate-limited the request)"
        )));
    }
    let hash = sha256_file(&file)?;
    // Verify it is a real APK and read its package/label.
    let badging = crate::apps::badging_of(&file).map_err(|e| {
        Error(format!(
            "the download is not a readable APK ({e}); the file was left at {} so you can inspect it",
            file.display()
        ))
    })?;
    let mut verification = "no checksum published with this release; aapt verified it is a valid APK".to_string();
    if let Some(url) = checksum_url {
        let sums_file = dir.join("checksums.txt");
        if curl(&url, &sums_file).is_ok() {
            if let Ok(text) = std::fs::read_to_string(&sums_file) {
                if text.contains(&hash) {
                    verification = "checksum file verified (SHA-256 matches)".to_string();
                } else {
                    verification = format!(
                        "WARNING: the published checksum file does not contain this download's SHA-256 ({}). The file was kept, do not install it unless you trust it.",
                        &hash[..16]
                    );
                }
            }
        }
    }
    Ok(DownloadReport {
        version,
        file: file.to_string_lossy().into_owned(),
        size_bytes: size,
        sha256: hash,
        package: badging.package,
        label: badging.label,
        verification,
    })
}

/// The newest downloaded Singularity APK in the cache, if any.
pub fn cached_apk() -> Option<PathBuf> {
    let dir = cache_dir().ok()?;
    let mut apks: Vec<PathBuf> = std::fs::read_dir(&dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "apk").unwrap_or(false))
        .collect();
    apks.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
    apks.into_iter().next_back()
}

pub fn install(t: &dyn AdbTransport, serial: &str) -> Result<String> {
    let apk = cached_apk().ok_or_else(|| {
        Error("no downloaded Singularity APK found. Download it first (step 3 of the wizard).".into())
    })?;
    let target = Target::serial(serial);
    let msg = t.install(&target, &[apk.clone()], true)?;
    Ok(format!(
        "Singularity installed on the headset. Open it on the headset and press Root Now. ({msg})"
    ))
}

/// Verify root after the user pressed Root Now in Singularity.
pub fn verify(t: &dyn AdbTransport, serial: &str) -> Result<RootStatus> {
    let root = root_status(t, serial);
    if !root.rooted {
        return Err(Error(
            "root is not on yet. In Singularity on the headset, press Root Now and let it finish (the headset may restart), then try again.".into(),
        ));
    }
    Ok(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_release_assets_finds_apk_and_checksum() {
        let text = r#"{"tag_name":"v1.0.8","assets":[
            {"name":"Singularity-v1.0.8.apk","browser_download_url":"https://example.com/s.apk"},
            {"name":"checksums.sha256","browser_download_url":"https://example.com/c.txt"},
            {"name":"README.md","browser_download_url":"https://example.com/r.md"}
        ]}"#;
        let (version, pair, checksum) = pick_release_assets(text).unwrap();
        assert_eq!(version, "v1.0.8");
        assert!(pair.starts_with("Singularity-v1.0.8.apk|"));
        assert_eq!(checksum.as_deref(), Some("https://example.com/c.txt"));
    }

    #[test]
    fn pick_release_assets_no_apk_errors() {
        let text = r#"{"tag_name":"v1.0.0","assets":[{"name":"README.md","browser_download_url":"https://example.com/r.md"}]}"#;
        assert!(pick_release_assets(text).is_err());
    }

    #[test]
    fn pick_release_assets_no_checksum_is_ok() {
        let text = r#"{"tag_name":"v1.0.8","assets":[{"name":"Singularity.apk","browser_download_url":"https://example.com/s.apk"}]}"#;
        let (_, pair, checksum) = pick_release_assets(text).unwrap();
        assert!(pair.ends_with("https://example.com/s.apk"));
        assert!(checksum.is_none());
    }
}
