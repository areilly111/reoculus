//! Headset model classification: which Quest is connected.
//!
//! The app keys on the device codename (`ro.product.device`) first and
//! confirms with an exact match on the model (`ro.product.model`).
//! The model is never matched by substring: "Quest 2" starts with
//! "Quest", so a `contains("quest")` check would call a Quest 2 a
//! Quest 1. Quest 1 is `monterey` / `Quest`, Quest 2 is `hollywood` /
//! `Quest 2`, Quest 3 is `panther` / `Quest 3`.
//!
//! The Quest 1 strings are inferred from the Quest 2/3 pattern (no
//! literal Quest 1 getprop dump is published anywhere); the final
//! Quest 1 firmware build, `49845030443200410`, is a useful second
//! fingerprint if the model ever reads oddly. Confirm on a real
//! Quest 1 before trusting the strings blindly.
//!
//! Singularity only supports Quest 2, Pro, 3, and 3S (its own README),
//! and Quest Home Switcher only lists Quest 2 / 3 / 3S, so both are
//! hidden on Quest 1. An unreadable model ("unknown") keeps the old
//! behaviour: everything shows, and the Singularity preflight refuses
//! with a plain message when it cannot confirm the headset.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Headset {
    Quest1,
    Quest2,
    Quest3,
    Quest3S,
    QuestPro,
    Unknown,
}

impl Headset {
    /// Short slug for JSON (`quest1`, `quest2`, ...).
    pub fn slug(&self) -> &'static str {
        match self {
            Headset::Quest1 => "quest1",
            Headset::Quest2 => "quest2",
            Headset::Quest3 => "quest3",
            Headset::Quest3S => "quest3s",
            Headset::QuestPro => "questpro",
            Headset::Unknown => "unknown",
        }
    }

    /// Plain display name ("Quest 1", ...).
    pub fn display_name(&self) -> &'static str {
        match self {
            Headset::Quest1 => "Quest 1",
            Headset::Quest2 => "Quest 2",
            Headset::Quest3 => "Quest 3",
            Headset::Quest3S => "Quest 3S",
            Headset::QuestPro => "Quest Pro",
            Headset::Unknown => "Unknown headset",
        }
    }

    /// Highest refresh rate the panel supports.
    pub fn max_refresh_rate(&self) -> u32 {
        match self {
            Headset::Quest1 => 72,
            Headset::Quest3 | Headset::Quest3S => 207,
            _ => 120,
        }
    }

    /// True only for Quest 1.
    pub fn is_quest1(&self) -> bool {
        matches!(self, Headset::Quest1)
    }

    /// Singularity root features. False only on Quest 1; an unknown
    /// model still shows them and lets the preflight refuse.
    pub fn supports_singularity(&self) -> bool {
        !matches!(self, Headset::Quest1)
    }

    /// Quest Home Switcher. False only on Quest 1.
    pub fn supports_home_switcher(&self) -> bool {
        !matches!(self, Headset::Quest1)
    }
}

/// Classify from the model and device codename strings, either of
/// which may be empty. Device codename wins when it is known.
pub fn classify(model: &str, device: &str) -> Headset {
    let d = device.trim().to_lowercase();
    match d.as_str() {
        "monterey" => return Headset::Quest1,
        "hollywood" => return Headset::Quest2,
        "panther" => return Headset::Quest3,
        "seacliff" => return Headset::QuestPro,
        _ => {}
    }
    match model.trim().to_lowercase().as_str() {
        "quest" => Headset::Quest1,
        "quest 2" => Headset::Quest2,
        "quest 3" => Headset::Quest3,
        "quest 3s" => Headset::Quest3S,
        "quest pro" => Headset::QuestPro,
        _ => Headset::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quest1_by_device_and_model() {
        assert_eq!(classify("Quest", "monterey"), Headset::Quest1);
        assert_eq!(classify("", "monterey"), Headset::Quest1);
        assert_eq!(classify("Quest", ""), Headset::Quest1);
    }

    #[test]
    fn quest2_is_not_quest1() {
        // The substring trap: "Quest 2" starts with "Quest".
        assert_eq!(classify("Quest 2", "hollywood"), Headset::Quest2);
        assert_eq!(classify("Quest 2", ""), Headset::Quest2);
        assert_ne!(classify("Quest 2", "hollywood"), Headset::Quest1);
    }

    #[test]
    fn quest3_family_and_unknown() {
        assert_eq!(classify("Quest 3", "panther"), Headset::Quest3);
        assert_eq!(classify("Quest 3S", ""), Headset::Quest3S);
        assert_eq!(classify("Quest Pro", "seacliff"), Headset::QuestPro);
        assert_eq!(classify("Lorem ipsum 1.0.0", ""), Headset::Unknown);
        assert_eq!(classify("", ""), Headset::Unknown);
    }

    #[test]
    fn gates() {
        assert!(!Headset::Quest1.supports_singularity());
        assert!(!Headset::Quest1.supports_home_switcher());
        assert!(Headset::Quest2.supports_singularity());
        assert!(Headset::Quest2.supports_home_switcher());
        assert!(Headset::Unknown.supports_singularity());
        assert_eq!(Headset::Quest1.max_refresh_rate(), 72);
        assert_eq!(Headset::Quest2.max_refresh_rate(), 120);
        assert_eq!(Headset::Quest3.max_refresh_rate(), 207);
    }
}
