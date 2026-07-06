@echo off
rem MiOS first-logon launcher -- baked into the All-Users Startup folder. Launches the
rem hidden MiOS-FirstBoot.ps1 (brain + Gaming deploy) in the desktop user's session, then
rem MiOS-FirstBoot.ps1 removes this shortcut once fired. One-time; a sub-second flash.
start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ProgramData%\MiOS\MiOS-FirstBoot.ps1"
exit /b 0
