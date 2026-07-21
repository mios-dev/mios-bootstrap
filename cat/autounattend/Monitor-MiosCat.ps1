<#
.SYNOPSIS
    MiOS Dedicated Live SSOT-Driven Build & Flash Monitor Wrapper
    Delegates to Python Rich Cross-Platform TUI (mios_monitor.py).
#>
param(
    [string]$LogPath,
    [string]$TomlPath
)

$pyScript = Join-Path $PSScriptRoot 'mios_monitor.py'
if (-not (Test-Path $pyScript)) {
    $pyScript = 'C:\mios-bootstrap\cat\autounattend\mios_monitor.py'
}

if (Get-Command python.exe -ErrorAction SilentlyContinue) {
    & python.exe "$pyScript"
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
    & python3 "$pyScript"
} else {
    Write-Error "Python 3 is required to run the cross-platform MiOS TUI monitor."
}
