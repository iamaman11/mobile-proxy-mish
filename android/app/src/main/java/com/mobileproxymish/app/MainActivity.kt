package com.mobileproxymish.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ProxyRuntimeService.requestStart(this)
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()

            MaterialTheme {
                Scaffold { padding ->
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(padding),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(text = state.title, style = MaterialTheme.typography.headlineMedium)
                        Text(text = state.overallStatus, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            text = "Cellular admission: ${state.cellularState}",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        state.cellularReasonCode?.let { reason ->
                            Text(
                                text = "Cellular reason: $reason",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                        Text(
                            text = "Proxy runtime: ${state.proxyState}",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        state.proxyReasonCode?.let { reason ->
                            Text(
                                text = "Proxy reason: $reason",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}
