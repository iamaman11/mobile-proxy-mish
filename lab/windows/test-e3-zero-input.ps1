[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if(-not $Condition){ throw $Message }
}

$workflowPath=Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) '.github/workflows/e3-physical-cellular.yml'
$workflow=Get-Content -Raw -LiteralPath $workflowPath

$dispatch=[regex]::Match($workflow,'(?ms)^  workflow_dispatch:\s*\r?\n(?<body>.*?)(?=^permissions:)')
Assert-True $dispatch.Success 'E3 workflow_dispatch block could not be isolated.'
Assert-True (-not $dispatch.Groups['body'].Value.Contains('inputs:')) 'Physical E3 must remain zero-input.'
Assert-True (-not $workflow.Contains('${{ inputs.rc_tag }}')) 'Physical E3 must not accept a human RC tag.'
Assert-True (-not $workflow.Contains('${{ inputs.mode }}')) 'Physical E3 must not accept a human execution mode.'
Assert-True ($workflow.Contains('python3 scripts/release/android_release.py next-rc')) 'E3 must derive the current RC from the canonical release lineage helper.'
Assert-True ($workflow.Contains('previous_tag')) 'E3 must consume the current machine-owned RC as next-rc.previous_tag.'
Assert-True ($workflow.Contains('git merge-base --is-ancestor "$SOURCE_SHA" origin/main')) 'Selected RC source must belong to accepted main history.'
Assert-True ($workflow.Contains('android/*|crates/*|Cargo.toml|Cargo.lock|rust-toolchain.toml|vendor/sing-box/release.toml|.github/actions/*')) 'E3 must reject a stale RC after product-impacting main changes.'
Assert-True ($workflow.Contains('release.get("immutable") is not True')) 'Selected RC must remain GitHub-native immutable.'
Assert-True ($workflow.Contains('RUN_MODE: full-root-toggle')) 'Manual physical E3 authorization must execute the full physical ceremony.'

$e3ModulePath=Join-Path $PSScriptRoot 'E3Harness.psm1'
$module=Import-Module $e3ModulePath -Force -PassThru
function Resolve-SyntheticFailure {
    param([Parameter(Mandatory)][string]$StdOut,[int]$ExitCode=1)
    return & $module { param($text,$code) Resolve-E3InstrumentationFailure -StdOut $text -ExitCode $code } $StdOut $ExitCode
}

Assert-True ((Resolve-SyntheticFailure 'expected:<ADMITTED> but was:<NOT_ADMITTED>') -eq 'positive_admission_timeout') 'Initial admission timeout classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'expected direct cellular Internet presence=true validated_required=true') -eq 'positive_direct_cellular_missing') 'Initial direct-cellular classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'network-scoped DNS returned no addresses') -eq 'positive_bound_probe_failed') 'Initial bound-probe classification drifted.'

$positive="E3_EVIDENCE phase=positive direct_cellular_validated=true`n"
Assert-True ((Resolve-SyntheticFailure ($positive + 'expected direct cellular Internet presence=false validated_required=false')) -eq 'negative_loss_timeout') 'Negative loss timeout classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positive + 'expected:<NOT_ADMITTED> but was:<ADMITTED>')) -eq 'negative_owner_timeout') 'Negative owner classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positive + 'pre-loss cellular lease must be revoked')) -eq 'negative_lease_revocation_failed') 'Negative lease-revocation classification drifted.'

$positiveNegative=$positive + "E3_EVIDENCE phase=negative direct_cellular_available=false`n"
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'expected:<ADMITTED> but was:<NOT_ADMITTED>')) -eq 'recovery_admission_timeout') 'Recovery admission timeout classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'expected direct cellular Internet presence=true validated_required=true')) -eq 'recovery_direct_cellular_missing') 'Recovery direct-cellular classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'recovery echo must be a bare IPv4/IPv6 literal')) -eq 'recovery_bound_probe_failed') 'Recovery bound-probe classification drifted.'

$complete=$positiveNegative + "E3_EVIDENCE phase=recovery direct_cellular_validated=true`nOK (1 test)"
Assert-True ((Resolve-SyntheticFailure $complete 0) -eq 'none') 'Successful lifecycle must not classify as a failure.'
Assert-True ((Resolve-SyntheticFailure 'unrecognized synthetic failure') -eq 'positive_unknown') 'Unknown pre-positive failures must remain fail-closed and typed.'

$moduleText=Get-Content -Raw -LiteralPath $e3ModulePath
Assert-True ($moduleText.Contains('raw device output is intentionally not persisted.')) 'E3 failure adapter must retain raw device-output non-persistence.'
Assert-True ($moduleText.Contains('reason=$reason')) 'E3 failure adapter must surface only the typed safe reason.'

Write-Host 'E3_ZERO_INPUT_CONTRACT=PASS'
Write-Host 'E3_TYPED_FAILURE_CLASSIFICATION=PASS'
$global:LASTEXITCODE=0
exit 0
