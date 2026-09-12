package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRootPolicyFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.RuntimeProcessFailure
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

data class MainUiState(
    val title: String = "Mobile Proxy MISH",
    val overallStatus: String = "Overall readiness — production acceptance pending",
    val cellularState: String = "Unknown",
    val cellularReasonCode: String? = "cellular.no_observation",
    val proxyState: String = "Stopped",
    val proxyReasonCode: String? = null,
)

/** Presentation projection only; it neither owns nor mutates cellular/proxy runtime state. */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as MishApplication
    private val runtimeController = app.runtimeController

    val state: StateFlow<MainUiState> = combine(
        runtimeController.cellularSnapshot,
        runtimeController.proxySnapshot,
        ::toUiState,
    ).stateIn(
        scope = viewModelScope,
        started = SharingStarted.Eagerly,
        initialValue = toUiState(
            runtimeController.cellularSnapshot.value,
            runtimeController.proxySnapshot.value,
        ),
    )

    private fun toUiState(
        cellular: CellularRuntimeSnapshot,
        proxy: ProxyRuntimeSnapshot,
    ): MainUiState {
        val cellularProjection = when (cellular) {
            is CellularRuntimeSnapshot.BoundaryUnavailable -> Pair(
                "Unknown",
                boundaryReasonCode(cellular.reason),
            )
            is CellularRuntimeSnapshot.OwnerSnapshot -> Pair(
                when (cellular.admission.state) {
                    CellularAdmissionState.UNKNOWN -> "Unknown"
                    CellularAdmissionState.NOT_ADMITTED -> "Not admitted"
                    CellularAdmissionState.ADMITTED -> "Admitted"
                },
                cellular.admission.reason?.let(::reasonCode),
            )
        }
        val proxyProjection = when (proxy) {
            ProxyRuntimeSnapshot.Stopped -> Pair("Stopped", null)
            ProxyRuntimeSnapshot.Starting -> Pair("Starting", null)
            ProxyRuntimeSnapshot.Running -> Pair("Running (loopback acceptance only)", null)
            is ProxyRuntimeSnapshot.Failed -> Pair("Failed", proxyReasonCode(proxy.reason))
        }
        return MainUiState(
            cellularState = cellularProjection.first,
            cellularReasonCode = cellularProjection.second,
            proxyState = proxyProjection.first,
            proxyReasonCode = proxyProjection.second,
        )
    }

    private fun boundaryReasonCode(reason: CellularBoundaryFailure): String = when (reason) {
        CellularBoundaryFailure.NativeLibraryUnavailable ->
            "android_ffi.native_library_unavailable"
        CellularBoundaryFailure.ForeignCallFailed -> "android_ffi.foreign_call_failed"
        CellularBoundaryFailure.RootAuthorityUnavailable ->
            "cellular.root_authority_unavailable"
        CellularBoundaryFailure.RootPolicyReconcileFailed ->
            "cellular.root_policy_reconcile_failed"
        CellularBoundaryFailure.RootPolicyGenerationChanged ->
            "cellular.root_policy_generation_changed"
        CellularBoundaryFailure.RootPolicyCleanupFailed ->
            "cellular.root_policy_cleanup_failed"
        is CellularBoundaryFailure.RootPolicyUnavailable ->
            rootPolicyReasonCode(reason.failure)
    }

    private fun rootPolicyReasonCode(reason: CellularRootPolicyFailure): String = when (reason) {
        CellularRootPolicyFailure.InvalidProductUid -> "cellular.root_policy_invalid_product_uid"
        CellularRootPolicyFailure.InvalidInterface -> "cellular.root_policy_invalid_interface"
        CellularRootPolicyFailure.ReservedPolicyCollision ->
            "cellular.root_policy_reserved_policy_collision"
        CellularRootPolicyFailure.RouteTableDiscoveryFailed ->
            "cellular.root_policy_route_table_discovery_failed"
        CellularRootPolicyFailure.RuleMutationFailed ->
            "cellular.root_policy_rule_mutation_failed"
        CellularRootPolicyFailure.VerificationFailed ->
            "cellular.root_policy_verification_failed"
    }

    private fun proxyReasonCode(reason: RuntimeProcessFailure): String = when (reason) {
        RuntimeProcessFailure.NATIVE_RUNTIME_MISSING -> "proxy.native_runtime_missing"
        RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH ->
            "proxy.stale_process_identity_mismatch"
        RuntimeProcessFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE ->
            "proxy.external_credential_unavailable"
        RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE -> "proxy.private_bridge_unavailable"
        RuntimeProcessFailure.CONFIGURATION_REJECTED -> "proxy.configuration_rejected"
        RuntimeProcessFailure.CHILD_LAUNCH_FAILED -> "proxy.child_launch_failed"
        RuntimeProcessFailure.HEALTH_CHECK_FAILED -> "proxy.health_check_failed"
        RuntimeProcessFailure.CHILD_EXITED -> "proxy.child_exited"
        RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY -> "proxy.private_bridge_unhealthy"
        RuntimeProcessFailure.CLEANUP_FAILED -> "proxy.cleanup_failed"
    }

    private fun reasonCode(reason: CellularAdmissionReason): String = when (reason) {
        CellularAdmissionReason.NO_OBSERVATION -> "cellular.no_observation"
        CellularAdmissionReason.NOT_CELLULAR -> "cellular.not_cellular"
        CellularAdmissionReason.MISSING_INTERNET_CAPABILITY -> "cellular.missing_internet_capability"
        CellularAdmissionReason.VPN_DERIVED_NETWORK -> "cellular.vpn_derived_network"
        CellularAdmissionReason.NOT_VALIDATED -> "cellular.not_validated"
        CellularAdmissionReason.NETWORK_LOST -> "cellular.network_lost"
    }
}
