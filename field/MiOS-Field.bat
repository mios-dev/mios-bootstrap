@echo off
:: MiOS-Field.bat -- thin WinPE/legacy-cmd shim
:: Forwards all execution to the canonical MiOS-Field.ps1 (Law 9 Parity).

setlocal

:: Check if PowerShell is available
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [FATAL] powershell.exe not found. MiOS requires PowerShell 5.1+ to run.
    exit /b 1
)

:: Forward arguments to canonical MiOS-Field.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MiOS-Field.ps1" %*
exit /b %ERRORLEVEL%
