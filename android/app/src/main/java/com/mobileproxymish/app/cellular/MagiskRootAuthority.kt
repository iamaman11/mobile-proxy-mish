package com.mobileproxymish.app.cellular

/**
 * Bounded Magisk authority boundary for cellular policy routing.
 *
 * Root authority is acquired once per live root-shell generation and then cached. An explicit
 * denial or unanswered interactive grant is terminal for the current app process so recovery
 * cannot keep reopening Magisk prompts. After permanent grant, one app restart establishes the
 * cached session and normal network recovery does not ask Magisk again.
 *
 * Root command framing/process I/O lives in `RootCommandTransport.kt`; this class owns only the
 * process-generation privilege proof. RPDB/mangle policy remains owned by `CellularRootPolicy`.
 */
class MagiskRootAuthority private constructor(
    private val process: RootProcess = SuProcess(),
    private val bootstrap: RootSessionBootstrap = RootSessionBootstrap.None,
) {
    constructor() : this(
        process = SuProcess(),
        bootstrap = RootSessionBootstrap.currentProcess(),
    )

    private var readyGeneration: Long? = null
    private var terminalStatus: RootAuthorityStatus? = null

    @Synchronized
    fun probe(): RootAuthorityStatus {
        terminalStatus?.let { return it }

        val currentGeneration = process.sessionGeneration()
        if (currentGeneration != null && currentGeneration == readyGeneration) {
            return RootAuthorityStatus.Ready
        }
        readyGeneration = null

        val identity = process.run(listOf("su", "-c", "id -u"))
        if (identity.timedOut) {
            return RootAuthorityStatus.InteractiveGrantRequired.also { terminalStatus = it }
        }
        if (identity.exitCode == 126 || identity.exitCode == 127) {
            return RootAuthorityStatus.Unavailable
        }
        if (identity.exitCode > 0) {
            return RootAuthorityStatus.Denied.also { terminalStatus = it }
        }
        if (!identity.outputComplete || identity.exitCode != 0) {
            return RootAuthorityStatus.Incomplete
        }
        if (identity.stdout.trim() != "0") {
            return RootAuthorityStatus.Denied.also { terminalStatus = it }
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
            return RootAuthorityStatus.Incomplete
        }

        // One process-generation bootstrap may remove only exact stale PRODUCT owner jumps left by
        // a legitimate package UID change. Unknown/malformed policy stays untouched/fail-closed.
        if (!bootstrap.reconcile(process)) {
            return RootAuthorityStatus.Incomplete
        }

        readyGeneration = process.sessionGeneration()
        return RootAuthorityStatus.Ready
    }

    internal companion object {
        fun forTesting(process: RootProcess): MagiskRootAuthority = MagiskRootAuthority(
            process = process,
            bootstrap = RootSessionBootstrap.None,
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
