# tests/test_install_host_tools.ps1
# Two-sided regression test for the winget ladder in src/install-host-tools.ps1 (Task T-1142).
#
# Positive mode (default) runs the REAL script under a fully mocked, hermetic harness:
#   - a mock `winget` FUNCTION (functions shadow winget.exe for `& winget`) that records
#     every invocation's arguments and scripts $LASTEXITCODE per a scenario table,
#     including one package whose install exits -1978335189 (= 0x8A15002B);
#   - mock Log-Ok/Log-Warn/Write-Log/Set-Step/Get-MiosTomlValue, mock Invoke-RestMethod/
#     Invoke-WebRequest (network disabled), no-op functions for the direct-download tools
#     the script guards on via Get-Command;
#   - $env:LOCALAPPDATA/$env:TEMP/$env:ProgramFiles/${env:ProgramFiles(x86)} redirected
#     into a scratch tree; $MiosBinDir/$MiosRepoDir/$MiosBootstrapShadow pointed at scratch;
#   - Test-Path is shadowed to return $false for EXACTLY the two foreign vendor toml
#     candidates (M:\etc\mios\mios.toml, M:\usr\share\mios\mios.toml) so the controlled
#     package list in the scratch $MiosBootstrapShadow\mios.toml is the only source;
#     every other Test-Path call delegates to the real cmdlet.
# Assertions: orphaned-but-seen pkg installs with EXACTLY ONE '--force' token (and zero
# single-char tokens); fresh pkg installs with NO '--force'; 0x8A15002B is classified as
# already-installed (log line + PATH verify, no second attempt, no third retry) and never
# counted as failed; no '--ignore-security-hash' argument ever; User PATH and
# BTOP_CONFIG_DIR (User scope) untouched.
#
# Recorded install arguments are kept in per-package List[object] collections that are
# read by direct indexing only: passing arrays-of-arrays across a function-return or
# pipeline boundary re-wraps them in PowerShell, which corrupted naive approaches.
#
# Negative mode (-PlantDefect) byte-replants the original collapsed forceArgs line into a
# scratch copy and EXPECTS the defect signature: the recorded install args enumerate the
# string '--force' char-by-char (- - f o r c e).
#
# Run from repo root:
#   pwsh -NoProfile -File tests\test_install_host_tools.ps1
#   pwsh -NoProfile -File tests\test_install_host_tools.ps1 -PlantDefect

[CmdletBinding()]
param(
    [switch]$PlantDefect
)

$ErrorActionPreference = "Continue"

$repoRoot = Split-Path $PSScriptRoot -Parent
$targetScript = Join-Path $repoRoot "src\install-host-tools.ps1"

if (-not (Test-Path -LiteralPath $targetScript)) {
    Write-Error "src/install-host-tools.ps1 not found at $targetScript"
    exit 1
}

# Scratch tree (nothing outside it may be written).
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("lanez-t1142-scratch-" + $PID)
$shadowDir = Join-Path $scratch "shadow"
$mockBinsDir = Join-Path $scratch "mockbins"
$localDir = Join-Path $scratch "local"
$tmpDir = Join-Path $scratch "tmp"
foreach ($d in @($scratch, $shadowDir, $mockBinsDir)) {
    $null = New-Item -ItemType Directory -Path $d -Force
}
$scriptUnderTest = $targetScript

# Scenario table: listSeen drives `winget list`; installExits scripts consecutive
# install attempt exit codes. -1978335189 == 0x8A15002B (APPINSTALLER_CLI_ERROR_
# PACKAGE_ALREADY_INSTALLED, Int32 in $LASTEXITCODE).
$script:WingetScenario = @{
    "Mock.Skip.Pkg"   = @{ listSeen = $true;  installExits = @(0) }
    "Mock.Orphan.Pkg" = @{ listSeen = $true;  installExits = @(0) }
    "Mock.Fresh.Pkg"  = @{ listSeen = $false; installExits = @(-1978335189) }
    "Mock.Retry.Pkg"  = @{ listSeen = $false; installExits = @(1, -1978335189) }
}

$script:MockLog = [System.Collections.Generic.List[string]]::new()
$script:WingetCalls = [System.Collections.Generic.List[object]]::new()
$script:InstallArgsByPkg = @{}
$script:WingetInstallCount = @{}
$script:WingetCallFile = Join-Path $scratch "winget-calls.log"
$script:HarnessError = $null
$script:passedCount = 0
$script:failedCount = 0

function Assert-Condition {
    param(
        [string]$TestName,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        Write-Host "  [+] PASS: $TestName" -ForegroundColor Green
        $script:passedCount++
    } else {
        Write-Host "  [!] FAIL: $TestName" -ForegroundColor Red
        Write-Error "assertion failed: $TestName $(if ($Details) { "-- $Details" } else { '' })"
        if ($Details) {
            Write-Host "      Details: $Details" -ForegroundColor Yellow
        }
        $script:failedCount++
    }
}

function Get-CallCount {
    param($Calls)
    if ($null -ne $Calls) { return $Calls.Count }
    return 0
}

function Get-TokenCount {
    param($CallArgs, [string]$Token)
    $n = 0
    foreach ($t in $CallArgs) {
        if ("$t" -eq $Token) { $n++ }
    }
    return $n
}

function Get-SingleCharArgCount {
    param($CallArgs)
    $n = 0
    foreach ($t in $CallArgs) {
        if ("$t".Length -eq 1) { $n++ }
    }
    return $n
}

# ---------------------------------------------------------------------------
# Mock harness (defined BEFORE the script under test is invoked)
# ---------------------------------------------------------------------------
function Log-Ok    { param([string]$Message) $script:MockLog.Add("OK: $Message") }
function Log-Warn  { param([string]$Message) $script:MockLog.Add("WARN: $Message") }
function Write-Log { param([string]$Message) $script:MockLog.Add("LOG: $Message") }
function Set-Step  { param([string]$Message) $script:MockLog.Add("STEP: $Message") }

function Get-MiosTomlValue {
    param($Section, $Key, $Default)
    switch ("$Section|$Key") {
        "packages.windows|bin_map"      { return @(
            "Mock.Skip.Pkg|mockskipbin",
            "Mock.Orphan.Pkg|orphanbin",
            "Mock.Fresh.Pkg|mockokbin",
            "Mock.Retry.Pkg|retrybin"
        ) }
        "packages.windows|verify_probes" { return @() }
        "browser_ai|enable"              { return "false" }
        default                          { return $Default }
    }
}

# winget mock: functions shadow winget.exe for `& winget`. Records every invocation's
# full argument list (structure-preserving) plus a human-readable log file line; install
# arguments additionally land in a per-package List read only by direct indexing.
function winget {
    $a = @($args)
    $script:WingetCalls.Add($a)
    Add-Content -LiteralPath $script:WingetCallFile -Value (($a | ForEach-Object { "[$_]" }) -join " ")
    if ($a.Count -ge 3 -and $a[0] -eq "list" -and $a[1] -eq "--id") {
        $id = [string]$a[2]
        $scen = $script:WingetScenario[$id]
        if ($scen -and $scen["listSeen"]) {
            Write-Output $id
            $global:LASTEXITCODE = 0
        } else {
            $global:LASTEXITCODE = 1
        }
        return
    }
    if ($a.Count -ge 3 -and $a[0] -eq "install" -and $a[1] -eq "--id") {
        $id = [string]$a[2]
        if (-not $script:InstallArgsByPkg.ContainsKey($id)) {
            $script:InstallArgsByPkg[$id] = [System.Collections.Generic.List[object]]::new()
        }
        $script:InstallArgsByPkg[$id].Add($a)
        if (-not $script:WingetInstallCount.ContainsKey($id)) { $script:WingetInstallCount[$id] = 0 }
        $script:WingetInstallCount[$id]++
        $n = $script:WingetInstallCount[$id]
        $codes = @($script:WingetScenario[$id]["installExits"])
        $code = $codes[$codes.Count - 1]
        if ($n -le $codes.Count) { $code = $codes[$n - 1] }
        $global:LASTEXITCODE = [int]$code
        return
    }
    $global:LASTEXITCODE = 0
}

# Test-Path shadow: hermeticity for the toml candidate resolution ONLY. The two foreign
# vendor toml paths are reported as absent so the scratch shadow mios.toml wins; all
# other queries delegate verbatim to the real cmdlet.
$script:RealTestPathCmd = Get-Command -Name Test-Path -CommandType Cmdlet | Select-Object -First 1
$script:BlockedTomlPaths = @("M:\etc\mios\mios.toml", "M:\usr\share\mios\mios.toml")
function Test-Path {
    foreach ($argValue in $args) {
        if ($argValue -is [string] -and $script:BlockedTomlPaths -contains $argValue) { return $false }
    }
    return & $script:RealTestPathCmd @args
}

# Network disabled: any direct-download fallback must fail fast into its catch block.
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Headers)
    throw "mock harness: network disabled ($Uri)"
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $OutFile, $UseBasicParsing)
    throw "mock harness: network disabled ($Uri)"
}

# No-op stand-ins for the tools the script guards on via Get-Command, so every
# direct-download block skips without touching the network.
function fastfetch { }
function rg { }
function fzf { }
function jq { }
function bat { }
function fd { }
function gh { }

# ---------------------------------------------------------------------------
# Fixtures + environment
# ---------------------------------------------------------------------------
$toml = "[packages.windows]`r`npkgs = [`"Mock.Skip.Pkg`", `"Mock.Orphan.Pkg`", `"Mock.Fresh.Pkg`", `"Mock.Retry.Pkg`"]`r`n"
[System.IO.File]::WriteAllText((Join-Path $shadowDir "mios.toml"), $toml, [System.Text.UTF8Encoding]::new($false))

$null = New-Item -ItemType File -Path (Join-Path $mockBinsDir "mockskipbin.exe") -Force
$null = New-Item -ItemType File -Path (Join-Path $mockBinsDir "mockokbin.exe") -Force
# orphanbin / retrybin deliberately NOT created (bin-missing scenario).

if ($PlantDefect) {
    $fixedLine = '            $forceArgs = @(if ($wingetSeesIt) { ''--force'' })'
    $collapsedLine = '            $forceArgs = if ($wingetSeesIt) { @(''--force'') } else { @() }'
    $text = [System.IO.File]::ReadAllText($targetScript)
    if (-not $text.Contains($fixedLine)) {
        Write-Error "PlantDefect: fixed forceArgs line not found in src/install-host-tools.ps1"
        exit 1
    }
    $scriptUnderTest = Join-Path $scratch "planted-install-host-tools.ps1"
    [System.IO.File]::WriteAllText($scriptUnderTest, $text.Replace($fixedLine, $collapsedLine), [System.Text.UTF8Encoding]::new($true))
    Write-Host "[negative control] planted collapsed forceArgs line into $scriptUnderTest" -ForegroundColor Yellow
}

$savedLocalAppData = $env:LOCALAPPDATA
$savedTemp = $env:TEMP
$savedProgramFiles = $env:ProgramFiles
$savedProgramFilesX86 = ${env:ProgramFiles(x86)}
$savedPath = $env:PATH
$userPathBefore = [Environment]::GetEnvironmentVariable("PATH", "User")
$btopBefore = [Environment]::GetEnvironmentVariable("BTOP_CONFIG_DIR", "User")

$env:LOCALAPPDATA = $localDir
$env:TEMP = $tmpDir
$env:ProgramFiles = Join-Path $scratch "ProgramFiles"
${env:ProgramFiles(x86)} = Join-Path $scratch "ProgramFilesx86"
$env:PATH = "$mockBinsDir;$env:PATH"

# Variables the dot-sourced script resolves through the scope chain (not env vars).
$MiosBinDir = Join-Path $scratch "bin"        # deliberately NOT created (no User PATH persist)
$MiosRepoDir = Join-Path $scratch "repo"
$MiosBootstrapShadow = $shadowDir

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  install-host-tools.ps1 winget ladder tests (T-1142)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

try {
    . $scriptUnderTest

    try {
        Install-MiosWindowsTools
    } catch {
        $script:HarnessError = $_.Exception.Message
        $script:MockLog.Add("HARNESS-ERROR: $script:HarnessError")
    }

    $userPathAfter = [Environment]::GetEnvironmentVariable("PATH", "User")
    $btopAfter = [Environment]::GetEnvironmentVariable("BTOP_CONFIG_DIR", "User")
    $logText = $script:MockLog -join "`n"

    $skipCalls = $script:InstallArgsByPkg["Mock.Skip.Pkg"]
    $orphanCalls = $script:InstallArgsByPkg["Mock.Orphan.Pkg"]
    $freshCalls = $script:InstallArgsByPkg["Mock.Fresh.Pkg"]
    $retryCalls = $script:InstallArgsByPkg["Mock.Retry.Pkg"]

    if ($PlantDefect) {
        # Negative control: the collapsed if-expression unwraps @('--force') to a
        # scalar String, and splatting a String enumerates it char-by-char.
        $singleChars = @()
        if ((Get-CallCount $orphanCalls) -ge 1) {
            foreach ($t in $orphanCalls[0]) {
                if ("$t".Length -eq 1) { $singleChars += "$t" }
            }
        }
        $expectedSeq = @("-", "-", "f", "o", "r", "c", "e")
        $seqMatch = ($singleChars.Count -eq $expectedSeq.Count)
        if ($seqMatch) {
            for ($i = 0; $i -lt $expectedSeq.Count; $i++) {
                if ($singleChars[$i] -ne $expectedSeq[$i]) { $seqMatch = $false }
            }
        }
        $hasWholeToken = ((Get-CallCount $orphanCalls) -ge 1) -and ((Get-TokenCount $orphanCalls[0] "--force") -gt 0)
        if ($seqMatch -and -not $hasWholeToken) {
            Write-Host "PLANTED DEFECT REPRODUCED: forceArgs char-enumerated: - - f o r c e" -ForegroundColor Yellow
            exit 0
        }
        Write-Error "negative control failed: planted collapse did not reproduce"
        exit 1
    }

    Write-Host "`n[Suite 1] skip path (seen + bin on PATH)" -ForegroundColor Yellow
    Assert-Condition "seen+on-PATH pkg triggers ZERO install calls" ( (Get-CallCount $skipCalls) -eq 0 ) ("install calls: $(Get-CallCount $skipCalls)")
    Assert-Condition "seen+on-PATH pkg logged as already-present" ( $logText.Contains("winget already-present: Mock.Skip.Pkg") )

    Write-Host "`n[Suite 2] orphan path (seen + bin missing): --force splat" -ForegroundColor Yellow
    $orphanCount = Get-CallCount $orphanCalls
    Assert-Condition "orphan pkg: exactly one install call" ( $orphanCount -eq 1 ) ("install calls: $orphanCount")
    if ($orphanCount -ge 1) {
        Assert-Condition "orphan install call carries EXACTLY ONE '--force' token" ( (Get-TokenCount $orphanCalls[0] "--force") -eq 1 ) ("--force tokens: $(Get-TokenCount $orphanCalls[0] '--force'); args: [$($orphanCalls[0] -join ' ')]")
        Assert-Condition "orphan install call carries ZERO single-character tokens" ( (Get-SingleCharArgCount $orphanCalls[0]) -eq 0 ) ("single-char tokens: $(Get-SingleCharArgCount $orphanCalls[0])")
    } else {
        Assert-Condition "orphan install call carries EXACTLY ONE '--force' token" $false "no install call recorded"
        Assert-Condition "orphan install call carries ZERO single-character tokens" $false "no install call recorded"
    }
    Assert-Condition "orphan pkg logged the forcing-reinstall warning" ( $logText.Contains("winget claims Mock.Orphan.Pkg present but 'orphanbin' not on PATH -- forcing reinstall") )

    Write-Host "`n[Suite 3] fresh path + 0x8A15002B classification (first attempt)" -ForegroundColor Yellow
    $freshCount = Get-CallCount $freshCalls
    Assert-Condition "fresh pkg: exactly one install call (no second attempt)" ( $freshCount -eq 1 ) ("install calls: $freshCount")
    if ($freshCount -ge 1) {
        Assert-Condition "fresh install call carries NO '--force' token" ( (Get-TokenCount $freshCalls[0] "--force") -eq 0 )
    } else {
        Assert-Condition "fresh install call carries NO '--force' token" $false "no install call recorded"
    }
    Assert-Condition "0x8A15002B logged as already installed" ( $logText.Contains("winget install: Mock.Fresh.Pkg already installed (winget 0x8A15002B)") )
    Assert-Condition "0x8A15002B path verifies bin on PATH" ( $logText.Contains("winget already-present: Mock.Fresh.Pkg ('mockokbin' on PATH)") )

    Write-Host "`n[Suite 4] retry path + 0x8A15002B classification (second attempt)" -ForegroundColor Yellow
    $retryCount = Get-CallCount $retryCalls
    Assert-Condition "retry pkg: exactly two install calls" ( $retryCount -eq 2 ) ("install calls: $retryCount")
    if ($retryCount -eq 2) {
        Assert-Condition "retry attempt 1 carries --scope user" ( (Get-TokenCount $retryCalls[0] "--scope") -eq 1 )
        Assert-Condition "retry attempt 2 drops --scope" ( (Get-TokenCount $retryCalls[1] "--scope") -eq 0 )
    }
    Assert-Condition "retry 0x8A15002B logged as already installed" ( $logText.Contains("winget install (retry): Mock.Retry.Pkg already installed (winget 0x8A15002B)") )
    Assert-Condition "retry 0x8A15002B path warns when bin missing" ( $logText.Contains("winget claims Mock.Retry.Pkg already installed but 'retrybin' not on PATH") )

    Write-Host "`n[Suite 5] --ignore-security-hash removal + counters" -ForegroundColor Yellow
    $hashHits = 0
    foreach ($c in $script:WingetCalls) {
        foreach ($t in $c) {
            if ("$t" -like "*ignore-security-hash*") { $hashHits++ }
        }
    }
    Assert-Condition "no recorded argument mentions ignore-security-hash" ( $hashHits -eq 0 ) ("hits: $hashHits")
    Assert-Condition "no third (hash) install attempt for any pkg" ( $retryCount -le 2 )
    Assert-Condition "summary counts 0x8A15002B as already-present, not failed" ( $logText.Contains("winget summary: 1 installed / 3 already-present / 0 failed") )
    Assert-Condition "script completed without a terminating error" ( $null -eq $script:HarnessError ) ("$script:HarnessError")

    Write-Host "`n[Suite 6] hermeticity (nothing written outside scratch)" -ForegroundColor Yellow
    Assert-Condition "User PATH unchanged" ( $userPathAfter -ceq $userPathBefore ) ("before='$userPathBefore' after='$userPathAfter'")
    Assert-Condition "User BTOP_CONFIG_DIR unchanged" ( "$btopAfter" -ceq "$btopBefore" ) ("before='$btopBefore' after='$btopAfter'")
    $callLines = @(Get-Content -LiteralPath $script:WingetCallFile -ErrorAction SilentlyContinue)
    Assert-Condition "winget call log recorded all invocations" ( $callLines.Count -ge 8 ) ("lines: $($callLines.Count)")
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:TEMP = $savedTemp
    $env:ProgramFiles = $savedProgramFiles
    ${env:ProgramFiles(x86)} = $savedProgramFilesX86
    $env:PATH = $savedPath
    $userPathRestored = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPathRestored -cne $userPathBefore) {
        [Environment]::SetEnvironmentVariable("PATH", $userPathBefore, "User")
    }
    $btopRestored = [Environment]::GetEnvironmentVariable("BTOP_CONFIG_DIR", "User")
    if ("$btopRestored" -cne "$btopBefore") {
        [Environment]::SetEnvironmentVariable("BTOP_CONFIG_DIR", $btopBefore, "User")
    }
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Test Summary: Passed = $($script:passedCount), Failed = $($script:failedCount)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
if ($script:failedCount -gt 0) {
    exit 1
}
Write-Host "T-1142 positive controls: ALL PASS" -ForegroundColor Green
exit 0
