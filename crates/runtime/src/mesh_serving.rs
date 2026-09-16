/// Cross-owner runtime composition policy for realizing public Mesh ingress.
///
/// Android supplies current owner projections and executes the platform effect, but it must not
/// independently decide when Proxy Serving + Readiness + Mesh admission are sufficient to expose
/// public ingress.
pub const fn mesh_ingress_serving_allowed(
    proxy_running: bool,
    readiness_ready: bool,
    mesh_admitted: bool,
    admission_epoch_present: bool,
) -> bool {
    proxy_running && readiness_ready && mesh_admitted && admission_epoch_present
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ingress_requires_every_current_owner_fact() {
        assert!(mesh_ingress_serving_allowed(true, true, true, true));

        for facts in [
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false),
        ] {
            assert!(!mesh_ingress_serving_allowed(
                facts.0, facts.1, facts.2, facts.3
            ));
        }
    }
}
