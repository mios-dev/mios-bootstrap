# AI-hint: Registers the automated MiOS-XBOX ISO build (Build-MiOSXboxISO.ps1) as an ELEVATED, on-demand Windows scheduled task -- the "auth the launch" mechanism for kicking off the build inside a remote Windows App / AVD / Cloud PC / Dev Box session with NO UAC click and NO stored password. Elevation is baked in at registration (RunLevel Highest); the operator triggers it from a low-priv shell with `Start-ScheduledTask`. The task's own principal makes the build's web/UNC fetch a FIRST hop, so the PowerShell-Remoting double-hop never applies. Default principal = SYSTEM (the build uses DISM/oscdimg, not WSL, so SYSTEM works + needs no credential); gMSA for domain passwordless; a named account as fallback.
# AI-related: mios-bootstrap, Build-MiOSXboxISO.ps1, docs/remote-build-auth.md
#Requires -Version 5.1
<#
.SYNOPSIS
    Register Build-MiOSXboxISO.ps1 as an elevated, on-demand scheduled task so it
    can be launched unattended (incl. from a remote session) via Start-ScheduledTask.

.PARAMETER TaskName    Task name (default MiOS-Build).
.PARAMETER Principal   system | gmsa | user  (how the task authenticates + elevates).
.PARAMETER GmsaAccount 'DOMAIN\gMSA_Build$'  (with -Principal gmsa; passwordless).
.PARAMETER RunUser / -RunPassword  'DOMAIN\user' + password (with -Principal user).
.PARAMETER BuildScript Path to Build-MiOSXboxISO.ps1 (default: sibling).
.PARAMETER BuildArgs   Extra args passed to the build (e.g. '-SourceIso M:\...\dev.iso').
.PARAMETER Run         Also trigger the task immediately after registering.

.EXAMPLE
    # Simplest: SYSTEM, no password, elevated. Then trigger from ANY shell:
    .\Register-MiOSBuildTask.ps1
    Start-ScheduledTask -TaskName MiOS-Build

.EXAMPLE
    # Domain passwordless via gMSA:
    .\Register-MiOSBuildTask.ps1 -Principal gmsa -GmsaAccount 'CONTOSO\gMSA_Build$'
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'MiOS-Build',
    [ValidateSet('system','gmsa','user')][string]$Principal = 'system',
    [string]$GmsaAccount,
    [string]$RunUser,
    [string]$RunPassword,
    [string]$BuildScript = (Join-Path $PSScriptRoot 'Build-MiOSXboxISO.ps1'),
    [string]$BuildArgs = '',
    [switch]$Run
)
$ErrorActionPreference = 'Stop'

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: registering a RunLevel=Highest task requires an ELEVATED shell (one-time)." -ForegroundColor Red
    exit 10
}
if (-not (Test-Path $BuildScript)) { Write-Host "ERROR: build script not found: $BuildScript" -ForegroundColor Red; exit 11 }

# Action: run the build non-interactively, bypassing execution policy.
$arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}"{1}' -f $BuildScript, $(if ($BuildArgs) { " $BuildArgs" } else { '' })
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory (Split-Path $BuildScript)

# Principal: elevation is authorized HERE (at registration) -> no UAC click at launch.
switch ($Principal) {
    'gmsa' {
        if (-not $GmsaAccount) { Write-Host "ERROR: -GmsaAccount 'DOMAIN\gMSA$' required for -Principal gmsa." -ForegroundColor Red; exit 12 }
        # gMSA idiom: LogonType Password (Task Scheduler pulls the AD-managed password; none stored here).
        $prin = New-ScheduledTaskPrincipal -UserId $GmsaAccount -LogonType Password -RunLevel Highest
    }
    'user' {
        if (-not $RunUser -or -not $RunPassword) { Write-Host "ERROR: -RunUser and -RunPassword required for -Principal user." -ForegroundColor Red; exit 13 }
        $prin = New-ScheduledTaskPrincipal -UserId $RunUser -LogonType Password -RunLevel Highest
    }
    default {
        # SYSTEM: already elevated, no credential. The build needs DISM/oscdimg (not
        # WSL), so SYSTEM is fully capable -- the passwordless local default.
        $prin = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
}

# Long DISM/oscdimg run: no time limit; resilient to power state; on-demand (no trigger).
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
$task = New-ScheduledTask -Action $action -Principal $prin -Settings $settings `
    -Description 'MiOS-XBOX automated ISO build (elevated, on-demand). Trigger: Start-ScheduledTask.'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$reg = if ($Principal -eq 'user') { Register-ScheduledTask -TaskName $TaskName -InputObject $task -User $RunUser -Password $RunPassword }
       else                        { Register-ScheduledTask -TaskName $TaskName -InputObject $task }

Write-Host "[+] Registered '$TaskName' (principal=$Principal, elevated, on-demand)." -ForegroundColor Green
Write-Host "    Launch it from ANY shell (incl. a remote Windows App session), no UAC/no admin needed to TRIGGER:" -ForegroundColor DarkGray
Write-Host "      Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "    Watch:  Get-ScheduledTaskInfo -TaskName $TaskName   |  log: <WorkDir>\logs\build-*.log" -ForegroundColor DarkGray

if ($Run) { Start-ScheduledTask -TaskName $TaskName; Write-Host "[+] Triggered $TaskName." -ForegroundColor Green }
