package com.mobileproxymish.app

import android.util.Base64
import com.mobileproxymish.ffi.EgressProbeOutcome
import com.mobileproxymish.ffi.ReadinessProbeTargetView
import com.mobileproxymish.ffi.proxyHttpConnectPort
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * One narrow Android network effect for readiness: authenticated CONNECT through the local native
 * proxy followed by a hostname-verified TLS handshake. It owns no readiness policy or freshness
 * state; the injected predicate is the Rust owner's current ticket check.
 *
 * The public hostname is written only into CONNECT/TLS SNI. Android never resolves it directly;
 * native Proxy Serving preserves the unresolved target until the Cellular Egress DNS owner.
 */
internal class AuthenticatedEgressProbe(
    private val isFreshnessCurrent: (ULong) -> Boolean,
) {
    private val socketLock = Any()
    private var activeSocket: Socket? = null

    fun execute(
        freshness: ULong,
        target: ReadinessProbeTargetView,
        credentials: ProxyRuntimeCredentials,
        budgetMs: Long,
    ): EgressProbeOutcome {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budgetMs)
        val socket = Socket()
        if (!registerActiveSocket(freshness, socket)) {
            socket.close()
            return EgressProbeOutcome.TRANSPORT_FAILED
        }

        try {
            socket.connect(
                InetSocketAddress(LOOPBACK, proxyHttpConnectPort().toInt()),
                remainingMillis(deadline),
            )
            socket.soTimeout = remainingMillis(deadline)

            val authority = "${target.hostname}:${target.port}"
            val basic = Base64.encodeToString(
                "${credentials.username}:${credentials.password}"
                    .toByteArray(StandardCharsets.UTF_8),
                Base64.NO_WRAP,
            )
            val request = buildString {
                append("CONNECT ")
                append(authority)
                append(" HTTP/1.1\r\nHost: ")
                append(authority)
                append("\r\nProxy-Authorization: Basic ")
                append(basic)
                append("\r\nProxy-Connection: keep-alive\r\n\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            socket.getOutputStream().apply {
                write(request)
                flush()
            }

            val header = readBoundedConnectHeader(socket, deadline)
                ?: return EgressProbeOutcome.TRANSPORT_FAILED
            val status = classifyProxyConnectStatusLine(header.lineSequence().firstOrNull().orEmpty())
            if (status != EgressProbeOutcome.SUCCEEDED) return status

            val sslFactory = SSLSocketFactory.getDefault() as? SSLSocketFactory
                ?: return EgressProbeOutcome.TLS_FAILED
            val ssl = sslFactory.createSocket(
                socket,
                target.hostname,
                target.port.toInt(),
                false,
            ) as? SSLSocket ?: return EgressProbeOutcome.TLS_FAILED
            ssl.use {
                it.soTimeout = remainingMillis(deadline)
                it.startHandshake()
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(target.hostname, it.session)) {
                    return EgressProbeOutcome.TLS_FAILED
                }
            }
            return EgressProbeOutcome.SUCCEEDED
        } catch (_: SocketTimeoutException) {
            return EgressProbeOutcome.TIMEOUT
        } catch (_: SSLException) {
            return EgressProbeOutcome.TLS_FAILED
        } catch (_: IOException) {
            return EgressProbeOutcome.TRANSPORT_FAILED
        } catch (_: RuntimeException) {
            return EgressProbeOutcome.TRANSPORT_FAILED
        } finally {
            synchronized(socketLock) {
                if (activeSocket === socket) activeSocket = null
            }
            runCatching { socket.close() }
        }
    }

    fun cancel() {
        synchronized(socketLock) {
            activeSocket?.let { runCatching { it.close() } }
            activeSocket = null
        }
    }

    private fun registerActiveSocket(freshness: ULong, socket: Socket): Boolean =
        synchronized(socketLock) {
            if (!isFreshnessCurrent(freshness)) {
                false
            } else {
                activeSocket?.let { runCatching { it.close() } }
                activeSocket = socket
                true
            }
        }

    private fun readBoundedConnectHeader(socket: Socket, deadline: Long): String? {
        val input = socket.getInputStream()
        val output = ByteArrayOutputStream()
        var suffix = 0
        while (output.size() < MAX_CONNECT_HEADER_BYTES) {
            socket.soTimeout = remainingMillis(deadline)
            val next = input.read()
            if (next < 0) return null
            output.write(next)
            suffix = when {
                suffix == 0 && next == '\r'.code -> 1
                suffix == 1 && next == '\n'.code -> 2
                suffix == 2 && next == '\r'.code -> 3
                suffix == 3 && next == '\n'.code -> 4
                next == '\r'.code -> 1
                else -> 0
            }
            if (suffix == 4) {
                return output.toString(StandardCharsets.US_ASCII.name())
            }
        }
        return null
    }

    private fun remainingMillis(deadline: Long): Int {
        val remainingNanos = deadline - System.nanoTime()
        if (remainingNanos <= 0L) throw SocketTimeoutException("readiness probe deadline expired")
        return TimeUnit.NANOSECONDS
            .toMillis(remainingNanos)
            .coerceAtLeast(1L)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }

    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val MAX_CONNECT_HEADER_BYTES = 8_192
    }
}

/** Pure parser used by the concrete readiness effect; it owns no proxy policy. */
internal fun classifyProxyConnectStatusLine(statusLine: String): EgressProbeOutcome {
    val parts = statusLine.trim().split(Regex("\\s+"), limit = 3)
    if (parts.size < 2 || (parts[0] != "HTTP/1.0" && parts[0] != "HTTP/1.1")) {
        return EgressProbeOutcome.TRANSPORT_FAILED
    }
    val status = parts[1].toIntOrNull() ?: return EgressProbeOutcome.TRANSPORT_FAILED
    return when {
        status == 407 -> EgressProbeOutcome.AUTHENTICATION_FAILED
        status in 200..299 -> EgressProbeOutcome.SUCCEEDED
        else -> EgressProbeOutcome.TRANSPORT_FAILED
    }
}
