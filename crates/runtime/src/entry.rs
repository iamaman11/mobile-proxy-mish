//! Runtime Lifecycle natural-owner capability.
//!
//! Vendor-neutral lifecycle and Cellular Egress runtime coordination live here. Platform DNS,
//! Android process APIs, root-shell mechanics, UI and vendor JSON remain outside this crate.

mod execution;
pub use execution::*;

mod tls_client;

mod public_ip_network;

mod readiness_network;

mod readiness_runtime;
pub use readiness_network::*;
pub use readiness_runtime::*;

mod root_session;

mod airplane_effect;

mod root_policy_effect;
mod root_policy_runtime;
pub use root_policy_runtime::*;

mod lifecycle;
pub use lifecycle::*;

mod cellular_connector;
pub use cellular_connector::*;

mod cellular_runtime;
pub use cellular_runtime::*;

mod cellular_policy_coordinator;
pub use cellular_policy_coordinator::*;

mod public_ip;
pub use public_ip::*;

mod mesh_serving;

mod mesh_composition;
pub use mesh_composition::*;
pub use mesh_serving::*;

#[cfg(test)]
mod mesh_serving_atomicity_test;

mod proxy_recovery;
pub use proxy_recovery::*;

mod proxy_runtime;

mod proxy_coordinator;
pub use proxy_coordinator::*;

mod product_generation;
pub use product_generation::*;

mod product_runtime;
pub use product_runtime::*;

mod product_diagnostics;
pub use product_diagnostics::*;

mod rotation_runtime;
pub use rotation_runtime::*;

pub use proxy_runtime::*;
