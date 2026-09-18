package com.mobileproxymish.app.cellular

import com.mobileproxymish.ffi.CellularController
import com.mobileproxymish.ffi.PublicIpEffectFailure
import com.mobileproxymish.ffi.PublicIpObservationView
import com.mobileproxymish.ffi.PublicIpProbeTicket
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Android effect adapter for one Rust-issued Cellular public-IP observation ticket.
 *
 * It owns no admission/currentness/readiness state. DNS, endpoint identity, generation binding,
 * deadline authority and final IP parsing remain in Rust. Android performs only an ordinary
 * PRODUCT-UID TCP + verified TLS/HTTPS effect over numeric candidates already produced by the
 * owner-bound cellular DNS seam.
 */
internal class PublicIpProbeEffect(
    private val controller: CellularController,
) {
    fun observe(timeoutMs: Long): PublicIpObservationView {
        require(timeoutMs in 1..MAX_TIMEOUT_MS) { "public IP timeout must be bounded" }
        val ticket = controller.preparePublicIpProbe(timeoutMs.toULong())
        val body = try {
            executeHttps(ticket)
        } catch (failure: Throwable) {
            ticket.effectFailed(classifyEffectFailure(failure))
            throw IllegalStateException("public IP effect failure was not rejected by Rust")
        }
        return ticket.complete(body)
    }

    private fun executeHttps(ticket: PublicIpProbeTicket): String {
        val addresses = ticket.numericAddresses()
        if (addresses.isEmpty()) {
            throw PublicIpResponseMalformedException()
        }

        var lastFailure: Throwable? = null
        for (numericAddress in addresses) {
            try {
                return connectAndRead(ticket, numericAddress)
            } catch (failure: Throwable) {
                lastFailure = failure
                if (failure is PublicIpTlsHostnameException ||
                    failure is PublicIpHttpStatusException ||
                    failure is PublicIpResponseTooLargeException ||
                    failure is PublicIpResponseMalformedException
                ) {
                    break
                }
            }
        }
        throw lastFailure ?: PublicIpResponseMalformedException()
    }

    private fun connectAndRead(ticket: PublicIpProbeTicket, numericAddress: String): String {
        val address = InetAddress.getByAddress(parseNumericIpv4Address(numericAddress))
        val port = ticket.endpointPort().toInt()
        val host = ticket.endpointHost()
        val path = ticket.endpointPath()

        val raw = Socket()
        try {
            raw.connect(
                InetSocketAddress(address, port),
                remainingTimeoutInt(ticket),
            )
            raw.soTimeout = remainingTimeoutInt(ticket)

            val tls = SSLSocketFactory.getDefault().createSocket(raw, host, port, true) as SSLSocket
            tls.soTimeout = remainingTimeoutInt(ticket)
            tls.startHandshake()
            if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, tls.session)) {
                throw PublicIpTlsHostnameException()
            }

            tls.use { socket ->
                socket.soTimeout = remainingTimeoutInt(ticket)
                val request = (
                    "GET $path HTTP/1.1\r\n" +
                        "Host: $host\r\n" +
                        "Connection: close\r\n" +
                        "User-Agent: mobile-proxy-mish-u4\r\n" +
                        "Accept: text/plain\r\n\r\n"
                    ).toByteArray(Charsets.US_ASCII)
                socket.getOutputStream().write(request)
                socket.getOutputStream().flush()
                socket.soTimeout = remainingTimeoutInt(ticket)
                val response = readBounded(socket.getInputStream(), HTTP_RESPONSE_MAX_BYTES)
                return parseHttp200Body(
                    response = response,
                    maxBodyBytes = ticket.responseBodyMaxBytes()
                        .coerceAtMost(Int.MAX_VALUE.toULong())
                        .toInt(),
                )
            }
        } catch (failure: Throwable) {
            runCatching { raw.close() }
            throw failure
        }
    }

    private fun remainingTimeoutInt(ticket: PublicIpProbeTicket): Int =
        ticket.remainingTimeoutMs()
            .coerceAtMost(Int.MAX_VALUE.toULong())
            .toInt()
            .coerceAtLeast(1)

    private fun classifyEffectFailure(failure: Throwable): PublicIpEffectFailure = when (failure) {
        is PublicIpTlsHostnameException -> PublicIpEffectFailure.TLS_HOSTNAME
        is PublicIpHttpStatusException -> PublicIpEffectFailure.HTTP_STATUS
        is PublicIpResponseTooLargeException -> PublicIpEffectFailure.RESPONSE_TOO_LARGE
        is PublicIpResponseMalformedException -> PublicIpEffectFailure.RESPONSE_MALFORMED
        is SocketTimeoutException -> PublicIpEffectFailure.SOCKET_TIMEOUT
        is ConnectException -> PublicIpEffectFailure.SOCKET_CONNECT
        is SSLException -> PublicIpEffectFailure.TLS_HANDSHAKE
        else -> PublicIpEffectFailure.IO
    }

    private companion object {
        const val MAX_TIMEOUT_MS = 120_000L
        const val HTTP_RESPONSE_MAX_BYTES = 2_048
    }
}

internal fun parseNumericIpv4Address(value: String): ByteArray {
    val parts = value.split('.')
    require(parts.size == 4) { "numeric candidate must be IPv4" }
    return ByteArray(4) { index ->
        val part = parts[index]
        require(part.isNotEmpty() && part.all(Char::isDigit)) {
            "numeric candidate must be IPv4"
        }
        val octet = part.toIntOrNull()
        require(octet != null && octet in 0..255) { "numeric candidate must be IPv4" }
        octet.toByte()
    }
}

internal fun parseHttp200Body(
    response: ByteArray,
    maxBodyBytes: Int,
): String {
    require(maxBodyBytes > 0) { "public IP body bound must be positive" }
    val text = response.toString(Charsets.US_ASCII)
    val separator = text.indexOf("\r\n\r\n")
    if (separator < 0) throw PublicIpResponseMalformedException()

    val header = text.substring(0, separator)
    val status = header.lineSequence().firstOrNull().orEmpty()
    if (status != "HTTP/1.1 200 OK" &&
        !status.startsWith("HTTP/1.1 200 ") &&
        !status.startsWith("HTTP/1.0 200 ")
    ) {
        throw PublicIpHttpStatusException()
    }

    val body = text.substring(separator + 4)
    if (body.toByteArray(Charsets.US_ASCII).size > maxBodyBytes) {
        throw PublicIpResponseTooLargeException()
    }
    return body
}

private fun readBounded(input: InputStream, maxBytes: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(256)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        if (output.size() + count > maxBytes) {
            throw PublicIpResponseTooLargeException()
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private class PublicIpTlsHostnameException : Exception()
private class PublicIpHttpStatusException : Exception()
private class PublicIpResponseTooLargeException : Exception()
private class PublicIpResponseMalformedException : Exception()
