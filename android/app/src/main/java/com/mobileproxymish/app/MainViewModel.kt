package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.RootPolicyFailureView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

internal sealed interface CredentialRevealUiState {
    data object Hidden : CredentialRevealUiState
    data object Unavailable : CredentialRevealUiState

    class Revealed(
        val version: ULong,
        val username: String,
        val password: String,
    ) : CredentialRevealUiState {
        override fun toString(): String =
            "CredentialRevealUiState.Revealed(version=$version,<redacted>)"
    }
}

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
    private val mutableCredentialReveal =
        MutableStateFlow<CredentialRevealUiState>(CredentialRevealUiState.Hidden)

    internal val credentialReveal: StateFlow<CredentialRevealUiState>
        get() = mutableCredentialReveal.asStateFlow()

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

    fun showCurrentCredentials() {
        val current = runtimeController.revealCurrentExternalCredential()
        mutableCredentialReveal.value = if (current == null) {
            CredentialRevealUiState.Unavailable
        } else {
            CredentialRevealUiState.Revealed(
                version = current.version,
                username = current.credentials.username,
                password = current.credentials.password,
            )
        }
    }

    fun hideCurrentCredentials() {
        mutableCredentialReveal.value = CredentialRevealUiState.Hidden
    }

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

    private fun rootPolicyReasonCode(reason: RootPolicyFailureView): String = when (reason) {
        RootPolicyFailureView.INVALID_INTERFACE ->
            "cellular.root_policy_invalid_interface"
        RootPolicyFailureView.RESERVED_POLICY_COLLISION ->
            "cellular.root_policy_reserved_policy_collision"
        RootPolicyFailureView.OBSERVATION_UNAVAILABLE ->
            "cellular.root_policy_observation_unavailable"
        RootPolicyFailureView.OBSERVATION_INCOMPLETE ->
            "cellular.root_policy_observation_incomplete"
        RootPolicyFailureView.STRUCTURAL_MISMATCH ->
            "cellular.root_policy_structural_mismatch"
        RootPolicyFailureView.ROUTE_TABLE_DISCOVERY_FAILED ->
            "cellular.root_policy_route_table_discovery_failed"
        RootPolicyFailureView.MUTATION_REJECTED ->
            "cellular.root_policy_mutation_rejected"
        RootPolicyFailureView.MUTATION_UNCERTAIN ->
            "cellular.root_policy_mutation_uncertain"
        RootPolicyFailureView.LOOKUP_RULE_CREATION_FAILED ->
            "cellular.root_policy_lookup_rule_creation_failed"
        RootPolicyFailureView.ROUTE_LOOKUP_VERIFICATION_FAILED ->
            "cellular.root_policy_route_lookup_verification_failed"
        RootPolicyFailureView.EXACT_CLEANUP_FAILED ->
            "cellular.root_policy_exact_cleanup_failed"
    }

    private fun proxyReasonCode(reason: ProxyServingFailure): String = when (reason) {
        ProxyServingFailure.NATIVE_RUNTIME_MISSING -> "proxy.native_runtime_missing"
        ProxyServingFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE ->
            "proxy.external_credential_unavailable"
        ProxyServingFailure.CELLULAR_CONNECTOR_UNAVAILABLE ->
            "proxy.cellular_connector_unavailable"
        ProxyServingFailure.PROXY_CONFIGURATION_REJECTED ->
            "proxy.configuration_rejected"
        ProxyServingFailure.MIXED_LISTENER_UNAVAILABLE ->
            "proxy.mixed_listener_unavailable"
        ProxyServingFailure.SOCKS5_LISTENER_UNAVAILABLE ->
            "proxy.socks5_listener_unavailable"
        ProxyServingFailure.HTTP_CONNECT_LISTENER_UNAVAILABLE ->
            "proxy.http_connect_listener_unavailable"
        ProxyServingFailure.EXECUTOR_UNAVAILABLE -> "proxy.executor_unavailable"
        ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE -> "proxy.runtime_state_unavailable"
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
