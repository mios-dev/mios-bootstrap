<#
.SYNOPSIS
  One-shot MiOS-XBOX builder. Self-elevates, auto-picks fresh-download vs a local
  base ISO (by base-ISO presence + a live network probe), runs the full
  UUP -> DISM -> autounattend -> oscdimg pipeline on the roomiest drive, and
  can boot a Hyper-V test VM to validate the install end-to-end.

.DESCRIPTION
  MiOS ships two install routes:
    * PRIMARY  - the MiOS browser-app: mios.html configures + deploys MiOS
                 on top of an EXISTING Windows install (in-place overlay).
    * ALTERNATE (this) - MiOS-XBOX: a whole custom, gaming-minimal Windows 11
                 SOURCE image. Its on-disk tree is pared to a minimal,
                 Linux-pattern directory surface WITHOUT breaking C:\Users or
                 the app dependencies that expect the standard Windows folders.
                 (The layout + debloat are baked offline in Stage 2 servicing;
                 this wrapper only orchestrates building + testing that image.)

  Source auto-selection (no flags needed):
    -Fresh forced ............................ fresh UUP download
    else local base ISO exists ............... reuse it (fast, network-proof)
    else network reachable ................... fresh UUP download
    else ..................................... stop with guidance

.PARAMETER TomlPath   SSOT. Default C:\mios-bootstrap\mios.toml.
.PARAMETER SourceIso  Explicit pre-built base ISO. Else autounattend.source_iso, else a known location.
.PARAMETER Fresh      Force a fresh UUP download even if a local base ISO exists.
.PARAMETER TestVM     After the build, (re)create + boot a Hyper-V Gen2 test VM on the ISO.
.PARAMETER SkipServicing  Pass-through: skip the DISM debloat (fast boot smoke test).
.PARAMETER SecureBoot Test-VM Secure Boot (MS UEFI CA template). -SecureBoot:$false to disable.

.EXAMPLE
  .\Build-MiOSXbox.ps1
  # auto: local base if present else fresh; build to <most-free drive>\MiOS\iso\MiOS-Xbox.iso

.EXAMPLE
  .\Build-MiOSXbox.ps1 -Fresh -TestVM
  # force fresh UUP pull, then boot a Hyper-V VM to validate the install
#>
[CmdletBinding()]
param(
    [string]$TomlPath = 'C:\mios-bootstrap\mios.toml',
    [string]$SourceIso,
    [switch]$Fresh,
    [switch]$TestVM,
    [switch]$SkipServicing,
    [bool]$SecureBoot = $true
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# --------------------------------------------------------------------------
# Self-elevation -- Stage 2 (DISM WIM mount) + Hyper-V need a HIGH-IL token.
# A UAC relaunch turns the filtered admin token into a full one. Reconstruct
# the caller's args verbatim so the elevated run is identical.
# --------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host '[*] Not elevated -- relaunching via UAC ...' -ForegroundColor Yellow
    $relaunch = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $v = $kv.Value
        if     ($v -is [switch]) { if ($v.IsPresent) { $relaunch += "-$($kv.Key)" } }
        elseif ($v -is [bool])   { $relaunch += "-$($kv.Key):`$$([string]$v.ToString().ToLower())" }
        else                     { $relaunch += "-$($kv.Key)"; $relaunch += "`"$v`"" }
    }
    $exe  = (Get-Process -Id $PID).Path   # this host (pwsh.exe or powershell.exe)
    $head = @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList ($head + $relaunch)
    return
}

# --------------------------------------------------------------------------
# Shared helpers (Resolve-MiOSBuildRoot / Read-MiosToml / Get-Toml).
# --------------------------------------------------------------------------
. (Join-Path $here 'MiOS-Provision.lib.ps1')
$toml = if (Test-Path $TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }

# Quick TCP reachability probe (no long Test-NetConnection stall).
function Test-Reachable {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok -and $c.Connected) { $c.EndConnect($ar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

# --------------------------------------------------------------------------
# Decide the source: fresh UUP download vs local base ISO.
# --------------------------------------------------------------------------
$candidates = @()
if ($SourceIso)                                   { $candidates += $SourceIso }
$ssotBase = Get-Toml $toml 'autounattend.source_iso' ''
if ($ssotBase)                                    { $candidates += $ssotBase }
$candidates += 'C:\MiOS-XBOX\MiOS-XBOX.iso'       # last-known deployed base
$localBase = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

$mode = $null
if     ($Fresh)      { $mode = 'fresh' }
elseif ($localBase)  { $mode = 'local' }
else {
    Write-Host '[*] No local base ISO -- probing network (api.uupdump.net:443) ...' -ForegroundColor Cyan
    if (Test-Reachable -HostName 'api.uupdump.net') { $mode = 'fresh' }
    else { throw "No local base ISO and UUP Dump is unreachable. Restore connectivity or pass -SourceIso <path>." }
}

$root = Resolve-MiOSBuildRoot $toml
Write-Host ''
Write-Host ('================ MiOS-XBOX build ================') -ForegroundColor Green
Write-Host ('  mode        : {0}' -f $(if($mode -eq 'local'){"LOCAL base (network-proof)"}else{"FRESH UUP download"}))
if ($mode -eq 'local') { Write-Host ('  base ISO    : {0}' -f $localBase) }
Write-Host ('  build root  : {0}' -f $root)
Write-Host ('  servicing   : {0}' -f $(if($SkipServicing){'SKIPPED (smoke test)'}else{'DISM debloat + drivers + Xbox FSE'}))
Write-Host ('  test VM     : {0}' -f $(if($TestVM){"Hyper-V (SecureBoot={0})" -f $SecureBoot}else{'no'}))
Write-Host ('=================================================') -ForegroundColor Green
Write-Host ''

# --------------------------------------------------------------------------
# Run the pipeline (New-MiOSISO orchestrates Stages 0-4).
# --------------------------------------------------------------------------
$isoArgs = @{ TomlPath = $TomlPath }
if ($mode -eq 'local') { $isoArgs.SourceIso = $localBase }
if ($SkipServicing)    { $isoArgs.SkipServicing = $true }

$out = & (Join-Path $here 'New-MiOSISO.ps1') @isoArgs
# New-MiOSISO returns $OutIso; guard against any leaked host lines.
$iso = @($out) | Where-Object { "$_" -match '\.iso$' -and (Test-Path "$_") } | Select-Object -Last 1
if (-not $iso) { throw "Pipeline finished but no output ISO was produced (last value: '$out')." }
Write-Host ''
Write-Host ("[+] MiOS-XBOX ISO ready: {0}  ({1} GB)" -f $iso, [math]::Round((Get-Item $iso).Length/1GB,2)) -ForegroundColor Green

# --------------------------------------------------------------------------
# Optional Hyper-V test boot. A UAC-elevated session has the full token, so
# Hyper-V cmdlets work here (unlike the filtered `mios` shell). The autounattend
# carries the LabConfig TPM/SecureBoot bypass, so no vTPM is required to install.
# --------------------------------------------------------------------------
function Invoke-MiOSHyperVTest {
    param([string]$Iso, [string]$BuildRoot, [bool]$SecureBoot,
          [string]$Name = 'MiOS-XBOX-Test', [int]$MemGB = 8, [int]$Cpu = 4, [int]$DiskGB = 100)

    if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
        Write-Warning "Hyper-V PowerShell module not present. Enable it (elevated), reboot, then re-run with -TestVM:"
        Write-Warning "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All"
        return
    }
    Write-Host "[*] Hyper-V test VM '$Name' -- recreating fresh ..." -ForegroundColor Cyan
    Get-VM -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.State -ne 'Off') { Stop-VM $_ -TurnOff -Force -ErrorAction SilentlyContinue }
        Remove-VM $_ -Force -ErrorAction SilentlyContinue
    }
    $vmDir = Join-Path $BuildRoot 'test-vm'
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    $vhd = Join-Path $vmDir "$Name.vhdx"
    Remove-Item $vhd -Force -ErrorAction SilentlyContinue

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemGB * 1GB) `
        -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB) -Path $vmDir | Out-Null
    Set-VM -Name $Name -ProcessorCount $Cpu -AutomaticCheckpointsEnabled $false
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes 2GB `
        -StartupBytes ($MemGB * 1GB) -MaximumBytes ($MemGB * 1GB)
    Add-VMDvdDrive -VMName $Name -Path $Iso
    $dvd = Get-VMDvdDrive -VMName $Name

    if ($SecureBoot) {
        Set-VMFirmware -VMName $Name -EnableSecureBoot On `
            -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -FirstBootDevice $dvd
    } else {
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off -FirstBootDevice $dvd
    }

    # Wire internet (FirstLogon bootstrap needs it): prefer the NAT 'Default Switch'.
    $sw = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object Name -eq 'Default Switch'
    if (-not $sw) { $sw = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($sw) { Connect-VMNetworkAdapter -VMName $Name -SwitchName $sw.Name; Write-Host "    NIC -> $($sw.Name)" -ForegroundColor DarkGray }
    else     { Write-Warning "    No NAT/External vSwitch found -- VM has no internet; MiOS bootstrap won't fetch." }

    Start-VM -Name $Name
    Write-Host "[+] VM '$Name' started on $Iso -- opening console." -ForegroundColor Green
    Start-Process 'vmconnect.exe' -ArgumentList @('localhost', $Name) -ErrorAction SilentlyContinue
}

if ($TestVM) {
    Write-Host ''
    Invoke-MiOSHyperVTest -Iso $iso -BuildRoot $root -SecureBoot $SecureBoot
}

Write-Host ''
Write-Host "[+] Done. Flash $iso to USB (Rufus/Ventoy) or attach it to a VM to install MiOS-XBOX." -ForegroundColor Green
return $iso
