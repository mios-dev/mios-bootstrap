# MiOS-Cat.ps1 -- thin compatibility shim (Windows).
#
# The canonical Windows implementation is MiOS-Cat.bat. On a factory-fresh
# Windows box the .bat is the most compatible handle: cmd.exe is always present,
# it is double-clickable, there is no PowerShell execution-policy gate, and
# Get-MiOS FlashUSB / the scheduled task / Ventoy autorun all reference
# MiOS-Cat.bat BY NAME. This .ps1 exists only so `powershell -File MiOS-Cat.ps1
# <verb>` reaches the SAME flow -- it self-elevates and forwards every argument
# to MiOS-Cat.bat. (Decision 2026-07-17: keep .bat canonical. Written for
# Windows PowerShell 5.1 -- the version present on factory-fresh Windows -- with
# NO pwsh-7 dependency, so `powershell.exe` runs it unchanged.)

$ErrorActionPreference = "Stop"

# Self-elevate (the .bat preflight requires Administrator; the .bat also
# self-elevates now, but doing it here avoids a doubled UAC bounce).
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching with Administrator privileges..." -ForegroundColor Yellow
    $relaunch = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $args
    Start-Process powershell.exe -ArgumentList $relaunch -Verb RunAs
    exit
}

$bat = Join-Path $PSScriptRoot "MiOS-Cat.bat"
if (-not (Test-Path $bat)) {
    Write-Error "MiOS-Cat.bat not found beside this shim ($bat) -- cannot forward."
    exit 1
}

# Forward all args to the canonical launcher and mirror its exit code.
& $bat @args
exit $LASTEXITCODE
