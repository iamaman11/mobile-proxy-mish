package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mobileproxymish.ffi.NativeRotationStartError
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

sealed interface CredentialRevealUiState {
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

/**
 * Presentation/application adapter over Rust-owned PRODUCT state.
 *
 * No readiness decision, rotation phase, retry/timing policy, generation identity or network
 * currentness is owned here. It only combines typed native projections and forwards explicit
 * user commands through MishRuntimeController.
 */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val runtimeController = (application as MishApplication).runtimeController
    private val proxyListeners = runtimeController.proxyListenerContract()
    private val mutableCredentialReveal =
        MutableStateFlow<CredentialRevealUiState>(CredentialRevealUiState.Hidden)
    private val rotationStartRejection = MutableStateFlow<RotationStartRejectionUi?>(null)

    internal val credentialReveal: StateFlow<CredentialRevealUiState>
        get() = mutableCredentialReveal.asStateFlow()

    private fun projectCurrent(): ProductUiState = projectProductUi(
        ProductPresentationInput(
            readiness = runtimeController.readinessSnapshot.value,
            cellular = runtimeController.cellularSnapshot.value,
            proxy = runtimeController.proxySnapshot.value,
            mesh = runtimeController.meshSnapshot.value,
            rotation = runtimeController.rotationSnapshot.value,
            proxyListeners = proxyListeners,
        ),
    )

    val state: StateFlow<ProductUiState> = combine(
        combine(
            runtimeController.cellularSnapshot,
            runtimeController.proxySnapshot,
            runtimeController.readinessSnapshot,
            runtimeController.meshSnapshot,
            runtimeController.rotationSnapshot,
        ) { cellular, proxy, readiness, mesh, rotation ->
            projectProductUi(
                ProductPresentationInput(
                    readiness = readiness,
                    cellular = cellular,
                    proxy = proxy,
                    mesh = mesh,
                    rotation = rotation,
                    proxyListeners = proxyListeners,
                ),
            )
        },
        rotationStartRejection,
    ) { nativeProjection, requestRejection ->
        // Display-only acknowledgement; the backend Rotation snapshot stays authoritative.
        nativeProjection.copy(rotationStartRejection = requestRejection)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = projectCurrent(),
    )

    fun changePublicIp() {
        // Never retry, infer, or complete Rotation in Kotlin. Only report immediate refusal.
        rotationStartRejection.value = null
        try {
            runtimeController.startPublicIpRotation()
        } catch (rejected: NativeRotationStartError) {
            rotationStartRejection.value = rejected.toUi()
        } catch (_: Exception) {
            // Never display arbitrary exception text, which could contain private material.
            rotationStartRejection.value = RotationStartRejectionUi.UNEXPECTED_BRIDGE_FAILURE
        }
    }

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
}
