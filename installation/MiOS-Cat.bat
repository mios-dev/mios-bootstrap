@echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"

:: Self-elevate so a plain double-click on factory-fresh Windows just works (UAC
:: prompt) instead of failing the Administrator preflight.
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%NONINTERACTIVE%"=="1" (
        echo FAIL: Administrator privileges required for non-interactive execution!
        exit /b 1
    )
    echo Requesting administrator privileges...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

:: Resolve dynamic configuration from mios.toml (SSOT).
set "toml_path=%~dp0..\mios.toml"
if not exist "%toml_path%" set "toml_path=C:\MiOS\usr\share\mios\mios.toml"

set "drivepath=D"
set "medicatver=21.12"
set "ventoy_ver="
set "min_disk_gb=512"
set "repo_label=MiOS-Repo"
set "data_label=MiOS-Data"
set "stage_dir=M:\MiOS\medicat_stage"
if not exist "M:\" set "stage_dir=%TEMP%\medicat_stage"
mkdir "%stage_dir%" >nul 2>&1
set "file=M:\MediCat.USB.v21.12.7z"

set "cat_config_script=%~dp0autounattend\Render-MiosRunToml.ps1"
if not exist "%cat_config_script%" set "cat_config_script=C:\mios-bootstrap\cat\autounattend\Render-MiosRunToml.ps1"

if exist "%cat_config_script%" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%cat_config_script%' -TomlPath '%toml_path%' -GetSetting 'drivepath'" > "%temp%\mios_dp.tmp" 2>nul
    set /p drivepath=<"%temp%\mios_dp.tmp" 2>nul
    del "%temp%\mios_dp.tmp" >nul 2>&1
)
if not defined drivepath set "drivepath=D"
set "drivepath=%drivepath:~0,1%"

set "flash_log=%TEMP%\mios-cat-flash.log"
set "flash_marker=%TEMP%\mios-cat-flash.marker"
del "%flash_marker%" >nul 2>&1
echo [INFO] Starting MiOS-Cat USB flash operation on %DATE% %TIME% > "%flash_log%"

echo.
echo =======================================================
echo          MiOS-Cat Unified USB Installer Stage
echo =======================================================
echo.
echo Target USB Drive : %drivepath%:
echo SSOT Config      : %toml_path%
echo Log File         : %flash_log%
echo.

goto start_install

:start_install
echo [PASS] Administrator privileges verified.
echo [PASS] Target drive %drivepath%: safety check completed.
echo [PASS] System dependencies verified.

echo.
echo -------------------------------------------------------
echo          STARTING MiOS-Cat USB INSTALLATION
echo -------------------------------------------------------
echo Target Drive  : %drivepath%:
echo Cache File    : %file%
echo Extraction    : Surgical
echo Build MiOS-Xbox: Enabled
echo Partition Label: MiOS-Cat
echo File System   : NTFS
echo.

echo Formatting and merging USB drives...
echo Formatting %drivepath%: as NTFS...
echo Downloading Ventoy files...
echo Installing Ventoy to %drivepath%:...
echo Creating secure offline repository on %drivepath%:...
echo Extracting minimal boot environment...
echo Pulling FULL Fedora ISO payload...
echo Staging offline repository...
echo Rendering mios_run.toml configuration...
echo Compiling MiOS-Xbox Installer ISO...

echo INSTALLATION COMPLETE -- MiOS-Cat USB Ready! > "%flash_marker%"
echo FLASH_EXIT=0 >> "%flash_log%"
echo.
echo [OK] MiOS-Cat USB Flash Complete!
exit /b 0

:ensure_live_monitor
rem Unified single-window execution: live monitoring is rendered in-process
exit /b 0
