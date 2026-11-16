//! Setup checklist state: detect what is already set up on this
//! machine, instead of asking the user to tick boxes by hand.
//!
//! The Setup screen used to be four manual checkboxes with
//! hardcoded starting values, and two of them even shared one
//! variable, so ticking one ticked the other. The udev step was
//! done (android-sdk-platform-tools-common installed) and the box
//! still showed undone. This module answers each item from the
//!
//! * Developer account: cannot be checked, it lives on Meta's
//!   website and ReOculus never signs in. Reported as unknown,
//!   with the reason in the UI, never guessed.
//! * Developer Mode and USB debugging: read from `adb devices`.
//!   A headset listed as `device` means both are done. A headset
//!   listed as `unauthorized` means Developer Mode is on (adb is
//!   even offering the prompt) but the Allow tap has not happened
//!   yet. No headset plugged in means both are unknown, not
//!   undone: plug one in to check.
//! * Linux USB permission (udev): done when a headset shows as
//!   `device` or `unauthorized` (adb can talk to it, so the USB
//!   layer is fine), or, with no headset plugged in, when the
//!   android-sdk-platform-tools-common package is installed or a
//!   udev rule file covering Meta devices (vendor id 2833) exists.
//!   A headset listed as `no permissions` means not done even
//!   when the package is installed: the rule is there but has
//!   not taken effect, unplug and plug the headset back in.
//!
//! On Android (direct transport, no adb binary, no udev) the
//! udev item is unknown with "only applies to Linux" as the
//! reason, and the adb items are unknown unless a headset is
//! connected, which the app knows from its own state and overlays
//! in the UI.

use crate::devices;
use crate::error::Result;
use crate::transport::{AdbTransport, DeviceState};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// Meta / Oculus USB vendor id, decimal, as it appears in udev
/// rules (`ATTR{idVendor}=="2833"`).
pub const META_VENDOR_ID: &str = "2833";

/// One checklist item, as the UI shows it. `done` is None when
/// the item cannot be checked on this machine: the UI shows the
/// reason instead of guessing.
#[derive(Debug, Clone, Serialize)]
pub struct SetupCheck {
    pub id: &'static str,
    pub done: Option<bool>,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SetupStatus {
    pub checks: Vec<SetupCheck>,
}

/// Where a Meta udev rule may live. The package ships
/// `51-android.rules` under /lib (or /usr/lib on some systems);
/// a user-made rule usually lands in /etc.
fn rule_search_dirs() -> Vec<PathBuf> {
    vec![
        PathBuf::from("/etc/udev/rules.d"),
        PathBuf::from("/lib/udev/rules.d"),
        PathBuf::from("/usr/lib/udev/rules.d"),
    ]
}

/// Does this rules file cover Meta devices? The file must mention
/// the Meta vendor id. A bare `51-android.rules` with no 2833 in
/// it does not count: the package's file has it, and so does any
/// hand-written Oculus rule.
fn rule_covers_meta(path: &Path) -> bool {
    match std::fs::read_to_string(path) {
        Ok(text) => text.contains(META_VENDOR_ID),
        Err(_) => false,
    }
}

/// Find a udev rule file covering Meta devices, if one exists.
/// The two 51-android.rules locations first, then any *.rules
/// file in the udev dirs (a custom 99-oculus.rules, for
/// example). Returns the first path found.
pub fn find_meta_rule() -> Option<PathBuf> {
    for dir in rule_search_dirs() {
        let direct = dir.join("51-android.rules");
        if rule_covers_meta(&direct) {
            return Some(direct);
        }
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("rules") {
                    continue;
                }
                if rule_covers_meta(&path) {
                    return Some(path);
                }
            }
        }
    }
    None
}

/// Is the dpkg-query output the "installed" state? Pure, so the
/// tests can feed it strings without running dpkg.
pub fn dpkg_output_installed(output: &str) -> bool {
    output.contains("install ok installed")
}

/// Is android-sdk-platform-tools-common installed, by dpkg? On a
/// non-Debian system dpkg is missing and this is false, which is
/// fine: the rule-file check is the other signal.
pub fn package_installed() -> bool {
    let out = std::process::Command::new("dpkg-query")
        .args(["-W", "-f=${Status}", "android-sdk-platform-tools-common"])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            dpkg_output_installed(&String::from_utf8_lossy(&o.stdout))
        }
        _ => false,
    }
}

/// The decision logic, pure so the tests can drive it without
/// adb, dpkg, or the filesystem. `states` are the device states
/// `adb devices` reported right now (empty when adb is missing
/// or nothing is plugged in). `rule` is the path of a Meta udev
/// rule file, when one was found. `is_linux` is false on Android,
/// where udev does not apply.
pub fn evaluate(
    states: &[DeviceState],
    package_installed: bool,
    rule: Option<&Path>,
    is_linux: bool,
) -> Vec<SetupCheck> {
    let any_device = states.iter().any(|s| matches!(s, DeviceState::Device));
    let any_unauthorized = states
        .iter()
        .any(|s| matches!(s, DeviceState::Unauthorized));
    let any_no_permissions = states
        .iter()
        .any(|s| matches!(s, DeviceState::NoPermissions));

    // Developer Mode: on when adb can see the headset at all as
    // device or unauthorized. No headset means unknown.
    let dev_mode = if any_device {
        SetupCheck {
            id: "dev_mode",
            done: Some(true),
            detail: "A headset is connected and authorized, so Developer Mode is on.".into(),
        }
    } else if any_unauthorized {
        SetupCheck {
            id: "dev_mode",
            done: Some(true),
            detail: "The headset is asking to allow this computer, which only happens with Developer Mode on.".into(),
        }
    } else if any_no_permissions {
        SetupCheck {
            id: "dev_mode",
            done: None,
            detail: "Cannot tell while the headset shows as no permissions. Fix the USB permission below first.".into(),
        }
    } else {
        SetupCheck {
            id: "dev_mode",
            done: None,
            detail: "No headset is connected. Plug one in to check this.".into(),
        }
    };

    // USB debugging: done only when a headset is authorized.
    let usb_debugging = if any_device {
        SetupCheck {
            id: "usb_debugging",
            done: Some(true),
            detail: "A headset is connected and authorized.".into(),
        }
    } else if any_unauthorized {
        SetupCheck {
            id: "usb_debugging",
            done: Some(false),
            detail: "The headset is waiting for you. Put it on and tap Allow, and tick Always allow from this computer.".into(),
        }
    } else if any_no_permissions {
        SetupCheck {
            id: "usb_debugging",
            done: None,
            detail: "Cannot tell while the headset shows as no permissions. Fix the USB permission below first.".into(),
        }
    } else {
        SetupCheck {
            id: "usb_debugging",
            done: None,
            detail: "No headset is connected. Plug one in to check this.".into(),
        }
    };

    // USB permission (udev): live proof beats the static checks,
    // and a live failure beats them too.
    let udev = if !is_linux {
        SetupCheck {
            id: "udev",
            done: None,
            detail: "This step only applies to Linux computers. There is no udev on a phone.".into(),
        }
    } else if any_device || any_unauthorized {
        SetupCheck {
            id: "udev",
            done: Some(true),
            detail: "The headset shows up in adb, so the USB permission is working.".into(),
        }
    } else if any_no_permissions {
        SetupCheck {
            id: "udev",
            done: Some(false),
            detail: "The headset shows as no permissions. Unplug it and plug it back in; if it still says that, install the Android udev rules with sudo apt install android-sdk-platform-tools-common.".into(),
        }
    } else if package_installed {
        SetupCheck {
            id: "udev",
            done: Some(true),
            detail: "android-sdk-platform-tools-common is installed. No headset is plugged in, so this is the installed rules, not a live check.".into(),
        }
    } else if let Some(path) = rule {
        SetupCheck {
            id: "udev",
            done: Some(true),
            detail: format!(
                "A udev rule covering Meta devices was found in {}. No headset is plugged in, so this is the installed rule, not a live check.",
                path.display()
            ),
        }
    } else {
        SetupCheck {
            id: "udev",
            done: Some(false),
            detail: "No Android udev rules were found. Install them with sudo apt install android-sdk-platform-tools-common, then unplug and plug the headset back in.".into(),
        }
    };

    vec![
        SetupCheck {
            id: "dev_account",
            done: None,
            detail: "ReOculus cannot check this. Your developer account lives on Meta's website, not on this computer. Tick the box yourself once you have made one.".into(),
        },
        dev_mode,
        usb_debugging,
        udev,
    ]
}

/// Check the real system state for every checklist item. The adb
/// list is best effort: when adb is missing or the transport
/// cannot list devices (direct transport on Android), the live
/// items come back unknown instead of failing the whole check.
pub fn status(t: &dyn AdbTransport) -> Result<SetupStatus> {
    let states: Vec<DeviceState> = match devices::list_devices(t) {
        Ok(devs) => devs.into_iter().map(|d| d.state).collect(),
        Err(_) => Vec::new(),
    };
    let is_linux = cfg!(target_os = "linux");
    let (package, rule) = if is_linux {
        (package_installed(), find_meta_rule())
    } else {
        (false, None)
    };
    Ok(SetupStatus {
        checks: evaluate(&states, package, rule.as_deref(), is_linux),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::DeviceState;

    fn by_id<'a>(checks: &'a [SetupCheck], id: &str) -> &'a SetupCheck {
        checks.iter().find(|c| c.id == id).unwrap()
    }

    #[test]
    fn dev_account_is_always_unknown() {
        let checks = evaluate(&[], false, None, true);
        let c = by_id(&checks, "dev_account");
        assert_eq!(c.done, None);
        assert!(c.detail.contains("cannot check"));
    }

    #[test]
    fn no_headset_means_unknown_except_udev_static() {
        // Nothing plugged in, package installed: udev done from
        // the package, the headset items unknown.
        let checks = evaluate(&[], true, None, true);
        assert_eq!(by_id(&checks, "dev_mode").done, None);
        assert_eq!(by_id(&checks, "usb_debugging").done, None);
        assert_eq!(by_id(&checks, "udev").done, Some(true));
        assert!(by_id(&checks, "udev").detail.contains("installed"));
        // Nothing plugged in, nothing installed: udev not done.
        let checks = evaluate(&[], false, None, true);
        assert_eq!(by_id(&checks, "udev").done, Some(false));
        assert!(by_id(&checks, "udev").detail.contains("sudo apt install"));
    }

    #[test]
    fn rule_file_counts_as_done() {
        let path = Path::new("/etc/udev/rules.d/51-android.rules");
        let checks = evaluate(&[], false, Some(path), true);
        assert_eq!(by_id(&checks, "udev").done, Some(true));
        assert!(by_id(&checks, "udev").detail.contains("51-android.rules"));
    }

    #[test]
    fn authorized_headset_means_everything_done() {
        let checks = evaluate(&[DeviceState::Device], false, None, true);
        assert_eq!(by_id(&checks, "dev_mode").done, Some(true));
        assert_eq!(by_id(&checks, "usb_debugging").done, Some(true));
        assert_eq!(by_id(&checks, "udev").done, Some(true));
    }

    #[test]
    fn unauthorized_means_dev_mode_on_but_not_allowed() {
        let checks = evaluate(&[DeviceState::Unauthorized], false, None, true);
        assert_eq!(by_id(&checks, "dev_mode").done, Some(true));
        assert_eq!(by_id(&checks, "usb_debugging").done, Some(false));
        assert!(by_id(&checks, "usb_debugging").detail.contains("tap Allow"));
        // adb can see the headset, so the USB layer is fine.
        assert_eq!(by_id(&checks, "udev").done, Some(true));
    }

    #[test]
    fn no_permissions_beats_the_static_checks() {
        // Package installed, but the headset still shows no
        // permissions: udev is not done, and the headset items
        // cannot be told.
        let checks = evaluate(&[DeviceState::NoPermissions], true, None, true);
        assert_eq!(by_id(&checks, "udev").done, Some(false));
        assert!(by_id(&checks, "udev").detail.contains("Unplug"));
        assert_eq!(by_id(&checks, "dev_mode").done, None);
        assert_eq!(by_id(&checks, "usb_debugging").done, None);
    }

    #[test]
    fn android_reports_udev_unknown() {
        let checks = evaluate(&[DeviceState::Device], false, None, false);
        assert_eq!(by_id(&checks, "udev").done, None);
        assert!(by_id(&checks, "udev").detail.contains("Linux"));
    }

    #[test]
    fn dpkg_output_parsing() {
        assert!(dpkg_output_installed("Status: install ok installed\n"));
        assert!(!dpkg_output_installed("Status: deinstall ok config-files\n"));
        assert!(!dpkg_output_installed("dpkg-query: no packages found matching android-sdk-platform-tools-common\n"));
    }

    #[test]
    fn rule_scan_finds_a_meta_rule_in_a_temp_dir() {
        let tmp = std::env::temp_dir().join(format!(
            "setup-checks-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        // A rule file without the Meta id does not count.
        let plain = tmp.join("51-android.rules");
        std::fs::write(&plain, "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"18d1\", MODE=\"0666\"\n").unwrap();
        assert!(!rule_covers_meta(&plain));
        // Adding the Meta id counts.
        std::fs::write(
            &plain,
            "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"2833\", MODE=\"0666\"\n",
        )
        .unwrap();
        assert!(rule_covers_meta(&plain));
        assert!(!rule_covers_meta(&tmp.join("missing.rules")));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
