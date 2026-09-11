package com.mobileproxymish.app.cellular

import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * Bounded authority boundary for product-owned Magisk operations.
 *
 * This class deliberately exposes no arbitrary command API. It only classifies whether
 * the PRODUCT UID has a non-interactive root grant that can read RPDB state. Cellular
 * Egress remains the semantic owner of admission/generation/fail-closed decisions.
 */
class MagiskRootAuthority private constructor(
    private val process: RootProcess,
) {
    constructor() : this(SuProcess())

    fun probe(): RootAuthorityStatus {
        val identity = process.run(listOf("su", "-c", "id -u"))
        if (identity.timedOut) {
            return RootAuthorityStatus.InteractiveGrantRequired
        }
        if (identity.exitCode == 126 || identity.exitCode == 127 || identity.exitCode < 0) {
            return RootAuthorityStatus.Unavailable
        }
        if (identity.exitCode != 0 || identity.stdout.trim() != "0") {
            return RootAuthorityStatus.Denied
        }

        // uid=0 alone is insufficient. The bounded routing executor also needs to read
        // current RPDB state before it is permitted to mutate PRODUCT-owned objects.
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

/** Internal process seam for deterministic tests; app consumers cannot execute commands. */
internal interface RootProcess {
    fun run(arguments: List<String>): RootProcessResult
}

internal data class RootProcessResult(
    val exitCode: Int,
    val stdout: String,
    val timedOut: Boolean = false,
)

/**
 * Process implementation used only by typed root adapters. Output is bounded and is
 * never logged or persisted.
 */
internal class SuProcess : RootProcess {
    override fun run(arguments: List<String>): RootProcessResult {
        var child: Process? = null
        return try {
            child = ProcessBuilder(arguments).redirectErrorStream(true).start()
            if (!child.waitFor(COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                child.destroyForcibly()
                RootProcessResult(exitCode = -1, stdout = "", timedOut = true)
            } else {
                val output = child.inputStream.use { input ->
                    ByteArrayOutputStream().use { sink ->
                        val buffer = ByteArray(512)
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
        const val COMMAND_TIMEOUT_SECONDS = 10L
        const val MAX_OUTPUT_BYTES = 16 * 1024
    }
}
