package com.mobileproxymish.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            val credentialReveal by viewModel.credentialReveal.collectAsStateWithLifecycle()
            val temporaryIssued by viewModel.temporaryIssued.collectAsStateWithLifecycle()
            val temporaryAction by viewModel.temporaryAction.collectAsStateWithLifecycle()
            var manageTemporary by remember { mutableStateOf(false) }
            MishApp(
                state = state,
                credentialReveal = credentialReveal,
                onChangeIp = viewModel::changePublicIp,
                onShowCredentials = viewModel::showCurrentCredentials,
                onHideCredentials = viewModel::hideCurrentCredentials,
                onManageTemporary = { manageTemporary = true },
            )
            if (manageTemporary) {
                TemporaryProxyAccessDialog(
                    hasBeenIssued = temporaryIssued,
                    action = temporaryAction,
                    onIssue = viewModel::issueTemporaryCredential,
                    onRevoke = viewModel::revokeTemporaryCredential,
                    onDismiss = { manageTemporary = false },
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        ProxyRuntimeService.requestStart(this)
    }
}
