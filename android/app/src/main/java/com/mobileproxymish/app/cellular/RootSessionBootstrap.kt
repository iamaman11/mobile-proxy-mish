package com.mobileproxymish.app.cellular

import android.os.Process
import com.mobileproxymish.app.BuildConfig

/**
 * One-time process-generation bootstrap performed only after root authority has been proven.
 *
 * Android may assign a new UID after an intentional clean uninstall/reinstall. Exact PRODUCT
 * OUTPUT jumps from the previous UID can survive in kernel policy and would otherwise make the
 * new process fail closed forever. The PRODUCT owns its named MISH chain references, so an exact
 * stale owner jump to the chain is safe to remove. Everything else remains untouched and is left
 * for CellularRootPolicy's normal fail-closed collision audit.
 */
internal fun interface RootSessionBootstrap {
    fun reconcile(process: RootProcess): Boolean

    data object None : RootSessionBootstrap {
        override fun reconcile(process: RootProcess): Boolean = true
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

    override fun reconcile(process: RootProcess): Boolean =
        reconcileFamily(process, "iptables") && reconcileFamily(process, "ip6tables")

    private fun reconcileFamily(process: RootProcess, binary: String): Boolean {
        val before = readOutput(process, binary) ?: return false
        val staleUids = before
            .mapNotNull { line -> exactOwnerJump.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull() }
            .filter { it != productUid }
            .distinct()

        for (staleUid in staleUids) {
            val delete = runRoot(
                process,
                "$binary -t mangle -D OUTPUT -m owner --uid-owner $staleUid -j $mishChain",
            )
            if (
                delete.timedOut ||
                !delete.outputComplete ||
                delete.exitCode != 0
            ) {
                return false
            }
        }

        val after = readOutput(process, binary) ?: return false
        return after.none { line ->
            val uid = exactOwnerJump.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull()
            uid != null && uid != productUid
        }
    }

    private fun readOutput(process: RootProcess, binary: String): List<String>? {
        val result = runRoot(process, "$binary -t mangle -S OUTPUT")
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

    private fun runRoot(process: RootProcess, command: String): RootProcessResult =
        process.run(listOf("su", "-c", command))
}
