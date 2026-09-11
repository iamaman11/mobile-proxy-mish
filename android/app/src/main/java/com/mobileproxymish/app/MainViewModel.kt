package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRootPolicyFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

data class MainUiState(
    val title: String = "Mobile Proxy MISH",
    val overallStatus: String = "Overall readiness — not implemented",
    val cellularState: String = "Unknown",
    val cellularReasonCode: String? = "cellular.no_observation",
)

/** Presentation projection only; it neither owns nor mutates cellular state. */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val cellularRuntime = (application as MishApplication).cellularRuntime

    val state: StateFlow<MainUiState> = cellularRuntime.snapshot
        .map(::toUiState)
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = toUiState(cellularRuntime.snapshot.value),
        )

    private fun toUiState(snapshot: CellularRuntimeSnapshot): MainUiState = when (snapshot) {
        is CellularRuntimeSnapshot.BoundaryUnavailable -> MainUiState(
            cellularState = "Unknown",
            cellularReasonCode = boundaryReasonCode(snapshot.reason),
        )

        is CellularRuntimeSnapshot.OwnerSnapshot -> MainUiState(
            cellularState = when (snapshot.admission.state) {
                CellularAdmissionState.UNKNOWN -> "Unknown"
                CellularAdmissionState.NOT_ADMITTED -> "Not admitted"
                CellularAdmissionState.ADMITTED -> "Admitted"
            },
            cellularReasonCode = snapshot.admission.reason?.let(::reasonCode),
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

    private fun reasonCode(reason: CellularAdmissionReason): String = when (reason) {
        CellularAdmissionReason.NO_OBSERVATION -> "cellular.no_observation"
        CellularAdmissionReason.NOT_CELLULAR -> "cellular.not_cellular"
        CellularAdmissionReason.MISSING_INTERNET_CAPABILITY -> "cellular.missing_internet_capability"
        CellularAdmissionReason.VPN_DERIVED_NETWORK -> "cellular.vpn_derived_network"
        CellularAdmissionReason.NOT_VALIDATED -> "cellular.not_validated"
        CellularAdmissionReason.NETWORK_LOST -> "cellular.network_lost"
    }
}
