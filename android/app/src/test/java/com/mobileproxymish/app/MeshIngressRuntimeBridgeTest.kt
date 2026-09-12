package com.mobileproxymish.app

import org.junit.Assert.assertEquals
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
            listOf("192.168.1.4", "100.96.2.4"),
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
}
