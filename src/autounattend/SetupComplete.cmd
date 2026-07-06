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

rem --- MiOS FACTORY IDENTITY (per-user defaults): apply the MiOS palette + Bibata
rem     cursor + wallpaper to the DEFAULT user hive LIVE. Live Default-hive editing is
rem     SAFE (real registry, proper transactions) -- unlike OFFLINE WIM hive editing,
rem     which corrupts the profile. Every account inherits this at first logon, so the
rem     desktop is MiOS-themed with NO script and NO UAC. mios-theme-default.reg is
rem     rendered from SSOT ([colors].accent, cursor, wallpaper) + baked beside this. --
echo [MiOS] applying MiOS identity via your New-MiOSProvisionCommands %DATE% %TIME%>>"%LOG%"
if exist "%~dp0mios-identity.cmd" (
    call "%~dp0mios-identity.cmd">>"%LOG%" 2>&1
) else ( echo [MiOS] WARN mios-identity.cmd missing beside SetupComplete>>"%LOG%" )

rem --- Start the MiOS brain deploy NOW (end of setup, BEFORE first logon). The
rem     specialize pass registered MiOS-Host as mios-svc (a LOCAL ADMIN, run level
rem     HIGHEST). Running it here launches the WSL2 + agent-stack install in Session 0
rem     -- HIDDEN, ELEVATED, NO UAC, NO visible console (WSL cannot run as SYSTEM, so
rem     mios-svc is the account; being admin means Get-MiOS runs already-elevated and
rem     never prompts). There is deliberately NO interactive Startup launcher. --------
echo [MiOS] starting pre-logon MiOS-Host (Session 0, hidden) %DATE% %TIME%>>"%LOG%"
schtasks /run /tn "MiOS-Host">>"%LOG%" 2>&1

echo [MiOS] SetupComplete done %DATE% %TIME%>>"%LOG%"
exit /b 0
