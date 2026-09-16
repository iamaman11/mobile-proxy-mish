package com.mobileproxymish.app.cellular

/**
 * Narrow root-command effect used only by the Cellular root-policy transaction.
 *
 * The command strings remain constructed by the typed policy adapter; this class is not exposed as
 * an application shell API. It centralizes completeness/deadline handling for authoritative kernel
 * snapshots and exact idempotent mutations.
 */
internal class RootPolicyExecutor(
    private val process: RootProcess,
) {
    fun run(command: String): RootProcessResult = process.run(listOf("su", "-c", command))

    fun lines(command: String): List<String>? {
        val result = run(command)
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

    fun mangleLines(binary: String): List<String>? = lines("$binary -t mangle -S")

    fun commandSucceeded(command: String): Boolean {
        val result = run(command)
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    fun removeExactRule(
        checkCommand: String,
        deleteCommand: String,
        maxPasses: Int,
    ): Boolean {
        repeat(maxPasses) {
            val check = run(checkCommand)
            if (check.timedOut || !check.outputComplete) return false
            if (check.exitCode != 0) return true
            if (!commandSucceeded(deleteCommand)) return false
        }
        val finalCheck = run(checkCommand)
        return !finalCheck.timedOut && finalCheck.outputComplete && finalCheck.exitCode != 0
    }
}
