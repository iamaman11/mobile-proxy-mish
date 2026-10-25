package com.mobileproxymish.app

/**
 * Platform-only durable anchor for one 24-hour Rust Credentials lease.
 *
 * The trusted duration is the Android kernel's elapsedRealtime, not mutable wall-clock time.
 * If we cannot prove the same boot, the temporary principal must fail closed. That can end
 * temporary access early after reboot, but cannot lengthen the issued 24-hour grant.
 * The anchor is AEAD-encrypted together with the credentials and the Rust lease.
 */
internal data class TemporaryLeaseAnchor(
    val bootCount: Int,
    val activatedElapsedMillis: Long,
    val activatedUnixSeconds: Long,
)

internal object TemporaryLeaseMonotonicClock {
    private const val MAX_SAFE_ELAPSED_MILLIS = 31L * 24L * 60L * 60L * 1000L
    private const val MIN_REASONABLE_EPOCH_SECONDS = 1_577_836_800L // 2020-01-01 UTC

    fun issue(
        bootCount: Int?,
        elapsedMillis: Long,
        wallUnixSeconds: Long,
    ): TemporaryLeaseAnchor? {
        if (bootCount == null || bootCount < 0 || elapsedMillis < 0L ||
            wallUnixSeconds < MIN_REASONABLE_EPOCH_SECONDS
        ) return null
        return TemporaryLeaseAnchor(bootCount, elapsedMillis, wallUnixSeconds)
    }

    /** Each accepted read uses monotonic elapsed time. Wall clock changes never extend the grant. */
    fun observe(anchor: TemporaryLeaseAnchor, bootCount: Int?, elapsedMillis: Long): ULong? {
        if (bootCount == null || bootCount != anchor.bootCount ||
            elapsedMillis < anchor.activatedElapsedMillis
        ) return null
        val elapsed = elapsedMillis - anchor.activatedElapsedMillis
        if (elapsed < 0 || elapsed > MAX_SAFE_ELAPSED_MILLIS) return null
        val unix = anchor.activatedUnixSeconds + (elapsed / 1_000L)
        return if (unix >= anchor.activatedUnixSeconds) unix.toULong() else null
    }
}
