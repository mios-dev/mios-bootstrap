# AI-hint: MiOS-Xbox Stage-1 PROVISION STATE MACHINE. Reboot-surviving driver that
# turns the BAKED-IN seed blobs into a running MiOS brain with NO download/build on
# the critical path. Registered as a Task Scheduler MINUTE task run as the RID-500
# admin (mios-sudo, HIGHEST) so it fires within a minute of every boot and re-fires
# across the reboots WSL/podman need. Each invocation runs exactly ONE idempotent
# phase (check-before-doing), reports weighted progress via MiOS-Progress.psm1 so the
# full-screen bar advances, and -- when a phase needs a reboot -- sets reboot_pending
# and `shutdown /r`. It RESUMES at the first non-done phase (state persisted in
# provision-state.json). Per-phase attempt cap + timeout -> state:error (degrade-open:
# never the old destructive per-boot full-reset, never a hard brick). On all-done it
# clears its own task and hands off to the desktop / Xbox FSE.
# AI-related: mios-bootstrap, MiOS-Progress.psm1, write-mios-progress.sh, MiOS-SetupExperience.ps1, MiOS-Host.ps1, MiOS-Provision.lib.ps1, mios.toml [autounattend.provision]/[autounattend.seed]
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$StateDir = 'C:\ProgramData\MiOS',
    [string]$TomlPath,
    [switch]$NoSelfKick,     # do not immediately relaunch after a non-reboot phase
    [switch]$NoRegister      # do not self-register the MINUTE task (already registered)
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# --- single-instance: the MINUTE task tick + any self-kick must never overlap. ---
$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MiOS-Provision-Driver', [ref]$mutexCreated)
if (-not $mutexCreated) { return }   # another invocation owns the run

New-Item -ItemType Directory -Force -Path (Join-Path $StateDir 'logs') | Out-Null
$log       = Join-Path $StateDir 'logs\mios-provision.log'
$stateFile = Join-Path $StateDir 'provision-state.json'
$attemptDir = Join-Path $StateDir 'attempts'
New-Item -ItemType Directory -Force -Path $attemptDir | Out-Null
function Log { param([string]$m) try { "$([DateTime]::UtcNow.ToString('o')) $m" | Out-File -Append -Encoding utf8 $log } catch {} }

# --- setup safety check: prevent premature reboots during Windows Setup/OOBE ---
$setupInProgress = (Get-ItemProperty -Path "HKLM:\SYSTEM\Setup" -Name "SystemSetupInProgress" -ErrorAction SilentlyContinue).SystemSetupInProgress
$oobeInProgress = (Get-ItemProperty -Path "HKLM:\SYSTEM\Setup" -Name "OOBEInProgress" -ErrorAction SilentlyContinue).OOBEInProgress
if ($setupInProgress -eq 1 -or $oobeInProgress -eq 1) {
    Log "Windows Setup or OOBE is in progress (SetupState=$setupInProgress, OOBEState=$oobeInProgress). Deferring execution."
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
    return
}


Import-Module (Join-Path $PSScriptRoot 'MiOS-Progress.psm1') -Force -ErrorAction SilentlyContinue
if (-not (Get-Command Write-MiOSProgress -ErrorAction SilentlyContinue)) {
    # If the module could not be staged (should never happen), a no-op keeps the
    # driver degrade-open rather than crashing the whole first-boot.
    function Write-MiOSProgress { param($Step,$Pct,$State,$RebootPending,$Note,$StateFile) }
    function Initialize-MiOSProgress { param($StateFile,[switch]$Force) }
    function Get-MiOSProgressState { param($StateFile) $null }
    Log 'WARN: MiOS-Progress.psm1 not importable -- progress reporting is a no-op (provisioning still runs).'
}

# --- SSOT config (degrade-open defaults). Prefer the shared lib reader if present. ---
$lib = Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1'
$toml = $null
if (Test-Path $lib) {
    try {
        . $lib
        if (-not $TomlPath) {
            foreach ($c in @('C:\ProgramData\MiOS\repo\mios-bootstrap\mios.toml','M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
                if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path -LiteralPath $c).Path; break }
            }
        }
        if ($TomlPath) { $toml = Read-MiosToml -Path $TomlPath }
    } catch { Log "toml read failed: $($_.Exception.Message)" }
}
function Cfg { param([string]$Key,[string]$Def)
    if ($toml -and (Get-Command Get-Toml -ErrorAction SilentlyContinue)) { return (Get-Toml $toml $Key $Def) }
    return $Def
}

$enabled       = (Cfg 'autounattend.provision.enable' 'true') -match '^(?i:true|1|yes)$'
$attemptCap    = [int](Cfg 'autounattend.provision.phase_attempt_cap' '3')
$phaseTimeout  = [int](Cfg 'autounattend.provision.phase_timeout_sec' '1800')
$autoLogonCnt  = [int](Cfg 'autounattend.provision.autologon_count' '6')
$svcUser       = Cfg 'autounattend.service.svc_user' 'mios-sudo'
$svcPass       = Cfg 'autounattend.service.svc_password' (Cfg 'identity.default_password' 'user')

$seedDir       = Join-Path $StateDir 'seed'
$seedRootfs    = Join-Path $seedDir (Cfg 'autounattend.seed.rootfs' 'mios-rootfs.tar')
$seedOci       = Join-Path $seedDir (Cfg 'autounattend.seed.oci_archive' 'mios-image.oci.tar')
$seedMachine   = Join-Path $seedDir (Cfg 'autounattend.seed.podman_machine' 'podman-machine.tar')
$distroName    = Cfg 'autounattend.seed.distro' 'MiOS'
$imageRef      = Cfg 'autounattend.seed.image_ref' 'ghcr.io/mios-dev/mios:latest'
$installDir    = Cfg 'autounattend.seed.install_dir' 'M:\wsl\MiOS'
if (-not (Test-Path -LiteralPath (Split-Path -Qualifier $installDir) -ErrorAction SilentlyContinue)) {
    $installDir = Join-Path $StateDir 'wsl\MiOS'   # M: absent -> keep on C:
}

# --- WSL plumbing (mirrors MiOS-Host.ps1: packaged wsl.exe, UTF-8, exact-name resolve) ---
$wsl = if (Test-Path "$env:ProgramFiles\WSL\wsl.exe") { "$env:ProgramFiles\WSL\wsl.exe" } else { 'wsl.exe' }
$env:WSL_UTF8 = '1'
$DistroCandidates = @($distroName, 'podman-MiOS-DEV', 'MiOS-DEV') | Where-Object { $_ } | Select-Object -Unique
function Resolve-MiOSDistro {
    $names = (((& $wsl --list --quiet 2>$null) -join "`n") -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($c in $DistroCandidates) { if ($names -contains $c) { return $c } }
    return $null
}

# --- attempt bookkeeping (bounded; NOT the destructive per-boot reset) -----------
function Get-Attempts { param([string]$Phase) $f = Join-Path $attemptDir "$Phase.count"; if (Test-Path $f) { return [int]((Get-Content $f -EA SilentlyContinue | Select-Object -First 1)) } return 0 }
function Add-Attempt  { param([string]$Phase) $n = (Get-Attempts $Phase) + 1; Set-Content -Path (Join-Path $attemptDir "$Phase.count") -Value $n; return $n }
function Clear-Attempt { param([string]$Phase) Remove-Item (Join-Path $attemptDir "$Phase.count") -Force -EA SilentlyContinue }

# --- reboot helper: flag it in the bar, then reboot (a few seconds to flush the UI). ---
function Request-Reboot { param([string]$Phase,[string]$Why)
    Log "phase '$Phase' requires reboot: $Why"
    Write-MiOSProgress -Step $Phase -Pct 100 -State running -RebootPending $true -Note "reboot: $Why" -StateFile $stateFile | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $StateDir 'reboot.pending') | Out-Null
    Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r','/t','8','/c','MiOS is preparing your system and will restart.' -WindowStyle Hidden
}

# Run a blocking native command with a hard timeout. Returns @{ exit; timedout }.
function Invoke-Bounded { param([string]$File,[string[]]$Args,[int]$TimeoutSec)
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Args -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.WaitForExit($TimeoutSec * 1000)) { return @{ exit = $p.ExitCode; timedout = $false } }
        try { $p.Kill() } catch {}
        return @{ exit = -1; timedout = $true }
    } catch { return @{ exit = -1; timedout = $false; err = $_.Exception.Message } }
}

$seedShWin = Join-Path $StateDir 'write-mios-progress.sh'
function Get-SeedShInDistro {
    # /mnt/c path of the POSIX progress twin, for in-distro sub-step reporting.
    return '/mnt/c/ProgramData/MiOS/write-mios-progress.sh'
}

# ============================================================================
#  PHASES -- each returns @{ done=<bool>; reboot=<bool>; err=<string|null> }.
#  Every phase CHECKS BEFORE DOING and LOADS from the seed dir (no download).
# ============================================================================

function Phase-WslFeature {
    Write-MiOSProgress -Step 'wsl-feature' -Pct 10 -State running -StateFile $stateFile | Out-Null
    $need = @()
    foreach ($f in 'VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux') {
        $st = $null
        try { $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State } catch {}
        if ("$st" -ne 'Enabled') { $need += $f }
    }
    if ($need.Count -eq 0) {
        Write-MiOSProgress -Step 'wsl-feature' -Pct 100 -State done -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    Write-MiOSProgress -Step 'wsl-feature' -Pct 40 -State running -Note "enabling: $($need -join ', ')" -StateFile $stateFile | Out-Null
    foreach ($f in $need) {
        try { & dism.exe /online /enable-feature /featurename:$f /all /norestart 2>&1 | Out-Null } catch {}
    }
    # Feature enable takes effect on reboot; the answer file already enabled these
    # offline, so on a factory boot this phase is usually already 'done' above.
    return @{ done = $false; reboot = $true; err = $null }
}

function Phase-SeedStage {
    Write-MiOSProgress -Step 'seed-stage' -Pct 20 -State running -StateFile $stateFile | Out-Null
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
    # If the blobs were baked at the media root instead of ProgramData\MiOS\seed,
    # copy them in now (offline; both placements supported -- see New-MiOSISO.ps1).
    foreach ($alt in @('C:\seed','M:\seed', (Join-Path $env:SystemDrive 'MiOS-Seed'))) {
        if (Test-Path -LiteralPath $alt) {
            foreach ($b in @($seedRootfs,$seedOci,$seedMachine)) {
                $name = Split-Path -Leaf $b
                $src = Join-Path $alt $name
                if ((Test-Path $src) -and -not (Test-Path $b)) { try { Copy-Item $src $b -Force } catch {} }
            }
        }
    }
    $have = @{
        rootfs  = (Test-Path $seedRootfs)
        oci     = (Test-Path $seedOci)
        machine = (Test-Path $seedMachine)
    }
    $note = "rootfs=$($have.rootfs) oci=$($have.oci) machine=$($have.machine)"
    Log "seed-stage: $note (dir=$seedDir)"
    # Degrade-open: even with NO seed we mark done -- later phases fall back to the
    # embedded Get-MiOS build path (today's behavior) so Stage-1 tolerates missing seeds.
    Write-MiOSProgress -Step 'seed-stage' -Pct 100 -State done -Note $note -StateFile $stateFile | Out-Null
    return @{ done = $true; reboot = $false; err = $null }
}

function Phase-WslImport {
    Write-MiOSProgress -Step 'wsl-import' -Pct 5 -State running -StateFile $stateFile | Out-Null
    if (Resolve-MiOSDistro) {
        Write-MiOSProgress -Step 'wsl-import' -Pct 100 -State done -Note 'distro already registered' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    if (Test-Path $seedRootfs) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Write-MiOSProgress -Step 'wsl-import' -Pct 25 -State running -Note "wsl --import $distroName (offline seed)" -StateFile $stateFile | Out-Null
        $r = Invoke-Bounded -File $wsl -Args @('--import', $distroName, $installDir, $seedRootfs, '--version', '2') -TimeoutSec $phaseTimeout
        if ($r.timedout) { return @{ done = $false; reboot = $false; err = "wsl --import timed out after ${phaseTimeout}s" } }
        Start-Sleep -Seconds 2
        if (Resolve-MiOSDistro) {
            Write-MiOSProgress -Step 'wsl-import' -Pct 100 -State done -Note 'imported from seed rootfs' -StateFile $stateFile | Out-Null
            return @{ done = $true; reboot = $false; err = $null }
        }
        return @{ done = $false; reboot = $false; err = "wsl --import exit=$($r.exit) but no distro registered" }
    }
    # --- Fallback (no seed): today's behavior -- the embedded offline installer. ---
    $localGetMios = 'C:\ProgramData\MiOS\repo\mios-bootstrap\Get-MiOS.ps1'
    if (Test-Path $localGetMios) {
        Write-MiOSProgress -Step 'wsl-import' -Pct 30 -State running -Note 'no seed -> embedded Get-MiOS (build fallback)' -StateFile $stateFile | Out-Null
        $env:MIOS_AGREEMENT_ACK = 'accepted'; $env:MIOS_AGREEMENT_BANNER = 'silent'; $env:MIOS_PROMPT_TIMEOUT = '1'
        $r = Invoke-Bounded -File 'powershell.exe' -Args @('-NoProfile','-ExecutionPolicy','Bypass','-File',$localGetMios,'-Unattended') -TimeoutSec $phaseTimeout
        if ($r.timedout) { return @{ done = $false; reboot = $false; err = "Get-MiOS fallback timed out after ${phaseTimeout}s" } }
        if (Resolve-MiOSDistro) {
            Write-MiOSProgress -Step 'wsl-import' -Pct 100 -State done -Note 'built via embedded Get-MiOS' -StateFile $stateFile | Out-Null
            return @{ done = $true; reboot = $false; err = $null }
        }
        return @{ done = $false; reboot = $false; err = "Get-MiOS fallback exit=$($r.exit) but no distro registered" }
    }
    return @{ done = $false; reboot = $false; err = 'no seed rootfs and no embedded Get-MiOS.ps1 (nothing to import)' }
}

function Phase-MVolume {
    Write-MiOSProgress -Step 'm-volume' -Pct 30 -State running -StateFile $stateFile | Out-Null
    if (Test-Path -LiteralPath 'M:\') {
        foreach ($d in @('M:\podman\machine','M:\wsl','M:\MiOS')) { try { New-Item -ItemType Directory -Force -Path $d | Out-Null } catch {} }
        Write-MiOSProgress -Step 'm-volume' -Pct 100 -State done -Note 'M: present (carved at install)' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    # Stage-1 is NON-DESTRUCTIVE: do not create/format a volume here. Degrade-open.
    Write-MiOSProgress -Step 'm-volume' -Pct 100 -State done -Note 'M: absent -> skipped (Stage-1 non-destructive)' -StateFile $stateFile | Out-Null
    return @{ done = $true; reboot = $false; err = $null }
}

function Phase-PodmanMachine {
    Write-MiOSProgress -Step 'podman-machine' -Pct 20 -State running -StateFile $stateFile | Out-Null
    # The customer runtime runs podman INSIDE the MiOS distro (systemd + podman.socket),
    # so a separate Windows podman machine is optional. Only stand one up if a seed
    # machine image was baked; otherwise this is a reported no-op. Non-fatal throughout.
    $podman = (Get-Command podman.exe -ErrorAction SilentlyContinue)
    if (-not $podman) {
        Write-MiOSProgress -Step 'podman-machine' -Pct 100 -State done -Note 'no windows podman client -> engine runs in-distro' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    $have = $false
    try { $have = @((& podman.exe machine list --format '{{.Name}}' 2>$null) | Where-Object { $_ }).Count -gt 0 } catch {}
    if ($have) {
        Write-MiOSProgress -Step 'podman-machine' -Pct 100 -State done -Note 'podman machine already present' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    if (Test-Path $seedMachine) {
        Write-MiOSProgress -Step 'podman-machine' -Pct 55 -State running -Note 'init podman machine from seed image' -StateFile $stateFile | Out-Null
        $r = Invoke-Bounded -File 'podman.exe' -Args @('machine','init','--image',$seedMachine) -TimeoutSec $phaseTimeout
        if (-not $r.timedout -and $r.exit -eq 0) {
            try { & podman.exe machine start 2>$null | Out-Null } catch {}
            Write-MiOSProgress -Step 'podman-machine' -Pct 100 -State done -Note 'podman machine up from seed' -StateFile $stateFile | Out-Null
            return @{ done = $true; reboot = $false; err = $null }
        }
        Log "podman-machine: seed init failed (exit=$($r.exit) timedout=$($r.timedout)); continuing (engine still runs in-distro)."
    }
    # Degrade-open: no seed machine / init failed -> the in-distro engine covers it.
    Write-MiOSProgress -Step 'podman-machine' -Pct 100 -State done -Note 'skipped (engine runs in-distro)' -StateFile $stateFile | Out-Null
    return @{ done = $true; reboot = $false; err = $null }
}

function Phase-ImageLoad {
    Write-MiOSProgress -Step 'image-load' -Pct 10 -State running -StateFile $stateFile | Out-Null
    $distro = Resolve-MiOSDistro
    if (-not $distro) { return @{ done = $false; reboot = $false; err = 'no distro to load images into' } }
    if (-not (Test-Path $seedOci)) {
        Write-MiOSProgress -Step 'image-load' -Pct 100 -State done -Note 'no oci seed -> images ship in rootfs' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    # check-before-do: is the image already in the distro's podman storage?
    $exists = $false
    try {
        & $wsl -d $distro -u root --exec /bin/sh -c "command -v podman >/dev/null 2>&1 && podman image exists '$imageRef'" 2>$null
        $exists = ($LASTEXITCODE -eq 0)
    } catch {}
    if ($exists) {
        Write-MiOSProgress -Step 'image-load' -Pct 100 -State done -Note 'image already loaded' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    Write-MiOSProgress -Step 'image-load' -Pct 40 -State running -Note 'podman load (offline oci-archive)' -StateFile $stateFile | Out-Null
    $ociInDistro = '/mnt/c/ProgramData/MiOS/seed/' + (Split-Path -Leaf $seedOci)
    $sh = Get-SeedShInDistro
    # Report the in-distro load into the SAME bar via the POSIX twin, then load.
    $cmd = "sh '$sh' --step image-load --pct 60 --state running 2>/dev/null; podman load -i '$ociInDistro'; rc=`$?; sh '$sh' --step image-load --pct 95 --state running 2>/dev/null; exit `$rc"
    $r = Invoke-Bounded -File $wsl -Args @('-d',$distro,'-u','root','--exec','/bin/sh','-c',$cmd) -TimeoutSec $phaseTimeout
    if ($r.timedout) { return @{ done = $false; reboot = $false; err = "podman load timed out after ${phaseTimeout}s" } }
    if ($r.exit -eq 0) {
        Write-MiOSProgress -Step 'image-load' -Pct 100 -State done -Note 'oci-archive loaded' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    return @{ done = $false; reboot = $false; err = "podman load exit=$($r.exit)" }
}

function Phase-DistroBoot {
    Write-MiOSProgress -Step 'distro-boot' -Pct 10 -State running -StateFile $stateFile | Out-Null
    $distro = Resolve-MiOSDistro
    if (-not $distro) { return @{ done = $false; reboot = $false; err = 'no distro to boot' } }
    # Kick systemd + podman.socket; keep the utility VM warm (host-side holder, detached).
    try { Start-Process -FilePath $wsl -ArgumentList @('-d',$distro,'--exec','/bin/sh','-c','command -v systemctl >/dev/null 2>&1 && systemctl start podman.socket 2>/dev/null; systemctl start "mios-*" 2>/dev/null; exit 0') -WindowStyle Hidden | Out-Null } catch {}
    # Poll systemd readiness + the MiOS endpoint health gate (hermes :8642) up to timeout.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $healthUrl = 'http://localhost:8642/health'
    $ready = $false
    while ($sw.Elapsed.TotalSeconds -lt $phaseTimeout) {
        $sysRun = $false
        try { & $wsl -d $distro --exec /bin/sh -c 'command -v systemctl >/dev/null 2>&1 && systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded"' 2>$null; $sysRun = ($LASTEXITCODE -eq 0) } catch {}
        $brain = $false
        try { $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop; $brain = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) } catch { $brain = $false }
        $pct = [int](12 + [Math]::Min(80, $sw.Elapsed.TotalSeconds / [double]$phaseTimeout * 80))
        Write-MiOSProgress -Step 'distro-boot' -Pct $pct -State running -Note "systemd=$sysRun brain=$brain" -StateFile $stateFile | Out-Null
        if ($brain -or $sysRun) { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if ($ready) {
        Write-MiOSProgress -Step 'distro-boot' -Pct 100 -State done -Note 'brain up (systemd/endpoint healthy)' -StateFile $stateFile | Out-Null
        return @{ done = $true; reboot = $false; err = $null }
    }
    return @{ done = $false; reboot = $false; err = "brain not healthy within ${phaseTimeout}s" }
}

function Phase-FirstBoot {
    Write-MiOSProgress -Step 'firstboot' -Pct 25 -State running -StateFile $stateFile | Out-Null
    # Persist the provisioned marker MiOS-Host/MiOS-FirstBoot honor (stops their retries).
    try { New-Item -ItemType File -Force -Path (Join-Path $StateDir 'provisioned.marker') | Out-Null } catch {}
    # Ensure the always-on keep-alive + supervisor tasks exist (idempotent) so the brain
    # stays warm after we hand off. These run as the RID-500 admin (WSL needs a profile).
    $hostTr   = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-Host.ps1'
    $daemonTr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-Daemon.ps1'
    try { & schtasks.exe /create /tn 'MiOS-Host'   /sc ONSTART      /rl HIGHEST /ru $svcUser /rp $svcPass /tr $hostTr   /f 2>&1 | Out-Null } catch {}
    try { & schtasks.exe /create /tn 'MiOS-Daemon' /sc MINUTE /mo 1 /rl HIGHEST /ru $svcUser /rp $svcPass /tr $daemonTr /f 2>&1 | Out-Null } catch {}
    Write-MiOSProgress -Step 'firstboot' -Pct 70 -State running -StateFile $stateFile | Out-Null
    # Un-arm interactive auto-logon so the box does not auto-logon forever post-setup.
    try { & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' /v AutoLogonCount /t REG_DWORD /d 0 /f 2>&1 | Out-Null } catch {}
    try { & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' /v AutoAdminLogon /t REG_SZ /d 0 /f 2>&1 | Out-Null } catch {}
    # Authoritatively de-arm the full-screen bar's relaunch (the app self-removes too,
    # but it runs unelevated so its HKLM write is best-effort; the RID-500 driver is sure).
    try { & reg.exe delete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' /v 'MiOS-SetupExperience' /f 2>&1 | Out-Null } catch {}
    # Mark the final phase done -> the aggregate flips to 100 + Complete=1 in the mirror.
    Write-MiOSProgress -Step 'firstboot' -Pct 100 -State done -RebootPending $false -Note 'provisioned; handing off' -StateFile $stateFile | Out-Null
    return @{ done = $true; reboot = $false; err = $null }
}

$phasePlan = @(
    @{ id = 'wsl-feature';    fn = 'Phase-WslFeature';    critical = $true }
    @{ id = 'seed-stage';     fn = 'Phase-SeedStage';     critical = $false }
    @{ id = 'wsl-import';     fn = 'Phase-WslImport';     critical = $true }
    @{ id = 'm-volume';       fn = 'Phase-MVolume';       critical = $false }
    @{ id = 'podman-machine'; fn = 'Phase-PodmanMachine'; critical = $false }
    @{ id = 'image-load';     fn = 'Phase-ImageLoad';     critical = $false }
    @{ id = 'distro-boot';    fn = 'Phase-DistroBoot';    critical = $false }
    @{ id = 'firstboot';      fn = 'Phase-FirstBoot';     critical = $true }
)

function Complete-Driver {
    Log 'all phases done -- clearing the driver task + handing off.'
    New-Item -ItemType File -Force -Path (Join-Path $StateDir 'provision.complete') -EA SilentlyContinue | Out-Null
    try { & schtasks.exe /delete /tn 'MiOS-Setup-Driver' /f 2>&1 | Out-Null } catch {}
}

# --- self-register the reboot-surviving MINUTE task (idempotent guard) -----------
function Register-Self {
    if ($NoRegister) { return }
    $existing = & schtasks.exe /query /tn 'MiOS-Setup-Driver' 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-Provision.ps1'
    try { & schtasks.exe /create /tn 'MiOS-Setup-Driver' /sc MINUTE /mo 1 /rl HIGHEST /ru $svcUser /rp $svcPass /tr $tr /f 2>&1 | Out-Null; Log 'self-registered MiOS-Setup-Driver MINUTE task' } catch { Log "self-register failed: $($_.Exception.Message)" }
}

# ============================================================================
#  MAIN -- run exactly ONE phase, then either reboot / self-kick / exit.
# ============================================================================
try {
    if (-not $enabled) { Log 'provisioning disabled (autounattend.provision.enable=false) -- exiting.'; return }
    Register-Self

    # Never wipe an in-progress bar across a reboot; only init if absent.
    if (-not (Test-Path $stateFile)) { Initialize-MiOSProgress -StateFile $stateFile | Out-Null; Log 'initialized provision-state.json (all phases pending)' }

    if (Test-Path (Join-Path $StateDir 'provision.complete')) { Log 'already complete -- clearing task.'; Complete-Driver; return }

    $state = Get-MiOSProgressState -StateFile $stateFile
    # Find the first non-done, non-error phase; an errored critical phase halts driving.
    $target = $null
    foreach ($p in $phasePlan) {
        $ph = $null
        if ($state -and $state.phases) { $ph = $state.phases | Where-Object { "$($_.id)" -eq $p.id } | Select-Object -First 1 }
        $s = if ($ph) { "$($ph.state)" } else { 'pending' }
        if ($s -eq 'done') { continue }
        if ($s -eq 'error') {
            if ($p.critical) { Log "critical phase '$($p.id)' is in error -- finalizing to hand off (degrade-open)."; [void](Phase-FirstBoot); Complete-Driver; return }
            else { continue }   # non-critical error -> skip past it
        }
        $target = $p; break
    }
    if (-not $target) { Log 'no runnable phase (all done/skipped) -- finalizing.'; [void](Phase-FirstBoot); Complete-Driver; return }

    $attempts = Add-Attempt $target.id
    if ($attempts -gt $attemptCap) {
        Log "phase '$($target.id)' exceeded attempt cap ($attemptCap) -> state:error"
        Write-MiOSProgress -Step $target.id -Pct 100 -State error -Note "attempt cap ($attemptCap) exceeded" -StateFile $stateFile | Out-Null
        if ($target.critical) { Log 'critical phase failed -> finalizing to hand off (never a hard brick).'; [void](Phase-FirstBoot); Complete-Driver }
        return
    }

    Log "running phase '$($target.id)' (attempt $attempts/$attemptCap)"
    $result = & (Get-Item "Function:\$($target.fn)").ScriptBlock

    if ($result.reboot) { Request-Reboot -Phase $target.id -Why 'phase requires reboot'; return }

    if ($result.done) {
        Clear-Attempt $target.id
        Log "phase '$($target.id)' done"
        # is that the last phase?
        $st2 = Get-MiOSProgressState -StateFile $stateFile
        $remaining = @($phasePlan | Where-Object { $pp = $_; $rp = ($st2.phases | Where-Object { "$($_.id)" -eq $pp.id } | Select-Object -First 1); (-not $rp) -or ("$($rp.state)" -ne 'done') })
        if ($remaining.Count -eq 0) { Complete-Driver; return }
        # Advance immediately (do not wait a full MINUTE tick) unless suppressed.
        if (-not $NoSelfKick) {
            try { Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath) -WindowStyle Hidden | Out-Null } catch {}
        }
        return
    }

    # Not done, no reboot: transient error -> record + let the next tick retry (bounded).
    $err = if ($result.err) { $result.err } else { 'unknown phase failure' }
    Log "phase '$($target.id)' incomplete: $err (will retry next tick)"
    Write-MiOSProgress -Step $target.id -Pct 0 -State running -Note "retry: $err" -StateFile $stateFile | Out-Null
}
catch {
    Log "driver crashed: $($_.Exception.Message)"
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}
