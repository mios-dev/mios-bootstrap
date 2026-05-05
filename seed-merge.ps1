<#
.SYNOPSIS
    Universal MiOS-SEED merge step (PowerShell native).

.DESCRIPTION
    Overlays mios-bootstrap onto a mios.git checkout so the Containerfile
    build context contains the FULL deployed root layout (mios.git system
    layer + mios-bootstrap user/AI layer) regardless of the host platform
    the build runs from. Functionally identical to ./seed-merge.sh -- the
    PowerShell version exists so build-mios.ps1 can run the merge before
    invoking podman build, without depending on bash on the Windows host.

    Day-0 builds from any platform produce an identical OCI image. Every
    deploy shape (raw, vhdx, qcow2, ISO, WSL2 distro, Podman-WSL OCI
    host) lands the same content because they're produced by
    bootc-image-builder from the same OCI image.

    Idempotent + non-destructive: bootstrap files OVERLAY onto mios.git
    (bootstrap wins when both own the same path). Re-running produces
    no diff.

.PARAMETER MiosDir
    Path to the mios.git checkout. Mutated in place; pass a copy if you
    need to keep the upstream checkout pristine.

.PARAMETER BootstrapDir
    Path to the mios-bootstrap.git checkout. Read-only.
#>
param(
    [Parameter(Mandatory=$true)] [string]$MiosDir,
    [Parameter(Mandatory=$true)] [string]$BootstrapDir
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MiosDir))      { throw "mios.git not found: $MiosDir" }
if (-not (Test-Path $BootstrapDir)) { throw "mios-bootstrap.git not found: $BootstrapDir" }

function Write-Seed { param([string]$M) Write-Host "[seed-merge] $M" }

# 1. Directory-tree overlays. Bootstrap's etc, usr, var, profile layer
# ON TOP of mios.git's same directories. robocopy /E recurses (incl
# empty dirs); /IS /IT overwrites identical+tweaked files so bootstrap
# wins on path collisions. /XO is NOT used -- bootstrap's content
# always wins regardless of timestamp.
foreach ($dir in @("etc", "usr", "var", "profile")) {
    $src = Join-Path $BootstrapDir $dir
    $dst = Join-Path $MiosDir      $dir
    if (Test-Path $src) {
        Write-Seed "overlay: $src\* -> $dst\"
        $null = New-Item -ItemType Directory -Path $dst -Force -ErrorAction SilentlyContinue
        # robocopy emits to stdout; suppress unless caller wants it.
        # Exit codes 0-7 are success (files copied / no copy needed /
        # extras present); 8+ is real failure.
        & robocopy $src $dst /E /IS /IT /NJH /NJS /NFL /NDL /NP 2>&1 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed for ${src} -> ${dst} (exit ${LASTEXITCODE})"
        }
    }
}

# 2. Root-level files. User-facing entry points + the canonical
# user-edit dotfile that live at / on the deployed system.
$rootFiles = @(
    "mios.toml",
    "CLAUDE.md", "AGENTS.md", "GEMINI.md", "usr/share/doc/mios-bootstrap/concepts/ai-architecture.md", "AGREEMENTS.md",
    ".cursorrules",
    "usr/share/doc/mios/reference/api.md", "usr/share/doc/mios/reference/credits.md", "system-prompt.md",
    "usr/share/doc/mios-bootstrap/reference/variables.md", "usr/share/doc/mios-bootstrap/guides/user-space.md", "usr/share/doc/mios-bootstrap/guides/install-architecture.md",
    "llms.txt",
    "bootstrap.sh", "bootstrap.ps1", "install.sh", "install.ps1",
    "Get-MiOS.ps1", "build-mios.sh", "build-mios.ps1"
)
foreach ($file in $rootFiles) {
    $src = Join-Path $BootstrapDir $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $MiosDir $file) -Force
    }
}

# 3. Stage canonical mios.toml at its FHS-resolved locations so the
# runtime resolver (tools/lib/userenv.sh) finds it without needing
# a bootstrap-side install step. Both vendor layer and host-local
# layer get the same content baked in; firstboot writes a per-user
# copy from /etc/skel/.config/mios/mios.toml (also bootstrap-supplied).
$miosToml = Join-Path $BootstrapDir "mios.toml"
if (Test-Path $miosToml) {
    foreach ($staged in @(
        (Join-Path $MiosDir "usr\share\mios\mios.toml"),
        (Join-Path $MiosDir "etc\mios\mios.toml")
    )) {
        $null = New-Item -ItemType Directory -Path (Split-Path $staged -Parent) -Force -ErrorAction SilentlyContinue
        Copy-Item -Path $miosToml -Destination $staged -Force
    }
}

Write-Seed "Universal MiOS-SEED merge complete: $BootstrapDir -> $MiosDir"
