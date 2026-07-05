@echo off
rem ============================================================================
rem  MiOS first-logon bootstrap launcher.
rem  Baked into install.wim beside SetupComplete.cmd; SetupComplete copies it into
rem  the All-Users Startup folder. It runs at the FIRST interactive logon as the
rem  auto-logon 'mios' user -- the CORRECT context for Get-MiOS: two-pass UAC self-
rem  elevation + a WSL distro import, neither of which can run as SYSTEM
rem  (microsoft/WSL#11280). That is why there is NO ONLOGON /ru SYSTEM task.
rem
rem  Idempotent + single-owner so it NEVER re-triggers Get-MiOS's destructive full
rem  reset: firstboot.done => already succeeded (clean up and stop); firstboot.lock
rem  => an install is in flight (a second logon no-ops). On a crash before .done is
rem  written, the next logon resumes rather than skips.
rem ============================================================================
set "S=%ProgramData%\MiOS"
if not exist "%S%" md "%S%" 2>nul
if exist "%S%\firstboot.done" goto :cleanup
if exist "%S%\firstboot.lock" exit /b 0
>"%S%\firstboot.lock"   echo locked %DATE% %TIME%
>"%S%\firstboot.marker" echo fired %DATE% %TIME%
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1' | iex"
if %ERRORLEVEL%==0 (>"%S%\firstboot.done" echo done %DATE% %TIME%)
del /f /q "%S%\firstboot.lock" 2>nul
if not exist "%S%\firstboot.done" exit /b 0
:cleanup
del /f /q "%~f0" 2>nul
exit /b 0
