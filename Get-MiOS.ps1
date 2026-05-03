<#
.SYNOPSIS
    'MiOS' bootstrap -- canonical Windows one-liner entry point.

.DESCRIPTION
    Designed for: irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex

    'mios-bootstrap' is the user-facing entry repo: it owns the
    user-defined dotfiles, the canonical 'mios.toml', and the entry-
    point scripts. The 'mios' repo carries the system FHS overlay
    (factory defaults under usr/, etc/, var/, srv/) that's baked into
    the deployed image; the user-space side overlays bootstrap's own
    files on top of the FHS defaults at install/build time, so user
    definitions override factory defaults field-by-field.

    What this script does:
      1. Elevates to Administrator if needed.
      2. Ensures Git + Podman are present.
      3. Clones / updates the 'mios-bootstrap' repo into
         $env:USERPROFILE\MiOS-bootstrap.
      4. Sets MIOS_UNIFIED_LOG so the entire session writes one flat
         transcript at ~/Documents/MiOS/mios-build-<ts>.log.
      5. Starts Start-Transcript (unified log).
      6. Calls bootstrap's build-mios.ps1 from the repo root. That
         script clones mios.git into the WSL2 builder, applies the
         user-defined dotfiles + mios.toml on top of mios.git's FHS
         defaults, and orchestrates the end-to-end pipeline:
         preflight -> Podman machine -> WSL2 builder -> build ->
         deploy targets (RAW, VHDX, ISO, qcow2, WSL2).
      7. Stops the transcript on exit.

    Prompts auto-accept after 90 seconds idle, falling back to the
    'global MiOS/mios defaults' resolved from mios.toml via
    tools/lib/userenv.sh (vendor -> host -> per-user overlay).
#>
param(
    [string]$RepoUrl  = "https://github.com/mios-dev/mios-bootstrap.git",
    [string]$Branch   = "main",
    [string]$RepoDir  = (Join-Path $env:USERPROFILE "MiOS-bootstrap"),
    [string]$Workflow = ""
)

$ErrorActionPreference = "Stop"

# Acknowledgment banner (inlined; this script runs via 'irm | iex' where
# $PSScriptRoot is empty). Respects $env:MIOS_AGREEMENT_BANNER for quiet
# unattended invocation.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking Get-MiOS.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in CREDITS.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

# 1. Elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args_ = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Workflow) { $args_ += " -Workflow $Workflow" }
    Start-Process powershell.exe -ArgumentList $args_ -Verb RunAs
    return
}

# 2. Helpers
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

Write-Host "'MiOS' Bootstrap (irm | iex entry, bootstrap repo)" -ForegroundColor Cyan

# 3. Prerequisites
Require-Cmd "git"    "Install Git from https://git-scm.com/download/win"
Require-Cmd "podman" "Install Podman Desktop from https://podman-desktop.io"
Write-Good "Prerequisites OK (git, podman)"

# 4. Unified log path (before transcript starts)
$LogDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "MiOS"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "mios-build-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
[Environment]::SetEnvironmentVariable("MIOS_UNIFIED_LOG", $LogFile)
Write-Info "Unified log -> $LogFile"

# 5. Start transcript
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}

# 6. Clone / update the bootstrap repo (NOT the mios repo -- bootstrap is
# the user-facing entry, owns mios.toml + dotfiles, and its build-mios.ps1
# clones mios.git itself into the WSL2 builder).
if (Test-Path (Join-Path $RepoDir ".git")) {
    Write-Info "Updating existing repo at $RepoDir ..."
    Push-Location $RepoDir
    & git fetch origin 2>&1 | Write-Host
    & git checkout $Branch 2>&1 | Write-Host
    & git pull --ff-only origin $Branch 2>&1 | Write-Host
    Pop-Location
} else {
    Write-Info "Cloning $RepoUrl -> $RepoDir ..."
    & git clone --branch $Branch --depth 1 $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git clone failed"
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
}
Write-Good "Bootstrap repo ready at $RepoDir"

# 7. Launch bootstrap's build-mios.ps1
$buildScript = Join-Path $RepoDir "build-mios.ps1"
if (-not (Test-Path $buildScript)) {
    Write-Err "build-mios.ps1 not found in $RepoDir"
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

if ($Workflow) { $env:MIOS_WORKFLOW = $Workflow }

Write-Info "Entering bootstrap repo and launching build-mios.ps1 ..."
Push-Location $RepoDir
try {
    & $buildScript
} finally {
    Pop-Location
    try { Stop-Transcript | Out-Null } catch {}
}
