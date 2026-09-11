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

Write-Host 'E3_ZERO_INPUT_CONTRACT=PASS'
$global:LASTEXITCODE=0
exit 0
