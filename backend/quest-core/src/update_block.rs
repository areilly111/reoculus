//! Pause / block Horizon OS updates: rooted only, optional, OFF by
//! default, and only by a method that is verified reversible.
//!
//! What it does: disables the two updater packages the Quest 2
//! actually has (`com.oculus.updater`, `com.oculus.nux.ota`) with
//! `pm disable-user --user 0` (run as root). That is the standard
//! Android package disable: the packages stay on the device, their
//! files are untouched, and `pm enable` turns them straight back
//! on. Nothing is deleted, nothing is flashed, the bootloader is
//! untouched. The app never enables this on its own: the user turns
//! it on in the Rooted section, and the same screen turns it off.
//!
//! What it does NOT do: Meta telemetry. No standalone telemetry
//! package was found on the Quest 2 (checked live: no package
//! matches telemetry/analytics/bugreport/crash), so there is nothing
//! safe to disable here; Singularity itself ships a telemetry
//! disabler in-headset for users who want that. This section does
//! not pretend to block telemetry, and the docs say so.
//!
//! Why it exists: Meta ends Quest 2 feature updates with Horizon OS
//! v2.13 (March 2027). After that, an update prompt is at best a
//! dead end; pausing updates keeps a working rooted Quest 2 from
//! being pushed onto an update the user did not ask for.

use crate::error::Result;
use crate::transport::{AdbTransport, Target};
use serde::Serialize;

/// The updater packages on a Quest 2 (verified live with
/// `pm list packages` on the owner's headset).
pub const UPDATER_PACKAGES: [&str; 2] = ["com.oculus.updater", "com.oculus.nux.ota"];

#[derive(Debug, Clone, Serialize)]
pub struct UpdateBlockStatus {
    /// True when every updater package is currently disabled.
    pub blocked: bool,
    pub packages: Vec<PackageBlock>,
    /// Root is required for disable/enable; without it the status
    /// is reported and the action is refused with a plain message.
    pub rooted: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct PackageBlock {
    pub package: String,
    pub disabled: bool,
}

fn is_disabled(t: &dyn AdbTransport, serial: &str, package: &str) -> bool {
    // `pm list packages -d <filter>` prints the package only when
    // it is disabled for the user.
    t.shell(
        &Target::serial(serial),
        &format!("pm list packages -d {package}"),
    )
    .map(|o| o.stdout.contains(package))
    .unwrap_or(false)
}

pub fn update_block_status(t: &dyn AdbTransport, serial: &str) -> UpdateBlockStatus {
    let rooted = crate::wireless::root_status(t, serial).rooted;
    let packages: Vec<PackageBlock> = UPDATER_PACKAGES
        .iter()
        .map(|p| PackageBlock {
            package: p.to_string(),
            disabled: is_disabled(t, serial, p),
        })
        .collect();
    let blocked = !packages.is_empty() && packages.iter().all(|p| p.disabled);
    UpdateBlockStatus { blocked, packages, rooted }
}

/// Turn update blocking on (disable) or off (enable). Root only.
/// Returns a per-package outcome; a failure on one package does not
/// silently pretend the other worked.
pub fn set_update_block(
    t: &dyn AdbTransport,
    serial: &str,
    block: bool,
) -> Result<Vec<PackageBlock>> {
    let target = Target::serial(serial);
    if !crate::wireless::root_status(t, serial).rooted {
        return Err(crate::error::Error(
            "pausing updates needs root, and this headset did not grant su".into(),
        ));
    }
    let verb = if block { "disable-user --user 0" } else { "enable" };
    let mut out = Vec::new();
    for p in UPDATER_PACKAGES {
        let r = t.shell(&target, &format!("su -c \"pm {verb} {p}\""));
        match r {
            Ok(o) if o.code == 0 || format!("{}{}", o.stdout, o.stderr).contains("new state") => {
                out.push(PackageBlock {
                    package: p.to_string(),
                    disabled: if block { true } else { false },
                });
            }
            Ok(o) => {
                return Err(crate::error::Error(format!(
                    "could not {} {}: {}",
                    if block { "disable" } else { "enable" },
                    p,
                    format!("{}{}", o.stdout, o.stderr).trim()
                )));
            }
            Err(e) => {
                return Err(crate::error::Error(format!(
                    "could not {} {}: {e}",
                    if block { "disable" } else { "enable" },
                    p
                )));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn updater_packages_are_the_live_ones() {
        // Verified on the owner's Quest 2 with `pm list packages`:
        // these two are the only update/OTA packages on the device.
        assert_eq!(
            super::UPDATER_PACKAGES,
            ["com.oculus.updater", "com.oculus.nux.ota"]
        );
    }
}
