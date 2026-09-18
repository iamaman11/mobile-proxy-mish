//! Android-facing presentation vocabulary for the Rust-owned readiness runtime.
//!
//! Readiness eligibility, freshness, probe scheduling, network execution and projection are owned
//! inside mish-readiness/mish-runtime. Android receives only the terminal projection.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProductReadinessState {
    Ready,
    NotReady,
    Degraded,
    Unknown,
}
