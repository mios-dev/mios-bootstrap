<#
.SYNOPSIS
  Fully-logged MiOS-XBOX build -> Hyper-V deploy -> in-guest functionality debug.
  Runs ELEVATED (launch via Start-Process -Verb RunAs). Automates + logs the whole
  cycle so a monitoring session can tail one file and act on failures.

.DESCRIPTION
  STAGE 1 build  : New-MiOSISO (SourceIso = the stock converted ISO -> skip the
                   converter) -> C:\MiOS\iso\MiOS-Xbox.iso, baking SetupComplete +
                   MiOS-Daemon + debloat + Xbox.
  STAGE 2 vm     : (re)create a Gen2 Hyper-V VM, Secure Boot (MS UEFI CA), NAT
                   switch, DVD boot-first, no vTPM (LabConfig bypass), start it.
  STAGE 3 install: wait for the guest to install + auto-logon (PowerShell Direct
                   responds) -- heartbeat-logged.
  STAGE 4 deploy : wait inside the guest for the MiOS deploy markers (SetupComplete
                   log, firstboot.marker, provisioned.marker / firstboot.done).
  STAGE 5 verify : run Test-MiOSXbox.ps1 inside the guest (PS Direct), collect its
                   JSON + the guest deploy logs into the host log.
  Everything is checkpointed to <LogDir>\deploy.log + status.json (single source of
  truth for the monitor). Idempotent-ish: -SkipBuild reuses an existing ISO.

.PARAMETER SourceIso  Stock converted ISO to service (skips UUP fetch/convert).
.PARAMETER SkipBuild  Reuse an existing C:\MiOS\iso\MiOS-Xbox.iso.
.PARAMETER VMName     Hyper-V VM name (default MiOS-XBOX-Test).
#>
[CmdletBinding()]
param(
    [string]$SourceIso,
    [string]$TomlPath = 'C:\mios-bootstrap\mios.toml',
    [switch]$SkipBuild,
    [string]$VMName   = 'MiOS-XBOX-Test',
    [string]$LogDir   = 'C:\MiOS\logs',
    [int]$InstallTimeoutMin = 75,
    [int]$DeployTimeoutMin  = 50
)
$ErrorActionPreference = 'Continue'
$dir = 'C:\mios-bootstrap\src\autounattend'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logFile = Join-Path $LogDir 'deploy.log'
$statusF = Join-Path $LogDir 'status.json'
$isoOut  = 'C:\MiOS\iso\MiOS-Xbox.iso'
$state = [ordered]@{ stage = 'init'; status = 'running'; started = (Get-Date).ToString('o'); iso = $null; vm = $VMName; markers = @{}; selftest = $null; error = $null }

function Save-Status { try { $state.updated = (Get-Date).ToString('o'); ($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusF -Encoding utf8 } catch {} }
function Log { param([string]$m, [string]$c = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $m
    $line | Out-File -Append -Encoding utf8 $logFile
    Write-Host $line -ForegroundColor $c
}
function Stage { param([string]$s, [string]$m) $state.stage = $s; Save-Status; Log "==== STAGE $s :: $m ====" Cyan }
function Fail { param([string]$m) $state.status = 'failed'; $state.error = $m; Save-Status; Log "FAILED: $m" Red; try { Stop-Transcript | Out-Null } catch {}; exit 1 }

try { Start-Transcript -Path (Join-Path $LogDir 'deploy.transcript.log') -Append | Out-Null } catch {}
$adm = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $adm) { Fail 'not elevated -- launch via Start-Process -Verb RunAs' }
Log "MiOS-XBOX deploy harness (elevated) start" Green

# ---------------------------------------------------------------- STAGE 1: build
Stage '1-build' 'produce the fixed MiOS-XBOX ISO'
if ($SkipBuild -and (Test-Path $isoOut)) {
    Log "SkipBuild: reusing $isoOut ($('{0:N2}' -f ((Get-Item $isoOut).Length/1GB)) GB)"
    $state.iso = $isoOut
} else {
    if (-not $SourceIso) {
        $SourceIso = (Get-ChildItem 'C:\MiOS\uup\package' -Filter '*.ISO' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
    if (-not $SourceIso -or -not (Test-Path $SourceIso)) { Fail "no SourceIso and no stock ISO under C:\MiOS\uup\package" }
    Log "building from stock ISO: $SourceIso"
    try {
        $iso = & (Join-Path $dir 'New-MiOSISO.ps1') -TomlPath $TomlPath -SourceIso $SourceIso 2>&1 | Tee-Object -Append -FilePath $logFile | Select-Object -Last 1
        $iso = @($iso) | Where-Object { "$_" -match '\.iso$' -and (Test-Path "$_") } | Select-Object -Last 1
        if (-not $iso) { $iso = if (Test-Path $isoOut) { $isoOut } else { $null } }
        if (-not $iso) { Fail "build finished but no output ISO found" }
        $state.iso = "$iso"; Save-Status
        Log "ISO built: $iso ($('{0:N2}' -f ((Get-Item $iso).Length/1GB)) GB)" Green
    } catch { Fail "build threw: $($_.Exception.Message)" }
}
$iso = $state.iso

# --------------------------------------------- STAGE 1b: parse guest creds
$creds = @()
$media = 'C:\MiOS\isobuild\media\autounattend.xml'
if (Test-Path $media) {
    try {
        [xml]$au = Get-Content $media -Raw
        $u = ($au.unattend.settings.component.AutoLogon.Username | Where-Object { $_ } | Select-Object -First 1)
        $p = ($au.unattend.settings.component.AutoLogon.Password.Value | Where-Object { $_ } | Select-Object -First 1)
        if ($u) { $creds += @{ u = "$u"; p = "$p" } }
    } catch {}
}
foreach ($c in @(@{u='mios';p='mios'}, @{u='Administrator';p='mios'}, @{u='mios';p=''})) { $creds += $c }
Log ("guest cred candidates: {0}" -f (($creds | ForEach-Object { $_.u }) -join ', '))

# ---------------------------------------------------------------- STAGE 2: vm
Stage '2-vm' 'recreate + boot the Hyper-V VM'
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) { Fail "Hyper-V module absent -- Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All (reboot)" }
Get-VM -Name $VMName -ErrorAction SilentlyContinue | ForEach-Object { if ($_.State -ne 'Off') { Stop-VM $_ -TurnOff -Force -EA SilentlyContinue }; Remove-VM $_ -Force -EA SilentlyContinue }
$vmDir = 'C:\MiOS\test-vm'; New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
$vhd = Join-Path $vmDir "$VMName.vhdx"; Remove-Item $vhd -Force -EA SilentlyContinue
try {
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 8GB -NewVHDPath $vhd -NewVHDSizeBytes 100GB -Path $vmDir | Out-Null
    Set-VM -Name $VMName -ProcessorCount 4 -AutomaticCheckpointsEnabled $false
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -MinimumBytes 2GB -StartupBytes 8GB -MaximumBytes 8GB
    Add-VMDvdDrive -VMName $VMName -Path $iso
    $dvd = Get-VMDvdDrive -VMName $VMName
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -FirstBootDevice $dvd
    $swv = Get-VMSwitch -EA SilentlyContinue | Where-Object Name -eq 'Default Switch'
    if (-not $swv) { $swv = Get-VMSwitch -SwitchType External -EA SilentlyContinue | Select-Object -First 1 }
    if ($swv) { Connect-VMNetworkAdapter -VMName $VMName -SwitchName $swv.Name; Log "NIC -> $($swv.Name)" } else { Log "WARN no NAT/External vSwitch -- guest has no internet; MiOS bootstrap will not fetch" Yellow }
    Start-VM -Name $VMName
    Log "VM '$VMName' started on the ISO (SecureBoot on, 8GB/4vCPU/100GB, DVD-first)" Green
} catch { Fail "VM create/boot failed: $($_.Exception.Message)" }

# --------------------------------------------- STAGE 3: wait for guest (PS Direct)
Stage '3-install' 'wait for Windows install + auto-logon (PowerShell Direct)'
function Get-GuestSession {
    foreach ($c in $creds) {
        try {
            $sec = ConvertTo-SecureString $c.p -AsPlainText -Force
            $cred = New-Object PSCredential($c.u, $sec)
            $s = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop
            $state.markers.creds = $c.u; Save-Status
            return $s
        } catch {}
    }
    return $null
}
$deadline = (Get-Date).AddMinutes($InstallTimeoutMin)
$sess = $null
while ((Get-Date) -lt $deadline -and -not $sess) {
    Start-Sleep -Seconds 30
    $vm = Get-VM -Name $VMName -EA SilentlyContinue
    $sess = Get-GuestSession
    Log ("waiting for guest... vm={0} heartbeat={1} psdirect={2}" -f $vm.State, $vm.Uptime, [bool]$sess)
}
if (-not $sess) { Fail "guest never became reachable via PowerShell Direct within $InstallTimeoutMin min (install stuck? check via Hyper-V console)" }
Log "PowerShell Direct connected to guest (creds=$($state.markers.creds))" Green

# --------------------------------------------- STAGE 4: wait for MiOS deploy
Stage '4-deploy' 'wait for the MiOS bootstrap to deploy inside the guest'
$deadline = (Get-Date).AddMinutes($DeployTimeoutMin)
$deployed = $false
while ((Get-Date) -lt $deadline -and -not $deployed) {
    Start-Sleep -Seconds 45
    try {
        $m = Invoke-Command -Session $sess -ScriptBlock {
            [pscustomobject]@{
                setupcomplete = Test-Path 'C:\Windows\Temp\mios-setupcomplete.log'
                launcher      = Test-Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\mios-firstboot.cmd'
                firstboot     = Test-Path 'C:\ProgramData\MiOS\firstboot.marker'
                provisioned   = Test-Path 'C:\ProgramData\MiOS\provisioned.marker'
                done          = Test-Path 'C:\ProgramData\MiOS\firstboot.done'
                daemontask    = [bool](& schtasks.exe /query /tn 'MiOS-Daemon' 2>$null)
                wsl           = [bool](((& wsl.exe -l -q 2>$null) -join '') -match 'MiOS')
                repo          = Test-Path 'C:\mios-bootstrap'
            }
        } -ErrorAction Stop
        $state.markers = @{} + ($m.PSObject.Properties | ForEach-Object -Begin { $h=@{} } -Process { $h[$_.Name]=$_.Value } -End { $h }); Save-Status
        Log ("deploy markers: setupcomplete={0} launcher={1} firstboot={2} provisioned={3} done={4} daemon={5} wsl={6} repo={7}" -f $m.setupcomplete,$m.launcher,$m.firstboot,$m.provisioned,$m.done,$m.daemontask,$m.wsl,$m.repo)
        if ($m.done -or $m.provisioned -or $m.wsl) { $deployed = $true }
    } catch { Log "guest poll error (retrying): $($_.Exception.Message)" Yellow; $sess = Get-GuestSession }
}
Log ("deploy wait ended (deployed={0})" -f $deployed) $(if($deployed){'Green'}else{'Yellow'})

# --------------------------------------------- STAGE 5: in-guest self-test + logs
Stage '5-verify' 'run Test-MiOSXbox.ps1 in the guest + collect logs'
try {
    Copy-Item -ToSession $sess -Path (Join-Path $dir 'Test-MiOSXbox.ps1') -Destination 'C:\Windows\Temp\Test-MiOSXbox.ps1' -Force -EA Stop
    $test = Invoke-Command -Session $sess -ScriptBlock { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Windows\Temp\Test-MiOSXbox.ps1' -Json } -ErrorAction Stop
    $state.selftest = ("$test" | Out-String).Trim(); Save-Status
    Log "self-test JSON:`n$($state.selftest)"
    $logs = Invoke-Command -Session $sess -ScriptBlock {
        [pscustomobject]@{
            setupcomplete = (Get-Content 'C:\Windows\Temp\mios-setupcomplete.log' -Raw -EA SilentlyContinue)
            daemon        = (Get-Content 'C:\ProgramData\MiOS\logs\mios-daemon.log' -Tail 40 -EA SilentlyContinue) -join "`n"
            host          = (Get-Content 'C:\ProgramData\MiOS\logs\mios-host.log' -Tail 40 -EA SilentlyContinue) -join "`n"
            health        = (Get-Content 'C:\ProgramData\MiOS\health.json' -Raw -EA SilentlyContinue)
        }
    } -ErrorAction SilentlyContinue
    if ($logs) {
        "==== GUEST mios-setupcomplete.log ====`n$($logs.setupcomplete)`n==== GUEST mios-daemon.log (tail) ====`n$($logs.daemon)`n==== GUEST mios-host.log (tail) ====`n$($logs.host)`n==== GUEST health.json ====`n$($logs.health)" |
            Out-File -Append -Encoding utf8 (Join-Path $LogDir 'guest-logs.txt')
        Log "collected guest logs -> $LogDir\guest-logs.txt" Green
    }
} catch { Log "self-test/collection error: $($_.Exception.Message)" Yellow }

$state.status = if ($deployed) { 'deployed' } else { 'incomplete' }
Save-Status
Log "DONE (status=$($state.status)). Monitor: $statusF ; full log: $logFile ; guest logs: $LogDir\guest-logs.txt" Green
try { Remove-PSSession $sess -EA SilentlyContinue } catch {}
try { Stop-Transcript | Out-Null } catch {}
