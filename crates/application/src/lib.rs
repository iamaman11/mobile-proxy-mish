//! Cross-owner application use-cases.
//!
//! This crate owns no leaf product facts. D2 adds the bounded authenticated DNS+TLS probe as a
//! genuine cross-owner use-case. The concrete platform/network effect is injected; this layer
//! binds observations to exact owner generations/versions and owns only the monotonic freshness
//! sequence needed to reject stale asynchronous probe completions.

use mish_readiness::{EgressProbeObservation, FreshnessMarker, ProbeBinding, ProbeOutcome};
use std::time::{Duration, Instant};

/// One bounded end-to-end probe may wait for cellular-owned DNS, public TCP and TLS under the
/// existing 15-second private-bridge operation timeout, with a small outer margin for local proxy
/// CONNECT/auth and TLS bookkeeping. This is an operation deadline, not a readiness TTL.
pub const DEFAULT_EGRESS_PROBE_BUDGET: Duration = Duration::from_secs(20);

/**
 * Low-duty-cycle refresh for one already-coherent readiness binding.
 *
 * This is readiness/application policy, not an Android timer owner. Android may schedule one
 * delayed effect using this value; every refresh still obtains a new Rust-owned freshness ticket
 * and is rejected if owner identity changes before completion. The delay is intentionally longer
 * than the probe budget so one slow probe cannot overlap the next refresh.
 */
pub const DEFAULT_EGRESS_PROBE_REFRESH_DELAY: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EgressProbeError {
    ZeroBudget,
    DeadlineOverflow,
    FreshnessExhausted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeTicket {
    binding: ProbeBinding,
    freshness: FreshnessMarker,
}

impl ProbeTicket {
    pub const fn from_parts(binding: ProbeBinding, freshness: FreshnessMarker) -> Self {
        Self { binding, freshness }
    }

    pub const fn binding(self) -> ProbeBinding {
        self.binding
    }

    pub const fn freshness(self) -> FreshnessMarker {
        self.freshness
    }
}

/// Application-use-case coordinator only. It owns no readiness value and no leaf fact; its sole
/// state is a monotonic freshness sequence plus the exact currently issued probe ticket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EgressProbeCoordinator {
    last_freshness: u64,
    current: Option<ProbeTicket>,
}

impl Default for EgressProbeCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl EgressProbeCoordinator {
    pub const fn new() -> Self {
        Self {
            last_freshness: 0,
            current: None,
        }
    }

    pub fn begin(&mut self, binding: ProbeBinding) -> Result<ProbeTicket, EgressProbeError> {
        let freshness = self.next_freshness()?;
        let ticket = ProbeTicket::from_parts(binding, freshness);
        self.current = Some(ticket);
        Ok(ticket)
    }

    /// Invalidates any in-flight/completed observation when structural owner facts change before
    /// a fresh probe can be issued. A late completion from the previous ticket is then ignored.
    pub fn invalidate(&mut self) -> Result<FreshnessMarker, EgressProbeError> {
        let freshness = self.next_freshness()?;
        self.current = None;
        Ok(freshness)
    }

    pub const fn expected_freshness(self) -> Option<FreshnessMarker> {
        FreshnessMarker::new(self.last_freshness)
    }

    /// Consumes exactly one current ticket. Duplicate or late completion is ignored. The
    /// application layer, not the platform adapter, owns timeout classification for the shared
    /// probe budget.
    pub fn complete_bounded(
        &mut self,
        ticket: ProbeTicket,
        reported: ProbeOutcome,
        elapsed: Duration,
        budget: Duration,
    ) -> Option<EgressProbeObservation> {
        if self.current != Some(ticket) {
            return None;
        }
        self.current = None;
        let outcome = classify_outcome(reported, elapsed >= budget);
        Some(EgressProbeObservation {
            outcome,
            binding: ticket.binding,
            freshness: ticket.freshness,
        })
    }

    fn next_freshness(&mut self) -> Result<FreshnessMarker, EgressProbeError> {
        let raw = self
            .last_freshness
            .checked_add(1)
            .ok_or(EgressProbeError::FreshnessExhausted)?;
        let freshness = FreshnessMarker::new(raw).ok_or(EgressProbeError::FreshnessExhausted)?;
        self.last_freshness = raw;
        Ok(freshness)
    }
}

fn classify_outcome(reported: ProbeOutcome, timed_out: bool) -> ProbeOutcome {
    if timed_out {
        ProbeOutcome::Timeout
    } else {
        reported
    }
}

/// Injected concrete authenticated DNS+TLS effect. The effect must finish under `deadline` and
/// must not create fallback resolver/routing ownership. Secrets stay inside the concrete adapter.
pub trait AuthenticatedDnsTlsProbeEffect {
    fn execute(&self, deadline: Instant) -> ProbeOutcome;
}

impl<F> AuthenticatedDnsTlsProbeEffect for F
where
    F: Fn(Instant) -> ProbeOutcome,
{
    fn execute(&self, deadline: Instant) -> ProbeOutcome {
        self(deadline)
    }
}

/// Executes one bounded probe and returns an immutable observation carrying only non-secret
/// generation/version/freshness keys plus a typed outcome.
pub fn run_authenticated_egress_probe(
    binding: ProbeBinding,
    freshness: FreshnessMarker,
    budget: Duration,
    effect: &impl AuthenticatedDnsTlsProbeEffect,
) -> Result<EgressProbeObservation, EgressProbeError> {
    if budget.is_zero() {
        return Err(EgressProbeError::ZeroBudget);
    }
    let started = Instant::now();
    let deadline = started
        .checked_add(budget)
        .ok_or(EgressProbeError::DeadlineOverflow)?;
    let reported = effect.execute(deadline);
    let outcome = classify_outcome(reported, Instant::now().duration_since(started) >= budget);
    Ok(EgressProbeObservation {
        outcome,
        binding,
        freshness,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_readiness::{
        CellularOwnerGeneration, CredentialVersion, MeshAdmissionEpoch, ProxyServingGeneration,
        RuntimeGeneration,
    };
    use std::thread;

    fn binding() -> ProbeBinding {
        ProbeBinding {
            cellular_owner_generation: CellularOwnerGeneration::new(1).expect("cellular"),
            runtime_generation: RuntimeGeneration::new(2).expect("runtime"),
            proxy_serving_generation: ProxyServingGeneration::new(3).expect("proxy"),
            mesh_admission_epoch: MeshAdmissionEpoch::new(4).expect("mesh"),
            credential_version: CredentialVersion::new(5).expect("credential"),
        }
    }

    #[test]
    fn readiness_refresh_delay_is_bounded_and_exceeds_one_probe_budget() {
        assert_eq!(DEFAULT_EGRESS_PROBE_REFRESH_DELAY, Duration::from_secs(60));
        assert!(DEFAULT_EGRESS_PROBE_REFRESH_DELAY > DEFAULT_EGRESS_PROBE_BUDGET);
    }

    #[test]
    fn coordinator_invalidates_late_completion_on_owner_change() {
        let mut coordinator = EgressProbeCoordinator::new();
        let old = coordinator.begin(binding()).expect("ticket");
        let invalidated = coordinator.invalidate().expect("invalidate");
        assert_ne!(invalidated, old.freshness());
        assert_eq!(
            coordinator.complete_bounded(
                old,
                ProbeOutcome::Succeeded,
                Duration::ZERO,
                DEFAULT_EGRESS_PROBE_BUDGET,
            ),
            None,
        );
        assert_eq!(coordinator.expected_freshness(), Some(invalidated));
    }

    #[test]
    fn newer_ticket_rejects_older_completion_and_is_single_use() {
        let mut coordinator = EgressProbeCoordinator::new();
        let old = coordinator.begin(binding()).expect("old ticket");
        let current = coordinator.begin(binding()).expect("current ticket");
        assert_eq!(
            coordinator.complete_bounded(
                old,
                ProbeOutcome::Succeeded,
                Duration::ZERO,
                DEFAULT_EGRESS_PROBE_BUDGET,
            ),
            None,
        );
        let observation = coordinator
            .complete_bounded(
                current,
                ProbeOutcome::Succeeded,
                Duration::ZERO,
                DEFAULT_EGRESS_PROBE_BUDGET,
            )
            .expect("current observation");
        assert_eq!(observation.freshness, current.freshness());
        assert_eq!(coordinator.expected_freshness(), Some(current.freshness()),);
        assert_eq!(
            coordinator.complete_bounded(
                current,
                ProbeOutcome::TlsFailed,
                Duration::ZERO,
                DEFAULT_EGRESS_PROBE_BUDGET,
            ),
            None,
        );
    }

    #[test]
    fn coordinator_owns_budget_timeout_classification() {
        let mut coordinator = EgressProbeCoordinator::new();
        let ticket = coordinator.begin(binding()).expect("ticket");
        let observation = coordinator
            .complete_bounded(
                ticket,
                ProbeOutcome::Succeeded,
                DEFAULT_EGRESS_PROBE_BUDGET,
                DEFAULT_EGRESS_PROBE_BUDGET,
            )
            .expect("observation");
        assert_eq!(observation.outcome, ProbeOutcome::Timeout);
    }

    #[test]
    fn zero_budget_is_rejected_before_effect() {
        let invoked = std::cell::Cell::new(false);
        let result = run_authenticated_egress_probe(
            binding(),
            FreshnessMarker::new(6).expect("freshness"),
            Duration::ZERO,
            &|_| {
                invoked.set(true);
                ProbeOutcome::Succeeded
            },
        );
        assert_eq!(result, Err(EgressProbeError::ZeroBudget));
        assert!(!invoked.get());
    }

    #[test]
    fn observation_preserves_exact_binding_and_marker() {
        let expected_binding = binding();
        let expected_freshness = FreshnessMarker::new(6).expect("freshness");
        let observation = run_authenticated_egress_probe(
            expected_binding,
            expected_freshness,
            Duration::from_secs(1),
            &|deadline| {
                assert!(deadline > Instant::now());
                ProbeOutcome::Succeeded
            },
        )
        .expect("probe");
        assert_eq!(observation.binding, expected_binding);
        assert_eq!(observation.freshness, expected_freshness);
        assert_eq!(observation.outcome, ProbeOutcome::Succeeded);
    }

    #[test]
    fn typed_failure_is_preserved_when_within_budget() {
        let observation = run_authenticated_egress_probe(
            binding(),
            FreshnessMarker::new(6).expect("freshness"),
            Duration::from_secs(1),
            &|_| ProbeOutcome::AuthenticationFailed,
        )
        .expect("probe");
        assert_eq!(observation.outcome, ProbeOutcome::AuthenticationFailed);
    }

    #[test]
    fn effect_finishing_after_deadline_is_timeout() {
        let observation = run_authenticated_egress_probe(
            binding(),
            FreshnessMarker::new(6).expect("freshness"),
            Duration::from_millis(1),
            &|_| {
                thread::sleep(Duration::from_millis(5));
                ProbeOutcome::Succeeded
            },
        )
        .expect("probe");
        assert_eq!(observation.outcome, ProbeOutcome::Timeout);
    }
}
