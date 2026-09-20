use mish_transport::{MAX_MESH_SESSIONS, MeshSessionOwner};

#[test]
fn five_hundred_thirteenth_mesh_session_is_rejected_by_transport_owner() {
    assert_eq!(
        MAX_MESH_SESSIONS, 512,
        "PRODUCT external Mesh capacity changed unexpectedly"
    );

    let owner = MeshSessionOwner::product_generation();
    let mut admitted = Vec::with_capacity(MAX_MESH_SESSIONS);
    for _ in 0..MAX_MESH_SESSIONS {
        admitted.push(owner.try_admit().expect("session within Transport budget"));
    }

    assert_eq!(owner.active_sessions(), MAX_MESH_SESSIONS);
    assert!(
        owner.try_admit().is_none(),
        "513th session must be rejected before runtime/backend execution"
    );
    assert_eq!(owner.active_sessions(), MAX_MESH_SESSIONS);

    owner.revoke();
    assert!(
        owner.try_admit().is_none(),
        "revoked generation must fail closed"
    );
    drop(admitted);
    assert_eq!(owner.active_sessions(), 0);
}
