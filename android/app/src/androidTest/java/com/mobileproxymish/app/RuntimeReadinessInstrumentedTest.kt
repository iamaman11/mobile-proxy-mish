package com.mobileproxymish.app

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.mobileproxymish.ffi.ProductReadinessState
import org.junit.Test

/**
 * Retained DEVICE-1 diagnostic: projects only typed owner state after a normal runtime restart.
 * It never prints endpoints, credentials, network handles, routes, DNS answers or process IDs.
 */
class RuntimeReadinessInstrumentedTest {
    @Test
    fun emitsTypedRestartReadinessProjection() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val app = context.applicationContext as MishApplication
        val deadline = SystemClock.elapsedRealtime() + 20_000L
        while (SystemClock.elapsedRealtime() < deadline &&
            (app.runtimeController.proxySnapshot.value == ProxyRuntimeSnapshot.Starting ||
                app.runtimeController.readinessSnapshot.value == ProductReadinessState.UNKNOWN)
        ) {
            SystemClock.sleep(250L)
        }
        val proxy = app.runtimeController.proxySnapshot.value
        val readiness = app.runtimeController.readinessSnapshot.value
        val mesh = app.runtimeController.meshSnapshot.value
        val readinessDiagnostic = app.runtimeController.currentReadinessRuntime.diagnosticObservation()
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val currentVpnCount = connectivity.allNetworks.count { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }

        println("MISH_RESTART_PROXY=${proxy.javaClass.simpleName}")
        println("MISH_RESTART_READINESS=$readiness")
        println("MISH_RESTART_MESH_STATE=${mesh?.state?.name.orEmpty()}")
        println("MISH_RESTART_MESH_EPOCH_PRESENT=${mesh?.admissionEpoch != null}")
        println("MISH_RESTART_MESH_INGRESS=${mesh?.ingressRunning == true}")
        println("MISH_RESTART_PLATFORM_VPN_COUNT=$currentVpnCount")
        println("MISH_RESTART_CELLULAR_STATE=${readinessDiagnostic.cellularState}")
        println("MISH_RESTART_CELLULAR_REASON=${readinessDiagnostic.cellularReason}")
        println("MISH_RESTART_CELLULAR_ADMITTED=${readinessDiagnostic.cellularAdmitted}")
        println("MISH_RESTART_ROOT_POLICY=${readinessDiagnostic.rootPolicyVerified}")
        println("MISH_RESTART_PRIVATE_BRIDGE=${readinessDiagnostic.privateBridgeHealthy}")
        println("MISH_RESTART_PROXY_HEALTHY=${readinessDiagnostic.proxyHealthy}")
        println("MISH_RESTART_CREDENTIAL_ACTIVE=${readinessDiagnostic.credentialActive}")
        println("MISH_RESTART_BINDING_ELIGIBLE=${readinessDiagnostic.bindingEligible}")
    }
}
