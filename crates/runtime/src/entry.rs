//! Runtime Lifecycle natural-owner capability.
//!
//! Vendor-neutral lifecycle and Cellular Egress runtime coordination live here. Platform DNS,
//! Android process APIs, root-shell mechanics, UI and vendor JSON remain outside this crate.

mod lifecycle;
pub use lifecycle::*;

#[path = "lib.rs"]
mod cellular_connector;
pub use cellular_connector::*;

mod cellular_runtime;
pub use cellular_runtime::*;
