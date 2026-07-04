# AI-hint: Post-install MiOS provisioner for PRE-EXISTING Windows users -- creates all local offline accounts from mios.toml SSOT, enables long paths, then chains the same nested MiOS irm|iex bootstrap (Get-MiOS.ps1). The existing-Windows counterpart to the autounattend "during install" path.
# AI-related: mios-bootstrap, Get-MiOS.ps1, src/autounattend/New-MiOSAutounattend.ps1, src/autounattend/autounattend.xml
# AI-functions: Read-MiosToml, New-MiOSLocalAccounts
#Requires -Version 5.1
<#
.SYNOPSIS
    Apply MiOS's SSOT provisioning to an ALREADY-INSTALLED Windows box, then run
    the MiOS bootstrap. The post-install twin of the autounattend "during
    install" path -- both converge on `irm .../Get-MiOS.ps1 | iex`.

.DESCRIPTION
    Fresh installs get their local accounts + tweaks from autounattend.xml.
    Existing Windows users don't reinstall, so this script does the equivalent
    at runtime:
      1. Creates every local ("offline") account defined in mios.toml
         [[autounattend.accounts]] (SSOT) that doesn't already exist, in its
         SSOT group (Administrators/Users), password never-expires.
      2. Enables NTFS long paths (LongPathsEnabled).
      3. Chains the SAME nested MiOS bootstrap: irm Get-MiOS.ps1 | iex.

    Requires an elevated (admin) PowerShell. Multi-user aware: creates the full
    SSOT account set so the MiOS-Autostart all-users login task (registered by
    build-mios.ps1) then boots the stack for each of them.

.PARAMETER TomlPath
    mios.toml to read (default: M:\etc\mios, M:\usr\share\mios, or <repo>\mios.toml).

.PARAMETER BootstrapUrl
    Override the bootstrap URL (default: canonical raw Get-MiOS.ps1).

.PARAMETER SkipBootstrap
    Only create accounts + enable long paths; do not run the MiOS bootstrap.
#>
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$BootstrapUrl = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1',
    [switch]$SkipBootstrap
)
$ErrorActionPreference = 'Stop'

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

# Reuse the SSOT reader from the generator (same folder).
$gen = Join-Path $PSScriptRoot 'New-MiOSAutounattend.ps1'
function Read-MiosToml {
    param([string]$Path)
    $result = @{ scalars = @{}; accounts = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $section = ''; $curAccount = $null
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -eq '[[autounattend.accounts]]') {
            if ($curAccount) { $result.accounts += ,$curAccount }
            $curAccount = @{}; $section = 'account'; continue
        }
        if ($line -match '^\[(?<s>[^\]]+)\]$') {
            if ($curAccount) { $result.accounts += ,$curAccount; $curAccount = $null }
            $section = $Matches['s']; continue
        }
        if ($line -match '^(?<k>[A-Za-z0-9_\-\.]+)\s*=\s*(?<v>.+)$') {
            $k = $Matches['k'].Trim(); $v = $Matches['v'].Trim().Trim('"', "'")
            if ($section -eq 'account' -and $curAccount -ne $null) { $curAccount[$k] = $v }
            else { $result.scalars["$section.$k"] = $v }
        }
    }
    if ($curAccount) { $result.accounts += ,$curAccount }
    return $result
}

if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',
                     (Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@() } }

# Resolve SSOT accounts (fallback: [identity].username as a single admin).
$accounts = @($toml.accounts)
if ($accounts.Count -eq 0) {
    $u = if ($toml.scalars.ContainsKey('identity.username')) { $toml.scalars['identity.username'] } else { 'mios' }
    $accounts = @(@{ name = $u; display_name = 'MiOS User'; group = 'Administrators'; password = $u })
}

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
            if ($sec) {
                New-LocalUser -Name $name -Password $sec -FullName $disp -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
            } else {
                New-LocalUser -Name $name -NoPassword -FullName $disp -ErrorAction Stop | Out-Null
            }
            Write-Host "  [+] Created local account: $name ($disp)" -ForegroundColor Green
        }
        # Ensure group membership (Administrators or Users).
        $grpName = if ($group -match '^(?i)admin') { 'Administrators' } else { 'Users' }
        if (-not (Get-LocalGroupMember -Group $grpName -Member $name -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $grpName -Member $name -ErrorAction SilentlyContinue
            Write-Host "  [+] $name added to $grpName" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  account '$name' provisioning failed: $($_.Exception.Message)"
    }
}

# Enable NTFS long paths (same as the autounattend specialize pass).
try {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "[+] LongPathsEnabled=1" -ForegroundColor Green
} catch { Write-Warning "LongPathsEnabled set failed: $($_.Exception.Message)" }

if ($SkipBootstrap) {
    Write-Host "[.] -SkipBootstrap set -- accounts + long paths applied; not running MiOS bootstrap." -ForegroundColor DarkGray
    return
}

# Chain the SAME nested MiOS bootstrap that the autounattend runs at first logon.
Write-Host "[*] Running MiOS bootstrap: irm $BootstrapUrl | iex" -ForegroundColor Cyan
try {
    $src = Invoke-RestMethod -Uri ("{0}?cb={1}" -f $BootstrapUrl, [guid]::NewGuid().ToString('N')) -TimeoutSec 60
    & ([scriptblock]::Create($src))
} catch {
    Write-Warning "MiOS bootstrap fetch/run failed: $($_.Exception.Message)"
    Write-Host "  Retry manually:  irm $BootstrapUrl | iex" -ForegroundColor DarkGray
}
