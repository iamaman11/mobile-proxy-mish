package com.mobileproxymish.app.cellular

internal data class RootPolicyCommandWindowDiagnostic(
    val commands: Int,
    val observationCommands: Int,
    val mutationCommands: Int,
    val duplicateObservations: Int,
    val incompleteOrTimedOutCommands: Int,
    val mutationFailures: Int,
)

private data class RootPolicyCommandWindow(
    var commands: Int = 0,
    var observationCommands: Int = 0,
    var mutationCommands: Int = 0,
    var duplicateObservations: Int = 0,
    var incompleteOrTimedOutCommands: Int = 0,
    var mutationFailures: Int = 0,
    val observationIdentities: MutableSet<String> = mutableSetOf(),
)

/**
 * Narrow root-command effect used only by the Cellular root-policy transaction.
 *
 * Command text remains constructed by the typed policy adapter, but the transport receives an
 * explicit RootObservation or RootMutation rather than a shell-shaped su invocation. This class is
 * not exposed as an application shell API. It centralizes completeness/deadline handling for
 * authoritative kernel snapshots and exact idempotent mutations.
 */
internal class RootPolicyExecutor(
    private val transport: RootCommandTransport,
) {
    private var diagnosticWindow: RootPolicyCommandWindow? = null

    @Synchronized
    fun beginDiagnosticWindow() {
        check(diagnosticWindow == null) { "root-policy diagnostic window already active" }
        diagnosticWindow = RootPolicyCommandWindow()
    }

    @Synchronized
    fun finishDiagnosticWindow(): RootPolicyCommandWindowDiagnostic {
        val window = checkNotNull(diagnosticWindow) { "root-policy diagnostic window is not active" }
        diagnosticWindow = null
        return RootPolicyCommandWindowDiagnostic(
            commands = window.commands,
            observationCommands = window.observationCommands,
            mutationCommands = window.mutationCommands,
            duplicateObservations = window.duplicateObservations,
            incompleteOrTimedOutCommands = window.incompleteOrTimedOutCommands,
            mutationFailures = window.mutationFailures,
        )
    }

    fun observe(command: String): RootCommandResult = runObservation(command)

    fun lines(command: String): List<String>? {
        val result = runObservation(command)
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

    fun mangleLines(binary: String): List<String>? = lines("$binary -t mangle -S")

    fun commandSucceeded(command: String): Boolean {
        val result = runMutation(command)
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    fun removeExactRule(
        checkCommand: String,
        deleteCommand: String,
        maxPasses: Int,
    ): Boolean {
        repeat(maxPasses) {
            val check = runObservation(checkCommand)
            if (check.timedOut || !check.outputComplete) return false
            if (check.exitCode != 0) return true
            if (!commandSucceeded(deleteCommand)) return false
        }
        val finalCheck = runObservation(checkCommand)
        return !finalCheck.timedOut && finalCheck.outputComplete && finalCheck.exitCode != 0
    }

    private fun runObservation(command: String): RootCommandResult {
        var result = transport.execute(RootObservation(command))
        recordObservation(command, result)

        // A read-only effect is safe to re-observe after a non-authoritative transport result.
        // Mutations deliberately do not share this path: an uncertain mutation may already have
        // reached the kernel and must be reconciled by fresh observation instead of replayed.
        if (result.timedOut || !result.outputComplete) {
            result = transport.execute(RootObservation(command))
            recordObservation(command, result)
        }
        return result
    }

    private fun runMutation(command: String): RootCommandResult {
        val result = transport.execute(RootMutation(command))
        recordMutation(result)
        return result
    }

    @Synchronized
    private fun recordObservation(
        command: String,
        result: RootCommandResult,
    ) {
        val window = diagnosticWindow ?: return
        window.commands += 1
        window.observationCommands += 1
        if (!window.observationIdentities.add(command)) {
            window.duplicateObservations += 1
        }
        if (result.timedOut || !result.outputComplete) {
            window.incompleteOrTimedOutCommands += 1
        }
    }

    @Synchronized
    private fun recordMutation(result: RootCommandResult) {
        val window = diagnosticWindow ?: return
        window.commands += 1
        window.mutationCommands += 1
        if (result.timedOut || !result.outputComplete) {
            window.incompleteOrTimedOutCommands += 1
        }
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) {
            window.mutationFailures += 1
        }
    }
}
