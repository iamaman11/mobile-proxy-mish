use mish_configuration::EXTERNAL_TCP_SESSION_BUDGET;
use mish_transport::MAX_MESH_SESSIONS;

#[test]
fn mesh_ingress_uses_the_single_external_session_budget() {
    assert_eq!(EXTERNAL_TCP_SESSION_BUDGET, 64);
    assert_eq!(MAX_MESH_SESSIONS, EXTERNAL_TCP_SESSION_BUDGET);
}
