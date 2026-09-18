package com.mobileproxymish.app

import com.mobileproxymish.ffi.EgressProbeOutcome
import com.mobileproxymish.ffi.ProbeBindingView
import org.junit.Assert.assertEquals
import org.junit.Test

class ProductReadinessRuntimeTest {
    @Test
    fun delayedRefreshRequiresExactCurrentBindingIdentity() {
        val expected = ProbeBindingView(
            cellularOwnerGeneration = 11uL,
            runtimeGeneration = 21uL,
            proxyServingGeneration = 31uL,
            meshAdmissionEpoch = 41uL,
            credentialVersion = 51uL,
        )
        assertEquals(true, readinessRefreshBindingStillCurrent(expected, expected))
        assertEquals(false, readinessRefreshBindingStillCurrent(expected, null))
        assertEquals(
            false,
            readinessRefreshBindingStillCurrent(expected, expected.copy(meshAdmissionEpoch = 42uL)),
        )
        assertEquals(
            false,
            readinessRefreshBindingStillCurrent(expected, expected.copy(credentialVersion = 52uL)),
        )
    }

    @Test
    fun connectStatusClassificationIsFailClosedAndAuthTyped() {
        assertEquals(
            EgressProbeOutcome.SUCCEEDED,
            classifyProxyConnectStatusLine("HTTP/1.1 200 Connection established"),
        )
        assertEquals(
            EgressProbeOutcome.SUCCEEDED,
            classifyProxyConnectStatusLine("HTTP/1.0 204 No Content"),
        )
        assertEquals(
            EgressProbeOutcome.AUTHENTICATION_FAILED,
            classifyProxyConnectStatusLine("HTTP/1.1 407 Proxy Authentication Required"),
        )
        for (line in listOf(
            "HTTP/1.1 502 Bad Gateway",
            "HTTP/2 200",
            "not-http",
            "HTTP/1.1 nope",
            "",
        )) {
            assertEquals(
                EgressProbeOutcome.TRANSPORT_FAILED,
                classifyProxyConnectStatusLine(line),
            )
        }
    }
}
