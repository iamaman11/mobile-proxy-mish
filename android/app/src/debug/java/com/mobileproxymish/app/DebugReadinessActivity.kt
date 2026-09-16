package com.mobileproxymish.app

import android.app.Activity
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import com.mobileproxymish.app.cellular.MagiskRootAuthority
import com.mobileproxymish.ffi.ProductReadinessState

/**
 * DEVICE-1 debug-only normal-process observer. It accepts no extras and reports no endpoint,
 * identifier, route, DNS value, credential, or probe response. Release manifests exclude it.
 */
class DebugReadinessActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Thread {
            val runtime = (application as MishApplication).runtimeController
            val deadline = SystemClock.elapsedRealtime() + OBSERVATION_TIMEOUT_MS
            while (SystemClock.elapsedRealtime() < deadline &&
                runtime.readinessSnapshot.value == ProductReadinessState.UNKNOWN
            ) {
                SystemClock.sleep(POLL_INTERVAL_MS)
            }
            val diagnostic = runtime.currentReadinessRuntime.diagnosticObservation()
            val innerReadiness = runtime.currentReadinessRuntime.state.value
            val proxySnapshot = runtime.currentProxyRuntime.snapshot.value
            val proxyFailure = (proxySnapshot as? ProxyRuntimeSnapshot.Failed)?.reason
            val proxyFailureCode = proxyFailure?.name ?: "NONE"
            val rootAuthority = MagiskRootAuthority().probe()
            val mesh = runtime.meshSnapshot.value
            val ingressFailure = runtime.currentMeshRuntime.diagnosticIngressFailure()
            Log.i(TAG, "state=${runtime.readinessSnapshot.value}")
            Log.i(TAG, "inner_readiness=$innerReadiness")
            Log.i(TAG, "cellular_state=${diagnostic.cellularState}")
            Log.i(TAG, "cellular_reason=${diagnostic.cellularReason}")
            Log.i(TAG, "cellular_admitted=${diagnostic.cellularAdmitted}")
            Log.i(TAG, "root_policy=${diagnostic.rootPolicyVerified}")
            Log.i(TAG, "app_root_authority=$rootAuthority")
            Log.i(TAG, "proxy_healthy=${diagnostic.proxyHealthy}")
            Log.i(TAG, "proxy_lifecycle=${proxySnapshot.javaClass.simpleName}")
            Log.i(TAG, "proxy_failure=$proxyFailureCode")
            Log.i(TAG, "credential_active=${diagnostic.credentialActive}")
            Log.i(TAG, "mesh_admitted=${diagnostic.meshAdmitted}")
            Log.i(TAG, "mesh_epoch_present=${mesh?.admissionEpoch != null}")
            Log.i(TAG, "mesh_ingress_failure=$ingressFailure")
            Log.i(TAG, "binding_eligible=${diagnostic.bindingEligible}")
            runOnUiThread(::finish)
        }.start()
    }

    private companion object {
        const val TAG = "MishReadinessDiagnostic"
        const val OBSERVATION_TIMEOUT_MS = 20_000L
        const val POLL_INTERVAL_MS = 250L
    }
}
