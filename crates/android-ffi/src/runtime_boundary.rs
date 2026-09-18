//! Narrow Rust <-> Kotlin / Android composition boundary.
//!
//! This module contains typed FFI projection/mapping plus the concrete Android DNS effect adapter.
//! Cellular admission, root-policy coordination and direct proxy egress remain behind public
//! `mish-cellular` / `mish-runtime` APIs rather than drifting into the FFI seam.

use mish_android_network::AndroidNetworkError;
use mish_cellular::{
    CellularAdmissionReason as OwnerAdmissionReason,
    CellularAdmissionSnapshot as OwnerAdmissionSnapshot,
    CellularAdmissionState as OwnerAdmissionState, CellularNetworkAuthority, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_proxy::ProxyOutboundConnectError;
use mish_runtime::{
    CellularDnsResolver, CellularRuntimeCoordinator,
    PublicIpProbeEffectFailure as RuntimePublicIpProbeEffectFailure,
    PublicIpProbeFailure as RuntimePublicIpProbeFailure, RuntimePublicIpProbe,
};
use std::fmt;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionState {
    Unknown,
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionReason {
    NoObservation,
    NotCellular,
    MissingInternetCapability,
    VpnDerivedNetwork,
    NotValidated,
    NetworkLost,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularAdmissionView {
    pub state: CellularAdmissionState,
    pub reason: Option<CellularAdmissionReason>,
    pub admitted_network_handle: Option<u64>,
    pub last_sequence: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum CellularBridgeError {
    InvalidObservationSequence,
    InvalidNetworkHandle,
    OwnerUnavailable,
}
impl fmt::Display for CellularBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidObservationSequence => "observation sequence must be non-zero",
            Self::InvalidNetworkHandle => "Android network handle must be non-zero",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        })
    }
}
impl std::error::Error for CellularBridgeError {}

/// Effect-level Android runtime errors that genuinely cross the FFI exception channel.
/// Expected Proxy Serving start failures use the typed `NativeProxyStartAttempt` data path instead.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularDnsDiagnosticView {
    pub slow_threshold_ms: u64,
    pub started: u64,
    pub completed: u64,
    pub active: u64,
    pub peak_active: u64,
    pub slow_completions: u64,
    pub resolver_failed: u64,
    pub discarded_after_deadline: u64,
    pub completed_after_owner_change: u64,
    pub discarded_stale: u64,
    pub authority_validation_failed: u64,
    pub unusable_result: u64,
    pub accepted_current: u64,
    pub max_native_elapsed_ms: u64,
    pub last_started_owner_sequence: Option<u64>,
    pub last_completed_start_owner_sequence: Option<u64>,
    pub last_completed_current_owner_sequence: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PublicIpEffectFailure {
    SocketConnect,
    SocketTimeout,
    TlsHandshake,
    TlsHostname,
    HttpStatus,
    ResponseTooLarge,
    ResponseMalformed,
    Io,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum PublicIpProbeError {
    NoCurrentCellular,
    RootPolicyUnavailable,
    DnsUnavailable,
    DeadlineExceeded,
    StaleGeneration,
    InvalidResponse,
    SocketConnect,
    SocketTimeout,
    TlsHandshake,
    TlsHostname,
    HttpStatus,
    ResponseTooLarge,
    ResponseMalformed,
    Io,
}

impl fmt::Display for PublicIpProbeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NoCurrentCellular => "no current cellular generation is admitted",
            Self::RootPolicyUnavailable => "current cellular root policy is not authorized",
            Self::DnsUnavailable => "owner-bound cellular DNS is unavailable",
            Self::DeadlineExceeded => "public IP observation exceeded its absolute deadline",
            Self::StaleGeneration => "public IP observation belongs to a stale cellular generation",
            Self::InvalidResponse => "public IP endpoint returned an invalid IP literal",
            Self::SocketConnect => "public IP socket connection failed",
            Self::SocketTimeout => "public IP socket operation timed out",
            Self::TlsHandshake => "public IP TLS handshake failed",
            Self::TlsHostname => "public IP TLS hostname verification failed",
            Self::HttpStatus => "public IP endpoint returned a non-success HTTP status",
            Self::ResponseTooLarge => "public IP endpoint response exceeded its bounded size",
            Self::ResponseMalformed => "public IP endpoint response was malformed",
            Self::Io => "public IP effect I/O failed",
        })
    }
}
impl std::error::Error for PublicIpProbeError {}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PublicIpObservationView {
    pub address: String,
    pub generation: u64,
}

#[derive(uniffi::Object)]
pub struct PublicIpProbeTicket {
    inner: RuntimePublicIpProbe,
}

#[uniffi::export]
impl PublicIpProbeTicket {
    pub fn endpoint_host(&self) -> String {
        self.inner.host().to_owned()
    }

    pub fn endpoint_port(&self) -> u16 {
        self.inner.port()
    }

    pub fn endpoint_path(&self) -> String {
        self.inner.path().to_owned()
    }

    pub fn response_body_max_bytes(&self) -> u64 {
        u64::try_from(self.inner.response_body_max_bytes()).unwrap_or(u64::MAX)
    }

    pub fn numeric_addresses(&self) -> Vec<String> {
        self.inner.numeric_addresses()
    }

    pub fn is_current(&self) -> bool {
        self.inner.is_current()
    }

    pub fn remaining_timeout_ms(&self) -> Result<u64, PublicIpProbeError> {
        self.inner
            .remaining_timeout_ms()
            .map_err(map_public_ip_failure)
    }

    pub fn complete(
        &self,
        raw_body: String,
    ) -> Result<PublicIpObservationView, PublicIpProbeError> {
        self.inner
            .complete(&raw_body)
            .map(|observation| PublicIpObservationView {
                address: observation.address().to_string(),
                generation: observation.generation(),
            })
            .map_err(map_public_ip_failure)
    }

    pub fn effect_failed(&self, effect: PublicIpEffectFailure) -> Result<(), PublicIpProbeError> {
        Err(map_public_ip_failure(
            self.inner
                .effect_failed(map_public_ip_effect_failure(effect)),
        ))
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct AndroidDnsResolver;
impl CellularDnsResolver for AndroidDnsResolver {
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
        mish_android_network::resolve_host(authority, hostname)
            .map_err(map_android_network_error)?
            .into_iter()
            .map(|raw| {
                raw.parse::<IpAddr>()
                    .map_err(|_| ProxyOutboundConnectError::Failed)
            })
            .collect()
    }
}

pub(crate) struct CellularController {
    runtime: Arc<CellularRuntimeCoordinator>,
}

impl CellularController {
    pub(crate) fn from_runtime(runtime: Arc<CellularRuntimeCoordinator>) -> Self {
        Self { runtime }
    }

    pub(crate) fn admission_snapshot(
        &self,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        self.runtime
            .admission_snapshot()
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub(crate) fn dns_diagnostic_snapshot(&self) -> CellularDnsDiagnosticView {
        let snapshot = self.runtime.dns_diagnostic_snapshot();
        CellularDnsDiagnosticView {
            slow_threshold_ms: snapshot.slow_threshold_ms,
            started: snapshot.started,
            completed: snapshot.completed,
            active: snapshot.active,
            peak_active: snapshot.peak_active,
            slow_completions: snapshot.slow_completions,
            resolver_failed: snapshot.resolver_failed,
            discarded_after_deadline: snapshot.discarded_after_deadline,
            completed_after_owner_change: snapshot.completed_after_owner_change,
            discarded_stale: snapshot.discarded_stale,
            authority_validation_failed: snapshot.authority_validation_failed,
            unusable_result: snapshot.unusable_result,
            accepted_current: snapshot.accepted_current,
            max_native_elapsed_ms: snapshot.max_native_elapsed_ms,
            last_started_owner_sequence: snapshot.last_started_owner_sequence,
            last_completed_start_owner_sequence: snapshot.last_completed_start_owner_sequence,
            last_completed_current_owner_sequence: snapshot.last_completed_current_owner_sequence,
        }
    }

    pub(crate) fn prepare_public_ip_probe(
        &self,
        timeout_ms: u64,
    ) -> Result<Arc<PublicIpProbeTicket>, PublicIpProbeError> {
        self.runtime
            .prepare_public_ip_probe(Duration::from_millis(timeout_ms))
            .map(|inner| Arc::new(PublicIpProbeTicket { inner }))
            .map_err(map_public_ip_failure)
    }
}

pub(crate) fn map_snapshot(snapshot: OwnerAdmissionSnapshot) -> CellularAdmissionView {
    CellularAdmissionView {
        state: match snapshot.state() {
            OwnerAdmissionState::Unknown => CellularAdmissionState::Unknown,
            OwnerAdmissionState::NotAdmitted => CellularAdmissionState::NotAdmitted,
            OwnerAdmissionState::Admitted => CellularAdmissionState::Admitted,
        },
        reason: snapshot.reason().map(|reason| match reason {
            OwnerAdmissionReason::NoObservation => CellularAdmissionReason::NoObservation,
            OwnerAdmissionReason::NotCellular => CellularAdmissionReason::NotCellular,
            OwnerAdmissionReason::MissingInternetCapability => {
                CellularAdmissionReason::MissingInternetCapability
            }
            OwnerAdmissionReason::VpnDerivedNetwork => CellularAdmissionReason::VpnDerivedNetwork,
            OwnerAdmissionReason::NotValidated => CellularAdmissionReason::NotValidated,
            OwnerAdmissionReason::NetworkLost => CellularAdmissionReason::NetworkLost,
        }),
        admitted_network_handle: snapshot.admitted_network().map(NetworkHandle::raw),
        last_sequence: snapshot.last_sequence().map(ObservationSequence::raw),
    }
}

fn map_public_ip_effect_failure(
    effect: PublicIpEffectFailure,
) -> RuntimePublicIpProbeEffectFailure {
    match effect {
        PublicIpEffectFailure::SocketConnect => RuntimePublicIpProbeEffectFailure::SocketConnect,
        PublicIpEffectFailure::SocketTimeout => RuntimePublicIpProbeEffectFailure::SocketTimeout,
        PublicIpEffectFailure::TlsHandshake => RuntimePublicIpProbeEffectFailure::TlsHandshake,
        PublicIpEffectFailure::TlsHostname => RuntimePublicIpProbeEffectFailure::TlsHostname,
        PublicIpEffectFailure::HttpStatus => RuntimePublicIpProbeEffectFailure::HttpStatus,
        PublicIpEffectFailure::ResponseTooLarge => {
            RuntimePublicIpProbeEffectFailure::ResponseTooLarge
        }
        PublicIpEffectFailure::ResponseMalformed => {
            RuntimePublicIpProbeEffectFailure::ResponseMalformed
        }
        PublicIpEffectFailure::Io => RuntimePublicIpProbeEffectFailure::Io,
    }
}

pub(crate) fn map_public_ip_failure(failure: RuntimePublicIpProbeFailure) -> PublicIpProbeError {
    match failure {
        RuntimePublicIpProbeFailure::NoCurrentCellular => PublicIpProbeError::NoCurrentCellular,
        RuntimePublicIpProbeFailure::RootPolicyUnavailable => {
            PublicIpProbeError::RootPolicyUnavailable
        }
        RuntimePublicIpProbeFailure::DnsUnavailable => PublicIpProbeError::DnsUnavailable,
        RuntimePublicIpProbeFailure::DeadlineExceeded => PublicIpProbeError::DeadlineExceeded,
        RuntimePublicIpProbeFailure::StaleGeneration => PublicIpProbeError::StaleGeneration,
        RuntimePublicIpProbeFailure::InvalidResponse => PublicIpProbeError::InvalidResponse,
        RuntimePublicIpProbeFailure::SocketConnect => PublicIpProbeError::SocketConnect,
        RuntimePublicIpProbeFailure::SocketTimeout => PublicIpProbeError::SocketTimeout,
        RuntimePublicIpProbeFailure::TlsHandshake => PublicIpProbeError::TlsHandshake,
        RuntimePublicIpProbeFailure::TlsHostname => PublicIpProbeError::TlsHostname,
        RuntimePublicIpProbeFailure::HttpStatus => PublicIpProbeError::HttpStatus,
        RuntimePublicIpProbeFailure::ResponseTooLarge => PublicIpProbeError::ResponseTooLarge,
        RuntimePublicIpProbeFailure::ResponseMalformed => PublicIpProbeError::ResponseMalformed,
        RuntimePublicIpProbeFailure::Io => PublicIpProbeError::Io,
    }
}

fn map_android_network_error(error: AndroidNetworkError) -> ProxyOutboundConnectError {
    match error {
        AndroidNetworkError::InvalidHostname => ProxyOutboundConnectError::Rejected,
        AndroidNetworkError::UnsupportedPlatform => ProxyOutboundConnectError::Unavailable,
        AndroidNetworkError::NativeDnsLookupFailed
        | AndroidNetworkError::NativeDnsNoResults
        | AndroidNetworkError::NativeAddressConversionFailed => ProxyOutboundConnectError::Failed,
    }
}

