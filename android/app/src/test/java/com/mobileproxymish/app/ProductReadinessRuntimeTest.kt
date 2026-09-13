package com.mobileproxymish.app

import com.mobileproxymish.ffi.EgressProbeOutcome
import org.junit.Assert.assertEquals
import org.junit.Test

class ProductReadinessRuntimeTest {
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
