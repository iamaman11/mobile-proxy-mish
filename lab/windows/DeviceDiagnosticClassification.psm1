Set-StrictMode -Version Latest

function Get-MishDeviceDiagnosticClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $PidStable,
        [Parameter(Mandatory)][bool] $AndroidConsistent,
        [string] $CellularState = 'ADMITTED',
        [string] $CellularReason = 'NONE',
        [bool] $CellularAdmitted = $true,
        [string] $RootAuthorityObservation = 'READY_AT_POLICY_AUTHORIZATION',
        [bool] $RootPolicyAuthorized = $true,
        [Parameter(Mandatory)][string] $ProxyState,
        [AllowNull()][string] $ProxyFailure,
        [Parameter(Mandatory)][bool] $CredentialActive,
        [Parameter(Mandatory)][ValidateSet('NOT_ATTEMPTED', 'AVAILABLE', 'PROVISIONING_FAILED', 'OPEN_FAILED')]
        [string] $CredentialLeaseStatus,
        [Parameter(Mandatory)][string] $LoopbackResult,
        [Parameter(Mandatory)][string] $LoopbackReason,
        [Parameter(Mandatory)][string] $ReadinessState,
        [Parameter(Mandatory)][bool] $MeshIngressRunning,
        [AllowNull()][string] $MeshIngressFailure,
        [Parameter(Mandatory)][int] $MeshEndpointCount,
        [Parameter(Mandatory)][bool] $RoutePresent,
        [Parameter(Mandatory)][bool] $Tcp3128,
        [Parameter(Mandatory)][string] $MeshProbeResult,
        [Parameter(Mandatory)][string] $MeshProbeReason
    )

    if (-not $PidStable) { return 'INVALID_PROCESS_CHANGED_DURING_CAPTURE' }
    if (-not $AndroidConsistent) { return 'INVALID_ANDROID_SNAPSHOT_CHANGED_DURING_CAPTURE' }

    if ($RootAuthorityObservation -ceq 'UNAVAILABLE') {
        return 'PRODUCT_ROOT_AUTHORITY_UNAVAILABLE'
    }
    if (-not $CellularAdmitted) {
        $state = if ([string]::IsNullOrWhiteSpace($CellularState)) { 'UNKNOWN' } else { $CellularState }
        $reason = if ([string]::IsNullOrWhiteSpace($CellularReason)) { 'UNKNOWN' } else { $CellularReason }
        return "PRODUCT_CELLULAR_${state}_${reason}"
    }
    if (-not $RootPolicyAuthorized) {
        return 'PRODUCT_ROOT_POLICY_NOT_AUTHORIZED'
    }

    if ($ProxyState -ceq 'FAILED') {
        $reason = if ([string]::IsNullOrWhiteSpace($ProxyFailure)) { 'UNKNOWN' } else { $ProxyFailure }
        return "PRODUCT_PROXY_$reason"
    }
    if ($ProxyState -cne 'RUNNING') {
        $state = if ([string]::IsNullOrWhiteSpace($ProxyState)) { 'UNKNOWN' } else { $ProxyState }
        return "PRODUCT_PROXY_NOT_RUNNING_$state"
    }

    if (-not $CredentialActive) { return 'PRODUCT_CREDENTIAL_INACTIVE' }
    switch ($CredentialLeaseStatus) {
        'PROVISIONING_FAILED' { return 'LAB_CREDENTIAL_PROVISIONING_FAILED' }
        'OPEN_FAILED' { return 'LAB_CREDENTIAL_LEASE_OPEN_FAILED' }
        'NOT_ATTEMPTED' { return 'LAB_CREDENTIAL_LEASE_NOT_ATTEMPTED' }
    }

    if ($LoopbackResult -cne 'PASS') { return "PRODUCT_LOOPBACK_E2E_$LoopbackReason" }
    if ($ReadinessState -cne 'READY') { return 'READINESS_INTERNAL_PROBE_MISMATCH' }
    if (-not $MeshIngressRunning) {
        $failure = if ([string]::IsNullOrWhiteSpace($MeshIngressFailure)) { 'UNKNOWN' } else { $MeshIngressFailure }
        return "MESH_INGRESS_$failure"
    }
    if ($MeshEndpointCount -ne 1) { return 'MESH_ENDPOINT_CARDINALITY_INVALID' }
    if (-not $RoutePresent) { return 'WINDOWS_MESH_ROUTE_UNAVAILABLE' }
    if (-not $Tcp3128) { return 'WINDOWS_MESH_TCP_3128_UNREACHABLE' }
    if ($MeshProbeResult -cne 'PASS') { return "WINDOWS_MESH_PROXY_E2E_$MeshProbeReason" }
    return 'PASS'
}

Export-ModuleMember -Function 'Get-MishDeviceDiagnosticClassification'
