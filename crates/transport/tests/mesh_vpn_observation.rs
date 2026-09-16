use mish_transport::{
    MeshIngressError, MeshIngressExecutor, MeshPortForward, MeshSessionLease, MeshSessionOwner,
    MeshTransportCoordinator, MeshVpnObservation,
};
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

struct RetainedSessionExecutor {
    healthy: AtomicBool,
    lease: Mutex<Option<MeshSessionLease>>,
}

impl RetainedSessionExecutor {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            healthy: AtomicBool::new(false),
            lease: Mutex::new(None),
        })
    }
}

impl MeshIngressExecutor for RetainedSessionExecutor {
    fn start_ingress(
        &self,
        _endpoint: Ipv4Addr,
        _mappings: &[MeshPortForward],
        sessions: Arc<MeshSessionOwner>,
    ) -> Result<(), MeshIngressError> {
        let lease = sessions
            .try_admit()
            .ok_or(MeshIngressError::ExecutorUnavailable)?;
        *self
            .lease
            .lock()
            .map_err(|_| MeshIngressError::ExecutorUnavailable)? = Some(lease);
        self.healthy.store(true, Ordering::Release);
        Ok(())
    }

    fn stop_ingress(&self) -> Result<(), MeshIngressError> {
        self.healthy.store(false, Ordering::Release);
        self.lease
            .lock()
            .map_err(|_| MeshIngressError::ExecutorUnavailable)?
            .take();
        Ok(())
    }

    fn ingress_healthy(&self) -> bool {
        self.healthy.load(Ordering::Acquire)
    }
}

#[test]
fn vpn_loss_revokes_active_session_before_same_endpoint_gets_fresh_epoch() {
    let endpoint = Ipv4Addr::new(127, 0, 0, 2);
    let runtime = MeshTransportCoordinator::new(Ipv4Addr::new(127, 0, 0, 0), 8)
        .expect("loopback test coordinator");
    let executor = RetainedSessionExecutor::new();
    let execution: Arc<dyn MeshIngressExecutor> = executor.clone();

    let admitted = runtime
        .observe_vpn(
            1,
            MeshVpnObservation::UniqueVpn {
                local_ipv4: vec![endpoint],
            },
        )
        .expect("initial VPN observation");
    let first_epoch = admitted
        .admission()
        .admission_epoch()
        .expect("initial admission epoch");
    assert!(
        runtime
            .start_ingress(first_epoch, &[MeshPortForward::same(40001)], execution)
            .expect("start ingress")
    );
    assert!(runtime.ingress_healthy().expect("healthy ingress"));
    assert_eq!(runtime.snapshot().expect("snapshot").active_sessions(), 1);

    let lost = runtime
        .observe_vpn(2, MeshVpnObservation::Absent)
        .expect("VPN loss");
    assert!(!lost.ingress_running());
    assert_eq!(lost.active_sessions(), 0);
    assert!(!executor.ingress_healthy());

    let returned = runtime
        .observe_vpn(
            3,
            MeshVpnObservation::UniqueVpn {
                local_ipv4: vec![endpoint],
            },
        )
        .expect("same endpoint returns");
    assert_ne!(returned.admission().admission_epoch(), Some(first_epoch));
    assert!(!returned.ingress_running());
}
