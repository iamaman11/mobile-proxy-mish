package com.mobileproxymish.app.cellular

import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

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
        if (identity.exitCode == 126 || identity.exitCode == 127) {
            return RootAuthorityStatus.Unavailable
        }
        if (identity.exitCode != 0 || identity.stdout.trim() != "0") {
            return RootAuthorityStatus.Denied
        }

        // uid=0 alone is insufficient. The runtime must be able to inspect RPDB before
        // the typed policy adapter is allowed to mutate exact PRODUCT-owned rules.
        val rules = process.run(listOf("su", "-c", "ip -4 rule show"))
        return if (!rules.timedOut && rules.exitCode == 0 && rules.stdout.isNotBlank()) {
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

internal data class RootProcessResult(
    val exitCode: Int,
    val stdout: String,
    val timedOut: Boolean = false,
)

/**
 * Root process implementation. Output is capped and consumed only to classify typed
 * adapter results; command output is never logged or persisted.
 */
internal class SuProcess : RootProcess {
    override fun run(arguments: List<String>): RootProcessResult {
        var child: Process? = null
        return try {
            child = ProcessBuilder(arguments).redirectErrorStream(true).start()
            if (!child.waitFor(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                child.destroyForcibly()
                RootProcessResult(exitCode = -1, stdout = "", timedOut = true)
            } else {
                val output = child.inputStream.use { input ->
                    ByteArrayOutputStream().use { sink ->
                        val buffer = ByteArray(256)
                        while (sink.size() < MAX_OUTPUT_BYTES) {
                            val read = input.read(
                                buffer,
                                0,
                                minOf(buffer.size, MAX_OUTPUT_BYTES - sink.size()),
                            )
                            if (read <= 0) break
                            sink.write(buffer, 0, read)
                        }
                        sink.toString(Charsets.UTF_8.name())
                    }
                }
                RootProcessResult(exitCode = child.exitValue(), stdout = output)
            }
        } catch (_: Exception) {
            RootProcessResult(exitCode = -1, stdout = "")
        } finally {
            child?.destroy()
        }
    }

    private companion object {
        const val PROBE_TIMEOUT_SECONDS = 10L
        const val MAX_OUTPUT_BYTES = 4096
    }
}
