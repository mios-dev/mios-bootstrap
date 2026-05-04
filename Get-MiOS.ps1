<#
.SYNOPSIS
    'MiOS' bootstrap -- canonical Windows one-liner entry point.

.DESCRIPTION
    Designed for: irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex

    Thin entrypoint that:
      1. Elevates to Administrator (re-launches a NEW window so the
         operator sees a clean, properly-sized terminal).
      2. Resizes the host window to ~100x40 so the build dashboard
         frame (80 cols + breathing room) fits without wrapping.
      3. Verifies Git + Podman are present.
      4. Clones / updates the mios-bootstrap repo into
         $env:USERPROFILE\MiOS-bootstrap.
      5. Hands off to bootstrap.ps1 -- the new split-bootstrap entry
         (default: -BootstrapOnly = preflight + dev VM + Windows
         install; the deployable OCI image is built later via the
         "Build MiOS" Start Menu shortcut bootstrap.ps1 drops).

    Pre-v0.2.4 this script wrapped the run in Start-Transcript --
    that captured the dashboard's cursor escapes and broke the
    in-place repaint. Removed: build-mios.ps1 writes its own unified
    log directly via [IO.File]::AppendAllText (no transcript needed).

    Pass -FullBuild to chain the OCI image build immediately
    (legacy one-shot behavior).

.PARAMETER RepoUrl
    git URL for mios-bootstrap (default: GitHub upstream).

.PARAMETER Branch
    Branch to clone (default: main).

.PARAMETER RepoDir
    Local clone target (default: $USERPROFILE\MiOS-bootstrap).

.PARAMETER FullBuild
    Run the full pipeline in one shot (preflight + dev VM + Windows
    install + OCI build + deploy). Equivalent to passing -FullBuild
    through to bootstrap.ps1.

.PARAMETER Unattended
    Take all defaults; skip interactive prompts.

.PARAMETER Workflow
    Optional preset workflow name (legacy parameter; passed through
    via $env:MIOS_WORKFLOW for any consumer that reads it).
#>
param(
    [string]$RepoUrl   = "https://github.com/mios-dev/mios-bootstrap.git",
    [string]$Branch    = "main",
    [string]$RepoDir   = (Join-Path $env:USERPROFILE "MiOS-bootstrap"),
    [switch]$FullBuild,
    [switch]$Unattended,
    [string]$Workflow  = ""
)

$ErrorActionPreference = "Stop"

# Acknowledgment banner. Inlined because this script runs via 'irm | iex'
# where $PSScriptRoot is empty. Quiet via $env:MIOS_AGREEMENT_BANNER.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking Get-MiOS.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in CREDITS.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

# 1. Elevation -- re-launch a fresh elevated pwsh window so the host has
# a clean, full-size console (the original `irm | iex` host inherits
# whatever terminal called us, which may be too small for the dashboard).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"irm $RepoUrl/raw/$Branch/Get-MiOS.ps1 | iex"
    if ($FullBuild)  { $relaunchArgs += " -FullBuild" }
    if ($Unattended) { $relaunchArgs += " -Unattended" }
    if ($Workflow)   { $relaunchArgs += " -Workflow $Workflow" }
    $relaunchArgs += "`""
    # Prefer pwsh 7+ (the script Requires-Version 5.1 elsewhere but the
    # build dashboard needs PS7's [Console] behavior).
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process $shell -ArgumentList $relaunchArgs -Verb RunAs
    return
}

# 2. Resize host window so the 80-col dashboard frame fits with breathing room.
try {
    $sz  = New-Object Management.Automation.Host.Size 100, 40
    $buf = New-Object Management.Automation.Host.Size 100, 3000
    $Host.UI.RawUI.BufferSize = $buf
    $Host.UI.RawUI.WindowSize = $sz
} catch {
    try { $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size 100, 40 } catch {}
}

# 3. Helpers
function Write-Info { param([string]$M) Write-Host "  [*] $M" -ForegroundColor Cyan }
function Write-Good { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green }
function Write-Err  { param([string]$M) Write-Host "  [!] $M" -ForegroundColor Red }
function Require-Cmd {
    param([string]$Cmd, [string]$InstallHint)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Err "$Cmd not found. $InstallHint"
        exit 1
    }
}

Clear-Host
Write-Host "MiOS Bootstrap (irm | iex web entry)" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Cyan

# 4. Prerequisites
Require-Cmd "git"    "Install Git from https://git-scm.com/download/win"
Require-Cmd "podman" "Install Podman Desktop from https://podman-desktop.io"
Write-Good "Prerequisites OK (git, podman)"

# 5. Clone or refresh the mios-bootstrap repo. We do NOT use Start-Transcript
# here -- build-mios.ps1's unified log captures everything, and a transcript
# wraps stdout in a way that breaks the dashboard's in-place repaint.
if (Test-Path (Join-Path $RepoDir ".git")) {
    Write-Info "Updating existing repo at $RepoDir ..."
    Push-Location $RepoDir
    try {
        & git fetch origin 2>&1 | Out-Null
        & git checkout $Branch 2>&1 | Out-Null
        & git pull --ff-only origin $Branch 2>&1 | Out-Null
    } finally { Pop-Location }
} else {
    Write-Info "Cloning $RepoUrl -> $RepoDir ..."
    & git clone --branch $Branch --depth 1 $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git clone failed"
        exit 1
    }
}
Write-Good "Bootstrap repo ready at $RepoDir"

# 6. Hand off to bootstrap.ps1 (canonical split-bootstrap entry).
# Defaults to -BootstrapOnly: stops after dev VM + Windows install.
# The "Build MiOS" Start Menu shortcut drives the OCI build.
$entry = Join-Path $RepoDir "bootstrap.ps1"
if (-not (Test-Path $entry)) {
    Write-Err "bootstrap.ps1 not found in $RepoDir (cloned with wrong branch?)"
    exit 1
}

if ($Workflow) { $env:MIOS_WORKFLOW = $Workflow }

$forwardArgs = @()
if ($FullBuild)  { $forwardArgs += '-FullBuild' }
if ($Unattended) { $forwardArgs += '-Unattended' }

Write-Info "Handing off to bootstrap.ps1 ..."
Push-Location $RepoDir
try {
    & $entry @forwardArgs
} finally { Pop-Location }
exit $LASTEXITCODE
