# AI-hint: Post-install MiOS provisioner for PRE-EXISTING Windows -- creates all SSOT local accounts, LIVE-applies the SAME global branding/theme + unified Linux-like layout + prefs that the MiOS-XBOX.iso bakes (shared MiOS-Provision.lib.ps1), enables long paths, then chains the nested MiOS irm|iex bootstrap. The existing-Windows twin of the ISO install path -- feature parity by construction.
# AI-related: mios-bootstrap, MiOS-Provision.lib.ps1, ConvertTo-MiOSPreset.ps1, Get-MiOS.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
    Apply MiOS's SSOT provisioning to an ALREADY-INSTALLED Windows box, then run
    the MiOS bootstrap. The post-install twin of the MiOS-XBOX.iso path -- both
    share MiOS-Provision.lib.ps1 and converge on `irm .../Get-MiOS.ps1 | iex`.

.DESCRIPTION
    Fresh MiOS ISO installs get accounts + global branding/layout/prefs from the
    autounattend (baked from the shared lib). Existing Windows users run this to
    reach the SAME state at runtime:
      1. Creates every SSOT local ("offline") account (never a blank admin).
      2. LIVE-applies the identical global MiOS branding/theme + Linux-like layout
         + prefs (accent/wallpaper/lockscreen/OEM/RGB/cursor/font, Default hive).
      3. Enables NTFS long paths.
      4. Chains the nested MiOS bootstrap: irm Get-MiOS.ps1 | iex (M:\, WSL2 podman
         dev VM, AI lanes, gateways, services -- the full MiOS component stack).

    Requires an elevated (admin) PowerShell.

.PARAMETER TomlPath        mios.toml SSOT (default: M:\etc\mios, M:\usr\share\mios, or <repo>\mios.toml).
.PARAMETER BootstrapUrl    Override the bootstrap URL.
.PARAMETER SkipBootstrap   Only accounts + global provisioning; do not run Get-MiOS.ps1.
#>
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$BootstrapUrl = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1',
    [switch]$SkipBootstrap
)
$ErrorActionPreference = 'Stop'

# Shared MiOS provisioning core (identical to what ConvertTo-MiOSPreset bakes).
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Warning "Not elevated -- relaunching as admin (UAC)..."
    $psi = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($TomlPath)      { $psi += @('-TomlPath',"`"$TomlPath`"") }
    if ($SkipBootstrap) { $psi += '-SkipBootstrap' }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psi -Verb RunAs
    return
}

if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',
                     (Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml     = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }
$accounts = Get-MiOSAccounts -Toml $toml

# 1) SSOT local accounts (multi-user) --------------------------------------
Write-Host "[*] Provisioning $($accounts.Count) SSOT local account(s) from $(if($TomlPath){$TomlPath}else{'identity defaults'})" -ForegroundColor Cyan
foreach ($a in $accounts) {
    $name  = [string]$a.name
    $group = if ($a.group) { [string]$a.group } else { 'Users' }
    $pw    = [string]$a.password
    $disp  = if ($a.display_name) { [string]$a.display_name } else { $name }
    try {
        $sec = if ($pw) { ConvertTo-SecureString $pw -AsPlainText -Force } else { $null }
        if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
            Write-Host "  [.] $name already exists -- skipping create" -ForegroundColor DarkGray
        } else {
            if ($sec) { New-LocalUser -Name $name -Password $sec -FullName $disp -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null }
            else      { New-LocalUser -Name $name -NoPassword -FullName $disp -ErrorAction Stop | Out-Null }
            Write-Host "  [+] Created local account: $name ($disp)" -ForegroundColor Green
        }
        $grpName = if ($group -match '^(?i)admin') { 'Administrators' } else { 'Users' }
        if (-not (Get-LocalGroupMember -Group $grpName -Member $name -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $grpName -Member $name -ErrorAction SilentlyContinue
            Write-Host "  [+] $name added to $grpName" -ForegroundColor Green
        }
    } catch { Write-Warning "  account '$name' provisioning failed: $($_.Exception.Message)" }
}

# 2) LIVE-apply the SAME global branding/layout/prefs the ISO bakes ---------
foreach ($grp in (New-MiOSProvisionCommands -Toml $toml)) {
    Invoke-MiOSHostCommands -Commands $grp.Commands -Label $grp.Description
}

# 3) NTFS long paths -------------------------------------------------------
try {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "[+] LongPathsEnabled=1" -ForegroundColor Green
} catch { Write-Warning "LongPathsEnabled set failed: $($_.Exception.Message)" }

if ($SkipBootstrap) {
    Write-Host "[.] -SkipBootstrap set -- accounts + global MiOS provisioning applied; not running the bootstrap." -ForegroundColor DarkGray
    return
}

# 4) Chain the nested MiOS bootstrap (same one the ISO FirstLogon runs) -----
Write-Host "[*] Running MiOS bootstrap: irm $BootstrapUrl | iex" -ForegroundColor Cyan
try {
    $src = Invoke-RestMethod -Uri ("{0}?cb={1}" -f $BootstrapUrl, [guid]::NewGuid().ToString('N')) -TimeoutSec 60
    & ([scriptblock]::Create($src))
} catch {
    Write-Warning "MiOS bootstrap fetch/run failed: $($_.Exception.Message)"
    Write-Host "  Retry manually:  irm $BootstrapUrl | iex" -ForegroundColor DarkGray
}
