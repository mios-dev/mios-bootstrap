# AI-hint: The MiOS-Host boot payload -- runs at Windows startup (ONSTART scheduled task) under the dedicated NON-admin local account (.\mios-svc), BEFORE any interactive/RDP logon, to bring the MiOS WSL2+systemd+podman service plane up as a system service. On FIRST run it does the one-time heavy install (nested MiOS irm|iex bootstrap); on EVERY boot it (re)starts the distro and holds it alive with a host-side `--exec sleep infinity` process (the reliable keep-alive; vmIdleTimeout/-in-distro-systemd are not sufficient). CANNOT run as LocalSystem: WSL is tied to a user profile (microsoft/WSL#11280) -- hence the mios-svc identity.
# AI-related: mios-bootstrap, New-MiOSHostServiceCommands (MiOS-Provision.lib.ps1), New-MiOSAutounattend.ps1, Get-MiOS.ps1, docs/pre-logon-system-services.md
#Requires -Version 5.1
<#
.SYNOPSIS
    Boot the MiOS WSL2 service plane before logon, keep it alive. Payload of the
    MiOS-Host ONSTART task (runs as .\mios-svc, Session 0, pre-logon).
.PARAMETER Distro        WSL distro name (default MiOS).
.PARAMETER BootstrapUrl  Nested MiOS installer for the one-time first-run install.
.PARAMETER StateDir      Where the provisioned marker + logs live.
#>
[CmdletBinding()]
param(
    [string]$Distro = 'MiOS',
    [string]$BootstrapUrl = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1',
    [string]$StateDir = 'C:\ProgramData\MiOS'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Join-Path $StateDir 'logs') | Out-Null
$log    = Join-Path $StateDir 'logs\mios-host.log'
$marker = Join-Path $StateDir 'provisioned.marker'
function Log { param([string]$m) "$([Environment]::TickCount) $m" | Out-File -Append -Encoding utf8 $log }

# Prefer the packaged WSL binary -- the System32 shim can fail in Session 0; the
# packaged one carries the WSL-2.0.0 Session-0 fix.
$wsl = if (Test-Path "$env:ProgramFiles\WSL\wsl.exe") { "$env:ProgramFiles\WSL\wsl.exe" } else { 'wsl.exe' }

# wsl.exe emits --list output as UTF-16LE regardless of codepage (microsoft/WSL#4607);
# captured by PS 5.1 it becomes NUL-interleaved mojibake. WSL_UTF8=1 makes it emit
# UTF-8; strip any residual NULs as belt-and-suspenders.
$env:WSL_UTF8 = '1'
# Resolve the ACTUAL registered distro by EXACT name. The nested Get-MiOS bootstrap
# registers 'podman-MiOS-DEV' (or 'MiOS-DEV'), NOT the SSOT hint 'MiOS'; and `wsl -d`
# needs the exact name -- a substring/regex match would falsely pass the readiness
# gate while `wsl -d MiOS` still failed with WSL_E_DISTRO_NOT_FOUND. Returns the
# real name (used for both the readiness check and the keep-alive), or $null.
$DistroCandidates = @($Distro, 'podman-MiOS-DEV', 'MiOS-DEV') | Where-Object { $_ } | Select-Object -Unique
function Resolve-MiOSDistro {
    $names = (((& $wsl --list --quiet 2>$null) -join "`n") -replace "`0", '') -split "`r?`n" |
             ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($c in $DistroCandidates) { if ($names -contains $c) { return $c } }
    return $null
}

# --- FIRST RUN: one-time heavy install (as mios-svc, NOT SYSTEM) -------------
# The nested MiOS installer provisions the WSL2 distro + podman + Quadlet units in
# THIS account's Lxss hive (why the boot service must be a real user, not LocalSystem).
if (-not (Test-Path $marker)) {
    # BOUNDED attempts: the nested `irm|iex` begins with a DESTRUCTIVE full-reset. Cap
    # retries so a persistently-failing install can't wipe-and-reclone on every boot
    # forever; after the cap, write the marker (give up) rather than loop destructively.
    $attemptFile = Join-Path $StateDir 'first-run.attempts'
    $attempts = 0
    if (Test-Path $attemptFile) { $attempts = [int]((Get-Content $attemptFile -ErrorAction SilentlyContinue | Select-Object -First 1)) }
    if ($attempts -ge 5) {
        New-Item -ItemType File -Force -Path $marker | Out-Null
        Log "first-run: attempt cap ($attempts) reached -- giving up; marker written to stop the destructive loop"
    } else {
        Set-Content -Path $attemptFile -Value ($attempts + 1)
        Log "first-run (attempt $($attempts + 1)): MiOS install via $BootstrapUrl"
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm $BootstrapUrl | iex"
            # Native exe does NOT throw on non-zero exit -> check $LASTEXITCODE + that a
            # real MiOS distro is now registered. Only then mark provisioned; else the
            # next boot retries (fresh boxes often have no/late network / reboot-pending).
            $distro = Resolve-MiOSDistro
            if (($LASTEXITCODE -eq 0) -and $distro) { New-Item -ItemType File -Force -Path $marker | Out-Null; Log "first-run: install complete (distro '$distro'), marker written" }
            else { Log "first-run: incomplete (exit=$LASTEXITCODE, distro=$distro) -- next boot retries" }
        } catch { Log "first-run: install FAILED: $($_.Exception.Message)" }
    }
}

# --- EVERY BOOT: ensure the distro is registered + running, then hold it ------
$distro = Resolve-MiOSDistro
if (-not $distro) {
    Log "no MiOS distro registered yet (candidates: $($DistroCandidates -join ', ')) -- exiting; next boot retries"
    return
}
Log "starting + holding distro '$distro'"
# systemd=true in the distro's /etc/wsl.conf brings up podman.socket + the MiOS
# Quadlet units when systemd starts. This host-side holder keeps the utility VM
# alive across the (userless) boot session -- the documented reliable keep-alive.
& $wsl -d $distro --exec /bin/sh -c 'command -v systemctl >/dev/null 2>&1 && systemctl is-system-running --wait >/dev/null 2>&1; exec /usr/bin/sleep infinity'
