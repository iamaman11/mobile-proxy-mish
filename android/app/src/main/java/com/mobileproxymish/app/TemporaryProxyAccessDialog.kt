package com.mobileproxymish.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy

/**
 * Explicit local-only operator interaction; no secret appears in Bundle, saved state, diagnostics,
 * telemetry, GitHub or a build artifact. The primary credential is never shown/edited here.
 */
@Composable
internal fun TemporaryProxyAccessDialog(
    hasBeenIssued: Boolean,
    action: TemporaryAccessActionUi,
    onIssue: (String, String) -> Unit,
    onRevoke: () -> Unit,
    onDismiss: () -> Unit,
) {
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    val busy = action == TemporaryAccessActionUi.BUSY
    AlertDialog(
        onDismissRequest = {
            username = ""
            password = ""
            onDismiss()
        },
        properties = DialogProperties(securePolicy = SecureFlagPolicy.SecureOn),
        title = { Text("Temporary proxy access") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("One additional account for up to 24 hours. The primary account is unchanged.")
                Text(
                    "Changing device time cannot extend access. A reboot ends the temporary grant " +
                        "early if its original monotonic clock cannot be verified.",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (hasBeenIssued) {
                    Text("A temporary grant has already been issued. It cannot be renewed.")
                } else {
                    OutlinedTextField(
                        value = username,
                        onValueChange = { username = it },
                        label = { Text("Temporary username") },
                        enabled = !busy,
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Temporary password") },
                        enabled = !busy,
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    )
                }
                when (action) {
                    TemporaryAccessActionUi.BUSY -> Text("Updating protected local record…")
                    TemporaryAccessActionUi.ISSUED -> Text("Temporary access enabled.")
                    TemporaryAccessActionUi.REVOKED -> Text("Temporary access revoked.")
                    TemporaryAccessActionUi.FAILED -> Text("Operation rejected. No primary account change.")
                    TemporaryAccessActionUi.IDLE -> Unit
                }
            }
        },
        confirmButton = {
            if (hasBeenIssued) {
                TextButton(onClick = onRevoke, enabled = !busy) { Text("Revoke temporary access") }
            } else {
                TextButton(
                    onClick = {
                        val user = username
                        val secret = password
                        username = ""
                        password = ""
                        onIssue(user, secret)
                    },
                    enabled = !busy && username.isNotBlank() && password.isNotBlank(),
                ) {
                    Text("Enable for 24h")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = {
                username = ""
                password = ""
                onDismiss()
            }) { Text("Close") }
        },
    )
}
