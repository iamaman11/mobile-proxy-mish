package com.mobileproxymish.app

import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertExists
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class TemporaryProxyAccessDialogInstrumentedTest {
    @get:Rule val compose = createComposeRule()

    @Test fun requiresBothOperatorValuesAndNeverShowsPasswordOnScreen() {
        var issuedUsername: String? = null
        var issuedPassword: String? = null
        compose.setContent {
            MishTheme {
                TemporaryProxyAccessDialog(
                    hasBeenIssued = false,
                    action = TemporaryAccessActionUi.IDLE,
                    onIssue = { user, pass ->
                        issuedUsername = user
                        issuedPassword = pass
                    },
                    onRevoke = {},
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithText("Enable for 24h").assertIsNotEnabled()
        compose.onNodeWithTag("temporary-username").performTextInput("synthetic-guest")
        compose.onNodeWithTag("temporary-password").performTextInput("test-not-production")
        compose.onNodeWithText("Enable for 24h").assertIsEnabled().performClick()
        assertEquals("synthetic-guest", issuedUsername)
        assertEquals("test-not-production", issuedPassword)
        compose.onNodeWithText("test-not-production").assertDoesNotExist()
    }

    @Test fun existingGrantCannotBeReissuedAndHasSeparateRevokeButton() {
        var revokeCalls = 0
        compose.setContent {
            MishTheme {
                TemporaryProxyAccessDialog(
                    hasBeenIssued = true,
                    action = TemporaryAccessActionUi.IDLE,
                    onIssue = { _, _ -> error("must not issue again") },
                    onRevoke = { revokeCalls++ },
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithText("Enable for 24h").assertDoesNotExist()
        compose.onNodeWithText("Revoke temporary access").assertExists().performClick()
        assertEquals(1, revokeCalls)
    }
}
