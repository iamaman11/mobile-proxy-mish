//! Cross-owner application use-cases.
//!
//! This crate owns no leaf product facts. D2 adds the bounded authenticated DNS+TLS probe as a
//! genuine cross-owner use-case. The concrete platform/network effect is injected; this layer
//! binds its observation to exact owner generations/versions and an explicit freshness marker.

use mish_readiness::{EgressProbeObservation, FreshnessMarker, ProbeBinding, ProbeOutcome};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EgressProbeError {
    ZeroBudget,
    DeadlineOverflow,
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
