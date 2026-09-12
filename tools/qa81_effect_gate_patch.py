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
old = 'use std::sync::{Arc, Mutex, MutexGuard};'
new = 'use std::sync::{Arc, Condvar, Mutex, MutexGuard};'
assert old in text
text = text.replace(old, new, 1)

old = '''pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
}'''
new = '''pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
    root_policy_effect_gate: Arc<RootPolicyEffectGate>,
}'''
assert old in text
text = text.replace(old, new, 1)
old = '''            bridge_claimed: Arc::new(AtomicBool::new(false)),
        })'''
new = '''            bridge_claimed: Arc::new(AtomicBool::new(false)),
            root_policy_effect_gate: Arc::new(RootPolicyEffectGate::default()),
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
    pub fn set_root_policy_ready(&self, ready: bool) -> Result<(), AndroidRuntimeError> {
        if self.root_policy_effect_gate.set_ready(ready) {
            Ok(())
        } else {
            Err(AndroidRuntimeError::BridgeStateUnavailable)
        }
    }

    /// Waits until connect operations that acquired the preceding root-policy generation have
    /// released their bounded permits. Root mutation is forbidden until this returns true.
    pub fn await_root_policy_quiesced(
        &self,
        timeout_ms: u64,
    ) -> Result<bool, AndroidRuntimeError> {
        if timeout_ms == 0 || timeout_ms > BRIDGE_OPERATION_TIMEOUT_MAX_MS {
            return Err(AndroidRuntimeError::InvalidOperationTimeout);
        }
        self.root_policy_effect_gate
            .wait_quiesced(Duration::from_millis(timeout_ms))
            .ok_or(AndroidRuntimeError::BridgeStateUnavailable)
    }
'''
assert anchor in text
text = text.replace(anchor, addition, 1)
old = '''            Arc::clone(&self.bridge_claimed),
            username,'''
new = '''            Arc::clone(&self.bridge_claimed),
            Arc::clone(&self.root_policy_effect_gate),
            username,'''
assert old in text
text = text.replace(old, new, 1)

runtime_anchor = '''#[derive(uniffi::Object)]
pub struct CellularBridgeRuntime {'''
gated = '''#[derive(Default)]
struct RootPolicyEffectGate {
    state: Mutex<RootPolicyEffectGateState>,
    quiesced: Condvar,
}

#[derive(Default)]
struct RootPolicyEffectGateState {
    ready: bool,
    in_flight: usize,
}

impl RootPolicyEffectGate {
    fn set_ready(&self, ready: bool) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        state.ready = ready;
        if !ready && state.in_flight == 0 {
            self.quiesced.notify_all();
        }
        true
    }

    fn acquire(self: &Arc<Self>) -> Option<RootPolicyEffectPermit> {
        let mut state = self.state.lock().ok()?;
        if !state.ready {
            return None;
        }
        state.in_flight = state.in_flight.checked_add(1)?;
        drop(state);
        Some(RootPolicyEffectPermit {
            gate: Arc::clone(self),
        })
    }

    fn wait_quiesced(&self, timeout: Duration) -> Option<bool> {
        let state = self.state.lock().ok()?;
        let (state, wait) = self
            .quiesced
            .wait_timeout_while(state, timeout, |state| state.in_flight != 0)
            .ok()?;
        Some(state.in_flight == 0 && !wait.timed_out() || state.in_flight == 0)
    }
}

struct RootPolicyEffectPermit {
    gate: Arc<RootPolicyEffectGate>,
}

impl Drop for RootPolicyEffectPermit {
    fn drop(&mut self) {
        if let Ok(mut state) = self.gate.state.lock() {
            if state.in_flight == 0 {
                return;
            }
            state.in_flight -= 1;
            if state.in_flight == 0 {
                self.gate.quiesced.notify_all();
            }
        }
    }
}

#[derive(Clone)]
struct RootPolicyGatedConnector<C> {
    inner: C,
    effect_gate: Arc<RootPolicyEffectGate>,
}

impl<C> RootPolicyGatedConnector<C> {
    fn new(inner: C, effect_gate: Arc<RootPolicyEffectGate>) -> Self {
        Self { inner, effect_gate }
    }
}

impl<C: CellularOutboundConnector> CellularOutboundConnector for RootPolicyGatedConnector<C> {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        let _permit = self
            .effect_gate
            .acquire()
            .ok_or(OutboundConnectError::Unavailable)?;
        self.inner.connect(target)
    }
}

'''
assert runtime_anchor in text
text = text.replace(runtime_anchor, gated + runtime_anchor, 1)
old = '''        bridge_claimed: Arc<AtomicBool>,
        username: String,'''
new = '''        bridge_claimed: Arc<AtomicBool>,
        root_policy_effect_gate: Arc<RootPolicyEffectGate>,
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
                root_policy_effect_gate,
            );'''
assert old in text
text = text.replace(old, new, 1)

test_anchor = '''    #[test]
    fn one_owner_allows_only_one_private_bridge_and_releases_claim_on_stop() {'''
gate_test = '''    #[test]
    fn root_policy_effect_gate_is_default_closed_and_drains_preexisting_permits() {
        let gate = Arc::new(RootPolicyEffectGate::default());
        assert!(gate.acquire().is_none());
        assert!(gate.set_ready(true));
        let permit = gate.acquire().expect("open gate permit");
        assert!(gate.set_ready(false));
        assert_eq!(gate.wait_quiesced(Duration::from_millis(1)), Some(false));
        drop(permit);
        assert_eq!(gate.wait_quiesced(Duration::from_millis(10)), Some(true));
        assert!(gate.acquire().is_none());
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
            // Policy work waits for pre-existing connect permits before any root mutation.
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

reconcile_anchor = '''        val policyResult = rootPolicy.reconcile(
            admitted = admission.state == CellularAdmissionState.ADMITTED,
            interfaceName = interfaceName,
        )'''
reconcile_replacement = '''        val quiesced = try {
            activeController.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong())
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        if (!quiesced) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
            return
        }

        val policyResult = rootPolicy.reconcile(
            admitted = admission.state == CellularAdmissionState.ADMITTED,
            interfaceName = interfaceName,
        )'''
assert reconcile_anchor in text
text = text.replace(reconcile_anchor, reconcile_replacement, 1)

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
        val quiesced = try {
            controller?.setRootPolicyReady(false)
            controller?.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong()) ?: true
        } catch (_: Exception) {
            false
        } catch (_: LinkageError) {
            false
        }
        if (!quiesced) {
            return CellularRuntimeSnapshot.BoundaryUnavailable(
                preferredFailure ?: CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
        }
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

        observer.close()
        val cleanup = try {
            policyExecutor.submit {
                interfaceHints.clear()
                rootPolicy.cleanupExactOwnedRules()
            }'''
close_replacement = '''    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        runCatching { controller?.setRootPolicyReady(false) }
        observer.close()
        val cleanup = try {
            policyExecutor.submit {
                interfaceHints.clear()
                val quiesced = try {
                    controller?.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong()) ?: true
                } catch (_: Exception) {
                    false
                } catch (_: LinkageError) {
                    false
                }
                quiesced && rootPolicy.cleanupExactOwnedRules()
            }'''
assert close_anchor in text
text = text.replace(close_anchor, close_replacement, 1)
old = '''    private companion object {
        const val CLOSE_TIMEOUT_SECONDS = 60L
    }'''
new = '''    private companion object {
        const val CLOSE_TIMEOUT_SECONDS = 60L
        const val EFFECT_DRAIN_TIMEOUT_MS = 20_000L
    }'''
assert old in text
text = text.replace(old, new, 1)
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

docs = Path('docs/architecture/CELLULAR_ROOT_POLICY.md')
text = docs.read_text()
anchor = '''The same `CellularController` / `CellularEgress` instance is also supplied to the private loopback egress bridge used by the Android proxy runtime. Starting the proxy bridge must not instantiate a second Cellular Egress owner or a second admission/generation state machine.
'''
addition = anchor + '''
Ordinary PRODUCT-UID outbound socket effects are additionally protected by a process-local infrastructure gate. The gate is default-closed, is closed synchronously before any owner observation can advance the generation, and opens only after exact root-policy enforcement for that same generation. A connect operation holds a bounded RAII permit for its DNS/connect transaction; the policy executor must observe permit quiescence before mutating or revoking kernel routing state. This gate is not admission/readiness state and cannot make a network admissible; it only prevents the runtime adapter from issuing a new ordinary socket effect while root-policy realization is unproven or changing.
'''
assert anchor in text
text = text.replace(anchor, addition, 1)
docs.write_text(text)
