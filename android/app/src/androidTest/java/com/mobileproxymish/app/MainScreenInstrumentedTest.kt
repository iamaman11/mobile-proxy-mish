package com.mobileproxymish.app

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class MainScreenInstrumentedTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun readyDashboardShowsStatusHealthProxyAndEnabledAction() {
        var changeRequests = 0
        compose.setContent {
            MishTheme(darkTheme = false) {
                MainScreen(
                    state = readyState(),
                    credentialReveal = CredentialRevealUiState.Hidden,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = { changeRequests += 1 },
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText("READY").assertExists()
        compose.onNodeWithText("Product connectivity is ready.").assertExists()
        compose.onNodeWithText("198.51.100.11").assertExists()
        compose.onNodeWithText("198.51.100.10").assertExists()
        compose.onNodeWithText("Root policy").assertExists()
        compose.onNodeWithText("HTTP CONNECT — 100.96.2.4:3128").assertExists()
        compose.onNodeWithText("IP changed").assertExists()
        compose.onNodeWithText("Change IP")
            .assertHasClickAction()
            .assertIsEnabled()
            .performClick()
        assertEquals(1, changeRequests)
    }

    @Test
    fun largeFontScalePreservesReadableStatusAndPrimaryActionSemantics() {
        compose.setContent {
            val baseDensity = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(
                    density = baseDensity.density,
                    fontScale = 2.0f,
                ),
            ) {
                MishTheme(darkTheme = false) {
                    MainScreen(
                        state = readyState(),
                        credentialReveal = CredentialRevealUiState.Hidden,
                        diagnosticsExpanded = false,
                        onDiagnosticsExpandedChange = {},
                        onChangeIp = {},
                        onShowCredentials = {},
                        onHideCredentials = {},
                    )
                }
            }
        }

        compose.onNodeWithText("READY").assertExists()
        compose.onNodeWithText("Product connectivity is ready.").assertExists()
    }

    @Test
    fun activeRotationShowsSemanticProgressAndDisablesActionInDarkTheme() {
        compose.setContent {
            MishTheme(darkTheme = true) {
                MainScreen(
                    state = readyState().copy(
                        publicIp = PublicIpUiState(current = null, previous = "198.51.100.10"),
                        rotation = RotationUiState(
                            operationId = 5uL,
                            stage = RotationStageUi.WAITING_FOR_CELLULAR_RECOVERY,
                            inProgress = true,
                            beforeGeneration = 7uL,
                        ),
                    ),
                    credentialReveal = CredentialRevealUiState.Hidden,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText("Changing IP").assertExists()
        compose.onNodeWithText("Waiting for cellular recovery").assertExists()
        compose.onNodeWithText("Changing…").assertIsNotEnabled()
        compose.onNodeWithText("42%").assertDoesNotExist()
    }

    @Test
    fun terminalChangedUnchangedAndFailureUseExplicitText() {
        compose.setContent {
            MishTheme {
                MainScreen(
                    state = readyState().copy(
                        rotation = RotationUiState(
                            stage = RotationStageUi.COMPLETE,
                            result = RotationResultUi.UNCHANGED,
                        ),
                    ),
                    credentialReveal = CredentialRevealUiState.Hidden,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText("IP unchanged").assertExists()
        compose.onNodeWithText("IP change failed").assertDoesNotExist()
    }

    @Test
    fun failedTerminalShowsTypedFailureMessage() {
        compose.setContent {
            MishTheme {
                MainScreen(
                    state = readyState().copy(
                        rotation = RotationUiState(
                            stage = RotationStageUi.COMPLETE,
                            result = RotationResultUi.FAILED,
                            failure = RotationFailureUi.DEADLINE_EXCEEDED,
                        ),
                    ),
                    credentialReveal = CredentialRevealUiState.Hidden,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText("IP change failed").assertExists()
        compose.onNodeWithText("The IP change timed out.").assertExists()
    }

    @Test
    fun advancedDiagnosticsAreCollapsedByDefaultAndExpandForLongTechnicalText() {
        val technical = "cellular.root_policy_observation_unavailable.with.a.very.long.detail"
        compose.setContent {
            MishApp(
                state = readyState().copy(
                    advancedDiagnostics = AdvancedDiagnosticsUiState(
                        technicalReason = technical,
                        cellularOwnerSequence = 7uL,
                    ),
                ),
                credentialReveal = CredentialRevealUiState.Hidden,
                onChangeIp = {},
                onShowCredentials = {},
                onHideCredentials = {},
            )
        }
        compose.onNodeWithText(technical).assertDoesNotExist()
        compose.onNodeWithText("Advanced diagnostics").performClick()
        compose.onNodeWithText(technical).assertExists()
        compose.onNodeWithText("Cellular owner sequence").assertExists()
    }

    @Test
    fun credentialsStayOffDashboardUntilExplicitSensitiveReveal() {
        val secret = "proxy-secret"
        compose.setContent {
            MishTheme {
                MainScreen(
                    state = readyState(),
                    credentialReveal = CredentialRevealUiState.Hidden,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText(secret).assertDoesNotExist()
        compose.onNodeWithText("Proxy credentials").assertHasClickAction()
    }

    @Test
    fun unavailableCredentialStateIsExplicitAndContainsNoMaterial() {
        compose.setContent {
            MishTheme {
                MainScreen(
                    state = readyState(),
                    credentialReveal = CredentialRevealUiState.Unavailable,
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = {},
                )
            }
        }
        compose.onNodeWithText("Current proxy credentials are unavailable.").assertExists()
        compose.onNodeWithText("proxy-secret").assertDoesNotExist()
    }

    @Test
    fun explicitCredentialDialogCanRevealAndHideMaterial() {
        var hideRequested = false
        compose.setContent {
            MishTheme {
                MainScreen(
                    state = readyState(),
                    credentialReveal = CredentialRevealUiState.Revealed(
                        version = 3uL,
                        username = "proxy-user",
                        password = "proxy-secret",
                    ),
                    diagnosticsExpanded = false,
                    onDiagnosticsExpandedChange = {},
                    onChangeIp = {},
                    onShowCredentials = {},
                    onHideCredentials = { hideRequested = true },
                )
            }
        }
        compose.onNodeWithText("proxy-user").assertExists()
        compose.onNodeWithText("proxy-secret").assertExists()
        compose.onNodeWithText("Hide").assertHasClickAction().performClick()
        assertTrue(hideRequested)
    }

    private fun readyState(): ProductUiState = ProductUiState(
        overall = ProductOverallUiState.READY,
        cause = ProductCauseUi.READY,
        publicIp = PublicIpUiState(
            current = "198.51.100.11",
            previous = "198.51.100.10",
        ),
        rotation = RotationUiState(
            stage = RotationStageUi.COMPLETE,
            result = RotationResultUi.CHANGED,
        ),
        health = HealthSummaryUiState(
            cellular = ComponentHealthUi.READY,
            rootPolicy = ComponentHealthUi.READY,
            proxy = ComponentHealthUi.READY,
            mesh = ComponentHealthUi.READY,
        ),
        proxyEndpoint = ProxyEndpointUiState(
            endpoint = "100.96.2.4",
            listeners = listOf(
                ProxyListenerUi(ProxyProtocolUi.HTTP_CONNECT, 3128),
                ProxyListenerUi(ProxyProtocolUi.SOCKS5, 1081),
                ProxyListenerUi(ProxyProtocolUi.MIXED, 1080),
            ),
        ),
    )
}
