# AI-hint: One-shot AUTOMATED MiOS-XBOX ISO build orchestrator -- the full-specs, non-interactive, end-to-end pipeline. Chains: Install-MiOSBuildPrereqs (ADK oscdimg) -> Merge-MiOSPresets (protect-clean merged preset) -> New-MiOSISO (UUP-Dump Dev-channel fetch -> DISM offline servicing: remove capabilities/features + Xbox-FSE reg + Posture-B virt-enable -> autounattend with pre-logon MiOS-Host service + boot-into-Xbox + first-login hydration -> oscdimg dual BIOS/UEFI). Fully SSOT-driven, elevation-checked, transcript-logged, resumable, emits a build manifest. Designed to be launched by a scheduled task / gMSA / CI runner in a remote session (see docs/remote-build-auth.md) -- no interactive prompts, clean exit codes.
# AI-related: mios-bootstrap, Install-MiOSBuildPrereqs.ps1, Merge-MiOSPresets.ps1, New-MiOSISO.ps1, mios-uup-fetch.ps1, MiOS-Provision.lib.ps1, docs/uup-autounattend-dism-iso-flow.md
#Requires -Version 5.1
<#
.SYNOPSIS
    Automated, non-interactive MiOS-XBOX ISO build (full specs) from stock
    Dev-channel Microsoft media -- no NTLite, no manual steps.

.DESCRIPTION
    Run ELEVATED on a networked build host (or via a scheduled task / CI runner).
    Stages, each skippable + resumable:
      0. Install-MiOSBuildPrereqs.ps1  -> ADK oscdimg (+ optional WSL) via winget
      1. Merge-MiOSPresets.ps1         -> MiOS-Xbox-Merged.xml (protect-clean union)
      2. New-MiOSISO.ps1               -> the DISM-native ISO (internally: uup-fetch
                                          Dev -> extract -> service -> autounattend
                                          -> oscdimg)
    Emits a build manifest (JSON: stages, timings via the caller's clock, output
    path + SHA-256) and a full transcript. Exit code 0 = success; non-zero = the
    stage that failed. No Read-Host anywhere -- safe for unattended launch.

.PARAMETER TomlPath   mios.toml SSOT (default: layered lookup).
.PARAMETER SourceIso  Reuse a previously-fetched stock ISO (skips the UUP fetch).
.PARAMETER OutIso     Final MiOS-Xbox ISO (default: [autounattend].iso_out).
.PARAMETER WorkDir    Scratch dir.
.PARAMETER SkipPrereqs / -SkipMerge / -SkipWsl   Stage skips.

.EXAMPLE
    # interactive elevated one-shot
    .\Build-MiOSXboxISO.ps1

.EXAMPLE
    # unattended (scheduled task / CI): reuse a fetched ISO, explicit output
    .\Build-MiOSXboxISO.ps1 -SourceIso M:\MiOS\uup\dev.iso -OutIso M:\MiOS\iso\MiOS-Xbox.iso
#>
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$SourceIso,
    [string]$OutIso,
    [string]$WorkDir,
    [switch]$SkipPrereqs,
    [switch]$SkipMerge,
    [switch]$SkipWsl
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

# --- preflight ---------------------------------------------------------------
$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
# NB: Write-Error is terminating under ErrorActionPreference=Stop and would pre-empt
# our explicit exit codes -- emit failures as plain red text, then exit with a code.
function Fail { param([string]$m) Write-Host "ERROR: $m" -ForegroundColor Red }
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Build-MiOSXboxISO must run ELEVATED (DISM mounts + oscdimg). Launch via an elevated shell or a scheduled task with -RunLevel Highest."
    exit 10
}
if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml   = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }
if (-not $OutIso)  { $OutIso  = Get-Toml $toml 'autounattend.iso_out' 'M:\MiOS\iso\MiOS-Xbox.iso' }
if (-not $WorkDir) {
    $v = (Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.SizeRemaining -gt 20GB } | Sort-Object SizeRemaining -Descending | Select-Object -First 1)
    $WorkDir = if ($v) { Join-Path "$($v.DriveLetter):\" 'MiOS\isobuild' } else { Join-Path $env:TEMP 'mios-isobuild' }
}
$logDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# No Date.Now fabrication -- name the log by the process id + tick (monotonic).
$logFile = Join-Path $logDir ("build-{0}-{1}.log" -f $PID, [Environment]::TickCount)
Start-Transcript -Path $logFile -Force | Out-Null

$manifest = [ordered]@{ stages = [ordered]@{}; toml = $TomlPath; out_iso = $OutIso; work = $WorkDir; log = $logFile }
function Stage {
    param([string]$Name, [scriptblock]$Do, [int]$FailCode)
    Write-Host "`n==== [$Name] ====" -ForegroundColor Cyan
    $t0 = [Environment]::TickCount
    try { & $Do; $manifest.stages[$Name] = @{ ok = $true;  ms = ([Environment]::TickCount - $t0) } }
    catch {
        $manifest.stages[$Name] = @{ ok = $false; ms = ([Environment]::TickCount - $t0); error = "$($_.Exception.Message)" }
        Fail "[$Name] FAILED: $($_.Exception.Message)"
        $manifest | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 (Join-Path $WorkDir 'build-manifest.json')
        Stop-Transcript | Out-Null
        exit $FailCode
    }
}

Write-Host "MiOS-XBOX automated ISO build" -ForegroundColor Green
Write-Host "  SSOT   : $(if($TomlPath){$TomlPath}else{'(defaults)'})" -ForegroundColor DarkGray
Write-Host "  channel: $(Get-Toml $toml 'autounattend.uup_channel' 'dev')  out: $OutIso" -ForegroundColor DarkGray

# --- stage 0: build-host prereqs (ADK oscdimg) -------------------------------
if (-not $SkipPrereqs) {
    Stage 'prereqs' { & (Join-Path $PSScriptRoot 'Install-MiOSBuildPrereqs.ps1') -IncludeWsl:(-not $SkipWsl) } 20
} else { Write-Host '[skip] prereqs' -ForegroundColor DarkGray }

# --- stage 1: merged preset (protect-clean union) ----------------------------
# Write the build artifact into $WorkDir, NOT the repo checkout ($PSScriptRoot) --
# so a build never mutates a tracked file and two builds don't collide on the path.
$merged = Join-Path $WorkDir 'MiOS-Xbox-Merged.xml'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (-not $SkipMerge) {
    Stage 'merge' { & (Join-Path $PSScriptRoot 'Merge-MiOSPresets.ps1') -OutputPreset $merged } 30
} else { Write-Host '[skip] merge' -ForegroundColor DarkGray }

# --- stage 2: the DISM-native ISO (fetch Dev -> service -> autounattend -> oscdimg) ---
Stage 'iso' {
    $isoArgs = @{ TomlPath = $TomlPath; OutIso = $OutIso; WorkDir = $WorkDir; MergedPreset = $merged }
    if ($SourceIso) { $isoArgs['SourceIso'] = $SourceIso }
    & (Join-Path $PSScriptRoot 'New-MiOSISO.ps1') @isoArgs
} 40

# --- verify + manifest -------------------------------------------------------
if (-not (Test-Path $OutIso)) {
    Fail "Build reported success but $OutIso is missing."
    Stop-Transcript | Out-Null; exit 50
}
$size = [math]::Round((Get-Item $OutIso).Length / 1GB, 2)
$sha  = (Get-FileHash $OutIso -Algorithm SHA256).Hash
$manifest.out_size_gb = $size
$manifest.sha256      = $sha
$manifest.success     = $true
$manifest | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 (Join-Path $WorkDir 'build-manifest.json')

Write-Host "`n[+] MiOS-XBOX ISO built: $OutIso ($size GB)" -ForegroundColor Green
Write-Host "    sha256=$sha" -ForegroundColor DarkGray
Write-Host "    manifest=$(Join-Path $WorkDir 'build-manifest.json')  log=$logFile" -ForegroundColor DarkGray
Stop-Transcript | Out-Null
exit 0
