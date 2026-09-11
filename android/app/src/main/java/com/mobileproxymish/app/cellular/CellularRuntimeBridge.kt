package com.mobileproxymish.app.cellular

import android.content.Context
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularController
import java.io.Closeable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Adapter-level failure reason; this does not become a Cellular Egress owner fact. */
enum class CellularBoundaryFailure {
    NativeLibraryUnavailable,
    ForeignCallFailed,
}

/**
 * Read-only runtime projection crossing from the Rust owner toward Android consumers.
 *
 * `OwnerSnapshot` is the natural owner's typed projection. `BoundaryUnavailable`
 * represents failure of this adapter boundary and therefore cannot be treated as an
 * admitted or ready cellular path.
 */
sealed interface CellularRuntimeSnapshot {
    data class OwnerSnapshot(
        val admission: CellularAdmissionView,
    ) : CellularRuntimeSnapshot

    data class BoundaryUnavailable(
        val reason: CellularBoundaryFailure,
    ) : CellularRuntimeSnapshot
}

/**
 * One process-generation bridge between Android Network observations and the Rust owner.
 *
 * This class owns no cellular policy. It owns only the foreign controller handle,
 * observer lifetime, and a read-only StateFlow projection for Android presentation.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    private val observer = CellularNetworkObserver(context.applicationContext, this)

    val snapshot: StateFlow<CellularRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    init {
        var createdController: CellularController? = null
        val initialSnapshot = try {
            createdController = CellularController()
            CellularRuntimeSnapshot.OwnerSnapshot(createdController.admissionSnapshot())
        } catch (_: LinkageError) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }

        controller = createdController
        mutableSnapshot = MutableStateFlow(initialSnapshot)
    }

    fun start() {
        if (controller != null) {
            observer.start()
        }
    }

    override fun onEvent(event: CellularNetworkEvent) {
        val activeController = controller ?: run {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            return
        }

        mutableSnapshot.value = try {
            val admission = when (event) {
                is CellularNetworkEvent.Observed -> activeController.observeNetwork(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                    isCellular = event.isCellular,
                    hasInternet = event.hasInternet,
                    isValidated = event.isValidated,
                    isNotVpn = event.isNotVpn,
                )

                is CellularNetworkEvent.Lost -> activeController.networkLost(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                )
            }
            CellularRuntimeSnapshot.OwnerSnapshot(admission)
        } catch (_: LinkageError) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }
    }

    override fun close() {
        observer.close()
    }
}
