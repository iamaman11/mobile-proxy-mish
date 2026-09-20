package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionReason
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyListenerView
import com.mobileproxymish.ffi.ProxyProtocolView
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.RotationFailureView
import com.mobileproxymish.ffi.RotationPhaseView
import com.mobileproxymish.ffi.RotationSnapshotView
import com.mobileproxymish.ffi.RotationTerminalResultView

enum class ProductOverallUiState { READY, DEGRADED, NOT_READY, UNKNOWN }

enum class ProductCauseUi {
    READY,
    CHECKING_CONNECTIVITY,
    PUBLIC_CONNECTION_DEGRADED,
    MOBILE_NETWORK_NOT_READY,
    MOBILE_NETWORK_RECOVERING,
    ROOT_AUTHORIZATION_UNAVAILABLE,
    ROOT_POLICY_FAILED,
    PROXY_UNAVAILABLE,
    MESH_UNAVAILABLE,
    PRODUCT_NOT_READY,
}

enum class ComponentHealthUi { READY, RECOVERING, WAITING, NOT_READY, UNKNOWN }

enum class RotationStageUi {
    IDLE,
    STARTING,
    DISCONNECTING_CELLULAR,
    WAITING_FOR_CELLULAR_DISCONNECT,
    RESTORING_RADIO,
    WAITING_FOR_CELLULAR_RECOVERY,
    APPLYING_NETWORK_POLICY,
    CHECKING_PUBLIC_IP,
    COMPLETE,
}

enum class RotationResultUi { CHANGED, UNCHANGED, FAILED }

enum class RotationFailureUi {
    RUNTIME_NOT_RUNNING,
    NO_CURRENT_CELLULAR,
    ROOT_POLICY_UNAVAILABLE,
    BEFORE_IP_FAILED,
    AIRPLANE_ENABLE_FAILED,
    AIRPLANE_OBSERVATION_FAILED,
    AIRPLANE_DISABLE_FAILED,
    FRESH_CELLULAR_UNAVAILABLE,
    ROOT_POLICY_RECOVERY_FAILED,
    AFTER_IP_FAILED,
    CREDENTIAL_CHANGED,
    DEADLINE_EXCEEDED,
    STATE_UNAVAILABLE,
}

enum class ProxyProtocolUi { MIXED, SOCKS5, HTTP_CONNECT }

data class PublicIpUiState(
    val current: String? = null,
    val previous: String? = null,
)

data class RotationUiState(
    val operationId: ULong? = null,
    val stage: RotationStageUi = RotationStageUi.IDLE,
    val inProgress: Boolean = false,
    val result: RotationResultUi? = null,
    val failure: RotationFailureUi? = null,
    val beforeGeneration: ULong? = null,
    val afterGeneration: ULong? = null,
)

data class HealthSummaryUiState(
    val cellular: ComponentHealthUi = ComponentHealthUi.UNKNOWN,
    val rootPolicy: ComponentHealthUi = ComponentHealthUi.UNKNOWN,
    val proxy: ComponentHealthUi = ComponentHealthUi.UNKNOWN,
    val mesh: ComponentHealthUi = ComponentHealthUi.UNKNOWN,
)

data class ProxyListenerUi(
    val protocol: ProxyProtocolUi,
    val port: Int,
)

data class ProxyEndpointUiState(
    val endpoint: String? = null,
    val listeners: List<ProxyListenerUi> = emptyList(),
)

data class AdvancedDiagnosticsUiState(
    val technicalReason: String? = null,
    val cellularOwnerSequence: ULong? = null,
    val meshObservationSequence: ULong? = null,
    val meshAdmissionEpoch: ULong? = null,
    val rotationOperationId: ULong? = null,
    val rotationBeforeGeneration: ULong? = null,
    val rotationAfterGeneration: ULong? = null,
)

data class ProductUiState(
    val overall: ProductOverallUiState = ProductOverallUiState.UNKNOWN,
    val cause: ProductCauseUi = ProductCauseUi.CHECKING_CONNECTIVITY,
    val publicIp: PublicIpUiState = PublicIpUiState(),
    val rotation: RotationUiState = RotationUiState(),
    val health: HealthSummaryUiState = HealthSummaryUiState(),
    val proxyEndpoint: ProxyEndpointUiState = ProxyEndpointUiState(),
    val advancedDiagnostics: AdvancedDiagnosticsUiState = AdvancedDiagnosticsUiState(),
) {
    val changeIpEnabled: Boolean
        get() = overall == ProductOverallUiState.READY && !rotation.inProgress
}

internal data class ProductPresentationInput(
    val readiness: ProductReadinessState,
    val cellular: CellularRuntimeSnapshot,
    val proxy: ProxyRuntimeSnapshot,
    val mesh: MeshAdmissionView?,
    val rotation: RotationSnapshotView,
    val proxyListeners: List<ProxyListenerView>,
)

internal fun projectProductUi(input: ProductPresentationInput): ProductUiState {
    val overall = input.readiness.toUi()
    val rotation = input.rotation.toUi()
    val health = projectHealth(input.cellular, input.proxy, input.mesh, rotation.inProgress)
    return ProductUiState(
        overall = overall,
        cause = projectCause(
            overall = overall,
            cellular = input.cellular,
            proxy = input.proxy,
            mesh = input.mesh,
            rotationInProgress = rotation.inProgress,
        ),
        publicIp = PublicIpUiState(
            current = if (rotation.inProgress) null else input.rotation.afterIp,
            previous = input.rotation.beforeIp,
        ),
        rotation = rotation,
        health = health,
        proxyEndpoint = ProxyEndpointUiState(
            endpoint = input.mesh
                ?.takeIf { it.state == MeshAdmissionState.ADMITTED }
                ?.endpoint,
            listeners = input.proxyListeners.map { it.toUi() },
        ),
        advancedDiagnostics = AdvancedDiagnosticsUiState(
            technicalReason = firstTechnicalReason(input.cellular, input.proxy, input.mesh),
            cellularOwnerSequence = (input.cellular as? CellularRuntimeSnapshot.OwnerSnapshot)
                ?.admission
                ?.lastSequence,
            meshObservationSequence = input.mesh?.lastSequence,
            meshAdmissionEpoch = input.mesh?.admissionEpoch,
            rotationOperationId = input.rotation.operationId,
            rotationBeforeGeneration = input.rotation.beforeGeneration,
            rotationAfterGeneration = input.rotation.afterGeneration,
        ),
    )
}

private fun ProductReadinessState.toUi(): ProductOverallUiState = when (this) {
    ProductReadinessState.READY -> ProductOverallUiState.READY
    ProductReadinessState.DEGRADED -> ProductOverallUiState.DEGRADED
    ProductReadinessState.NOT_READY -> ProductOverallUiState.NOT_READY
    ProductReadinessState.UNKNOWN -> ProductOverallUiState.UNKNOWN
}

private fun RotationSnapshotView.toUi(): RotationUiState {
    val active = when (phase) {
        RotationPhaseView.IDLE,
        RotationPhaseView.CHANGED,
        RotationPhaseView.UNCHANGED,
        RotationPhaseView.FAILED,
        -> false
        else -> true
    }
    return RotationUiState(
        operationId = operationId,
        stage = when (phase) {
            RotationPhaseView.IDLE -> RotationStageUi.IDLE
            RotationPhaseView.PREPARING -> RotationStageUi.STARTING
            RotationPhaseView.AIRPLANE_ENABLING -> RotationStageUi.DISCONNECTING_CELLULAR
            RotationPhaseView.WAITING_RADIO_DOWN ->
                RotationStageUi.WAITING_FOR_CELLULAR_DISCONNECT
            RotationPhaseView.AIRPLANE_DISABLING -> RotationStageUi.RESTORING_RADIO
            RotationPhaseView.WAITING_CELLULAR_RECOVERY ->
                RotationStageUi.WAITING_FOR_CELLULAR_RECOVERY
            RotationPhaseView.WAITING_ROOT_POLICY -> RotationStageUi.APPLYING_NETWORK_POLICY
            RotationPhaseView.PROBING_PUBLIC_IP -> RotationStageUi.CHECKING_PUBLIC_IP
            RotationPhaseView.CHANGED,
            RotationPhaseView.UNCHANGED,
            RotationPhaseView.FAILED,
            -> RotationStageUi.COMPLETE
        },
        inProgress = active,
        result = terminalResult?.let {
            when (it) {
                RotationTerminalResultView.CHANGED -> RotationResultUi.CHANGED
                RotationTerminalResultView.UNCHANGED -> RotationResultUi.UNCHANGED
                RotationTerminalResultView.FAILED -> RotationResultUi.FAILED
            }
        },
        failure = failure?.toUi(),
        beforeGeneration = beforeGeneration,
        afterGeneration = afterGeneration,
    )
}

private fun RotationFailureView.toUi(): RotationFailureUi = when (this) {
    RotationFailureView.RUNTIME_NOT_RUNNING -> RotationFailureUi.RUNTIME_NOT_RUNNING
    RotationFailureView.NO_CURRENT_CELLULAR -> RotationFailureUi.NO_CURRENT_CELLULAR
    RotationFailureView.ROOT_POLICY_UNAVAILABLE -> RotationFailureUi.ROOT_POLICY_UNAVAILABLE
    RotationFailureView.BEFORE_IP_FAILED -> RotationFailureUi.BEFORE_IP_FAILED
    RotationFailureView.AIRPLANE_ENABLE_FAILED -> RotationFailureUi.AIRPLANE_ENABLE_FAILED
    RotationFailureView.AIRPLANE_OBSERVATION_FAILED ->
        RotationFailureUi.AIRPLANE_OBSERVATION_FAILED
    RotationFailureView.AIRPLANE_DISABLE_FAILED -> RotationFailureUi.AIRPLANE_DISABLE_FAILED
    RotationFailureView.FRESH_CELLULAR_UNAVAILABLE ->
        RotationFailureUi.FRESH_CELLULAR_UNAVAILABLE
    RotationFailureView.ROOT_POLICY_RECOVERY_FAILED ->
        RotationFailureUi.ROOT_POLICY_RECOVERY_FAILED
    RotationFailureView.AFTER_IP_FAILED -> RotationFailureUi.AFTER_IP_FAILED
    RotationFailureView.CREDENTIAL_CHANGED -> RotationFailureUi.CREDENTIAL_CHANGED
    RotationFailureView.DEADLINE_EXCEEDED -> RotationFailureUi.DEADLINE_EXCEEDED
    RotationFailureView.STATE_UNAVAILABLE -> RotationFailureUi.STATE_UNAVAILABLE
}

private fun ProxyListenerView.toUi(): ProxyListenerUi = ProxyListenerUi(
    protocol = when (protocol) {
        ProxyProtocolView.MIXED -> ProxyProtocolUi.MIXED
        ProxyProtocolView.SOCKS5 -> ProxyProtocolUi.SOCKS5
        ProxyProtocolView.HTTP_CONNECT -> ProxyProtocolUi.HTTP_CONNECT
    },
    port = port.toInt(),
)

private fun projectHealth(
    cellular: CellularRuntimeSnapshot,
    proxy: ProxyRuntimeSnapshot,
    mesh: MeshAdmissionView?,
    rotationInProgress: Boolean,
): HealthSummaryUiState {
    val cellularHealth = when (cellular) {
        is CellularRuntimeSnapshot.BoundaryUnavailable -> ComponentHealthUi.NOT_READY
        is CellularRuntimeSnapshot.OwnerSnapshot -> when (cellular.admission.state) {
            CellularAdmissionState.ADMITTED -> ComponentHealthUi.READY
            CellularAdmissionState.NOT_ADMITTED ->
                if (rotationInProgress) ComponentHealthUi.RECOVERING else ComponentHealthUi.NOT_READY
            CellularAdmissionState.UNKNOWN -> ComponentHealthUi.UNKNOWN
        }
    }
    val rootHealth = when (cellular) {
        is CellularRuntimeSnapshot.BoundaryUnavailable -> when (cellular.reason) {
            CellularBoundaryFailure.RootAuthorityUnavailable,
            CellularBoundaryFailure.RootPolicyReconcileFailed,
            CellularBoundaryFailure.RootPolicyGenerationChanged,
            CellularBoundaryFailure.RootPolicyCleanupFailed,
            is CellularBoundaryFailure.RootPolicyUnavailable,
            -> ComponentHealthUi.NOT_READY
            CellularBoundaryFailure.NativeLibraryUnavailable,
            CellularBoundaryFailure.ForeignCallFailed,
            -> ComponentHealthUi.UNKNOWN
        }
        is CellularRuntimeSnapshot.OwnerSnapshot -> when (cellular.admission.state) {
            CellularAdmissionState.ADMITTED -> ComponentHealthUi.READY
            CellularAdmissionState.NOT_ADMITTED -> ComponentHealthUi.WAITING
            CellularAdmissionState.UNKNOWN -> ComponentHealthUi.UNKNOWN
        }
    }
    val proxyHealth = when (proxy) {
        ProxyRuntimeSnapshot.Running -> ComponentHealthUi.READY
        ProxyRuntimeSnapshot.Starting -> ComponentHealthUi.RECOVERING
        ProxyRuntimeSnapshot.Stopped,
        is ProxyRuntimeSnapshot.Failed,
        -> ComponentHealthUi.NOT_READY
    }
    val meshHealth = when {
        mesh == null -> ComponentHealthUi.UNKNOWN
        mesh.state == MeshAdmissionState.ADMITTED && mesh.ingressRunning ->
            ComponentHealthUi.READY
        mesh.state == MeshAdmissionState.ADMITTED -> ComponentHealthUi.WAITING
        rotationInProgress -> ComponentHealthUi.RECOVERING
        else -> ComponentHealthUi.NOT_READY
    }
    return HealthSummaryUiState(
        cellular = cellularHealth,
        rootPolicy = rootHealth,
        proxy = proxyHealth,
        mesh = meshHealth,
    )
}

private fun projectCause(
    overall: ProductOverallUiState,
    cellular: CellularRuntimeSnapshot,
    proxy: ProxyRuntimeSnapshot,
    mesh: MeshAdmissionView?,
    rotationInProgress: Boolean,
): ProductCauseUi = when (overall) {
    ProductOverallUiState.READY -> ProductCauseUi.READY
    ProductOverallUiState.DEGRADED -> ProductCauseUi.PUBLIC_CONNECTION_DEGRADED
    ProductOverallUiState.UNKNOWN -> ProductCauseUi.CHECKING_CONNECTIVITY
    ProductOverallUiState.NOT_READY -> when (cellular) {
        is CellularRuntimeSnapshot.BoundaryUnavailable -> when (cellular.reason) {
            CellularBoundaryFailure.RootAuthorityUnavailable ->
                ProductCauseUi.ROOT_AUTHORIZATION_UNAVAILABLE
            CellularBoundaryFailure.RootPolicyReconcileFailed,
            CellularBoundaryFailure.RootPolicyGenerationChanged,
            CellularBoundaryFailure.RootPolicyCleanupFailed,
            is CellularBoundaryFailure.RootPolicyUnavailable,
            -> ProductCauseUi.ROOT_POLICY_FAILED
            CellularBoundaryFailure.NativeLibraryUnavailable,
            CellularBoundaryFailure.ForeignCallFailed,
            -> ProductCauseUi.MOBILE_NETWORK_NOT_READY
        }
        is CellularRuntimeSnapshot.OwnerSnapshot -> when {
            cellular.admission.state == CellularAdmissionState.UNKNOWN ->
                ProductCauseUi.CHECKING_CONNECTIVITY
            cellular.admission.state != CellularAdmissionState.ADMITTED && rotationInProgress ->
                ProductCauseUi.MOBILE_NETWORK_RECOVERING
            cellular.admission.state != CellularAdmissionState.ADMITTED ->
                ProductCauseUi.MOBILE_NETWORK_NOT_READY
            proxy !is ProxyRuntimeSnapshot.Running -> ProductCauseUi.PROXY_UNAVAILABLE
            mesh == null || mesh.state != MeshAdmissionState.ADMITTED ->
                ProductCauseUi.MESH_UNAVAILABLE
            else -> ProductCauseUi.PRODUCT_NOT_READY
        }
    }
}

private fun firstTechnicalReason(
    cellular: CellularRuntimeSnapshot,
    proxy: ProxyRuntimeSnapshot,
    mesh: MeshAdmissionView?,
): String? {
    if (cellular is CellularRuntimeSnapshot.BoundaryUnavailable) return cellular.reason.technicalCode()
    if (cellular is CellularRuntimeSnapshot.OwnerSnapshot) {
        cellular.admission.reason?.let { return it.technicalCode() }
    }
    if (proxy is ProxyRuntimeSnapshot.Failed) return proxy.reason.technicalCode()
    return mesh?.reason?.technicalCode()
}

private fun CellularBoundaryFailure.technicalCode(): String = when (this) {
    CellularBoundaryFailure.NativeLibraryUnavailable -> "android_ffi.native_library_unavailable"
    CellularBoundaryFailure.ForeignCallFailed -> "android_ffi.foreign_call_failed"
    CellularBoundaryFailure.RootAuthorityUnavailable -> "cellular.root_authority_unavailable"
    CellularBoundaryFailure.RootPolicyReconcileFailed -> "cellular.root_policy_reconcile_failed"
    CellularBoundaryFailure.RootPolicyGenerationChanged -> "cellular.root_policy_generation_changed"
    CellularBoundaryFailure.RootPolicyCleanupFailed -> "cellular.root_policy_cleanup_failed"
    is CellularBoundaryFailure.RootPolicyUnavailable ->
        "cellular.root_policy_${failure.name.lowercase()}"
}

private fun CellularAdmissionReason.technicalCode(): String = when (this) {
    CellularAdmissionReason.NO_OBSERVATION -> "cellular.no_observation"
    CellularAdmissionReason.NOT_CELLULAR -> "cellular.not_cellular"
    CellularAdmissionReason.MISSING_INTERNET_CAPABILITY -> "cellular.missing_internet_capability"
    CellularAdmissionReason.VPN_DERIVED_NETWORK -> "cellular.vpn_derived_network"
    CellularAdmissionReason.NOT_VALIDATED -> "cellular.not_validated"
    CellularAdmissionReason.NETWORK_LOST -> "cellular.network_lost"
}

private fun ProxyServingFailure.technicalCode(): String = "proxy.${name.lowercase()}"

private fun MeshAdmissionReason.technicalCode(): String = when (this) {
    MeshAdmissionReason.NO_OBSERVATION -> "mesh.no_observation"
    MeshAdmissionReason.NO_ACCEPTED_ADDRESS -> "mesh.no_accepted_address"
    MeshAdmissionReason.MULTIPLE_ACCEPTED_ADDRESSES -> "mesh.multiple_accepted_addresses"
}

fun overallStatusText(state: ProductOverallUiState): String = when (state) {
    ProductOverallUiState.READY -> "READY"
    ProductOverallUiState.DEGRADED -> "DEGRADED"
    ProductOverallUiState.NOT_READY -> "NOT READY"
    ProductOverallUiState.UNKNOWN -> "UNKNOWN"
}

fun productCauseText(cause: ProductCauseUi): String = when (cause) {
    ProductCauseUi.READY -> "Product connectivity is ready."
    ProductCauseUi.CHECKING_CONNECTIVITY -> "Checking connectivity."
    ProductCauseUi.PUBLIC_CONNECTION_DEGRADED -> "Public connection is degraded."
    ProductCauseUi.MOBILE_NETWORK_NOT_READY -> "Mobile network is not ready."
    ProductCauseUi.MOBILE_NETWORK_RECOVERING -> "Mobile network is recovering."
    ProductCauseUi.ROOT_AUTHORIZATION_UNAVAILABLE -> "Root authorization is unavailable."
    ProductCauseUi.ROOT_POLICY_FAILED -> "Network policy is not ready."
    ProductCauseUi.PROXY_UNAVAILABLE -> "Proxy service is not ready."
    ProductCauseUi.MESH_UNAVAILABLE -> "Mesh connection is not ready."
    ProductCauseUi.PRODUCT_NOT_READY -> "Product is not ready yet."
}

fun componentHealthText(state: ComponentHealthUi): String = when (state) {
    ComponentHealthUi.READY -> "Ready"
    ComponentHealthUi.RECOVERING -> "Recovering"
    ComponentHealthUi.WAITING -> "Waiting"
    ComponentHealthUi.NOT_READY -> "Not ready"
    ComponentHealthUi.UNKNOWN -> "Unknown"
}

fun rotationStageText(stage: RotationStageUi): String = when (stage) {
    RotationStageUi.IDLE -> "Ready"
    RotationStageUi.STARTING -> "Starting"
    RotationStageUi.DISCONNECTING_CELLULAR -> "Disconnecting cellular"
    RotationStageUi.WAITING_FOR_CELLULAR_DISCONNECT -> "Waiting for cellular disconnect"
    RotationStageUi.RESTORING_RADIO -> "Restoring radio"
    RotationStageUi.WAITING_FOR_CELLULAR_RECOVERY -> "Waiting for cellular recovery"
    RotationStageUi.APPLYING_NETWORK_POLICY -> "Applying network policy"
    RotationStageUi.CHECKING_PUBLIC_IP -> "Checking public IP"
    RotationStageUi.COMPLETE -> "Complete"
}

fun rotationResultText(result: RotationResultUi): String = when (result) {
    RotationResultUi.CHANGED -> "IP changed"
    RotationResultUi.UNCHANGED -> "IP unchanged"
    RotationResultUi.FAILED -> "IP change failed"
}

fun rotationFailureText(failure: RotationFailureUi): String = when (failure) {
    RotationFailureUi.RUNTIME_NOT_RUNNING -> "Runtime is not running."
    RotationFailureUi.NO_CURRENT_CELLULAR -> "No current mobile network is available."
    RotationFailureUi.ROOT_POLICY_UNAVAILABLE -> "Network policy is unavailable."
    RotationFailureUi.BEFORE_IP_FAILED -> "Could not read the current public IP."
    RotationFailureUi.AIRPLANE_ENABLE_FAILED -> "Could not disconnect the mobile radio."
    RotationFailureUi.AIRPLANE_OBSERVATION_FAILED -> "Could not confirm the radio state."
    RotationFailureUi.AIRPLANE_DISABLE_FAILED -> "Could not restore the mobile radio."
    RotationFailureUi.FRESH_CELLULAR_UNAVAILABLE -> "Mobile network did not recover."
    RotationFailureUi.ROOT_POLICY_RECOVERY_FAILED -> "Network policy did not recover."
    RotationFailureUi.AFTER_IP_FAILED -> "Could not verify the new public IP."
    RotationFailureUi.CREDENTIAL_CHANGED -> "Proxy credentials changed during the operation."
    RotationFailureUi.DEADLINE_EXCEEDED -> "The IP change timed out."
    RotationFailureUi.STATE_UNAVAILABLE -> "Rotation state is unavailable."
}

fun proxyProtocolText(protocol: ProxyProtocolUi): String = when (protocol) {
    ProxyProtocolUi.MIXED -> "Mixed"
    ProxyProtocolUi.SOCKS5 -> "SOCKS5"
    ProxyProtocolUi.HTTP_CONNECT -> "HTTP CONNECT"
}
