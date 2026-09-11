package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
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
            cellularReasonCode = when (snapshot.reason) {
                CellularBoundaryFailure.NativeLibraryUnavailable ->
                    "android_ffi.native_library_unavailable"
                CellularBoundaryFailure.ForeignCallFailed -> "android_ffi.foreign_call_failed"
                CellularBoundaryFailure.RootAuthorityUnavailable ->
                    "cellular.root_authority_unavailable"
                CellularBoundaryFailure.RootPolicyReconcileFailed ->
                    "cellular.root_policy_reconcile_failed"
            },
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

    private fun reasonCode(reason: CellularAdmissionReason): String = when (reason) {
        CellularAdmissionReason.NO_OBSERVATION -> "cellular.no_observation"
        CellularAdmissionReason.NOT_CELLULAR -> "cellular.not_cellular"
        CellularAdmissionReason.MISSING_INTERNET_CAPABILITY -> "cellular.missing_internet_capability"
        CellularAdmissionReason.VPN_DERIVED_NETWORK -> "cellular.vpn_derived_network"
        CellularAdmissionReason.NOT_VALIDATED -> "cellular.not_validated"
        CellularAdmissionReason.NETWORK_LOST -> "cellular.network_lost"
    }
}
