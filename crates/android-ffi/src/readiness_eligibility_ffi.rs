use crate::{ProbeBindingView, ProductReadinessFactsView, ReadinessBoundaryError};
use mish_readiness::{
    CellularOwnerGeneration, CellularReadinessFact, CredentialReadinessFact, CredentialVersion,
    MeshAdmissionEpoch, MeshReadinessFact, ProbeEligibility, ProductReadinessInput,
    ProxyReadinessFact, ProxyServingGeneration, RuntimeGeneration, RuntimeReadinessFact,
    probe_eligibility,
};

/// Thin adapter from flattened UniFFI facts to the single Rust readiness eligibility predicate.
#[uniffi::export]
pub fn readiness_probe_binding_if_eligible(
    facts: ProductReadinessFactsView,
) -> Result<Option<ProbeBindingView>, ReadinessBoundaryError> {
    let input = map_facts(facts)?;
    Ok(match probe_eligibility(input) {
        ProbeEligibility::Eligible(binding) => Some(ProbeBindingView {
            cellular_owner_generation: binding.cellular_owner_generation.raw(),
            runtime_generation: binding.runtime_generation.raw(),
            proxy_serving_generation: binding.proxy_serving_generation.raw(),
            mesh_admission_epoch: binding.mesh_admission_epoch.raw(),
            credential_version: binding.credential_version.raw(),
        }),
        ProbeEligibility::NotReady | ProbeEligibility::Unknown => None,
    })
}

fn map_facts(
    facts: ProductReadinessFactsView,
) -> Result<ProductReadinessInput, ReadinessBoundaryError> {
    let cellular = facts
        .cellular_owner_generation
        .map(|raw| {
            Ok(CellularReadinessFact {
                owner_generation: cellular_generation(raw)?,
                admitted: facts.cellular_admitted,
                root_policy_verified: facts.root_policy_verified,
            })
        })
        .transpose()?;

    let runtime = facts
        .runtime_generation
        .map(|raw| {
            Ok(RuntimeReadinessFact {
                generation: runtime_generation(raw)?,
            })
        })
        .transpose()?;

    let proxy = match facts.proxy_runtime_generation {
        Some(runtime_raw) => Some(ProxyReadinessFact {
            runtime_generation: runtime_generation(runtime_raw)?,
            serving_generation: facts
                .proxy_serving_generation
                .map(proxy_generation)
                .transpose()?,
            credential_version: facts
                .proxy_credential_version
                .map(credential_version)
                .transpose()?,
            healthy: facts.proxy_healthy,
        }),
        None => {
            if facts.proxy_serving_generation.is_some() || facts.proxy_credential_version.is_some()
            {
                return Err(ReadinessBoundaryError::InvalidOwnerKey);
            }
            None
        }
    };

    let credential = facts
        .credential_version
        .map(|raw| {
            Ok(CredentialReadinessFact {
                version: credential_version(raw)?,
                active: facts.credential_active,
            })
        })
        .transpose()?;

    let mesh = facts
        .mesh_runtime_generation
        .map(|raw| {
            Ok(MeshReadinessFact {
                runtime_generation: runtime_generation(raw)?,
                admission_epoch: facts.mesh_admission_epoch.map(mesh_epoch).transpose()?,
                admitted: facts.mesh_admitted,
                ingress_running: facts.mesh_ingress_running,
            })
        })
        .transpose()?;

    Ok(ProductReadinessInput {
        cellular,
        runtime,
        proxy,
        credential,
        mesh,
        expected_freshness: None,
        probe: None,
    })
}

fn cellular_generation(raw: u64) -> Result<CellularOwnerGeneration, ReadinessBoundaryError> {
    CellularOwnerGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn runtime_generation(raw: u64) -> Result<RuntimeGeneration, ReadinessBoundaryError> {
    RuntimeGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn proxy_generation(raw: u64) -> Result<ProxyServingGeneration, ReadinessBoundaryError> {
    ProxyServingGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn mesh_epoch(raw: u64) -> Result<MeshAdmissionEpoch, ReadinessBoundaryError> {
    MeshAdmissionEpoch::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn credential_version(raw: u64) -> Result<CredentialVersion, ReadinessBoundaryError> {
    CredentialVersion::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eligible_facts() -> ProductReadinessFactsView {
        ProductReadinessFactsView {
            cellular_owner_generation: Some(11),
            cellular_admitted: true,
            root_policy_verified: true,
            runtime_generation: Some(21),
            proxy_runtime_generation: Some(21),
            proxy_serving_generation: Some(31),
            proxy_credential_version: Some(51),
            proxy_healthy: true,
            credential_version: Some(51),
            credential_active: true,
            mesh_runtime_generation: Some(21),
            mesh_admission_epoch: Some(41),
            mesh_admitted: true,
            mesh_ingress_running: false,
        }
    }

    #[test]
    fn ffi_returns_exact_binding_only_for_eligible_facts() {
        let binding = readiness_probe_binding_if_eligible(eligible_facts())
            .expect("eligibility")
            .expect("binding");
        assert_eq!(binding.cellular_owner_generation, 11);
        assert_eq!(binding.runtime_generation, 21);
        assert_eq!(binding.proxy_serving_generation, 31);
        assert_eq!(binding.mesh_admission_epoch, 41);
        assert_eq!(binding.credential_version, 51);

        let mut blocked = eligible_facts();
        blocked.root_policy_verified = false;
        assert_eq!(
            readiness_probe_binding_if_eligible(blocked).expect("blocked"),
            None
        );
    }
}
