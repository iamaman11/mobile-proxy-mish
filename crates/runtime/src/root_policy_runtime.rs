//! Generation-bound root-policy transaction executed on the single PRODUCT Tokio runtime.
//!
//! mish-cellular owns the pure policy contract. This module owns transaction sequencing, root
//! authority/session currentness and typed recovery classification. It owns no Android state.

use crate::root_policy_effect::{
    RootPolicyCommandWindow, RootPolicyCommandWindowDiagnostic, RootPolicyEffectExecutor,
    RootPolicyEffectFailure, RootPolicyIo,
};
use crate::root_session::RootSessionManager;
use mish_cellular::{
    IP6TABLES, IPTABLES, IPV4_RULE_SHOW, IPV6_RULE_SHOW, MAX_RECONCILE_PASSES, MangleFamilyState,
    PolicyIdentityResolution, RootPolicyContract, RootPolicyNamespace, RootPolicySnapshot,
    is_safe_interface_name, referenced_tables, route_get_uses_interface,
    route_has_default_on_interface,
};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootAuthorityStatus {
    Ready,
    InteractiveGrantRequired,
    Denied,
    Unavailable,
    Incomplete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootPolicyFailure {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootPolicyCleanupFailure {
    IdentityUnavailable,
    IdentityCollision,
    Ipv4LookupDeleteFailed,
    Ipv4OutputJumpDeleteFailed,
    Ipv4LegacySelectorDeleteFailed,
    Ipv4ChainDeleteFailed,
    Ipv4GuardDeleteFailed,
    Ipv6OutputJumpDeleteFailed,
    Ipv6LegacySelectorDeleteFailed,
    Ipv6ChainDeleteFailed,
    Ipv6GuardDeleteFailed,
    FinalVerificationFailed,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootPolicyResult {
    Enforced,
    FailClosed(Option<RootPolicyFailure>),
    AuthorityUnavailable(RootAuthorityStatus),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RootPolicyReconcileOutcome {
    Completed(RootPolicyResult),
    Superseded,
}

impl RootPolicyResult {
    pub const fn retryable(self) -> bool {
        matches!(
            self,
            Self::AuthorityUnavailable(
                RootAuthorityStatus::Unavailable | RootAuthorityStatus::Incomplete
            ) | Self::FailClosed(Some(
                RootPolicyFailure::ObservationUnavailable
                    | RootPolicyFailure::ObservationIncomplete
                    | RootPolicyFailure::MutationUncertain
            ))
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RootPolicyPhaseDiagnostic {
    pub elapsed_ms: u64,
    pub commands: u64,
    pub observation_commands: u64,
    pub mutation_commands: u64,
    pub duplicate_observations: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RootPolicyPhaseDiagnostics {
    pub initial_snapshot: RootPolicyPhaseDiagnostic,
    pub fail_closed_prepare: RootPolicyPhaseDiagnostic,
    pub fail_closed_verify: RootPolicyPhaseDiagnostic,
    pub table_discovery: RootPolicyPhaseDiagnostic,
    pub admitted_apply_verify: RootPolicyPhaseDiagnostic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RootPolicyReconcileDiagnostic {
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
    pub last_phases: RootPolicyPhaseDiagnostics,
}

struct RootPolicyState {
    contract: RootPolicyContract,
    ready_session_generation: Option<u64>,
    terminal_authority: Option<RootAuthorityStatus>,
    diagnostic: RootPolicyReconcileDiagnostic,
}

#[derive(Debug, Default)]
struct RootPolicyReconcileTrace {
    phases: RootPolicyPhaseDiagnostics,
    superseded: bool,
}

pub struct RootPolicyRuntime {
    io: Arc<dyn RootPolicyIo>,
    state: Mutex<RootPolicyState>,
}

impl RootPolicyRuntime {
    pub(crate) fn new(
        session: Arc<RootSessionManager>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
    ) -> Option<Arc<Self>> {
        let io: Arc<dyn RootPolicyIo> = Arc::new(RootPolicyEffectExecutor::new(session));
        Self::with_io(io, product_uid, namespace)
    }

    fn with_io(
        io: Arc<dyn RootPolicyIo>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
    ) -> Option<Arc<Self>> {
        let contract = RootPolicyContract::new(product_uid, namespace)?;
        Some(Arc::new(Self {
            io,
            state: Mutex::new(RootPolicyState {
                contract,
                ready_session_generation: None,
                terminal_authority: None,
                diagnostic: RootPolicyReconcileDiagnostic::default(),
            }),
        }))
    }

    pub async fn reconcile(
        &self,
        admitted: bool,
        interface_name: Option<&str>,
    ) -> RootPolicyResult {
        match self
            .reconcile_if_current(admitted, interface_name, || true)
            .await
        {
            RootPolicyReconcileOutcome::Completed(result) => result,
            RootPolicyReconcileOutcome::Superseded => {
                unreachable!("an always-current root reconcile cannot be superseded")
            }
        }
    }

    /// Reconciles one Cellular owner generation while allowing its natural owner to invalidate
    /// stale work only at transaction boundaries that are safe to abandon.
    ///
    /// The predicate is read-only. RootPolicyRuntime does not own Cellular generation state and
    /// does not cancel an in-flight mutation. Once fail-closed construction starts it runs through
    /// authoritative fail-closed verification before currentness is checked again.
    pub(crate) async fn reconcile_if_current<F>(
        &self,
        admitted: bool,
        interface_name: Option<&str>,
        is_current: F,
    ) -> RootPolicyReconcileOutcome
    where
        F: Fn() -> bool + Sync,
    {
        let reconcile_started = Instant::now();
        let mut state = self.state.lock().await;

        if !is_current() {
            record_reconcile(
                &mut state.diagnostic,
                reconcile_started,
                Duration::ZERO,
                RootPolicyCommandWindowDiagnostic::default(),
                RootPolicyPhaseDiagnostics::default(),
            );
            return RootPolicyReconcileOutcome::Superseded;
        }

        let authority = self.probe_authority(&mut state).await;
        if authority != RootAuthorityStatus::Ready {
            record_reconcile(
                &mut state.diagnostic,
                reconcile_started,
                Duration::ZERO,
                RootPolicyCommandWindowDiagnostic::default(),
                RootPolicyPhaseDiagnostics::default(),
            );
            return RootPolicyReconcileOutcome::Completed(RootPolicyResult::AuthorityUnavailable(
                authority,
            ));
        }
        if !is_current() {
            record_reconcile(
                &mut state.diagnostic,
                reconcile_started,
                Duration::ZERO,
                RootPolicyCommandWindowDiagnostic::default(),
                RootPolicyPhaseDiagnostics::default(),
            );
            return RootPolicyReconcileOutcome::Superseded;
        }

        let policy_started = Instant::now();
        let mut window = RootPolicyCommandWindow::default();
        let mut trace = RootPolicyReconcileTrace::default();
        let result = self
            .reconcile_authorized(
                &mut state.contract,
                admitted,
                interface_name,
                &mut window,
                &mut trace,
                &is_current,
            )
            .await;
        record_reconcile(
            &mut state.diagnostic,
            reconcile_started,
            policy_started.elapsed(),
            window.diagnostic(),
            trace.phases,
        );
        if trace.superseded {
            RootPolicyReconcileOutcome::Superseded
        } else {
            RootPolicyReconcileOutcome::Completed(result)
        }
    }

    pub async fn diagnostic(&self) -> RootPolicyReconcileDiagnostic {
        self.state.lock().await.diagnostic
    }

    pub async fn active_identity_mark(&self) -> Option<u64> {
        self.state
            .lock()
            .await
            .contract
            .active_identity()
            .map(|identity| identity.mark_value())
    }

    async fn reconcile_authorized<F>(
        &self,
        contract: &mut RootPolicyContract,
        admitted: bool,
        interface_name: Option<&str>,
        window: &mut RootPolicyCommandWindow,
        trace: &mut RootPolicyReconcileTrace,
        is_current: &F,
    ) -> RootPolicyResult
    where
        F: Fn() -> bool + Sync,
    {
        let phase_started = Instant::now();
        let phase_before = window.diagnostic();
        let initial = match self.read_snapshot(window).await {
            Ok(snapshot) => snapshot,
            Err(failure) => return RootPolicyResult::FailClosed(Some(failure)),
        };
        trace.phases.initial_snapshot =
            phase_diagnostic(phase_started, phase_before, window.diagnostic());
        // No policy mutation has happened yet. A superseded generation can be abandoned without
        // changing kernel state.
        if !is_current() {
            trace.superseded = true;
            return RootPolicyResult::FailClosed(None);
        }

        match contract.resolve_identity(&initial) {
            PolicyIdentityResolution::Selected(_) => {}
            PolicyIdentityResolution::Collision => {
                if contract.active_identity().is_some()
                    && self
                        .remove_owned_ipv4_lookups(contract, window)
                        .await
                        .is_err()
                {
                    return RootPolicyResult::FailClosed(Some(RootPolicyFailure::MutationRejected));
                }
                return RootPolicyResult::FailClosed(Some(
                    RootPolicyFailure::ReservedPolicyCollision,
                ));
            }
        }

        let phase_started = Instant::now();
        let phase_before = window.diagnostic();

        // Reuse the authoritative initial snapshot only for exact no-op decisions. Any state that
        // needs repair still enters the existing fresh-read helper path, and the complete
        // fail-closed base is always re-read and verified below before admitted policy may start.
        if !initial
            .ipv4_rules
            .iter()
            .any(|line| contract.is_owned_ipv4_guard(line))
            && let Err(failure) = self.ensure_guard(contract, true, window).await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if !initial
            .ipv6_rules
            .iter()
            .any(|line| contract.is_owned_ipv6_guard(line))
            && let Err(failure) = self.ensure_guard(contract, false, window).await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if !contract
            .owned_ipv4_lookup_tables(&initial.ipv4_rules)
            .is_empty()
            && let Err(failure) = self.remove_owned_ipv4_lookups(contract, window).await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if contract.mangle_family_state(&initial.ipv4_mangle, true)
            != Some(MangleFamilyState::AttachedExact)
            && let Err(failure) = self
                .ensure_mangle_family(contract, IPTABLES, true, window)
                .await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if contract.mangle_family_state(&initial.ipv6_mangle, false)
            != Some(MangleFamilyState::AttachedExact)
            && let Err(failure) = self
                .ensure_mangle_family(contract, IP6TABLES, false, window)
                .await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if let Err(failure) = self
            .remove_exact_rule(
                &contract.legacy_selector_check(IPTABLES),
                &contract.legacy_selector_delete(IPTABLES),
                window,
            )
            .await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        if let Err(failure) = self
            .remove_exact_rule(
                &contract.legacy_selector_check(IP6TABLES),
                &contract.legacy_selector_delete(IP6TABLES),
                window,
            )
            .await
        {
            return RootPolicyResult::FailClosed(Some(failure));
        }
        trace.phases.fail_closed_prepare =
            phase_diagnostic(phase_started, phase_before, window.diagnostic());

        let phase_started = Instant::now();
        let phase_before = window.diagnostic();
        let fail_closed = match self.read_snapshot(window).await {
            Ok(snapshot) => snapshot,
            Err(failure) => return RootPolicyResult::FailClosed(Some(failure)),
        };
        if contract.verify_fail_closed_base(&fail_closed).is_err() {
            return RootPolicyResult::FailClosed(Some(RootPolicyFailure::StructuralMismatch));
        }
        trace.phases.fail_closed_verify =
            phase_diagnostic(phase_started, phase_before, window.diagnostic());
        // Everything before this point is the fail-closed base. If owner generation changed while
        // constructing it, stop here rather than starting admitted-generation work.
        if !is_current() {
            trace.superseded = true;
            return RootPolicyResult::FailClosed(None);
        }

        if !admitted {
            return RootPolicyResult::FailClosed(None);
        }

        let Some(interface) = interface_name.filter(|value| is_safe_interface_name(value)) else {
            return RootPolicyResult::FailClosed(Some(RootPolicyFailure::InvalidInterface));
        };
        let phase_started = Instant::now();
        let phase_before = window.diagnostic();
        let table = match self
            .discover_validated_ipv4_table(&fail_closed.ipv4_rules, interface, window)
            .await
        {
            Ok(table) => table,
            Err(failure) => return RootPolicyResult::FailClosed(Some(failure)),
        };
        trace.phases.table_discovery =
            phase_diagnostic(phase_started, phase_before, window.diagnostic());
        // Route-table discovery is observation-only. This is the final safe point before the
        // admitted lookup mutation begins.
        if !is_current() {
            trace.superseded = true;
            return RootPolicyResult::FailClosed(None);
        }

        let phase_started = Instant::now();
        let phase_before = window.diagnostic();
        if let Err(failure) = self.replace_ipv4_lookup(contract, &table, window).await {
            return RootPolicyResult::FailClosed(Some(failure));
        }

        let Some(identity) = contract.active_identity() else {
            return RootPolicyResult::FailClosed(Some(RootPolicyFailure::StructuralMismatch));
        };
        let route_command = format!("ip -4 route get 1.1.1.1 mark {}", identity.mark_hex());
        let route = match self.io.observe(&route_command, window).await {
            Ok(result) => result,
            Err(error) => return RootPolicyResult::FailClosed(Some(map_effect_failure(error))),
        };
        if route.exit_code != 0 || !route_get_uses_interface(&route.stdout, interface) {
            let _ = self.remove_owned_ipv4_lookups(contract, window).await;
            return RootPolicyResult::FailClosed(Some(
                RootPolicyFailure::RouteLookupVerificationFailed,
            ));
        }
        trace.phases.admitted_apply_verify =
            phase_diagnostic(phase_started, phase_before, window.diagnostic());

        RootPolicyResult::Enforced
    }

    async fn probe_authority(&self, state: &mut RootPolicyState) -> RootAuthorityStatus {
        if let Some(terminal) = state.terminal_authority {
            return terminal;
        }

        let current_generation = self.io.session_generation().await;
        if current_generation.is_some() && current_generation == state.ready_session_generation {
            return RootAuthorityStatus::Ready;
        }
        state.ready_session_generation = None;

        let identity = match self.io.raw_observation("id -u").await {
            Ok(result) => result,
            Err(_) => return RootAuthorityStatus::Unavailable,
        };
        if identity.timed_out {
            state.terminal_authority = Some(RootAuthorityStatus::InteractiveGrantRequired);
            return RootAuthorityStatus::InteractiveGrantRequired;
        }
        if matches!(identity.exit_code, 126 | 127) {
            return RootAuthorityStatus::Unavailable;
        }
        if identity.exit_code > 0 || identity.stdout.trim() != "0" {
            state.terminal_authority = Some(RootAuthorityStatus::Denied);
            return RootAuthorityStatus::Denied;
        }
        if !identity.output_complete || identity.exit_code != 0 {
            return RootAuthorityStatus::Incomplete;
        }

        let rules = match self.io.raw_observation(IPV4_RULE_SHOW).await {
            Ok(result) => result,
            Err(_) => return RootAuthorityStatus::Incomplete,
        };
        if rules.timed_out
            || !rules.output_complete
            || rules.exit_code != 0
            || rules.stdout.trim().is_empty()
        {
            return RootAuthorityStatus::Incomplete;
        }

        if !self.bootstrap_stale_owner_jumps(&state.contract).await {
            return RootAuthorityStatus::Incomplete;
        }

        state.ready_session_generation = self.io.session_generation().await;
        if state.ready_session_generation.is_some() {
            RootAuthorityStatus::Ready
        } else {
            RootAuthorityStatus::Incomplete
        }
    }

    async fn bootstrap_stale_owner_jumps(&self, contract: &RootPolicyContract) -> bool {
        for (binary, ipv4) in [(IPTABLES, true), (IP6TABLES, false)] {
            let command = format!("{binary} -t mangle -S");
            let before = match self.io.raw_observation(&command).await {
                Ok(result)
                    if !result.timed_out && result.output_complete && result.exit_code == 0 =>
                {
                    parse_lines(&result.stdout)
                }
                _ => return false,
            };
            let stale_uids = contract.stale_owner_jump_uids(&before);
            if stale_uids.is_empty() {
                continue;
            }
            if !contract.is_exact_known_product_state(&before, ipv4) {
                continue;
            }

            let mut ignored_window = RootPolicyCommandWindow::default();
            for uid in stale_uids {
                let delete = contract.stale_owner_jump_delete(binary, uid);
                if self.io.mutate(&delete, &mut ignored_window).await.is_err() {
                    return false;
                }
            }

            let after = match self.io.raw_observation(&command).await {
                Ok(result)
                    if !result.timed_out && result.output_complete && result.exit_code == 0 =>
                {
                    parse_lines(&result.stdout)
                }
                _ => return false,
            };
            if !contract.stale_owner_jump_uids(&after).is_empty() {
                return false;
            }
        }
        true
    }

    async fn read_snapshot(
        &self,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<RootPolicySnapshot, RootPolicyFailure> {
        Ok(RootPolicySnapshot::new(
            self.io
                .lines(IPV4_RULE_SHOW, window)
                .await
                .map_err(map_effect_failure)?,
            self.io
                .lines(IPV6_RULE_SHOW, window)
                .await
                .map_err(map_effect_failure)?,
            self.io
                .lines(&format!("{IPTABLES} -t mangle -S"), window)
                .await
                .map_err(map_effect_failure)?,
            self.io
                .lines(&format!("{IP6TABLES} -t mangle -S"), window)
                .await
                .map_err(map_effect_failure)?,
        ))
    }

    async fn ensure_guard(
        &self,
        contract: &RootPolicyContract,
        ipv4: bool,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let show = if ipv4 { IPV4_RULE_SHOW } else { IPV6_RULE_SHOW };
        let current = self
            .io
            .lines(show, window)
            .await
            .map_err(map_effect_failure)?;
        let present = if ipv4 {
            current
                .iter()
                .any(|line| contract.is_owned_ipv4_guard(line))
        } else {
            current
                .iter()
                .any(|line| contract.is_owned_ipv6_guard(line))
        };
        if present {
            return Ok(());
        }
        let add = if ipv4 {
            contract.ipv4_guard_add()
        } else {
            contract.ipv6_guard_add()
        }
        .ok_or(RootPolicyFailure::StructuralMismatch)?;
        self.io
            .mutate(&add, window)
            .await
            .map_err(map_effect_failure)?;

        let verified = self
            .io
            .lines(show, window)
            .await
            .map_err(map_effect_failure)?;
        let present = if ipv4 {
            verified
                .iter()
                .any(|line| contract.is_owned_ipv4_guard(line))
        } else {
            verified
                .iter()
                .any(|line| contract.is_owned_ipv6_guard(line))
        };
        present
            .then_some(())
            .ok_or(RootPolicyFailure::StructuralMismatch)
    }

    async fn ensure_mangle_family(
        &self,
        contract: &RootPolicyContract,
        binary: &str,
        ipv4: bool,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let show = format!("{binary} -t mangle -S");
        let mut snapshot = self
            .io
            .lines(&show, window)
            .await
            .map_err(map_effect_failure)?;
        let mut state = contract
            .mangle_family_state(&snapshot, ipv4)
            .ok_or(RootPolicyFailure::StructuralMismatch)?;

        if state == MangleFamilyState::InvalidReferenced {
            return Err(RootPolicyFailure::StructuralMismatch);
        }

        if state == MangleFamilyState::AttachedDuplicateExact {
            while contract.output_jump_count(&snapshot) > 1 {
                let delete = contract.output_jump_delete(binary);
                match self.io.mutate(&delete, window).await {
                    Ok(()) => {}
                    Err(RootPolicyEffectFailure::MutationUncertain) => {
                        snapshot = self
                            .io
                            .lines(&show, window)
                            .await
                            .map_err(map_effect_failure)?;
                        if contract.output_jump_count(&snapshot) <= 1 {
                            break;
                        }
                        return Err(RootPolicyFailure::MutationUncertain);
                    }
                    Err(error) => return Err(map_effect_failure(error)),
                }
                snapshot = self
                    .io
                    .lines(&show, window)
                    .await
                    .map_err(map_effect_failure)?;
            }
            state = contract
                .mangle_family_state(&snapshot, ipv4)
                .ok_or(RootPolicyFailure::StructuralMismatch)?;
            if state == MangleFamilyState::AttachedExact {
                return Ok(());
            }
        }

        if state == MangleFamilyState::AttachedExact {
            return Ok(());
        }

        if state == MangleFamilyState::Missing {
            let create = contract.create_chain_command(binary);
            self.io
                .mutate(&create, window)
                .await
                .map_err(map_effect_failure)?;
            snapshot = self
                .io
                .lines(&show, window)
                .await
                .map_err(map_effect_failure)?;
            state = contract
                .mangle_family_state(&snapshot, ipv4)
                .ok_or(RootPolicyFailure::StructuralMismatch)?;
        }

        if state == MangleFamilyState::DetachedMismatch {
            let flush = contract.flush_chain_command(binary);
            self.io
                .mutate(&flush, window)
                .await
                .map_err(map_effect_failure)?;
            let expected = if ipv4 {
                contract.ipv4_owned_chain_lines()
            } else {
                contract.ipv6_owned_chain_lines()
            }
            .ok_or(RootPolicyFailure::StructuralMismatch)?;
            for rule in expected {
                let append = format!("{binary} -t mangle {rule}");
                self.io
                    .mutate(&append, window)
                    .await
                    .map_err(map_effect_failure)?;
            }
            snapshot = self
                .io
                .lines(&show, window)
                .await
                .map_err(map_effect_failure)?;
            state = contract
                .mangle_family_state(&snapshot, ipv4)
                .ok_or(RootPolicyFailure::StructuralMismatch)?;
        }

        if state != MangleFamilyState::DetachedExact {
            return Err(RootPolicyFailure::StructuralMismatch);
        }

        let attach = contract.output_jump_add(binary);
        self.io
            .mutate(&attach, window)
            .await
            .map_err(map_effect_failure)?;
        let verified = self
            .io
            .lines(&show, window)
            .await
            .map_err(map_effect_failure)?;
        (contract.mangle_family_state(&verified, ipv4) == Some(MangleFamilyState::AttachedExact))
            .then_some(())
            .ok_or(RootPolicyFailure::StructuralMismatch)
    }

    async fn remove_exact_rule(
        &self,
        check: &str,
        delete: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        for _ in 0..MAX_RECONCILE_PASSES {
            let observed = self
                .io
                .observe(check, window)
                .await
                .map_err(map_effect_failure)?;
            if observed.exit_code != 0 {
                return Ok(());
            }
            self.io
                .mutate(delete, window)
                .await
                .map_err(map_effect_failure)?;
        }
        let final_check = self
            .io
            .observe(check, window)
            .await
            .map_err(map_effect_failure)?;
        (final_check.exit_code != 0)
            .then_some(())
            .ok_or(RootPolicyFailure::MutationRejected)
    }

    async fn remove_owned_ipv4_lookups(
        &self,
        contract: &RootPolicyContract,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        for _ in 0..MAX_RECONCILE_PASSES {
            let rules = self
                .io
                .lines(IPV4_RULE_SHOW, window)
                .await
                .map_err(map_effect_failure)?;
            let tables = contract.owned_ipv4_lookup_tables(&rules);
            if tables.is_empty() {
                return Ok(());
            }
            for table in tables {
                let delete = contract
                    .ipv4_lookup_delete(&table)
                    .ok_or(RootPolicyFailure::MutationRejected)?;
                self.io
                    .mutate(&delete, window)
                    .await
                    .map_err(map_effect_failure)?;
            }
        }
        let final_rules = self
            .io
            .lines(IPV4_RULE_SHOW, window)
            .await
            .map_err(map_effect_failure)?;
        contract
            .owned_ipv4_lookup_tables(&final_rules)
            .is_empty()
            .then_some(())
            .ok_or(RootPolicyFailure::MutationRejected)
    }

    async fn discover_validated_ipv4_table(
        &self,
        rules: &[String],
        interface: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<String, RootPolicyFailure> {
        let mut matching = Vec::new();
        for table in referenced_tables(rules) {
            let command = format!("ip -4 route show table {table} default");
            let route = self
                .io
                .observe(&command, window)
                .await
                .map_err(map_effect_failure)?;
            if route.exit_code == 0
                && route_has_default_on_interface(&parse_lines(&route.stdout), interface)
            {
                matching.push(table);
            }
        }
        if matching.len() == 1 {
            Ok(matching.remove(0))
        } else {
            Err(RootPolicyFailure::RouteTableDiscoveryFailed)
        }
    }

    async fn replace_ipv4_lookup(
        &self,
        contract: &RootPolicyContract,
        table: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let rules = self
            .io
            .lines(IPV4_RULE_SHOW, window)
            .await
            .map_err(map_effect_failure)?;
        let existing = contract.owned_ipv4_lookup_tables(&rules);
        for stale in existing
            .iter()
            .filter(|existing| existing.as_str() != table)
        {
            let delete = contract
                .ipv4_lookup_delete(stale)
                .ok_or(RootPolicyFailure::LookupRuleCreationFailed)?;
            self.io
                .mutate(&delete, window)
                .await
                .map_err(map_effect_failure)?;
        }

        let after_delete = self
            .io
            .lines(IPV4_RULE_SHOW, window)
            .await
            .map_err(map_effect_failure)?;
        if contract
            .owned_ipv4_lookup_tables(&after_delete)
            .iter()
            .any(|existing| existing == table)
        {
            return Ok(());
        }

        let add = contract
            .ipv4_lookup_add(table)
            .ok_or(RootPolicyFailure::LookupRuleCreationFailed)?;
        self.io
            .mutate(&add, window)
            .await
            .map_err(map_effect_failure)?;
        let after_add = self
            .io
            .lines(IPV4_RULE_SHOW, window)
            .await
            .map_err(map_effect_failure)?;
        contract
            .owned_ipv4_lookup_tables(&after_add)
            .iter()
            .any(|existing| existing == table)
            .then_some(())
            .ok_or(RootPolicyFailure::LookupRuleCreationFailed)
    }
}

impl RootPolicyRuntime {
    pub async fn cleanup_exact(&self) -> Result<(), RootPolicyCleanupFailure> {
        let mut state = self.state.lock().await;
        let mut window = RootPolicyCommandWindow::default();

        if state.contract.active_identity().is_none() {
            let snapshot = self
                .read_snapshot(&mut window)
                .await
                .map_err(|_| RootPolicyCleanupFailure::IdentityUnavailable)?;
            match state.contract.resolve_identity(&snapshot) {
                PolicyIdentityResolution::Selected(_) => {}
                PolicyIdentityResolution::Collision => {
                    if state.contract.has_any_product_signature(&snapshot) {
                        return Err(RootPolicyCleanupFailure::IdentityCollision);
                    }
                    return Ok(());
                }
            }
        }

        self.remove_owned_ipv4_lookups(&state.contract, &mut window)
            .await
            .map_err(|_| RootPolicyCleanupFailure::Ipv4LookupDeleteFailed)?;

        let ipv4_jump = self
            .remove_all_output_jumps(&state.contract, IPTABLES, &mut window)
            .await;
        let ipv4_legacy = self
            .remove_exact_rule(
                &state.contract.legacy_selector_check(IPTABLES),
                &state.contract.legacy_selector_delete(IPTABLES),
                &mut window,
            )
            .await;
        if ipv4_jump.is_ok() && ipv4_legacy.is_ok() {
            self.remove_owned_chain(&state.contract, IPTABLES, true, &mut window)
                .await
                .map_err(|_| RootPolicyCleanupFailure::Ipv4ChainDeleteFailed)?;
            self.remove_guard(&state.contract, true, &mut window)
                .await
                .map_err(|_| RootPolicyCleanupFailure::Ipv4GuardDeleteFailed)?;
        }

        let ipv6_jump = self
            .remove_all_output_jumps(&state.contract, IP6TABLES, &mut window)
            .await;
        let ipv6_legacy = self
            .remove_exact_rule(
                &state.contract.legacy_selector_check(IP6TABLES),
                &state.contract.legacy_selector_delete(IP6TABLES),
                &mut window,
            )
            .await;
        if ipv6_jump.is_ok() && ipv6_legacy.is_ok() {
            self.remove_owned_chain(&state.contract, IP6TABLES, false, &mut window)
                .await
                .map_err(|_| RootPolicyCleanupFailure::Ipv6ChainDeleteFailed)?;
            self.remove_guard(&state.contract, false, &mut window)
                .await
                .map_err(|_| RootPolicyCleanupFailure::Ipv6GuardDeleteFailed)?;
        }

        if ipv4_jump.is_err() {
            return Err(RootPolicyCleanupFailure::Ipv4OutputJumpDeleteFailed);
        }
        if ipv4_legacy.is_err() {
            return Err(RootPolicyCleanupFailure::Ipv4LegacySelectorDeleteFailed);
        }
        if ipv6_jump.is_err() {
            return Err(RootPolicyCleanupFailure::Ipv6OutputJumpDeleteFailed);
        }
        if ipv6_legacy.is_err() {
            return Err(RootPolicyCleanupFailure::Ipv6LegacySelectorDeleteFailed);
        }

        if self.probe_authority(&mut state).await != RootAuthorityStatus::Ready {
            return Err(RootPolicyCleanupFailure::FinalVerificationFailed);
        }
        let final_snapshot = self
            .read_snapshot(&mut window)
            .await
            .map_err(|_| RootPolicyCleanupFailure::FinalVerificationFailed)?;
        if !state.contract.verify_exact_cleanup(&final_snapshot) {
            return Err(RootPolicyCleanupFailure::FinalVerificationFailed);
        }
        state.contract.clear_active_identity();
        Ok(())
    }

    async fn remove_all_output_jumps(
        &self,
        contract: &RootPolicyContract,
        binary: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let show = format!("{binary} -t mangle -S");
        for _ in 0..MAX_RECONCILE_PASSES {
            let lines = self
                .io
                .lines(&show, window)
                .await
                .map_err(map_effect_failure)?;
            if contract.output_jump_count(&lines) == 0 {
                return Ok(());
            }
            let delete = contract.output_jump_delete(binary);
            match self.io.mutate(&delete, window).await {
                Ok(()) => {}
                Err(RootPolicyEffectFailure::MutationUncertain) => {
                    let fresh = self
                        .io
                        .lines(&show, window)
                        .await
                        .map_err(map_effect_failure)?;
                    if contract.output_jump_count(&fresh) == 0 {
                        return Ok(());
                    }
                    return Err(RootPolicyFailure::MutationUncertain);
                }
                Err(error) => return Err(map_effect_failure(error)),
            }
        }
        let final_lines = self
            .io
            .lines(&show, window)
            .await
            .map_err(map_effect_failure)?;
        (contract.output_jump_count(&final_lines) == 0)
            .then_some(())
            .ok_or(RootPolicyFailure::MutationRejected)
    }

    async fn remove_owned_chain(
        &self,
        contract: &RootPolicyContract,
        binary: &str,
        ipv4: bool,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let show = format!("{binary} -t mangle -S");
        let lines = self
            .io
            .lines(&show, window)
            .await
            .map_err(map_effect_failure)?;
        let definition = format!("-N {}", contract.chain_name());
        if !lines.iter().any(|line| line == &definition) {
            return Ok(());
        }
        let expected = if ipv4 {
            contract.ipv4_owned_chain_lines()
        } else {
            contract.ipv6_owned_chain_lines()
        }
        .ok_or(RootPolicyFailure::ExactCleanupFailed)?;
        let prefix = format!("-A {} ", contract.chain_name());
        let actual = lines
            .iter()
            .filter(|line| line.starts_with(&prefix))
            .collect::<Vec<_>>();
        if actual.iter().any(|line| !expected.contains(line)) {
            return Err(RootPolicyFailure::ExactCleanupFailed);
        }
        let flush = contract.flush_chain_command(binary);
        self.io
            .mutate(&flush, window)
            .await
            .map_err(map_effect_failure)?;
        let delete = contract.delete_chain_command(binary);
        self.io
            .mutate(&delete, window)
            .await
            .map_err(map_effect_failure)?;
        let fresh = self
            .io
            .lines(&show, window)
            .await
            .map_err(map_effect_failure)?;
        (!fresh
            .iter()
            .any(|line| line.contains(contract.chain_name())))
        .then_some(())
        .ok_or(RootPolicyFailure::ExactCleanupFailed)
    }

    async fn remove_guard(
        &self,
        contract: &RootPolicyContract,
        ipv4: bool,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyFailure> {
        let show = if ipv4 { IPV4_RULE_SHOW } else { IPV6_RULE_SHOW };
        for _ in 0..MAX_RECONCILE_PASSES {
            let rules = self
                .io
                .lines(show, window)
                .await
                .map_err(map_effect_failure)?;
            let present = if ipv4 {
                rules.iter().any(|line| contract.is_owned_ipv4_guard(line))
            } else {
                rules.iter().any(|line| contract.is_owned_ipv6_guard(line))
            };
            if !present {
                return Ok(());
            }
            let delete = if ipv4 {
                contract.ipv4_guard_delete()
            } else {
                contract.ipv6_guard_delete()
            }
            .ok_or(RootPolicyFailure::ExactCleanupFailed)?;
            self.io
                .mutate(&delete, window)
                .await
                .map_err(map_effect_failure)?;
        }
        Err(RootPolicyFailure::ExactCleanupFailed)
    }
}
fn map_effect_failure(failure: RootPolicyEffectFailure) -> RootPolicyFailure {
    match failure {
        RootPolicyEffectFailure::ObservationUnavailable => {
            RootPolicyFailure::ObservationUnavailable
        }
        RootPolicyEffectFailure::ObservationIncomplete => RootPolicyFailure::ObservationIncomplete,
        RootPolicyEffectFailure::MutationRejected => RootPolicyFailure::MutationRejected,
        RootPolicyEffectFailure::MutationUncertain => RootPolicyFailure::MutationUncertain,
    }
}

fn parse_lines(stdout: &str) -> Vec<String> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

fn phase_diagnostic(
    started: Instant,
    before: RootPolicyCommandWindowDiagnostic,
    after: RootPolicyCommandWindowDiagnostic,
) -> RootPolicyPhaseDiagnostic {
    RootPolicyPhaseDiagnostic {
        elapsed_ms: duration_ms(started.elapsed()),
        commands: after.commands.saturating_sub(before.commands),
        observation_commands: after
            .observation_commands
            .saturating_sub(before.observation_commands),
        mutation_commands: after
            .mutation_commands
            .saturating_sub(before.mutation_commands),
        duplicate_observations: after
            .duplicate_observations
            .saturating_sub(before.duplicate_observations),
    }
}

fn record_reconcile(
    diagnostic: &mut RootPolicyReconcileDiagnostic,
    started: Instant,
    policy_elapsed: Duration,
    window: RootPolicyCommandWindowDiagnostic,
    phases: RootPolicyPhaseDiagnostics,
) {
    let reconcile_ms = duration_ms(started.elapsed());
    let policy_ms = duration_ms(policy_elapsed);
    diagnostic.attempts = diagnostic.attempts.saturating_add(1);
    diagnostic.total_executor_commands = diagnostic
        .total_executor_commands
        .saturating_add(window.commands);
    diagnostic.total_observation_commands = diagnostic
        .total_observation_commands
        .saturating_add(window.observation_commands);
    diagnostic.total_mutation_commands = diagnostic
        .total_mutation_commands
        .saturating_add(window.mutation_commands);
    diagnostic.total_duplicate_observations = diagnostic
        .total_duplicate_observations
        .saturating_add(window.duplicate_observations);
    diagnostic.last_reconcile_elapsed_ms = reconcile_ms;
    diagnostic.max_reconcile_elapsed_ms = diagnostic.max_reconcile_elapsed_ms.max(reconcile_ms);
    diagnostic.last_policy_effect_elapsed_ms = policy_ms;
    diagnostic.max_policy_effect_elapsed_ms =
        diagnostic.max_policy_effect_elapsed_ms.max(policy_ms);
    diagnostic.last_executor_commands = window.commands;
    diagnostic.last_observation_commands = window.observation_commands;
    diagnostic.last_mutation_commands = window.mutation_commands;
    diagnostic.last_duplicate_observations = window.duplicate_observations;
    diagnostic.last_incomplete_or_timed_out_commands = window.incomplete_or_timed_out_commands;
    diagnostic.last_mutation_failures = window.mutation_failures;
    diagnostic.last_phases = phases;
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_vocabulary_retries_only_non_authoritative_or_uncertain_failures() {
        assert!(
            RootPolicyResult::FailClosed(Some(RootPolicyFailure::ObservationUnavailable))
                .retryable()
        );
        assert!(
            RootPolicyResult::FailClosed(Some(RootPolicyFailure::ObservationIncomplete))
                .retryable()
        );
        assert!(
            RootPolicyResult::FailClosed(Some(RootPolicyFailure::MutationUncertain)).retryable()
        );
        assert!(
            !RootPolicyResult::FailClosed(Some(RootPolicyFailure::StructuralMismatch)).retryable()
        );
        assert!(
            !RootPolicyResult::FailClosed(Some(RootPolicyFailure::ReservedPolicyCollision))
                .retryable()
        );
        assert!(
            !RootPolicyResult::FailClosed(Some(RootPolicyFailure::MutationRejected)).retryable()
        );
    }

    struct SupersedingIo {
        current: Arc<std::sync::atomic::AtomicBool>,
        line_calls: std::sync::atomic::AtomicUsize,
        mutation_calls: std::sync::atomic::AtomicUsize,
    }

    impl SupersedingIo {
        fn result(stdout: impl Into<String>) -> crate::root_session::RootCommandResult {
            crate::root_session::RootCommandResult {
                exit_code: 0,
                stdout: stdout.into(),
                timed_out: false,
                output_complete: true,
                session_generation: 1,
            }
        }
    }

    impl RootPolicyIo for SupersedingIo {
        fn session_generation<'a>(
            &'a self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<u64>> + Send + 'a>> {
            Box::pin(async { Some(1) })
        }

        fn raw_observation<'a>(
            &'a self,
            command: &'a str,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<
                            crate::root_session::RootCommandResult,
                            crate::root_session::RootSessionError,
                        >,
                    > + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                let stdout = match command {
                    "id -u" => "0".to_owned(),
                    IPV4_RULE_SHOW => {
                        "0: from all lookup local\n32766: from all lookup main".to_owned()
                    }
                    _ => String::new(),
                };
                Ok(Self::result(stdout))
            })
        }

        fn observe<'a>(
            &'a self,
            _command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<
                            crate::root_session::RootCommandResult,
                            RootPolicyEffectFailure,
                        >,
                    > + Send
                    + 'a,
            >,
        > {
            Box::pin(async { panic!("observation after initial snapshot is not allowed") })
        }

        fn lines<'a>(
            &'a self,
            command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<Output = Result<Vec<String>, RootPolicyEffectFailure>>
                    + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                let lines = match command {
                    IPV4_RULE_SHOW | IPV6_RULE_SHOW => vec![
                        "0: from all lookup local".to_owned(),
                        "32766: from all lookup main".to_owned(),
                    ],
                    _ => Vec::new(),
                };
                let call = self
                    .line_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                    + 1;
                if call == 4 {
                    self.current
                        .store(false, std::sync::atomic::Ordering::SeqCst);
                }
                Ok(lines)
            })
        }

        fn mutate<'a>(
            &'a self,
            _command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<(), RootPolicyEffectFailure>> + Send + 'a>,
        > {
            Box::pin(async move {
                self.mutation_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(())
            })
        }
    }

    struct PreparedFailClosedIo {
        snapshot: RootPolicySnapshot,
        line_calls: std::sync::atomic::AtomicUsize,
        observe_calls: std::sync::atomic::AtomicUsize,
        mutation_calls: std::sync::atomic::AtomicUsize,
    }

    impl PreparedFailClosedIo {
        fn result(
            exit_code: i32,
            stdout: impl Into<String>,
        ) -> crate::root_session::RootCommandResult {
            crate::root_session::RootCommandResult {
                exit_code,
                stdout: stdout.into(),
                timed_out: false,
                output_complete: true,
                session_generation: 1,
            }
        }
    }

    impl RootPolicyIo for PreparedFailClosedIo {
        fn session_generation<'a>(
            &'a self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<u64>> + Send + 'a>> {
            Box::pin(async { Some(1) })
        }

        fn raw_observation<'a>(
            &'a self,
            command: &'a str,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<
                            crate::root_session::RootCommandResult,
                            crate::root_session::RootSessionError,
                        >,
                    > + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                let stdout = match command {
                    "id -u" => "0".to_owned(),
                    IPV4_RULE_SHOW => self.snapshot.ipv4_rules.join("\n"),
                    _ => String::new(),
                };
                Ok(Self::result(0, stdout))
            })
        }

        fn observe<'a>(
            &'a self,
            _command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Result<
                            crate::root_session::RootCommandResult,
                            RootPolicyEffectFailure,
                        >,
                    > + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                self.observe_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(Self::result(1, ""))
            })
        }

        fn lines<'a>(
            &'a self,
            command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<Output = Result<Vec<String>, RootPolicyEffectFailure>>
                    + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                self.line_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let lines = if command == IPV4_RULE_SHOW {
                    self.snapshot.ipv4_rules.clone()
                } else if command == IPV6_RULE_SHOW {
                    self.snapshot.ipv6_rules.clone()
                } else if command == format!("{IPTABLES} -t mangle -S") {
                    self.snapshot.ipv4_mangle.clone()
                } else if command == format!("{IP6TABLES} -t mangle -S") {
                    self.snapshot.ipv6_mangle.clone()
                } else {
                    panic!("unexpected line observation: {command}");
                };
                Ok(lines)
            })
        }

        fn mutate<'a>(
            &'a self,
            _command: &'a str,
            _window: &'a mut RootPolicyCommandWindow,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<(), RootPolicyEffectFailure>> + Send + 'a>,
        > {
            Box::pin(async move {
                self.mutation_calls
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(())
            })
        }
    }

    fn prepared_fail_closed_snapshot(product_uid: u32) -> RootPolicySnapshot {
        let mut contract =
            RootPolicyContract::new(product_uid, RootPolicyNamespace::Release).expect("contract");
        let empty = RootPolicySnapshot::new(
            vec![
                "0: from all lookup local".to_owned(),
                "32766: from all lookup main".to_owned(),
            ],
            vec![
                "0: from all lookup local".to_owned(),
                "32766: from all lookup main".to_owned(),
            ],
            Vec::new(),
            Vec::new(),
        );
        let PolicyIdentityResolution::Selected(identity) = contract.resolve_identity(&empty) else {
            panic!("identity");
        };
        let mark = identity.mark_hex();
        let guard = format!(
            "{}: from all fwmark {mark}/{mark} unreachable",
            identity.guard_priority()
        );
        let mut ipv4_mangle = vec![format!("-N {}", contract.chain_name())];
        ipv4_mangle.extend(contract.ipv4_owned_chain_lines().expect("ipv4 chain"));
        ipv4_mangle.push(contract.output_jump());
        let mut ipv6_mangle = vec![format!("-N {}", contract.chain_name())];
        ipv6_mangle.extend(contract.ipv6_owned_chain_lines().expect("ipv6 chain"));
        ipv6_mangle.push(contract.output_jump());

        RootPolicySnapshot::new(vec![guard.clone()], vec![guard], ipv4_mangle, ipv6_mangle)
    }

    #[tokio::test]
    async fn prepared_initial_snapshot_skips_redundant_prepare_reads_but_keeps_final_verify() {
        let product_uid = 10_123;
        let io = Arc::new(PreparedFailClosedIo {
            snapshot: prepared_fail_closed_snapshot(product_uid),
            line_calls: std::sync::atomic::AtomicUsize::new(0),
            observe_calls: std::sync::atomic::AtomicUsize::new(0),
            mutation_calls: std::sync::atomic::AtomicUsize::new(0),
        });
        let runtime = RootPolicyRuntime::with_io(
            Arc::clone(&io) as Arc<dyn RootPolicyIo>,
            product_uid,
            RootPolicyNamespace::Release,
        )
        .expect("root policy runtime");

        let result = runtime.reconcile_if_current(false, None, || true).await;

        assert_eq!(
            result,
            RootPolicyReconcileOutcome::Completed(RootPolicyResult::FailClosed(None))
        );
        assert_eq!(
            io.line_calls.load(std::sync::atomic::Ordering::SeqCst),
            8,
            "only initial snapshot plus final fail-closed verification should read full state"
        );
        assert_eq!(
            io.observe_calls.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "legacy selector absence still uses its exact checks"
        );
        assert_eq!(
            io.mutation_calls.load(std::sync::atomic::Ordering::SeqCst),
            0
        );
    }

    #[tokio::test]
    async fn superseded_after_initial_snapshot_stops_before_first_policy_mutation() {
        let current = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let io = Arc::new(SupersedingIo {
            current: Arc::clone(&current),
            line_calls: std::sync::atomic::AtomicUsize::new(0),
            mutation_calls: std::sync::atomic::AtomicUsize::new(0),
        });
        let runtime = RootPolicyRuntime::with_io(
            Arc::clone(&io) as Arc<dyn RootPolicyIo>,
            10_123,
            RootPolicyNamespace::Release,
        )
        .expect("root policy runtime");
        let current_for_check = Arc::clone(&current);

        let result = runtime
            .reconcile_if_current(true, Some("rmnet_data0"), move || {
                current_for_check.load(std::sync::atomic::Ordering::SeqCst)
            })
            .await;

        assert_eq!(result, RootPolicyReconcileOutcome::Superseded);
        assert_eq!(io.line_calls.load(std::sync::atomic::Ordering::SeqCst), 4);
        assert_eq!(
            io.mutation_calls.load(std::sync::atomic::Ordering::SeqCst),
            0
        );
    }
}
