#Requires -Version 5.1
<#
.SYNOPSIS
    MiOS Bootstrap (Windows) -- the canonical curl/iex web entry.

.DESCRIPTION
    Stops at the localhost-side bring-up: preflight, oh-my-posh,
    Geist + Symbols-Only Nerd Font, Windows partition shrink + M:\
    data disk, MiOS-DEV podman machine (init + overlay + components +
    live update from PACKAGES.md), smoke test, RENAME
    (podman-MiOS-DEV -> MiOS-DEV), Windows install at M:\MiOS\
    (bin/icons/themes/fonts), Desktop + Start Menu icons.

    The "Build MiOS" Start Menu shortcut this drops then drives the
    actual OCI image build via build-mios.ps1 -BuildOnly when the
    operator is ready -- decoupling "set me up" from "build me a
    deployable image".

    One-liner (canonical):
        irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/bootstrap.ps1 | iex

    Pass -FullBuild to chain the OCI image build immediately (legacy
    one-shot behavior); without it the bootstrap stops cleanly and
    the operator clicks "Build MiOS" on the Start Menu when ready.

.PARAMETER FullBuild
    Skip -BootstrapOnly mode and run the entire build pipeline
    (preflight + dev VM + Windows install + Phase 6+: identity,
    OCI build, deploy). Equivalent to the pre-v0.2.4 behavior.

.PARAMETER BuildOnly
    Skip the bootstrap phase (assume MiOS-DEV is already provisioned).
    Jump straight to identity prompts + OCI build + deploy. Used by
    the "Build MiOS" Start Menu shortcut.

.PARAMETER Unattended
    Take all defaults; no interactive prompts.
#>

param(
    [switch]$FullBuild,
    [switch]$BuildOnly,
    [switch]$Unattended
)

# Acknowledgment banner. The downstream build-mios.ps1 prints its own
# dashboard; this is the single user-facing notice if AGREEMENTS.md
# is required reading on first contact.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking bootstrap.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in usr/share/doc/mios/reference/credits.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

# Build the arg list for build-mios.ps1. Default = -BootstrapOnly so
# curl-bash entries stop after dev VM + Windows install. -FullBuild
# overrides for the legacy one-shot path.
$forwardArgs = @()
if (-not $FullBuild -and -not $BuildOnly) { $forwardArgs += '-BootstrapOnly' }
if ($BuildOnly)                            { $forwardArgs += '-BuildOnly' }
if ($Unattended)                           { $forwardArgs += '-Unattended' }

$target = Join-Path $PSScriptRoot 'build-mios.ps1'
if (Test-Path $target) {
    & $target @forwardArgs
    exit $LASTEXITCODE
}

# Running piped via irm | iex -- $PSScriptRoot is empty. Fetch the
# canonical build-mios.ps1 from the same branch and dot-source it.
$url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.ps1"
$src = Invoke-RestMethod $url
$sb  = [scriptblock]::Create($src)
& $sb @forwardArgs
exit $LASTEXITCODE
