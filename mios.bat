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
::    Paste, hit Enter, that's it. (UAC prompt at the same point as
::    mios.bat below, since the elevation logic lives in Get-MiOS.ps1.)
::
:: Both paths fetch Get-MiOS.ps1 via irm|iex which:
::   * SELF-ELEVATES (UAC prompt) -- needed to shrink C:\ + create M:\
::   * provisions M:\ at exactly 256 GB (NTFS, label MIOS-DEV)
::   * winget-installs Podman Desktop if not already present
::   * provisions the podman-MiOS-DEV machine on M:\
::   * installs WT MiOS profile + Geist + oh-my-posh + fastfetch
::   * stages mios-build / mios-config / mios-dev / mios-help functions
::   * registers MiOS as a native Windows app (Start Menu + Add/Remove)
::     with a multi-size .ico matching the isometric MiOS ASCII art
::   * auto-chains into MiOS-DEV and runs mios-build-driver
::
:: Self-elevation lives here in mios.bat (rather than in Get-MiOS.ps1)
:: because once we're inside `irm|iex` the script is a string in pwsh
:: memory -- there's no .ps1 file to relaunch with -Verb RunAs. Doing
:: it in mios.bat means double-click handles UAC up front, then the
:: elevated child fetches+iex's Get-MiOS.ps1 with admin already in hand.

setlocal
set "MIOS_URL=https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1"

:: Self-elevate. `net session` returns 0 only when we have admin. If not
:: admin, relaunch this same .bat via Start-Process -Verb RunAs (which
:: triggers the UAC consent dialog), then exit the non-admin instance.
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [mios] requesting administrator rights ^(needed to provision M:\^) ...
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Prefer pwsh 7+ if available; fall back to Windows PowerShell 5.1.
where /q pwsh.exe
if %ERRORLEVEL%==0 (
    set "MIOS_PWSH=pwsh.exe"
) else (
    set "MIOS_PWSH=powershell.exe"
)

%MIOS_PWSH% -NoLogo -ExecutionPolicy Bypass -Command "irm '%MIOS_URL%' | iex"
endlocal

:: The elevated console is a fresh window spawned by Start-Process. If
:: we let it close immediately the operator never sees the bootstrap
:: result. Pause so they can read + press a key to dismiss.
echo.
pause
