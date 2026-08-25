@echo off
:: MiOS-Cat.bat -- thin WinPE/legacy-cmd shim
:: Forwards all execution to the canonical MiOS-Cat.ps1 (Law 9 Parity).

setlocal

:: Check if PowerShell is available
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [FATAL] powershell.exe not found. MiOS requires PowerShell 5.1+ to run.
    exit /b 1
)

:: Forward arguments to canonical MiOS-Cat.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MiOS-Cat.ps1" %*
exit /b %ERRORLEVEL%
