package com.mobileproxymish.app.cellular

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PublicIpProbeEffectTest {
    @Test
    fun numericIpv4ParsingNeverUsesDefaultDns() {
        assertArrayEquals(
            byteArrayOf(203.toByte(), 0, 113, 9),
            parseNumericIpv4Address("203.0.113.9"),
        )
        assertThrows(IllegalArgumentException::class.java) {
            parseNumericIpv4Address("example.com")
        }
        assertThrows(IllegalArgumentException::class.java) {
            parseNumericIpv4Address("203.0.113.999")
        }
    }

    @Test
    fun httpParserAcceptsOnlySuccessAndBoundedBody() {
        val response = (
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" +
                "198.51.100.42\n"
            ).toByteArray(Charsets.US_ASCII)
        assertEquals(
            "198.51.100.42\n",
            parseHttp200Body(response, maxBodyBytes = 64),
        )

        assertThrows(Exception::class.java) {
            parseHttp200Body(
                "HTTP/1.1 503 Service Unavailable\r\n\r\nnope"
                    .toByteArray(Charsets.US_ASCII),
                maxBodyBytes = 64,
            )
        }
        assertThrows(Exception::class.java) {
            parseHttp200Body(
                "HTTP/1.1 200 OK\r\n\r\n11111111111111111111111111111111111111111111111111111111111111111"
                    .toByteArray(Charsets.US_ASCII),
                maxBodyBytes = 64,
            )
        }
        assertThrows(Exception::class.java) {
            parseHttp200Body(
                "HTTP/1.1 200 OK\r\nmissing-separator"
                    .toByteArray(Charsets.US_ASCII),
                maxBodyBytes = 64,
            )
        }
    }
}
