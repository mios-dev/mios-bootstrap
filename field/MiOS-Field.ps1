# MiOS-Cat.ps1 -- canonical Windows launcher for MiOS.
# Implements Law 9 (ONE-CANONICAL-NAME). Dispatches verbs.

$ErrorActionPreference = "Stop"

# Check for -NoElevate in args
$noElevate = ($args -contains "-NoElevate")
$passArgs = @($args | Where-Object { $_ -ne "-NoElevate" })

if (-not $noElevate) {
    # Self-elevate if not admin
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Re-launching with Administrator privileges..." -ForegroundColor Yellow
        $relaunch = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $args
        Start-Process powershell.exe -ArgumentList $relaunch -Verb RunAs
        exit
    }
}

# Import the shared library
$libPath = Join-Path $PSScriptRoot "lib\MiOS-Cat.psm1"
if (-not (Test-Path -LiteralPath $libPath)) {
    Write-Error "Backend library not found at $libPath"
    exit 1
}
Import-Module $libPath -Force

$Verb = if ($passArgs.Count -ge 1) { [string]$passArgs[0] } else { "" }
$VerbArgs = if ($passArgs.Count -gt 1) { $passArgs[1..($passArgs.Count - 1)] } else { @() }

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
    "^(wsl|import)$" {
        $importArgs = @('-Target', $Verb) + $VerbArgs
        Invoke-MiOSCatInstall @importArgs
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
    "^(verify)$" {
        Invoke-MiOSCatVerify @VerbArgs
    }
    "^(manual)$" {
        Invoke-MiOSCatManual @VerbArgs
    }
    default {
        Write-Error "Unknown verb: $Verb. Valid verbs: stage, install, build, update, provision, verify, manual, wsl, import."
        exit 1
    }
}
exit $LASTEXITCODE
