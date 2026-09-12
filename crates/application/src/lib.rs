//! Cross-owner application use-cases.
//!
//! This crate owns no leaf product facts. D2 adds the bounded authenticated DNS+TLS probe as a
//! genuine cross-owner use-case. The concrete platform/network effect is injected; this layer
//! binds observations to exact owner generations/versions and owns only the monotonic freshness
//! sequence needed to reject stale asynchronous probe completions.

use mish_readiness::{EgressProbeObservation, FreshnessMarker, ProbeBinding, ProbeOutcome};
use std::time::{Duration, Instant};

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

    pub fn complete(
        &self,
        ticket: ProbeTicket,
        outcome: ProbeOutcome,
    ) -> Option<EgressProbeObservation> {
        if self.current != Some(ticket) {
            return None;
        }
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
    let deadline = Instant::now()
        .checked_add(budget)
        .ok_or(EgressProbeError::DeadlineOverflow)?;
    let reported = effect.execute(deadline);
    let outcome = if Instant::now() >= deadline {
        ProbeOutcome::Timeout
    } else {
        reported
    };
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
    fn coordinator_invalidates_late_completion_on_owner_change() {
        let mut coordinator = EgressProbeCoordinator::new();
        let old = coordinator.begin(binding()).expect("ticket");
        let invalidated = coordinator.invalidate().expect("invalidate");
        assert_ne!(invalidated, old.freshness());
        assert_eq!(coordinator.complete(old, ProbeOutcome::Succeeded), None);
        assert_eq!(coordinator.expected_freshness(), Some(invalidated));
    }

    #[test]
    fn newer_ticket_rejects_older_completion() {
        let mut coordinator = EgressProbeCoordinator::new();
        let old = coordinator.begin(binding()).expect("old ticket");
        let current = coordinator.begin(binding()).expect("current ticket");
        assert_eq!(coordinator.complete(old, ProbeOutcome::Succeeded), None);
        let observation = coordinator
            .complete(current, ProbeOutcome::Succeeded)
            .expect("current observation");
        assert_eq!(observation.freshness, current.freshness());
        assert_eq!(
            coordinator.expected_freshness(),
            Some(current.freshness()),
        );
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
