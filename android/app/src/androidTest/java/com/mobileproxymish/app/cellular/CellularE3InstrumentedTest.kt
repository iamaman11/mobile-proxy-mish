package com.mobileproxymish.app.cellular

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * E3 physical-device acceptance harness for the Cellular Egress boundary.
 *
 * Hosted CI only compiles this androidTest APK. A protected-main physical run executes
 * the complete positive -> negative -> recovery lifecycle on one live controller and
 * one live requestNetwork() registration so recovery proves the product contract rather
 * than a fresh-process retry.
 */
@RunWith(AndroidJUnit4::class)
class CellularE3InstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)

    private class SafeProbeFailure(
        val stage: String,
        val exceptionClass: String,
        val errno: Int?,
    ) : AssertionError("safe E3 probe failure")

    @Test
    fun runPhysicalScenario() {
        val arguments = InstrumentationRegistry.getArguments()
        val mode = arguments.getString("e3Mode") ?: "lifecycle"
        require(mode == "lifecycle") { "unsupported e3Mode=$mode" }
        runLifecycle(arguments)
    }

    private fun runLifecycle(arguments: android.os.Bundle) {
        val host = arguments.getString("e3Host") ?: "checkip.amazonaws.com"
        val port = arguments.getString("e3Port")?.toIntOrNull() ?: 80
        val path = arguments.getString("e3Path") ?: "/"

        require(port in 1..65535) { "e3Port must be in 1..65535" }
        require(path.startsWith('/')) { "e3Path must start with /" }

        val controller = CellularController()
        val observer = CellularNetworkObserver(context, forwardingSink(controller))
        var mobileDataMayBeDisabled = false
        observer.start()
        try {
            // Positive: this same request lifetime must acquire the direct cellular
            // Internet Network even while another default/VPN network may exist.
            waitForAdmission(controller, CellularAdmissionState.ADMITTED, 60_000)
            waitForDirectCellular(validated = true, present = true, timeoutMillis = 60_000)
            val initialLease = controller.admittedNetworkLease()
            val initialPublicIp = performBoundHttpProbe(initialLease, host, port, path)
            requirePublicIpLiteral(initialPublicIp)
            println(
                "E3_EVIDENCE phase=positive direct_cellular_validated=true " +
                    "not_vpn=owner_verified dns=lease socket_bind=lease public_ip_observed=true",
            )

            // Negative: the immutable test harness performs the same already-authorized
            // root `svc data disable` effect used by LAB, while keeping this request and
            // owner alive. onLost must revoke authority; Wi-Fi/VPN/IMS cannot substitute.
            mobileDataMayBeDisabled = true
            requireMobileDataTransition("disable")
            waitForDirectCellular(validated = false, present = false, timeoutMillis = 60_000)
            waitForAdmission(controller, CellularAdmissionState.NOT_ADMITTED, 60_000)
            assertNoLease(controller)
            assertLeaseRevoked(initialLease, host)
            println(
                "E3_EVIDENCE phase=negative direct_cellular_available=false " +
                    "owner_not_admitted=true lease_issued=false old_lease_revoked=true",
            )

            // Recovery: only the user mobile-data setting is re-enabled. The still-live
            // requestNetwork() registration must cause Android to recreate a matching
            // direct cellular Network and the same owner must mint fresh authority.
            requireMobileDataTransition("enable")
            mobileDataMayBeDisabled = false
            waitForAdmission(controller, CellularAdmissionState.ADMITTED, 120_000)
            waitForDirectCellular(validated = true, present = true, timeoutMillis = 120_000)
            val recoveryLease = controller.admittedNetworkLease()
            val recoveryPublicIp = performBoundHttpProbe(recoveryLease, host, port, path)
            requirePublicIpLiteral(recoveryPublicIp)
            println(
                "E3_EVIDENCE phase=recovery direct_cellular_validated=true " +
                    "not_vpn=owner_verified fresh_lease=true dns=lease socket_bind=lease " +
                    "public_ip_observed=true",
            )
        } finally {
            // Cleanup is best-effort here because any failure already prevents E3 PASS;
            // the outer Windows harness performs a second bounded `svc data enable`.
            if (mobileDataMayBeDisabled) {
                runCatching { executeMobileDataTransition("enable") }
            }
            observer.close()
        }
    }

    private fun requireMobileDataTransition(state: String) {
        assertTrue("root mobile-data transition failed", executeMobileDataTransition(state))
    }

    private fun executeMobileDataTransition(state: String): Boolean {
        require(state == "enable" || state == "disable")
        val command = "su -c 'svc data $state'; code=\$?; echo E3_ROOT_EXIT:\$code"
        val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
        val output = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader(Charsets.UTF_8)
            .use { it.readText() }
        return Regex("(?m)^E3_ROOT_EXIT:0\\s*$").containsMatchIn(output)
    }

    private fun assertNoLease(controller: CellularController) {
        var leaseIssued = false
        try {
            controller.admittedNetworkLease()
            leaseIssued = true
        } catch (_: Exception) {
            // Expected fail-closed path: NOT_ADMITTED cannot mint a lease.
        }
        assertFalse("no cellular authority lease may be issued", leaseIssued)
    }

    private fun assertLeaseRevoked(lease: CellularNetworkLease, host: String) {
        var staleLeaseWorked = false
        try {
            lease.resolveHost(host)
            staleLeaseWorked = true
        } catch (_: Exception) {
            // Expected: owner generation changed before any platform DNS operation.
        }
        assertFalse("pre-loss cellular lease must be revoked", staleLeaseWorked)
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
        timeoutMillis: Long,
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
     * VPN-derived and IMS-only networks never satisfy this predicate.
     */
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

        val failures = mutableListOf<SafeProbeFailure>()
        for (numericAddress in numericAddresses) {
            try {
                return connectAndReadPublicIp(lease, numericAddress, host, port, path)
            } catch (failure: Throwable) {
                val safe = safeProbeFailure("unknown", failure)
                failures += safe
                emitSafeAttempt(safe)
            }
        }

        val stages = failures.map { it.stage }.toSet()
        val aggregateStage = when (stages.size) {
            0 -> "unknown"
            1 -> stages.first()
            else -> "mixed"
        }
        throw AssertionError("all lease-resolved addresses failed; E3_SAFE_FAILURE stage=$aggregateStage")
    }

    private fun connectAndReadPublicIp(
        lease: CellularNetworkLease,
        numericAddress: String,
        host: String,
        port: Int,
        path: String,
    ): String {
        val family = if (numericAddress.contains(':')) OsConstants.AF_INET6 else OsConstants.AF_INET
        val address = withSafeProbeStage("address_conversion") {
            Os.inet_pton(family, numericAddress)
                ?: throw AssertionError("numeric address conversion returned null")
        }

        val original = withSafeProbeStage("socket_create") {
            Os.socket(family, OsConstants.SOCK_STREAM, OsConstants.IPPROTO_TCP)
        }
        var duplicateFailure: SafeProbeFailure? = null
        val rawFd = try {
            withSafeProbeStage("fd_duplicate") {
                ParcelFileDescriptor.dup(original).use { duplicate -> duplicate.detachFd() }
            }
        } catch (failure: SafeProbeFailure) {
            duplicateFailure = failure
            throw failure
        } finally {
            try {
                Os.close(original)
            } catch (failure: Throwable) {
                if (duplicateFailure == null) {
                    throw safeProbeFailure("fd_cleanup", failure)
                }
            }
        }

        val socket = withSafeProbeStage("fd_adopt") { ParcelFileDescriptor.adoptFd(rawFd) }
        var primaryFailure: Throwable? = null
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                withSafeProbeStage("socket_option") {
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
            }

            withSafeProbeStage("socket_bind") { lease.bindSocket(rawFd) }
            withSafeProbeStage("connect") { Os.connect(socket.fileDescriptor, address, port) }

            val request = (
                "GET $path HTTP/1.1\r\n" +
                    "Host: $host\r\n" +
                    "Connection: close\r\n" +
                    "User-Agent: mobile-proxy-mish-e3\r\n\r\n"
                ).toByteArray(Charsets.US_ASCII)
            withSafeProbeStage("write") { writeAll(socket.fileDescriptor, request) }

            val response = withSafeProbeStage("read") { readBounded(socket.fileDescriptor) }
            val text = response.toString(Charsets.US_ASCII)
            withSafeProbeStage("http_status") {
                assertTrue(
                    "E3 echo endpoint must return HTTP 200",
                    text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200"),
                )
            }
            val separator = text.indexOf("\r\n\r\n")
            withSafeProbeStage("response_parse") {
                assertTrue("HTTP response must contain header/body separator", separator >= 0)
            }
            return text.substring(separator + 4).trim().lineSequence().firstOrNull().orEmpty().trim()
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            try {
                socket.close()
            } catch (failure: Throwable) {
                if (primaryFailure == null) {
                    throw safeProbeFailure("fd_cleanup", failure)
                }
            }
        }
    }

    private inline fun <T> withSafeProbeStage(stage: String, block: () -> T): T {
        try {
            return block()
        } catch (failure: Throwable) {
            throw safeProbeFailure(stage, failure)
        }
    }

    private fun safeProbeFailure(stage: String, failure: Throwable): SafeProbeFailure {
        if (failure is SafeProbeFailure) {
            return failure
        }
        return SafeProbeFailure(
            stage = stage,
            exceptionClass = failure.javaClass.name,
            errno = (failure as? ErrnoException)?.errno,
        )
    }

    private fun emitSafeAttempt(failure: SafeProbeFailure) {
        val errno = failure.errno?.toString() ?: "NONE"
        println(
            "E3_SAFE_ATTEMPT stage=${failure.stage} " +
                "class=${failure.exceptionClass} errno=$errno",
        )
    }

    private fun requirePublicIpLiteral(value: String) {
        if (!isIpLiteral(value)) {
            throw AssertionError("E3_SAFE_FAILURE stage=public_ip_parse")
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
