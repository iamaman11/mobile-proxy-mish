//! Single derived product Readiness Projection.
//!
//! This crate is a terminal projection sink. It owns no leaf facts, performs no I/O, owns no
//! timers/sockets, and stores no mutable readiness state. Callers supply immutable projections
//! from the natural owners plus one generation-bound probe observation.

macro_rules! generation_key {
    ($name:ident) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(u64);

        impl $name {
            pub const fn new(raw: u64) -> Option<Self> {
                if raw == 0 { None } else { Some(Self(raw)) }
            }

            pub const fn raw(self) -> u64 {
                self.0
            }
        }
    };
}

generation_key!(CellularOwnerGeneration);
generation_key!(RuntimeGeneration);
generation_key!(ProxyServingGeneration);
generation_key!(MeshAdmissionEpoch);
generation_key!(CredentialVersion);
generation_key!(FreshnessMarker);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    NotReady,
    Degraded,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    Succeeded,
    DnsFailed,
    TlsFailed,
    AuthenticationFailed,
    TransportFailed,
    Timeout,
}

/// Exact non-secret owner keys captured for one authenticated egress probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeBinding {
    pub cellular_owner_generation: CellularOwnerGeneration,
    pub runtime_generation: RuntimeGeneration,
    pub proxy_serving_generation: ProxyServingGeneration,
    pub mesh_admission_epoch: MeshAdmissionEpoch,
    pub credential_version: CredentialVersion,
}

/// One immutable DNS+TLS+authentication effect observation. Successful DNS is represented only
/// here rather than as a separately cached readiness fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EgressProbeObservation {
    pub outcome: ProbeOutcome,
    pub binding: ProbeBinding,
    pub freshness: FreshnessMarker,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularReadinessFact {
    pub owner_generation: CellularOwnerGeneration,
    pub admitted: bool,
    pub root_policy_verified: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeReadinessFact {
    pub generation: RuntimeGeneration,
    pub private_bridge_healthy: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyReadinessFact {
    pub runtime_generation: RuntimeGeneration,
    pub serving_generation: Option<ProxyServingGeneration>,
    pub credential_version: CredentialVersion,
    pub healthy: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CredentialReadinessFact {
    pub version: CredentialVersion,
    pub active: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshReadinessFact {
    pub runtime_generation: RuntimeGeneration,
    pub admission_epoch: Option<MeshAdmissionEpoch>,
    pub admitted: bool,
    pub ingress_running: bool,
}

/// Ephemeral projection input assembled from natural-owner observations. No value is stored here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductReadinessInput {
    pub cellular: Option<CellularReadinessFact>,
    pub runtime: Option<RuntimeReadinessFact>,
    pub proxy: Option<ProxyReadinessFact>,
    pub credential: Option<CredentialReadinessFact>,
    pub mesh: Option<MeshReadinessFact>,
    pub expected_freshness: Option<FreshnessMarker>,
    pub probe: Option<EgressProbeObservation>,
}

/// Pure terminal projection. No listener/process liveness fact can independently produce READY.
pub fn project(input: ProductReadinessInput) -> Readiness {
    let (Some(cellular), Some(runtime), Some(proxy), Some(credential), Some(mesh)) = (
        input.cellular,
        input.runtime,
        input.proxy,
        input.credential,
        input.mesh,
    ) else {
        return Readiness::Unknown;
    };

    if !cellular.admitted
        || !cellular.root_policy_verified
        || !runtime.private_bridge_healthy
        || !proxy.healthy
        || !credential.active
        || !mesh.admitted
        || !mesh.ingress_running
    {
        return Readiness::NotReady;
    }

    if proxy.runtime_generation != runtime.generation
        || mesh.runtime_generation != runtime.generation
        || proxy.credential_version != credential.version
    {
        return Readiness::Unknown;
    }

    let (Some(proxy_serving_generation), Some(mesh_admission_epoch)) =
        (proxy.serving_generation, mesh.admission_epoch)
    else {
        return Readiness::Unknown;
    };
    let Some(expected_freshness) = input.expected_freshness else {
        return Readiness::Unknown;
    };
    let Some(probe) = input.probe else {
        return Readiness::Unknown;
    };
    let current_binding = ProbeBinding {
        cellular_owner_generation: cellular.owner_generation,
        runtime_generation: runtime.generation,
        proxy_serving_generation,
        mesh_admission_epoch,
        credential_version: credential.version,
    };
    if probe.binding != current_binding || probe.freshness != expected_freshness {
        return Readiness::Unknown;
    }

    match probe.outcome {
        ProbeOutcome::Succeeded => Readiness::Ready,
        ProbeOutcome::DnsFailed
        | ProbeOutcome::TlsFailed
        | ProbeOutcome::AuthenticationFailed
        | ProbeOutcome::TransportFailed
        | ProbeOutcome::Timeout => Readiness::Degraded,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cellular_generation(raw: u64) -> CellularOwnerGeneration {
        CellularOwnerGeneration::new(raw).expect("cellular generation")
    }

    fn runtime_generation(raw: u64) -> RuntimeGeneration {
        RuntimeGeneration::new(raw).expect("runtime generation")
    }

    fn proxy_generation(raw: u64) -> ProxyServingGeneration {
        ProxyServingGeneration::new(raw).expect("proxy generation")
    }

    fn mesh_epoch(raw: u64) -> MeshAdmissionEpoch {
        MeshAdmissionEpoch::new(raw).expect("mesh epoch")
    }

    fn credential_version(raw: u64) -> CredentialVersion {
        CredentialVersion::new(raw).expect("credential version")
    }

    fn freshness(raw: u64) -> FreshnessMarker {
        FreshnessMarker::new(raw).expect("freshness marker")
    }

    fn ready_input() -> ProductReadinessInput {
        let binding = ProbeBinding {
            cellular_owner_generation: cellular_generation(11),
            runtime_generation: runtime_generation(21),
            proxy_serving_generation: proxy_generation(31),
            mesh_admission_epoch: mesh_epoch(41),
            credential_version: credential_version(51),
        };
        ProductReadinessInput {
            cellular: Some(CellularReadinessFact {
                owner_generation: binding.cellular_owner_generation,
                admitted: true,
                root_policy_verified: true,
            }),
            runtime: Some(RuntimeReadinessFact {
                generation: binding.runtime_generation,
                private_bridge_healthy: true,
            }),
            proxy: Some(ProxyReadinessFact {
                runtime_generation: binding.runtime_generation,
                serving_generation: Some(binding.proxy_serving_generation),
                credential_version: binding.credential_version,
                healthy: true,
            }),
            credential: Some(CredentialReadinessFact {
                version: binding.credential_version,
                active: true,
            }),
            mesh: Some(MeshReadinessFact {
                runtime_generation: binding.runtime_generation,
                admission_epoch: Some(binding.mesh_admission_epoch),
                admitted: true,
                ingress_running: true,
            }),
            expected_freshness: Some(freshness(61)),
            probe: Some(EgressProbeObservation {
                outcome: ProbeOutcome::Succeeded,
                binding,
                freshness: freshness(61),
            }),
        }
    }

    #[test]
    fn coherent_success_is_ready() {
        assert_eq!(project(ready_input()), Readiness::Ready);
    }

    #[test]
    fn missing_leaf_probe_or_freshness_is_unknown() {
        let mut missing_leaf = ready_input();
        missing_leaf.mesh = None;
        assert_eq!(project(missing_leaf), Readiness::Unknown);

        let mut missing_probe = ready_input();
        missing_probe.probe = None;
        assert_eq!(project(missing_probe), Readiness::Unknown);

        let mut missing_freshness = ready_input();
        missing_freshness.expected_freshness = None;
        assert_eq!(project(missing_freshness), Readiness::Unknown);
    }

    #[test]
    fn explicit_leaf_failure_is_not_ready_even_without_serving_epoch() {
        let mut input = ready_input();
        input
            .cellular
            .as_mut()
            .expect("cellular")
            .root_policy_verified = false;
        assert_eq!(project(input), Readiness::NotReady);

        let mut input = ready_input();
        let mesh = input.mesh.as_mut().expect("mesh");
        mesh.ingress_running = false;
        mesh.admission_epoch = None;
        assert_eq!(project(input), Readiness::NotReady);

        let mut input = ready_input();
        let proxy = input.proxy.as_mut().expect("proxy");
        proxy.healthy = false;
        proxy.serving_generation = None;
        assert_eq!(project(input), Readiness::NotReady);

        let mut input = ready_input();
        input.credential.as_mut().expect("credential").active = false;
        assert_eq!(project(input), Readiness::NotReady);
    }

    #[test]
    fn generation_or_version_mismatch_never_becomes_ready() {
        let mut input = ready_input();
        input.proxy.as_mut().expect("proxy").runtime_generation = runtime_generation(22);
        assert_eq!(project(input), Readiness::Unknown);

        let mut input = ready_input();
        input.proxy.as_mut().expect("proxy").credential_version = credential_version(52);
        assert_eq!(project(input), Readiness::Unknown);

        let mut input = ready_input();
        input
            .probe
            .as_mut()
            .expect("probe")
            .binding
            .mesh_admission_epoch = mesh_epoch(42);
        assert_eq!(project(input), Readiness::Unknown);
    }

    #[test]
    fn stale_probe_marker_never_becomes_ready() {
        let mut input = ready_input();
        input.probe.as_mut().expect("probe").freshness = freshness(62);
        assert_eq!(project(input), Readiness::Unknown);
    }

    #[test]
    fn current_failed_probe_is_degraded() {
        for outcome in [
            ProbeOutcome::DnsFailed,
            ProbeOutcome::TlsFailed,
            ProbeOutcome::AuthenticationFailed,
            ProbeOutcome::TransportFailed,
            ProbeOutcome::Timeout,
        ] {
            let mut input = ready_input();
            input.probe.as_mut().expect("probe").outcome = outcome;
            assert_eq!(project(input), Readiness::Degraded);
        }
    }
}
