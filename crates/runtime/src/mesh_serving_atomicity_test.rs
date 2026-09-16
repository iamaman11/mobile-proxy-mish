use crate::mesh_serving::MeshExecutionOwner;
use mish_transport::{MeshIngressError, MeshPortForward, MeshSessionOwner};
use std::net::{Ipv4Addr, TcpListener as StdTcpListener};
use std::sync::Arc;
use tokio::runtime::{Builder, Runtime};

fn test_runtime() -> Runtime {
    Builder::new_multi_thread()
        .worker_threads(2)
        .enable_io()
        .enable_time()
        .build()
        .expect("test runtime")
}

#[test]
fn failed_multi_listener_bind_never_publishes_partial_mesh_generation() {
    let runtime = test_runtime();
    let execution = MeshExecutionOwner::new();
    let sessions = MeshSessionOwner::product_generation();

    let first_reservation =
        StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve first Mesh port");
    let first_port = first_reservation
        .local_addr()
        .expect("first Mesh address")
        .port();
    drop(first_reservation);

    let blocked =
        StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve blocked Mesh port");
    let blocked_port = blocked.local_addr().expect("blocked Mesh address").port();

    let result = execution.start(
        &runtime,
        Ipv4Addr::LOCALHOST,
        &[
            MeshPortForward::same(first_port),
            MeshPortForward::same(blocked_port),
        ],
        Arc::clone(&sessions),
    );

    assert_eq!(result, Err(MeshIngressError::BindFailed));
    assert!(
        !execution.is_running(),
        "failed multi-listener bind must not publish a Mesh generation"
    );
    assert!(
        !execution.is_healthy(),
        "failed multi-listener bind must not publish healthy ingress"
    );
    assert_eq!(sessions.active_sessions(), 0);

    let rebound = StdTcpListener::bind((Ipv4Addr::LOCALHOST, first_port))
        .expect("first listener must be released when a later bind fails");
    drop(rebound);
    drop(blocked);
}
