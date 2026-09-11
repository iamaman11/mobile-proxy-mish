package com.mobileproxymish.app.cellular

/**
 * Typed Android-platform observation sent toward the Rust Cellular Egress owner.
 *
 * These events are runtime-only adapter facts. They are not readiness decisions and
 * must never be persisted as current truth. `interfaceName` is an infrastructure hint
 * consumed only after the owner admits this exact network generation; it is not owner
 * state and does not cross the Rust policy boundary.
 */
sealed interface CellularNetworkEvent {
    val sequence: Long

    data class Observed(
        override val sequence: Long,
        val networkHandle: Long,
        val isCellular: Boolean,
        val hasInternet: Boolean,
        val isValidated: Boolean,
        val isNotVpn: Boolean,
        val interfaceName: String?,
    ) : CellularNetworkEvent

    data class Lost(
        override val sequence: Long,
        val networkHandle: Long,
    ) : CellularNetworkEvent
}

/** Narrow typed sink boundary. No JSON, localhost HTTP, or Android object crosses it. */
fun interface CellularObservationSink {
    fun onEvent(event: CellularNetworkEvent)
}
