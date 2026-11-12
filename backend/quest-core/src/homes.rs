//! Home manager: list the home / environment apps on the headset,
//! see which one is active, and switch the active home.
//!
//! Homes are ordinary APKs that handle ACTION_MAIN + CATEGORY_HOME.
//! The list comes from `pm query-activities`, the same query the
//! Android home picker uses. Switching runs `cmd package
//! set-home-activity` (a shell-user command since Android 10); on
//! builds that refuse it, the UI falls back to opening the
//! headset's Home settings screen so the user picks there.
//!
//! This never copies Quest Home Switcher's code; it only uses the
//! public adb commands any home manager would use.

use crate::apps::list_apps;
use crate::error::{Error, Result};
use crate::transport::{AdbTransport, Target};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct HomeEntry {
    /// Flattened component, e.g. `com.oculus.home/.HomeActivity`.
    pub component: String,
    pub package: String,
    pub label: String,
    pub is_current: bool,
}

/// Parse `pm query-activities --components -a android.intent.action.MAIN
/// -c android.intent.category.HOME` output: one flattened component
/// per line, `package/Activity` (activity may start with `.`).
/// Falls back to parsing `package:` lines from the long form.
pub fn parse_query_activities(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        // Flattened component: `com.foo/.Bar` or `com.foo/com.foo.Bar`.
        if t.contains('/') && !t.contains(' ') && !t.contains(':') {
            let comp = t.to_string();
            if !out.contains(&comp) {
                out.push(comp);
            }
            continue;
        }
        // Long form fallback: `package:com.foo` lines.
        if let Some(pkg) = t.strip_prefix("package:") {
            let pkg = pkg.trim().to_string();
            if !pkg.is_empty() && !out.iter().any(|c| c.starts_with(&format!("{pkg}/"))) {
                out.push(format!("{pkg}/"));
            }
        }
    }
    // Drop the bare `package/` entries when a real component for
    // the same package was also found.
    let real: Vec<String> = out
        .iter()
        .filter(|c| !c.ends_with('/'))
        .map(|c| c.split('/').next().unwrap_or("").to_string())
        .collect();
    out.retain(|c| !(c.ends_with('/') && real.iter().any(|p| c.starts_with(p.as_str()))));
    out
}

/// Parse `pm resolve-activity --brief -a android.intent.action.MAIN
/// -c android.intent.category.HOME` output: a single flattened
/// component, or the system resolver / nothing.
pub fn parse_resolve_activity(text: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if t.contains('/') && !t.contains(' ') {
            // The resolver itself means "no home picked yet".
            if t.contains("ResolverActivity") || t.contains("resolver") {
                return None;
            }
            return Some(t.to_string());
        }
    }
    None
}

fn package_of(component: &str) -> String {
    component
        .split('/')
        .next()
        .unwrap_or(component)
        .to_string()
}

/// True when a component from `pm query-activities` is a home a user
/// can actually pick. The query also lists system panels that handle
/// the HOME intent but are not homes: the Quest system UI library
/// panel and its shortcut dialog (`com.oculus.systemux`), and any
/// dialog activity. Those would fail to set, so they never reach
/// the list. Verified live on a Quest 2: the real homes are
/// `com.oculus.vrshell`, `com.threethan.launcher` and
/// `com.android.settings/.FallbackHome`.
pub fn is_home_component(component: &str) -> bool {
    let (pkg, activity) = component
        .split_once('/')
        .unwrap_or((component, ""));
    if pkg == "com.oculus.systemux" {
        return false;
    }
    if activity.contains("Dialog") {
        return false;
    }
    true
}

pub fn list_homes(t: &dyn AdbTransport, serial: &str) -> Result<Vec<HomeEntry>> {
    let target = Target::serial(serial);
    let out = t.shell(
        &target,
        "pm query-activities --components -a android.intent.action.MAIN -c android.intent.category.HOME",
    )?;
    let components: Vec<String> = parse_query_activities(&out.stdout)
        .into_iter()
        .filter(|c| is_home_component(c))
        .collect();
    if components.is_empty() {
        return Err(Error(
            "no home apps answered the query (is this a Quest? the headset may need a restart)".into(),
        ));
    }
    let current = current_home(t, serial).ok().flatten();
    // Labels from the installed-app list (one call, already fast).
    let labels: std::collections::HashMap<String, String> = list_apps(t, serial, false)
        .map(|apps| apps.into_iter().map(|a| (a.package, a.label)).collect())
        .unwrap_or_default();
    let mut homes: Vec<HomeEntry> = components
        .into_iter()
        .map(|component| {
            let package = package_of(&component);
            let label = labels
                .get(&package)
                .cloned()
                .unwrap_or_else(|| package.clone());
            HomeEntry {
                is_current: current.as_deref() == Some(component.as_str()),
                component,
                package,
                label,
            }
        })
        .collect();
    // Current home first, then the rest by label.
    homes.sort_by(|a, b| b.is_current.cmp(&a.is_current).then(a.label.cmp(&b.label)));
    Ok(homes)
}

pub fn current_home(t: &dyn AdbTransport, serial: &str) -> Result<Option<String>> {
    let target = Target::serial(serial);
    let out = t.shell(
        &target,
        "pm resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME",
    )?;
    if out.code != 0 {
        return Ok(None);
    }
    Ok(parse_resolve_activity(&out.stdout))
}

/// Set the active home. Returns a plain message. Fails with a clear
/// error when the build refuses the command; the caller then opens
/// the headset's Home settings screen instead.
pub fn set_home(t: &dyn AdbTransport, serial: &str, component: &str) -> Result<String> {
    if !component.contains('/') || component.contains(' ') || component.contains(';') || component.contains('$') {
        return Err(Error(
            "that does not look like a home component (want package/Activity)".into(),
        ));
    }
    let target = Target::serial(serial);
    let out = t.shell(
        &target,
        &format!("cmd package set-home-activity {component}"),
    )?;
    if out.code != 0 {
        return Err(Error(format!(
            "the headset refused to switch homes ({}). Open the headset's Home settings instead and pick the home there.",
            out.stderr.trim()
        )));
    }
    // Verify the switch landed.
    match current_home(t, serial)? {
        Some(c) if c == component => Ok(format!("Home switched to {component}.")),
        Some(c) => Err(Error(format!(
            "the switch did not stick: the headset still reports {c}. Open the headset's Home settings instead."
        ))),
        None => Ok(format!("Home switch sent for {component}; the headset did not confirm it yet, check in the headset.")),
    }
}

/// Open the headset's Home settings (the system home picker).
pub fn open_home_settings(t: &dyn AdbTransport, serial: &str) -> Result<String> {
    let target = Target::serial(serial);
    let out = t.shell(&target, "am start -a android.settings.HOME_SETTINGS")?;
    if out.code != 0 {
        return Err(Error(format!(
            "could not open Home settings on the headset: {}",
            out.stderr.trim()
        )));
    }
    Ok("Home settings are open on the headset. Put it on and pick a home there.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_activities_parses_components() {
        let text = "com.oculus.home/.HomeActivity\ncom.itsmattkc.questhomeswitcher/.MainActivity\ncom.oculus.environment.rays/.HomeActivity\n";
        let comps = parse_query_activities(text);
        assert_eq!(comps.len(), 3);
        assert_eq!(comps[0], "com.oculus.home/.HomeActivity");
    }

    #[test]
    fn query_activities_long_form_fallback() {
        let text = "package:com.oculus.home\n  activity: com.oculus.home/.HomeActivity\npackage:com.other.home\n";
        let comps = parse_query_activities(text);
        assert!(comps.iter().any(|c| c.starts_with("com.oculus.home/")));
        assert!(comps.iter().any(|c| c.starts_with("com.other.home/")));
    }

    #[test]
    fn resolve_activity_parses_and_ignores_resolver() {
        assert_eq!(
            parse_resolve_activity("com.oculus.home/.HomeActivity\n"),
            Some("com.oculus.home/.HomeActivity".to_string())
        );
        assert_eq!(
            parse_resolve_activity("com.android.internal.app.ResolverActivity\n"),
            None
        );
        assert_eq!(parse_resolve_activity("\n"), None);
    }

    #[test]
    fn package_of_component() {
        assert_eq!(package_of("com.oculus.home/.HomeActivity"), "com.oculus.home");
        assert_eq!(package_of("com.foo/com.foo.Bar"), "com.foo");
    }
}
