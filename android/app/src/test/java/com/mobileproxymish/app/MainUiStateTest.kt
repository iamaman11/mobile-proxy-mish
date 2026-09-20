package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.MeshAdmissionReason
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyListenerView
import com.mobileproxymish.ffi.ProxyProtocolView
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.RootPolicyFailureView
import com.mobileproxymish.ffi.RotationFailureView
import com.mobileproxymish.ffi.RotationPhaseView
import com.mobileproxymish.ffi.RotationSnapshotView
import com.mobileproxymish.ffi.RotationTerminalResultView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MainUiStateTest {
    @Test
    fun overallReadinessIsExactlyTheRustProjection() {
        val expected = mapOf(
            ProductReadinessState.READY to ProductOverallUiState.READY,
            ProductReadinessState.DEGRADED to ProductOverallUiState.DEGRADED,
            ProductReadinessState.NOT_READY to ProductOverallUiState.NOT_READY,
            ProductReadinessState.UNKNOWN to ProductOverallUiState.UNKNOWN,
        )
        expected.forEach { (backend, ui) ->
            assertEquals(ui, projectProductUi(input(readiness = backend)).overall)
        }
    }

    @Test
    fun readyIsNotRecomputedFromComponentRows() {
        val state = projectProductUi(
            input(
                readiness = ProductReadinessState.READY,
                proxy = ProxyRuntimeSnapshot.Stopped,
                mesh = notAdmittedMesh(),
            ),
        )
        assertEquals(ProductOverallUiState.READY, state.overall)
        assertEquals(ComponentHealthUi.NOT_READY, state.health.proxy)
        assertEquals(ComponentHealthUi.NOT_READY, state.health.mesh)
    }

    @Test
    fun firstUseOrProcessRestartHasUnknownPublicIps() {
        val state = projectProductUi(input(rotation = rotation()))
        assertNull(state.publicIp.current)
        assertNull(state.publicIp.previous)
    }

    @Test
    fun terminalRotationProjectsCurrentAndPreviousIpEphemerally() {
        val state = projectProductUi(
            input(
                cellular = cellular(sequence = 8uL),
                rotation = rotation(
                    phase = RotationPhaseView.CHANGED,
                    terminal = RotationTerminalResultView.CHANGED,
                    beforeIp = "198.51.100.10",
                    afterIp = "198.51.100.11",
                ),
            ),
        )
        assertEquals("198.51.100.11", state.publicIp.current)
        assertEquals("198.51.100.10", state.publicIp.previous)
        assertEquals(RotationResultUi.CHANGED, state.rotation.result)
    }

    @Test
    fun terminalIpBecomesUnknownWhenCellularOwnerGenerationAdvances() {
        val state = projectProductUi(
            input(
                cellular = cellular(sequence = 9uL),
                rotation = rotation(
                    phase = RotationPhaseView.CHANGED,
                    terminal = RotationTerminalResultView.CHANGED,
                    beforeIp = "198.51.100.10",
                    afterIp = "198.51.100.11",
                ),
            ),
        )
        assertNull(state.publicIp.current)
        assertEquals("198.51.100.10", state.publicIp.previous)
    }

    @Test
    fun everyActiveBackendRotationPhaseHasSemanticProgressAndDisablesDuplicateStart() {
        val cases = mapOf(
            RotationPhaseView.PREPARING to RotationStageUi.STARTING,
            RotationPhaseView.AIRPLANE_ENABLING to RotationStageUi.DISCONNECTING_CELLULAR,
            RotationPhaseView.WAITING_RADIO_DOWN to
                RotationStageUi.WAITING_FOR_CELLULAR_DISCONNECT,
            RotationPhaseView.AIRPLANE_DISABLING to RotationStageUi.RESTORING_RADIO,
            RotationPhaseView.WAITING_CELLULAR_RECOVERY to
                RotationStageUi.WAITING_FOR_CELLULAR_RECOVERY,
            RotationPhaseView.WAITING_ROOT_POLICY to RotationStageUi.APPLYING_NETWORK_POLICY,
            RotationPhaseView.PROBING_PUBLIC_IP to RotationStageUi.CHECKING_PUBLIC_IP,
        )
        cases.forEach { (backend, semantic) ->
            val state = projectProductUi(input(rotation = rotation(phase = backend)))
            assertTrue(state.rotation.inProgress)
            assertEquals(semantic, state.rotation.stage)
            assertFalse(state.changeIpEnabled)
            assertNull(state.publicIp.current)
        }
    }

    @Test
    fun unchangedIsAValidTerminalResultNotFailure() {
        val state = projectProductUi(
            input(
                cellular = cellular(sequence = 8uL),
                rotation = rotation(
                    phase = RotationPhaseView.UNCHANGED,
                    terminal = RotationTerminalResultView.UNCHANGED,
                    beforeIp = "198.51.100.10",
                    afterIp = "198.51.100.10",
                ),
            ),
        )
        assertEquals(RotationResultUi.UNCHANGED, state.rotation.result)
        assertNull(state.rotation.failure)
        assertEquals("198.51.100.10", state.publicIp.current)
    }

    @Test
    fun failedRotationPreservesTypedFailure() {
        val state = projectProductUi(
            input(
                rotation = rotation(
                    phase = RotationPhaseView.FAILED,
                    terminal = RotationTerminalResultView.FAILED,
                    failure = RotationFailureView.ROOT_POLICY_RECOVERY_FAILED,
                ),
            ),
        )
        assertEquals(RotationResultUi.FAILED, state.rotation.result)
        assertEquals(RotationFailureUi.ROOT_POLICY_RECOVERY_FAILED, state.rotation.failure)
        assertFalse(state.rotation.inProgress)
    }

    @Test
    fun cellularUnavailableProducesTypedNotReadyCause() {
        val state = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                cellular = CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.NativeLibraryUnavailable,
                ),
            ),
        )
        assertEquals(ProductCauseUi.MOBILE_NETWORK_NOT_READY, state.cause)
        assertEquals(ComponentHealthUi.NOT_READY, state.health.cellular)
    }

    @Test
    fun cellularLossDuringRotationIsPresentedAsRecoveringOnly() {
        val state = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                cellular = cellular(
                    state = CellularAdmissionState.NOT_ADMITTED,
                    reason = CellularAdmissionReason.NETWORK_LOST,
                ),
                rotation = rotation(RotationPhaseView.WAITING_CELLULAR_RECOVERY),
            ),
        )
        assertEquals(ProductCauseUi.MOBILE_NETWORK_RECOVERING, state.cause)
        assertEquals(ComponentHealthUi.RECOVERING, state.health.cellular)
    }

    @Test
    fun rootAuthorityUnavailableAndRootPolicyFailureStayDistinct() {
        val authority = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                cellular = CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootAuthorityUnavailable,
                ),
            ),
        )
        assertEquals(ProductCauseUi.ROOT_AUTHORIZATION_UNAVAILABLE, authority.cause)

        val policy = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                cellular = CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootPolicyUnavailable(
                        RootPolicyFailureView.OBSERVATION_UNAVAILABLE,
                    ),
                ),
            ),
        )
        assertEquals(ProductCauseUi.ROOT_POLICY_FAILED, policy.cause)
        assertTrue(
            policy.advancedDiagnostics.technicalReason
                ?.contains("root_policy_observation_unavailable") == true,
        )
    }

    @Test
    fun proxyAndMeshFailuresRemainTypedComponentFacts() {
        val proxy = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                proxy = ProxyRuntimeSnapshot.Failed(ProxyServingFailure.SERVING_UNHEALTHY),
            ),
        )
        assertEquals(ProductCauseUi.PROXY_UNAVAILABLE, proxy.cause)

        val mesh = projectProductUi(
            input(
                readiness = ProductReadinessState.NOT_READY,
                mesh = notAdmittedMesh(),
            ),
        )
        assertEquals(ProductCauseUi.MESH_UNAVAILABLE, mesh.cause)
    }

    @Test
    fun unknownReadinessNeverBecomesFailure() {
        val state = projectProductUi(
            input(
                readiness = ProductReadinessState.UNKNOWN,
                proxy = ProxyRuntimeSnapshot.Failed(ProxyServingFailure.SERVING_UNHEALTHY),
            ),
        )
        assertEquals(ProductOverallUiState.UNKNOWN, state.overall)
        assertEquals(ProductCauseUi.CHECKING_CONNECTIVITY, state.cause)
    }

    @Test
    fun degradedReadinessIsNotCollapsedIntoNotReady() {
        val state = projectProductUi(input(readiness = ProductReadinessState.DEGRADED))
        assertEquals(ProductOverallUiState.DEGRADED, state.overall)
        assertEquals(ProductCauseUi.PUBLIC_CONNECTION_DEGRADED, state.cause)
    }

    @Test
    fun proxyCoordinatesComeFromTypedBackendContractAndMeshOwner() {
        val state = projectProductUi(
            input(
                mesh = readyMesh(endpoint = "100.96.2.4"),
                listeners = listOf(
                    ProxyListenerView(
                        protocol = ProxyProtocolView.HTTP_CONNECT,
                        port = 3128u.toUShort(),
                    ),
                ),
            ),
        )
        assertEquals("100.96.2.4", state.proxyEndpoint.endpoint)
        assertEquals(
            listOf(ProxyListenerUi(ProxyProtocolUi.HTTP_CONNECT, 3128)),
            state.proxyEndpoint.listeners,
        )
    }

    @Test
    fun normalProductUiStateCannotCarryCredentialMaterial() {
        val fieldNames = ProductUiState::class.java.declaredFields
            .map { it.name.lowercase() }
            .toSet()
        assertFalse(fieldNames.any { "password" in it || "username" in it || "credential" in it })
    }

    private fun input(
        readiness: ProductReadinessState = ProductReadinessState.READY,
        cellular: CellularRuntimeSnapshot = cellular(),
        proxy: ProxyRuntimeSnapshot = ProxyRuntimeSnapshot.Running,
        mesh: MeshAdmissionView? = readyMesh(),
        rotation: RotationSnapshotView = rotation(),
        listeners: List<ProxyListenerView> = emptyList(),
    ): ProductPresentationInput = ProductPresentationInput(
        readiness = readiness,
        cellular = cellular,
        proxy = proxy,
        mesh = mesh,
        rotation = rotation,
        proxyListeners = listeners,
    )

    private fun cellular(
        state: CellularAdmissionState = CellularAdmissionState.ADMITTED,
        reason: CellularAdmissionReason? = null,
        sequence: ULong = 7uL,
    ): CellularRuntimeSnapshot = CellularRuntimeSnapshot.OwnerSnapshot(
        CellularAdmissionView(
            state = state,
            reason = reason,
            admittedNetworkHandle = if (state == CellularAdmissionState.ADMITTED) 42uL else null,
            lastSequence = sequence,
        ),
    )

    private fun readyMesh(endpoint: String = "100.96.2.4"): MeshAdmissionView = MeshAdmissionView(
        state = MeshAdmissionState.ADMITTED,
        reason = null,
        endpoint = endpoint,
        admissionEpoch = 2uL,
        lastSequence = 9uL,
        ingressRunning = true,
        activeSessions = 0uL,
        capacityRejects = 0uL,
    )

    private fun notAdmittedMesh(): MeshAdmissionView = MeshAdmissionView(
        state = MeshAdmissionState.NOT_ADMITTED,
        reason = MeshAdmissionReason.NO_ACCEPTED_ADDRESS,
        endpoint = null,
        admissionEpoch = null,
        lastSequence = 10uL,
        ingressRunning = false,
        activeSessions = 0uL,
        capacityRejects = 0uL,
    )

    private fun rotation(
        phase: RotationPhaseView = RotationPhaseView.IDLE,
        terminal: RotationTerminalResultView? = null,
        failure: RotationFailureView? = null,
        beforeIp: String? = null,
        afterIp: String? = null,
    ): RotationSnapshotView = RotationSnapshotView(
        operationId = if (phase == RotationPhaseView.IDLE) null else 4uL,
        phase = phase,
        beforeGeneration = if (phase == RotationPhaseView.IDLE) null else 7uL,
        afterGeneration = when (phase) {
            RotationPhaseView.CHANGED,
            RotationPhaseView.UNCHANGED,
            RotationPhaseView.FAILED,
            -> 8uL
            else -> null
        },
        beforeIp = beforeIp,
        afterIp = afterIp,
        restoreRequired = false,
        terminalResult = terminal,
        failure = failure,
        restoreResult = null,
    )
}
