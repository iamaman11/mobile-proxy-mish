package com.mobileproxymish.app.cellular

import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mobileproxymish.app.MishApplication
import com.mobileproxymish.app.ProxyRuntimeSnapshot
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Read-only DEVICE-1 diagnostic used only to classify physical composition blockers.
 *
 * This test never mutates RPDB/iptables state and never becomes a readiness owner. It emits
 * only bounded booleans for the accepted PRODUCT candidate set; foreign rule bodies, route
 * tables, addresses and credentials are deliberately not printed.
 */
@RunWith(AndroidJUnit4::class)
class PhysicalCompositionDiagnosticTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun emitSanitizedCompositionFacts() {
        assertEquals(
            "diagnostic must execute inside the PRODUCT UID",
            context.applicationInfo.uid,
            Process.myUid(),
        )

        val application = context.applicationContext as? MishApplication
            ?: throw AssertionError("PHYSICAL_DIAGNOSTIC application_missing=true")

        emitProxyFacts(application)

        val identity = runProductRoot("id -u")
        if (!identity.ok || identity.stdout.trim() != "0") {
            println("PHYSICAL_DIAGNOSTIC root_observation=UNAVAILABLE")
            return
        }

        val ipv4Rules = runProductRoot("ip -4 rule show")
        val ipv6Rules = runProductRoot("ip -6 rule show")
        val ipv4Mangle = runProductRoot("iptables -t mangle -S")
        val ipv6Mangle = runProductRoot("ip6tables -t mangle -S")
        if (listOf(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle).any { !it.ok }) {
            println("PHYSICAL_DIAGNOSTIC policy_snapshot=UNAVAILABLE")
            return
        }

        val ipv4RuleLines = lines(ipv4Rules.stdout)
        val ipv6RuleLines = lines(ipv6Rules.stdout)
        val ipv4MangleLines = lines(ipv4Mangle.stdout)
        val ipv6MangleLines = lines(ipv6Mangle.stdout)
        val chainPresent = (ipv4MangleLines + ipv6MangleLines).any { it.contains(MISH_CHAIN) }

        CANDIDATES.forEachIndexed { index, candidate ->
            println(
                "PHYSICAL_POLICY_DIAGNOSTIC candidate=${index + 1} mark=${candidate.markHex} " +
                    "ipv4_priority_collision=${priorityCollision(ipv4RuleLines, candidate)} " +
                    "ipv6_priority_collision=${priorityCollision(ipv6RuleLines, candidate)} " +
                    "ipv4_rpdb_mark_collision=${rpdbMarkCollision(ipv4RuleLines, candidate)} " +
                    "ipv6_rpdb_mark_collision=${rpdbMarkCollision(ipv6RuleLines, candidate)} " +
                    "ipv4_mangle_mark_collision=${mangleMarkCollision(ipv4MangleLines, candidate)} " +
                    "ipv6_mangle_mark_collision=${mangleMarkCollision(ipv6MangleLines, candidate)} " +
                    "product_chain_present=$chainPresent",
            )
        }
    }

    private fun emitProxyFacts(application: MishApplication) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(PROXY_WAIT_SECONDS)
        var snapshot = application.proxyRuntime.snapshot.value
        while (snapshot == ProxyRuntimeSnapshot.Starting && System.nanoTime() < deadline) {
            Thread.sleep(100)
            snapshot = application.proxyRuntime.snapshot.value
        }

        val state = when (snapshot) {
            ProxyRuntimeSnapshot.Stopped -> "STOPPED"
            ProxyRuntimeSnapshot.Starting -> "STARTING"
            ProxyRuntimeSnapshot.Running -> "RUNNING"
            is ProxyRuntimeSnapshot.Failed -> "FAILED_${snapshot.reason.name}"
        }
        println("PHYSICAL_PROXY_DIAGNOSTIC runtime_state=$state")

        val sockets = runProductRoot("ss -ltnpe")
        if (!sockets.ok) {
            println("PHYSICAL_PROXY_DIAGNOSTIC listener_observation=UNAVAILABLE")
            return
        }

        val uid = Process.myUid().toString()
        val ownedLoopbackPorts = lines(sockets.stdout)
            .filter { it.contains("LISTEN") && it.contains("127.0.0.1:") && lineOwnedByUid(it, uid) }
            .mapNotNull(::extractLoopbackPort)
            .toSet()
        val publicPresent = PUBLIC_PORTS.all(ownedLoopbackPorts::contains)
        val privateCandidates = ownedLoopbackPorts - PUBLIC_PORTS
        println(
            "PHYSICAL_PROXY_DIAGNOSTIC public_loopback_present=$publicPresent " +
                "distinct_private_loopback_present=${privateCandidates.isNotEmpty()} " +
                "owned_loopback_listener_count=${ownedLoopbackPorts.size}",
        )
    }

    private fun priorityCollision(lines: List<String>, candidate: Candidate): Boolean =
        lines.any { line ->
            val priority = line.substringBefore(':').trim().toIntOrNull()
            (priority == candidate.lookupPriority || priority == candidate.guardPriority) &&
                !isExactOwnedRule(line, candidate)
        }

    private fun rpdbMarkCollision(lines: List<String>, candidate: Candidate): Boolean =
        lines.any { line ->
            !isExactOwnedRule(line, candidate) &&
                fwmarkSpec(line)?.let { specTouchesBit(it, candidate.markValue) } == true
        }

    private fun mangleMarkCollision(lines: List<String>, candidate: Candidate): Boolean =
        lines.any { line ->
            !line.contains(MISH_CHAIN) && lineTouchesBit(line, candidate.markValue)
        }

    private fun isExactOwnedRule(line: String, candidate: Candidate): Boolean {
        val trimmed = line.trim()
        val priority = trimmed.substringBefore(':').trim().toIntOrNull() ?: return false
        val expectedMark = "fwmark ${candidate.markHex}/${candidate.markHex}"
        return when (priority) {
            candidate.lookupPriority -> trimmed.contains(expectedMark) && trimmed.contains(" lookup ")
            candidate.guardPriority -> trimmed.contains(expectedMark) && trimmed.contains(" unreachable")
            else -> false
        }
    }

    private fun fwmarkSpec(line: String): String? {
        val tokens = line.trim().split(WHITESPACE)
        val index = tokens.indexOf("fwmark")
        return if (index >= 0) tokens.getOrNull(index + 1) else null
    }

    private fun lineTouchesBit(line: String, bit: ULong): Boolean {
        val tokens = line.trim().split(WHITESPACE)
        for (index in tokens.indices) {
            when (tokens[index]) {
                "--set-xmark", "--set-mark", "--mark" -> {
                    if (tokens.getOrNull(index + 1)?.let { specTouchesBit(it, bit) } == true) return true
                }
                "--nfmask", "--ctmask" -> {
                    val mask = parseUnsigned(tokens.getOrNull(index + 1)) ?: continue
                    if ((mask and bit) != 0UL) return true
                }
            }
        }
        return false
    }

    private fun specTouchesBit(spec: String, bit: ULong): Boolean {
        val parts = spec.split('/', limit = 2)
        if (parseUnsigned(parts[0]) == null) return false
        val mask = if (parts.size == 2) parseUnsigned(parts[1]) ?: return false else FULL_MASK
        return (mask and bit) != 0UL
    }

    private fun parseUnsigned(raw: String?): ULong? {
        if (raw == null) return null
        return if (raw.startsWith("0x", ignoreCase = true)) {
            raw.substring(2).toULongOrNull(16)
        } else {
            raw.toULongOrNull()
        }
    }

    private fun lineOwnedByUid(line: String, uid: String): Boolean =
        line.contains("uid:$uid") || line.contains("uid=$uid") || line.contains("uid $uid")

    private fun extractLoopbackPort(line: String): Int? {
        val match = LOOPBACK_PORT.find(line) ?: return null
        return match.groupValues[1].toIntOrNull()?.takeIf { it in 1..65535 }
    }

    private fun lines(raw: String): List<String> =
        raw.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()

    private fun runProductRoot(command: String): RootReadResult {
        val child = try {
            ProcessBuilder(listOf("su", "-c", command))
                .redirectErrorStream(true)
                .start()
        } catch (_: Exception) {
            return RootReadResult(false, "")
        }
        return try {
            if (!child.waitFor(ROOT_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                child.destroy()
                RootReadResult(false, "")
            } else {
                val stdout = child.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                RootReadResult(child.exitValue() == 0, stdout.take(MAX_ROOT_OUTPUT_CHARS))
            }
        } catch (_: Exception) {
            RootReadResult(false, "")
        } finally {
            child.destroy()
        }
    }

    private data class RootReadResult(val ok: Boolean, val stdout: String)

    private data class Candidate(
        val markHex: String,
        val markValue: ULong,
        val lookupPriority: Int,
        val guardPriority: Int,
    )

    private companion object {
        const val MISH_CHAIN = "MISH_EGRESS_V1"
        const val PROXY_WAIT_SECONDS = 10L
        const val ROOT_TIMEOUT_SECONDS = 5L
        const val MAX_ROOT_OUTPUT_CHARS = 64 * 1024
        const val FULL_MASK = 0xffffffffUL
        val PUBLIC_PORTS = setOf(1080, 1081, 3128)
        val WHITESPACE = Regex("""\s+""")
        val LOOPBACK_PORT = Regex("""127\.0\.0\.1:(\d+)""")
        val CANDIDATES = listOf(
            Candidate("0x200000", 0x200000UL, 9500, 9501),
            Candidate("0x400000", 0x400000UL, 9520, 9521),
            Candidate("0x800000", 0x800000UL, 9540, 9541),
            Candidate("0x1000000", 0x1000000UL, 9560, 9561),
        )
    }
}
