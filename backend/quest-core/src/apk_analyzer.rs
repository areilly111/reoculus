//! APK analyzer: what an APK file is, before you install it.
//!
//! Reads a local APK (or a .apks / .xapk bundle, whose largest
//! inner APK is analyzed) and reports, in plain terms:
//! label, package, version, SDK levels, permissions, features,
//! native libraries (which ABIs, 32-bit or 64-bit, how big), a
//! size breakdown (code, native libs, assets, resources), the
//! file's own SHA-256, and the signer's certificate SHA-256 when
//! `apksigner` is available to check it.
//!
//! The signer check is the honest one: it tells you WHO signed
//! the APK, not whether Android will accept it (that depends on
//! the headset's trust). An APK signed by a key you do not
//! recognize is a reason to stop and think, not proof of malware.

use crate::apps::badging_of;
use crate::error::{Error, Result};
use serde::Serialize;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct ApkAnalysis {
    pub path: String,
    pub file: String,
    pub file_size_bytes: u64,
    pub sha256: String,
    pub package: Option<String>,
    pub label: Option<String>,
    pub version_name: Option<String>,
    pub version_code: Option<u32>,
    pub min_sdk: Option<u32>,
    pub target_sdk: Option<u32>,
    pub permissions: Vec<String>,
    pub features: Vec<String>,
    /// ABIs from the manifest (`native-code:`) plus the lib/ folder.
    pub abis: Vec<String>,
    pub is_64_bit: bool,
    pub native_lib_bytes: u64,
    pub native_lib_count: usize,
    pub dex_bytes: u64,
    pub assets_bytes: u64,
    pub res_bytes: u64,
    /// Signer certificate SHA-256, when apksigner could check it.
    pub signature_sha256: Option<String>,
    pub signature_checked: bool,
    /// Plain-language notes (bundle source, missing checks, ...).
    pub notes: Vec<String>,
}

/// Classify one zip entry for the size breakdown.
/// Returns ("lib" | "dex" | "assets" | "res" | "other", size).
fn classify_entry(name: &str, size: u64) -> (&'static str, u64) {
    if name.starts_with("lib/") && name.ends_with(".so") {
        ("lib", size)
    } else if name.starts_with("classes") && name.ends_with(".dex") {
        ("dex", size)
    } else if name.starts_with("assets/") {
        ("assets", size)
    } else if name.starts_with("res/") {
        ("res", size)
    } else {
        ("other", size)
    }
}

fn abi_of_lib_entry(name: &str) -> Option<String> {
    // lib/<abi>/libfoo.so
    let rest = name.strip_prefix("lib/")?;
    let abi = rest.split('/').next()?;
    if abi.is_empty() || abi.contains('.') {
        None
    } else {
        Some(abi.to_string())
    }
}

fn sha256_file(path: &Path) -> Result<String> {
    use sha2::Digest;
    let mut f = std::fs::File::open(path)?;
    let mut h = sha2::Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
}

/// Find a JDK for apksigner (it is a shell script that execs
/// `java`): $JAVA_HOME first, then the usual JDK homes.
fn find_java_home() -> Option<PathBuf> {
    if let Ok(v) = std::env::var("JAVA_HOME") {
        if !v.is_empty() && PathBuf::from(&v).join("bin").join("java").exists() {
            return Some(PathBuf::from(v));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        for cand in [
            PathBuf::from(&home).join("workspace").join("android-toolchain").join("jdk-17"),
            PathBuf::from(&home).join("Android").join("Sdk").join("java"),
        ] {
            if cand.join("bin").join("java").exists() {
                return Some(cand);
            }
        }
    }
    if let Ok(rd) = std::fs::read_dir("/usr/lib/jvm") {
        let mut dirs: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        dirs.sort_by(|a, b| b.cmp(a));
        for d in dirs {
            if d.join("bin").join("java").exists() {
                return Some(d);
            }
        }
    }
    None
}

/// Find `apksigner` the same way aapt is found: PATH, then the
/// newest Android SDK build-tools dir.
fn find_apksigner() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let cand = dir.join("apksigner");
            if cand.exists() {
                return Some(cand);
            }
        }
    }
    let mut roots: Vec<PathBuf> = Vec::new();
    for var in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                roots.push(PathBuf::from(v));
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        roots.push(PathBuf::from(&home).join("Android").join("Sdk"));
        roots.push(
            PathBuf::from(&home)
                .join("workspace")
                .join("android-sdk"),
        );
    }
    for root in roots {
        let bt = root.join("build-tools");
        if let Ok(rd) = std::fs::read_dir(&bt) {
            let mut versions: Vec<_> = rd.flatten().map(|e| e.path()).collect();
            versions.sort_by(|a, b| b.cmp(a));
            for v in versions {
                let cand = v.join("apksigner");
                if cand.exists() {
                    return Some(cand);
                }
            }
        }
    }
    None
}

/// Parse `apksigner verify --print-certs` output for the signer's
/// SHA-256 digest. Pure, so it is unit-tested.
pub fn parse_apksigner_certs(text: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("Signer #1 certificate SHA-256 digest:") {
            let d = rest.trim().to_string();
            if !d.is_empty() {
                return Some(d);
            }
        }
    }
    None
}

/// If `path` is a .apks / .xapk bundle, extract its largest inner
/// APK to a temp file and return that path (plus a note). Otherwise
/// returns `path` unchanged. The temp file lives until the caller
/// drops the returned TempDir.
fn maybe_unbundle(path: &Path) -> Result<(PathBuf, Option<tempfile::TempDir>, Option<String>)> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ext != "apks" && ext != "xapk" {
        return Ok((path.to_path_buf(), None, None));
    }
    let file = std::fs::File::open(path)?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| Error(format!("cannot open the bundle {}: {e}", path.display())))?;
    let mut best: Option<(usize, String, u64)> = None;
    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| Error(e.to_string()))?;
        let name = entry.name().to_string();
        if name.to_lowercase().ends_with(".apk") {
            let size = entry.size();
            if best.as_ref().map(|(_, _, s)| size > *s).unwrap_or(true) {
                best = Some((i, name, size));
            }
        }
    }
    let (idx, name, _) = best.ok_or_else(|| {
        Error(format!(
            "no APK inside the bundle {} (is it a real .apks / .xapk?)",
            path.display()
        ))
    })?;
    let dir = tempfile::tempdir().map_err(|e| Error(format!("cannot make a temp dir: {e}")))?;
    let out = dir.path().join("base.apk");
    let mut entry = archive.by_index(idx).map_err(|e| Error(e.to_string()))?;
    let mut data = Vec::new();
    entry.read_to_end(&mut data)?;
    std::fs::write(&out, &data)?;
    Ok((
        out,
        Some(dir),
        Some(format!("a bundle; analyzing its largest APK ({name})")),
    ))
}

pub fn analyze_apk(path: &Path) -> Result<ApkAnalysis> {
    if !path.is_file() {
        return Err(Error(format!("no such file: {}", path.display())));
    }
    let file_size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let sha256 = sha256_file(path)?;
    let (apk_path, _tmp, bundle_note) = maybe_unbundle(path)?;
    let mut notes: Vec<String> = Vec::new();
    if let Some(n) = bundle_note {
        notes.push(n);
    }
    let badging = badging_of(&apk_path).map_err(|e| {
        Error(format!(
            "could not read the APK ({e}); it may be corrupt or use a resource format aapt cannot parse"
        ))
    })?;
    // Size breakdown + ABIs from the zip.
    let mut abis: Vec<String> = badging.native_code.clone();
    let mut native_lib_bytes = 0u64;
    let mut native_lib_count = 0usize;
    let mut dex_bytes = 0u64;
    let mut assets_bytes = 0u64;
    let mut res_bytes = 0u64;
    let file = std::fs::File::open(&apk_path)?;
    if let Ok(mut archive) = zip::ZipArchive::new(file) {
        for i in 0..archive.len() {
            if let Ok(entry) = archive.by_index(i) {
                let name = entry.name().to_string();
                let size = entry.size();
                match classify_entry(&name, size).0 {
                    "lib" => {
                        native_lib_bytes += size;
                        native_lib_count += 1;
                        if let Some(abi) = abi_of_lib_entry(&name) {
                            if !abis.contains(&abi) {
                                abis.push(abi);
                            }
                        }
                    }
                    "dex" => dex_bytes += size,
                    "assets" => assets_bytes += size,
                    "res" => res_bytes += size,
                    _ => {}
                }
            }
        }
    }
    let is_64_bit = abis.iter().any(|a| a == "arm64-v8a" || a == "x86_64");
    // Signer certificate, when apksigner is around. apksigner is a
    // shell script that execs `java` from PATH (it ignores
    // JAVA_HOME), so prepend the JDK's bin dir to PATH when we
    // found one.
    let mut signature_sha256 = None;
    let mut signature_checked = false;
    match find_apksigner() {
        Some(apksigner) => {
            let mut cmd = std::process::Command::new(&apksigner);
            cmd.args(["verify", "--print-certs"]).arg(&apk_path);
            if let Some(java_home) = find_java_home() {
                let old_path = std::env::var("PATH").unwrap_or_default();
                let bin = java_home.join("bin");
                cmd.env("PATH", format!("{}:{old_path}", bin.display()));
            }
            if let Ok(out) = cmd.output() {
                let text = format!(
                    "{}{}",
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                );
                if let Some(d) = parse_apksigner_certs(&text) {
                    signature_sha256 = Some(d);
                    signature_checked = true;
                } else if text.contains("java") && text.contains("not found") {
                    notes.push(
                        "apksigner needs Java, which was not found on this computer, so the signer was not checked".to_string(),
                    );
                } else if !out.status.success() {
                    notes.push(
                        "apksigner could not verify this APK's signature (it may be unsigned or use an old scheme); Android will refuse it on the headset".to_string(),
                    );
                }
            }
        }
        None => {
            notes.push("apksigner was not found, so the signer was not checked".to_string());
        }
    }
    if badging.permissions.is_empty() {
        notes.push("this APK requests no permissions".to_string());
    }
    Ok(ApkAnalysis {
        path: path.to_string_lossy().into_owned(),
        file: path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        file_size_bytes: file_size,
        sha256,
        package: badging.package,
        label: badging.label,
        version_name: badging.version,
        version_code: badging.version_code,
        min_sdk: badging.sdk_version,
        target_sdk: badging.target_sdk,
        permissions: badging.permissions,
        features: badging.features,
        abis,
        is_64_bit,
        native_lib_bytes,
        native_lib_count,
        dex_bytes,
        assets_bytes,
        res_bytes,
        signature_sha256,
        signature_checked,
        notes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apksigner_certs_parses() {
        let text = "Verifies\nVerified using v1 scheme (JAR signing): true\nSigner #1 certificate DN: CN=Example\nSigner #1 certificate SHA-256 digest: ab12cd34\n";
        assert_eq!(
            parse_apksigner_certs(text).as_deref(),
            Some("ab12cd34")
        );
        assert_eq!(parse_apksigner_certs("Verifies\n"), None);
    }

    #[test]
    fn classify_entry_buckets() {
        assert_eq!(classify_entry("lib/arm64-v8a/libfoo.so", 10).0, "lib");
        assert_eq!(classify_entry("classes2.dex", 10).0, "dex");
        assert_eq!(classify_entry("assets/data.bin", 10).0, "assets");
        assert_eq!(classify_entry("res/layout.xml", 10).0, "res");
        assert_eq!(classify_entry("META-INF/MANIFEST.MF", 10).0, "other");
    }

    #[test]
    fn abi_of_lib_entry_works() {
        assert_eq!(
            abi_of_lib_entry("lib/arm64-v8a/libfoo.so").as_deref(),
            Some("arm64-v8a")
        );
        assert_eq!(abi_of_lib_entry("lib/x86/libfoo.so").as_deref(), Some("x86"));
        assert_eq!(abi_of_lib_entry("classes.dex"), None);
        assert_eq!(abi_of_lib_entry("lib/libfoo.so"), None);
    }
}
