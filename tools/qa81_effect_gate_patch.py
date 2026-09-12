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
    /// Closes the infrastructure-only gate for ordinary PRODUCT-UID socket effects.
    /// Closing cannot make any network admissible and therefore owns no cellular semantics.
    pub fn close_root_policy_gate(&self) -> Result<(), AndroidRuntimeError> {
        if self.root_policy_effect_gate.set_ready(false) {
            Ok(())
        } else {
            Err(AndroidRuntimeError::BridgeStateUnavailable)
        }
    }

    /// Waits until connect operations admitted by the preceding root-policy generation have
    /// released their bounded permits. Kernel policy mutation is forbidden until quiesced.
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

    /// Opens the infrastructure effect gate only while holding the same owner mutex used by
    /// observation/loss. A stale Kotlin reconcile therefore cannot authorize a newer owner
    /// generation between its final currentness check and gate publication.
    pub fn authorize_root_policy(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<bool, AndroidRuntimeError> {
        let Some(sequence) = ObservationSequence::new(sequence) else {
            return Ok(false);
        };
        let Some(network_handle) = NetworkHandle::new(network_handle) else {
            return Ok(false);
        };
        let owner = self
            .owner
            .lock()
            .map_err(|_| AndroidRuntimeError::BridgeStateUnavailable)?;
        let snapshot = owner.admission();
        let current = snapshot.state() == OwnerAdmissionState::Admitted
            && snapshot.last_sequence() == Some(sequence)
            && snapshot.admitted_network() == Some(network_handle);
        if !current {
            if !self.root_policy_effect_gate.set_ready(false) {
                return Err(AndroidRuntimeError::BridgeStateUnavailable);
            }
            return Ok(false);
        }
        if !self.root_policy_effect_gate.set_ready(true) {
            return Err(AndroidRuntimeError::BridgeStateUnavailable);
        }
        Ok(true)
    }
'''
assert anchor in text
text = text.replace(anchor, addition, 1)

old = '''        let mut owner = self.owner()?;
        owner.observe(observation);'''
new = '''        let mut owner = self.owner()?;
        if !self.root_policy_effect_gate.set_ready(false) {
            return Err(CellularBridgeError::OwnerUnavailable);
        }
        owner.observe(observation);'''
assert old in text
text = text.replace(old, new, 1)
old = '''        let mut owner = self.owner()?;
        owner.lost(sequence, network_handle);'''
new = '''        let mut owner = self.owner()?;
        if !self.root_policy_effect_gate.set_ready(false) {
            return Err(CellularBridgeError::OwnerUnavailable);
        }
        owner.lost(sequence, network_handle);'''
assert old in text
text = text.replace(old, new, 1)
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
        let (state, _) = self
            .quiesced
            .wait_timeout_while(state, timeout, |state| state.in_flight != 0)
            .ok()?;
        Some(state.in_flight == 0)
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
old = '''fn bridge_accept_loop(
    listener: Arc<BridgeListener>,
    connector: AndroidCellularOutboundConnector,'''
new = '''fn bridge_accept_loop<C>(
    listener: Arc<BridgeListener>,
    connector: C,'''
assert old in text
text = text.replace(old, new, 1)
old = ''') {
    while !stop_requested.load(Ordering::Acquire) {'''
new = ''') where
    C: CellularOutboundConnector + Clone + 'static,
{
    while !stop_requested.load(Ordering::Acquire) {'''
# Only replace the bridge_accept_loop terminator occurrence: use split around function anchor.
idx = text.index('fn bridge_accept_loop<C>(')
tail = text[idx:]
assert old in tail
tail = tail.replace(old, new, 1)
text = text[:idx] + tail

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

    #[test]
    fn stale_generation_cannot_reopen_root_policy_effect_gate() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("first observation");
        assert!(controller.authorize_root_policy(1, 42).expect("authorize first"));
        controller
            .observe_network(2, 43, true, true, true, true)
            .expect("newer observation");
        assert!(!controller.authorize_root_policy(1, 42).expect("reject stale"));
        assert!(controller.root_policy_effect_gate.acquire().is_none());
        assert!(controller.authorize_root_policy(2, 43).expect("authorize current"));
        assert!(controller.root_policy_effect_gate.acquire().is_some());
        controller.close_root_policy_gate().expect("close gate");
    }

'''
assert test_anchor in text
text = text.replace(test_anchor, gate_test + test_anchor, 1)
ffi.write_text(text)

bridge = Path('android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt')
text = bridge.read_text()
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
enforced_replacement = '''            CellularRootPolicyResult.Enforced -> {
                val sequence = admission.lastSequence
                val handle = admission.admittedNetworkHandle
                val authorized = if (sequence != null && handle != null) {
                    try {
                        activeController.authorizeRootPolicy(sequence, handle)
                    } catch (_: LinkageError) {
                        false
                    } catch (_: Exception) {
                        false
                    }
                } else {
                    false
                }
                if (authorized) {
                    CellularRuntimeSnapshot.OwnerSnapshot(admission)
                } else {
                    snapshotForFailClosed(
                        preferredFailure = CellularBoundaryFailure.RootPolicyGenerationChanged,
                    ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyGenerationChanged,
                    )
                }
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
            controller?.closeRootPolicyGate()
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

        runCatching { controller?.closeRootPolicyGate() }
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
# Preserve a previously published identity across every collision path so exact lookup
# revocation/cleanup still knows what PRODUCT owns. Initial trial selection remains cleared
# only after the bounded candidate loop proves that no safe candidate exists.
for old in [
    '''        if ((!ipv4ChainExists && ipv4JumpCount != 0) || (!ipv6ChainExists && ipv6JumpCount != 0)) {
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }''',
    '''        if ((ipv4JumpCount != 0 && ipv4Chain.isEmpty()) ||
            (ipv6JumpCount != 0 && ipv6Chain.isEmpty())
        ) {
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }''',
    '''        if (hasChainState && compatible.isEmpty()) {
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }''',
    '''            if (preferred !in candidates) {
                activeIdentity = null
                return PolicyIdentityResolution.Collision
            }''',
]:
    assert old in text
    text = text.replace(old, old.replace('            activeIdentity = null\n', '').replace('                activeIdentity = null\n', ''), 1)
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

    @Test
    fun malformedPublishedChainStillRevokesLookupUsingRetainedIdentity() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        process.ipv4ChainRules += "-A $CHAIN -j MARK --set-xmark 0xdead/0xdead"

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertTrue(process.ipv4ChainRules.any { it.contains("0xdead/0xdead") })
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
Ordinary PRODUCT-UID outbound socket effects are additionally protected by a process-local infrastructure gate. The gate is default-closed. The same Rust `CellularController` mutex that serializes owner observations also closes the gate before an observation/loss mutates the owner and authorizes reopening only when the expected sequence/network handle is still the exact current ADMITTED generation. A connect transaction holds a bounded RAII permit; the Kotlin policy executor must observe permit quiescence before mutating or revoking kernel routing state. This gate is not admission/readiness state and cannot make a network admissible; it only prevents the runtime adapter from issuing a new ordinary socket effect while root-policy realization is unproven or changing.
'''
assert anchor in text
text = text.replace(anchor, addition, 1)
docs.write_text(text)
