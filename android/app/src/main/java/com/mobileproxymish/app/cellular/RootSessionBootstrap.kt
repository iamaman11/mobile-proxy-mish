package com.mobileproxymish.app.cellular

import android.os.Process
import com.mobileproxymish.app.BuildConfig

/**
 * One-time process-generation bootstrap performed only after root authority has been proven.
 *
 * Android may assign a new UID after an intentional clean uninstall/reinstall. An exact PRODUCT
 * OUTPUT jump from the previous UID can survive in kernel policy and would otherwise make the new
 * process fail closed forever. Self-heal is intentionally narrower than normal policy reconcile:
 * it removes an old UID jump only when the complete named MISH chain is byte-for-byte one of the
 * known PRODUCT contracts and every reference to that chain has the exact owner-jump shape.
 * Unknown, partial or malformed state is left untouched for CellularRootPolicy's fail-closed
 * collision audit.
 */
internal fun interface RootSessionBootstrap {
    fun reconcile(transport: RootCommandTransport): Boolean

    data object None : RootSessionBootstrap {
        override fun reconcile(transport: RootCommandTransport): Boolean = true
    }

    companion object {
        fun currentProcess(): RootSessionBootstrap = MishRootSessionBootstrap(
            productUid = Process.myUid(),
            mishChain = if (BuildConfig.APPLICATION_ID.endsWith(".debug")) {
                "MISH_DEBUG_EGRESS_V1"
            } else {
                "MISH_EGRESS_V1"
            },
        )
    }
}

internal class MishRootSessionBootstrap(
    private val productUid: Int,
    private val mishChain: String,
) : RootSessionBootstrap {
    private val exactOwnerJump = Regex(
        """^-A OUTPUT -m owner --uid-owner ([1-9][0-9]*) -j ${Regex.escape(mishChain)}$""",
    )

    override fun reconcile(transport: RootCommandTransport): Boolean =
        reconcileFamily(transport, "iptables", ipv4 = true) &&
            reconcileFamily(transport, "ip6tables", ipv4 = false)

    private fun reconcileFamily(
        transport: RootCommandTransport,
        binary: String,
        ipv4: Boolean,
    ): Boolean {
        val before = readMangle(transport, binary) ?: return false
        val staleUids = before
            .mapNotNull { line -> exactOwnerJump.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull() }
            .filter { it != productUid }
            .distinct()

        if (staleUids.isEmpty()) return true

        // A stale UID by itself is not enough authority to mutate kernel state. Prove first that
        // the complete chain is one of our exact contracts and that no unknown reference points
        // at it. Otherwise leave the snapshot untouched so normal collision handling fails closed.
        if (!isExactKnownProductState(before, ipv4)) return true

        for (staleUid in staleUids) {
            val delete = transport.execute(
                RootMutation(
                    "$binary -t mangle -D OUTPUT -m owner --uid-owner $staleUid -j $mishChain",
                ),
            )
            if (delete.timedOut || !delete.outputComplete || delete.exitCode != 0) {
                return false
            }
        }

        val after = readMangle(transport, binary) ?: return false
        return after.none { line ->
            val uid = exactOwnerJump.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull()
            uid != null && uid != productUid
        }
    }

    private fun isExactKnownProductState(lines: List<String>, ipv4: Boolean): Boolean {
        if (lines.count { it == "-N $mishChain" } != 1) return false

        val actualChain = lines.filter { it.startsWith("-A $mishChain ") }
        val matchingMarks = knownMarks().filter { mark ->
            actualChain == expectedChain(mark, ipv4)
        }
        if (matchingMarks.size != 1) return false

        val expectedChainLines = actualChain.toSet()
        return lines
            .filter { it.contains(mishChain) }
            .all { line ->
                line == "-N $mishChain" ||
                    line in expectedChainLines ||
                    exactOwnerJump.matches(line)
            }
    }

    private fun expectedChain(mark: String, ipv4: Boolean): List<String> {
        val loopback = if (ipv4) "127.0.0.0/8" else "::1/128"
        return listOf(
            "-A $mishChain -d $loopback -j RETURN",
            "-A $mishChain -j CONNMARK --restore-mark --nfmask $mark --ctmask $mark",
            "-A $mishChain -m conntrack --ctstate NEW -j MARK --set-xmark $mark/$mark",
            "-A $mishChain -m conntrack --ctstate NEW -m mark --mark $mark/$mark " +
                "-j CONNMARK --save-mark --nfmask $mark --ctmask $mark",
        )
    }

    private fun knownMarks(): List<String> = when (mishChain) {
        "MISH_DEBUG_EGRESS_V1" -> listOf(
            "0x2000000",
            "0x4000000",
            "0x8000000",
            "0x10000000",
        )

        "MISH_EGRESS_V1" -> listOf(
            "0x200000",
            "0x400000",
            "0x800000",
            "0x1000000",
        )

        else -> emptyList()
    }

    private fun readMangle(transport: RootCommandTransport, binary: String): List<String>? {
        val result = transport.execute(RootObservation("$binary -t mangle -S"))
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

}
