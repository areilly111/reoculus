//! Custom PC games and apps for the WiVRn launcher: the .desktop writer.
//!
//! WiVRn's in-headset launcher lists .desktop files whose Categories
//! contain `X-WiVRn-VR` (verified live 2026-11-12: Open Saber added
//! this way showed up in the headset and booted). ReOculus writes
//! those files into `~/.local/share/applications` and lists and
//! removes them. The .desktop files are the source of truth: no
//! separate registry to drift. Steam games are a separate step
//! (Phase 1 research): their launch options live in Steam's VDF
//! files, not here.

use crate::error::{Error, Result};
use serde::Serialize;
use std::path::PathBuf;

pub const WIVRN_CATEGORY: &str = "X-WiVRn-VR";
const DEFAULT_ICON: &str = "applications-games";

fn home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

/// Where WiVRn looks for launcher entries. Overridable with
/// `QUEST_COMPANION_APPS_DIR` (tests only, same pattern as the
/// backup-root override in paths.rs).
pub fn apps_dir() -> PathBuf {
    if let Ok(d) = std::env::var("QUEST_COMPANION_APPS_DIR") {
        if !d.is_empty() {
            return PathBuf::from(d);
        }
    }
    home().join(".local").join("share").join("applications")
}

#[derive(Debug, Clone, Serialize)]
pub struct WivrnApp {
    pub file: String,
    pub name: String,
    pub exec: String,
    pub icon: String,
}

/// Parse the [Desktop Entry] section of a .desktop file.
/// Returns (name, exec, icon, categories) when all of Name, Exec
/// and Categories are present.
pub fn parse_desktop(text: &str) -> Option<(String, String, String, String)> {
    let mut in_entry = false;
    let mut name = None;
    let mut exec = None;
    let mut icon = None;
    let mut categories = None;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (k, v) = line.split_once('=')?;
        let v = v.trim().to_string();
        match k.trim() {
            "Name" => name = Some(v),
            "Exec" => exec = Some(v),
            "Icon" => icon = Some(v),
            "Categories" => categories = Some(v),
            _ => {}
        }
    }
    Some((
        name?,
        exec?,
        icon.unwrap_or_default(),
        categories?,
    ))
}

/// Every .desktop file in the apps dir that WiVRn shows in the
/// headset launcher (Categories contains X-WiVRn-VR), by name.
pub fn list() -> Vec<WivrnApp> {
    let dir = apps_dir();
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
            continue;
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let (name, exec, icon, categories) = match parse_desktop(&text) {
            Some(v) => v,
            None => continue,
        };
        if !categories.split(';').any(|c| c.trim() == WIVRN_CATEGORY) {
            continue;
        }
        out.push(WivrnApp {
            file: entry.file_name().to_string_lossy().to_string(),
            name,
            exec,
            icon,
        });
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

/// "Open Saber!" -> "open-saber". Non-alphanumeric runs become one
/// dash; leading and trailing dashes are dropped.
pub fn slugify(name: &str) -> String {
    let mut out = String::new();
    let mut last_dash = true; // drops leading dashes
    for c in name.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// The .desktop file text for one entry. No shell, no % codes, no
/// env injection: Exec is the plain executable path, which is all
/// WiVRn's launcher reads.
pub fn desktop_content(name: &str, exec: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName={name}\nExec={exec}\nIcon={DEFAULT_ICON}\nCategories=Game;{WIVRN_CATEGORY};\n"
    )
}

/// Add a game or app to the headset launcher. The executable must
/// exist and be a file; a path with spaces is refused (WiVRn does
/// no shell quoting, so a spaced Exec would not launch). If the
/// file is not executable yet, it is made executable first, the
/// same step Open Saber needed. Writes
/// `reoculus-<slug>.desktop`, numbered when the name is taken.
pub fn add(name: &str, exec: &str) -> Result<WivrnApp> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error("Give the game or app a name first.".into()));
    }
    if name.len() > 100 {
        return Err(Error("That name is too long (100 characters max).".into()));
    }
    let exec_path = PathBuf::from(exec);
    if !exec_path.is_file() {
        return Err(Error(format!(
            "No file at {exec}. Pick the game's executable with Browse."
        )));
    }
    if exec.contains(char::is_whitespace) {
        return Err(Error(
            "That path has a space in it, and the WiVRn launcher does not handle spaced paths. Move the game somewhere without spaces first.".into(),
        ));
    }
    // Make it runnable if it is not yet (Open Saber shipped without
    // the executable bit). Best effort: a failure here does not
    // block the entry, the launch will just fail instead.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(m) = std::fs::metadata(&exec_path) {
            if m.permissions().mode() & 0o111 == 0 {
                let mut p = m.permissions();
                p.set_mode(m.permissions().mode() | 0o111);
                let _ = std::fs::set_permissions(&exec_path, p);
            }
        }
    }
    let dir = apps_dir();
    std::fs::create_dir_all(&dir)?;
    let slug = {
        let s = slugify(name);
        if s.is_empty() {
            "app".to_string()
        } else {
            s
        }
    };
    let mut file = format!("reoculus-{slug}.desktop");
    let mut n = 2;
    while dir.join(&file).exists() {
        file = format!("reoculus-{slug}-{n}.desktop");
        n += 1;
        if n > 99 {
            return Err(Error(format!(
                "Could not find a free file name for '{name}'."
            )));
        }
    }
    std::fs::write(dir.join(&file), desktop_content(name, exec))?;
    Ok(WivrnApp {
        file,
        name: name.to_string(),
        exec: exec.to_string(),
        icon: DEFAULT_ICON.to_string(),
    })
}

/// Remove a launcher entry. Only a plain file name is accepted,
/// only from the apps dir, and only when the file is a WiVRn
/// entry, so a stray name can never delete another app's file.
pub fn remove(file: &str) -> Result<String> {
    if file.contains('/') || file.contains('\\') || file.contains("..") {
        return Err(Error("That is not a plain file name.".into()));
    }
    if !file.ends_with(".desktop") {
        return Err(Error("Only .desktop entries can be removed here.".into()));
    }
    let path = apps_dir().join(file);
    let text = std::fs::read_to_string(&path)
        .map_err(|_| Error(format!("No launcher entry named {file}.")))?;
    let Some((_, _, _, categories)) = parse_desktop(&text) else {
        return Err(Error(format!("{file} is not a launcher entry.")));
    };
    if !categories.split(';').any(|c| c.trim() == WIVRN_CATEGORY) {
        return Err(Error(format!(
            "{file} is not a WiVRn entry, so it was left alone."
        )));
    }
    std::fs::remove_file(&path)?;
    Ok(format!("{file} removed from the headset launcher."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_cases() {
        assert_eq!(slugify("Open Saber!"), "open-saber");
        assert_eq!(slugify("  Beat   Saber  "), "beat-saber");
        assert_eq!(slugify("The Lab"), "the-lab");
        assert_eq!(slugify("!!!"), "");
        assert_eq!(slugify("Half-Life 2 VR"), "half-life-2-vr");
    }

    #[test]
    fn desktop_content_has_the_category() {
        let c = desktop_content("Open Saber", "/home/anthony/Downloads/OpenSaber.x86_64");
        assert!(c.contains("Name=Open Saber"));
        assert!(c.contains("Exec=/home/anthony/Downloads/OpenSaber.x86_64"));
        assert!(c.contains("X-WiVRn-VR"));
        let (name, exec, _, cats) = parse_desktop(&c).unwrap();
        assert_eq!(name, "Open Saber");
        assert_eq!(exec, "/home/anthony/Downloads/OpenSaber.x86_64");
        assert!(cats.split(';').any(|x| x == "X-WiVRn-VR"));
    }

    #[test]
    fn parse_ignores_other_sections_and_non_wivrn() {
        let text = "[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam\nCategories=Game;\n[Desktop Action Play]\nName=Play\n";
        let (name, _, _, cats) = parse_desktop(text).unwrap();
        assert_eq!(name, "Steam");
        assert!(!cats.split(';').any(|x| x == "X-WiVRn-VR"));
        assert!(parse_desktop("Name=x\n").is_none());
    }

    #[test]
    fn add_list_remove_round_trip() {
        let tmp = std::env::temp_dir().join(format!(
            "wivrn-apps-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        std::env::set_var("QUEST_COMPANION_APPS_DIR", &tmp);
        // A fake executable to add.
        let exe = tmp.join("Game.x86_64");
        std::fs::write(&exe, b"fake").unwrap();
        let added = add("Test Game", exe.to_str().unwrap()).unwrap();
        assert_eq!(added.file, "reoculus-test-game.desktop");
        assert!(tmp.join(&added.file).exists());
        // Executable bit was set by add().
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_ne!(std::fs::metadata(&exe).unwrap().permissions().mode() & 0o111, 0);
        }
        let listed = list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "Test Game");
        // A second add with the same name gets a numbered file.
        let added2 = add("Test Game", exe.to_str().unwrap()).unwrap();
        assert_eq!(added2.file, "reoculus-test-game-2.desktop");
        assert_eq!(list().len(), 2);
        // Refusals.
        assert!(add("", exe.to_str().unwrap()).is_err());
        assert!(add("Nope", "/does/not/exist").is_err());
        assert!(add("Spaced", "/tmp/has a space/game").is_err());
        // Remove one, then the other; removing a non-WiVRn file is refused.
        let other = tmp.join("plain.desktop");
        std::fs::write(
            &other,
            "[Desktop Entry]\nName=Plain\nExec=/bin/true\nCategories=Game;\n",
        )
        .unwrap();
        assert!(remove("plain.desktop").is_err());
        assert!(remove("../escape.desktop").is_err());
        remove(&added.file).unwrap();
        assert_eq!(list().len(), 1);
        remove(&added2.file).unwrap();
        assert!(list().is_empty());
        std::env::remove_var("QUEST_COMPANION_APPS_DIR");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
