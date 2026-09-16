package com.mobileproxymish.app.cellular

/**
 * Bounded process-wide Magisk authority boundary for PRODUCT root effects.
 *
 * Every production client shares the same authority state and the same process-wide `SuProcess`
 * shell generation. Authority is therefore acquired once per live root-shell generation and then
 * cached across typed root clients. An explicit denial or unanswered interactive grant is terminal
 * for the current app process so another subsystem cannot reopen the Magisk prompt.
 *
 * Root command framing/process I/O lives in `RootCommandTransport.kt`; this class owns only the
 * process-generation privilege proof. RPDB/mangle policy remains owned by `CellularRootPolicy` and
 * one-shot upgrade cleanup remains owned by its narrow cutover adapter.
 */
class MagiskRootAuthority private constructor(
    private val process: RootProcess,
    private val bootstrap: RootSessionBootstrap,
    private val state: AuthorityState,
) {
    constructor() : this(
        process = SuProcess(),
        bootstrap = RootSessionBootstrap.currentProcess(),
        state = CURRENT_PROCESS_STATE,
    )

    fun probe(): RootAuthorityStatus = synchronized(state) {
        state.terminalStatus?.let { return@synchronized it }

        val currentGeneration = process.sessionGeneration()
        if (currentGeneration != null && currentGeneration == state.readyGeneration) {
            return@synchronized RootAuthorityStatus.Ready
        }
        state.readyGeneration = null

        val identity = process.run(listOf("su", "-c", "id -u"))
        if (identity.timedOut) {
            return@synchronized RootAuthorityStatus.InteractiveGrantRequired.also {
                state.terminalStatus = it
            }
        }
        if (identity.exitCode == 126 || identity.exitCode == 127) {
            return@synchronized RootAuthorityStatus.Unavailable
        }
        if (identity.exitCode > 0) {
            return@synchronized RootAuthorityStatus.Denied.also { state.terminalStatus = it }
        }
        if (!identity.outputComplete || identity.exitCode != 0) {
            return@synchronized RootAuthorityStatus.Incomplete
        }
        if (identity.stdout.trim() != "0") {
            return@synchronized RootAuthorityStatus.Denied.also { state.terminalStatus = it }
        }

        // uid=0 alone is insufficient. The typed policy adapter must be able to inspect a complete
        // RPDB snapshot before it may mutate exact PRODUCT rules.
        val rules = process.run(listOf("su", "-c", "ip -4 rule show"))
        if (
            rules.timedOut ||
            !rules.outputComplete ||
            rules.exitCode != 0 ||
            rules.stdout.isBlank()
        ) {
            return@synchronized RootAuthorityStatus.Incomplete
        }

        // One process-generation bootstrap may remove only exact stale PRODUCT owner jumps left by
        // a legitimate package UID change. Unknown/malformed policy stays untouched/fail-closed.
        if (!bootstrap.reconcile(process)) {
            return@synchronized RootAuthorityStatus.Incomplete
        }

        state.readyGeneration = process.sessionGeneration()
        RootAuthorityStatus.Ready
    }

    private class AuthorityState {
        var readyGeneration: Long? = null
        var terminalStatus: RootAuthorityStatus? = null
    }

    internal companion object {
        /** One PRODUCT privilege fact per app process; process restart intentionally resets it. */
        private val CURRENT_PROCESS_STATE = AuthorityState()

        fun forTesting(process: RootProcess): MagiskRootAuthority = MagiskRootAuthority(
            process = process,
            bootstrap = RootSessionBootstrap.None,
            state = AuthorityState(),
        )
    }
}

sealed interface RootAuthorityStatus {
    data object Ready : RootAuthorityStatus
    data object InteractiveGrantRequired : RootAuthorityStatus
    data object Denied : RootAuthorityStatus
    data object Unavailable : RootAuthorityStatus
    data object Incomplete : RootAuthorityStatus
}
