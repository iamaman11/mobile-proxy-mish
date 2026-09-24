use crate::readiness_ffi::ProductReadinessState;
use crate::runtime_boundary::{
    AndroidDnsResolver, CellularAdmissionReason, CellularAdmissionState, CellularAdmissionView,
    CellularBridgeError, CellularController, CellularDnsDiagnosticView, PublicIpObservationView,
    PublicIpProbeError, map_dns_diagnostic, map_public_ip_failure, map_snapshot,
};
use crate::runtime_lifecycle_ffi::{
    ProxyServingFailure, ProxyServingState, RuntimeLifecycleState, map_lifecycle_state,
    map_proxy_failure_out,
};
use crate::transport_ffi::{
    MeshAdmissionState, MeshAdmissionView, MeshTransportBoundaryError, map_transport_error,
    map_view as map_mesh_view,
};
use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence, RootPolicyNamespace};
use mish_control::RemoteRotationResult;
use mish_proxy::{ProxyProtocol as OwnerProxyProtocol, canonical_listeners};
use mish_rotation::{
    RotationFailure, RotationPhase, RotationRestoreResult, RotationSnapshot, RotationTerminalResult,
};
use mish_runtime::{
    CellularPolicyObserver, CellularPolicyPublication, CellularReconcileDiagnostic,
    CellularRequestRearmEffect, ControlAuthSignError, ControlAuthSigner,
    ControlOperationTimingSnapshot, ControlRuntimeSnapshot, ControlRuntimeStartError,
    ControlSessionState, MeshRuntimeObserver, ProductDiagnosticSnapshot, ProductRuntimeCoordinator,
    ProductRuntimeSnapshot, ProxyRuntimeObserver, ProxyRuntimePublication,
    ProxyServingState as OwnerProxyServingState, ReadinessDiagnosticSnapshot, ReadinessObserver,
    RootAuthorityStatus as OwnerRootAuthorityStatus, RootPolicyFailure as OwnerRootPolicyFailure,
    RootPolicyPhaseDiagnostic, RootPolicyPhaseDiagnostics, RootPolicyReconcileDiagnostic,
    RootPolicyResult as OwnerRootPolicyResult, RootRecoveryDiagnostic, RotationObserver,
    RotationRuntimeStartError, RotationRuntimeTimingSnapshot, RuntimeExecutionError,
};
use mish_transport::MeshVpnObservation;
use std::fmt;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum NativeProductRuntimeError {
    InvalidProductUid,
    ThreadUnavailable,
    StateUnavailable,
    CleanupFailed,
}

impl fmt::Display for NativeProductRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidProductUid => "PRODUCT Android UID must be positive",
            Self::ThreadUnavailable => "native PRODUCT executor threads are unavailable",
            Self::StateUnavailable => "native PRODUCT runtime state is unavailable",
            Self::CleanupFailed => "native PRODUCT root-policy cleanup failed",
        })
    }
}

impl std::error::Error for NativeProductRuntimeError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum NativeRotationStartError {
    RuntimeNotRunning,
    AlreadyInProgress,
    NoCurrentCellular,
    RootPolicyUnavailable,
    CredentialUnavailable,
    ExecutorUnavailable,
    StateUnavailable,
}

impl fmt::Display for NativeRotationStartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::RuntimeNotRunning => "PRODUCT runtime is not running",
            Self::AlreadyInProgress => "an IP rotation is already in progress",
            Self::NoCurrentCellular => "no current admitted Cellular generation",
            Self::RootPolicyUnavailable => {
                "root policy is not authorized for current Cellular generation"
            }
            Self::CredentialUnavailable => "current proxy credential is unavailable",
            Self::ExecutorUnavailable => "native PRODUCT executor is unavailable",
            Self::StateUnavailable => "native rotation state is unavailable",
        })
    }
}

impl std::error::Error for NativeRotationStartError {}

impl From<RotationRuntimeStartError> for NativeRotationStartError {
    fn from(error: RotationRuntimeStartError) -> Self {
        match error {
            RotationRuntimeStartError::RuntimeNotRunning => Self::RuntimeNotRunning,
            RotationRuntimeStartError::AlreadyInProgress => Self::AlreadyInProgress,
            RotationRuntimeStartError::NoCurrentCellular => Self::NoCurrentCellular,
            RotationRuntimeStartError::RootPolicyUnavailable => Self::RootPolicyUnavailable,
            RotationRuntimeStartError::CredentialUnavailable => Self::CredentialUnavailable,
            RotationRuntimeStartError::ExecutorUnavailable => Self::ExecutorUnavailable,
            RotationRuntimeStartError::StateUnavailable => Self::StateUnavailable,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum NativeControlStartError {
    AlreadyStarted,
    InvalidIdentity,
    ExecutorUnavailable,
    StateUnavailable,
}

impl fmt::Display for NativeControlStartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::AlreadyStarted => "control runtime is already started with another identity",
            Self::InvalidIdentity => "control public identity is invalid",
            Self::ExecutorUnavailable => "native PRODUCT executor is unavailable",
            Self::StateUnavailable => "native control state is unavailable",
        })
    }
}

impl std::error::Error for NativeControlStartError {}

impl From<ControlRuntimeStartError> for NativeControlStartError {
    fn from(error: ControlRuntimeStartError) -> Self {
        match error {
            ControlRuntimeStartError::AlreadyStarted => Self::AlreadyStarted,
            ControlRuntimeStartError::InvalidIdentity => Self::InvalidIdentity,
            ControlRuntimeStartError::ExecutorUnavailable => Self::ExecutorUnavailable,
            ControlRuntimeStartError::StateUnavailable => Self::StateUnavailable,
        }
    }
}

impl From<RuntimeExecutionError> for NativeProductRuntimeError {
    fn from(error: RuntimeExecutionError) -> Self {
        match error {
            RuntimeExecutionError::ThreadUnavailable => Self::ThreadUnavailable,
            RuntimeExecutionError::StateUnavailable => Self::StateUnavailable,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RootAuthorityStatusView {
    Ready,
    InteractiveGrantRequired,
    Denied,
    Unavailable,
    Incomplete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RootPolicyFailureView {
    InvalidInterface,
    ReservedPolicyCollision,
    ObservationUnavailable,
    ObservationIncomplete,
    StructuralMismatch,
    RouteTableDiscoveryFailed,
    MutationRejected,
    MutationUncertain,
    LookupRuleCreationFailed,
    RouteLookupVerificationFailed,
    ExactCleanupFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RootPolicyStateView {
    Enforced,
    FailClosed,
    AuthorityUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularNetworkObservationInput {
    pub sequence: u64,
    pub network_handle: u64,
    pub is_cellular: bool,
    pub has_internet: bool,
    pub is_validated: bool,
    pub is_not_vpn: bool,
    pub interface_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularPolicyPublicationView {
    pub admission: CellularAdmissionView,
    pub state: RootPolicyStateView,
    pub failure: Option<RootPolicyFailureView>,
    pub authority_status: Option<RootAuthorityStatusView>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CellularReconcileDiagnosticView {
    pub requested: u64,
    pub executed: u64,
    pub coalesced: u64,
    pub pending: bool,
    pub drain_scheduled: bool,
    pub last_owner_sequence: Option<u64>,
    pub last_dequeue_wait_ms: u64,
    pub max_dequeue_wait_ms: u64,
    pub last_quiesce_wait_ms: u64,
    pub max_quiesce_wait_ms: u64,
    pub stale_after_reconcile: u64,
    pub superseded_during_reconcile: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RootRecoveryDiagnosticView {
    pub pending: bool,
    pub attempts_since_reset: u32,
    pub next_delay_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RootPolicyPhaseDiagnosticView {
    pub elapsed_ms: u64,
    pub commands: u64,
    pub observation_commands: u64,
    pub mutation_commands: u64,
    pub duplicate_observations: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RootPolicyPhaseDiagnosticsView {
    pub initial_snapshot: RootPolicyPhaseDiagnosticView,
    pub fail_closed_prepare: RootPolicyPhaseDiagnosticView,
    pub fail_closed_verify: RootPolicyPhaseDiagnosticView,
    pub table_discovery: RootPolicyPhaseDiagnosticView,
    pub admitted_apply_verify: RootPolicyPhaseDiagnosticView,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RootPolicyReconcileDiagnosticView {
    pub attempts: u64,
    pub total_executor_commands: u64,
    pub total_observation_commands: u64,
    pub total_mutation_commands: u64,
    pub total_duplicate_observations: u64,
    pub last_reconcile_elapsed_ms: u64,
    pub max_reconcile_elapsed_ms: u64,
    pub last_policy_effect_elapsed_ms: u64,
    pub max_policy_effect_elapsed_ms: u64,
    pub last_executor_commands: u64,
    pub last_observation_commands: u64,
    pub last_mutation_commands: u64,
    pub last_duplicate_observations: u64,
    pub last_incomplete_or_timed_out_commands: u64,
    pub last_mutation_failures: u64,
    pub last_phases: RootPolicyPhaseDiagnosticsView,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ReadinessDiagnosticView {
    pub state: ProductReadinessState,
    pub root_policy_verified: bool,
    pub proxy_healthy: bool,
    pub credential_active: bool,
    pub mesh_admitted: bool,
    pub binding_eligible: bool,
    pub probe_in_flight: bool,
    pub refresh_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeLifecycleSnapshotView {
    pub state: RuntimeLifecycleState,
    pub generation: u64,
    pub generation_requires_replacement: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyProtocolView {
    Mixed,
    Socks5,
    HttpConnect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProxyListenerView {
    pub protocol: ProxyProtocolView,
    pub port: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProxyRuntimePublicationView {
    pub state: ProxyServingState,
    pub failure: Option<ProxyServingFailure>,
    pub serving_generation: Option<u64>,
    pub credential_version: Option<u64>,
    pub recovery_pending: bool,
    pub recovery_operation_id: u64,
    pub recovery_attempts_since_success: u32,
    pub recovery_next_delay_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RotationPhaseView {
    Idle,
    Preparing,
    AirplaneEnabling,
    WaitingRadioDown,
    AirplaneDisabling,
    WaitingCellularRecovery,
    WaitingRootPolicy,
    ProbingPublicIp,
    Changed,
    Unchanged,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RotationTerminalResultView {
    Changed,
    Unchanged,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RotationFailureView {
    RuntimeNotRunning,
    NoCurrentCellular,
    RootPolicyUnavailable,
    BeforeIpFailed,
    AirplaneEnableFailed,
    AirplaneObservationFailed,
    AirplaneDisableFailed,
    FreshCellularUnavailable,
    RootPolicyRecoveryFailed,
    AfterIpFailed,
    CredentialChanged,
    DeadlineExceeded,
    StateUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RotationRestoreResultView {
    NotRequired,
    AlreadyOff,
    RestoredOff,
    Failed,
    Uncertain,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RotationSnapshotView {
    pub operation_id: Option<u64>,
    pub phase: RotationPhaseView,
    pub before_generation: Option<u64>,
    pub after_generation: Option<u64>,
    pub before_ip: Option<String>,
    pub after_ip: Option<String>,
    pub restore_required: bool,
    pub terminal_result: Option<RotationTerminalResultView>,
    pub failure: Option<RotationFailureView>,
    pub restore_result: Option<RotationRestoreResultView>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ControlSessionStateView {
    Stopped,
    Connecting,
    Authenticating,
    Ready,
    Backoff,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteRotationResultView {
    Changed,
    Unchanged,
    Failed,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ControlOperationTimingView {
    pub operation_id: Option<u64>,
    pub operation_age_ms: Option<u64>,
    pub operation_reserved_ms: Option<u64>,
    pub accepted_sent_ms: Option<u64>,
    pub reconnect_started_ms: Option<u64>,
    pub reconnect_ready_ms: Option<u64>,
    pub rotation_terminal_ms: Option<u64>,
    pub result_sent_ms: Option<u64>,
    pub result_ack_ms: Option<u64>,
    pub rotation_origin_from_command_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RotationRuntimeTimingView {
    pub operation_id: Option<u64>,
    pub operation_age_ms: Option<u64>,
    pub activated_ms: Option<u64>,
    pub pre_rotation_probe_started_ms: Option<u64>,
    pub pre_rotation_probe_completed_ms: Option<u64>,
    pub airplane_enable_started_ms: Option<u64>,
    pub airplane_enable_effect_completed_ms: Option<u64>,
    pub airplane_on_observed_ms: Option<u64>,
    pub cellular_loss_observed_ms: Option<u64>,
    pub airplane_disable_started_ms: Option<u64>,
    pub airplane_disable_effect_completed_ms: Option<u64>,
    pub airplane_off_observed_ms: Option<u64>,
    pub cellular_request_rearm_started_ms: Option<u64>,
    pub cellular_request_rearm_completed_ms: Option<u64>,
    pub first_platform_cellular_observation_ms: Option<u64>,
    pub platform_cellular_observations_after_rearm: u64,
    pub fresh_cellular_observed_ms: Option<u64>,
    pub fresh_cellular_generation: Option<u64>,
    pub root_authorized_ms: Option<u64>,
    pub root_authorized_generation: Option<u64>,
    pub post_rotation_probe_started_ms: Option<u64>,
    pub post_rotation_probe_completed_ms: Option<u64>,
    pub terminal_ms: Option<u64>,
    pub restore_completed_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ControlRuntimeSnapshotView {
    pub state: ControlSessionStateView,
    pub reconnect_attempts: u32,
    pub reconnect_count: u64,
    pub next_delay_ms: u64,
    pub session_age_ms: Option<u64>,
    pub application_heartbeat_count: u64,
    pub payload_tx_bytes: u64,
    pub payload_rx_bytes: u64,
    pub last_tx_age_ms: Option<u64>,
    pub last_rx_age_ms: Option<u64>,
    pub pending_operation: bool,
    pub pending_operation_id: Option<u64>,
    pub last_terminal_result: Option<RemoteRotationResultView>,
    pub operation_timing: ControlOperationTimingView,
    pub rotation_timing: RotationRuntimeTimingView,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProductDiagnosticSnapshotView {
    pub consistent: bool,
    pub runtime_running: bool,
    pub runtime_generation: u64,
    pub runtime_active_tasks: u64,
    pub cellular_state: String,
    pub cellular_reason: String,
    pub cellular_admitted: bool,
    pub cellular_owner_sequence: Option<u64>,
    pub cellular_boundary_failure: Option<String>,
    pub cellular_reconcile: CellularReconcileDiagnosticView,
    pub dns: CellularDnsDiagnosticView,
    pub root_authority_observation: String,
    pub root_policy_authorized: bool,
    pub root_session_generation: Option<u64>,
    pub root_last_failure_class: Option<String>,
    pub root_policy_authorized_generation: Option<u64>,
    pub root_reconcile: RootPolicyReconcileDiagnosticView,
    pub root_recovery: RootRecoveryDiagnosticView,
    pub proxy_state: String,
    pub proxy_healthy: bool,
    pub proxy_failure: Option<String>,
    pub proxy_serving_generation: Option<u64>,
    pub proxy_active_sessions: u64,
    pub proxy_recovery_pending: bool,
    pub proxy_recovery_operation_id: u64,
    pub proxy_recovery_attempts_scheduled: u32,
    pub proxy_recovery_next_delay_ms: u64,
    pub credential_active: bool,
    pub credential_version: Option<u64>,
    pub mesh_state: String,
    pub mesh_admitted: bool,
    pub mesh_observation_sequence: Option<u64>,
    pub mesh_admission_epoch: Option<u64>,
    pub mesh_epoch_present: bool,
    pub mesh_ingress_running: bool,
    pub mesh_serving_generation: Option<u64>,
    pub mesh_ingress_failure: String,
    pub mesh_active_sessions: Option<u64>,
    pub mesh_capacity_rejects: Option<u64>,
    pub readiness_state: String,
    pub readiness_binding_eligible: bool,
    pub readiness_binding_cellular_owner_generation: Option<u64>,
    pub readiness_binding_runtime_generation: Option<u64>,
    pub readiness_binding_proxy_serving_generation: Option<u64>,
    pub readiness_binding_mesh_admission_epoch: Option<u64>,
    pub readiness_binding_credential_version: Option<u64>,
    pub readiness_expected_freshness: Option<u64>,
    pub readiness_observed_freshness: Option<u64>,
    pub readiness_probe_in_flight: bool,
    pub readiness_refresh_pending: bool,
    pub readiness_probe_state: String,
    pub rotation_state: String,
    pub rotation_operation_id: Option<u64>,
    pub rotation_before_generation: Option<u64>,
    pub rotation_after_generation: Option<u64>,
    pub rotation_restore_required: bool,
    pub rotation_terminal_result: Option<String>,
    pub rotation_failure: Option<String>,
    pub rotation_restore_result: Option<String>,
    pub rotation_active_tasks: u64,
}

#[uniffi::export(foreign)]
pub trait NativeProxyRuntimeObserver: Send + Sync {
    fn on_proxy_runtime(&self, publication: ProxyRuntimePublicationView);
}

#[uniffi::export(foreign)]
pub trait NativeReadinessObserver: Send + Sync {
    fn on_readiness(&self, readiness: ProductReadinessState);
}

#[uniffi::export(foreign)]
pub trait NativeRotationObserver: Send + Sync {
    fn on_rotation(&self, snapshot: RotationSnapshotView);
}

#[uniffi::export(foreign)]
pub trait NativeMeshRuntimeObserver: Send + Sync {
    fn on_mesh_runtime(&self, snapshot: MeshAdmissionView);
}

#[uniffi::export(foreign)]
pub trait NativeCellularPolicyObserver: Send + Sync {
    fn on_cellular_policy_publication(&self, publication: CellularPolicyPublicationView);
}

#[uniffi::export(foreign)]
pub trait NativeCellularRequestRearmEffect: Send + Sync {
    fn rearm_cellular_request(&self) -> bool;
}

#[uniffi::export(foreign)]
pub trait NativeControlAuthSigner: Send + Sync {
    /// Returns Android Keystore SHA256withECDSA DER bytes. Empty means signing failed closed.
    fn sign_control_auth(&self, payload: Vec<u8>) -> Vec<u8>;
}

struct ForeignCellularRequestRearmEffect {
    effect: Arc<dyn NativeCellularRequestRearmEffect>,
}

impl CellularRequestRearmEffect for ForeignCellularRequestRearmEffect {
    fn rearm_cellular_request(&self) -> bool {
        self.effect.rearm_cellular_request()
    }
}

struct ForeignControlAuthSigner {
    signer: Arc<dyn NativeControlAuthSigner>,
}

impl ControlAuthSigner for ForeignControlAuthSigner {
    fn sign_control_auth(&self, payload: &[u8]) -> Result<Vec<u8>, ControlAuthSignError> {
        let signature = self.signer.sign_control_auth(payload.to_vec());
        if signature.is_empty() {
            Err(ControlAuthSignError::SignFailed)
        } else {
            Ok(signature)
        }
    }
}

/// Stable opaque FFI handle over the Rust-owned PRODUCT process runtime.
///
/// ProductRuntimeCoordinator owns Tokio execution, lifecycle/generation replacement and native
/// composition. Kotlin supplies only Android platform facts/effects and consumes typed projections.
#[derive(uniffi::Object)]
pub struct NativeProductRuntime {
    runtime: Arc<ProductRuntimeCoordinator>,
}

#[uniffi::export]
impl NativeProductRuntime {
    #[uniffi::constructor]
    pub fn new(
        product_uid: u32,
        debug_isolation: bool,
    ) -> Result<Arc<Self>, NativeProductRuntimeError> {
        if product_uid == 0 {
            return Err(NativeProductRuntimeError::InvalidProductUid);
        }

        let namespace = if debug_isolation {
            RootPolicyNamespace::Debug
        } else {
            RootPolicyNamespace::Release
        };
        let runtime =
            ProductRuntimeCoordinator::new(Arc::new(AndroidDnsResolver), product_uid, namespace)?;

        Ok(Arc::new(Self { runtime }))
    }

    pub fn runtime_lifecycle_snapshot(&self) -> RuntimeLifecycleSnapshotView {
        map_runtime_snapshot(self.runtime.snapshot())
    }

    pub fn diagnostic_snapshot(
        &self,
    ) -> Result<ProductDiagnosticSnapshotView, NativeProductRuntimeError> {
        self.runtime
            .diagnostic_snapshot()
            .map(map_product_diagnostic_snapshot)
            .map_err(Into::into)
    }

    pub fn start_runtime(
        self: &Arc<Self>,
        credential_version: Option<u64>,
        username: Option<String>,
        password: Option<String>,
    ) -> Result<(), NativeProductRuntimeError> {
        self.runtime
            .request_start(credential_version, username, password)
            .map(|_| ())
            .map_err(Into::into)
    }

    pub fn stop_runtime(self: &Arc<Self>) -> Result<(), NativeProductRuntimeError> {
        self.runtime.request_stop().map(|_| ()).map_err(Into::into)
    }

    pub fn start_public_ip_rotation(
        self: &Arc<Self>,
        cellular_request_rearm: Arc<dyn NativeCellularRequestRearmEffect>,
    ) -> Result<u64, NativeRotationStartError> {
        self.runtime
            .start_public_ip_rotation(Arc::new(ForeignCellularRequestRearmEffect {
                effect: cellular_request_rearm,
            }))
            .map_err(Into::into)
    }

    pub fn rotation_snapshot(&self) -> RotationSnapshotView {
        map_rotation_snapshot(self.runtime.rotation_snapshot())
    }

    pub fn start_remote_control(
        self: &Arc<Self>,
        public_key_spki: Vec<u8>,
        signer: Arc<dyn NativeControlAuthSigner>,
        cellular_request_rearm: Arc<dyn NativeCellularRequestRearmEffect>,
    ) -> Result<String, NativeControlStartError> {
        self.runtime
            .start_remote_control(
                public_key_spki,
                Arc::new(ForeignControlAuthSigner { signer }),
                Arc::new(ForeignCellularRequestRearmEffect {
                    effect: cellular_request_rearm,
                }),
            )
            .map_err(Into::into)
    }

    pub fn control_snapshot(&self) -> ControlRuntimeSnapshotView {
        map_control_snapshot(self.runtime.control_snapshot())
    }

    pub fn observe_rotation(&self, observer: Arc<dyn NativeRotationObserver>) {
        let callback: RotationObserver = Arc::new(move |snapshot| {
            observer.on_rotation(map_rotation_snapshot(snapshot));
        });
        self.runtime.set_rotation_observer(callback);
    }

    pub fn begin_stopped_platform_mutation(
        &self,
    ) -> Result<Option<u64>, NativeProductRuntimeError> {
        self.runtime
            .begin_stopped_platform_mutation()
            .map_err(Into::into)
    }

    pub fn complete_stopped_platform_mutation(
        &self,
        lease: u64,
        succeeded: bool,
    ) -> Result<bool, NativeProductRuntimeError> {
        self.runtime
            .complete_stopped_platform_mutation(lease, succeeded)
            .map_err(Into::into)
    }

    pub fn observe_cellular_policy(&self, observer: Arc<dyn NativeCellularPolicyObserver>) {
        let callback: CellularPolicyObserver = Arc::new(move |publication| {
            observer.on_cellular_policy_publication(map_policy_publication(publication));
        });
        self.runtime.set_cellular_observer(callback);
    }

    pub fn observe_readiness(&self, observer: Arc<dyn NativeReadinessObserver>) {
        let callback: ReadinessObserver = Arc::new(move |readiness| {
            observer.on_readiness(map_readiness_state(readiness));
        });
        self.runtime.set_readiness_observer(callback);
    }

    pub fn readiness_snapshot(&self) -> ProductReadinessState {
        self.runtime
            .current_generation()
            .map(|generation| map_readiness_state(generation.readiness().snapshot()))
            .unwrap_or(ProductReadinessState::Unknown)
    }

    pub fn observe_proxy_runtime(&self, observer: Arc<dyn NativeProxyRuntimeObserver>) {
        let callback: ProxyRuntimeObserver = Arc::new(move |publication| {
            observer.on_proxy_runtime(map_proxy_publication(publication));
        });
        self.runtime.set_proxy_observer(callback);
    }

    pub fn proxy_runtime_snapshot(&self) -> ProxyRuntimePublicationView {
        self.runtime
            .current_generation()
            .map(|generation| map_proxy_publication(generation.proxy().snapshot()))
            .unwrap_or_else(|_| unavailable_proxy_publication())
    }

    pub fn proxy_listener_contract(&self) -> Vec<ProxyListenerView> {
        canonical_listeners()
            .iter()
            .map(|listener| ProxyListenerView {
                protocol: match listener.protocol {
                    OwnerProxyProtocol::Mixed => ProxyProtocolView::Mixed,
                    OwnerProxyProtocol::Socks5 => ProxyProtocolView::Socks5,
                    OwnerProxyProtocol::Http => ProxyProtocolView::HttpConnect,
                },
                port: listener.port,
            })
            .collect()
    }

    pub fn admission_snapshot(&self) -> Result<CellularAdmissionView, CellularBridgeError> {
        let generation = self
            .runtime
            .current_generation()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)?;
        CellularController::from_runtime(generation.cellular()).admission_snapshot()
    }

    pub fn observe_network(
        &self,
        input: CellularNetworkObservationInput,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(input.sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle = NetworkHandle::new(input.network_handle)
            .ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        let observation = NetworkObservation::new(
            sequence,
            network_handle,
            input.is_cellular,
            input.has_internet,
            input.is_validated,
            input.is_not_vpn,
        );
        self.runtime
            .observe_network(
                sequence.raw(),
                observation,
                network_handle,
                input.interface_name,
            )
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn network_lost(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        self.runtime
            .network_lost(sequence.raw(), network_handle)
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn invalidate_cellular_platform_facts(&self) -> Result<(), NativeProductRuntimeError> {
        self.runtime
            .invalidate_cellular_platform_facts()
            .map_err(Into::into)
    }

    pub fn observe_public_egress_ip(
        &self,
        timeout_ms: u64,
    ) -> Result<PublicIpObservationView, PublicIpProbeError> {
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| PublicIpProbeError::NoCurrentCellular)?;
        generation
            .cellular()
            .observe_public_egress_ip(&generation.executor(), Duration::from_millis(timeout_ms))
            .map(|observation| PublicIpObservationView {
                address: observation.address().to_string(),
                generation: observation.generation(),
            })
            .map_err(map_public_ip_failure)
    }

    pub fn invalidate_mesh_platform_fact(&self) -> Result<(), NativeProductRuntimeError> {
        self.runtime
            .invalidate_mesh_platform_fact()
            .map_err(Into::into)
    }

    pub fn observe_mesh_runtime(&self, observer: Arc<dyn NativeMeshRuntimeObserver>) {
        let callback: MeshRuntimeObserver = Arc::new(move |snapshot| {
            observer.on_mesh_runtime(map_mesh_view(snapshot));
        });
        self.runtime.set_mesh_observer(callback);
    }

    pub fn mesh_admission_snapshot(&self) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let generation = self
            .runtime
            .current_generation()
            .map_err(|_| MeshTransportBoundaryError::OwnerUnavailable)?;
        generation
            .mesh()
            .snapshot()
            .map(map_mesh_view)
            .map_err(map_transport_error)
    }

    pub fn observe_mesh_vpn_absent(
        &self,
        sequence: u64,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        self.runtime
            .observe_mesh_vpn(sequence, MeshVpnObservation::Absent)
            .map(map_mesh_view)
            .map_err(map_transport_error)
    }

    pub fn observe_mesh_unique_vpn(
        &self,
        sequence: u64,
        local_ipv4: Vec<String>,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let addresses = local_ipv4
            .into_iter()
            .map(|raw| {
                raw.parse::<Ipv4Addr>()
                    .map_err(|_| MeshTransportBoundaryError::InvalidVpnObservation)
            })
            .collect::<Result<Vec<_>, _>>()?;
        self.runtime
            .observe_mesh_vpn(
                sequence,
                MeshVpnObservation::UniqueVpn {
                    local_ipv4: addresses,
                },
            )
            .map(map_mesh_view)
            .map_err(map_transport_error)
    }

    pub fn observe_mesh_vpn_ambiguous(
        &self,
        sequence: u64,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        self.runtime
            .observe_mesh_vpn(sequence, MeshVpnObservation::AmbiguousVpn)
            .map(map_mesh_view)
            .map_err(map_transport_error)
    }

    pub fn shutdown(self: &Arc<Self>) -> Result<(), NativeProductRuntimeError> {
        if self.runtime.shutdown_blocking()? {
            Ok(())
        } else {
            Err(NativeProductRuntimeError::CleanupFailed)
        }
    }

    pub fn is_running(&self) -> bool {
        matches!(
            self.runtime.snapshot().state,
            mish_runtime::RuntimeLifecycleState::Starting
                | mish_runtime::RuntimeLifecycleState::Running
        )
    }
}

fn map_product_diagnostic_snapshot(
    snapshot: ProductDiagnosticSnapshot,
) -> ProductDiagnosticSnapshotView {
    let generation = snapshot.generation;
    let admission = map_snapshot(generation.cellular_admission);
    let cellular_owner_sequence = admission.last_sequence;
    let root_publication = generation.root_publication;
    let root_result = root_publication.map(|publication| publication.result);
    let root_publication_current = root_publication.is_some_and(|publication| {
        publication
            .admission
            .last_sequence()
            .map(|sequence| sequence.raw())
            == cellular_owner_sequence
    });
    let current_root_result = root_publication_current.then_some(root_result).flatten();
    let boundary_failure = cellular_boundary_failure(current_root_result);
    let cellular_state = cellular_admission_state_code(admission.state).to_owned();
    let cellular_reason = admission
        .reason
        .map(cellular_admission_reason_code)
        .unwrap_or("NONE")
        .to_owned();
    let cellular_admitted = admission.state == CellularAdmissionState::Admitted;

    let root_policy_authorized_generation = root_publication.and_then(|publication| {
        matches!(publication.result, OwnerRootPolicyResult::Enforced)
            .then_some(publication.admission.last_sequence())
            .flatten()
            .map(|sequence| sequence.raw())
    });
    let root_policy_authorized = cellular_admitted
        && cellular_owner_sequence.is_some()
        && root_policy_authorized_generation == cellular_owner_sequence;
    let root_authority_observation = match current_root_result {
        Some(OwnerRootPolicyResult::Enforced) => "READY_AT_POLICY_AUTHORIZATION",
        Some(OwnerRootPolicyResult::AuthorityUnavailable(_)) => "UNAVAILABLE",
        _ => "NOT_OBSERVED",
    };
    let root_last_failure_class = root_result.and_then(root_failure_class).map(str::to_owned);

    let proxy = map_proxy_publication(generation.proxy);
    let proxy_state = proxy_state_code(proxy.state).to_owned();
    let proxy_healthy = proxy.state == ProxyServingState::Running && proxy.failure.is_none();
    let proxy_failure = proxy.failure.map(proxy_failure_code).map(str::to_owned);

    let mesh = generation.mesh.map(map_mesh_view);
    let mesh_state = mesh
        .as_ref()
        .map(|snapshot| mesh_state_code(snapshot.state))
        .unwrap_or("ABSENT")
        .to_owned();
    let mesh_admitted = mesh
        .as_ref()
        .is_some_and(|snapshot| snapshot.state == MeshAdmissionState::Admitted);
    let mesh_observation_sequence = mesh.as_ref().and_then(|snapshot| snapshot.last_sequence);
    let mesh_admission_epoch = mesh.as_ref().and_then(|snapshot| snapshot.admission_epoch);
    let mesh_epoch_present = mesh_admission_epoch.is_some();
    let mesh_ingress_running = mesh
        .as_ref()
        .is_some_and(|snapshot| snapshot.ingress_running);
    let mesh_serving_generation = mesh_ingress_running
        .then_some(mesh_admission_epoch)
        .flatten();
    let mesh_active_sessions = mesh.as_ref().map(|snapshot| snapshot.active_sessions);
    let mesh_capacity_rejects = mesh.as_ref().map(|snapshot| snapshot.capacity_rejects);

    let readiness_owner = generation.readiness;
    let readiness = map_readiness_diagnostic(readiness_owner);
    let readiness_state = readiness_state_code(readiness.state).to_owned();
    let readiness_probe_state = readiness_probe_state_code(readiness.state).to_owned();
    let readiness_binding_cellular_owner_generation = readiness_owner
        .binding
        .map(|binding| binding.cellular_owner_generation.raw());
    let readiness_binding_runtime_generation = readiness_owner
        .binding
        .map(|binding| binding.runtime_generation.raw());
    let readiness_binding_proxy_serving_generation = readiness_owner
        .binding
        .map(|binding| binding.proxy_serving_generation.raw());
    let readiness_binding_mesh_admission_epoch = readiness_owner
        .binding
        .map(|binding| binding.mesh_admission_epoch.raw());
    let readiness_binding_credential_version = readiness_owner
        .binding
        .map(|binding| binding.credential_version.raw());
    let readiness_expected_freshness = readiness_owner
        .expected_freshness
        .map(|freshness| freshness.raw());
    let readiness_observed_freshness = readiness_owner
        .observed_freshness
        .map(|freshness| freshness.raw());

    let rotation = generation.rotation;

    ProductDiagnosticSnapshotView {
        consistent: snapshot.consistent,
        runtime_running: snapshot.runtime.state != mish_runtime::RuntimeLifecycleState::Stopped,
        runtime_generation: snapshot.runtime.generation,
        runtime_active_tasks: snapshot.runtime.active_tasks,
        cellular_state,
        cellular_reason,
        cellular_admitted,
        cellular_owner_sequence,
        cellular_boundary_failure: boundary_failure.map(str::to_owned),
        cellular_reconcile: map_reconcile_diagnostic(generation.cellular_reconcile),
        dns: map_dns_diagnostic(generation.dns),
        root_authority_observation: root_authority_observation.to_owned(),
        root_policy_authorized,
        root_session_generation: generation.root_session_generation,
        root_last_failure_class,
        root_policy_authorized_generation,
        root_reconcile: map_root_policy_diagnostic(generation.root_reconcile),
        root_recovery: map_recovery_diagnostic(generation.root_recovery),
        proxy_state,
        proxy_healthy,
        proxy_failure,
        proxy_serving_generation: proxy.serving_generation,
        proxy_active_sessions: u64::from(generation.proxy_active_sessions),
        proxy_recovery_pending: proxy.recovery_pending,
        proxy_recovery_operation_id: proxy.recovery_operation_id,
        proxy_recovery_attempts_scheduled: proxy.recovery_attempts_since_success,
        proxy_recovery_next_delay_ms: proxy.recovery_next_delay_ms,
        credential_active: generation.readiness.credential_active,
        credential_version: proxy.credential_version,
        mesh_state,
        mesh_admitted,
        mesh_observation_sequence,
        mesh_admission_epoch,
        mesh_epoch_present,
        mesh_ingress_running,
        mesh_serving_generation,
        mesh_ingress_failure: mesh_failure_code(generation.mesh_failure).to_owned(),
        mesh_active_sessions,
        mesh_capacity_rejects,
        readiness_state,
        readiness_binding_eligible: readiness.binding_eligible,
        readiness_binding_cellular_owner_generation,
        readiness_binding_runtime_generation,
        readiness_binding_proxy_serving_generation,
        readiness_binding_mesh_admission_epoch,
        readiness_binding_credential_version,
        readiness_expected_freshness,
        readiness_observed_freshness,
        readiness_probe_in_flight: readiness.probe_in_flight,
        readiness_refresh_pending: readiness.refresh_pending,
        readiness_probe_state,
        rotation_state: rotation_phase_code(rotation.phase).to_owned(),
        rotation_operation_id: rotation.operation_id,
        rotation_before_generation: rotation.before_generation,
        rotation_after_generation: rotation.after_generation,
        rotation_restore_required: rotation.restore_required,
        rotation_terminal_result: rotation
            .terminal_result
            .map(rotation_terminal_code)
            .map(str::to_owned),
        rotation_failure: rotation
            .failure
            .map(rotation_failure_code)
            .map(str::to_owned),
        rotation_restore_result: rotation
            .restore_result
            .map(rotation_restore_code)
            .map(str::to_owned),
        rotation_active_tasks: u64::from(generation.rotation_active_tasks),
    }
}

fn map_control_snapshot(snapshot: ControlRuntimeSnapshot) -> ControlRuntimeSnapshotView {
    ControlRuntimeSnapshotView {
        state: match snapshot.state {
            ControlSessionState::Stopped => ControlSessionStateView::Stopped,
            ControlSessionState::Connecting => ControlSessionStateView::Connecting,
            ControlSessionState::Authenticating => ControlSessionStateView::Authenticating,
            ControlSessionState::Ready => ControlSessionStateView::Ready,
            ControlSessionState::Backoff => ControlSessionStateView::Backoff,
        },
        reconnect_attempts: snapshot.reconnect_attempts,
        reconnect_count: snapshot.reconnect_count,
        next_delay_ms: snapshot.next_delay_ms,
        session_age_ms: snapshot.session_age_ms,
        application_heartbeat_count: snapshot.application_heartbeat_count,
        payload_tx_bytes: snapshot.payload_tx_bytes,
        payload_rx_bytes: snapshot.payload_rx_bytes,
        last_tx_age_ms: snapshot.last_tx_age_ms,
        last_rx_age_ms: snapshot.last_rx_age_ms,
        pending_operation: snapshot.pending_operation,
        pending_operation_id: snapshot.pending_operation_id,
        last_terminal_result: snapshot.last_terminal_result.map(|result| match result {
            RemoteRotationResult::Changed => RemoteRotationResultView::Changed,
            RemoteRotationResult::Unchanged => RemoteRotationResultView::Unchanged,
            RemoteRotationResult::Failed => RemoteRotationResultView::Failed,
            RemoteRotationResult::Rejected => RemoteRotationResultView::Rejected,
        }),
        operation_timing: map_control_operation_timing(snapshot.operation_timing),
        rotation_timing: map_rotation_runtime_timing(snapshot.rotation_timing),
    }
}

fn map_control_operation_timing(
    timing: ControlOperationTimingSnapshot,
) -> ControlOperationTimingView {
    ControlOperationTimingView {
        operation_id: timing.operation_id,
        operation_age_ms: timing.operation_age_ms,
        operation_reserved_ms: timing.operation_reserved_ms,
        accepted_sent_ms: timing.accepted_sent_ms,
        reconnect_started_ms: timing.reconnect_started_ms,
        reconnect_ready_ms: timing.reconnect_ready_ms,
        rotation_terminal_ms: timing.rotation_terminal_ms,
        result_sent_ms: timing.result_sent_ms,
        result_ack_ms: timing.result_ack_ms,
        rotation_origin_from_command_ms: timing.rotation_origin_from_command_ms,
    }
}

fn map_rotation_runtime_timing(timing: RotationRuntimeTimingSnapshot) -> RotationRuntimeTimingView {
    RotationRuntimeTimingView {
        operation_id: timing.operation_id,
        operation_age_ms: timing.operation_age_ms,
        activated_ms: timing.activated_ms,
        pre_rotation_probe_started_ms: timing.pre_rotation_probe_started_ms,
        pre_rotation_probe_completed_ms: timing.pre_rotation_probe_completed_ms,
        airplane_enable_started_ms: timing.airplane_enable_started_ms,
        airplane_enable_effect_completed_ms: timing.airplane_enable_effect_completed_ms,
        airplane_on_observed_ms: timing.airplane_on_observed_ms,
        cellular_loss_observed_ms: timing.cellular_loss_observed_ms,
        airplane_disable_started_ms: timing.airplane_disable_started_ms,
        airplane_disable_effect_completed_ms: timing.airplane_disable_effect_completed_ms,
        airplane_off_observed_ms: timing.airplane_off_observed_ms,
        cellular_request_rearm_started_ms: timing.cellular_request_rearm_started_ms,
        cellular_request_rearm_completed_ms: timing.cellular_request_rearm_completed_ms,
        first_platform_cellular_observation_ms: timing.first_platform_cellular_observation_ms,
        platform_cellular_observations_after_rearm: timing
            .platform_cellular_observations_after_rearm,
        fresh_cellular_observed_ms: timing.fresh_cellular_observed_ms,
        fresh_cellular_generation: timing.fresh_cellular_generation,
        root_authorized_ms: timing.root_authorized_ms,
        root_authorized_generation: timing.root_authorized_generation,
        post_rotation_probe_started_ms: timing.post_rotation_probe_started_ms,
        post_rotation_probe_completed_ms: timing.post_rotation_probe_completed_ms,
        terminal_ms: timing.terminal_ms,
        restore_completed_ms: timing.restore_completed_ms,
    }
}

fn map_rotation_snapshot(snapshot: RotationSnapshot) -> RotationSnapshotView {
    RotationSnapshotView {
        operation_id: snapshot.operation_id,
        phase: map_rotation_phase(snapshot.phase),
        before_generation: snapshot.before_generation,
        after_generation: snapshot.after_generation,
        before_ip: snapshot.before_ip.map(|address| address.to_string()),
        after_ip: snapshot.after_ip.map(|address| address.to_string()),
        restore_required: snapshot.restore_required,
        terminal_result: snapshot.terminal_result.map(map_rotation_terminal),
        failure: snapshot.failure.map(map_rotation_failure),
        restore_result: snapshot.restore_result.map(map_rotation_restore),
    }
}

fn map_rotation_phase(phase: RotationPhase) -> RotationPhaseView {
    match phase {
        RotationPhase::Idle => RotationPhaseView::Idle,
        RotationPhase::Preparing => RotationPhaseView::Preparing,
        RotationPhase::AirplaneEnabling => RotationPhaseView::AirplaneEnabling,
        RotationPhase::WaitingRadioDown => RotationPhaseView::WaitingRadioDown,
        RotationPhase::AirplaneDisabling => RotationPhaseView::AirplaneDisabling,
        RotationPhase::WaitingCellularRecovery => RotationPhaseView::WaitingCellularRecovery,
        RotationPhase::WaitingRootPolicy => RotationPhaseView::WaitingRootPolicy,
        RotationPhase::ProbingPublicIp => RotationPhaseView::ProbingPublicIp,
        RotationPhase::Changed => RotationPhaseView::Changed,
        RotationPhase::Unchanged => RotationPhaseView::Unchanged,
        RotationPhase::Failed => RotationPhaseView::Failed,
    }
}

fn map_rotation_terminal(result: RotationTerminalResult) -> RotationTerminalResultView {
    match result {
        RotationTerminalResult::Changed => RotationTerminalResultView::Changed,
        RotationTerminalResult::Unchanged => RotationTerminalResultView::Unchanged,
        RotationTerminalResult::Failed => RotationTerminalResultView::Failed,
    }
}

fn map_rotation_failure(failure: RotationFailure) -> RotationFailureView {
    match failure {
        RotationFailure::RuntimeNotRunning => RotationFailureView::RuntimeNotRunning,
        RotationFailure::NoCurrentCellular => RotationFailureView::NoCurrentCellular,
        RotationFailure::RootPolicyUnavailable => RotationFailureView::RootPolicyUnavailable,
        RotationFailure::BeforeIpFailed => RotationFailureView::BeforeIpFailed,
        RotationFailure::AirplaneEnableFailed => RotationFailureView::AirplaneEnableFailed,
        RotationFailure::AirplaneObservationFailed => {
            RotationFailureView::AirplaneObservationFailed
        }
        RotationFailure::AirplaneDisableFailed => RotationFailureView::AirplaneDisableFailed,
        RotationFailure::FreshCellularUnavailable => RotationFailureView::FreshCellularUnavailable,
        RotationFailure::RootPolicyRecoveryFailed => RotationFailureView::RootPolicyRecoveryFailed,
        RotationFailure::AfterIpFailed => RotationFailureView::AfterIpFailed,
        RotationFailure::CredentialChanged => RotationFailureView::CredentialChanged,
        RotationFailure::DeadlineExceeded => RotationFailureView::DeadlineExceeded,
        RotationFailure::StateUnavailable => RotationFailureView::StateUnavailable,
    }
}

fn map_rotation_restore(result: RotationRestoreResult) -> RotationRestoreResultView {
    match result {
        RotationRestoreResult::NotRequired => RotationRestoreResultView::NotRequired,
        RotationRestoreResult::AlreadyOff => RotationRestoreResultView::AlreadyOff,
        RotationRestoreResult::RestoredOff => RotationRestoreResultView::RestoredOff,
        RotationRestoreResult::Failed => RotationRestoreResultView::Failed,
        RotationRestoreResult::Uncertain => RotationRestoreResultView::Uncertain,
    }
}

fn rotation_phase_code(phase: RotationPhase) -> &'static str {
    match phase {
        RotationPhase::Idle => "IDLE",
        RotationPhase::Preparing => "PREPARING",
        RotationPhase::AirplaneEnabling => "AIRPLANE_ENABLING",
        RotationPhase::WaitingRadioDown => "WAITING_RADIO_DOWN",
        RotationPhase::AirplaneDisabling => "AIRPLANE_DISABLING",
        RotationPhase::WaitingCellularRecovery => "WAITING_CELLULAR_RECOVERY",
        RotationPhase::WaitingRootPolicy => "WAITING_ROOT_POLICY",
        RotationPhase::ProbingPublicIp => "PROBING_PUBLIC_IP",
        RotationPhase::Changed => "CHANGED",
        RotationPhase::Unchanged => "UNCHANGED",
        RotationPhase::Failed => "FAILED",
    }
}

fn rotation_terminal_code(result: RotationTerminalResult) -> &'static str {
    match result {
        RotationTerminalResult::Changed => "CHANGED",
        RotationTerminalResult::Unchanged => "UNCHANGED",
        RotationTerminalResult::Failed => "FAILED",
    }
}

fn rotation_failure_code(failure: RotationFailure) -> &'static str {
    match failure {
        RotationFailure::RuntimeNotRunning => "RUNTIME_NOT_RUNNING",
        RotationFailure::NoCurrentCellular => "NO_CURRENT_CELLULAR",
        RotationFailure::RootPolicyUnavailable => "ROOT_POLICY_UNAVAILABLE",
        RotationFailure::BeforeIpFailed => "BEFORE_IP_FAILED",
        RotationFailure::AirplaneEnableFailed => "AIRPLANE_ENABLE_FAILED",
        RotationFailure::AirplaneObservationFailed => "AIRPLANE_OBSERVATION_FAILED",
        RotationFailure::AirplaneDisableFailed => "AIRPLANE_DISABLE_FAILED",
        RotationFailure::FreshCellularUnavailable => "FRESH_CELLULAR_UNAVAILABLE",
        RotationFailure::RootPolicyRecoveryFailed => "ROOT_POLICY_RECOVERY_FAILED",
        RotationFailure::AfterIpFailed => "AFTER_IP_FAILED",
        RotationFailure::CredentialChanged => "CREDENTIAL_CHANGED",
        RotationFailure::DeadlineExceeded => "DEADLINE_EXCEEDED",
        RotationFailure::StateUnavailable => "STATE_UNAVAILABLE",
    }
}

fn rotation_restore_code(result: RotationRestoreResult) -> &'static str {
    match result {
        RotationRestoreResult::NotRequired => "NOT_REQUIRED",
        RotationRestoreResult::AlreadyOff => "ALREADY_OFF",
        RotationRestoreResult::RestoredOff => "RESTORED_OFF",
        RotationRestoreResult::Failed => "FAILED",
        RotationRestoreResult::Uncertain => "UNCERTAIN",
    }
}

fn root_failure_class(result: OwnerRootPolicyResult) -> Option<&'static str> {
    match result {
        OwnerRootPolicyResult::Enforced | OwnerRootPolicyResult::FailClosed(None) => None,
        OwnerRootPolicyResult::AuthorityUnavailable(status) => Some(match status {
            OwnerRootAuthorityStatus::Ready => "AUTHORITY_READY",
            OwnerRootAuthorityStatus::InteractiveGrantRequired => {
                "AUTHORITY_INTERACTIVE_GRANT_REQUIRED"
            }
            OwnerRootAuthorityStatus::Denied => "AUTHORITY_DENIED",
            OwnerRootAuthorityStatus::Unavailable => "AUTHORITY_UNAVAILABLE",
            OwnerRootAuthorityStatus::Incomplete => "AUTHORITY_INCOMPLETE",
        }),
        OwnerRootPolicyResult::FailClosed(Some(failure)) => Some(match failure {
            OwnerRootPolicyFailure::InvalidInterface => "INVALID_INTERFACE",
            OwnerRootPolicyFailure::ReservedPolicyCollision => "RESERVED_POLICY_COLLISION",
            OwnerRootPolicyFailure::ObservationUnavailable => "OBSERVATION_UNAVAILABLE",
            OwnerRootPolicyFailure::ObservationIncomplete => "OBSERVATION_INCOMPLETE",
            OwnerRootPolicyFailure::StructuralMismatch => "STRUCTURAL_MISMATCH",
            OwnerRootPolicyFailure::RouteTableDiscoveryFailed => "ROUTE_TABLE_DISCOVERY_FAILED",
            OwnerRootPolicyFailure::MutationRejected => "MUTATION_REJECTED",
            OwnerRootPolicyFailure::MutationUncertain => "MUTATION_UNCERTAIN",
            OwnerRootPolicyFailure::LookupRuleCreationFailed => "LOOKUP_RULE_CREATION_FAILED",
            OwnerRootPolicyFailure::RouteLookupVerificationFailed => {
                "ROUTE_LOOKUP_VERIFICATION_FAILED"
            }
            OwnerRootPolicyFailure::ExactCleanupFailed => "EXACT_CLEANUP_FAILED",
        }),
    }
}

fn cellular_boundary_failure(result: Option<OwnerRootPolicyResult>) -> Option<&'static str> {
    match result {
        Some(OwnerRootPolicyResult::AuthorityUnavailable(_)) => Some("ROOT_AUTHORITY_UNAVAILABLE"),
        Some(OwnerRootPolicyResult::FailClosed(Some(failure))) => Some(match failure {
            OwnerRootPolicyFailure::InvalidInterface => "ROOT_POLICY_INVALID_INTERFACE",
            OwnerRootPolicyFailure::ReservedPolicyCollision => {
                "ROOT_POLICY_RESERVED_POLICY_COLLISION"
            }
            OwnerRootPolicyFailure::ObservationUnavailable => "ROOT_POLICY_OBSERVATION_UNAVAILABLE",
            OwnerRootPolicyFailure::ObservationIncomplete => "ROOT_POLICY_OBSERVATION_INCOMPLETE",
            OwnerRootPolicyFailure::StructuralMismatch => "ROOT_POLICY_STRUCTURAL_MISMATCH",
            OwnerRootPolicyFailure::RouteTableDiscoveryFailed => {
                "ROOT_POLICY_ROUTE_TABLE_DISCOVERY_FAILED"
            }
            OwnerRootPolicyFailure::MutationRejected => "ROOT_POLICY_MUTATION_REJECTED",
            OwnerRootPolicyFailure::MutationUncertain => "ROOT_POLICY_MUTATION_UNCERTAIN",
            OwnerRootPolicyFailure::LookupRuleCreationFailed => {
                "ROOT_POLICY_LOOKUP_RULE_CREATION_FAILED"
            }
            OwnerRootPolicyFailure::RouteLookupVerificationFailed => {
                "ROOT_POLICY_ROUTE_LOOKUP_VERIFICATION_FAILED"
            }
            OwnerRootPolicyFailure::ExactCleanupFailed => "ROOT_POLICY_EXACT_CLEANUP_FAILED",
        }),
        _ => None,
    }
}

fn cellular_admission_state_code(state: CellularAdmissionState) -> &'static str {
    match state {
        CellularAdmissionState::Unknown => "UNKNOWN",
        CellularAdmissionState::NotAdmitted => "NOT_ADMITTED",
        CellularAdmissionState::Admitted => "ADMITTED",
    }
}

fn cellular_admission_reason_code(reason: CellularAdmissionReason) -> &'static str {
    match reason {
        CellularAdmissionReason::NoObservation => "NO_OBSERVATION",
        CellularAdmissionReason::NotCellular => "NOT_CELLULAR",
        CellularAdmissionReason::MissingInternetCapability => "MISSING_INTERNET_CAPABILITY",
        CellularAdmissionReason::VpnDerivedNetwork => "VPN_DERIVED_NETWORK",
        CellularAdmissionReason::NotValidated => "NOT_VALIDATED",
        CellularAdmissionReason::NetworkLost => "NETWORK_LOST",
    }
}

fn proxy_state_code(state: ProxyServingState) -> &'static str {
    match state {
        ProxyServingState::Stopped => "STOPPED",
        ProxyServingState::Starting => "STARTING",
        ProxyServingState::Running => "RUNNING",
        ProxyServingState::Failed => "FAILED",
    }
}

fn proxy_failure_code(failure: ProxyServingFailure) -> &'static str {
    match failure {
        ProxyServingFailure::NativeRuntimeMissing => "NATIVE_RUNTIME_MISSING",
        ProxyServingFailure::ExternalCredentialUnavailable => "EXTERNAL_CREDENTIAL_UNAVAILABLE",
        ProxyServingFailure::CellularConnectorUnavailable => "CELLULAR_CONNECTOR_UNAVAILABLE",
        ProxyServingFailure::ProxyConfigurationRejected => "PROXY_CONFIGURATION_REJECTED",
        ProxyServingFailure::MixedListenerUnavailable => "MIXED_LISTENER_UNAVAILABLE",
        ProxyServingFailure::Socks5ListenerUnavailable => "SOCKS5_LISTENER_UNAVAILABLE",
        ProxyServingFailure::HttpConnectListenerUnavailable => "HTTP_CONNECT_LISTENER_UNAVAILABLE",
        ProxyServingFailure::ExecutorUnavailable => "EXECUTOR_UNAVAILABLE",
        ProxyServingFailure::RuntimeStateUnavailable => "RUNTIME_STATE_UNAVAILABLE",
        ProxyServingFailure::ServingUnhealthy => "SERVING_UNHEALTHY",
        ProxyServingFailure::ShutdownFailed => "SHUTDOWN_FAILED",
    }
}

fn mesh_state_code(state: MeshAdmissionState) -> &'static str {
    match state {
        MeshAdmissionState::NotAdmitted => "NOT_ADMITTED",
        MeshAdmissionState::Admitted => "ADMITTED",
    }
}

fn mesh_failure_code(failure: Option<mish_transport::MeshTransportError>) -> &'static str {
    let Some(failure) = failure else {
        return "NONE";
    };
    match map_transport_error(failure) {
        MeshTransportBoundaryError::IngressBindFailed => "BIND_FAILED",
        MeshTransportBoundaryError::IngressShutdownFailed => "SHUTDOWN_FAILED",
        MeshTransportBoundaryError::IngressUnavailable => "UNAVAILABLE",
        MeshTransportBoundaryError::OwnerUnavailable => "OWNER_UNAVAILABLE",
        _ => "OTHER",
    }
}

fn readiness_state_code(state: ProductReadinessState) -> &'static str {
    match state {
        ProductReadinessState::Ready => "READY",
        ProductReadinessState::NotReady => "NOT_READY",
        ProductReadinessState::Degraded => "DEGRADED",
        ProductReadinessState::Unknown => "UNKNOWN",
    }
}

fn readiness_probe_state_code(state: ProductReadinessState) -> &'static str {
    match state {
        ProductReadinessState::Ready => "SUCCEEDED",
        ProductReadinessState::Degraded => "FAILED",
        ProductReadinessState::NotReady => "BLOCKED",
        ProductReadinessState::Unknown => "NOT_OBSERVED",
    }
}

fn map_runtime_snapshot(snapshot: ProductRuntimeSnapshot) -> RuntimeLifecycleSnapshotView {
    RuntimeLifecycleSnapshotView {
        state: map_lifecycle_state(snapshot.state),
        generation: snapshot.generation,
        generation_requires_replacement: snapshot.generation_requires_replacement,
    }
}

fn unavailable_proxy_publication() -> ProxyRuntimePublicationView {
    ProxyRuntimePublicationView {
        state: ProxyServingState::Failed,
        failure: Some(ProxyServingFailure::RuntimeStateUnavailable),
        serving_generation: None,
        credential_version: None,
        recovery_pending: false,
        recovery_operation_id: 0,
        recovery_attempts_since_success: 0,
        recovery_next_delay_ms: 0,
    }
}

fn map_proxy_publication(publication: ProxyRuntimePublication) -> ProxyRuntimePublicationView {
    ProxyRuntimePublicationView {
        state: match publication.state {
            OwnerProxyServingState::Stopped => ProxyServingState::Stopped,
            OwnerProxyServingState::Starting => ProxyServingState::Starting,
            OwnerProxyServingState::Running => ProxyServingState::Running,
            OwnerProxyServingState::Failed => ProxyServingState::Failed,
        },
        failure: publication.failure.map(map_proxy_failure_out),
        serving_generation: publication.serving_generation,
        credential_version: publication.credential_version,
        recovery_pending: publication.recovery_pending,
        recovery_operation_id: publication.recovery_operation_id,
        recovery_attempts_since_success: publication.recovery_attempts_since_success,
        recovery_next_delay_ms: publication.recovery_next_delay_ms,
    }
}

fn map_readiness_state(readiness: mish_readiness::Readiness) -> ProductReadinessState {
    match readiness {
        mish_readiness::Readiness::Ready => ProductReadinessState::Ready,
        mish_readiness::Readiness::NotReady => ProductReadinessState::NotReady,
        mish_readiness::Readiness::Degraded => ProductReadinessState::Degraded,
        mish_readiness::Readiness::Unknown => ProductReadinessState::Unknown,
    }
}

fn map_readiness_diagnostic(snapshot: ReadinessDiagnosticSnapshot) -> ReadinessDiagnosticView {
    ReadinessDiagnosticView {
        state: map_readiness_state(snapshot.state),
        root_policy_verified: snapshot.root_policy_verified,
        proxy_healthy: snapshot.proxy_healthy,
        credential_active: snapshot.credential_active,
        mesh_admitted: snapshot.mesh_admitted,
        binding_eligible: snapshot.binding_eligible,
        probe_in_flight: snapshot.probe_in_flight,
        refresh_pending: snapshot.refresh_pending,
    }
}

fn map_policy_publication(publication: CellularPolicyPublication) -> CellularPolicyPublicationView {
    let (state, failure, authority_status) = match publication.result {
        OwnerRootPolicyResult::Enforced => (RootPolicyStateView::Enforced, None, None),
        OwnerRootPolicyResult::FailClosed(failure) => (
            RootPolicyStateView::FailClosed,
            failure.map(map_policy_failure),
            None,
        ),
        OwnerRootPolicyResult::AuthorityUnavailable(status) => (
            RootPolicyStateView::AuthorityUnavailable,
            None,
            Some(map_authority_status(status)),
        ),
    };
    CellularPolicyPublicationView {
        admission: map_snapshot(publication.admission),
        state,
        failure,
        authority_status,
    }
}

fn map_policy_failure(failure: OwnerRootPolicyFailure) -> RootPolicyFailureView {
    match failure {
        OwnerRootPolicyFailure::InvalidInterface => RootPolicyFailureView::InvalidInterface,
        OwnerRootPolicyFailure::ReservedPolicyCollision => {
            RootPolicyFailureView::ReservedPolicyCollision
        }
        OwnerRootPolicyFailure::ObservationUnavailable => {
            RootPolicyFailureView::ObservationUnavailable
        }
        OwnerRootPolicyFailure::ObservationIncomplete => {
            RootPolicyFailureView::ObservationIncomplete
        }
        OwnerRootPolicyFailure::StructuralMismatch => RootPolicyFailureView::StructuralMismatch,
        OwnerRootPolicyFailure::RouteTableDiscoveryFailed => {
            RootPolicyFailureView::RouteTableDiscoveryFailed
        }
        OwnerRootPolicyFailure::MutationRejected => RootPolicyFailureView::MutationRejected,
        OwnerRootPolicyFailure::MutationUncertain => RootPolicyFailureView::MutationUncertain,
        OwnerRootPolicyFailure::LookupRuleCreationFailed => {
            RootPolicyFailureView::LookupRuleCreationFailed
        }
        OwnerRootPolicyFailure::RouteLookupVerificationFailed => {
            RootPolicyFailureView::RouteLookupVerificationFailed
        }
        OwnerRootPolicyFailure::ExactCleanupFailed => RootPolicyFailureView::ExactCleanupFailed,
    }
}

fn map_authority_status(status: OwnerRootAuthorityStatus) -> RootAuthorityStatusView {
    match status {
        OwnerRootAuthorityStatus::Ready => RootAuthorityStatusView::Ready,
        OwnerRootAuthorityStatus::InteractiveGrantRequired => {
            RootAuthorityStatusView::InteractiveGrantRequired
        }
        OwnerRootAuthorityStatus::Denied => RootAuthorityStatusView::Denied,
        OwnerRootAuthorityStatus::Unavailable => RootAuthorityStatusView::Unavailable,
        OwnerRootAuthorityStatus::Incomplete => RootAuthorityStatusView::Incomplete,
    }
}

fn map_reconcile_diagnostic(
    diagnostic: CellularReconcileDiagnostic,
) -> CellularReconcileDiagnosticView {
    CellularReconcileDiagnosticView {
        requested: diagnostic.requested,
        executed: diagnostic.executed,
        coalesced: diagnostic.coalesced,
        pending: diagnostic.pending,
        drain_scheduled: diagnostic.drain_scheduled,
        last_owner_sequence: diagnostic.last_owner_sequence,
        last_dequeue_wait_ms: diagnostic.last_dequeue_wait_ms,
        max_dequeue_wait_ms: diagnostic.max_dequeue_wait_ms,
        last_quiesce_wait_ms: diagnostic.last_quiesce_wait_ms,
        max_quiesce_wait_ms: diagnostic.max_quiesce_wait_ms,
        stale_after_reconcile: diagnostic.stale_after_reconcile,
        superseded_during_reconcile: diagnostic.superseded_during_reconcile,
    }
}

fn map_recovery_diagnostic(diagnostic: RootRecoveryDiagnostic) -> RootRecoveryDiagnosticView {
    RootRecoveryDiagnosticView {
        pending: diagnostic.pending,
        attempts_since_reset: diagnostic.attempts_since_reset,
        next_delay_ms: diagnostic.next_delay_ms,
    }
}

fn map_root_policy_phase_diagnostic(
    diagnostic: RootPolicyPhaseDiagnostic,
) -> RootPolicyPhaseDiagnosticView {
    RootPolicyPhaseDiagnosticView {
        elapsed_ms: diagnostic.elapsed_ms,
        commands: diagnostic.commands,
        observation_commands: diagnostic.observation_commands,
        mutation_commands: diagnostic.mutation_commands,
        duplicate_observations: diagnostic.duplicate_observations,
    }
}

fn map_root_policy_phases(phases: RootPolicyPhaseDiagnostics) -> RootPolicyPhaseDiagnosticsView {
    RootPolicyPhaseDiagnosticsView {
        initial_snapshot: map_root_policy_phase_diagnostic(phases.initial_snapshot),
        fail_closed_prepare: map_root_policy_phase_diagnostic(phases.fail_closed_prepare),
        fail_closed_verify: map_root_policy_phase_diagnostic(phases.fail_closed_verify),
        table_discovery: map_root_policy_phase_diagnostic(phases.table_discovery),
        admitted_apply_verify: map_root_policy_phase_diagnostic(phases.admitted_apply_verify),
    }
}

fn map_root_policy_diagnostic(
    diagnostic: RootPolicyReconcileDiagnostic,
) -> RootPolicyReconcileDiagnosticView {
    RootPolicyReconcileDiagnosticView {
        attempts: diagnostic.attempts,
        total_executor_commands: diagnostic.total_executor_commands,
        total_observation_commands: diagnostic.total_observation_commands,
        total_mutation_commands: diagnostic.total_mutation_commands,
        total_duplicate_observations: diagnostic.total_duplicate_observations,
        last_reconcile_elapsed_ms: diagnostic.last_reconcile_elapsed_ms,
        max_reconcile_elapsed_ms: diagnostic.max_reconcile_elapsed_ms,
        last_policy_effect_elapsed_ms: diagnostic.last_policy_effect_elapsed_ms,
        max_policy_effect_elapsed_ms: diagnostic.max_policy_effect_elapsed_ms,
        last_executor_commands: diagnostic.last_executor_commands,
        last_observation_commands: diagnostic.last_observation_commands,
        last_mutation_commands: diagnostic.last_mutation_commands,
        last_duplicate_observations: diagnostic.last_duplicate_observations,
        last_incomplete_or_timed_out_commands: diagnostic.last_incomplete_or_timed_out_commands,
        last_mutation_failures: diagnostic.last_mutation_failures,
        last_phases: map_root_policy_phases(diagnostic.last_phases),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_uid_is_rejected_before_runtime_construction() {
        let error = match NativeProductRuntime::new(0, false) {
            Ok(_) => panic!("zero UID must be rejected"),
            Err(error) => error,
        };
        assert_eq!(error, NativeProductRuntimeError::InvalidProductUid);
    }
}
