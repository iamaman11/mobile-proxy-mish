package com.mobileproxymish.app

import com.mobileproxymish.ffi.CellularDnsDiagnosticView
import com.mobileproxymish.ffi.CellularReconcileDiagnosticView
import com.mobileproxymish.ffi.ControlRuntimeSnapshotView
import com.mobileproxymish.ffi.ControlSessionStateView
import com.mobileproxymish.ffi.ProductDiagnosticSnapshotView
import com.mobileproxymish.ffi.RootPolicyReconcileDiagnosticView
import com.mobileproxymish.ffi.RootRecoveryDiagnosticView
import com.mobileproxymish.ffi.RemoteRotationResultView
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MishDiagnosticsSerializationTest {
    @Test
    fun serializesOneNativeAtomicSnapshotWithoutRecomputingProductSemantics() {
        val snapshot = ProductDiagnosticSnapshotView(
            consistent = true,
            runtimeRunning = true,
            runtimeGeneration = 11uL,
            cellularState = "ADMITTED",
            cellularReason = "NONE",
            cellularAdmitted = true,
            cellularOwnerSequence = 41uL,
            cellularBoundaryFailure = null,
            cellularReconcile = CellularReconcileDiagnosticView(
                requested = 7uL,
                executed = 6uL,
                coalesced = 1uL,
                pending = false,
                drainScheduled = false,
            ),
            dns = CellularDnsDiagnosticView(
                slowThresholdMs = 1_000uL,
                started = 9uL,
                completed = 8uL,
                active = 1uL,
                peakActive = 2uL,
                slowCompletions = 1uL,
                resolverFailed = 0uL,
                discardedAfterDeadline = 0uL,
                completedAfterOwnerChange = 0uL,
                discardedStale = 0uL,
                authorityValidationFailed = 0uL,
                unusableResult = 0uL,
                acceptedCurrent = 8uL,
                maxNativeElapsedMs = 25uL,
                lastStartedOwnerSequence = 41uL,
                lastCompletedStartOwnerSequence = 41uL,
                lastCompletedCurrentOwnerSequence = 41uL,
            ),
            rootAuthorityObservation = "READY_AT_POLICY_AUTHORIZATION",
            rootPolicyAuthorized = true,
            rootSessionGeneration = 3uL,
            rootLastFailureClass = null,
            rootPolicyAuthorizedGeneration = 41uL,
            rootReconcile = RootPolicyReconcileDiagnosticView(
                attempts = 4uL,
                totalExecutorCommands = 12uL,
                totalObservationCommands = 8uL,
                totalMutationCommands = 4uL,
                totalDuplicateObservations = 0uL,
                lastReconcileElapsedMs = 20uL,
                maxReconcileElapsedMs = 30uL,
                lastPolicyEffectElapsedMs = 15uL,
                maxPolicyEffectElapsedMs = 25uL,
                lastExecutorCommands = 3uL,
                lastObservationCommands = 2uL,
                lastMutationCommands = 1uL,
                lastDuplicateObservations = 0uL,
                lastIncompleteOrTimedOutCommands = 0uL,
                lastMutationFailures = 0uL,
            ),
            rootRecovery = RootRecoveryDiagnosticView(
                pending = false,
                attemptsSinceReset = 0u,
                nextDelayMs = 1_000uL,
            ),
            proxyState = "RUNNING",
            proxyHealthy = true,
            proxyFailure = null,
            proxyServingGeneration = 5uL,
            proxyActiveSessions = 2uL,
            proxyRecoveryPending = false,
            proxyRecoveryOperationId = 7uL,
            proxyRecoveryAttemptsScheduled = 0u,
            proxyRecoveryNextDelayMs = 1_000uL,
            credentialActive = true,
            credentialVersion = 2uL,
            meshState = "ADMITTED",
            meshAdmitted = true,
            meshObservationSequence = 17uL,
            meshAdmissionEpoch = 4uL,
            meshEpochPresent = true,
            meshIngressRunning = true,
            meshServingGeneration = 4uL,
            meshIngressFailure = "NONE",
            meshActiveSessions = 2uL,
            meshCapacityRejects = 0uL,
            readinessState = "READY",
            readinessBindingEligible = true,
            readinessBindingCellularOwnerGeneration = 41uL,
            readinessBindingRuntimeGeneration = 11uL,
            readinessBindingProxyServingGeneration = 5uL,
            readinessBindingMeshAdmissionEpoch = 4uL,
            readinessBindingCredentialVersion = 2uL,
            readinessExpectedFreshness = 13uL,
            readinessObservedFreshness = 13uL,
            readinessProbeInFlight = false,
            readinessRefreshPending = true,
            readinessProbeState = "SUCCEEDED",
            rotationState = "WAITING_ROOT_POLICY",
            rotationOperationId = 9uL,
            rotationBeforeGeneration = 41uL,
            rotationAfterGeneration = null,
            rotationRestoreRequired = false,
            rotationTerminalResult = null,
            rotationFailure = null,
            rotationRestoreResult = null,
            rotationActiveTasks = 0uL,
        )

        val rendered = renderMishDiagnosticSnapshotV2(
            applicationId = "com.mobileproxymish.app.debug",
            pid = 1234,
            capturedElapsedMs = 55_000,
            snapshot = snapshot,
        )
        val json = JSONObject(rendered)

        assertTrue(json.getBoolean("consistent"))
        assertEquals(11L, json.getJSONObject("runtime").getLong("generation"))
        assertEquals(41L, json.getJSONObject("cellular").getLong("owner_sequence"))

        val root = json.getJSONObject("root")
        assertTrue(root.getBoolean("policy_authorized"))
        assertEquals(3L, root.getLong("session_generation"))
        assertEquals(41L, root.getLong("policy_authorized_generation"))
        assertTrue(root.isNull("last_failure_class"))

        val proxyRecovery = json.getJSONObject("proxy").getJSONObject("recovery")
        assertEquals(7L, proxyRecovery.getLong("operation_id"))

        val mesh = json.getJSONObject("mesh")
        assertEquals(4L, mesh.getLong("serving_generation"))

        val readiness = json.getJSONObject("readiness")
        val binding = readiness.getJSONObject("binding")
        assertEquals(41L, binding.getLong("cellular_owner_generation"))
        assertEquals(11L, binding.getLong("runtime_generation"))
        assertEquals(5L, binding.getLong("proxy_serving_generation"))
        assertEquals(4L, binding.getLong("mesh_admission_epoch"))
        assertEquals(2L, binding.getLong("credential_version"))
        assertEquals(13L, readiness.getLong("expected_freshness"))
        assertEquals(13L, readiness.getLong("observed_freshness"))
        assertFalse(readiness.getBoolean("probe_in_flight"))
        assertTrue(readiness.getBoolean("refresh_pending"))

        val rotation = json.getJSONObject("rotation")
        assertEquals("WAITING_ROOT_POLICY", rotation.getString("state"))
        assertEquals(9L, rotation.getLong("operation_id"))
        assertEquals(41L, rotation.getLong("before_generation"))
        assertTrue(rotation.isNull("after_generation"))
        assertFalse(rotation.getBoolean("restore_required"))
        assertTrue(rotation.isNull("terminal_result"))
        assertTrue(rotation.isNull("failure"))
        assertTrue(rotation.isNull("restore_result"))
        assertEquals(0L, rotation.getLong("active_tasks"))
        assertFalse(rotation.getBoolean("raw_ip_persisted"))
        assertFalse(rendered.contains("username", ignoreCase = true))
        assertFalse(rendered.contains("password", ignoreCase = true))
    }

    @Test
    fun serializesControlOwnerTelemetryWithoutProductRecomposition() {
        val snapshot = ControlRuntimeSnapshotView(
            state = ControlSessionStateView.READY,
            reconnectAttempts = 0u,
            reconnectCount = 3uL,
            nextDelayMs = 1_000uL,
            sessionAgeMs = 90_000uL,
            applicationHeartbeatCount = 0uL,
            payloadTxBytes = 512uL,
            payloadRxBytes = 768uL,
            lastTxAgeMs = 30_000uL,
            lastRxAgeMs = 20_000uL,
            pendingOperation = false,
            pendingOperationId = null,
            lastTerminalResult = RemoteRotationResultView.CHANGED,
        )

        val rendered = renderMishControlDiagnosticSnapshotV1(
            applicationId = "com.mobileproxymish.app.debug",
            pid = 1234,
            capturedElapsedMs = 90_500,
            snapshot = snapshot,
        )
        val json = JSONObject(rendered)
        assertEquals(MISH_CONTROL_DIAGNOSTICS_SCHEMA_V1, json.getString("schema"))
        assertEquals(1234, json.getInt("pid"))

        val control = json.getJSONObject("control")
        assertEquals("READY", control.getString("state"))
        assertEquals(0L, control.getLong("reconnect_attempts"))
        assertEquals(3L, control.getLong("reconnect_count"))
        assertEquals(90_000L, control.getLong("session_age_ms"))
        assertEquals(0L, control.getLong("application_heartbeat_count"))
        assertEquals(512L, control.getLong("payload_tx_bytes"))
        assertEquals(768L, control.getLong("payload_rx_bytes"))
        assertEquals(30_000L, control.getLong("last_tx_age_ms"))
        assertEquals(20_000L, control.getLong("last_rx_age_ms"))
        assertFalse(control.getBoolean("pending_operation"))
        assertTrue(control.isNull("pending_operation_id"))
        assertEquals("CHANGED", control.getString("last_terminal_result"))
        assertFalse(rendered.contains("username", ignoreCase = true))
        assertFalse(rendered.contains("password", ignoreCase = true))
    }
}
