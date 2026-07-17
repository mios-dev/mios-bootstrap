# AI-hint: Build-HOST prerequisite fetcher for the MiOS-XBOX ISO pipeline -- polls the web (winget) and installs what New-MiOSISO.ps1 needs on the machine that BUILDS the ISO (not the target): the Windows ADK "Deployment Tools" (oscdimg.exe) and, optionally, the packaged WSL. Run once, elevated, before New-MiOSISO. Separate from the TARGET-machine first-login hydration (MiOS-XBOX-Hydrate.ps1).
# AI-related: mios-bootstrap, New-MiOSISO.ps1, mios-uup-fetch.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure the build host has the tools New-MiOSISO needs: oscdimg (Windows ADK
    Deployment Tools) and (optionally) the packaged WSL. Fetches via winget.
.PARAMETER IncludeWsl  Also install the packaged WSL (C:\Program Files\WSL\wsl.exe).
#>
[CmdletBinding()]
param([switch]$IncludeWsl)
$ErrorActionPreference = 'Continue'

function Test-Oscdimg {
    $kits = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Directory -ErrorAction SilentlyContinue
    foreach ($k in $kits) {
        if (Get-ChildItem (Join-Path $k.FullName 'Assessment and Deployment Kit\Deployment Tools') -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
    }
    return [bool](Get-Command oscdimg.exe -ErrorAction SilentlyContinue)
}

# If oscdimg is already present we don't even need winget -- short-circuit success.
if (Test-Oscdimg) { Write-Host '[=] oscdimg already present (ADK Deployment Tools).' -ForegroundColor DarkGray; if (-not $IncludeWsl) { Write-Host '[+] Build prereqs OK.' -ForegroundColor Green; return } }
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) { throw 'winget (Microsoft.DesktopAppInstaller) not found and oscdimg missing -- install App Installer + the Windows ADK Deployment Tools, then re-run.' }

if (Test-Oscdimg) {
    Write-Host '[=] oscdimg already present (ADK Deployment Tools).' -ForegroundColor DarkGray
} else {
    Write-Host '[*] Installing Windows ADK (Deployment Tools -> oscdimg) via winget ...' -ForegroundColor Cyan
    & $winget install --id Microsoft.WindowsADK --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
    if (Test-Oscdimg) { Write-Host '[+] oscdimg available.' -ForegroundColor Green }
    else {
        # THROW (not warn): oscdimg is mandatory for New-MiOSISO. Failing here stops
        # the build in the prereqs stage instead of a false-green followed by a wasted
        # long UUP fetch + full DISM servicing before oscdimg is discovered missing.
        throw 'ADK install did not surface oscdimg. Install the Windows ADK "Deployment Tools" feature, then re-run.'
    }
}

if ($IncludeWsl -and -not (Test-Path "$env:ProgramFiles\WSL\wsl.exe")) {
    Write-Host '[*] Installing packaged WSL via winget ...' -ForegroundColor Cyan
    & $winget install --id Microsoft.WSL --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
}

Write-Host '[+] Build prereqs checked. Next: mios-uup-fetch.ps1 (Dev ISO) then New-MiOSISO.ps1 (elevated).' -ForegroundColor Green
