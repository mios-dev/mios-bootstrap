@echo off
rem ============================================================================
rem  MiOS-XBOX SetupComplete.cmd
rem  Baked into install.wim at \Windows\Setup\Scripts\SetupComplete.cmd.
rem  Windows Setup runs this as SYSTEM at the END of setup (after specialize,
rem  before first logon) -- GUARANTEED and failure-tolerant, unlike the
rem  FirstLogonCommands/RunOnce path which Win11 26xxx silently skips under our
rem  unattended OOBE config. This is the reliable trigger that makes MiOS
rem  actually install on first boot.
rem ============================================================================
set "LOG=%WINDIR%\Temp\mios-setupcomplete.log"
echo [MiOS] SetupComplete start %DATE% %TIME%>>"%LOG%"

rem --- Linux-like FS layout (was FirstLogonCommands; do it reliably here) ------
for %%D in (etc usr home opt srv var bin lib root tmp) do md "%SystemDrive%\%%D" 2>nul
md "%ProgramData%\MiOS" 2>nul

rem --- Write the first-boot runner (space-free path, no nested quotes in the
rem     scheduled-task /tr, which is what the unattend validator chokes on) ----
set "R=%ProgramData%\MiOS\run-bootstrap.cmd"
>"%R%" echo @echo off
>>"%R%" echo powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1' | iex"
>>"%R%" echo schtasks /delete /tn MiOS-FirstBoot /f

rem --- Run the MiOS bootstrap at the first interactive logon (network + user
rem     session guaranteed). Task Scheduler ONLOGON is reliable here (RunOnce is
rem     not). The runner self-deletes the task after the bootstrap completes. ---
schtasks /create /tn MiOS-FirstBoot /sc ONLOGON /rl HIGHEST /ru SYSTEM /tr "%R%" /f >>"%LOG%" 2>&1

echo [MiOS] registered MiOS-FirstBoot -^> %R%>>"%LOG%"
echo [MiOS] SetupComplete done %DATE% %TIME%>>"%LOG%"
exit /b 0
