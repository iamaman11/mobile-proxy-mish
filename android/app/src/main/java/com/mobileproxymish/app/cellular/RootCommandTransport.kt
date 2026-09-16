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

/** Internal typed-command transport seam for deterministic tests and root-policy adapters. */
internal interface RootProcess {
    fun run(arguments: List<String>): RootProcessResult

    /** Live privilege-session identity. A change invalidates any cached authority proof. */
    fun sessionGeneration(): Long? = null
}

/**
 * Bounded root-command result. Incomplete output is never authoritative kernel state.
 */
internal data class RootProcessResult(
    val exitCode: Int,
    val stdout: String,
    val timedOut: Boolean = false,
    val outputComplete: Boolean = true,
)

/**
 * Process-wide persistent Magisk root-shell transport.
 *
 * This class owns framing, serialization, output/deadline bounds and shell-generation identity
 * only. It owns no root authority policy and exposes no general-purpose shell API to app callers.
 * A transport failure invalidates the shared shell but is never replayed automatically because a
 * mutating command may already have reached the kernel.
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
            if (!isAlive()) return unavailableOutcome()

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

                if (line == null) continue
                if (line == EOF_SENTINEL) {
                    return prematureShellExitOutcome(captured.toString(), outputComplete)
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

        private fun prematureShellExitOutcome(
            stdout: String,
            outputComplete: Boolean,
        ): CommandOutcome {
            val exited = try {
                process.waitFor(PREMATURE_EXIT_CAPTURE_MILLIS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            }
            val exitCode = if (exited) {
                try {
                    process.exitValue()
                } catch (_: IllegalThreadStateException) {
                    null
                }
            } else {
                null
            }
            return CommandOutcome(
                result = prematureExitResult(exitCode, stdout, outputComplete),
                transportHealthy = false,
            )
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

        /** Preserve only a proven non-zero pre-marker `su` exit as authoritative denial. */
        internal fun prematureExitResult(
            exitCode: Int?,
            stdout: String,
            outputComplete: Boolean,
        ): RootProcessResult = if (exitCode != null && exitCode != 0) {
            RootProcessResult(
                exitCode = exitCode,
                stdout = stdout,
                outputComplete = outputComplete,
            )
        } else {
            RootProcessResult(
                exitCode = -1,
                stdout = "",
                outputComplete = false,
            )
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
        const val PREMATURE_EXIT_CAPTURE_MILLIS = 250L
        const val MAX_OUTPUT_BYTES = 4096
        const val MARKER_PREFIX = "__MISH_ROOT_DONE_"
        const val EOF_SENTINEL = "__MISH_ROOT_TRANSPORT_EOF__"
    }
}
