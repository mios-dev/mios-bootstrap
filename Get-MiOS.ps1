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

# 1. ALWAYS spawn a fresh elevated pwsh window. The original `irm | iex`
# host inherits whatever terminal called us (VS Code integrated, remote
# session, embedded host, etc.) which often (a) isn't admin, (b) is the
# wrong size for the build, and (c) breaks console cursor positioning.
# A fresh top-level pwsh window guarantees a clean, properly-sized
# environment regardless of where the curl was run from.
#
# Sentinel: $env:MIOS_GETMIOS_RELAUNCHED prevents the new window from
# re-launching itself in an infinite loop.
if (-not $env:MIOS_GETMIOS_RELAUNCHED) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "  [*] Spawning a fresh elevated pwsh window for the bootstrap run..." -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host "  [*] You'll see a UAC prompt momentarily; approve it to continue." -ForegroundColor DarkGray
    }

    # Derive the raw.githubusercontent.com URL from the .git clone URL.
    # GitHub's "/raw/" path on github.com only works WITHOUT the .git
    # suffix; the tracked URL has .git for `git clone` so we strip it
    # here. Using raw.githubusercontent.com directly is the canonical
    # path for `irm | iex` and avoids the github.com 302 redirect
    # entirely.
    $rawBase = $RepoUrl -replace '\.git$', '' `
                       -replace '^https?://github\.com/', 'https://raw.githubusercontent.com/'
    $rawUrl  = "$rawBase/$Branch/Get-MiOS.ps1"

    $forwardSwitches = ""
    if ($FullBuild)  { $forwardSwitches += " -FullBuild" }
    if ($Unattended) { $forwardSwitches += " -Unattended" }
    if ($Workflow)   { $forwardSwitches += " -Workflow $Workflow" }

    # Heredoc with HTML-sniff guard so a 404 (which GitHub serves with
    # an HTML body) doesn't get piped into iex and execute as garbage.
    # The relaunched window keeps a Read-Host on failure so the operator
    # can read the diagnostic instead of the window vanishing.
    $relaunchCmd = @"
`$env:MIOS_GETMIOS_RELAUNCHED='1';
try {
    `$src = Invoke-RestMethod -Uri '$rawUrl' -ErrorAction Stop
    if (-not `$src -or `$src -match '<!DOCTYPE html>|<html\b') {
        throw "Get-MiOS.ps1 fetch from $rawUrl returned HTML (likely 404 / wrong branch '$Branch')."
    }
    & ([scriptblock]::Create(`$src))$forwardSwitches
} catch {
    Write-Host ""
    Write-Host "  [!] Bootstrap failed: `$_" -ForegroundColor Red
    Write-Host "      URL: $rawUrl" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Press Enter to close..." -ForegroundColor DarkGray -NoNewline
    `$null = Read-Host
}
"@

    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $startArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-Command', $relaunchCmd
    )
    Start-Process $shell -ArgumentList $startArgs -Verb RunAs
    Write-Host "  [+] New pwsh window opened. Continuing the bootstrap there." -ForegroundColor Green
    return
}

# 2. Resize host window. Larger here (110x42) than the 100x40 default
# inside build-mios.ps1 because the new pwsh window starts at the
# system default (often 80x25), so we need an explicit set.
try {
    $sz  = New-Object Management.Automation.Host.Size 110, 42
    $buf = New-Object Management.Automation.Host.Size 110, 3000
    $Host.UI.RawUI.BufferSize = $buf
    $Host.UI.RawUI.WindowSize = $sz
} catch {
    try { $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size 110, 42 } catch {}
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
