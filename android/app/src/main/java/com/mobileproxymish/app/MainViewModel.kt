package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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

    private val commandRejection = MutableStateFlow<String?>(null)

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
            commandRejection = commandRejection.value,
        ),
    )

    val state: StateFlow<ProductUiState> = combine(
        runtimeController.cellularSnapshot,
        runtimeController.proxySnapshot,
        runtimeController.readinessSnapshot,
        runtimeController.meshSnapshot,
        runtimeController.rotationSnapshot,
        commandRejection,
    ) { cellular, proxy, readiness, mesh, rotation, rejection ->
        projectProductUi(
            ProductPresentationInput(
                readiness = readiness,
                cellular = cellular,
                proxy = proxy,
                mesh = mesh,
                rotation = rotation,
                proxyListeners = proxyListeners,
                commandRejection = rejection,
            ),
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = projectCurrent(),
    )

    fun changePublicIp() {
        // UI disablement is presentation only. Rust still rejects repeated/concurrent starts.
        commandRejection.value = null
        runCatching(runtimeController::startPublicIpRotation)
            .onFailure { commandRejection.value = rotationCommandRejectionText(it) }
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

/** Presentation-only translation of known native rejection messages; no retry or operation owner. */
internal fun rotationCommandRejectionText(error: Throwable): String = when (error.message) {
    "PRODUCT runtime is not running" -> "Runtime is not running."
    "an IP rotation is already in progress" -> "An IP change is already in progress."
    "no current admitted Cellular generation" -> "No current mobile network is available."
    "root policy is not authorized for current Cellular generation" -> "Network policy is not authorized."
    "current proxy credential is unavailable" -> "Proxy credentials are unavailable."
    "native PRODUCT executor is unavailable" -> "Runtime execution is unavailable."
    "native rotation state is unavailable" -> "Rotation state is unavailable."
    else -> "IP change request was rejected. See advanced diagnostics."
}
