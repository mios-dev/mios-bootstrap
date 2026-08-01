# MiOS-Cat.ps1 -- canonical Windows launcher for MiOS.
# Implements Law 9 (ONE-CANONICAL-NAME). Dispatches verbs.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Verb = "",
    
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$VerbArgs
)

$ErrorActionPreference = "Stop"

# Self-elevate if not admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching with Administrator privileges..." -ForegroundColor Yellow
    $relaunch = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", $Verb) + $VerbArgs
    Start-Process powershell.exe -ArgumentList $relaunch -Verb RunAs
    exit
}

# Import the shared library
$libPath = Join-Path $PSScriptRoot "lib\MiOS-Cat.psm1"
if (-not (Test-Path $libPath)) {
    Write-Error "Backend library not found at $libPath"
    exit 1
}
Import-Module $libPath -Force

if ([string]::IsNullOrWhiteSpace($Verb)) {
    # Default behavior: interactive menu
    Show-MiOSCatMenu
    exit $LASTEXITCODE
}

switch -Regex ($Verb) {
    "^(stage)$" {
        Invoke-MiOSCatStage @VerbArgs
    }
    "^(install)$" {
        Invoke-MiOSCatInstall @VerbArgs
    }
    "^(build)$" {
        Invoke-MiOSCatBuild @VerbArgs
    }
    "^(update)$" {
        Invoke-MiOSCatUpdate @VerbArgs
    }
    "^(provision)$" {
        Invoke-MiOSCatProvision @VerbArgs
    }
    "^(manual)$" {
        Invoke-MiOSCatManual @VerbArgs
    }
    default {
        Write-Error "Unknown verb: $Verb. Valid verbs: stage, install, build, update, provision, manual."
        exit 1
    }
}
exit $LASTEXITCODE
