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
Assert-True ((Resolve-SyntheticFailure 'network-scoped DNS returned no addresses') -eq 'positive_dns_empty') 'Positive empty-DNS classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'Android explicit-network DNS lookup failed') -eq 'positive_dns_lookup_failed') 'Positive native DNS failure classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'Android explicit-network DNS lookup returned no addresses') -eq 'positive_dns_empty') 'Positive native empty-DNS classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'Android explicit-network DNS address conversion failed') -eq 'positive_address_conversion_failed') 'Positive native address-conversion classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'lease must return numeric IP strings') -eq 'positive_address_conversion_failed') 'Positive lease address-conversion classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'Android explicit-network socket binding failed') -eq 'positive_socket_bind_failed') 'Positive socket-bind classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'android.system.ErrnoException: connect failed: ENETUNREACH') -eq 'positive_connect_failed') 'Positive connect classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'E3 echo endpoint must return HTTP 200') -eq 'positive_http_status_failed') 'Positive HTTP-status classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'socket write made no progress') -eq 'positive_response_io_failed') 'Positive write-progress classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'android.system.ErrnoException: read failed: ETIMEDOUT') -eq 'positive_response_io_failed') 'Positive read failure classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'E3 HTTP response exceeded 64 KiB') -eq 'positive_response_io_failed') 'Positive bounded-response classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'HTTP response must contain header/body separator') -eq 'positive_response_parse_failed') 'Positive response-parse classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'echo response must be a bare IPv4/IPv6 literal') -eq 'positive_public_ip_parse_failed') 'Positive public-IP parse classification drifted.'
Assert-True ((Resolve-SyntheticFailure 'all lease-resolved addresses failed') -eq 'positive_bound_probe_unknown') 'Positive probe fallback must remain fail-closed and non-speculative.'

$positive="E3_EVIDENCE phase=positive direct_cellular_validated=true`n"
Assert-True ((Resolve-SyntheticFailure ($positive + 'expected direct cellular Internet presence=false validated_required=false')) -eq 'negative_loss_timeout') 'Negative loss timeout classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positive + 'expected:<NOT_ADMITTED> but was:<ADMITTED>')) -eq 'negative_owner_timeout') 'Negative owner classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positive + 'pre-loss cellular lease must be revoked')) -eq 'negative_lease_revocation_failed') 'Negative lease-revocation classification drifted.'

$positiveNegative=$positive + "E3_EVIDENCE phase=negative direct_cellular_available=false`n"
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'expected:<ADMITTED> but was:<NOT_ADMITTED>')) -eq 'recovery_admission_timeout') 'Recovery admission timeout classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'expected direct cellular Internet presence=true validated_required=true')) -eq 'recovery_direct_cellular_missing') 'Recovery direct-cellular classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'Android explicit-network socket binding failed')) -eq 'recovery_socket_bind_failed') 'Recovery socket-bind classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'recovery echo must be a bare IPv4/IPv6 literal')) -eq 'recovery_public_ip_parse_failed') 'Recovery public-IP parse classification drifted.'
Assert-True ((Resolve-SyntheticFailure ($positiveNegative + 'all lease-resolved addresses failed')) -eq 'recovery_bound_probe_unknown') 'Recovery probe fallback must remain fail-closed and non-speculative.'

$complete=$positiveNegative + "E3_EVIDENCE phase=recovery direct_cellular_validated=true`nOK (1 test)"
Assert-True ((Resolve-SyntheticFailure $complete 0) -eq 'none') 'Successful lifecycle must not classify as a failure.'
Assert-True ((Resolve-SyntheticFailure 'unrecognized synthetic failure') -eq 'positive_unknown') 'Unknown pre-positive failures must remain fail-closed and typed.'

$moduleText=Get-Content -Raw -LiteralPath $e3ModulePath
Assert-True ($moduleText.Contains('raw device output is intentionally not persisted.')) 'E3 failure adapter must retain raw device-output non-persistence.'
Assert-True ($moduleText.Contains('reason=$reason')) 'E3 failure adapter must surface only the typed safe reason.'
Assert-True (-not $moduleText.Contains("return 'positive_bound_probe_failed'")) 'Generic positive bound-probe collapse must stay removed.'
Assert-True (-not $moduleText.Contains("return 'recovery_bound_probe_failed'")) 'Generic recovery bound-probe collapse must stay removed.'

Write-Host 'E3_ZERO_INPUT_CONTRACT=PASS'
Write-Host 'E3_TYPED_FAILURE_CLASSIFICATION=PASS'
$global:LASTEXITCODE=0
exit 0
