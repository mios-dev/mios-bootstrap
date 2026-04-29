if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  Run as Administrator!' -ForegroundColor Red
    return
}
<#
.SYNOPSIS
    MiOS Preflight -- Check and install prerequisites
.DESCRIPTION
    Usage: $tmp = "$env:TEMP\mios-preflight.ps1"; irm https://raw.githubusercontent.com/Kabuki94/mios/main/preflight.ps1 | Set-Content $tmp; & $tmp; Remove-Item $tmp
#>
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "+==============================================================+" -ForegroundColor Cyan
Write-Host "|  MiOS Preflight -- Prerequisites Check                    |" -ForegroundColor Cyan
Write-Host "+==============================================================+" -ForegroundColor Cyan
Write-Host ""

$pass = 0
$fail = 0
$fixed = 0

function Check($name, $test, $fix) {
    Write-Host "  [$name] " -NoNewline
    if (& $test) {
        Write-Host "[OK]" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "[MISSING]" -ForegroundColor Red
        $script:fail++
        if ($fix) {
            $doFix = Read-Host "    Install $name? (y/n)"
            if ($doFix -eq 'y') {
                & $fix
                $script:fixed++
            }
        }
    }
}

Write-Host "--- System ---" -ForegroundColor Yellow
Check "Windows 10/11 Pro+" {
    (Get-CimInstance Win32_OperatingSystem).Caption -match "Pro|Enterprise|Education"
} $null

Write-Host ""
Write-Host "--- WSL2 ---" -ForegroundColor Yellow
Check "WSL2 Feature" {
    (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State -eq 'Enabled'
} {
    Write-Host "    Enabling WSL..." -ForegroundColor Cyan
    wsl --install --no-distribution
    Write-Host "    [WARN] Reboot required after WSL install" -ForegroundColor Yellow
}
Check "Virtual Machine Platform" {
    (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State -eq 'Enabled'
} {
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
}

Write-Host ""
Write-Host "--- Hyper-V (optional) ---" -ForegroundColor Yellow
Check "Hyper-V" {
    (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled'
} {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
    Write-Host "    [WARN] Reboot required" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- PowerShell ---" -ForegroundColor Yellow
Check "PowerShell 7+" {
    $PSVersionTable.PSVersion.Major -ge 7
} {
    Write-Host "    Installing PowerShell 7+ via winget..." -ForegroundColor Cyan
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
    Write-Host "    [WARN] Restart terminal after PS7 install, then re-run preflight" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- Software ---" -ForegroundColor Yellow
Check "Git" {
    Get-Command git -ErrorAction SilentlyContinue
} {
    winget install --id Git.Git --accept-source-agreements --accept-package-agreements
}
Check "Podman" {
    Get-Command podman -ErrorAction SilentlyContinue
} {
    winget install --id RedHat.Podman --accept-source-agreements --accept-package-agreements
}
Check "Podman Desktop" {
    (Get-Command "podman-desktop" -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA\Programs\Podman Desktop")
} {
    winget install --id RedHat.Podman-Desktop --accept-source-agreements --accept-package-agreements
}

Write-Host ""
Write-Host "--- Results ---" -ForegroundColor Cyan
Write-Host "  Passed: $pass  Failed: $fail  Fixed: $fixed" -ForegroundColor White
if ($fail -eq 0 -or $fail -eq $fixed) {
    Write-Host "  [OK] Ready to build MiOS!" -ForegroundColor Green
    Write-Host "    Run: `$tmp = `"`$env:TEMP\mios-install.ps1`"; irm https://raw.githubusercontent.com/Kabuki94/mios/main/install.ps1 | Set-Content `$tmp; & `$tmp; Remove-Item `$tmp" -ForegroundColor Gray
} else {
    Write-Host "  [WARN] Some prerequisites missing. Fix them and re-run." -ForegroundColor Yellow
}
Write-Host ""