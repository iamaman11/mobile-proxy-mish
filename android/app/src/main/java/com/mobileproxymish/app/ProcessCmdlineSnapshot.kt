package com.mobileproxymish.app

import java.security.MessageDigest

/**
 * Reconstruct the exact safe, non-truncated /proc/<pid>/cmdline byte representation from argv.
 * Linux exposes argv as NUL-delimited bytes including the final trailing NUL.
 */
internal fun procCmdlineSha256(argv: List<String>): String {
    val digest = MessageDigest.getInstance("SHA-256")
    argv.forEach { argument ->
        digest.update(argument.toByteArray(Charsets.UTF_8))
        digest.update(0.toByte())
    }
    return digest.digest().toLowerHex()
}

/**
 * Observation integrity check. A separately-read root digest must describe exactly the argv snapshot
 * being handed to the Rust ownership owner; otherwise the snapshot is stale/mixed and fails closed.
 */
internal fun procCmdlineSnapshotMatchesDigest(
    argv: List<String>,
    observedDigest: String,
): Boolean = SHA256_HEX.matches(observedDigest) && procCmdlineSha256(argv) == observedDigest

private fun ByteArray.toLowerHex(): String = buildString(size * 2) {
    for (byte in this@toLowerHex) {
        val value = byte.toInt() and 0xff
        append(HEX[value ushr 4])
        append(HEX[value and 0x0f])
    }
}

private val SHA256_HEX = Regex("[0-9a-f]{64}")
private const val HEX = "0123456789abcdef"
