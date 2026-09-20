package com.mobileproxymish.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onStart() {
        super.onStart()
        startService(Intent(this, ProxyRuntimeService::class.java))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val model: MainViewModel = viewModel()
            val state by model.state.collectAsStateWithLifecycle()
            val credentialReveal by model.credentialReveal.collectAsStateWithLifecycle()

            MishApp(
                state = state,
                credentialReveal = credentialReveal,
                onChangeIp = model::changePublicIp,
                onShowCredentials = model::showCurrentCredentials,
                onHideCredentials = model::hideCurrentCredentials,
            )
        }
    }
}
