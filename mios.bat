@echo off
:: mios.bat -- AIO entry. ONE window after UAC.
::
:: Two ways to invoke this:
::
::   1. Download + double-click mios.bat
::   2. Win+R and paste the equivalent powershell one-liner:
::        powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
::
:: Flow design (no intermediate flicker):
::   * Already admin: run `pwsh -Command "irm|iex"` IN-PLACE in the
::     current cmd window. No new window spawned, no UAC prompt. The
::     bootstrap runs, the window stays open via `pause`.
::   * Not admin: a HIDDEN-style powershell shim does Start-Process
::     -Verb RunAs of pwsh DIRECTLY (skipping the elevated-cmd hop),
::     so UAC pops once and lands the operator in ONE elevated pwsh
::     window with the bootstrap already running. The original
::     non-admin cmd exits immediately. The hidden shim doesn't paint
::     a window between the click and UAC.
::
:: After UAC the elevated pwsh runs:
::   irm Get-MiOS.ps1 | iex
:: Get-MiOS.ps1 detects $isAdmin=true (we just elevated) and skips its
:: own self-elevation block, so this is the ONLY UAC prompt and the
:: ONLY new window the operator sees. Steps 1-7 + M:\ provisioning +
:: Podman Desktop install + dev VM provision + native app + ICO + auto-
:: chain into mios-build-driver all happen in this single window.

setlocal
set "MIOS_URL=https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1"

:: Resolve pwsh: prefer 7+ MSI install; fall back to Windows PowerShell 5.1.
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    set "MIOS_PWSH=pwsh.exe"
) else (
    set "MIOS_PWSH=powershell.exe"
)

net session >nul 2>&1
if %ERRORLEVEL%==0 (
    :: Already admin -- run IN-PLACE (no spawn, no new window).
    %MIOS_PWSH% -NoLogo -ExecutionPolicy Bypass -Command "irm '%MIOS_URL%' | iex"
    echo.
    pause
    exit /b
)

:: Non-admin -- spawn ONE elevated pwsh window directly via UAC.
:: -WindowStyle Hidden hides the launching powershell shim so the
:: operator sees: their double-click, then UAC, then the bootstrap
:: window. No intermediate cmd, no visible powershell flicker.
:: -NoExit on the elevated pwsh keeps the bootstrap window open after
:: the script finishes so the operator can read the result.
powershell -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "Start-Process '%MIOS_PWSH%' -Verb RunAs -ArgumentList @('-NoLogo','-NoExit','-ExecutionPolicy','Bypass','-Command','irm ''%MIOS_URL%'' | iex')"
endlocal
