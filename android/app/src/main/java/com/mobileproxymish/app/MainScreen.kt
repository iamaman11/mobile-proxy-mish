package com.mobileproxymish.app

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp

@Composable
fun MishTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) darkColorScheme() else lightColorScheme(),
        content = content,
    )
}

@Composable
fun MishApp(
    state: ProductUiState,
    credentialReveal: CredentialRevealUiState,
    onChangeIp: () -> Unit,
    onShowCredentials: () -> Unit,
    onHideCredentials: () -> Unit,
) {
    var diagnosticsExpanded by rememberSaveable { mutableStateOf(false) }
    MishTheme {
        MainScreen(
            state = state,
            credentialReveal = credentialReveal,
            diagnosticsExpanded = diagnosticsExpanded,
            onDiagnosticsExpandedChange = { diagnosticsExpanded = it },
            onChangeIp = onChangeIp,
            onShowCredentials = onShowCredentials,
            onHideCredentials = onHideCredentials,
        )
    }
}

@Composable
fun MainScreen(
    state: ProductUiState,
    credentialReveal: CredentialRevealUiState,
    diagnosticsExpanded: Boolean,
    onDiagnosticsExpandedChange: (Boolean) -> Unit,
    onChangeIp: () -> Unit,
    onShowCredentials: () -> Unit,
    onHideCredentials: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Text(
                    text = "Mobile Proxy MISH",
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.semantics { heading() },
                )
            }
            item { OverallStatusCard(state) }
            item { PublicIpCard(state.publicIp) }
            item { RotationAction(state.rotation, state.changeIpEnabled, onChangeIp) }
            item { HealthSummary(state.health) }
            item { ProxyInfo(state.proxyEndpoint) }
            item {
                AdvancedDiagnostics(
                    state = state.advancedDiagnostics,
                    expanded = diagnosticsExpanded,
                    onExpandedChange = onDiagnosticsExpandedChange,
                )
            }
            item {
                TextButton(onClick = onShowCredentials) {
                    Text("Proxy credentials")
                }
            }
        }
    }
    CredentialRevealDialog(credentialReveal, onHideCredentials)
}

@Composable
private fun OverallStatusCard(state: ProductUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .padding(20.dp)
                .semantics { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(overallStatusText(state.overall), style = MaterialTheme.typography.headlineSmall)
            Text(productCauseText(state.cause), style = MaterialTheme.typography.bodyLarge)
        }
    }
}

@Composable
private fun PublicIpCard(state: PublicIpUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Public IP", style = MaterialTheme.typography.titleMedium)
            LabelValue("Current IP", state.current ?: "Unknown")
            LabelValue("Previous IP", state.previous ?: "Unknown")
        }
    }
}

@Composable
private fun RotationAction(
    state: RotationUiState,
    enabled: Boolean,
    onChangeIp: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (state.inProgress) {
            Text(
                "Changing IP",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            Text(rotationStageText(state.stage))
            LinearProgressIndicator(
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { stateDescription = rotationStageText(state.stage) },
            )
        } else {
            state.result?.let {
                Text(
                    rotationResultText(it),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            state.failure?.let { Text(rotationFailureText(it)) }
        }
        Button(
            onClick = onChangeIp,
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (state.inProgress) "Changing…" else "Change IP")
        }
    }
}

@Composable
private fun HealthSummary(state: HealthSummaryUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Health", style = MaterialTheme.typography.titleMedium)
            HealthRow("Cellular", state.cellular)
            HealthRow("Root policy", state.rootPolicy)
            HealthRow("Proxy", state.proxy)
            HealthRow("Mesh", state.mesh)
        }
    }
}

@Composable
private fun HealthRow(label: String, health: ComponentHealthUi) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label)
        Text(componentHealthText(health))
    }
}

@Composable
private fun ProxyInfo(state: ProxyEndpointUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Proxy", style = MaterialTheme.typography.titleMedium)
            LabelValue("Endpoint", state.endpoint ?: "Unavailable")
            if (state.listeners.isEmpty()) {
                Text("Protocol information unavailable")
            } else {
                state.listeners.forEach { listener ->
                    val coordinate = state.endpoint
                        ?.let { "$it:${listener.port}" }
                        ?: "port ${listener.port}"
                    Text("${proxyProtocolText(listener.protocol)} — $coordinate")
                }
            }
        }
    }
}

@Composable
private fun AdvancedDiagnostics(
    state: AdvancedDiagnosticsUiState,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        TextButton(
            onClick = { onExpandedChange(!expanded) },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (expanded) "Hide advanced diagnostics" else "Advanced diagnostics")
        }
        if (expanded) {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    DiagnosticRow("Technical reason", state.technicalReason ?: "None")
                    DiagnosticRow(
                        "Cellular owner sequence",
                        state.cellularOwnerSequence?.toString() ?: "Unknown",
                    )
                    DiagnosticRow(
                        "Mesh observation sequence",
                        state.meshObservationSequence?.toString() ?: "Unknown",
                    )
                    DiagnosticRow(
                        "Mesh admission epoch",
                        state.meshAdmissionEpoch?.toString() ?: "Unknown",
                    )
                    DiagnosticRow(
                        "Rotation operation",
                        state.rotationOperationId?.toString() ?: "None",
                    )
                    DiagnosticRow(
                        "Rotation before generation",
                        state.rotationBeforeGeneration?.toString() ?: "Unknown",
                    )
                    DiagnosticRow(
                        "Rotation after generation",
                        state.rotationAfterGeneration?.toString() ?: "Unknown",
                    )
                }
            }
        }
    }
}

@Composable
private fun DiagnosticRow(label: String, value: String) {
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun LabelValue(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun CredentialRevealDialog(
    state: CredentialRevealUiState,
    onHide: () -> Unit,
) {
    when (state) {
        CredentialRevealUiState.Hidden -> Unit
        CredentialRevealUiState.Unavailable -> AlertDialog(
            onDismissRequest = onHide,
            title = { Text("Proxy credentials") },
            text = { Text("Current proxy credentials are unavailable.") },
            confirmButton = {
                TextButton(onClick = onHide) { Text("Close") }
            },
        )
        is CredentialRevealUiState.Revealed -> AlertDialog(
            onDismissRequest = onHide,
            title = { Text("Proxy credentials") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    LabelValue("Username", state.username)
                    HorizontalDivider()
                    LabelValue("Password", state.password)
                }
            },
            confirmButton = {
                TextButton(onClick = onHide) { Text("Hide") }
            },
        )
    }
}
