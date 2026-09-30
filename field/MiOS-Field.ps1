# MiOS-Field.ps1 -- canonical Windows launcher for MiOS.
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
$libPath = Join-Path $PSScriptRoot "lib\MiOS-Field.psm1"
if (-not (Test-Path -LiteralPath $libPath)) {
    Write-Error "Backend library not found at $libPath"
    exit 1
}
Import-Module $libPath -Force

$Verb = if ($passArgs.Count -ge 1) { [string]$passArgs[0] } else { "" }
$VerbArgs = if ($passArgs.Count -gt 1) { $passArgs[1..($passArgs.Count - 1)] } else { @() }

if ([string]::IsNullOrWhiteSpace($Verb)) {
    # Default behavior: interactive menu
    Show-MiOSFieldMenu
    exit $LASTEXITCODE
}

switch -Regex ($Verb) {
    "^(flash|live)$" {
        $installer = Join-Path $PSScriptRoot '..\installation\mios-install.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
            throw "MiOS installer not found: $installer"
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Target $Verb @VerbArgs
    }
    "^(stage)$" {
        Invoke-MiOSFieldStage @VerbArgs
    }
    "^(install)$" {
        Invoke-MiOSFieldInstall @VerbArgs
    }
    "^(wsl|import)$" {
        $importArgs = @('-Target', $Verb) + $VerbArgs
        Invoke-MiOSFieldInstall @importArgs
    }
    "^(build)$" {
        Invoke-MiOSFieldBuild @VerbArgs
    }
    "^(update)$" {
        Invoke-MiOSFieldUpdate @VerbArgs
    }
    "^(provision)$" {
        Invoke-MiOSFieldProvision @VerbArgs
    }
    "^(verify)$" {
        Invoke-MiOSFieldVerify @VerbArgs
    }
    "^(manual)$" {
        Invoke-MiOSFieldManual @VerbArgs
    }
    default {
        Write-Error "Unknown verb: $Verb. Valid verbs: flash, live, stage, install, build, update, provision, verify, manual, wsl, import."
        exit 1
    }
}
exit $LASTEXITCODE
