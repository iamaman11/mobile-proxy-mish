package com.mobileproxymish.app.cellular

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.system.StructTimeval
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularController
import com.mobileproxymish.ffi.CellularNetworkLease
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * E3 physical-device acceptance harness for the Cellular Egress boundary.
 *
 * This test is intentionally not executed by ordinary hosted CI. Hosted CI only compiles
 * the androidTest APK. A self-hosted runner with a real rooted phone executes this class.
 */
@RunWith(AndroidJUnit4::class)
class CellularE3InstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)

    @Test
    fun runPhysicalScenario() {
        val arguments = InstrumentationRegistry.getArguments()
        when (val mode = arguments.getString("e3Mode") ?: "positive") {
            "positive" -> runPositive(arguments)
            "negative" -> runNegative()
            else -> error("unsupported e3Mode=$mode")
        }
    }

    private fun runPositive(arguments: android.os.Bundle) {
        val host = arguments.getString("e3Host") ?: "checkip.amazonaws.com"
        val port = arguments.getString("e3Port")?.toIntOrNull() ?: 80
        val path = arguments.getString("e3Path") ?: "/"

        require(port in 1..65535) { "e3Port must be in 1..65535" }
        require(path.startsWith('/')) { "e3Path must start with /" }

        val controller = CellularController()
        val observer = CellularNetworkObserver(context, forwardingSink(controller))
        observer.start()
        try {
            // The observer now owns an active requestNetwork() lifetime. Do not require
            // cellular to exist before starting it: DEVICE-1 proved that the product must
            // be able to acquire/retain a background direct cellular Network itself.
            waitForAdmission(controller, CellularAdmissionState.ADMITTED)
            waitForDirectCellular(validated = true, present = true)

            val lease = controller.admittedNetworkLease()
            val publicIp = performBoundHttpProbe(lease, host, port, path)

            assertTrue("echo response must be a bare IPv4/IPv6 literal", isIpLiteral(publicIp))
            println(
                "E3_EVIDENCE mode=positive direct_cellular_validated=true " +
                    "not_vpn=owner_verified dns=lease socket_bind=lease public_ip_observed=true",
            )
        } finally {
            observer.close()
        }
    }

    private fun runNegative() {
        // LAB disables user mobile data before this mode. The product request is then
        // started deliberately: it must fail closed rather than minting authority from
        // Wi-Fi, Cloudflare VPN, IMS-only cellular, or another default network.
        waitForDirectCellular(validated = false, present = false)

        val controller = CellularController()
        val observer = CellularNetworkObserver(context, forwardingSink(controller))
        observer.start()
        try {
            SystemClock.sleep(5_000)
            assertFalse(
                "cellular owner must not become ADMITTED while direct cellular is unavailable",
                controller.admissionSnapshot().state == CellularAdmissionState.ADMITTED,
            )

            var leaseIssued = false
            try {
                controller.admittedNetworkLease()
                leaseIssued = true
            } catch (_: Exception) {
                // Expected fail-closed path: UNKNOWN/NOT_ADMITTED cannot mint a lease.
            }
            assertFalse("no cellular authority lease may be issued", leaseIssued)
            println(
                "E3_EVIDENCE mode=negative direct_cellular_available=false lease_issued=false",
            )
        } finally {
            observer.close()
        }
    }

    private fun forwardingSink(controller: CellularController): CellularObservationSink =
        CellularObservationSink { event ->
            when (event) {
                is CellularNetworkEvent.Observed -> controller.observeNetwork(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                    isCellular = event.isCellular,
                    hasInternet = event.hasInternet,
                    isValidated = event.isValidated,
                    isNotVpn = event.isNotVpn,
                )

                is CellularNetworkEvent.Lost -> controller.networkLost(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                )
            }
        }

    private fun waitForAdmission(
        controller: CellularController,
        expected: CellularAdmissionState,
        timeoutMillis: Long = 30_000,
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        do {
            if (controller.admissionSnapshot().state == expected) {
                return
            }
            SystemClock.sleep(250)
        } while (SystemClock.elapsedRealtime() < deadline)

        assertEquals(expected, controller.admissionSnapshot().state)
    }

    /**
     * Observes only the direct cellular Internet path relevant to Cellular Egress.
     *
     * `validated=false` means validation is not required by the predicate; it is used
     * for the negative precondition so even an unvalidated direct cellular Internet
     * Network prevents an "absent" classification. VPN-derived and IMS-only networks
     * never satisfy this predicate.
     */
    private fun waitForDirectCellular(
        validated: Boolean,
        present: Boolean,
        timeoutMillis: Long = 30_000,
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

        assertTrue(
            "expected direct cellular Internet presence=$present validated_required=$validated",
            false,
        )
    }

    private fun performBoundHttpProbe(
        lease: CellularNetworkLease,
        host: String,
        port: Int,
        path: String,
    ): String {
        val numericAddresses = lease.resolveHost(host)
        assertFalse("network-scoped DNS returned no addresses", numericAddresses.isEmpty())

        var lastFailure: Throwable? = null
        for (numericAddress in numericAddresses) {
            try {
                return connectAndReadPublicIp(lease, numericAddress, host, port, path)
            } catch (failure: Throwable) {
                lastFailure = failure
            }
        }

        throw AssertionError("all lease-resolved addresses failed", lastFailure)
    }

    private fun connectAndReadPublicIp(
        lease: CellularNetworkLease,
        numericAddress: String,
        host: String,
        port: Int,
        path: String,
    ): String {
        val family = if (numericAddress.contains(':')) OsConstants.AF_INET6 else OsConstants.AF_INET
        val address = Os.inet_pton(family, numericAddress)
        assertNotNull("lease must return numeric IP strings", address)

        val original = Os.socket(family, OsConstants.SOCK_STREAM, OsConstants.IPPROTO_TCP)
        val rawFd = try {
            ParcelFileDescriptor.dup(original).use { duplicate -> duplicate.detachFd() }
        } finally {
            Os.close(original)
        }

        ParcelFileDescriptor.adoptFd(rawFd).use { socket ->
            if (Build.VERSION.SDK_INT >= 29) {
                val timeout = StructTimeval.fromMillis(15_000)
                Os.setsockoptTimeval(
                    socket.fileDescriptor,
                    OsConstants.SOL_SOCKET,
                    OsConstants.SO_RCVTIMEO,
                    timeout,
                )
                Os.setsockoptTimeval(
                    socket.fileDescriptor,
                    OsConstants.SOL_SOCKET,
                    OsConstants.SO_SNDTIMEO,
                    timeout,
                )
            }

            // This exact fd is bound through the same opaque owner-issued lease that
            // performed DNS above. No default process/network binding is used.
            lease.bindSocket(rawFd)
            Os.connect(socket.fileDescriptor, address, port)

            val request = (
                "GET $path HTTP/1.1\r\n" +
                    "Host: $host\r\n" +
                    "Connection: close\r\n" +
                    "User-Agent: mobile-proxy-mish-e3\r\n\r\n"
                ).toByteArray(Charsets.US_ASCII)
            writeAll(socket.fileDescriptor, request)

            val response = readBounded(socket.fileDescriptor)
            val text = response.toString(Charsets.US_ASCII)
            assertTrue(
                "E3 echo endpoint must return HTTP 200",
                text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200"),
            )
            val separator = text.indexOf("\r\n\r\n")
            assertTrue("HTTP response must contain header/body separator", separator >= 0)
            return text.substring(separator + 4).trim().lineSequence().firstOrNull().orEmpty().trim()
        }
    }

    private fun writeAll(fd: java.io.FileDescriptor, bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val written = Os.write(fd, bytes, offset, bytes.size - offset)
            assertTrue("socket write made no progress", written > 0)
            offset += written
        }
    }

    private fun readBounded(fd: java.io.FileDescriptor): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4_096)
        while (true) {
            val read = Os.read(fd, buffer, 0, buffer.size)
            if (read == 0) {
                break
            }
            output.write(buffer, 0, read)
            assertTrue("E3 HTTP response exceeded 64 KiB", output.size() <= 65_536)
        }
        return output.toByteArray()
    }

    private fun isIpLiteral(value: String): Boolean {
        val ipv4 = Regex("^(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}$")
        val ipv6Characters = Regex("^[0-9A-Fa-f:]+$")
        return ipv4.matches(value) || (value.contains(':') && ipv6Characters.matches(value))
    }
}
