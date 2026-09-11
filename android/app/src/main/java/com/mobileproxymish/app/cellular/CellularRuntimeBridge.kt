package com.mobileproxymish.app.cellular

import android.content.Context
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
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
    RootAuthorityUnavailable,
    RootPolicyReconcileFailed,
}

/**
 * Read-only runtime projection crossing from the Rust owner toward Android consumers.
 *
 * `OwnerSnapshot` is the natural owner's typed projection. `BoundaryUnavailable`
 * represents failure of an adapter boundary and therefore cannot be treated as an
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
 * Transient Android infrastructure hints keyed by the exact platform Network handle.
 *
 * This is deliberately not a second owner or readiness state. The Rust owner still
 * decides which handle is admitted; this cache only lets the policy adapter retrieve
 * the interface hint belonging to that exact owner-selected handle after reordered,
 * unrelated, or superseded callbacks.
 */
internal class CellularInterfaceHints {
    private val byNetwork = mutableMapOf<ULong, String?>()

    fun observed(networkHandle: ULong, interfaceName: String?) {
        byNetwork[networkHandle] = interfaceName
    }

    fun lost(networkHandle: ULong) {
        byNetwork.remove(networkHandle)
    }

    fun interfaceFor(admittedNetworkHandle: ULong?): String? =
        admittedNetworkHandle?.let(byNetwork::get)

    fun clear() {
        byNetwork.clear()
    }
}

/**
 * One process-generation bridge between Android Network observations, the Rust owner,
 * and the narrow root policy-routing adapter that realizes an already owner-admitted
 * decision. This class owns no cellular admission policy.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    private val rootPolicy = CellularRootPolicy(Process.myUid())
    private val interfaceHints = CellularInterfaceHints()
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
        if (controller == null) return

        val initialPolicy = rootPolicy.failClosed()
        mutableSnapshot.value = when (initialPolicy) {
            is CellularRootPolicyResult.AuthorityUnavailable ->
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootAuthorityUnavailable,
                )

            is CellularRootPolicyResult.FailClosed -> {
                if (initialPolicy.reason == null) {
                    mutableSnapshot.value
                } else {
                    CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyReconcileFailed,
                    )
                }
            }

            CellularRootPolicyResult.Enforced -> mutableSnapshot.value
        }
        observer.start()
    }

    @Synchronized
    override fun onEvent(event: CellularNetworkEvent) {
        val activeController = controller ?: run {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            return
        }

        mutableSnapshot.value = try {
            when (event) {
                is CellularNetworkEvent.Observed -> interfaceHints.observed(
                    networkHandle = event.networkHandle.toULong(),
                    interfaceName = event.interfaceName,
                )

                is CellularNetworkEvent.Lost -> interfaceHints.lost(
                    networkHandle = event.networkHandle.toULong(),
                )
            }

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

            // Mechanism follows the owner-selected handle, never whichever callback
            // happened to arrive most recently. This preserves the current path when an
            // old handle is lost or an unrelated candidate is observed.
            val interfaceName = interfaceHints.interfaceFor(admission.admittedNetworkHandle)
            val policyResult = rootPolicy.reconcile(
                admitted = admission.state == CellularAdmissionState.ADMITTED,
                interfaceName = interfaceName,
            )

            when (policyResult) {
                CellularRootPolicyResult.Enforced ->
                    CellularRuntimeSnapshot.OwnerSnapshot(admission)

                is CellularRootPolicyResult.FailClosed -> {
                    if (admission.state != CellularAdmissionState.ADMITTED &&
                        policyResult.reason == null
                    ) {
                        CellularRuntimeSnapshot.OwnerSnapshot(admission)
                    } else {
                        CellularRuntimeSnapshot.BoundaryUnavailable(
                            CellularBoundaryFailure.RootPolicyReconcileFailed,
                        )
                    }
                }

                is CellularRootPolicyResult.AuthorityUnavailable ->
                    CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootAuthorityUnavailable,
                    )
            }
        } catch (_: LinkageError) {
            rootPolicy.failClosed()
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            rootPolicy.failClosed()
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }
    }

    @Synchronized
    override fun close() {
        observer.close()
        interfaceHints.clear()
        rootPolicy.close()
    }
}
