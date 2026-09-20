package com.mobileproxymish.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            val credentialReveal by viewModel.credentialReveal.collectAsStateWithLifecycle()
            MishApp(
                state = state,
                credentialReveal = credentialReveal,
                onChangeIp = viewModel::changePublicIp,
                onShowCredentials = viewModel::showCurrentCredentials,
                onHideCredentials = viewModel::hideCurrentCredentials,
            )
        }
    }

    override fun onStart() {
        super.onStart()
        ProxyRuntimeService.requestStart(this)
    }
}
