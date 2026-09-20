package com.mobileproxymish.app

import android.content.Context
import android.content.pm.ApplicationInfo
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.NativeCellularRequestRearmEffect
import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.ProductDiagnosticSnapshotView
import com.mobileproxymish.ffi.NativeReadinessObserver
import com.mobileproxymish.ffi.NativeRotationObserver
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyListenerView
import com.mobileproxymish.ffi.RotationSnapshotView
import com.mobileproxymish.ffi.RuntimeLifecycleState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Android platform facade around one stable Rust-owned PRODUCT process handle.
 *
 * Rust owns lifecycle state, generation identity/replacement, Proxy recovery and native drain.
 * Android only supplies bounded platform credential material and starts/stops Android framework
 * observers for the foreground-Service lifetime.
 */
class MishRuntimeController internal constructor(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val externalCredentialStore = ExternalProxyCredentialStore(appContext)
    private val platformEffectsLock = Any()
    private val debugIsolation = appContext.packageName.endsWith(".debug") &&
        (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private val productRuntime = NativeProductRuntime(
        appContext.applicationInfo.uid.toUInt(),
        debugIsolation,
    )
    private val cellularRuntime = CellularRuntimeBridge(appContext, productRuntime)
    private val proxyRuntime = ProxyRuntimeSupervisor(productRuntime)
    private val meshRuntime = MeshIngressRuntimeBridge(appContext, productRuntime)
    private val mutableReadiness = MutableStateFlow(productRuntime.readinessSnapshot())
    private val mutableRotation = MutableStateFlow(productRuntime.rotationSnapshot())

    init {
        productRuntime.observeReadiness(
            object : NativeReadinessObserver {
                override fun onReadiness(readiness: ProductReadinessState) {
                    mutableReadiness.value = readiness
                }
            },
        )
        productRuntime.observeRotation(
            object : NativeRotationObserver {
                override fun onRotation(snapshot: RotationSnapshotView) {
                    mutableRotation.value = snapshot
                }
            },
        )
    }

    val cellularSnapshot: StateFlow<CellularRuntimeSnapshot>
        get() = cellularRuntime.snapshot

    val proxySnapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = proxyRuntime.snapshot

    val readinessSnapshot: StateFlow<ProductReadinessState>
        get() = mutableReadiness.asStateFlow()

    val rotationSnapshot: StateFlow<RotationSnapshotView>
        get() = mutableRotation.asStateFlow()

    /** Read-only Transport Reachability projection for UI and retained device diagnostics. */
    val meshSnapshot: StateFlow<MeshAdmissionView?>
        get() = meshRuntime.snapshot

    internal val currentCellularRuntime: CellularRuntimeBridge
        get() = cellularRuntime

    internal val currentProxyRuntime: ProxyRuntimeSupervisor
        get() = proxyRuntime

    internal val currentMeshRuntime: MeshIngressRuntimeBridge
        get() = meshRuntime

    /** Read-only bounded snapshot for the permission-gated Windows provisioning transaction. */
    internal fun currentExternalCredentialProvisioningSnapshot(): ExternalProxyCredentialSnapshot? =
        externalCredentialStore.currentProvisioningSnapshot()

    /** Explicit sensitive user read. It never rotates, provisions or restarts the runtime. */
    internal fun revealCurrentExternalCredential(): ExternalProxyCredentialSnapshot? =
        externalCredentialStore.revealCurrentCredential()

    /** One immutable Rust-composed PRODUCT diagnostic snapshot. */
    internal fun diagnosticSnapshot(): ProductDiagnosticSnapshotView =
        productRuntime.diagnosticSnapshot()

    internal fun proxyListenerContract(): List<ProxyListenerView> =
        productRuntime.proxyListenerContract()

    /** Thin PRODUCT command seam. Rust owns the operation, sequencing, effects and result. */
    internal fun startPublicIpRotation(): ULong =
        productRuntime.startPublicIpRotation(
            object : NativeCellularRequestRearmEffect {
                override fun rearmCellularRequest(): Boolean =
                    cellularRuntime.rearmNetworkRequest()
            },
        )

    val isRunning: Boolean
        get() = productRuntime.runtimeLifecycleSnapshot().state != RuntimeLifecycleState.STOPPED

    fun start(): Boolean = synchronized(platformEffectsLock) {
        val credential = runCatching { externalCredentialStore.currentCredentialForRuntime() }.getOrNull()
        val accepted = runCatching {
            productRuntime.startRuntime(
                credentialVersion = credential?.version,
                username = credential?.credentials?.username,
                password = credential?.credentials?.password,
            )
        }.isSuccess
        if (!accepted) return@synchronized false

        try {
            cellularRuntime.start()
            meshRuntime.start()
            true
        } catch (_: Exception) {
            runCatching(meshRuntime::stop)
            runCatching(cellularRuntime::stop)
            runCatching { productRuntime.stopRuntime() }
            false
        }
    }

    fun stop(): Boolean = synchronized(platformEffectsLock) {
        // Rust must enter STOPPING before platform observation is removed, so a concurrent start
        // can only become the native queued-restart decision rather than observe stale RUNNING.
        val nativeAccepted = runCatching { productRuntime.stopRuntime() }.isSuccess
        var platformClean = true
        if (runCatching(meshRuntime::stop).isFailure) platformClean = false
        if (runCatching(cellularRuntime::stop).isFailure) platformClean = false
        platformClean && nativeAccepted
    }

    internal fun rotateExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::rotateWhileStopped)

    internal fun revokeExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::revokeWhileStopped)

    private fun mutateExternalCredentialWhileStopped(mutation: () -> Boolean): Boolean =
        synchronized(platformEffectsLock) {
            val lease = runCatching {
                productRuntime.beginStoppedPlatformMutation()
            }.getOrNull() ?: return@synchronized false

            val succeeded = runCatching(mutation).getOrDefault(false)
            runCatching {
                productRuntime.completeStoppedPlatformMutation(
                    lease = lease,
                    succeeded = succeeded,
                )
            }.getOrDefault(false)
        }

    /** Final process cleanup seam retained for instrumentation; Service stop uses stop(), not this. */
    internal fun shutdownProcessExact(): Boolean = synchronized(platformEffectsLock) {
        var clean = true
        if (runCatching(meshRuntime::close).isFailure) clean = false
        if (runCatching(cellularRuntime::close).isFailure) clean = false
        if (runCatching { productRuntime.shutdown() }.isFailure) clean = false
        clean
    }
}
