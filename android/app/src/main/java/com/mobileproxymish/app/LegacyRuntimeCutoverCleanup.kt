package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.RootProcess
import com.mobileproxymish.app.cellular.SuProcess
import java.io.File

internal enum class LegacyRuntimeCutoverState {
    NOT_ATTEMPTED,
    READY,
    BLOCKED,
}

internal enum class LegacyRuntimeCutoverFailure {
    INITIAL_SCAN_ROOT_TIMEOUT,
    INITIAL_SCAN_ROOT_OUTPUT_INCOMPLETE,
    INITIAL_SCAN_ROOT_COMMAND_FAILED,
    INITIAL_SCAN_AMBIGUOUS_OWNERSHIP,
    TOO_MANY_OWNED_CANDIDATES,
    STOP_ROOT_TIMEOUT,
    STOP_ROOT_OUTPUT_INCOMPLETE,
    STOP_ROOT_COMMAND_FAILED,
    RESCAN_ROOT_TIMEOUT,
    RESCAN_ROOT_OUTPUT_INCOMPLETE,
    RESCAN_ROOT_COMMAND_FAILED,
    RESCAN_AMBIGUOUS_OWNERSHIP,
    OWNED_CANDIDATE_REMAINS,
    MARKER_PUBLISH_FAILED,
}

/** Secret-free observation of the one-shot upgrade boundary; never a steady-state runtime owner. */
internal data class LegacyRuntimeCutoverDiagnosticObservation(
    val state: LegacyRuntimeCutoverState,
    val failure: LegacyRuntimeCutoverFailure? = null,
    val ownedCandidateCount: Int? = null,
    val rootExitCode: Int? = null,
)

/**
 * One-shot cutover cleanup from the pre-L8 detached root sing-box runtime.
 *
 * This is deliberately not a process manager and is never part of steady-state Proxy Serving. It
 * scans only long enough to remove legacy children whose complete argv proves they were launched
 * from this package's app-private runtime directory, revalidates that exact argv immediately before
 * every signal, publishes one app-private completion marker, and then becomes a no-op forever.
 */
internal class LegacyRuntimeCutoverCleanup internal constructor(
    private val runtimeDir: File,
    private val marker: File,
    private val process: RootProcess,
) {
    constructor(context: Context) : this(
        runtimeDir = File(context.noBackupFilesDir, RUNTIME_DIR),
        marker = File(context.noBackupFilesDir, CUTOVER_MARKER),
        process = SuProcess(),
    )

    @Volatile
    private var observation = LegacyRuntimeCutoverDiagnosticObservation(
        state = LegacyRuntimeCutoverState.NOT_ATTEMPTED,
    )

    fun diagnosticObservation(): LegacyRuntimeCutoverDiagnosticObservation = observation

    fun ensureLegacyRuntimeAbsent(): Boolean {
        if (markerIsCurrent()) {
            observation = LegacyRuntimeCutoverDiagnosticObservation(
                state = LegacyRuntimeCutoverState.READY,
                ownedCandidateCount = 0,
            )
            return true
        }

        val initial = scanOwnedLegacyCandidates(ScanPhase.INITIAL)
        if (initial.failure != null) {
            return block(
                failure = initial.failure,
                ownedCandidateCount = initial.candidates?.size,
                rootExitCode = initial.rootExitCode,
            )
        }
        val initialCandidates = checkNotNull(initial.candidates)
        if (initialCandidates.size > MAX_OWNED_CANDIDATES) {
            return block(
                failure = LegacyRuntimeCutoverFailure.TOO_MANY_OWNED_CANDIDATES,
                ownedCandidateCount = initialCandidates.size,
            )
        }
        for (candidate in initialCandidates) {
            val stopped = stopExactCandidate(candidate)
            if (stopped != null) {
                return block(
                    failure = stopped.failure,
                    ownedCandidateCount = initialCandidates.size,
                    rootExitCode = stopped.rootExitCode,
                )
            }
        }

        // Never publish completion from an old observation. A fresh root snapshot must prove that
        // every exact package-owned legacy child is gone after termination effects.
        val remaining = scanOwnedLegacyCandidates(ScanPhase.RESCAN)
        if (remaining.failure != null) {
            return block(
                failure = remaining.failure,
                ownedCandidateCount = remaining.candidates?.size,
                rootExitCode = remaining.rootExitCode,
            )
        }
        val remainingCandidates = checkNotNull(remaining.candidates)
        if (remainingCandidates.isNotEmpty()) {
            return block(
                failure = LegacyRuntimeCutoverFailure.OWNED_CANDIDATE_REMAINS,
                ownedCandidateCount = remainingCandidates.size,
            )
        }

        if (!publishMarker()) {
            return block(
                failure = LegacyRuntimeCutoverFailure.MARKER_PUBLISH_FAILED,
                ownedCandidateCount = initialCandidates.size,
            )
        }
        observation = LegacyRuntimeCutoverDiagnosticObservation(
            state = LegacyRuntimeCutoverState.READY,
            ownedCandidateCount = initialCandidates.size,
        )
        return true
    }

    private fun block(
        failure: LegacyRuntimeCutoverFailure,
        ownedCandidateCount: Int? = null,
        rootExitCode: Int? = null,
    ): Boolean {
        observation = LegacyRuntimeCutoverDiagnosticObservation(
            state = LegacyRuntimeCutoverState.BLOCKED,
            failure = failure,
            ownedCandidateCount = ownedCandidateCount,
            rootExitCode = rootExitCode,
        )
        return false
    }

    private fun markerIsCurrent(): Boolean =
        marker.isFile && runCatching {
            marker.readText(Charsets.US_ASCII).trim() == MARKER_VALUE
        }.getOrDefault(false)

    /**
     * Returns only exact package-owned legacy processes. Foreign sing-box processes are ignored.
     * A malformed observation that nevertheless mentions this package's private runtime path is
     * ambiguous and therefore blocks cutover instead of authorizing a kill.
     */
    private fun scanOwnedLegacyCandidates(phase: ScanPhase): ScanOutcome {
        val scan = process.run(listOf("su", "-c", SCAN_COMMAND))
        if (scan.timedOut) {
            return ScanOutcome(failure = phase.timeoutFailure, rootExitCode = scan.exitCode)
        }
        if (!scan.outputComplete) {
            return ScanOutcome(failure = phase.incompleteFailure, rootExitCode = scan.exitCode)
        }
        if (scan.exitCode != 0) {
            return ScanOutcome(failure = phase.commandFailure, rootExitCode = scan.exitCode)
        }

        val owned = mutableListOf<LegacyCandidate>()
        for (line in scan.stdout.lineSequence().filter(String::isNotBlank)) {
            val parsed = parseCandidate(line)
            if (parsed == null) {
                if (line.contains(runtimeDir.absolutePath + "/")) {
                    return ScanOutcome(
                        candidates = owned.toList(),
                        failure = phase.ambiguousFailure,
                    )
                }
                continue
            }
            val ownedSequence = exactOwnedSequence(parsed.argv)
            if (ownedSequence != null) {
                owned += parsed
                if (owned.size > MAX_OWNED_CANDIDATES) {
                    return ScanOutcome(
                        candidates = owned.toList(),
                        failure = LegacyRuntimeCutoverFailure.TOO_MANY_OWNED_CANDIDATES,
                    )
                }
            } else if (parsed.argv.any(::isOwnedConfigPath)) {
                return ScanOutcome(
                    candidates = owned.toList(),
                    failure = phase.ambiguousFailure,
                )
            }
        }
        return ScanOutcome(candidates = owned.toList())
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

    private fun stopExactCandidate(candidate: LegacyCandidate): StopFailure? {
        // Linux /proc/<pid>/cmdline is complete argv with one trailing NUL. The scan translates NUL
        // to TAB; the stop command compares the complete translated argv again before TERM and KILL.
        // PID reuse, UID change or argv change therefore becomes a no-op, never a signal to a
        // replacement PID.
        val expected = candidate.argv.joinToString(separator = "\t", postfix = "\t")
        val command = buildString {
            append("set -eu; ")
            append("pid=").append(candidate.pid).append("; ")
            append("proc=/proc/\$pid; ")
            append("[ -d \"\$proc\" ] || exit 0; ")
            append("uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\" 2>/dev/null || true); ")
            append("[ \"\$uid\" = 0 ] || exit 0; ")
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
        return when {
            result.timedOut -> StopFailure(
                failure = LegacyRuntimeCutoverFailure.STOP_ROOT_TIMEOUT,
                rootExitCode = result.exitCode,
            )
            !result.outputComplete -> StopFailure(
                failure = LegacyRuntimeCutoverFailure.STOP_ROOT_OUTPUT_INCOMPLETE,
                rootExitCode = result.exitCode,
            )
            result.exitCode != 0 -> StopFailure(
                failure = LegacyRuntimeCutoverFailure.STOP_ROOT_COMMAND_FAILED,
                rootExitCode = result.exitCode,
            )
            else -> null
        }
    }

    private fun publishMarker(): Boolean = runCatching {
        val parent = checkNotNull(marker.parentFile)
        parent.mkdirs()
        val temporary = File(parent, "${marker.name}.tmp")
        temporary.writeText("$MARKER_VALUE\n", Charsets.US_ASCII)
        if (marker.exists() && !marker.delete()) error("cannot replace cutover marker")
        if (!temporary.renameTo(marker)) {
            temporary.delete()
            error("cannot publish cutover marker")
        }
        true
    }.getOrDefault(false)

    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    private data class LegacyCandidate(
        val pid: Int,
        val argv: List<String>,
    )

    private data class ScanOutcome(
        val candidates: List<LegacyCandidate>? = null,
        val failure: LegacyRuntimeCutoverFailure? = null,
        val rootExitCode: Int? = null,
    )

    private data class StopFailure(
        val failure: LegacyRuntimeCutoverFailure,
        val rootExitCode: Int? = null,
    )

    private enum class ScanPhase(
        val timeoutFailure: LegacyRuntimeCutoverFailure,
        val incompleteFailure: LegacyRuntimeCutoverFailure,
        val commandFailure: LegacyRuntimeCutoverFailure,
        val ambiguousFailure: LegacyRuntimeCutoverFailure,
    ) {
        INITIAL(
            timeoutFailure = LegacyRuntimeCutoverFailure.INITIAL_SCAN_ROOT_TIMEOUT,
            incompleteFailure = LegacyRuntimeCutoverFailure.INITIAL_SCAN_ROOT_OUTPUT_INCOMPLETE,
            commandFailure = LegacyRuntimeCutoverFailure.INITIAL_SCAN_ROOT_COMMAND_FAILED,
            ambiguousFailure = LegacyRuntimeCutoverFailure.INITIAL_SCAN_AMBIGUOUS_OWNERSHIP,
        ),
        RESCAN(
            timeoutFailure = LegacyRuntimeCutoverFailure.RESCAN_ROOT_TIMEOUT,
            incompleteFailure = LegacyRuntimeCutoverFailure.RESCAN_ROOT_OUTPUT_INCOMPLETE,
            commandFailure = LegacyRuntimeCutoverFailure.RESCAN_ROOT_COMMAND_FAILED,
            ambiguousFailure = LegacyRuntimeCutoverFailure.RESCAN_AMBIGUOUS_OWNERSHIP,
        ),
    }

    private companion object {
        const val RUNTIME_DIR = "proxy-runtime"
        const val LEGACY_CONFIG_FILE = "sing-box.json"
        const val SING_BOX_LIBRARY = "libsingbox.so"
        // Persist the original marker filename for already-upgraded installations; its semantics are
        // one-way L8 cutover completion, not a live migration subsystem.
        const val CUTOVER_MARKER = "proxy-native-migration-v1"
        const val MARKER_VALUE = "native-proxy-v1"
        const val EXACT_LAUNCH_ARGC = 4
        const val MAX_OWNED_CANDIDATES = 8
        const val MAX_OBSERVED_FIELDS = 17
        val GENERATION_CONFIG = Regex("""sing-box-[A-Za-z0-9_-]{24}\.json""")

        // Read-only first pass. Use one bounded process-table shortlist so the shared root transport
        // does not fork one status parser per Android process. Complete argv + root UID are still
        // read from /proc for each shortlisted PID, and every stop effect revalidates both again.
        const val SCAN_COMMAND =
            "set -eu; count=0; " +
                "candidate_pids=\$(ps -A 2>/dev/null | " +
                "awk 'NR > 1 && (\$0 ~ /libsingbox[.]so/ || \$0 ~ /sing-box/) { " +
                "if (\$2 ~ /^[0-9]+\$/) print \$2 }'); " +
                "for pid in \$candidate_pids; do " +
                "proc=/proc/\$pid; " +
                "[ -r \"\$proc/status\" ] || continue; " +
                "[ -r \"\$proc/cmdline\" ] || continue; " +
                "uid=\$(awk '/^Uid:/{print \$2; exit}' \"\$proc/status\" 2>/dev/null || true); " +
                "[ \"\$uid\" = 0 ] || continue; " +
                "actual=\$(tr '\\000' '\\t' < \"\$proc/cmdline\" 2>/dev/null || true); " +
                "case \"\$actual\" in *libsingbox.so*) " +
                "count=\$((count+1)); [ \"\$count\" -le 32 ] || exit 65; " +
                "printf '%s\\t%s\\n' \"\$pid\" \"\$actual\";; esac; done"
    }
}
