[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-public-ip-u4-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schema = 'mish.lab.public-ip-u4/v1'
$testPackage = "$PackageName.test"
$testClass = 'com.mobileproxymish.app.cellular.PublicIpU4InstrumentedTest'
$testMethod = 'runPhysicalScenario'
$testComponent = "$testPackage/androidx.test.runner.AndroidJUnitRunner"

function Stop-MishU4 {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_U4_PUBLIC_IP_FAILURE|$Classification|$Message"
}

function Invoke-MishProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 60
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-MishU4 'LAB_U4_PROCESS_START_FAILED' 'Required subprocess could not be started.'
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Stop-MishU4 'LAB_U4_PROCESS_TIMEOUT' 'Required subprocess exceeded its bounded timeout.'
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MishAdb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 60
    )
    Invoke-MishProcess -FilePath $AdbPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Stop-MishProductProcessForInstrumentation {
    $forceStop = Invoke-MishAdb -Arguments @('shell', 'am', 'force-stop', $PackageName) -TimeoutSeconds 20
    if ($forceStop.ExitCode -ne 0) {
        Stop-MishU4 'LAB_U4_INSTRUMENTATION_HANDOFF_FAILED' 'PRODUCT process could not be stopped.'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do {
        $processId = Invoke-MishAdb -Arguments @('shell', 'pidof', $PackageName) -TimeoutSeconds 10
        if ([string]::IsNullOrWhiteSpace($processId.StdOut)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    Stop-MishU4 'LAB_U4_INSTRUMENTATION_HANDOFF_FAILED' 'PRODUCT process remained alive after force-stop.'
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishU4 'LAB_U4_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$testPath = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $testPackage) -TimeoutSeconds 20
$testRows = @($testPath.StdOut -split "`r?`n" | Where-Object { $_ -match '^package:.+/base\.apk$' })
if ($testPath.ExitCode -ne 0 -or $testRows.Count -ne 1) {
    Stop-MishU4 'LAB_U4_TEST_HARNESS_MISSING' 'Exact candidate androidTest package is not installed.'
}

Stop-MishProductProcessForInstrumentation

$instrumentation = Invoke-MishAdb -Arguments @(
    'shell', 'am', 'instrument', '-w', '-r',
    '-e', 'class', $testClass,
    $testComponent
) -TimeoutSeconds 300

$output = (($instrumentation.StdOut, $instrumentation.StdErr) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"

$dispatched = $output -match "(?im)^INSTRUMENTATION_STATUS:\s*test=$([regex]::Escape($testMethod))\s*$"
$instrumentationPass = (
    $instrumentation.ExitCode -eq 0 -and
    $dispatched -and
    $output -match '(?m)^OK \(1 test\)\s*$'
)

$evidencePattern =
    '(?m)^INSTRUMENTATION_STATUS:\s*u4_evidence=phase=u4 ' +
    'positive=true https=true owner_bound_dns=true ordinary_uid_socket=true ' +
    'stale_generation_rejected=true no_default_fallback=true ' +
    'fresh_generation=true repeated_observations_bounded=true\s*$'
$semanticPass = $output -match $evidencePattern

$classification = if (-not $dispatched) {
    'LAB_U4_TEST_HARNESS_EXECUTION_UNPROVEN'
}
elseif ($instrumentationPass -and $semanticPass) {
    'U4_PUBLIC_IP_PASS'
}
else {
    'U4_PUBLIC_IP_FAILED'
}

$acceptanceResult = if ($classification -ceq 'U4_PUBLIC_IP_PASS') { 'PASS' } else { 'FAIL' }

$evidence = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = $acceptanceResult
    classification = $classification
    instrumentation_test_dispatched = $dispatched
    instrumentation_pass = $instrumentationPass
    positive_https_observation = $semanticPass
    owner_bound_dns = $semanticPass
    ordinary_product_uid_socket = $semanticPass
    stale_generation_rejected = $semanticPass
    no_default_fallback = $semanticPass
    fresh_generation_observed = $semanticPass
    repeated_observations_bounded = $semanticPass
    raw_public_ip_persisted = $false
}

$directory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
if (-not [string]::IsNullOrWhiteSpace($directory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
$evidence | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $EvidencePath

Write-Host "MISH_U4_PUBLIC_IP_CLASSIFICATION=$classification"
Write-Host "MISH_U4_PUBLIC_IP_ACCEPTANCE=$acceptanceResult"

if ($acceptanceResult -cne 'PASS') {
    Stop-MishU4 $classification 'U4 physical public-IP acceptance did not pass.'
}
