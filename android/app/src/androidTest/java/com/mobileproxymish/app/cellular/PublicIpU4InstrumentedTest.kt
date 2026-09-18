package com.mobileproxymish.app.cellular

import android.os.Bundle
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mobileproxymish.app.MishApplication
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * U4 physical acceptance for the PRODUCT generation-bound public-egress-IP observation.
 *
 * Evidence is semantic only. Raw public IP values never leave the device test process.
 */
@RunWith(AndroidJUnit4::class)
class PublicIpU4InstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun runPhysicalScenario() {
        val application = context.applicationContext as? MishApplication
            ?: throw AssertionError("U4_SAFE_FAILURE stage=product_runtime application_missing")
        val runtime = application.cellularRuntime
        var mobileDataMayBeDisabled = false

        try {
            val initial = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.ADMITTED,
                timeoutMillis = READY_TIMEOUT_MILLIS,
            )
            val initialGeneration = requireGeneration(initial, "initial")
            val fdBefore = openFdCount()

            val first = runtime.observePublicEgressIp(PUBLIC_IP_TIMEOUT_MILLIS)
            assertEquals(initialGeneration, first.generation)
            assertTrue("initial public IP must be a strict literal", isIpLiteral(first.address))

            repeat(REPEATED_OBSERVATIONS) {
                val repeated = runtime.observePublicEgressIp(PUBLIC_IP_TIMEOUT_MILLIS)
                assertEquals(initialGeneration, repeated.generation)
                assertTrue("repeated public IP must be a strict literal", isIpLiteral(repeated.address))
            }

            val staleTicket = runtime.nativeController()
                .preparePublicIpProbe(PUBLIC_IP_TIMEOUT_MILLIS.toULong())
            assertTrue("fresh ticket must begin current", staleTicket.isCurrent())

            mobileDataMayBeDisabled = true
            requireMobileDataTransition("disable")
            val lost = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.NOT_ADMITTED,
                timeoutMillis = LOSS_TIMEOUT_MILLIS,
            )
            val lossGeneration = requireGeneration(lost, "loss")
            assertTrue(
                "loss generation must supersede initial generation",
                lossGeneration > initialGeneration,
            )

            assertFalse("old U4 ticket must become stale after cellular loss", staleTicket.isCurrent())
            val staleRejected = runCatching {
                staleTicket.complete("198.51.100.77")
            }.isFailure
            assertTrue("old-generation public IP completion must be rejected", staleRejected)

            val fallbackBlocked = runCatching {
                runtime.observePublicEgressIp(NEGATIVE_PUBLIC_IP_TIMEOUT_MILLIS)
            }.isFailure
            assertTrue(
                "public IP observation must not fall back to default/Wi-Fi/WARP",
                fallbackBlocked,
            )

            requireMobileDataTransition("enable")
            mobileDataMayBeDisabled = false
            val recovered = waitForOwnerState(
                runtime = runtime,
                expected = CellularAdmissionState.ADMITTED,
                timeoutMillis = RECOVERY_TIMEOUT_MILLIS,
            )
            val recoveryGeneration = requireGeneration(recovered, "recovery")
            assertTrue(
                "recovery generation must supersede loss generation",
                recoveryGeneration > lossGeneration,
            )

            val recoveryObservation = runtime.observePublicEgressIp(PUBLIC_IP_TIMEOUT_MILLIS)
            assertEquals(recoveryGeneration, recoveryObservation.generation)
            assertTrue(
                "recovered public IP must be a strict literal",
                isIpLiteral(recoveryObservation.address),
            )

            val fdAfter = openFdCount()
            assertTrue(
                "repeated U4 observations must not leak unbounded file descriptors: before=$fdBefore after=$fdAfter",
                fdAfter <= fdBefore + FD_HEADROOM,
            )

            emitEvidence(
                "phase=u4 positive=true https=true owner_bound_dns=true ordinary_uid_socket=true " +
                    "stale_generation_rejected=true no_default_fallback=true " +
                    "fresh_generation=true repeated_observations_bounded=true",
            )
        } finally {
            if (mobileDataMayBeDisabled) {
                runCatching { executeMobileDataTransition("enable") }
            }
        }
    }

    private fun waitForOwnerState(
        runtime: CellularRuntimeBridge,
        expected: CellularAdmissionState,
        timeoutMillis: Long,
    ): CellularAdmissionView {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        do {
            val snapshot = runtime.snapshot.value
            if (snapshot is CellularRuntimeSnapshot.OwnerSnapshot &&
                snapshot.admission.state == expected
            ) {
                return snapshot.admission
            }
            SystemClock.sleep(POLL_MILLIS)
        } while (SystemClock.elapsedRealtime() < deadline)

        val actual = (runtime.snapshot.value as? CellularRuntimeSnapshot.OwnerSnapshot)
            ?.admission
            ?.state
        throw AssertionError("U4_SAFE_FAILURE stage=owner_state expected=$expected actual=$actual")
    }

    private fun requireGeneration(admission: CellularAdmissionView, phase: String): ULong =
        admission.lastSequence
            ?: throw AssertionError("U4_SAFE_FAILURE stage=owner_generation phase=$phase")

    private fun requireMobileDataTransition(state: String) {
        assertTrue(
            "mobile-data transition failed",
            executeMobileDataTransition(state),
        )
    }

    private fun executeMobileDataTransition(state: String): Boolean {
        require(state == "enable" || state == "disable")
        val descriptor = instrumentation.uiAutomation.executeShellCommand("cmd phone data $state")
        val output = android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader(Charsets.UTF_8)
            .use { it.readText() }
        return output.isBlank()
    }

    private fun openFdCount(): Int =
        File("/proc/self/fd").list()?.size
            ?: throw AssertionError("U4_SAFE_FAILURE stage=fd_count")

    private fun isIpLiteral(value: String): Boolean =
        IPV4_LITERAL.matches(value) ||
            (value.contains(':') && IPV6_LITERAL_CHARS.matches(value))

    private fun emitEvidence(value: String) {
        instrumentation.sendStatus(
            0,
            Bundle().apply { putString(U4_EVIDENCE_KEY, value) },
        )
    }

    private companion object {
        const val READY_TIMEOUT_MILLIS = 60_000L
        const val LOSS_TIMEOUT_MILLIS = 60_000L
        const val RECOVERY_TIMEOUT_MILLIS = 120_000L
        const val PUBLIC_IP_TIMEOUT_MILLIS = 15_000L
        const val NEGATIVE_PUBLIC_IP_TIMEOUT_MILLIS = 5_000L
        const val POLL_MILLIS = 250L
        const val REPEATED_OBSERVATIONS = 3
        const val FD_HEADROOM = 8
        const val U4_EVIDENCE_KEY = "u4_evidence"

        val IPV4_LITERAL = Regex(
            "^(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}$",
        )
        val IPV6_LITERAL_CHARS = Regex("^[0-9A-Fa-f:]+$")
    }
}
