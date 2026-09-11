package com.mobileproxymish.app.cellular

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Process
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mobileproxymish.app.MishApplication
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * E3 physical-device acceptance harness for the PRODUCT root-policy Cellular Egress path.
 *
 * Hosted CI only compiles this androidTest APK. Protected-main physical execution uses
 * the exact MishApplication process-generation runtime: the Rust natural owner decides
 * admission/currentness and the PRODUCT Magisk adapter realizes that decision. The test
 * never recreates a second controller, never calls the historical per-socket bind seam,
 * and never substitutes ADB root for PRODUCT runtime root authority.
 */
@RunWith(AndroidJUnit4::class)
class CellularE3InstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)

    @Test
    fun runPhysicalScenario() {
        val arguments = InstrumentationRegistry.getArguments()
        val mode = arguments.getString("e3Mode") ?: "lifecycle"
        require(mode == "lifecycle") { "unsupported e3Mode=$mode" }
        runLifecycle(arguments)
    }

    private fun runLifecycle(arguments: android.os.Bundle) {
        val host = arguments.getString("e3Host") ?: "checkip.amazonaws.com"
        val requestedPort = arguments.getString("e3Port")?.toIntOrNull() ?: HTTPS_PORT
        val path = arguments.getString("e3Path") ?: "/"
        // Historical orchestration supplied port 80. Revised #75 acceptance requires
        // HTTPS, so the PRODUCT proof is pinned to 443 until the orchestration default is
        // cleaned up; the legacy input remains validated for artifact compatibility only.
        val proofPort = HTTPS_PORT

        require(HOST_PATTERN.matches(host)) { "e3Host must be a DNS hostname" }
        require(requestedPort in 1..65535) { "e3Port must be in 1..65535" }
        require(path.startsWith('/')) { "e3Path must start with /" }
        assertEquals(
            "instrumentation must execute inside the PRODUCT UID",
            context.applicationInfo.uid,
            Process.myUid(),
        )

        val application = context.applicationContext as? MishApplication
            ?: throw AssertionError("E3_SAFE_FAILURE stage=product_runtime application_missing")
        val runtime = application.cellularRuntime
        var mobileDataMayBeDisabled = false
        var runtimeClosed = false
        var establishedFlow: SSLSocket? = null

        try {
            // Positive: MishApplication already started the real process-generation bridge.
            // OwnerSnapshot(ADMITTED) is published only after the PRODUCT root policy has
            // reconciled and verified the marked IPv4 path for this owner observation.
            val positiveAdmission = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.ADMITTED,
                timeoutMillis = POSITIVE_TIMEOUT_MILLIS,
            )
            waitForDirectCellular(validated = true, present = true, timeoutMillis = POSITIVE_TIMEOUT_MILLIS)
            val positiveSequence = requireSequence(positiveAdmission, "positive")
            val positiveDns = currentDirectCellularIpv4DnsServers()
            assertFalse("direct cellular must expose at least one IPv4 DNS server", positiveDns.isEmpty())

            val positiveAddresses = resolveIpv4ThroughPolicy(positiveDns, host, "positive")
            val stableProbeAddress = positiveAddresses.first()
            val initialPublicIp = performPublicProbe(
                addresses = positiveAddresses,
                host = host,
                port = proofPort,
                path = path,
                phase = "positive",
            )
            requirePublicIpLiteral(initialPublicIp)

            // Establish a second real PRODUCT HTTPS/TCP flow while cellular authority is
            // current, but intentionally send no HTTP application request yet. The TLS
            // handshake proves that this exact socket existed over the admitted path before
            // the loss generation. It stays open across the transition below.
            establishedFlow = openEstablishedHttpsFlow(
                numericAddress = stableProbeAddress,
                host = host,
                port = proofPort,
            )
            println(
                "E3_EVIDENCE phase=positive owner_admitted=true product_root_policy=enforced " +
                    "dns=uid_policy public_socket=uid_policy transport=https " +
                    "public_ip_observed=true established_https_ready=true ipv6=fail_closed",
            )

            // Negative: LAB authority requests the bounded mobile-data control effect. The
            // command result is only a control-plane precondition; actual loss is proven
            // exclusively by the owner/ConnectivityManager facts observed below.
            mobileDataMayBeDisabled = true
            requireMobileDataTransition("disable")
            waitForDirectCellular(validated = false, present = false, timeoutMillis = NEGATIVE_TIMEOUT_MILLIS)
            val negativeAdmission = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.NOT_ADMITTED,
                timeoutMillis = NEGATIVE_TIMEOUT_MILLIS,
            )
            val negativeSequence = requireSequence(negativeAdmission, "negative")
            assertTrue(
                "negative owner sequence must supersede the positive generation",
                negativeSequence > positiveSequence,
            )
            assertEstablishedFlowFailsClosed(
                socket = establishedFlow
                    ?: throw AssertionError("E3_SAFE_FAILURE stage=established_flow socket_missing"),
                host = host,
                path = path,
            )
            establishedFlow = null
            assertDnsFailsClosed(positiveDns, host)
            assertPublicSocketFailsClosed(stableProbeAddress, proofPort)
            println(
                "E3_EVIDENCE phase=negative owner_not_admitted=true fresh_loss_generation=true " +
                    "established_flow_blocked=true dns_blocked=true public_socket_blocked=true " +
                    "no_default_fallback=true",
            )

            // Recovery: the same owner/runtime must reacquire direct cellular, mint a fresh
            // observation generation, rediscover the current route table and reconcile the
            // PRODUCT policy before public egress works again.
            requireMobileDataTransition("enable")
            mobileDataMayBeDisabled = false
            val recoveryAdmission = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.ADMITTED,
                timeoutMillis = RECOVERY_TIMEOUT_MILLIS,
            )
            waitForDirectCellular(validated = true, present = true, timeoutMillis = RECOVERY_TIMEOUT_MILLIS)
            val recoverySequence = requireSequence(recoveryAdmission, "recovery")
            assertTrue(
                "recovery owner sequence must supersede the loss generation",
                recoverySequence > negativeSequence,
            )

            val recoveryDns = currentDirectCellularIpv4DnsServers()
            assertFalse("recovered cellular must expose at least one IPv4 DNS server", recoveryDns.isEmpty())
            val recoveryAddresses = resolveIpv4ThroughPolicy(recoveryDns, host, "recovery")
            val recoveryPublicIp = performPublicProbe(
                addresses = recoveryAddresses,
                host = host,
                port = proofPort,
                path = path,
                phase = "recovery",
            )
            requirePublicIpLiteral(recoveryPublicIp)

            // Deliberate shutdown is part of the accepted PRODUCT lifecycle. Verify from
            // the same PRODUCT UID/root grant that all exact #75 signatures disappeared;
            // this is read-only verification after the production adapter performed delete.
            runtime.close()
            runtimeClosed = true
            verifyProductPolicyCleanup(Process.myUid())

            println(
                "E3_EVIDENCE phase=recovery owner_admitted=true fresh_generation=true " +
                    "product_root_policy=reconciled dns=uid_policy public_socket=uid_policy " +
                    "transport=https public_ip_observed=true cleanup_verified=true ipv6=fail_closed",
            )
        } finally {
            runCatching { establishedFlow?.close() }
            if (mobileDataMayBeDisabled) {
                runCatching { executeMobileDataTransition("enable") }
            }
            if (!runtimeClosed) {
                runtime.close()
            }
        }
    }

    private fun waitForOwnerState(
        runtime: CellularRuntimeBridge,
        expected: CellularAdmissionState,
        timeoutMillis: Long,
    ): CellularAdmissionView {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        var lastBoundary: CellularBoundaryFailure? = null
        do {
            when (val snapshot = runtime.snapshot.value) {
                is CellularRuntimeSnapshot.OwnerSnapshot -> {
                    if (snapshot.admission.state == expected) {
                        return snapshot.admission
                    }
                }

                is CellularRuntimeSnapshot.BoundaryUnavailable -> {
                    lastBoundary = snapshot.reason
                }
            }
            SystemClock.sleep(250)
        } while (SystemClock.elapsedRealtime() < deadline)

        if (lastBoundary != null) {
            throw AssertionError(
                "E3_SAFE_FAILURE stage=root_policy_boundary reason=$lastBoundary",
            )
        }
        val actual = (runtime.snapshot.value as? CellularRuntimeSnapshot.OwnerSnapshot)
            ?.admission
            ?.state
        throw AssertionError("owner state timeout expected=$expected actual=$actual")
    }

    private fun requireSequence(admission: CellularAdmissionView, phase: String): ULong =
        admission.lastSequence
            ?: throw AssertionError("E3_SAFE_FAILURE stage=owner_generation phase=$phase")

    /** Read-only evidence observation; this never becomes an admission source. */
    private fun waitForDirectCellular(
        validated: Boolean,
        present: Boolean,
        timeoutMillis: Long,
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        do {
            val observed = connectivityManager.allNetworks.any { network ->
                val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return@any false
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                    (!validated || capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
            }
            if (observed == present) {
                return
            }
            SystemClock.sleep(250)
        } while (SystemClock.elapsedRealtime() < deadline)

        throw AssertionError(
            "expected direct cellular Internet presence=$present validated_required=$validated",
        )
    }

    /**
     * Returns transient IPv4 resolver addresses published by the currently validated
     * direct-cellular Network. Addresses are used only in-memory and never logged.
     * Final resolver/anti-leak ownership remains Issue #64, outside E3.
     */
    private fun currentDirectCellularIpv4DnsServers(): List<Inet4Address> =
        connectivityManager.allNetworks.asSequence()
            .filter { network ->
                val capabilities = connectivityManager.getNetworkCapabilities(network)
                    ?: return@filter false
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            }
            .flatMap { network ->
                connectivityManager.getLinkProperties(network)
                    ?.dnsServers
                    ?.asSequence()
                    ?: emptySequence()
            }
            .filterIsInstance<Inet4Address>()
            .distinctBy { it.hostAddress }
            .toList()

    private fun resolveIpv4ThroughPolicy(
        dnsServers: List<Inet4Address>,
        host: String,
        phase: String,
    ): List<String> {
        val failures = mutableListOf<SafeProbeFailure>()
        for (server in dnsServers) {
            try {
                val addresses = queryIpv4Dns(server, host)
                if (addresses.isNotEmpty()) {
                    return addresses
                }
            } catch (failure: Throwable) {
                val safe = SafeProbeFailure("dns_query", failure.javaClass.name)
                failures += safe
                emitSafeAttempt(safe, phase)
            }
        }
        throw AssertionError(
            "E3_SAFE_FAILURE stage=dns_query phase=$phase attempts=${failures.size}",
        )
    }

    private fun queryIpv4Dns(server: Inet4Address, host: String): List<String> {
        val transactionId = ((SystemClock.elapsedRealtime() ushr 2) and 0xffff).toInt()
        val query = buildDnsQuery(transactionId, host)
        val responseBytes = ByteArray(DNS_RESPONSE_MAX_BYTES)

        DatagramSocket().use { socket ->
            socket.soTimeout = DNS_TIMEOUT_MILLIS
            socket.connect(server, DNS_PORT)
            socket.send(DatagramPacket(query, query.size))
            val response = DatagramPacket(responseBytes, responseBytes.size)
            socket.receive(response)
            return parseIpv4DnsResponse(
                transactionId = transactionId,
                response = responseBytes.copyOf(response.length),
            )
        }
    }

    private fun buildDnsQuery(transactionId: Int, host: String): ByteArray =
        ByteArrayOutputStream().use { output ->
            output.write((transactionId ushr 8) and 0xff)
            output.write(transactionId and 0xff)
            output.write(0x01) // recursion desired
            output.write(0x00)
            output.write(0x00)
            output.write(0x01) // one question
            repeat(6) { output.write(0x00) }

            for (label in host.trimEnd('.').split('.')) {
                val bytes = label.toByteArray(Charsets.US_ASCII)
                require(bytes.size in 1..63) { "invalid DNS label" }
                output.write(bytes.size)
                output.write(bytes)
            }
            output.write(0x00)
            output.write(0x00)
            output.write(0x01) // A
            output.write(0x00)
            output.write(0x01) // IN
            output.toByteArray()
        }

    private fun parseIpv4DnsResponse(transactionId: Int, response: ByteArray): List<String> {
        require(response.size >= DNS_HEADER_BYTES) { "short DNS response" }
        require(readU16(response, 0) == transactionId) { "DNS transaction mismatch" }
        val flags = readU16(response, 2)
        require(flags and 0x8000 != 0) { "DNS response bit missing" }
        require(flags and 0x000f == 0) { "DNS response rcode is non-zero" }

        val questionCount = readU16(response, 4)
        val answerCount = readU16(response, 6)
        var offset = DNS_HEADER_BYTES

        repeat(questionCount) {
            offset = skipDnsName(response, offset)
            require(offset + 4 <= response.size) { "truncated DNS question" }
            offset += 4
        }

        val addresses = mutableListOf<String>()
        repeat(answerCount) {
            offset = skipDnsName(response, offset)
            require(offset + 10 <= response.size) { "truncated DNS answer" }
            val type = readU16(response, offset)
            val dnsClass = readU16(response, offset + 2)
            val dataLength = readU16(response, offset + 8)
            offset += 10
            require(offset + dataLength <= response.size) { "truncated DNS rdata" }

            if (type == 1 && dnsClass == 1 && dataLength == 4) {
                addresses += (0 until 4).joinToString(".") { index ->
                    (response[offset + index].toInt() and 0xff).toString()
                }
            }
            offset += dataLength
        }
        return addresses.distinct()
    }

    private fun skipDnsName(packet: ByteArray, start: Int): Int {
        var offset = start
        while (true) {
            require(offset < packet.size) { "truncated DNS name" }
            val length = packet[offset].toInt() and 0xff
            when {
                length == 0 -> return offset + 1
                length and 0xc0 == 0xc0 -> {
                    require(offset + 1 < packet.size) { "truncated DNS pointer" }
                    return offset + 2
                }
                length in 1..63 -> {
                    offset += 1 + length
                    require(offset <= packet.size) { "truncated DNS label" }
                }
                else -> throw IllegalArgumentException("invalid DNS label length")
            }
        }
    }

    private fun readU16(bytes: ByteArray, offset: Int): Int {
        require(offset + 1 < bytes.size) { "truncated 16-bit field" }
        return ((bytes[offset].toInt() and 0xff) shl 8) or
            (bytes[offset + 1].toInt() and 0xff)
    }

    private fun performPublicProbe(
        addresses: List<String>,
        host: String,
        port: Int,
        path: String,
        phase: String,
    ): String {
        val failures = mutableListOf<SafeProbeFailure>()
        for (address in addresses) {
            try {
                return connectAndReadPublicIp(address, host, port, path)
            } catch (failure: Throwable) {
                val safe = SafeProbeFailure(classifyProbeStage(failure), failure.javaClass.name)
                failures += safe
                emitSafeAttempt(safe, phase)
            }
        }
        throw AssertionError(
            "E3_SAFE_FAILURE stage=public_probe phase=$phase attempts=${failures.size}",
        )
    }

    private fun connectAndReadPublicIp(
        numericAddress: String,
        host: String,
        port: Int,
        path: String,
    ): String {
        require(IPV4_LITERAL.matches(numericAddress)) { "DNS must return numeric IPv4" }
        val raw = Socket()
        try {
            raw.connect(
                InetSocketAddress(InetAddress.getByName(numericAddress), port),
                SOCKET_TIMEOUT_MILLIS,
            )
            raw.soTimeout = SOCKET_TIMEOUT_MILLIS

            val transport: Socket = if (port == HTTPS_PORT) {
                createVerifiedTlsSocket(raw, host, port)
            } else {
                raw
            }

            transport.use { socket ->
                val request = (
                    "GET $path HTTP/1.1\r\n" +
                        "Host: $host\r\n" +
                        "Connection: close\r\n" +
                        "User-Agent: mobile-proxy-mish-e3\r\n\r\n"
                    ).toByteArray(Charsets.US_ASCII)
                socket.getOutputStream().write(request)
                socket.getOutputStream().flush()

                val response = readBounded(socket.getInputStream())
                val text = response.toString(Charsets.US_ASCII)
                require(text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200")) {
                    "E3 echo endpoint must return HTTP 200"
                }
                val separator = text.indexOf("\r\n\r\n")
                require(separator >= 0) { "HTTP response must contain header/body separator" }
                return text.substring(separator + 4)
                    .trim()
                    .lineSequence()
                    .firstOrNull()
                    .orEmpty()
                    .trim()
            }
        } catch (failure: Throwable) {
            runCatching { raw.close() }
            throw failure
        }
    }

    private fun openEstablishedHttpsFlow(
        numericAddress: String,
        host: String,
        port: Int,
    ): SSLSocket {
        require(port == HTTPS_PORT) { "established-flow proof requires HTTPS/443" }
        require(IPV4_LITERAL.matches(numericAddress)) { "DNS must return numeric IPv4" }
        val raw = Socket()
        try {
            raw.keepAlive = true
            raw.connect(
                InetSocketAddress(InetAddress.getByName(numericAddress), port),
                SOCKET_TIMEOUT_MILLIS,
            )
            raw.soTimeout = SOCKET_TIMEOUT_MILLIS
            return createVerifiedTlsSocket(raw, host, port).also {
                it.keepAlive = true
            }
        } catch (failure: Throwable) {
            runCatching { raw.close() }
            throw failure
        }
    }

    private fun assertEstablishedFlowFailsClosed(
        socket: SSLSocket,
        host: String,
        path: String,
    ) {
        val escaped = try {
            socket.soTimeout = NEGATIVE_SOCKET_TIMEOUT_MILLIS
            val request = (
                "GET $path HTTP/1.1\r\n" +
                    "Host: $host\r\n" +
                    "Connection: close\r\n" +
                    "User-Agent: mobile-proxy-mish-e3-established\r\n\r\n"
                ).toByteArray(Charsets.US_ASCII)
            socket.getOutputStream().write(request)
            socket.getOutputStream().flush()

            val response = readBounded(socket.getInputStream())
            val text = response.toString(Charsets.US_ASCII)
            text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200")
        } catch (_: Throwable) {
            false
        } finally {
            runCatching { socket.close() }
        }

        assertFalse(
            "established PRODUCT HTTPS flow exchanged application data after NOT_ADMITTED",
            escaped,
        )
    }

    private fun createVerifiedTlsSocket(raw: Socket, host: String, port: Int): SSLSocket {
        val ssl = SSLSocketFactory.getDefault().createSocket(raw, host, port, true) as SSLSocket
        ssl.soTimeout = SOCKET_TIMEOUT_MILLIS
        ssl.startHandshake()
        require(HttpsURLConnection.getDefaultHostnameVerifier().verify(host, ssl.session)) {
            "TLS hostname verification failed"
        }
        return ssl
    }

    private fun assertDnsFailsClosed(dnsServers: List<Inet4Address>, host: String) {
        val escaped = dnsServers.any { server ->
            runCatching { queryIpv4Dns(server, host) }
                .getOrNull()
                ?.isNotEmpty() == true
        }
        assertFalse("negative DNS query escaped fail-closed policy", escaped)
    }

    private fun assertPublicSocketFailsClosed(numericAddress: String, port: Int) {
        val escaped = runCatching {
            Socket().use { socket ->
                socket.connect(
                    InetSocketAddress(InetAddress.getByName(numericAddress), port),
                    NEGATIVE_SOCKET_TIMEOUT_MILLIS,
                )
            }
            true
        }.getOrDefault(false)
        assertFalse("negative public socket escaped fail-closed policy", escaped)
    }

    private fun verifyProductPolicyCleanup(productUid: Int) {
        val identity = runProductRoot("id -u")
        if (identity.timedOut || identity.exitCode != 0 || identity.stdout.trim() != "0") {
            throw AssertionError("E3_SAFE_FAILURE stage=root_policy_cleanup root_authority_lost")
        }

        val ipv4Rules = runProductRoot("ip -4 rule show")
        val ipv6Rules = runProductRoot("ip -6 rule show")
        val ipv4Table = runProductRoot("iptables -t mangle -L OUTPUT -n")
        val ipv6Table = runProductRoot("ip6tables -t mangle -L OUTPUT -n")
        if (listOf(ipv4Rules, ipv6Rules, ipv4Table, ipv6Table).any {
                it.timedOut || it.exitCode != 0
            }
        ) {
            throw AssertionError("E3_SAFE_FAILURE stage=root_policy_cleanup inspection_failed")
        }

        assertFalse(
            "PRODUCT IPv4 lookup survived intentional cleanup",
            OWNED_IPV4_LOOKUP.containsMatchIn(ipv4Rules.stdout),
        )
        assertFalse(
            "PRODUCT IPv4 guard survived intentional cleanup",
            OWNED_GUARD.containsMatchIn(ipv4Rules.stdout),
        )
        assertFalse(
            "PRODUCT IPv6 guard survived intentional cleanup",
            OWNED_GUARD.containsMatchIn(ipv6Rules.stdout),
        )

        val ipv4Selector = runProductRoot(selectorCheckCommand("iptables", productUid))
        val ipv6Selector = runProductRoot(selectorCheckCommand("ip6tables", productUid))
        if (ipv4Selector.timedOut || ipv6Selector.timedOut) {
            throw AssertionError("E3_SAFE_FAILURE stage=root_policy_cleanup selector_check_timeout")
        }
        assertTrue(
            "PRODUCT IPv4 selector survived intentional cleanup",
            ipv4Selector.exitCode != 0,
        )
        assertTrue(
            "PRODUCT IPv6 selector survived intentional cleanup",
            ipv6Selector.exitCode != 0,
        )
    }

    private fun selectorCheckCommand(binary: String, productUid: Int): String =
        "$binary -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark 0x200000/0x200000"

    private fun runProductRoot(command: String): RootReadResult {
        val child = try {
            ProcessBuilder(listOf("su", "-c", command))
                .redirectErrorStream(true)
                .start()
        } catch (_: Exception) {
            return RootReadResult(exitCode = -1, stdout = "", timedOut = false)
        }

        return try {
            val deadline = SystemClock.elapsedRealtime() + ROOT_READ_TIMEOUT_MILLIS
            var exitCode: Int? = null
            do {
                exitCode = try {
                    child.exitValue()
                } catch (_: IllegalThreadStateException) {
                    null
                }
                if (exitCode == null) {
                    SystemClock.sleep(ROOT_READ_POLL_MILLIS)
                }
            } while (exitCode == null && SystemClock.elapsedRealtime() < deadline)

            if (exitCode == null) {
                child.destroy()
                RootReadResult(exitCode = -1, stdout = "", timedOut = true)
            } else {
                val stdout = child.inputStream
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                    .take(ROOT_READ_OUTPUT_MAX_CHARS)
                RootReadResult(exitCode = exitCode, stdout = stdout, timedOut = false)
            }
        } finally {
            child.destroy()
        }
    }

    private fun requireMobileDataTransition(state: String) {
        assertTrue("root mobile-data transition command failed", executeMobileDataTransition(state))
    }

    private fun executeMobileDataTransition(state: String): Boolean {
        require(state == "enable" || state == "disable")
        val command = "su -c 'cmd phone data $state'; code=\$?; echo E3_ROOT_EXIT:\$code"
        val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
        val output = android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader(Charsets.UTF_8)
            .use { it.readText() }
        return Regex("(?m)^E3_ROOT_EXIT:0\\s*$").containsMatchIn(output)
    }

    private fun readBounded(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4_096)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            output.write(buffer, 0, read)
            require(output.size() <= HTTP_RESPONSE_MAX_BYTES) {
                "E3 HTTP response exceeded 64 KiB"
            }
        }
        return output.toByteArray()
    }

    private fun requirePublicIpLiteral(value: String) {
        if (!isIpLiteral(value)) {
            throw AssertionError("E3_SAFE_FAILURE stage=public_ip_parse")
        }
    }

    private fun isIpLiteral(value: String): Boolean {
        val ipv6Characters = Regex("^[0-9A-Fa-f:]+$")
        return IPV4_LITERAL.matches(value) ||
            (value.contains(':') && ipv6Characters.matches(value))
    }

    private fun classifyProbeStage(failure: Throwable): String = when {
        failure.message?.contains("TLS hostname verification", ignoreCase = true) == true ->
            "tls_hostname"
        failure.message?.contains("HTTP 200", ignoreCase = true) == true -> "http_status"
        failure.message?.contains("header/body", ignoreCase = true) == true -> "response_parse"
        failure is javax.net.ssl.SSLException -> "tls_handshake"
        failure is java.net.ConnectException -> "socket_connect"
        failure is java.net.SocketTimeoutException -> "socket_timeout"
        else -> "public_probe"
    }

    private fun emitSafeAttempt(failure: SafeProbeFailure, phase: String) {
        println(
            "E3_SAFE_ATTEMPT phase=$phase stage=${failure.stage} class=${failure.exceptionClass}",
        )
    }

    private data class SafeProbeFailure(
        val stage: String,
        val exceptionClass: String,
    )

    private data class RootReadResult(
        val exitCode: Int,
        val stdout: String,
        val timedOut: Boolean,
    )

    private companion object {
        const val POSITIVE_TIMEOUT_MILLIS = 60_000L
        const val NEGATIVE_TIMEOUT_MILLIS = 60_000L
        const val RECOVERY_TIMEOUT_MILLIS = 120_000L
        const val DNS_PORT = 53
        const val DNS_TIMEOUT_MILLIS = 5_000
        const val DNS_HEADER_BYTES = 12
        const val DNS_RESPONSE_MAX_BYTES = 4_096
        const val SOCKET_TIMEOUT_MILLIS = 15_000
        const val NEGATIVE_SOCKET_TIMEOUT_MILLIS = 5_000
        const val HTTP_RESPONSE_MAX_BYTES = 65_536
        const val HTTPS_PORT = 443
        const val ROOT_READ_TIMEOUT_MILLIS = 5_000L
        const val ROOT_READ_POLL_MILLIS = 25L
        const val ROOT_READ_OUTPUT_MAX_CHARS = 8_192

        val HOST_PATTERN = Regex("^[A-Za-z0-9.-]+$")
        val IPV4_LITERAL = Regex(
            "^(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}$",
        )
        val OWNED_IPV4_LOOKUP = Regex(
            "(?m)^9500:\\s+from\\s+all\\s+fwmark\\s+0x200000/0x200000\\s+lookup\\s+",
        )
        val OWNED_GUARD = Regex(
            "(?m)^9501:\\s+from\\s+all\\s+fwmark\\s+0x200000/0x200000\\s+unreachable",
        )
    }
}
