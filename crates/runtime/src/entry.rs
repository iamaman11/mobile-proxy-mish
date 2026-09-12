//! Runtime Lifecycle natural-owner capability.
//!
//! The crate root keeps vendor-neutral lifecycle policy separate from the transitional
//! cellular connector implementation while preserving the existing public connector API.

mod lifecycle;
pub use lifecycle::*;

#[path = "lib.rs"]
mod cellular_connector;
pub use cellular_connector::*;
