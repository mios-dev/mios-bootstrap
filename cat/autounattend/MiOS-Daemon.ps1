# AI-hint: The MiOS Daemon -- a boot + interval Windows supervisor driven by Task
# Scheduler (a per-minute MINUTE task run as mios-svc, because WSL cannot run as
# SYSTEM). One invocation = one tick then exit (Task Scheduler IS the service, so
# there is no fragile infinite loop / execution-time-limit). It circumvents the
# one-shot triggers (SetupComplete/FirstLogonCommands/RunOnce -- OEM-key skip,
# OOBE fragility, multi-trigger race) by being the always-on self-healing owner of
# the MiOS host: each tick (1) touches the WSL service plane to keep it warm,
# (2) health-checks the MiOS endpoints + WSL and writes structured health/logs,
# (3) auto-updates the repos on a time interval and restarts the plane on change.
# The one-time interactive install stays with the first-logon launcher (Get-MiOS
# needs an interactive UAC session); the daemon owns maintenance thereafter.
# AI-related: mios-bootstrap, MiOS-Host.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1, mios.toml [autounattend.daemon]
#Requires -Version 5.1
<#
.SYNOPSIS
    MiOS boot/interval supervisor: keep-warm + health + auto-update, self-healing.
    Default = one tick then exit (Task Scheduler re-invokes it). -Loop runs
    continuously for manual testing.
.PARAMETER Loop      Run continuously (manual/testing) instead of one tick.
.PARAMETER StateDir  Where config/markers/logs live (default C:\ProgramData\MiOS).
#>
[CmdletBinding()]
param(
    [switch]$Loop,
    [string]$StateDir = 'C:\ProgramData\MiOS'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Join-Path $StateDir 'logs') | Out-Null
$log      = Join-Path $StateDir 'logs\mios-daemon.log'
$health   = Join-Path $StateDir 'health.json'
$lastUpd  = Join-Path $StateDir 'daemon-last-update.txt'
function Log { param([string]$m) try { "$([DateTime]::UtcNow.ToString('o')) $m" | Out-File -Append -Encoding utf8 $log } catch {} }

# --- Config (SSOT): <StateDir>\mios-daemon.json, rendered from mios.toml
#     [autounattend.daemon] at build. Defaults keep the daemon working without it. -
$cfg = [ordered]@{
    tick_seconds       = 60
    update_every_min   = 30
    auto_update        = $true
    distro             = 'MiOS'
    endpoints          = [ordered]@{ 'agent-pipe' = 'http://localhost:8640/v1/models'; 'hermes' = 'http://localhost:8642/health'; 'llm-light' = 'http://localhost:8450/health' }
    repos              = @('C:\mios-bootstrap', 'M:\MiOS\repo\mios', 'M:\MiOS\repo\mios-bootstrap')
}
$cfgFile = Join-Path $StateDir 'mios-daemon.json'
if (Test-Path $cfgFile) {
    try { $j = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json; foreach ($k in @($cfg.Keys)) { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } } }
    catch { Log "config parse failed ($($_.Exception.Message)); using defaults" }
}

$wsl = if (Test-Path "$env:ProgramFiles\WSL\wsl.exe") { "$env:ProgramFiles\WSL\wsl.exe" } else { 'wsl.exe' }
$env:WSL_UTF8 = '1'
$DistroCandidates = @($cfg.distro, 'podman-MiOS-DEV', 'MiOS-DEV') | Where-Object { $_ } | Select-Object -Unique
function Resolve-Distro {
    $names = (((& $wsl --list --quiet 2>$null) -join "`n") -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($c in $DistroCandidates) { if ($names -contains $c) { return $c } }
    return $null
}

function Invoke-Tick {
    $status = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); distro = $null; wsl = $false; endpoints = @{}; updated = $false }

    # 1) keep the WSL service plane warm (only if a distro is registered)
    $distro = Resolve-Distro
    $status.distro = $distro
    if ($distro) {
        $status.wsl = $true
        try { & $wsl -d $distro --exec /bin/true 2>$null } catch {}
    }

    # 2) health-check the MiOS endpoints (Windows localhost -> WSL2 forward)
    foreach ($name in $cfg.endpoints.PSObject.Properties.Name) {
        $ok = $false
        try { $r = Invoke-WebRequest -Uri $cfg.endpoints.$name -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop; $ok = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) } catch { $ok = $false }
        $status.endpoints[$name] = $ok
    }

    # 3) auto-update on a TIME interval (per-tick process, so no in-memory counter):
    #    pull the repos; if HEAD moved, sync the overlay + restart the mios-* units.
    if ($cfg.auto_update) {
        $due = $true
        if (Test-Path $lastUpd) {
            try { $due = ([DateTime]::UtcNow - [DateTime]::Parse((Get-Content $lastUpd -Raw))).TotalMinutes -ge [double]$cfg.update_every_min } catch { $due = $true }
        }
        if ($due) {
            [DateTime]::UtcNow.ToString('o') | Set-Content -LiteralPath $lastUpd
            $changed = $false
            foreach ($repo in @($cfg.repos)) {
                if (-not (Test-Path (Join-Path $repo '.git'))) { continue }
                try {
                    $before = (& git -C $repo rev-parse HEAD 2>$null)
                    & git -C $repo pull --ff-only 2>&1 | ForEach-Object { Log "update[$repo]: $_" }
                    $after = (& git -C $repo rev-parse HEAD 2>$null)
                    if ($before -and $after -and $before -ne $after) { $changed = $true; Log "update[$repo]: $before -> $after" }
                } catch { Log "update[$repo] failed: $($_.Exception.Message)" }
            }
            $status.updated = $changed
            if ($changed -and $distro) {
                try { & $wsl -d $distro --exec /bin/sh -lc 'command -v mios-pull >/dev/null 2>&1 && mios-pull --hard >/dev/null 2>&1; command -v systemctl >/dev/null 2>&1 && systemctl restart "mios-*" 2>/dev/null || true' } catch {}
                Log 'applied repo update -> synced overlay + restarted mios-* units'
            }
        }
    }

    try { $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $health -Encoding utf8 } catch {}
    $up = @($status.endpoints.Values | Where-Object { $_ }).Count
    Log ("tick: distro={0} wsl={1} endpoints_up={2}/{3} updated={4}" -f $distro, $status.wsl, $up, $status.endpoints.Count, $status.updated)
}

# --- entry: one tick (Task Scheduler drives cadence) unless -Loop --------------
if ($Loop) {
    Log "MiOS-Daemon LOOP start (tick=$($cfg.tick_seconds)s)"
    while ($true) { try { Invoke-Tick } catch { Log "tick crashed (loop continues): $($_.Exception.Message)" }; Start-Sleep -Seconds ([int]$cfg.tick_seconds) }
} else {
    try { Invoke-Tick } catch { Log "tick crashed: $($_.Exception.Message)" }
}
