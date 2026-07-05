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

rem --- GAMING DEBLOAT: strip stock Win11 apps BEFORE first logon (the Linux UUP
rem     build produces a stock image; only the DISM path strips offline). Three
rem     parts: (1) policy off "Consumer Features" so the promoted/suggested apps
rem     (WhatsApp, LinkedIn, Spotify, Solitaire, Prime Video, ...) NEVER download
rem     or pin; (2) turn Content Delivery Manager suggestions off in the default
rem     user hive so new users inherit a clean Start; (3) remove the provisioned
rem     appx, keeping only the Xbox/gaming stack, Store, Game Bar, media
rem     extensions, and framework runtimes. Runs as SYSTEM; failures non-fatal.
rem     TODO(SSOT): drive the keep-list from mios.toml [autounattend.xbox.keep_appx].
echo [MiOS] debloat start %DATE% %TIME%>>"%LOG%"
rem (1) kill Consumer Features (the promoted-app pump) machine-wide
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
rem (2) Content Delivery Manager off for every future user (default hive)
reg load "HKU\MiOSDef" "%SystemDrive%\Users\Default\NTUSER.DAT" >>"%LOG%" 2>&1
for %%K in (SilentInstalledAppsEnabled PreInstalledAppsEnabled OemPreInstalledAppsEnabled SubscribedContentEnabled ContentDeliveryAllowed SystemPaneSuggestionsEnabled "SubscribedContent-338388Enabled" "SubscribedContent-338389Enabled" "SubscribedContent-310093Enabled" "SubscribedContent-314559Enabled") do reg add "HKU\MiOSDef\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v %%K /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg unload "HKU\MiOSDef" >>"%LOG%" 2>&1
rem (3) remove appx per the SSOT list generated from the NTLite preset <c> entries
rem     (mios-remove-appx.txt, baked next to this script). Exact case-insensitive
rem     DisplayName/Name match, so non-appx tokens are safe no-ops. This is the
rem     DISM appx strip (Remove-AppxProvisionedPackage) driven by your preset XMLs.
set "RMLIST=%~dp0mios-remove-appx.txt"
if exist "%RMLIST%" powershell -NoProfile -ExecutionPolicy Bypass -Command "$set=@{}; Get-Content -LiteralPath '%RMLIST%' | ForEach-Object { $t=$_.Trim(); if ($t -and $t[0] -ne '#') { $set[$t.ToLower()]=$true } }; Get-AppxProvisionedPackage -Online | Where-Object { $set.ContainsKey(($_.DisplayName).ToLower()) } | ForEach-Object { try { Remove-AppxProvisionedPackage -Online -AllUsers -PackageName $_.PackageName -EA Stop } catch {} }; Get-AppxPackage -AllUsers | Where-Object { $set.ContainsKey(($_.Name).ToLower()) } | ForEach-Object { try { Remove-AppxPackage -AllUsers -Package $_.PackageFullName -EA Stop } catch {} }" >>"%LOG%" 2>&1
echo [MiOS] debloat done %DATE% %TIME%>>"%LOG%"

rem --- First-boot bootstrap runner. Placed in the All-Users Startup folder so
rem     the shell runs it at the first interactive logon (network + user session,
rem     VISIBLE) -- Startup is reliable here where RunOnce is not. It drops a
rem     marker (proof it fired), runs the MiOS bootstrap, then removes itself so
rem     it runs exactly once. A duplicate ONLOGON scheduled task is registered as
rem     a belt-and-suspenders fallback. No nested quotes / no spaces in paths that
rem     would trip the unattend validator -- this is a plain .cmd on disk. --------
set "STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "R=%STARTUP%\mios-firstboot.cmd"
>"%R%"  echo @echo off
>>"%R%" echo echo fired %%DATE%% %%TIME%%^> "%ProgramData%\MiOS\firstboot.marker"
>>"%R%" echo powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1' | iex"
>>"%R%" echo del /f /q "%%~f0"
echo [MiOS] placed startup launcher %R%>>"%LOG%"

schtasks /create /tn MiOS-FirstBoot /sc ONLOGON /rl HIGHEST /ru SYSTEM /tr "%R%" /f >>"%LOG%" 2>&1

echo [MiOS] SetupComplete done %DATE% %TIME%>>"%LOG%"
exit /b 0
