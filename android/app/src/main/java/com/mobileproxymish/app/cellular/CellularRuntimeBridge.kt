package com.mobileproxymish.app.cellular

import android.content.Context
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularController
import java.io.Closeable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
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
 * `OwnerSnapshot.admission` remains the natural owner's typed projection. `rootPolicy`
 * reports only whether the adapter successfully realized that owner projection in the
 * kernel; it is not a second admission/readiness owner.
 */
sealed interface CellularRuntimeSnapshot {
    data class OwnerSnapshot(
        val admission: CellularAdmissionView,
        val rootPolicy: RootPolicyStatus,
    ) : CellularRuntimeSnapshot

    data class BoundaryUnavailable(
        val reason: CellularBoundaryFailure,
    ) : CellularRuntimeSnapshot
}

/**
 * One process-generation bridge between Android Network observations and the Rust owner.
 *
 * Cellular semantics remain in Rust. This class owns foreign-handle/observer lifetime,
 * a serialized adapter executor, ephemeral interface hints, and a read-only StateFlow.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    private val observer = CellularNetworkObserver(context.applicationContext, this)
    private val rootPolicy = RootPolicyExecutor()
    private val productUid = Process.myUid()
    private val adapterExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "mish-cellular-policy").apply { isDaemon = true }
    }
    private val interfacesByHandle = mutableMapOf<Long, String>()

    @Volatile
    private var started = false

    @Volatile
    private var closed = false

    val snapshot: StateFlow<CellularRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    init {
        var createdController: CellularController? = null
        val initialSnapshot = try {
            createdController = CellularController()
            CellularRuntimeSnapshot.OwnerSnapshot(
                admission = createdController.admissionSnapshot(),
                rootPolicy = RootPolicyStatus.NotReconciled,
            )
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

    @Synchronized
    fun start() {
        if (started || closed) return
        started = true

        // Establish the PRODUCT fail-closed guard before asking Android to produce an
        // admitted cellular generation. The first positive lookup is added only later.
        reconcileStartup()
        if (controller != null) {
            observer.start()
        }
    }

    /** Idempotent boot/start reconciliation entry point; it never invents admission. */
    fun reconcileStartup() {
        enqueuePolicyIntent(
            RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.Startup),
        )
    }

    override fun onEvent(event: CellularNetworkEvent) {
        if (closed) return
        adapterExecutor.execute { processEvent(event) }
    }

    private fun processEvent(event: CellularNetworkEvent) {
        val activeController = controller ?: run {
            rootPolicy.reconcile(
                productUid,
                RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.OwnerBoundaryUnavailable),
            )
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            return
        }

        try {
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

            val previousPolicy = (mutableSnapshot.value as? CellularRuntimeSnapshot.OwnerSnapshot)
                ?.rootPolicy ?: RootPolicyStatus.NotReconciled

            // The Rust owner ignores stale/reordered events. Such an event must not be
            // allowed to mutate adapter state after a newer owner generation is active.
            val isFreshOwnerEvent = admission.lastSequence?.toLong() == event.sequence
            if (!isFreshOwnerEvent) {
                mutableSnapshot.value = CellularRuntimeSnapshot.OwnerSnapshot(
                    admission = admission,
                    rootPolicy = previousPolicy,
                )
                return
            }

            when (event) {
                is CellularNetworkEvent.Observed -> {
                    val interfaceName = event.interfaceName
                    if (interfaceName != null) {
                        interfacesByHandle[event.networkHandle] = interfaceName
                    }
                }

                is CellularNetworkEvent.Lost -> interfacesByHandle.remove(event.networkHandle)
            }

            val intent = ownerIntent(admission)
            val policy = rootPolicy.reconcile(productUid, intent)
            mutableSnapshot.value = CellularRuntimeSnapshot.OwnerSnapshot(
                admission = admission,
                rootPolicy = policy,
            )
        } catch (_: LinkageError) {
            rootPolicy.reconcile(
                productUid,
                RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.OwnerBoundaryUnavailable),
            )
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            rootPolicy.reconcile(
                productUid,
                RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.OwnerBoundaryUnavailable),
            )
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }
    }

    private fun ownerIntent(admission: CellularAdmissionView): RootPolicyIntent {
        if (admission.state != CellularAdmissionState.ADMITTED) {
            return RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.NoAdmittedNetwork)
        }

        val networkHandle = admission.admittedNetworkHandle?.toLong()
        val generation = admission.lastSequence?.toLong()
        val interfaceName = networkHandle?.let(interfacesByHandle::get)
        return if (networkHandle != null && generation != null && interfaceName != null) {
            RootPolicyIntent.Admitted(
                generation = generation,
                interfaceName = interfaceName,
            )
        } else {
            RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.MissingInterface)
        }
    }

    private fun enqueuePolicyIntent(intent: RootPolicyIntent) {
        if (closed || adapterExecutor.isShutdown) return
        adapterExecutor.execute {
            val status = rootPolicy.reconcile(productUid, intent)
            val current = mutableSnapshot.value
            if (current is CellularRuntimeSnapshot.OwnerSnapshot) {
                mutableSnapshot.value = current.copy(rootPolicy = status)
            }
        }
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        observer.close()

        // Closing the Android bridge is not permission to remove the kernel guard. Keep
        // the PRODUCT mark fail-closed; explicit maintenance cleanup is a separate API.
        adapterExecutor.execute {
            rootPolicy.reconcile(
                productUid,
                RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.NoAdmittedNetwork),
            )
        }
        adapterExecutor.shutdown()
    }
}
