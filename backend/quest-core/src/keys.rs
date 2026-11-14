//! Per-install ADB host key.
//!
//! A fresh RSA-2048 keypair is generated once per install and stored at
//! `~/.config/quest-companion/adbkey` (private, mode 0600) with the public
//! half at `adbkey.pub`. No shared key is ever shipped: anyone holding a
//! shared private key could impersonate this app to any Quest that
//! trusted it.
//!
//! The spawned `adb` binary reads its key from `~/.android/adbkey`. If
//! that file does not exist yet, we install a copy of our key there so the
//! binary transport actually authenticates as *our* key. If the user
//! already has an adb key (e.g. from Android Studio / platform-tools),
//! we leave it alone and only report our own fingerprint.

use crate::error::{Error, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

/// The config folder on this computer: `~/.config/quest-companion`.
/// Errors when HOME is not set. Note this only builds the path; it
/// does not create the folder.
pub fn config_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| Error("HOME is not set; cannot locate config directory".into()))?;
    Ok(PathBuf::from(home).join(".config").join("quest-companion"))
}

pub struct KeyInfo {
    pub private_path: PathBuf,
    pub public_path: PathBuf,
    /// Base64 SHA-256 fingerprint of the public key blob, as shown in the
    /// headset's "Allow USB debugging?" dialog.
    pub fingerprint: String,
    /// True when we installed a copy into ~/.android/adbkey because the
    /// user had no adb key yet.
    pub installed_into_android_home: bool,
}

/// The name baked into the ADB public-key line (the `user@host` suffix
/// adbd shows). Fixed, so the key is recognizable as ours.
fn key_name() -> Result<libadb::keys::KeyName<'static>> {
    libadb::keys::KeyName::new("quest-companion@localhost")
        .map_err(|e| Error(format!("invalid key name: {e}")))
}

fn fingerprint_of(public_wire: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(public_wire);
    B64.encode(h.finalize())
}

fn write_private(path: &PathBuf, pem: &str) -> Result<()> {
    fs::write(path, pem)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// Generate a fresh keypair if needed and return its fingerprint.
/// Safe to call on every run; it is a no-op when the key already exists.
pub fn ensure_keypair() -> Result<KeyInfo> {
    let dir = config_dir()?;
    fs::create_dir_all(&dir)?;
    let private_path = dir.join("adbkey");
    let public_path = dir.join("adbkey.pub");

    let (wire, pem, pub_line) = if private_path.exists() && public_path.exists() {
        let pem = fs::read_to_string(&private_path)?;
        let key = libadb::AdbKey::from_pkcs8_pem(
            &pem,
            &mut libadb::keys::rsa::rand_core::OsRng,
            key_name()?,
        )
        .map_err(|e| Error(format!("stored ADB key is unreadable: {e}")))?;
        let wire = key.public_key_wire().to_vec();
        let pub_line = key.public_key_line().to_vec();
        (wire, pem, pub_line)
    } else {
        let key = libadb::AdbKey::generate(&mut libadb::keys::rsa::rand_core::OsRng, key_name()?)
            .map_err(|e| Error(format!("cannot generate ADB key: {e}")))?;
        let pem = key
            .to_pkcs8_pem()
            .map_err(|e| Error(format!("cannot serialize ADB key: {e}")))?
            .to_string();
        let wire = key.public_key_wire().to_vec();
        let pub_line = key.public_key_line().to_vec();
        write_private(&private_path, &pem)?;
        // Public half next to it, plus the plain key file adb itself uses.
        let mut pub_text = pub_line.clone();
        pub_text.extend_from_slice(b"\n");
        fs::write(&public_path, &pub_text)?;
        (wire, pem, pub_line)
    };

    let fingerprint = fingerprint_of(&wire);

    // Make the spawned adb binary use this key when the user has none.
    let android_home = std::env::var("HOME")
        .map(PathBuf::from)
        .map(|h| h.join(".android"))
        .unwrap_or_default();
    let adb_key = android_home.join("adbkey");
    let mut installed = false;
    if !adb_key.exists() {
        if fs::create_dir_all(&android_home).is_ok() {
            if write_private(&adb_key, &pem).is_ok() {
                let mut pub_text = pub_line;
                pub_text.extend_from_slice(b"\n");
                let _ = fs::write(android_home.join("adbkey.pub"), &pub_text);
                installed = true;
            }
        }
    }

    Ok(KeyInfo {
        private_path,
        public_path,
        fingerprint,
        installed_into_android_home: installed,
    })
}

/// Load the stored key for the direct (libadb) transport.
pub fn load_keypair() -> Result<libadb::AdbKey> {
    let info = ensure_keypair()?;
    let pem = fs::read_to_string(&info.private_path)?;
    libadb::AdbKey::from_pkcs8_pem(
        &pem,
        &mut libadb::keys::rsa::rand_core::OsRng,
        key_name()?,
    )
    .map_err(|e| Error(format!("cannot load ADB key: {e}")))
}
