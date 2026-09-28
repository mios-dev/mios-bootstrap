# AI-hint: The primary entry point for Windows environment provisioning; it automates preflight checks, Podman machine setup, disk partitioning, and local MiOS installation to prepare the local dev environment.
#Requires -Version 5.1
<#
.SYNOPSIS
    MiOS Bootstrap (Windows) -- canonical entry point for the bootstrap phase.

.DESCRIPTION
    Stops at the localhost-side bring-up: preflight, oh-my-posh,
    Geist + Symbols-Only Nerd Font, Windows partition shrink + M:\
    data disk, MiOS-DEV podman machine (init + overlay + components +
    live update from PACKAGES.md), smoke test, Windows install at M:\MiOS\
    (bin/icons/themes/fonts), Desktop + Start Menu icons.

    Pass -FullBuild to chain the OCI image build immediately;
    without it the bootstrap stops cleanly in -BootstrapOnly mode.

.PARAMETER FullBuild
    Run the entire build pipeline (preflight + dev VM + Windows install + OCI build + deploy).

.PARAMETER BuildOnly
    Skip the bootstrap phase (assume MiOS-DEV is already provisioned) and jump to OCI build.

.PARAMETER BootstrapOnly
    Run only the bootstrap phases (preflight + dev VM + Windows install). Default.

.PARAMETER Unattended
    Take all defaults; no interactive prompts.
#>

[CmdletBinding()]
param(
    [switch]$FullBuild,
    [switch]$BuildOnly,
    [switch]$BootstrapOnly,
    [switch]$Unattended,
    [parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough = @()
)

$ErrorActionPreference = "Stop"

if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking bootstrap.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in usr/share/doc/mios/reference/credits.md).
"@)
}

$forwardArgs = @()
if ($FullBuild)         { $forwardArgs += '-FullBuild' }
elseif ($BuildOnly)     { $forwardArgs += '-BuildOnly' }
elseif ($BootstrapOnly) { $forwardArgs += '-BootstrapOnly' }
else                    { $forwardArgs += '-BootstrapOnly' }

if ($Unattended)        { $forwardArgs += '-Unattended' }
if ($Passthrough -and $Passthrough.Count -gt 0) { $forwardArgs += $Passthrough }

$target = Join-Path $PSScriptRoot 'build-mios.ps1'
if (Test-Path $target) {
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    & $psBin -NoProfile -ExecutionPolicy Bypass -File $target @forwardArgs
    exit $LASTEXITCODE
}

# Running piped via irm | iex -- $PSScriptRoot is empty or build-mios.ps1 missing.
# Fetch canonical Get-MiOS.ps1 from the same branch and dot-source it.
$url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1"
$src = $null
for ($_a = 1; $_a -le 3; $_a++) {
    try {
        $src = Invoke-RestMethod -Uri ("{0}?cb={1}" -f $url, [guid]::NewGuid().ToString('N')) -TimeoutSec 60
        if ($src -and $src.Length -gt 200) { break }
        $src = $null
    } catch {
        Write-Warning ("[mios] Get-MiOS.ps1 fetch attempt {0} failed: {1}" -f $_a, $_.Exception.Message)
    }
    if ($_a -lt 3) { Start-Sleep -Seconds (@(2,5,10)[$_a-1]) }
}
if (-not $src) {
    [Console]::Error.WriteLine("[mios] FATAL: could not fetch Get-MiOS.ps1 from $url after 3 attempts. Check your network and re-run: irm .../bootstrap.ps1 | iex")
    exit 1
}
$sb  = [scriptblock]::Create($src)
& $sb @forwardArgs
exit $LASTEXITCODE
