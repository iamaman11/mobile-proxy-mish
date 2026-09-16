package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.RootProcess
import com.mobileproxymish.app.cellular.SuProcess
import java.io.File

/**
 * One-shot upgrade boundary from the pre-L8 detached root sing-box runtime.
 *
 * This is deliberately not a process manager. It scans only long enough to remove legacy children
 * whose complete argv proves they were launched from this package's app-private runtime directory,
 * revalidates that exact argv immediately before every signal, publishes one app-private marker,
 * and never participates in native proxy steady state.
 */
internal class LegacySingBoxUpgradeMigration internal constructor(
    private val runtimeDir: File,
    private val marker: File,
    private val process: RootProcess,
) {
    constructor(context: Context) : this(
        runtimeDir = File(context.noBackupFilesDir, RUNTIME_DIR),
        marker = File(context.noBackupFilesDir, MIGRATION_MARKER),
        process = SuProcess(),
    )

    fun runOnce(): Boolean {
        if (markerIsCurrent()) return true

        val initial = scanOwnedLegacyCandidates() ?: return false
        if (initial.size > MAX_OWNED_CANDIDATES) return false
        for (candidate in initial) {
            if (!stopExactCandidate(candidate)) return false
        }

        // Never publish the migration marker from an old observation. A fresh root snapshot must
        // prove that every exact package-owned legacy child is gone after termination effects.
        val remaining = scanOwnedLegacyCandidates() ?: return false
        if (remaining.isNotEmpty()) return false

        return publishMarker()
    }

    private fun markerIsCurrent(): Boolean =
        marker.isFile && runCatching {
            marker.readText(Charsets.US_ASCII).trim() == MARKER_VALUE
        }.getOrDefault(false)

    /**
     * Returns only exact package-owned legacy processes. Foreign sing-box processes are ignored.
     * A malformed observation that nevertheless mentions this package's private runtime path is
     * ambiguous and therefore fails the migration instead of authorizing a kill.
     */
    private fun scanOwnedLegacyCandidates(): List<LegacyCandidate>? {
        val scan = process.run(listOf("su", "-c", SCAN_COMMAND))
        if (scan.timedOut || !scan.outputComplete || scan.exitCode != 0) return null

        val owned = mutableListOf<LegacyCandidate>()
        for (line in scan.stdout.lineSequence().filter(String::isNotBlank)) {
            val parsed = parseCandidate(line)
            if (parsed == null) {
                if (line.contains(runtimeDir.absolutePath + "/")) return null
                continue
            }
            val ownedSequence = exactOwnedSequence(parsed.argv)
            if (ownedSequence != null) {
                owned += parsed
                if (owned.size > MAX_OWNED_CANDIDATES) return null
            } else if (parsed.argv.any(::isOwnedConfigPath)) {
                return null
            }
        }
        return owned
    }

    private fun parseCandidate(line: String): LegacyCandidate? {
        val fields = line.trimEnd('\t').split('\t')
        if (fields.size < 2 || fields.size > MAX_OBSERVED_FIELDS) return null
        val pid = fields.first().toIntOrNull()?.takeIf { it > 0 } ?: return null
        val argv = fields.drop(1)
        if (argv.isEmpty() || argv.any { it.contains('\u0000') || it.contains('\n') || it.contains('\r') }) {
            return null
        }
        return LegacyCandidate(pid = pid, argv = argv)
    }

    /** Accept old launcher prefixes/suffixes but require one exact contiguous legacy launch shape. */
    private fun exactOwnedSequence(argv: List<String>): List<String>? {
        val matches = argv.windowed(EXACT_LAUNCH_ARGC).filter { window ->
            window[0].startsWith("/") &&
                window[0].endsWith("/$SING_BOX_LIBRARY") &&
                window[1] == "run" &&
                window[2] == "-c" &&
                isOwnedConfigPath(window[3])
        }
        return matches.singleOrNull()
    }

    private fun isOwnedConfigPath(path: String): Boolean {
        val config = File(path)
        if (config.parentFile?.absolutePath != runtimeDir.absolutePath) return false
        if (config.name == LEGACY_CONFIG_FILE) return true
        return GENERATION_CONFIG.matches(config.name)
    }

    private fun stopExactCandidate(candidate: LegacyCandidate): Boolean {
        // Linux /proc/<pid>/cmdline is the complete argv with one trailing NUL. The scan translated
        // NUL to TAB; the termination command compares the complete translated argv again before
        // TERM and again before KILL. PID reuse or argv change therefore becomes a no-op, never a
        // signal to a different process.
        val expected = candidate.argv.joinToString(separator = "\t", postfix = "\t")
        val command = buildString {
            append("set -eu; ")
            append("pid=").append(candidate.pid).append("; ")
            append("proc=/proc/\$pid; ")
            append("[ -d \"\$proc\" ] || exit 0; ")
            append("uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\" 2>/dev/null || true); ")
            append("[ \"\$uid\" = 0 ] || exit 21; ")
            append("actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\" 2>/dev/null || true); ")
            append("[ \"\$actual\" = ").append(shellQuote(expected)).append(" ] || exit 0; ")
            append("kill -TERM \"\$pid\" 2>/dev/null || [ ! -d \"\$proc\" ] || exit 23; ")
            append("i=0; while [ -d \"\$proc\" ] && [ \"\$i\" -lt 30 ]; do ")
            append("sleep 0.1; i=\$((i+1)); done; ")
            append("[ ! -d \"\$proc\" ] && exit 0; ")
            append("actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\" 2>/dev/null || true); ")
            append("[ \"\$actual\" = ").append(shellQuote(expected)).append(" ] || exit 0; ")
            append("kill -KILL \"\$pid\" 2>/dev/null || [ ! -d \"\$proc\" ] || exit 24; ")
            append("i=0; while [ -d \"\$proc\" ] && [ \"\$i\" -lt 20 ]; do ")
            append("sleep 0.1; i=\$((i+1)); done; ")
            append("[ ! -d \"\$proc\" ] || exit 25")
        }
        val result = process.run(listOf("su", "-c", command))
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    private fun publishMarker(): Boolean = runCatching {
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

    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    private data class LegacyCandidate(
        val pid: Int,
        val argv: List<String>,
    )

    private companion object {
        const val RUNTIME_DIR = "proxy-runtime"
        const val LEGACY_CONFIG_FILE = "sing-box.json"
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val MIGRATION_MARKER = "proxy-native-migration-v1"
        const val MARKER_VALUE = "native-proxy-v1"
        const val EXACT_LAUNCH_ARGC = 4
        const val MAX_OWNED_CANDIDATES = 8
        const val MAX_OBSERVED_FIELDS = 17
        val GENERATION_CONFIG = Regex("""sing-box-[A-Za-z0-9_-]{24}\.json""")

        // Read-only first pass. Kotlin performs the strict full-argv/config ownership check; every
        // stop effect revalidates root UID + complete argv immediately before signalling.
        const val SCAN_COMMAND =
            "set -eu; count=0; for proc in /proc/[0-9]*; do " +
                "[ -r \"\$proc/status\" ] || continue; " +
                "uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\" 2>/dev/null || true); " +
                "[ \"\$uid\" = 0 ] || continue; " +
                "[ -r \"\$proc/cmdline\" ] || continue; " +
                "actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\" 2>/dev/null || true); " +
                "case \"\$actual\" in *libsingbox.so*) " +
                "count=\$((count+1)); [ \"\$count\" -le 32 ] || exit 65; " +
                "printf '%s\\t%s\\n' \"\${proc##*/}\" \"\$actual\";; esac; done"
    }
}
