package com.mobileproxymish.app.cellular

import android.content.Context
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularController
import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
 * admitted or ready cellular path. `rootPolicyFailure` is diagnostic adapter metadata,
 * not a second admission/readiness fact.
 */
sealed interface CellularRuntimeSnapshot {
    data class OwnerSnapshot(
        val admission: CellularAdmissionView,
    ) : CellularRuntimeSnapshot

    data class BoundaryUnavailable(
        val reason: CellularBoundaryFailure,
        val rootPolicyFailure: CellularRootPolicyFailure? = null,
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
    private val byNetwork = mutableMapOf<ULong, String>()

    fun observed(networkHandle: ULong, interfaceName: String?) {
        // A synchronous getLinkProperties() can transiently return null during a
        // capability callback. Do not erase an already observed interface for the same
        // exact Network generation; onLost is the authoritative lifetime revocation.
        if (interfaceName != null) {
            byNetwork[networkHandle] = interfaceName
        }
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
 *
 * Root process operations run on one private serial executor. They can legitimately
 * wait for a bounded Magisk decision or shell timeout and therefore must never block
 * Application.onCreate(), the UI thread, or a ConnectivityManager callback thread.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    private val rootPolicy = CellularRootPolicy(Process.myUid())
    private val interfaceHints = CellularInterfaceHints()
    private val observer = CellularNetworkObserver(context.applicationContext, this)
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val policyExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-cellular-policy").apply { isDaemon = true }
    }

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
        if (controller == null || closed.get() || !started.compareAndSet(false, true)) return

        submitPolicyWork {
            if (closed.get()) return@submitPolicyWork

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
                            reason = CellularBoundaryFailure.RootPolicyReconcileFailed,
                            rootPolicyFailure = initialPolicy.reason,
                        )
                    }
                }

                CellularRootPolicyResult.Enforced -> mutableSnapshot.value
            }

            if (!closed.get()) {
                observer.start()
                // close() can race between the check above and requestNetwork(). If it
                // did, revoke the just-created callback immediately rather than leaving
                // an observer alive after policy cleanup/executor shutdown.
                if (closed.get()) {
                    observer.close()
                }
            }
        }
    }

    override fun onEvent(event: CellularNetworkEvent) {
        if (closed.get()) return
        submitPolicyWork {
            if (!closed.get()) {
                processEvent(event)
            }
        }
    }

    private fun processEvent(event: CellularNetworkEvent) {
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
            // happened to arrive most recently. If the callback-time LinkProperties read
            // was transiently null, resolve the interface read-only from that exact handle.
            val admittedHandle = admission.admittedNetworkHandle
            var interfaceName = interfaceHints.interfaceFor(admittedHandle)
            if (interfaceName == null && admittedHandle != null) {
                interfaceName = observer.interfaceNameFor(admittedHandle)
                interfaceHints.observed(admittedHandle, interfaceName)
            }

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
                            reason = CellularBoundaryFailure.RootPolicyReconcileFailed,
                            rootPolicyFailure = policyResult.reason,
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

    private fun submitPolicyWork(block: () -> Unit) {
        try {
            policyExecutor.execute(block)
        } catch (_: RejectedExecutionException) {
            // close() owns executor shutdown. Work racing with closure is intentionally
            // dropped because the observer is already being revoked and exact cleanup
            // is serialized as the final executor effect.
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        observer.close()
        val cleanup = try {
            policyExecutor.submit {
                interfaceHints.clear()
                rootPolicy.cleanupExactOwnedRules()
            }
        } catch (_: RejectedExecutionException) {
            null
        }

        if (cleanup != null) {
            try {
                cleanup.get(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: Exception) {
                // E3 independently verifies the exact kernel post-condition. A future
                // process start also reconciles fail-closed before observation resumes.
            }
        }
        policyExecutor.shutdownNow()
    }

    private companion object {
        // Includes one potentially in-flight bounded root reconciliation plus the final
        // exact cleanup transaction. This is a shutdown-only path, never UI/callback work.
        const val CLOSE_TIMEOUT_SECONDS = 60L
    }
}
