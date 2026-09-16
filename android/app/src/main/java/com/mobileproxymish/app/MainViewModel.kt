package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRootPolicyFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyServingFailure
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

data class MainUiState(
    val title: String = "Mobile Proxy MISH",
    val overallStatus: String = readinessStatus(ProductReadinessState.UNKNOWN),
    val cellularState: String = "Unknown",
    val cellularReasonCode: String? = "cellular.no_observation",
    val proxyState: String = "Stopped",
    val proxyReasonCode: String? = null,
)

/** Presentation wording only. The input value is the Rust readiness projection itself. */
internal fun readinessStatus(readiness: ProductReadinessState): String = when (readiness) {
    ProductReadinessState.READY ->
        "Overall readiness — READY (runtime projection; production acceptance pending)"
    ProductReadinessState.NOT_READY ->
        "Overall readiness — NOT_READY (runtime projection; production acceptance pending)"
    ProductReadinessState.DEGRADED ->
        "Overall readiness — DEGRADED (runtime projection; production acceptance pending)"
    ProductReadinessState.UNKNOWN ->
        "Overall readiness — UNKNOWN (runtime projection; production acceptance pending)"
}

/** Presentation projection only; it neither owns nor mutates cellular/proxy/readiness state. */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as MishApplication
    private val runtimeController = app.runtimeController

    val state: StateFlow<MainUiState> = combine(
        runtimeController.cellularSnapshot,
        runtimeController.proxySnapshot,
        runtimeController.readinessSnapshot,
        ::toUiState,
    ).stateIn(
        scope = viewModelScope,
        started = SharingStarted.Eagerly,
        initialValue = toUiState(
            runtimeController.cellularSnapshot.value,
            runtimeController.proxySnapshot.value,
            runtimeController.readinessSnapshot.value,
        ),
    )

    private fun toUiState(
        cellular: CellularRuntimeSnapshot,
        proxy: ProxyRuntimeSnapshot,
        readiness: ProductReadinessState,
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
            overallStatus = readinessStatus(readiness),
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
        CellularRootPolicyFailure.MangleChainCreationFailed ->
            "cellular.root_policy_mangle_chain_creation_failed"
        CellularRootPolicyFailure.OwnerNewMarkRuleFailed ->
            "cellular.root_policy_owner_new_mark_rule_failed"
        CellularRootPolicyFailure.OutputJumpCreationFailed ->
            "cellular.root_policy_output_jump_creation_failed"
        CellularRootPolicyFailure.MangleVerificationFailed ->
            "cellular.root_policy_mangle_verification_failed"
        CellularRootPolicyFailure.LookupRuleCreationFailed ->
            "cellular.root_policy_lookup_rule_creation_failed"
        CellularRootPolicyFailure.RouteLookupVerificationFailed ->
            "cellular.root_policy_route_lookup_verification_failed"
        CellularRootPolicyFailure.ExactCleanupFailed ->
            "cellular.root_policy_exact_cleanup_failed"
    }

    private fun proxyReasonCode(reason: ProxyServingFailure): String = when (reason) {
        ProxyServingFailure.NATIVE_RUNTIME_MISSING -> "proxy.native_runtime_missing"
        ProxyServingFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE ->
            "proxy.external_credential_unavailable"
        ProxyServingFailure.LISTENER_UNAVAILABLE -> "proxy.listener_unavailable"
        ProxyServingFailure.SERVING_UNHEALTHY -> "proxy.serving_unhealthy"
        ProxyServingFailure.SHUTDOWN_FAILED -> "proxy.shutdown_failed"
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
