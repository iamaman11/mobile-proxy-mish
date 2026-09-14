package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeshIngressRuntimeBridgeTest {
    @Test
    fun zeroCurrentVpnsProducesAbsentSnapshot() {
        assertEquals(
            AndroidMeshVpnObservation.Absent,
            classifyMeshVpnNetworks(emptyList()),
        )
    }

    @Test
    fun oneCurrentVpnCarriesRawIpv4WithoutChoosingMeshEndpoint() {
        val observation = classifyMeshVpnNetworks(
            listOf(
                listOf(
                    "192.168.1.4",
                    "100.96.2.4",
                    "100.96.2.4",
                ),
            ),
        )

        assertTrue(observation is AndroidMeshVpnObservation.UniqueVpn)
        observation as AndroidMeshVpnObservation.UniqueVpn
        assertEquals(
            listOf("192.168.1.4", "100.96.2.4", "100.96.2.4"),
            observation.localIpv4,
        )
    }

    @Test
    fun multipleCurrentVpnsAreAmbiguousRatherThanMerged() {
        val observation = classifyMeshVpnNetworks(
            listOf(
                listOf("100.96.2.4"),
                listOf("100.97.2.5"),
            ),
        )

        assertEquals(AndroidMeshVpnObservation.AmbiguousVpn, observation)
    }

    @Test
    fun recoveryTelemetryEmitsOnlyOnRisingReadyEdge() {
        assertTrue(recoveryTransitionBecameReady(previous = false, current = true))
        assertFalse(recoveryTransitionBecameReady(previous = false, current = false))
        assertFalse(recoveryTransitionBecameReady(previous = true, current = true))
        assertFalse(recoveryTransitionBecameReady(previous = true, current = false))
    }

    @Test
    fun publicIngressWaitsForPrivateEgressReadiness() {
        assertFalse(
            meshIngressServingAllowed(
                proxyRunning = true,
                readiness = com.mobileproxymish.ffi.ProductReadinessState.NOT_READY,
                meshAdmitted = true,
                admissionEpoch = 7u,
            ),
        )
        assertFalse(
            meshIngressServingAllowed(
                proxyRunning = true,
                readiness = com.mobileproxymish.ffi.ProductReadinessState.DEGRADED,
                meshAdmitted = true,
                admissionEpoch = 7u,
            ),
        )
        assertFalse(
            meshIngressServingAllowed(
                proxyRunning = false,
                readiness = com.mobileproxymish.ffi.ProductReadinessState.READY,
                meshAdmitted = true,
                admissionEpoch = 7u,
            ),
        )
        assertTrue(
            meshIngressServingAllowed(
                proxyRunning = true,
                readiness = com.mobileproxymish.ffi.ProductReadinessState.READY,
                meshAdmitted = true,
                admissionEpoch = 7u,
            ),
        )
    }
}
