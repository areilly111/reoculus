//! quest-core: the shared Rust core of the Quest companion app.
//!
//! Local only. No Meta API, no account, no ads, no telemetry.
//! Everything here is ADB: the binary transport spawns the system
//! `adb`, the direct transport speaks the wire protocol with libadb.

pub mod apps;
pub mod backup;
pub mod device_backup;
pub mod devices;
pub mod gallery;
pub mod library;
pub mod update_block;
pub mod wireless;
pub mod error;
pub mod files;
pub mod keys;
pub mod media;
pub mod settings;
pub mod transport;
pub mod wivrn;

pub use error::{Error, Result};
pub use transport::{AdbTransport, Device, Target, TransportKind};
