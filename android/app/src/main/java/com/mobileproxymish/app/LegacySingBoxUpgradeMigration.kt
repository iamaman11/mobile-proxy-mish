package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.SuProcess
import java.io.File

/**
 * One-shot upgrade boundary from the pre-L7 detached root sing-box runtime.
 *
 * It is deliberately not a process manager: after one successful exact-identity scan/cleanup an
 * app-private marker prevents any future /proc reconciliation. Unknown or ambiguous root processes
 * are never killed.
 */
internal class LegacySingBoxUpgradeMigration(
    context: Context,
) {
    private val runtimeDir = File(context.noBackupFilesDir, RUNTIME_DIR)
    private val marker = File(context.noBackupFilesDir, MIGRATION_MARKER)

    fun runOnce(): Boolean {
        if (marker.isFile && runCatching { marker.readText(Charsets.US_ASCII).trim() }.getOrNull() == MARKER_VALUE) {
            return true
        }

        val scan = SuProcess().run(listOf("su", "-c", SCAN_COMMAND))
        if (scan.timedOut || !scan.outputComplete || scan.exitCode != 0) return false
        val candidates = scan.stdout
            .lineSequence()
            .mapNotNull(::parseCandidate)
            .filter(::isOwnedLegacyCandidate)
            .toList()
        if (candidates.size > 1) return false

        val stopped = candidates.singleOrNull()?.let(::stopExactCandidate) ?: true
        if (!stopped) return false

        return runCatching {
            val parent = checkNotNull(marker.parentFile)
            parent.mkdirs()
            val temporary = File(parent, "${marker.name}.tmp")
            temporary.writeText("$MARKER_VALUE\n", Charsets.US_ASCII)
            if (marker.exists() && !marker.delete()) error("cannot replace migration marker")
            if (!temporary.renameTo(marker)) {
                temporary.delete()
                error("cannot publish migration marker")
            }
            true
        }.getOrDefault(false)
    }

    private fun parseCandidate(line: String): LegacyCandidate? {
        val fields = line.trimEnd('\t').split('\t')
        if (fields.size != 5) return null
        val pid = fields[0].toIntOrNull()?.takeIf { it > 0 } ?: return null
        return LegacyCandidate(
            pid = pid,
            binary = fields[1],
            action = fields[2],
            configFlag = fields[3],
            config = fields[4],
        )
    }

    private fun isOwnedLegacyCandidate(candidate: LegacyCandidate): Boolean {
        if (!candidate.binary.startsWith("/") || !candidate.binary.endsWith("/$SING_BOX_LIBRARY")) {
            return false
        }
        if (candidate.action != "run" || candidate.configFlag != "-c") return false

        val config = File(candidate.config)
        if (config.parentFile?.absolutePath != runtimeDir.absolutePath) return false
        if (config.name == LEGACY_CONFIG_FILE) return true
        return GENERATION_CONFIG.matches(config.name)
    }

    private fun stopExactCandidate(candidate: LegacyCandidate): Boolean {
        val expected = listOf(
            candidate.binary,
            candidate.action,
            candidate.configFlag,
            candidate.config,
        ).joinToString(separator = "\t", postfix = "\t")
        val command = buildString {
            append("set -eu; ")
            append("pid=").append(candidate.pid).append("; ")
            append("proc=/proc/\$pid; ")
            append("[ -r \"\$proc/status\" ] || exit 20; ")
            append("uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\"); ")
            append("[ \"\$uid\" = 0 ] || exit 21; ")
            append("actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\"); ")
            append("[ \"\$actual\" = ").append(shellQuote(expected)).append(" ] || exit 22; ")
            append("kill -TERM \"\$pid\" || exit 23; ")
            append("i=0; while [ -d \"\$proc\" ] && [ \"\$i\" -lt 40 ]; do ")
            append("sleep 0.1; i=\$((i+1)); done; ")
            append("[ ! -d \"\$proc\" ] || exit 24")
        }
        val result = SuProcess().run(listOf("su", "-c", command))
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    private data class LegacyCandidate(
        val pid: Int,
        val binary: String,
        val action: String,
        val configFlag: String,
        val config: String,
    )

    private companion object {
        const val RUNTIME_DIR = "proxy-runtime"
        const val LEGACY_CONFIG_FILE = "sing-box.json"
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val MIGRATION_MARKER = "proxy-native-migration-v1"
        const val MARKER_VALUE = "native-proxy-v1"
        val GENERATION_CONFIG = Regex("""sing-box-[A-Za-z0-9_-]{24}\.json""")

        // Read-only first pass. Kotlin performs the strict argv/config ownership check; the stop
        // command revalidates the exact root UID and complete argv immediately before SIGTERM.
        const val SCAN_COMMAND =
            "set -eu; for proc in /proc/[0-9]*; do " +
                "[ -r \"\$proc/status\" ] || continue; " +
                "uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\" 2>/dev/null || true); " +
                "[ \"\$uid\" = 0 ] || continue; " +
                "[ -r \"\$proc/cmdline\" ] || continue; " +
                "actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\" 2>/dev/null || true); " +
                "case \"\$actual\" in *libsingbox.so*) " +
                "printf '%s\\t%s\\n' \"\${proc##*/}\" \"\$actual\";; esac; done"
    }
}
