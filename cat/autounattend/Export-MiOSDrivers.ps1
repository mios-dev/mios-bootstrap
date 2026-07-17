# AI-hint: Exports this machine's third-party (OEM) drivers to a folder so the MiOS custom-Windows ISO pipeline (NTLite / DISM Add-Driver) can slipstream them into a fresh MiOS-derived Windows edition. Sanitized MiOS-conventions version of the operator's driver-extract.ps1.
# AI-related: mios-bootstrap, ConvertTo-MiOSPreset.ps1, New-MiOSAutounattend.ps1, MiOS-Xbox.xml
#Requires -Version 5.1
<#
.SYNOPSIS
    Export installed 3rd-party drivers for MiOS ISO slipstream (NTLite / DISM).

.DESCRIPTION
    Step in the MiOS custom-Windows pipeline (UUP Dump -> customize -> ISO):
    captures the current box's OEM drivers so the MiOS-derived edition boots on
    the same hardware. Point NTLite (Drivers section) or DISM
    (`Add-WindowsDriver -Path <wim> -Driver <dir> -Recurse`) at the output.

    Replaces the hardcoded Desktop path from the source script with an
    SSOT/param destination (default M:\MiOS\drivers, MiOS's data drive), so the
    committed preset carries no machine-specific `C:\Users\<name>\Desktop\...`.

.PARAMETER Destination
    Output folder. Default: M:\MiOS\drivers if M:\ exists, else
    %USERPROFILE%\MiOS-Drivers.

.EXAMPLE
    .\Export-MiOSDrivers.ps1
.EXAMPLE
    .\Export-MiOSDrivers.ps1 -Destination D:\MiOS\drivers
#>
[CmdletBinding()]
param(
    [string]$Destination
)
$ErrorActionPreference = 'Stop'

if (-not $Destination) {
    $Destination = if (Test-Path 'M:\') { 'M:\MiOS\drivers' } else { Join-Path $env:USERPROFILE 'MiOS-Drivers' }
}

# Export-WindowsDriver needs an elevated session.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Export-WindowsDriver needs an elevated session -- relaunching via UAC..."
    Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Destination',"`"$Destination`"") `
        -Verb RunAs
    return
}

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
}

Write-Host "[*] Exporting third-party (OEM) drivers to $Destination ..." -ForegroundColor Cyan
Export-WindowsDriver -Online -Destination $Destination | Out-Null

$count = @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
Write-Host "[+] Exported $count driver package(s). Point NTLite (Drivers) or DISM Add-WindowsDriver here:" -ForegroundColor Green
Write-Host "    $Destination" -ForegroundColor DarkGray
