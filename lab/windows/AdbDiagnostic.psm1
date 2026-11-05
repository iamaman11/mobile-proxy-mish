# ADB availability is a LAB observation, not a PRODUCT recovery policy.
# Never print or persist device serials.
Set-StrictMode -Version Latest

function Get-MishAdbAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Lines,
        [Parameter(Mandatory)][int] $ExitCode
    )
    if ($ExitCode -ne 0) { return 'ADB_ENUMERATION_FAILED' }
    $authorized = 0
    $unauthorized = 0
    $offline = 0
    foreach ($line in $Lines) {
        if ($line -match '^\S+\s+(?<status>device|unauthorized|offline)(?:\s|$)') {
            switch ($Matches.status) {
                'device'       { $authorized++ }
                'unauthorized' { $unauthorized++ }
                'offline'      { $offline++ }
            }
        }
    }
    $total = $authorized + $unauthorized + $offline
    if ($total -eq 0) { return 'ADB_DEVICE_MISSING' }
    if ($total -gt 1) { return 'ADB_MULTIPLE_DEVICES' }
    if ($unauthorized -eq 1) { return 'ADB_UNAUTHORIZED' }
    if ($offline -eq 1) { return 'ADB_OFFLINE' }
    if ($authorized -eq 1) { return 'READY' }
    return 'ADB_ENUMERATION_FAILED'
}

function Assert-MishAdbReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $FailurePrefix
    )
    if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
        throw "$FailurePrefix|ADB_MISSING|Canonical ADB executable is missing."
    }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $AdbPath devices 2>$null | ForEach-Object { [string]$_ })
        $code = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    $state = Get-MishAdbAvailability -Lines $lines -ExitCode $code
    if ($state -ne 'READY') {
        throw "$FailurePrefix|$state|Android USB debugging is not ready for one authenticated device."
    }
}

Export-ModuleMember -Function Get-MishAdbAvailability, Assert-MishAdbReady
