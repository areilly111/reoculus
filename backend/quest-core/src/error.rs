//! Errors for the whole core: one human-readable message string.
//!
//! Every fallible function in quest-core returns `Result<T, Error>`,
//! and the CLI turns an Err into `{"ok": false, "error": "..."}`.

use std::fmt;

/// Error type for the whole core. Always a human-readable message; the
/// CLI turns it into `{"ok": false, "error": "..."}`.
#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<String> for Error {
    fn from(s: String) -> Self {
        Error(s)
    }
}

impl From<&str> for Error {
    fn from(s: &str) -> Self {
        Error(s.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error(e.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// Build an Err from a plain message string. Small helper so call sites
/// read `err("...")` instead of `Err(Error(...))`.
pub fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}
