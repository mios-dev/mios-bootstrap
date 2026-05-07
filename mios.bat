@echo off
:: mios.bat -- Win+R-friendly MiOS bootstrap launcher.
::
:: Two ways to invoke this:
::
:: 1. Download + double-click mios.bat
::    Drop this file anywhere on disk and run it directly.
::
:: 2. Win+R one-liner (no download needed):
::      powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
::    Paste, hit Enter, that's it.
::
:: Both paths fetch Get-MiOS.ps1 via irm|iex which:
::   * acks the agreement gate
::   * provisions M:\ + mios.git overlay
::   * installs WT MiOS profile + Geist + oh-my-posh + fastfetch
::   * stages mios-build / mios-config / mios-dev / mios-help functions
::   * registers MiOS as a native Windows app (Start Menu + Add/Remove)
::
:: Operator runs `mios-build` from any MiOS terminal afterwards to
:: trigger the full OCI image build inside MiOS-DEV.

setlocal
set "MIOS_URL=https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1"

:: Prefer pwsh 7+ if available; fall back to Windows PowerShell 5.1.
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    set "MIOS_PWSH=pwsh.exe"
) else (
    set "MIOS_PWSH=powershell.exe"
)

%MIOS_PWSH% -NoLogo -ExecutionPolicy Bypass -Command "irm '%MIOS_URL%' | iex"
endlocal
