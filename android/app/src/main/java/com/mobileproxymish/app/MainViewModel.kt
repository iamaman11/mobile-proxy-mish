package com.mobileproxymish.app

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class MainUiState(
    val title: String = "Mobile Proxy MISH",
    val status: String = "Bootstrap shell — runtime readiness is not implemented",
)

class MainViewModel : ViewModel() {
    private val mutableState = MutableStateFlow(MainUiState())
    val state: StateFlow<MainUiState> = mutableState.asStateFlow()
}
