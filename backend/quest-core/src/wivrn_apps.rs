//! Custom PC games and apps for the WiVRn launcher: the .desktop writer.
//!
//! WiVRn's in-headset launcher lists .desktop files whose Categories
//! contain `X-WiVRn-VR` (verified live 2026-11-12: Open Saber added
//! this way showed up in the headset and booted). ReOculus writes
//! those files into `~/.local/share/applications` and lists,
//! edits and removes them. The .desktop files are the source of
//! truth: no separate registry to drift. Steam games are a separate
//! step (Phase 1 research): their launch options live in Steam's
//! VDF files, not here.

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
    /// Extra command line options after the executable, as typed
    /// by the user (for example `--fullscreen`). Split from the
    /// Exec line on read, joined back on write.
    pub launch_options: String,
    pub icon: String,
    /// One-line description, from the Comment key. Empty when the
    /// entry has none.
    pub comment: String,
}

/// The [Desktop Entry] section of a .desktop file, as one tuple:
/// (name, exec path, launch options, icon, comment, categories).
/// The Exec line is split at the first whitespace: the first
/// token is the executable, the rest is launch options. Entries
/// we write never have a spaced executable path (add refuses
/// them), so the split is exact for our own files.
pub fn parse_desktop(
    text: &str,
) -> Option<(String, String, String, String, String, String)> {
    let mut in_entry = false;
    let mut name = None;
    let mut exec = None;
    let mut icon = None;
    let mut comment = None;
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
            "Comment" => comment = Some(v),
            "Categories" => categories = Some(v),
            _ => {}
        }
    }
    let exec_line = exec?;
    let (exec_path, launch_options) = match exec_line.split_once(char::is_whitespace) {
        Some((p, rest)) => (p.to_string(), rest.trim().to_string()),
        None => (exec_line, String::new()),
    };
    Some((
        name?,
        exec_path,
        launch_options,
        icon.unwrap_or_default(),
        comment.unwrap_or_default(),
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
        let (name, exec, launch_options, icon, comment, categories) = match parse_desktop(&text) {
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
            launch_options,
            icon,
            comment,
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

/// The .desktop file text for one entry. Exec is the plain
/// executable path plus the launch options, if any. No shell, no
/// % codes, no env injection: WiVRn's launcher reads the Exec
/// line as a command plus arguments. Comment is written only
/// when the user gave one; an empty icon means the default.
pub fn desktop_content(
    name: &str,
    exec: &str,
    launch_options: &str,
    icon: &str,
    comment: &str,
) -> String {
    let icon = if icon.trim().is_empty() {
        DEFAULT_ICON
    } else {
        icon.trim()
    };
    let exec_line = if launch_options.trim().is_empty() {
        exec.to_string()
    } else {
        format!("{exec} {}", launch_options.trim())
    };
    let mut out = format!(
        "[Desktop Entry]\nType=Application\nName={name}\nExec={exec_line}\nIcon={icon}\n"
    );
    if !comment.trim().is_empty() {
        out.push_str(&format!("Comment={}\n", comment.trim()));
    }
    out.push_str(&format!("Categories=Game;{WIVRN_CATEGORY};\n"));
    out
}

/// The checks shared by add and update: a usable name, a real
/// executable with no spaces in its path, single-line launch
/// options and comment (a newline would break the .desktop
/// file), and an icon path that exists when it names a file.
/// A bare icon name is a theme icon and cannot be checked here.
fn check_entry(name: &str, exec: &str, launch_options: &str, icon: &str, comment: &str) -> Result<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Error("Give the game or app a name first.".into()));
    }
    if name.len() > 100 {
        return Err(Error("That name is too long (100 characters max).".into()));
    }
    if !PathBuf::from(exec).is_file() {
        return Err(Error(format!(
            "No file at {exec}. Pick the game's executable with Browse."
        )));
    }
    if exec.contains(char::is_whitespace) {
        return Err(Error(
            "That path has a space in it, and the WiVRn launcher does not handle spaced paths. Move the game somewhere without spaces first.".into(),
        ));
    }
    if launch_options.contains(['\n', '\r']) {
        return Err(Error("Launch options must be one line.".into()));
    }
    if comment.contains(['\n', '\r']) {
        return Err(Error("The description must be one line.".into()));
    }
    let icon = icon.trim();
    if !icon.is_empty() && icon.contains('/') && !PathBuf::from(icon).is_file() {
        return Err(Error(format!("No image file at {icon}.")));
    }
    Ok(())
}

/// Make a file runnable when it is not yet (Open Saber shipped
/// without the executable bit). Best effort: a failure here does
/// not block the entry, the launch will just fail instead.
fn make_executable(exec: &str) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let exec_path = PathBuf::from(exec);
        if let Ok(m) = std::fs::metadata(&exec_path) {
            if m.permissions().mode() & 0o111 == 0 {
                let mut p = m.permissions();
                p.set_mode(m.permissions().mode() | 0o111);
                let _ = std::fs::set_permissions(&exec_path, p);
            }
        }
    }
}

/// Add a game or app to the headset launcher. Writes
/// `reoculus-<slug>.desktop`, numbered when the name is taken.
pub fn add(
    name: &str,
    exec: &str,
    launch_options: &str,
    icon: &str,
    comment: &str,
) -> Result<WivrnApp> {
    check_entry(name, exec, launch_options, icon, comment)?;
    make_executable(exec);
    let name = name.trim();
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
    std::fs::write(
        dir.join(&file),
        desktop_content(name, exec, launch_options, icon, comment),
    )?;
    Ok(WivrnApp {
        file,
        name: name.to_string(),
        exec: exec.to_string(),
        launch_options: launch_options.trim().to_string(),
        icon: if icon.trim().is_empty() {
            DEFAULT_ICON.to_string()
        } else {
            icon.trim().to_string()
        },
        comment: comment.trim().to_string(),
    })
}

/// Change a launcher entry in place: name, executable, launch
/// options, icon and description. The file keeps its name, so a
/// rename does not break anything that points at the file. The
/// same guards as remove apply: only a plain .desktop file name,
/// only from the apps dir, only a WiVRn entry.
pub fn update(
    file: &str,
    name: &str,
    exec: &str,
    launch_options: &str,
    icon: &str,
    comment: &str,
) -> Result<WivrnApp> {
    if file.contains('/') || file.contains('\\') || file.contains("..") {
        return Err(Error("That is not a plain file name.".into()));
    }
    if !file.ends_with(".desktop") {
        return Err(Error("Only .desktop entries can be changed here.".into()));
    }
    let path = apps_dir().join(file);
    let text = std::fs::read_to_string(&path)
        .map_err(|_| Error(format!("No launcher entry named {file}.")))?;
    let Some((_, _, _, _, _, categories)) = parse_desktop(&text) else {
        return Err(Error(format!("{file} is not a launcher entry.")));
    };
    if !categories.split(';').any(|c| c.trim() == WIVRN_CATEGORY) {
        return Err(Error(format!(
            "{file} is not a WiVRn entry, so it was left alone."
        )));
    }
    check_entry(name, exec, launch_options, icon, comment)?;
    make_executable(exec);
    let name = name.trim();
    std::fs::write(
        &path,
        desktop_content(name, exec, launch_options, icon, comment),
    )?;
    Ok(WivrnApp {
        file: file.to_string(),
        name: name.to_string(),
        exec: exec.to_string(),
        launch_options: launch_options.trim().to_string(),
        icon: if icon.trim().is_empty() {
            DEFAULT_ICON.to_string()
        } else {
            icon.trim().to_string()
        },
        comment: comment.trim().to_string(),
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
    let Some((_, _, _, _, _, categories)) = parse_desktop(&text) else {
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
        let c = desktop_content(
            "Open Saber",
            "/home/anthony/Downloads/OpenSaber.x86_64",
            "--fullscreen",
            "",
            "A free VR saber game.",
        );
        assert!(c.contains("Name=Open Saber"));
        assert!(c.contains("Exec=/home/anthony/Downloads/OpenSaber.x86_64 --fullscreen"));
        assert!(c.contains("Icon=applications-games"));
        assert!(c.contains("Comment=A free VR saber game."));
        assert!(c.contains("X-WiVRn-VR"));
        let (name, exec, opts, icon, comment, cats) = parse_desktop(&c).unwrap();
        assert_eq!(name, "Open Saber");
        assert_eq!(exec, "/home/anthony/Downloads/OpenSaber.x86_64");
        assert_eq!(opts, "--fullscreen");
        assert_eq!(icon, "applications-games");
        assert_eq!(comment, "A free VR saber game.");
        assert!(cats.split(';').any(|x| x == "X-WiVRn-VR"));
        // No options, no comment, custom icon: the lines drop out.
        let c2 = desktop_content("Plain", "/bin/true", "", "/home/anthony/icon.png", "");
        assert!(c2.contains("Exec=/bin/true\n"));
        assert!(c2.contains("Icon=/home/anthony/icon.png"));
        assert!(!c2.contains("Comment="));
        let (_, _, opts2, _, comment2, _) = parse_desktop(&c2).unwrap();
        assert_eq!(opts2, "");
        assert_eq!(comment2, "");
    }

    #[test]
    fn parse_ignores_other_sections_and_non_wivrn() {
        let text = "[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam\nCategories=Game;\n[Desktop Action Play]\nName=Play\n";
        let (name, _, _, _, _, cats) = parse_desktop(text).unwrap();
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
        // A fake executable to add, plus a fake icon file.
        let exe = tmp.join("Game.x86_64");
        std::fs::write(&exe, b"fake").unwrap();
        let icon = tmp.join("game.png");
        std::fs::write(&icon, b"fake png").unwrap();
        let added = add(
            "Test Game",
            exe.to_str().unwrap(),
            "--fullscreen -vr",
            icon.to_str().unwrap(),
            "A test game.",
        )
        .unwrap();
        assert_eq!(added.file, "reoculus-test-game.desktop");
        assert!(tmp.join(&added.file).exists());
        assert_eq!(added.launch_options, "--fullscreen -vr");
        assert_eq!(added.icon, icon.to_str().unwrap());
        assert_eq!(added.comment, "A test game.");
        // Executable bit was set by add().
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_ne!(std::fs::metadata(&exe).unwrap().permissions().mode() & 0o111, 0);
        }
        let listed = list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "Test Game");
        assert_eq!(listed[0].launch_options, "--fullscreen -vr");
        assert_eq!(listed[0].comment, "A test game.");
        // Edit the entry in place: same file, new values.
        let edited = update(
            &added.file,
            "Test Game 2",
            exe.to_str().unwrap(),
            "",
            "",
            "",
        )
        .unwrap();
        assert_eq!(edited.file, added.file);
        assert_eq!(edited.name, "Test Game 2");
        assert_eq!(edited.launch_options, "");
        assert_eq!(edited.icon, "applications-games");
        assert_eq!(listed[0].file, edited.file);
        let listed = list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "Test Game 2");
        assert_eq!(listed[0].icon, "applications-games");
        // A second add with the same name gets a numbered file.
        let added2 = add("Test Game", exe.to_str().unwrap(), "", "", "").unwrap();
        assert_eq!(added2.file, "reoculus-test-game-2.desktop");
        assert_eq!(list().len(), 2);
        // Refusals.
        assert!(add("", exe.to_str().unwrap(), "", "", "").is_err());
        assert!(add("Nope", "/does/not/exist", "", "", "").is_err());
        assert!(add("Spaced", "/tmp/has a space/game", "", "", "").is_err());
        assert!(add("Opts", exe.to_str().unwrap(), "a\nb", "", "").is_err());
        assert!(add("Icon", exe.to_str().unwrap(), "", "/does/not/exist.png", "").is_err());
        assert!(add("Desc", exe.to_str().unwrap(), "", "", "a\nb").is_err());
        assert!(update(&added.file, "", exe.to_str().unwrap(), "", "", "").is_err());
        assert!(update(&added.file, "X", "/does/not/exist", "", "", "").is_err());
        assert!(update("nope.desktop", "X", exe.to_str().unwrap(), "", "", "").is_err());
        assert!(update("../escape.desktop", "X", exe.to_str().unwrap(), "", "", "").is_err());
        // Remove one, then the other; removing a non-WiVRn file is refused.
        let other = tmp.join("plain.desktop");
        std::fs::write(
            &other,
            "[Desktop Entry]\nName=Plain\nExec=/bin/true\nCategories=Game;\n",
        )
        .unwrap();
        assert!(remove("plain.desktop").is_err());
        assert!(update("plain.desktop", "X", exe.to_str().unwrap(), "", "", "").is_err());
        assert!(remove("../escape.desktop").is_err());
        remove(&added.file).unwrap();
        assert_eq!(list().len(), 1);
        remove(&added2.file).unwrap();
        assert!(list().is_empty());
        std::env::remove_var("QUEST_COMPANION_APPS_DIR");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
