@echo off
title MiOS-Xbox Builder Launcher
cd /d %~dp0

echo ==========================================================
echo           MiOS-Xbox ISO/Image Builder Launcher            
echo ==========================================================
echo.

:: Check Admin
net session >nul 2>&1 || (
    echo [INFO] Requesting administrator elevation...
    powershell -Command "Start-Process -FilePath '%0' -Verb RunAs"
    exit /b
)

:: Sourced SSOT colors / branding info
echo Resolving configurations from MiOS SSOT...
set "TOM_PATH=C:\mios-bootstrap\mios.toml"
if not exist "%TOM_PATH%" (
    echo.
    echo [INFO] Sourced SSOT not found at C:\mios-bootstrap\mios.toml
    echo Pulling MiOS bootstrap live from GitHub...
    powershell -Command "Invoke-WebRequest -Uri 'https://github.com/mios-dev/mios-bootstrap/archive/refs/heads/main.zip' -OutFile 'mios-bootstrap.zip'"
    powershell -Command "Expand-Archive -Path 'mios-bootstrap.zip' -DestinationPath 'C:\' -Force"
    move "C:\mios-bootstrap-main" "C:\mios-bootstrap" >nul 2>&1
    del mios-bootstrap.zip /Q
)

if exist "%TOM_PATH%" (
    echo [OK] MiOS SSOT verified.
) else (
    echo [ERROR] Failed to fetch MiOS bootstrap.
    pause
    exit /b 1
)

echo.
echo Running the Build Pipeline for MiOS-Xbox ISO/Images...
echo ==========================================================
powershell -ExecutionPolicy Bypass -File "C:\mios-bootstrap\src\autounattend\Build-MiOSXboxISO.ps1"
echo.
echo Build execution completed.
pause
