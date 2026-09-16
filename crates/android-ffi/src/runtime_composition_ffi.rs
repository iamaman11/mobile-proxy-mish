use crate::ProductReadinessState;
use mish_runtime::mesh_ingress_serving_allowed as owner_mesh_ingress_serving_allowed;

/// Thin UniFFI projection of cross-owner runtime composition policy.
/// Android supplies current owner projections and executes effects; Rust decides eligibility.
#[uniffi::export]
pub fn mesh_ingress_serving_allowed(
    proxy_running: bool,
    readiness: ProductReadinessState,
    mesh_admitted: bool,
    admission_epoch_present: bool,
) -> bool {
    owner_mesh_ingress_serving_allowed(
        proxy_running,
        readiness == ProductReadinessState::Ready,
        mesh_admitted,
        admission_epoch_present,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_delegates_mesh_serving_policy_to_runtime() {
        assert!(mesh_ingress_serving_allowed(
            true,
            ProductReadinessState::Ready,
            true,
            true,
        ));
        assert!(!mesh_ingress_serving_allowed(
            true,
            ProductReadinessState::Degraded,
            true,
            true,
        ));
    }
}
