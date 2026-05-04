#Requires -Version 5.1
<#
.SYNOPSIS
    Legacy MiOS install entry -- redirects to bootstrap.ps1.

.DESCRIPTION
    Pre-v0.2.4 the canonical web entry was install.ps1, which ran the
    full build pipeline (preflight + dev VM + OCI image build + deploy)
    in one shot. v0.2.4 split that into:

        bootstrap.ps1  : preflight + dev VM + Windows install (default)
        Build MiOS     : Start Menu shortcut -> OCI image build

    This redirector preserves existing 'irm .../install.ps1 | iex'
    one-liners by forwarding to bootstrap.ps1 -- which by default
    stops at the bootstrap phase. Pass -FullBuild here to get the
    pre-v0.2.4 one-shot behavior.
#>

param(
    [switch]$FullBuild,
    [switch]$BuildOnly,
    [switch]$Unattended
)

$ErrorActionPreference = "Stop"

$forwardArgs = @()
if ($FullBuild)  { $forwardArgs += '-FullBuild' }
if ($BuildOnly)  { $forwardArgs += '-BuildOnly' }
if ($Unattended) { $forwardArgs += '-Unattended' }

$target = Join-Path $PSScriptRoot 'bootstrap.ps1'
if (-not (Test-Path $target)) {
    # Piped via irm | iex -- $PSScriptRoot is empty. Fetch bootstrap.ps1
    # canonical and dot-source.
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/bootstrap.ps1"
    $src = Invoke-RestMethod $url
    $sb  = [scriptblock]::Create($src)
    & $sb @forwardArgs
    exit $LASTEXITCODE
}
& $target @forwardArgs
exit $LASTEXITCODE
