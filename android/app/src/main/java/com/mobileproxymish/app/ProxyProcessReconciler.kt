package com.mobileproxymish.app

import android.system.Os
import com.mobileproxymish.app.cellular.SuProcess
import com.mobileproxymish.ffi.RuntimeProcessCleanupDecision
import com.mobileproxymish.ffi.RuntimeProcessObservationView
import com.mobileproxymish.ffi.RuntimeProcessTerminationTargetView
import com.mobileproxymish.ffi.planRuntimeProcessCleanup
import java.io.File

/**
 * Android effect adapter for the Rust process-reconciliation natural owner.
 *
 * Root only observes bounded PID/argv snapshots and executes Rust-authorized PID+digest targets.
 * Ownership classification never lives in shell/Kotlin. Every termination is followed by a fresh
 * observation and Rust plan before cleanup can be accepted.
 */
internal class ProxyProcessReconciler(
    private val runtimeDir: File,
) {
    private val observationScript = File(runtimeDir, OBSERVATION_SCRIPT_FILE)
    private val terminationScript = File(runtimeDir, TERMINATION_SCRIPT_FILE)

    fun cleanupOwnedProcesses(): Boolean {
        repeat(MAX_RECONCILIATION_PASSES) {
            val observations = observeCandidates() ?: return false
            val plan = runCatching {
                planRuntimeProcessCleanup(runtimeDir.absolutePath, observations)
            }.getOrNull() ?: return false

            when (plan.decision) {
                RuntimeProcessCleanupDecision.CLEAN -> return true
                RuntimeProcessCleanupDecision.FAIL_CLOSED -> return false
                RuntimeProcessCleanupDecision.TERMINATE_OWNED -> {
                    if (plan.terminate.isEmpty() || plan.terminate.size > MAX_CANDIDATES) return false
                    if (!terminateAuthorized(plan.terminate)) return false
                }
            }
        }

        // Bounded passes exhausted. One final owner decision may accept only an actually clean
        // snapshot; a further termination request is fail-closed rather than an unbounded loop.
        val finalObservations = observeCandidates() ?: return false
        val finalPlan = runCatching {
            planRuntimeProcessCleanup(runtimeDir.absolutePath, finalObservations)
        }.getOrNull() ?: return false
        return finalPlan.decision == RuntimeProcessCleanupDecision.CLEAN
    }

    private fun observeCandidates(): List<RuntimeProcessObservationView>? {
        if (!writeObservationScript()) return null
        val result = try {
            SuProcess().run(listOf(MAGISK_SU, "-c", observationScript.absolutePath))
        } finally {
            deleteIfPresent(observationScript)
        }
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null

        val observations = mutableListOf<RuntimeProcessObservationView>()
        for (line in result.stdout.lineSequence().filter(String::isNotBlank)) {
            val parts = line.split('\t')
            if (parts.size < OBSERVATION_PREFIX_FIELDS) return null
            if (observations.size >= MAX_CANDIDATES) return null

            val pid = parts[0].toULongOrNull()?.takeIf { it > 0uL } ?: return null
            val digest = parts[1]
            val truncated = parseFlag(parts[2]) ?: return null
            val unsafeArgv = parseFlag(parts[3]) ?: return null
            val argv = parts.drop(OBSERVATION_PREFIX_FIELDS)
            if (argv.size > MAX_OBSERVED_ARGV) return null
            if (argv.any { it.length > MAX_ARG_CHARS || !SAFE_ARG.matches(it) }) return null

            observations += RuntimeProcessObservationView(
                pid = pid,
                argv = argv,
                cmdlineDigest = digest,
                truncated = truncated,
                unsafeArgv = unsafeArgv,
            )
        }
        return observations
    }

    private fun terminateAuthorized(targets: List<RuntimeProcessTerminationTargetView>): Boolean {
        if (targets.isEmpty() || targets.size > MAX_CANDIDATES) return false
        if (!writeTerminationScript(targets)) return false
        val result = try {
            SuProcess().run(listOf(MAGISK_SU, "-c", terminationScript.absolutePath))
        } finally {
            deleteIfPresent(terminationScript)
        }
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    private fun writeObservationScript(): Boolean = try {
        if (!isSafeOwnedPath(observationScript) || !SAFE_PATH.matches(runtimeDir.absolutePath)) {
            return false
        }
        observationScript.writeText(
            """
            #!/system/bin/sh
            set -eu
            runtime="${runtimeDir.absolutePath}"
            candidate_count=0
            for proc in /proc/[0-9]*; do
              pid="${'$'}{proc#/proc/}"
              case "${'$'}pid" in ''|*[!0-9]*) exit 64;; esac
              [ -r "/proc/${'$'}pid/cmdline" ] || continue
              exec 3< "/proc/${'$'}pid/cmdline" || continue
              serialized=''
              candidate=0
              unsafe=0
              truncated=0
              argc=0
              while [ "${'$'}argc" -lt $MAX_OBSERVED_ARGV ]; do
                arg=''
                if ! IFS= read -r -d '' arg <&3; then
                  break
                fi
                argc=${'$'}((argc + 1))
                case "${'$'}arg" in
                  */$SING_BOX_LIBRARY|"${'$'}runtime"/sing-box*.json) candidate=1 ;;
                esac
                if [ "${'$'}{#arg}" -gt $MAX_ARG_CHARS ]; then
                  unsafe=1
                  arg='__UNSAFE__'
                else
                  case "${'$'}arg" in
                    *[!A-Za-z0-9_./~:=,+@%-]*) unsafe=1; arg='__UNSAFE__' ;;
                  esac
                fi
                serialized="${'$'}serialized\t${'$'}arg"
              done
              extra=''
              if IFS= read -r -d '' extra <&3; then truncated=1; fi
              exec 3<&-
              [ "${'$'}candidate" -eq 1 ] || continue
              candidate_count=${'$'}((candidate_count + 1))
              [ "${'$'}candidate_count" -le $MAX_CANDIDATES ] || exit 65
              hash_line="${'$'}(/system/bin/toybox sha256sum "/proc/${'$'}pid/cmdline" 2>/dev/null || true)"
              digest="${'$'}{hash_line%% *}"
              printf '%s\t%s\t%s\t%s%b\n' "${'$'}pid" "${'$'}digest" "${'$'}truncated" "${'$'}unsafe" "${'$'}serialized"
            done
            exit 0
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(observationScript.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun writeTerminationScript(targets: List<RuntimeProcessTerminationTargetView>): Boolean = try {
        if (!isSafeOwnedPath(terminationScript)) return false
        val cases = targets.joinToString("\n") { target ->
            val pid = target.pid.toString()
            val digest = target.cmdlineDigest
            if (pid.toULongOrNull()?.let { it > 0uL } != true || !SHA256_HEX.matches(digest)) {
                return false
            }
            "    $pid) printf '%s\\n' '$digest' ;;"
        }
        val pids = targets.joinToString(" ") { it.pid.toString() }
        terminationScript.writeText(
            """
            #!/system/bin/sh
            set -eu
            expected_digest() {
              case "${'$'}1" in
            $cases
                *) return 1 ;;
              esac
            }
            same_snapshot() {
              pid="${'$'}1"
              expected="${'$'}(expected_digest "${'$'}pid")" || return 1
              [ -r "/proc/${'$'}pid/cmdline" ] || return 1
              hash_line="${'$'}(/system/bin/toybox sha256sum "/proc/${'$'}pid/cmdline" 2>/dev/null || true)"
              actual="${'$'}{hash_line%% *}"
              [ "${'$'}actual" = "${'$'}expected" ]
            }
            pids="$pids"
            for pid in ${'$'}pids; do
              same_snapshot "${'$'}pid" || continue
              kill -TERM "${'$'}pid" 2>/dev/null || true
            done
            i=0
            while [ "${'$'}i" -lt 60 ]; do
              alive=0
              for pid in ${'$'}pids; do same_snapshot "${'$'}pid" && alive=1; done
              [ "${'$'}alive" -eq 0 ] && exit 0
              sleep 0.05
              i=${'$'}((i + 1))
            done
            for pid in ${'$'}pids; do
              same_snapshot "${'$'}pid" && kill -KILL "${'$'}pid" 2>/dev/null || true
            done
            i=0
            while [ "${'$'}i" -lt 40 ]; do
              alive=0
              for pid in ${'$'}pids; do same_snapshot "${'$'}pid" && alive=1; done
              [ "${'$'}alive" -eq 0 ] && exit 0
              sleep 0.05
              i=${'$'}((i + 1))
            done
            exit 5
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(terminationScript.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun isSafeOwnedPath(file: File): Boolean = file.absolutePath
        .let { it.startsWith(runtimeDir.absolutePath + "/") && SAFE_PATH.matches(it) }

    private fun parseFlag(value: String): Boolean? = when (value) {
        "0" -> false
        "1" -> true
        else -> null
    }

    private fun deleteIfPresent(file: File): Boolean = !file.exists() || file.delete() || !file.exists()

    private companion object {
        const val OBSERVATION_SCRIPT_FILE = "sing-box-process-observe.sh"
        const val TERMINATION_SCRIPT_FILE = "sing-box-process-terminate.sh"
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val MAGISK_SU = "su"
        const val MAX_RECONCILIATION_PASSES = 3
        const val MAX_CANDIDATES = 8
        const val MAX_OBSERVED_ARGV = 12
        const val MAX_ARG_CHARS = 512
        const val OBSERVATION_PREFIX_FIELDS = 4
        const val ROOT_SCRIPT_MODE = 448 // 0700
        val SAFE_PATH = Regex("""/[A-Za-z0-9_./~=-]+""")
        val SAFE_ARG = Regex("""[A-Za-z0-9_./~:=,+@%-]*""")
        val SHA256_HEX = Regex("""[0-9a-f]{64}""")
    }
}
