package com.mobileproxymish.app.cellular

/**
 * Bounded retry cadence for recovering the existing PRODUCT Magisk/root authority boundary.
 *
 * This is not readiness state and not a second lifecycle owner. It only controls when the
 * existing CellularRuntimeBridge should re-probe the same current owner generation after root
 * authority was temporarily unavailable.
 */
internal data class RootAuthorityRecoveryDiagnostic(
    val attemptsSinceReset: Int,
    val nextDelayMs: Long,
)

internal class RootAuthorityRecoveryBackoff {
    private var attempt = 0

    @Synchronized
    fun nextDelayMs(): Long {
        val delay = rootAuthorityRecoveryDelayMs(attempt)
        if (attempt < MAX_BACKOFF_ATTEMPT) attempt += 1
        return delay
    }

    @Synchronized
    fun reset() {
        attempt = 0
    }

    @Synchronized
    fun diagnostic(): RootAuthorityRecoveryDiagnostic = RootAuthorityRecoveryDiagnostic(
        attemptsSinceReset = attempt,
        nextDelayMs = rootAuthorityRecoveryDelayMs(attempt),
    )
}

internal fun rootAuthorityRecoveryDelayMs(attempt: Int): Long = when (attempt.coerceIn(0, MAX_BACKOFF_ATTEMPT)) {
    0 -> 1_000L
    1 -> 5_000L
    2 -> 15_000L
    3 -> 30_000L
    else -> 60_000L
}

private const val MAX_BACKOFF_ATTEMPT = 4
