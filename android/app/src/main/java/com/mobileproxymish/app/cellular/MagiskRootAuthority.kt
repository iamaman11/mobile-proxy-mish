package com.mobileproxymish.app.cellular

import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bounded Magisk authority boundary for cellular policy routing.
 *
 * This class deliberately does not observe networks, choose a route table, or install
 * routing policy by itself. Cellular Egress remains the sole owner of admission and
 * generation/currentness facts. No arbitrary shell API is exposed to app consumers.
 */
class MagiskRootAuthority private constructor(
    private val process: RootProcess = SuProcess(),
) {
    constructor() : this(SuProcess())

    fun probe(): RootAuthorityStatus {
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

        // uid=0 alone is insufficient. The runtime must be able to inspect a complete
        // RPDB snapshot before the typed policy adapter may mutate exact PRODUCT rules.
        val rules = process.run(listOf("su", "-c", "ip -4 rule show"))
        return if (
            !rules.timedOut &&
            rules.outputComplete &&
            rules.exitCode == 0 &&
            rules.stdout.isNotBlank()
        ) {
            RootAuthorityStatus.Ready
        } else {
            RootAuthorityStatus.Incomplete
        }
    }

    internal companion object {
        fun forTesting(process: RootProcess): MagiskRootAuthority = MagiskRootAuthority(process)
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
 * Root process implementation. Output is bounded and never logged or persisted.
 *
 * Android's timed Process.waitFor and destroyForcibly APIs start at API 26, while the
 * product supports API 23. This implementation therefore uses only the API-23-safe
 * Process contract: a bounded exitValue poll, concurrent output draining to avoid pipe
 * back-pressure, and destroy() on timeout. The reader continues draining after the
 * capture cap so a verbose root command cannot deadlock the child process.
 *
 * Policy parsing must never consume partial command output. After the child exits we
 * require both EOF within a bounded drain window and a non-overflowed capture. Any
 * reader failure or overflow is represented as `outputComplete=false` and fails closed.
 */
internal class SuProcess : RootProcess {
    override fun run(arguments: List<String>): RootProcessResult {
        var child: Process? = null
        var outputReader: Thread? = null
        val output = ByteArrayOutputStream()
        val outputComplete = AtomicBoolean(true)

        return try {
            child = ProcessBuilder(arguments).redirectErrorStream(true).start()
            val runningChild = child

            outputReader = Thread(
                {
                    try {
                        runningChild.inputStream.use { input ->
                            val buffer = ByteArray(OUTPUT_BUFFER_BYTES)
                            while (true) {
                                val read = input.read(buffer)
                                if (read <= 0) break

                                synchronized(output) {
                                    val remaining = MAX_OUTPUT_BYTES - output.size()
                                    val captured = minOf(read, remaining.coerceAtLeast(0))
                                    if (captured > 0) {
                                        output.write(buffer, 0, captured)
                                    }
                                    if (captured != read) {
                                        outputComplete.set(false)
                                    }
                                }
                            }
                        }
                    } catch (_: Exception) {
                        outputComplete.set(false)
                    }
                },
                "mish-root-output",
            ).apply {
                isDaemon = true
                start()
            }

            val deadline = System.nanoTime() + PROBE_TIMEOUT_NANOS
            var exitCode: Int? = null
            do {
                exitCode = try {
                    runningChild.exitValue()
                } catch (_: IllegalThreadStateException) {
                    null
                }

                if (exitCode == null) {
                    Thread.sleep(POLL_INTERVAL_MILLIS)
                }
            } while (exitCode == null && System.nanoTime() < deadline)

            if (exitCode == null) {
                runningChild.destroy()
                outputReader.join(READER_JOIN_MILLIS)
                RootProcessResult(
                    exitCode = -1,
                    stdout = "",
                    timedOut = true,
                    outputComplete = false,
                )
            } else {
                outputReader.join(READER_JOIN_MILLIS)
                if (outputReader.isAlive) {
                    RootProcessResult(
                        exitCode = -1,
                        stdout = "",
                        timedOut = true,
                        outputComplete = false,
                    )
                } else {
                    val stdout = synchronized(output) {
                        output.toString(Charsets.UTF_8.name())
                    }
                    RootProcessResult(
                        exitCode = exitCode,
                        stdout = stdout,
                        outputComplete = outputComplete.get(),
                    )
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            RootProcessResult(
                exitCode = -1,
                stdout = "",
                timedOut = true,
                outputComplete = false,
            )
        } catch (_: Exception) {
            RootProcessResult(exitCode = -1, stdout = "", outputComplete = false)
        } finally {
            child?.destroy()
        }
    }

    private companion object {
        const val PROBE_TIMEOUT_NANOS = 10_000_000_000L
        const val POLL_INTERVAL_MILLIS = 25L
        const val READER_JOIN_MILLIS = 1_000L
        const val OUTPUT_BUFFER_BYTES = 256
        const val MAX_OUTPUT_BYTES = 4096
    }
}
