@echo off
rem ============================================================================
rem  MiOS-XBOX first-logon FALLBACK
rem  Baked into install.wim at \Windows\Setup\Scripts\mios-firstlogon.cmd and run
rem  by the "MiOS-FirstLogon" ONLOGON task that the SPECIALIZE pass registers
rem  (New-MiOSHostServiceCommands). SetupComplete.cmd already applies identity +
rem  remote-access as SYSTEM pre-logon -- but Win11 26xxx has been observed to skip
rem  SetupComplete under some unattended OOBE flows, which would leave the desktop
rem  un-themed and enhanced-session locked out. The specialize pass is PROVEN to run
rem  (it registers mios-svc + MiOS-Host + RDP), so an ONLOGON task it schedules is
rem  the reliable safety net: it re-applies identity + remote in the REAL user's
rem  session (correct HKCU), exactly once, then deletes itself. Idempotent with
rem  SetupComplete -- both call the same marker-safe cmds.
rem ============================================================================
set "M=%ProgramData%\MiOS\firstlogon.done"
if exist "%M%" ( schtasks /delete /tn "MiOS-FirstLogon" /f >nul 2>&1 & exit /b 0 )
md "%ProgramData%\MiOS" 2>nul
set "L=%WINDIR%\Temp\mios-firstlogon.log"
echo [MiOS] first-logon fallback %DATE% %TIME%>>"%L%"
rem %~dp0 = C:\Windows\Setup\Scripts\ (the task runs this cmd by full path)
if exist "%~dp0mios-identity.cmd" ( call "%~dp0mios-identity.cmd">>"%L%" 2>&1 ) else ( echo [MiOS] WARN mios-identity.cmd missing>>"%L%" )
if exist "%~dp0mios-remote.cmd"   ( call "%~dp0mios-remote.cmd">>"%L%" 2>&1 )   else ( echo [MiOS] WARN mios-remote.cmd missing>>"%L%" )
rem refresh the session so the MiOS wallpaper/palette/cursor take effect immediately
RUNDLL32.EXE USER32.DLL,UpdatePerUserSystemParameters ,1 ,True
echo done>"%M%"
echo [MiOS] first-logon fallback done %DATE% %TIME%>>"%L%"
schtasks /delete /tn "MiOS-FirstLogon" /f >nul 2>&1
exit /b 0
