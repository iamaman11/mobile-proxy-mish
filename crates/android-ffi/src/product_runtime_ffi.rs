use crate::readiness_ffi::ProductReadinessState;
use crate::runtime_lifecycle_ffi::{
    ProxyServingFailure, ProxyServingState, RuntimeLifecycleState, RuntimeStartAction,
    RuntimeStopAction, map_lifecycle_state, map_proxy_failure_out, map_start_action,
    map_stop_action,
};
use crate::runtime_boundary::{
    AndroidDnsResolver, CellularAdmissionView, CellularBridgeError, CellularController,
    CellularDnsDiagnosticView, PublicIpObservationView, PublicIpProbeError, PublicIpProbeTicket,
    map_public_ip_failure, map_snapshot,
};
use crate::transport_ffi::{
    MeshAdmissionView, MeshTransportBoundaryError, map_transport_error, map_view as map_mesh_view,
};
use mish_cellular::{
    NetworkHandle, NetworkObservation, ObservationSequence, RootPolicyNamespace,
};
use mish_runtime::{
    CellularPolicyObserver, CellularPolicyPublication, CellularReconcileDiagnostic,
    ProductRuntimeCoordinator, ProductRuntimeSnapshot, ProxyRuntimeObserver,
    ProxyRuntimePublication,
    ProxyServingState as OwnerProxyServingState,
    RootAuthorityStatus as OwnerRootAuthorityStatus,
    RootPolicyFailure as OwnerRootPolicyFailure,
    ReadinessDiagnosticSnapshot, ReadinessObserver,
    ReadinessRuntimeError, RootPolicyReconcileDiagnostic,
    RootPolicyResult as OwnerRootPolicyResult, RootRecoveryDiagnostic, RuntimeExecutionError,
};
use mish_transport::MeshVpnObservation;
use std::fmt;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum NativeProductRuntimeError {
    InvalidProductUid,
    InvalidRuntimeGeneration,
    ThreadUnavailable,
    StateUnavailable,
    CleanupFailed,
}

impl fmt::Display for NativeProductRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidProductUid => "PRODUCT Android UID must be positive",
            Self::InvalidRuntimeGeneration => "PRODUCT runtime generation must be positive",
            Self::ThreadUnavailable => "native PRODUCT executor threads are unavailable",
            Self::StateUnavailable => "native PRODUCT runtime state is unavailable",
            Self::CleanupFailed => "native PRODUCT root-policy cleanup failed",
        })
    }
}

impl std::error::Error for NativeProductRuntimeError {}

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RootRecoveryDiagnosticView {
    pub pending: bool,
    pub attempts_since_reset: u32,
    pub next_delay_ms: u64,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProxyRuntimePublicationView {
    pub state: ProxyServingState,
    pub failure: Option<ProxyServingFailure>,
    pub serving_generation: Option<u64>,
    pub credential_version: Option<u64>,
    pub recovery_pending: bool,
    pub recovery_attempts_since_success: u32,
    pub recovery_next_delay_ms: u64,
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
pub trait NativeCellularPolicyObserver: Send + Sync {
    fn on_cellular_policy_publication(&self, publication: CellularPolicyPublicationView);
}

/// One native PRODUCT process generation.
///
/// This is the only FFI composition handle that owns Tokio execution, Cellular admission,
/// persistent root authority and root-policy reconciliation. Kotlin may supply Android observations
/// and consume typed projections, but cannot independently authorize or recover root policy.
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
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(AndroidDnsResolver),
            product_uid,
            namespace,
        )?;

        Ok(Arc::new(Self { runtime }))
    }

    pub fn runtime_lifecycle_snapshot(&self) -> RuntimeLifecycleSnapshotView {
        map_runtime_snapshot(self.runtime.snapshot())
    }

    pub fn start_runtime(
        self: &Arc<Self>,
        credential_version: Option<u64>,
        username: Option<String>,
        password: Option<String>,
    ) -> Result<RuntimeStartAction, NativeProductRuntimeError> {
        self.runtime
            .request_start(credential_version, username, password)
            .map(map_start_action)
            .map_err(Into::into)
    }

    pub fn stop_runtime(
        self: &Arc<Self>,
    ) -> Result<RuntimeStopAction, NativeProductRuntimeError> {
        self.runtime
            .request_stop()
            .map(map_stop_action)
            .map_err(Into::into)
    }

    pub fn advance_stopped_generation_after_platform_mutation(
        &self,
    ) -> Result<bool, NativeProductRuntimeError> {
        self.runtime
            .advance_stopped_generation_after_platform_mutation()
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

    pub fn readiness_diagnostic_snapshot(&self) -> ReadinessDiagnosticView {
        self.runtime
            .current_generation()
            .map(|generation| map_readiness_diagnostic(generation.readiness().diagnostic_snapshot()))
            .unwrap_or(ReadinessDiagnosticView {
                state: ProductReadinessState::Unknown,
                root_policy_verified: false,
                proxy_healthy: false,
                credential_active: false,
                mesh_admitted: false,
                binding_eligible: false,
                probe_in_flight: false,
                refresh_pending: false,
            })
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

    pub fn proxy_active_sessions(&self) -> u32 {
        self.runtime
            .current_generation()
            .map(|generation| generation.proxy().active_sessions())
            .unwrap_or(0)
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
        sequence: u64,
        network_handle: u64,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
        is_not_vpn: bool,
        interface_name: Option<String>,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        let observation = NetworkObservation::new(
            sequence,
            network_handle,
            is_cellular,
            has_internet,
            is_validated,
            is_not_vpn,
        );
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)?;
        generation
            .policy()
            .observe_network(observation, network_handle, interface_name)
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
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)?;
        generation
            .policy()
            .network_lost(sequence, network_handle)
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn dns_diagnostic_snapshot(&self) -> CellularDnsDiagnosticView {
        self.runtime
            .current_generation()
            .map(|generation| {
                CellularController::from_runtime(generation.cellular()).dns_diagnostic_snapshot()
            })
            .unwrap_or_else(|_| CellularDnsDiagnosticView {
                slow_threshold_ms: 0,
                started: 0,
                completed: 0,
                active: 0,
                peak_active: 0,
                slow_completions: 0,
                resolver_failed: 0,
                discarded_after_deadline: 0,
                completed_after_owner_change: 0,
                discarded_stale: 0,
                authority_validation_failed: 0,
                unusable_result: 0,
                accepted_current: 0,
                max_native_elapsed_ms: 0,
                last_started_owner_sequence: None,
                last_completed_start_owner_sequence: None,
                last_completed_current_owner_sequence: None,
            })
    }

    pub fn prepare_public_ip_probe(
        &self,
        timeout_ms: u64,
    ) -> Result<Arc<PublicIpProbeTicket>, PublicIpProbeError> {
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| PublicIpProbeError::NoCurrentCellular)?;
        CellularController::from_runtime(generation.cellular()).prepare_public_ip_probe(timeout_ms)
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
            .observe_public_egress_ip(
                &generation.executor(),
                Duration::from_millis(timeout_ms),
            )
            .map(|observation| PublicIpObservationView {
                address: observation.address().to_string(),
                generation: observation.generation(),
            })
            .map_err(map_public_ip_failure)
    }

    pub fn cellular_reconcile_diagnostic(&self) -> CellularReconcileDiagnosticView {
        self.runtime
            .current_generation()
            .map(|generation| map_reconcile_diagnostic(generation.policy().reconcile_diagnostic()))
            .unwrap_or(CellularReconcileDiagnosticView {
                requested: 0,
                executed: 0,
                coalesced: 0,
                pending: false,
                drain_scheduled: false,
            })
    }

    pub fn root_recovery_diagnostic(&self) -> RootRecoveryDiagnosticView {
        self.runtime
            .current_generation()
            .map(|generation| map_recovery_diagnostic(generation.policy().recovery_diagnostic()))
            .unwrap_or(RootRecoveryDiagnosticView {
                pending: false,
                attempts_since_reset: 0,
                next_delay_ms: 0,
            })
    }

    pub fn root_policy_reconcile_diagnostic(
        &self,
    ) -> Result<RootPolicyReconcileDiagnosticView, NativeProductRuntimeError> {
        let generation = self.runtime.current_generation()?;
        generation
            .policy()
            .root_policy_diagnostic_blocking(&generation.executor())
            .map(map_root_policy_diagnostic)
            .map_err(Into::into)
    }

    pub fn mesh_admission_snapshot(
        &self,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
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
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| MeshTransportBoundaryError::OwnerUnavailable)?;
        let snapshot = generation
            .mesh()
            .observe_vpn(sequence, MeshVpnObservation::Absent)
            .map_err(map_transport_error)?;
        generation
            .readiness()
            .observe_mesh(snapshot)
            .map_err(map_readiness_runtime_to_mesh)?;
        generation
            .mesh()
            .snapshot()
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
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| MeshTransportBoundaryError::OwnerUnavailable)?;
        let snapshot = generation
            .mesh()
            .observe_vpn(
                sequence,
                MeshVpnObservation::UniqueVpn {
                    local_ipv4: addresses,
                },
            )
            .map_err(map_transport_error)?;
        generation
            .readiness()
            .observe_mesh(snapshot)
            .map_err(map_readiness_runtime_to_mesh)?;
        generation
            .mesh()
            .snapshot()
            .map(map_mesh_view)
            .map_err(map_transport_error)
    }

    pub fn observe_mesh_vpn_ambiguous(
        &self,
        sequence: u64,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let generation = self
            .runtime
            .active_generation()
            .map_err(|_| MeshTransportBoundaryError::OwnerUnavailable)?;
        let snapshot = generation
            .mesh()
            .observe_vpn(sequence, MeshVpnObservation::AmbiguousVpn)
            .map_err(map_transport_error)?;
        generation
            .readiness()
            .observe_mesh(snapshot)
            .map_err(map_readiness_runtime_to_mesh)?;
        generation
            .mesh()
            .snapshot()
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

fn map_readiness_runtime_to_mesh(_error: ReadinessRuntimeError) -> MeshTransportBoundaryError {
    MeshTransportBoundaryError::OwnerUnavailable
}

fn map_policy_publication(
    publication: CellularPolicyPublication,
) -> CellularPolicyPublicationView {
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
    }
}

fn map_recovery_diagnostic(diagnostic: RootRecoveryDiagnostic) -> RootRecoveryDiagnosticView {
    RootRecoveryDiagnosticView {
        pending: diagnostic.pending,
        attempts_since_reset: diagnostic.attempts_since_reset,
        next_delay_ms: diagnostic.next_delay_ms,
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
