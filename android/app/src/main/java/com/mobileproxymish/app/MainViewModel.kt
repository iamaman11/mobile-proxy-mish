package com.mobileproxymish.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
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

/** Non-secret presentation of explicit on-device secondary provisioning only. */
enum class TemporaryAccessActionUi {
    IDLE, BUSY, ISSUED, REVOKED, FAILED,
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

    internal val credentialReveal: StateFlow<CredentialRevealUiState>
        get() = mutableCredentialReveal.asStateFlow()

    private val temporaryIssuedState = MutableStateFlow(runtimeController.temporaryCredentialHasBeenIssued())
    private val temporaryActionState = MutableStateFlow(TemporaryAccessActionUi.IDLE)
    val temporaryIssued: StateFlow<Boolean> get() = temporaryIssuedState.asStateFlow()
    val temporaryAction: StateFlow<TemporaryAccessActionUi> get() = temporaryActionState.asStateFlow()

    fun issueTemporaryCredential(username: String, password: String) {
        if (temporaryActionState.value == TemporaryAccessActionUi.BUSY) return
        temporaryActionState.value = TemporaryAccessActionUi.BUSY
        viewModelScope.launch(Dispatchers.IO) {
            val ok = runtimeController.issueTemporaryCredentialOnDevice(username, password)
            temporaryIssuedState.value = runtimeController.temporaryCredentialHasBeenIssued()
            temporaryActionState.value =
                if (ok) TemporaryAccessActionUi.ISSUED else TemporaryAccessActionUi.FAILED
        }
    }

    fun revokeTemporaryCredential() {
        if (temporaryActionState.value == TemporaryAccessActionUi.BUSY) return
        temporaryActionState.value = TemporaryAccessActionUi.BUSY
        viewModelScope.launch(Dispatchers.IO) {
            val ok = runtimeController.revokeTemporaryCredentialOnDevice()
            temporaryIssuedState.value = runtimeController.temporaryCredentialHasBeenIssued()
            temporaryActionState.value =
                if (ok) TemporaryAccessActionUi.REVOKED else TemporaryAccessActionUi.FAILED
        }
    }

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
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = projectCurrent(),
    )

    fun changePublicIp() {
        // UI disablement is presentation only. Rust still rejects repeated/concurrent starts.
        runCatching(runtimeController::startPublicIpRotation)
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
