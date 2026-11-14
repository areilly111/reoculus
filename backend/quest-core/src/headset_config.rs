//! A small config file that lives ON the headset, so Linux and
//! Android show the same custom headset name on connect. Plain
//! INI-style text, human readable and editable:
//!
//! ```text
//! # ReOculus headset config. Written by ReOculus, read on connect.
//! # Edit the name line to rename this headset.
//! [headset]
//! name=Anthony's Quest
//! ```
//!
//! The file holds ONLY the custom name. Everything else (model,
//! firmware, settings, installed apps) the app reads live from
//! the headset itself, so there is nothing to sync: the name is
//! read on connect, and written only when the user renames.
//! Older files that also had `[settings]` and `[apps]` sections
//! still parse: the extra sections are ignored.
//!
//! Everything goes over `adb shell` (mkdir + base64 pipe), never
//! MTP: the user never has to enable USB file transfer when the
//! headset plugs in. The path is on /sdcard, so no root is needed.

use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use serde::Serialize;

/// Where the config lives on the headset.
pub const CONFIG_PATH: &str = "/sdcard/ReOculus/headset.cfg";
/// Folder for the config (and any later per-headset files).
pub const CONFIG_DIR: &str = "/sdcard/ReOculus";

#[derive(Debug, Clone, Default, Serialize)]
pub struct HeadsetConfig {
    /// The user's custom name for this headset, if they set one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// Render the config as the INI-style text stored on the headset.
/// A headset with no custom name gets a header-only file.
pub fn render(cfg: &HeadsetConfig) -> String {
    let mut out = String::new();
    out.push_str("# ReOculus headset config. Written by ReOculus, read on connect.\n");
    out.push_str("# Edit the name line to rename this headset; the app picks it up next connect.\n");
    out.push_str("[headset]\n");
    if let Some(v) = &cfg.name {
        out.push_str(&format!("name={v}\n"));
    }
    out
}

/// Parse the config text back. Tolerant: `#`/`;` comments, blank
/// lines, unknown sections and unknown keys are skipped, not
/// errors, so a hand-edited file (or an old file with [settings]
/// and [apps] sections) still loads. A value with a `#` in it
/// keeps the `#`: only a line whose first non-space character is
/// `#` or `;` is a comment. Only the `name` key is read.
pub fn parse(text: &str) -> HeadsetConfig {
    let mut cfg = HeadsetConfig::default();
    let mut section = "";
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = if &line[1..line.len() - 1] == "headset" {
                "headset"
            } else {
                ""
            };
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim());
        if section == "headset" && k == "name" && !v.is_empty() {
            cfg.name = Some(v.to_string());
        }
    }
    cfg
}

/// Read the config from the headset. `Ok(None)` when the file is
/// not there yet (never renamed): the UI shows the model name.
pub fn read_config(t: &dyn AdbTransport, serial: &str) -> Result<Option<HeadsetConfig>> {
    let target = Target::serial(serial);
    let out = t.shell(&target, &format!("cat {CONFIG_PATH}"))?;
    if out.stdout.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(parse(&out.stdout)))
}

/// Write the config file (just the name). When `name` is given it
/// replaces the saved name; when it is not, the name already in
/// the file (if any) is kept. Returns the config that was written,
/// verified by reading it back.
pub fn write_config(
    t: &dyn AdbTransport,
    serial: &str,
    name: Option<&str>,
) -> Result<HeadsetConfig> {
    let cfg = HeadsetConfig {
        name: match name {
            Some(n) if !n.trim().is_empty() => Some(n.trim().to_string()),
            _ => read_config(t, serial)?.and_then(|c| c.name),
        },
    };
    write_text(t, serial, &render(&cfg))?;
    // Verify by reading it back: what is on the headset is what
    // the other side will see.
    match read_config(t, serial)? {
        Some(back) => Ok(back),
        None => Err(Error(format!(
            "wrote {CONFIG_PATH} but could not read it back"
        ))),
    }
}

/// Set the custom name. An empty name clears it: the file is
/// deleted, and `Ok(None)` says the headset has no custom name
/// any more. Otherwise the file is written and the config that
/// was saved is returned.
pub fn set_name(
    t: &dyn AdbTransport,
    serial: &str,
    name: &str,
) -> Result<Option<HeadsetConfig>> {
    let name = name.trim();
    if name.is_empty() {
        let target = Target::serial(serial);
        // Best effort: rm -f succeeds even when the file is gone.
        let _ = t.shell(&target, &format!("rm -f {CONFIG_PATH}"));
        return Ok(None);
    }
    let cfg = HeadsetConfig {
        name: Some(name.to_string()),
    };
    write_text(t, serial, &render(&cfg))?;
    match read_config(t, serial)? {
        Some(back) => Ok(Some(back)),
        None => Err(Error(format!(
            "wrote {CONFIG_PATH} but could not read it back"
        ))),
    }
}

/// Write `text` to the config path over adb shell: make the folder,
/// then a base64 pipe so any character in the text (spaces, `#`,
/// `=`, non-ASCII names) survives the shell. No MTP, no root.
fn write_text(t: &dyn AdbTransport, serial: &str, text: &str) -> Result<()> {
    let target = Target::serial(serial);
    t.shell(&target, &format!("mkdir -p {CONFIG_DIR}"))?;
    let b64 = B64.encode(text.as_bytes());
    let out = t.shell(
        &target,
        &format!("echo {b64} | base64 -d > {CONFIG_PATH}"),
    )?;
    if !out.ok() {
        return Err(Error(format!(
            "writing {CONFIG_PATH} failed: {}",
            out.stderr.trim()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An OLD-format file (name + settings + apps): the new parser
    /// must still read the name out of it and ignore the rest.
    const OLD_SAMPLE: &str = "# ReOculus headset config.\n[headset]\nname=My Quest 2\nmodel=Quest 2\ndevice=hollywood\nheadset_model=quest2\nserial=TESTSERIAL000001\nfirmware=52242990024200150\nandroid_version=14\nsynced_at=2026-11-13T18:00:00Z\n[settings]\ndebug.oculus.refreshRate=120\ndebug.oculus.cpuLevel=2\n[apps]\ncom.foo.bar=1.2.3\ncom.example.game=0.9\n";

    #[test]
    fn round_trip() {
        let cfg = HeadsetConfig {
            name: Some("Anthony's Quest".to_string()),
        };
        let back = parse(&render(&cfg));
        assert_eq!(back.name, cfg.name);
    }

    #[test]
    fn parse_old_file_keeps_name_ignores_rest() {
        let cfg = parse(OLD_SAMPLE);
        assert_eq!(cfg.name.as_deref(), Some("My Quest 2"));
    }

    #[test]
    fn parse_tolerant() {
        // Comments, blank lines, unknown sections/keys, lines
        // without '=' and a '#' inside a value all survive.
        let text = "[headset]\nname=Quest #1\n; a comment\n\n[unknown]\nfoo=bar\n[settings]\nbad line\ndebug.oculus.cpuLevel=3\n";
        let cfg = parse(text);
        assert_eq!(cfg.name.as_deref(), Some("Quest #1"));
    }

    #[test]
    fn render_omits_name_when_unset() {
        let cfg = HeadsetConfig { name: None };
        let text = render(&cfg);
        assert!(text.contains("[headset]"));
        assert!(!text.contains("name="));
        assert!(!text.contains("[settings]"));
        assert!(!text.contains("[apps]"));
    }
}
