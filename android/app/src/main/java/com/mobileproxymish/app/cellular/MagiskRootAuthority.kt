package com.mobileproxymish.app.cellular

import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Bounded Magisk authority boundary for cellular policy routing.
 *
 * Root authority is acquired once per live root-shell generation and then cached. The policy
 * adapter still owns every typed RPDB/mangle decision; this class owns only the process-level
 * privilege capability. No arbitrary shell API is exposed to app consumers.
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

    @Synchronized
    fun probe(): RootAuthorityStatus {
        val currentGeneration = process.sessionGeneration()
        if (currentGeneration != null && currentGeneration == readyGeneration) {
            return RootAuthorityStatus.Ready
        }
        readyGeneration = null

        val identity = process.run(listOf("su", "-c", "id -u"))
        if (identity.timedOut) {
            return RootAuthorityStatus.InteractiveGrantRequired
        }
        if (!identity.outputComplete) {
            return RootAuthorityStatus.Incomplete
        }
        if (identity.exitCode == 126 || identity.exitCode == 127) {
            return RootAuthorityStatus.Unavailable
        }
        if (identity.exitCode != 0 || identity.stdout.trim() != "0") {
            return RootAuthorityStatus.Denied
        }

        // uid=0 alone is insufficient. The runtime must be able to inspect a complete RPDB
        // snapshot before the typed policy adapter may mutate exact PRODUCT rules.
        val rules = process.run(listOf("su", "-c", "ip -4 rule show"))
        if (
            rules.timedOut ||
            !rules.outputComplete ||
            rules.exitCode != 0 ||
            rules.stdout.isBlank()
        ) {
            return RootAuthorityStatus.Incomplete
        }

        // One process-generation bootstrap may remove only exact stale PRODUCT owner jumps left
        // by a legitimate package UID change. Unknown/malformed policy remains untouched and is
        // still rejected later by CellularRootPolicy's fail-closed collision audit.
        if (!bootstrap.reconcile(process)) {
            return RootAuthorityStatus.Incomplete
        }

        readyGeneration = process.sessionGeneration()
        return if (readyGeneration != null) {
            RootAuthorityStatus.Ready
        } else {
            RootAuthorityStatus.Incomplete
        }
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

/** Internal seam for deterministic tests. It is not exposed to app consumers. */
internal interface RootProcess {
    fun run(arguments: List<String>): RootProcessResult

    /**
     * Identity of the currently live privilege session, when the implementation has one.
     * A change invalidates any cached authority proof.
     */
    fun sessionGeneration(): Long? = null
}

/**
 * Bounded root-command result. `outputComplete=false` means the command output could not
 * be represented completely inside the capture contract and therefore must never be
 * parsed as authoritative kernel state.
 */
internal data class RootProcessResult(
    val exitCode: Int,
    val stdout: String,
    val timedOut: Boolean = false,
    val outputComplete: Boolean = true,
)

/**
 * Process-wide persistent Magisk root shell.
 *
 * Previous behavior started a fresh `su -c` process for every policy read/mutation. One healthy
 * reconcile could therefore launch many Magisk sessions and output-reader threads. DEVICE-1 has
 * exactly one application privilege boundary, so all typed callers now share one non-interactive
 * root shell for the Android process lifetime.
 *
 * Commands remain serialized, output-bounded and deadline-bounded. A transport failure invalidates
 * the shared shell but is never replayed automatically: a mutation may already have reached the
 * kernel before the transport failed. The next reconciliation opens one fresh shell and re-runs the
 * normal idempotent policy transaction.
 */
internal class SuProcess : RootProcess {
    override fun run(arguments: List<String>): RootProcessResult = synchronized(ROOT_PROCESS_LOCK) {
        if (
            arguments.size != 3 ||
            arguments[0] != "su" ||
            arguments[1] != "-c" ||
            arguments[2].contains('\n') ||
            arguments[2].contains('\r')
        ) {
            return@synchronized RootProcessResult(
                exitCode = -1,
                stdout = "",
                outputComplete = false,
            )
        }

        val session = liveSessionOrCreate()
            ?: return@synchronized RootProcessResult(
                exitCode = 127,
                stdout = "",
            )

        val outcome = session.execute(arguments[2])
        if (!outcome.transportHealthy) {
            invalidateSharedSession(session)
        }
        outcome.result
    }

    override fun sessionGeneration(): Long? = synchronized(ROOT_PROCESS_LOCK) {
        val current = sharedSession
        if (current == null) {
            null
        } else if (current.isAlive()) {
            current.generation
        } else {
            invalidateSharedSession(current)
            null
        }
    }

    private data class CommandOutcome(
        val result: RootProcessResult,
        val transportHealthy: Boolean,
    )

    private class RootShellSession(
        val generation: Long,
    ) {
        private val process = ProcessBuilder("su")
            .redirectErrorStream(true)
            .start()
        private val writer = BufferedWriter(
            OutputStreamWriter(process.outputStream, StandardCharsets.UTF_8),
        )
        private val lines = LinkedBlockingQueue<String>()
        private val markerNonce = UUID.randomUUID().toString().replace("-", "")
        private val commandSequence = AtomicLong(0L)
        private val reader = Thread(
            {
                try {
                    BufferedReader(
                        InputStreamReader(process.inputStream, StandardCharsets.UTF_8),
                    ).use { input ->
                        while (true) {
                            val line = input.readLine() ?: break
                            lines.put(line)
                        }
                    }
                } catch (_: Exception) {
                    // EOF sentinel below is the transport-failure signal.
                } finally {
                    lines.offer(EOF_SENTINEL)
                }
            },
            "mish-root-shell-output",
        ).apply {
            isDaemon = true
            start()
        }

        fun isAlive(): Boolean = process.isAlive

        fun execute(command: String): CommandOutcome {
            if (!isAlive()) {
                return unavailableOutcome()
            }

            val marker = "$MARKER_PREFIX${markerNonce}_${commandSequence.incrementAndGet()}"
            lines.clear()

            try {
                writer.write(command)
                writer.newLine()
                writer.write(
                    "__mish_root_status=${'$'}?; " +
                        "printf '\\n$marker:%s\\n' \"${'$'}__mish_root_status\"",
                )
                writer.newLine()
                writer.flush()
            } catch (_: Exception) {
                return unavailableOutcome()
            }

            val deadline = System.nanoTime() + COMMAND_TIMEOUT_NANOS
            val captured = StringBuilder()
            var capturedBytes = 0
            var outputComplete = true

            while (true) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) {
                    destroy()
                    return CommandOutcome(
                        result = RootProcessResult(
                            exitCode = -1,
                            stdout = "",
                            timedOut = true,
                            outputComplete = false,
                        ),
                        transportHealthy = false,
                    )
                }

                val line = try {
                    lines.poll(remaining, TimeUnit.NANOSECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    destroy()
                    return CommandOutcome(
                        result = RootProcessResult(
                            exitCode = -1,
                            stdout = "",
                            timedOut = true,
                            outputComplete = false,
                        ),
                        transportHealthy = false,
                    )
                }

                if (line == null) {
                    continue
                }
                if (line == EOF_SENTINEL) {
                    return unavailableOutcome()
                }
                if (line.startsWith("$marker:")) {
                    val exitCode = line.substringAfter(':').toIntOrNull()
                        ?: return CommandOutcome(
                            RootProcessResult(-1, "", outputComplete = false),
                            transportHealthy = false,
                        )
                    return CommandOutcome(
                        result = RootProcessResult(
                            exitCode = exitCode,
                            stdout = captured.toString(),
                            outputComplete = outputComplete,
                        ),
                        transportHealthy = true,
                    )
                }

                val encodedBytes = line.toByteArray(StandardCharsets.UTF_8).size + 1
                val remainingCapture = MAX_OUTPUT_BYTES - capturedBytes
                if (encodedBytes <= remainingCapture) {
                    captured.append(line).append('\n')
                    capturedBytes += encodedBytes
                } else {
                    outputComplete = false
                }
            }
        }

        fun destroy() {
            try {
                writer.close()
            } catch (_: Exception) {
                // Best effort only; the process is destroyed below.
            }
            if (process.isAlive) {
                process.destroy()
                try {
                    if (!process.waitFor(PROCESS_STOP_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)) {
                        process.destroyForcibly()
                    }
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    process.destroyForcibly()
                }
            }
        }

        private fun unavailableOutcome(): CommandOutcome = CommandOutcome(
            result = RootProcessResult(
                exitCode = -1,
                stdout = "",
                outputComplete = false,
            ),
            transportHealthy = false,
        )
    }

    internal companion object {
        val ROOT_PROCESS_LOCK = Any()
        private var sharedSession: RootShellSession? = null
        private var nextSessionGeneration = 1L

        /** Shares one DEVICE-1 Magisk shell across all typed root clients in the app process. */
        fun <T> serializedRootSession(block: () -> T): T = synchronized(ROOT_PROCESS_LOCK) {
            block()
        }

        private fun liveSessionOrCreate(): RootShellSession? {
            val current = sharedSession
            if (current != null && current.isAlive()) return current
            if (current != null) invalidateSharedSession(current)

            return try {
                RootShellSession(nextSessionGeneration++).also { sharedSession = it }
            } catch (_: Exception) {
                null
            }
        }

        private fun invalidateSharedSession(expected: RootShellSession) {
            if (sharedSession === expected) {
                sharedSession = null
            }
            expected.destroy()
        }

        const val COMMAND_TIMEOUT_NANOS = 10_000_000_000L
        const val PROCESS_STOP_TIMEOUT_MILLIS = 500L
        const val MAX_OUTPUT_BYTES = 4096
        const val MARKER_PREFIX = "__MISH_ROOT_DONE_"
        const val EOF_SENTINEL = "__MISH_ROOT_TRANSPORT_EOF__"
    }
}
