Set-StrictMode -Version Latest

function Test-MishCodexSandboxOutboundBlock {
    [CmdletBinding()]
    param()

    $command = Get-Command 'Get-NetFirewallRule' -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $false }

    try {
        $rules = @(
            Get-NetFirewallRule -Name 'codex_sandbox_offline_block_outbound' -ErrorAction Stop |
                Where-Object {
                    [string]$_.Enabled -eq 'True' -and
                    [string]$_.Direction -eq 'Outbound' -and
                    [string]$_.Action -eq 'Block'
                }
        )
        return $rules.Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-MishDeviceDiagnosticClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $PidStable,
        [Parameter(Mandatory)][bool] $AndroidConsistent,
        [Parameter(Mandatory)][bool] $RuntimeRunning,
        [string] $CellularState = 'ADMITTED',
        [string] $CellularReason = 'NONE',
        [bool] $CellularAdmitted = $true,
        [AllowNull()][string] $CellularBoundaryFailure,
        [string] $RootAuthorityObservation = 'READY_AT_POLICY_AUTHORIZATION',
        [bool] $RootPolicyAuthorized = $true,
        [Parameter(Mandatory)][string] $ProxyState,
        [Parameter(Mandatory)][bool] $ProxyHealthy,
        [AllowNull()][string] $ProxyFailure,
        [Parameter(Mandatory)][bool] $CredentialActive,
        [Parameter(Mandatory)][ValidateSet('NOT_ATTEMPTED', 'AVAILABLE', 'PROVISIONING_FAILED', 'OPEN_FAILED')]
        [string] $CredentialLeaseStatus,
        [Parameter(Mandatory)][string] $MeshState,
        [Parameter(Mandatory)][bool] $MeshAdmitted,
        [Parameter(Mandatory)][bool] $MeshEpochPresent,
        [Parameter(Mandatory)][bool] $MeshIngressRunning,
        [AllowNull()][string] $MeshIngressFailure,
        [Parameter(Mandatory)][string] $ReadinessState,
        [Parameter(Mandatory)][bool] $ReadinessBindingEligible,
        [Parameter(Mandatory)][string] $ReadinessProbeState,
        [Parameter(Mandatory)][string] $LoopbackResult,
        [Parameter(Mandatory)][string] $LoopbackReason,
        [Parameter(Mandatory)][int] $MeshEndpointCount,
        [Parameter(Mandatory)][bool] $RoutePresent,
        [Parameter(Mandatory)][bool] $Tcp3128,
        [Parameter(Mandatory)][string] $MeshProbeResult,
        [Parameter(Mandatory)][string] $MeshProbeReason
    )

    if (-not $PidStable) { return 'INVALID_PROCESS_CHANGED_DURING_CAPTURE' }
    if (-not $AndroidConsistent) { return 'INVALID_ANDROID_SNAPSHOT_CHANGED_DURING_CAPTURE' }

    # A terminal current-owner failure is the strongest causal fact. Downstream owners may have no
    # observation because startup stopped before they ran; never invent a historical failure class.
    if ($ProxyState -ceq 'FAILED') {
        $reason = if ([string]::IsNullOrWhiteSpace($ProxyFailure)) { 'UNKNOWN' } else { $ProxyFailure }
        return "PRODUCT_PROXY_$reason"
    }

    if (-not $RuntimeRunning) { return 'PRODUCT_RUNTIME_NOT_RUNNING' }

    if ($RootAuthorityObservation -ceq 'UNAVAILABLE') {
        return 'PRODUCT_ROOT_AUTHORITY_UNAVAILABLE'
    }
    if (-not [string]::IsNullOrWhiteSpace($CellularBoundaryFailure) -and $CellularBoundaryFailure -cne 'NONE') {
        return "PRODUCT_CELLULAR_BOUNDARY_$CellularBoundaryFailure"
    }
    if (-not $CellularAdmitted) {
        $state = if ([string]::IsNullOrWhiteSpace($CellularState)) { 'UNKNOWN' } else { $CellularState }
        $reason = if ([string]::IsNullOrWhiteSpace($CellularReason)) { 'UNKNOWN' } else { $CellularReason }
        return "PRODUCT_CELLULAR_${state}_${reason}"
    }
    if (-not $RootPolicyAuthorized) {
        return 'PRODUCT_ROOT_POLICY_NOT_AUTHORIZED'
    }

    if ($ProxyState -cne 'RUNNING') {
        $state = if ([string]::IsNullOrWhiteSpace($ProxyState)) { 'UNKNOWN' } else { $ProxyState }
        return "PRODUCT_PROXY_NOT_RUNNING_$state"
    }
    if (-not $ProxyHealthy) { return 'PRODUCT_PROXY_SERVING_UNHEALTHY' }

    if (-not $CredentialActive) { return 'PRODUCT_CREDENTIAL_INACTIVE' }
    switch ($CredentialLeaseStatus) {
        'PROVISIONING_FAILED' { return 'LAB_CREDENTIAL_PROVISIONING_FAILED' }
        'OPEN_FAILED' { return 'LAB_CREDENTIAL_LEASE_OPEN_FAILED' }
        'NOT_ATTEMPTED' { return 'LAB_CREDENTIAL_LEASE_NOT_ATTEMPTED' }
    }

    if (-not $MeshAdmitted) {
        $state = if ([string]::IsNullOrWhiteSpace($MeshState)) { 'UNKNOWN' } else { $MeshState }
        return "PRODUCT_MESH_NOT_ADMITTED_$state"
    }
    if (-not $MeshEpochPresent) { return 'PRODUCT_MESH_ADMISSION_EPOCH_MISSING' }
    if (-not $MeshIngressRunning) {
        $failure = if ([string]::IsNullOrWhiteSpace($MeshIngressFailure)) { 'UNKNOWN' } else { $MeshIngressFailure }
        return "PRODUCT_MESH_INGRESS_$failure"
    }

    if (-not $ReadinessBindingEligible) { return 'READINESS_BINDING_INELIGIBLE' }
    if ($ReadinessProbeState -cne 'SUCCEEDED') {
        $state = if ([string]::IsNullOrWhiteSpace($ReadinessProbeState)) { 'UNKNOWN' } else { $ReadinessProbeState }
        return "READINESS_PROBE_$state"
    }
    if ($ReadinessState -cne 'READY') { return 'READINESS_INTERNAL_PROJECTION_MISMATCH' }

    if ($LoopbackResult -cne 'PASS') { return "PRODUCT_LOOPBACK_E2E_$LoopbackReason" }
    if ($MeshEndpointCount -ne 1) { return 'MESH_ENDPOINT_CARDINALITY_INVALID' }
    if (-not $RoutePresent) { return 'WINDOWS_MESH_ROUTE_UNAVAILABLE' }
    if (-not $Tcp3128) {
        if (Test-MishCodexSandboxOutboundBlock) {
            return 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED'
        }
        return 'WINDOWS_MESH_TCP_3128_UNREACHABLE'
    }
    if ($MeshProbeResult -cne 'PASS') { return "WINDOWS_MESH_PROXY_E2E_$MeshProbeReason" }
    return 'PASS'
}

Export-ModuleMember -Function 'Get-MishDeviceDiagnosticClassification'
