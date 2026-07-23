<#
.SYNOPSIS
  MiOS-Monitor -- The shim for the new unified Python TUI.
  Bootstraps the 'rich' library and invokes MiOS-Mon.py.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dash','Flash','Mini','Full','Applet','Grab','Log','Services','Tui')]
    [string]$Mode = 'Dash',
    [string]$LogPath = '',
    [string]$MarkerPath = '',
    [switch]$Once,
    [int]$IntervalMs = 150,
    [switch]$Grab,
    [switch]$Pop,
    [string]$TargetHint = 'mios-install'
)

$ErrorActionPreference = 'Stop'

# Ensure Python is available
if (-not (Get-Command "python" -ErrorAction SilentlyContinue)) {
    Write-Host "FATAL: Python is required for the new unified MiOS-Mon TUI." -ForegroundColor Red
    exit 1
}

# Ensure Rich is installed
$richInstalled = $false
try {
    $null = & python -c "import rich" 2>$null
    if ($LASTEXITCODE -eq 0) { $richInstalled = $true }
} catch {}

if (-not $richInstalled) {
    Write-Host "Bootstrapping required python TUI library 'rich'..." -ForegroundColor Yellow
    & python -m pip install rich --user --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FATAL: Failed to install 'rich'." -ForegroundColor Red
        exit 1
    }
}

$scriptPath = 'C:\MiOS\usr\libexec\mios\MiOS-Mon.py'
if (-not (Test-Path $scriptPath)) {
    # Try local dir if running from repo
    $scriptPath = Join-Path $PSScriptRoot 'MiOS-Mon.py'
}

if (-not (Test-Path $scriptPath)) {
    Write-Host "FATAL: Unified python monitor not found at $scriptPath" -ForegroundColor Red
    exit 1
}

$argsList = @()
if ($Once) { $argsList += '--once' }

switch ($Mode) {
    'Dash' { $argsList += '--dash' }
    'Mini' { $argsList += '--mini' }
    default { $argsList += '--monitor' }
}

if ($Mode -notin 'Dash', 'Mini' -and -not $Once) {
    $argsList += '--monitor'
}

& python $scriptPath $argsList
exit $LASTEXITCODE
