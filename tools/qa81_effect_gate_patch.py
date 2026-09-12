#!/usr/bin/env python3
from pathlib import Path

ffi = Path('crates/android-ffi/src/lib.rs')
text = ffi.read_text()
old = 'use mish_cellular_egress_bridge::{BridgeCredentials, BridgeListener};'
new = '''use mish_cellular_egress_bridge::{
    BridgeCredentials, BridgeListener, CellularOutboundConnector, ConnectTarget,
    OutboundConnectError,
};'''
assert old in text
text = text.replace(old, new, 1)
old = '''pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
}'''
new = '''pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
    root_policy_effect_allowed: Arc<AtomicBool>,
}'''
assert old in text
text = text.replace(old, new, 1)
old = '''            bridge_claimed: Arc::new(AtomicBool::new(false)),
        })'''
new = '''            bridge_claimed: Arc::new(AtomicBool::new(false)),
            root_policy_effect_allowed: Arc::new(AtomicBool::new(false)),
        })'''
assert old in text
text = text.replace(old, new, 1)
anchor = '''    pub fn admission_snapshot(&self) -> Result<CellularAdmissionView, CellularBridgeError> {
        Ok(map_snapshot(self.owner()?.admission()))
    }
'''
addition = anchor + '''
    /// Infrastructure-only gate for ordinary PRODUCT-UID socket effects. Admission remains
    /// owned by Cellular Egress; Android opens this gate only after exact root-policy proof.
    pub fn set_root_policy_ready(&self, ready: bool) {
        self.root_policy_effect_allowed.store(ready, Ordering::Release);
    }
'''
assert anchor in text
text = text.replace(anchor, addition, 1)
old = '''            Arc::clone(&self.bridge_claimed),
            username,'''
new = '''            Arc::clone(&self.bridge_claimed),
            Arc::clone(&self.root_policy_effect_allowed),
            username,'''
assert old in text
text = text.replace(old, new, 1)
runtime_anchor = '''#[derive(uniffi::Object)]
pub struct CellularBridgeRuntime {'''
gated = '''#[derive(Clone)]
struct RootPolicyGatedConnector<C> {
    inner: C,
    effect_allowed: Arc<AtomicBool>,
}

impl<C> RootPolicyGatedConnector<C> {
    fn new(inner: C, effect_allowed: Arc<AtomicBool>) -> Self {
        Self { inner, effect_allowed }
    }
}

impl<C: CellularOutboundConnector> CellularOutboundConnector for RootPolicyGatedConnector<C> {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        if !self.effect_allowed.load(Ordering::Acquire) {
            return Err(OutboundConnectError::Unavailable);
        }
        let stream = self.inner.connect(target)?;
        if !self.effect_allowed.load(Ordering::Acquire) {
            let _ = stream.shutdown(Shutdown::Both);
            return Err(OutboundConnectError::Unavailable);
        }
        Ok(stream)
    }
}

'''
assert runtime_anchor in text
text = text.replace(runtime_anchor, gated + runtime_anchor, 1)
old = '''        bridge_claimed: Arc<AtomicBool>,
        username: String,'''
new = '''        bridge_claimed: Arc<AtomicBool>,
        root_policy_effect_allowed: Arc<AtomicBool>,
        username: String,'''
assert old in text
text = text.replace(old, new, 1)
old = '''            let connector = AndroidCellularOutboundConnector::new(
                owner,
                Duration::from_millis(operation_timeout_ms),
            )
            .map_err(|_| AndroidRuntimeError::ConnectorUnavailable)?;'''
new = '''            let connector = RootPolicyGatedConnector::new(
                AndroidCellularOutboundConnector::new(
                    owner,
                    Duration::from_millis(operation_timeout_ms),
                )
                .map_err(|_| AndroidRuntimeError::ConnectorUnavailable)?,
                root_policy_effect_allowed,
            );'''
assert old in text
text = text.replace(old, new, 1)
test_anchor = '''    #[test]
    fn one_owner_allows_only_one_private_bridge_and_releases_claim_on_stop() {'''
gate_test = '''    #[test]
    fn root_policy_effect_gate_defaults_closed_and_changes_only_explicitly() {
        let controller = CellularController::new();
        assert!(!controller.root_policy_effect_allowed.load(Ordering::Acquire));
        controller.set_root_policy_ready(true);
        assert!(controller.root_policy_effect_allowed.load(Ordering::Acquire));
        controller.set_root_policy_ready(false);
        assert!(!controller.root_policy_effect_allowed.load(Ordering::Acquire));
    }

'''
assert test_anchor in text
text = text.replace(test_anchor, gate_test + test_anchor, 1)
ffi.write_text(text)

bridge = Path('android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt')
text = bridge.read_text()
event_anchor = '''        val admission = try {
            when (event) {'''
event_replacement = '''        try {
            // Close the infrastructure effect gate before the owner generation can change.
            // It is reopened only after root-policy enforcement for that exact generation.
            activeController.setRootPolicyReady(false)
        } catch (_: LinkageError) {
            enqueueOwnerBoundaryFailure(CellularBoundaryFailure.NativeLibraryUnavailable)
            return
        } catch (_: Exception) {
            enqueueOwnerBoundaryFailure(CellularBoundaryFailure.ForeignCallFailed)
            return
        }

        val admission = try {
            when (event) {'''
assert event_anchor in text
text = text.replace(event_anchor, event_replacement, 1)
enforced = '''            CellularRootPolicyResult.Enforced ->
                CellularRuntimeSnapshot.OwnerSnapshot(admission)'''
enforced_replacement = '''            CellularRootPolicyResult.Enforced -> try {
                activeController.setRootPolicyReady(true)
                CellularRuntimeSnapshot.OwnerSnapshot(admission)
            } catch (_: LinkageError) {
                snapshotForFailClosed(
                    preferredFailure = CellularBoundaryFailure.NativeLibraryUnavailable,
                ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.NativeLibraryUnavailable,
                )
            } catch (_: Exception) {
                snapshotForFailClosed(
                    preferredFailure = CellularBoundaryFailure.ForeignCallFailed,
                ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.ForeignCallFailed,
                )
            }'''
assert enforced in text
text = text.replace(enforced, enforced_replacement, 1)
snapshot_anchor = '''    private fun snapshotForFailClosed(
        preferredFailure: CellularBoundaryFailure?,
        preserveOnCleanFailClosed: Boolean = false,
    ): CellularRuntimeSnapshot? = when (val result = rootPolicy.failClosed()) {'''
snapshot_replacement = '''    private fun snapshotForFailClosed(
        preferredFailure: CellularBoundaryFailure?,
        preserveOnCleanFailClosed: Boolean = false,
    ): CellularRuntimeSnapshot? {
        runCatching { controller?.setRootPolicyReady(false) }
        return when (val result = rootPolicy.failClosed()) {'''
assert snapshot_anchor in text
text = text.replace(snapshot_anchor, snapshot_replacement, 1)
end_anchor = '''        CellularRootPolicyResult.Enforced -> preferredFailure?.let {
            CellularRuntimeSnapshot.BoundaryUnavailable(it)
        }
    }

    private fun submitPolicyWork'''
end_replacement = '''        CellularRootPolicyResult.Enforced -> preferredFailure?.let {
            CellularRuntimeSnapshot.BoundaryUnavailable(it)
        }
        }
    }

    private fun submitPolicyWork'''
assert end_anchor in text
text = text.replace(end_anchor, end_replacement, 1)
close_anchor = '''    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        observer.close()'''
close_replacement = '''    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        runCatching { controller?.setRootPolicyReady(false) }
        observer.close()'''
assert close_anchor in text
text = text.replace(close_anchor, close_replacement, 1)
bridge.write_text(text)

root = Path('android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRootPolicy.kt')
text = root.read_text()
collision = '''            PolicyIdentityResolution.Collision ->
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.ReservedPolicyCollision,
                )

            PolicyIdentityResolution.Unavailable ->
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.VerificationFailed,
                )'''
collision_replacement = '''            PolicyIdentityResolution.Collision -> {
                val revoked = activeIdentity == null || removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    if (revoked) {
                        CellularRootPolicyFailure.ReservedPolicyCollision
                    } else {
                        CellularRootPolicyFailure.RuleMutationFailed
                    },
                )
            }

            PolicyIdentityResolution.Unavailable -> {
                val revoked = activeIdentity == null || removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    if (revoked) {
                        CellularRootPolicyFailure.VerificationFailed
                    } else {
                        CellularRootPolicyFailure.RuleMutationFailed
                    },
                )
            }'''
assert collision in text
text = text.replace(collision, collision_replacement, 1)
old = '''            if (preferred !in candidates) {
                activeIdentity = null
                return PolicyIdentityResolution.Collision
            }'''
new = '''            if (preferred !in candidates) {
                return PolicyIdentityResolution.Collision
            }'''
assert old in text
text = text.replace(old, new, 1)
old = '''            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }

        for (candidate in candidates) {'''
new = '''            return PolicyIdentityResolution.Collision
        }

        for (candidate in candidates) {'''
assert old in text
text = text.replace(old, new, 1)
root.write_text(text)

tests = Path('android/app/src/test/java/com/mobileproxymish/app/cellular/CellularRootPolicyTest.kt')
text = tests.read_text()
test_anchor = '''    @Test
    fun legacyNewOnlySelectorMigratesIntoNamedFlowPolicy() {'''
test = '''    @Test
    fun collisionAfterPublicationRevokesLookupAndKeepsSelectedIdentityForRecovery() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        val foreign = "-A OUTPUT -j MARK --set-xmark 0x0/${FIRST.mark}"
        process.foreignIpv4Mangle += foreign

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertTrue(process.foreignIpv4Mangle.contains(foreign))

        process.foreignIpv4Mangle.clear()
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertEquals(FIRST.lookup, process.ipv4Lookup?.lookup)
    }

'''
assert test_anchor in text
text = text.replace(test_anchor, test + test_anchor, 1)
tests.write_text(text)
