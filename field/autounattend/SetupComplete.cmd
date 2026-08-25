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

rem --- PRE-CREATE SYSTEMPROFILE DESKTOP DIRS: prevent "systemprofile\desktop is not accessible" modal (T-280) ---
echo [MiOS] pre-creating systemprofile desktop directories %DATE% %TIME%>>"%LOG%"
mkdir "%WINDIR%\System32\config\systemprofile\Desktop" >nul 2>&1
mkdir "%WINDIR%\SysWOW64\config\systemprofile\Desktop" >nul 2>&1

rem --- NATIVE BITLOCKER DISABLE: prevent Win11 24H2 automatic drive encryption ---
echo [MiOS] disabling BitLocker automatic encryption %DATE% %TIME%>>"%LOG%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\FVE" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
manage-bde.exe -off C: >>"%LOG%" 2>&1
powershell.exe -NoProfile -Command "try { Get-BitLockerVolume | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' } | Disable-BitLocker -ErrorAction SilentlyContinue } catch {}" >>"%LOG%" 2>&1

rem --- COMPACT OS: enforce CompactOS LZX/XPRESS WOF OS compression ---
echo [MiOS] enabling CompactOS OS compression %DATE% %TIME%>>"%LOG%"
compact.exe /CompactOS:always >>"%LOG%" 2>&1

rem --- GLOBAL PORTABLE APPS & SDIO STAGING: install PortableApps + SDIO machine-wide ---
echo [MiOS] staging global PortableApps & Snappy Driver Installer Origin %DATE% %TIME%>>"%LOG%"
set "PORTSRC="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\PortableApps" set "PORTSRC=%%D:\PortableApps"
)
if defined PORTSRC (
    echo [MiOS] found PortableApps source at %PORTSRC% >>"%LOG%"
    mkdir "%SystemDrive%\PortableApps" >nul 2>&1
    robocopy "%PORTSRC%" "%SystemDrive%\PortableApps" /E /R:2 /W:2 >>"%LOG%" 2>&1
) else (
    echo [MiOS] WARN: PortableApps source not found on optical/USB drive >>"%LOG%"
)

rem --- Ensure SDIO (Snappy Driver Installer Origin) config & drivers directory ---
if exist "%SystemDrive%\PortableApps\SnappyDriverInstallerOrigin" (
    mkdir "%SystemDrive%\PortableApps\SnappyDriverInstallerOrigin\drivers" >nul 2>&1
    (
        echo [disable]
        echo update=1
        echo [window]
        echo theme=Metallic
        echo [drp]
        echo path=drivers
    ) > "%SystemDrive%\PortableApps\SnappyDriverInstallerOrigin\sdi.cfg" 2>nul
)
if exist "%SystemDrive%\PortableApps\SDIO" (
    mkdir "%SystemDrive%\PortableApps\SDIO\drivers" >nul 2>&1
    (
        echo [disable]
        echo update=1
        echo [window]
        echo theme=Metallic
        echo [drp]
        echo path=drivers
    ) > "%SystemDrive%\PortableApps\SDIO\sdi.cfg" 2>nul
)

rem --- GLOBAL SHORTCUTS & SYSTEM PATH INTEGRATION ---
mkdir "%ProgramData%\Microsoft\Windows\Start Menu\Programs\MiOS Tools" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    $p = 'C:\PortableApps';
    $sm = '$env:ProgramData\Microsoft\Windows\Start Menu\Programs\MiOS Tools';
    $w = New-Object -ComObject WScript.Shell;
    
    $sdio = Get-ChildItem -Path $p -Recurse -Filter 'SDIO*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1;
    if ($sdio) {
        $s = $w.CreateShortcut(\"$sm\Snappy Driver Installer Origin.lnk\");
        $s.TargetPath = $sdio.FullName;
        $s.WorkingDirectory = $sdio.DirectoryName;
        $s.Description = 'MiOS Global Snappy Driver Installer Origin';
        $s.Save();
    }
    
    if (Test-Path \"$p\PortableApps.com\PortableAppsPlatform.exe\") {
        $s = $w.CreateShortcut(\"$sm\PortableApps Platform.lnk\");
        $s.TargetPath = \"$p\PortableApps.com\PortableAppsPlatform.exe\";
        $s.WorkingDirectory = \"$p\PortableApps.com\";
        $s.Description = 'MiOS Global PortableApps Suite';
        $s.Save();
    }

    $cdi = Get-ChildItem -Path $p -Recurse -Filter 'CrystalDiskInfo*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1;
    if ($cdi) {
        $s = $w.CreateShortcut(\"$sm\CrystalDiskInfo.lnk\");
        $s.TargetPath = $cdi.FullName;
        $s.WorkingDirectory = $cdi.DirectoryName;
        $s.Save();
    }

    $npp = Get-ChildItem -Path $p -Recurse -Filter 'Notepad++*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1;
    if ($npp) {
        $s = $w.CreateShortcut(\"$sm\Notepad++.lnk\");
        $s.TargetPath = $npp.FullName;
        $s.WorkingDirectory = $npp.DirectoryName;
        $s.Save();
    }

    $wiz = Get-ChildItem -Path $p -Recurse -Filter 'WizTree*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1;
    if ($wiz) {
        $s = $w.CreateShortcut(\"$sm\WizTree.lnk\");
        $s.TargetPath = $wiz.FullName;
        $s.WorkingDirectory = $wiz.DirectoryName;
        $s.Save();
    }

    $s = $w.CreateShortcut('$env:Public\Desktop\MiOS Tools.lnk');
    $s.TargetPath = $sm;
    $s.Description = 'MiOS Diagnostic & Driver Tools';
    $s.Save();
" >>"%LOG%" 2>&1

powershell.exe -NoProfile -Command "
    $oldPath = [Environment]::GetEnvironmentVariable('Path', 'Machine');
    $add = 'C:\PortableApps';
    if ($oldPath -notlike '*C:\PortableApps*') {
        [Environment]::SetEnvironmentVariable('Path', $oldPath + ';' + $add, 'Machine');
    }
" >>"%LOG%" 2>&1

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

rem --- REMOTE-ACCESS + VIRT-INTEGRATION: the specialize pass turned the RDP LISTENER on,
rem     but the interactive account must ALSO be in "Remote Desktop Users" (+ the logon
rem     right that group carries) or Hyper-V ENHANCED SESSION refuses sign-in ("you need
rem     the right to sign in through Remote Desktop Services"). That group-add can only run
rem     NOW -- post-account (oobeSystem created it), pre-logon. mios-remote.cmd (rendered
rem     from SSOT [autounattend.remote]) also opens the RDP+SSH firewall, starts sshd, and
rem     enables WinRM. virtio + host drivers are already baked offline into the image. ----
echo [MiOS] applying remote-access plane (enhanced-session RDP right / SSH / WinRM) %DATE% %TIME%>>"%LOG%"
if exist "%~dp0mios-remote.cmd" (
    call "%~dp0mios-remote.cmd">>"%LOG%" 2>&1
) else ( echo [MiOS] WARN mios-remote.cmd missing beside SetupComplete>>"%LOG%" )

rem --- Ensure the MiOS AI svc account (svc_user) + MiOS-Host task exist (guard: the
rem     specialize pass may have missed these if the autounattend RunSynchronous block
rem     was not fully rendered). IDEMPOTENT: re-running on a provisioned image is harmless.
rem     Account: rename/enable the built-in RID-500 Administrator so it runs tasks with a
rem     FULL unfiltered token (no UAC filter) and inherits SeBatchLogonRight.
rem     SSOT: __SVCUSER__ (autounattend.service.svc_user) and __SVCPW__ (svc_password,
rem     else identity.default_password) are substituted from mios.toml at bake time
rem     (New-MiOSISO SetupComplete.cmd render) -- NOT hardcoded. ----------
echo [MiOS] ensuring __SVCUSER__ account + MiOS-Host task (pre-logon bootstrap guard) %DATE% %TIME%>>"%LOG%"
net user Administrator "__SVCPW__" /active:yes>>"%LOG%" 2>&1
powershell.exe -NoProfile -Command "try { Rename-LocalUser -Name 'Administrator' -NewName '__SVCUSER__' -EA Stop } catch { }" >>"%LOG%" 2>&1
powershell.exe -NoProfile -Command "try { Set-LocalUser -Name '__SVCUSER__' -PasswordNeverExpires $true -Description '__SVCDESC__' -EA Stop } catch { }" >>"%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" /v "__SVCUSER__" /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
rem     Register MiOS-Host ONSTART task (idempotent /f overwrites if it already exists).
rem     Run level HIGHEST so the first-run install auto-elevates. WSL cannot run as
rem     LocalSystem (microsoft/WSL#11280) -- mios-sudo (RID-500, full token) is the runner.
schtasks /create /tn "MiOS-Host" /sc ONSTART /rl HIGHEST /ru "__SVCUSER__" /rp "__SVCPW__" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-Host.ps1" /f >>"%LOG%" 2>&1
rem     Also register the MINUTE supervisor daemon (keeps the brain alive across reboots).
schtasks /create /tn "MiOS-Daemon" /sc MINUTE /mo 1 /rl HIGHEST /ru "__SVCUSER__" /rp "__SVCPW__" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-Daemon.ps1" /f >>"%LOG%" 2>&1
rem     MiOS-XBOX-Hydrate: Store-delivered Gaming Services / Xbox app / WebView2 the WU-
rem     stripped image can't bake offline (winget msstore). MINUTE/2, self-removing, runs
rem     as __SVCUSER__ (RID-500 full token). Registered HERE (post-rename) now that the
rem     specialize pass no longer does identity work -- so mios-sudo is guaranteed present.
schtasks /create /tn "MiOS-XBOX-Hydrate" /sc MINUTE /mo 2 /rl HIGHEST /ru "__SVCUSER__" /rp "__SVCPW__" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MiOS\MiOS-XBOX-Hydrate.ps1" /f >>"%LOG%" 2>&1
rem --- STAGE-1: MiOS-Xbox provisioning DRIVER + FULL-SCREEN PROGRESS BAR. When the
rem     rendered mios-provision.cmd is present (New-MiOSISO Set-MiOSProvisionWiring), it
rem     OWNS the first-boot deploy: it registers the reboot-surviving MiOS-Setup-Driver
rem     (MiOS-Provision.ps1) that wsl --imports the BAKED-IN seed OFFLINE -- no download/
rem     build on the critical path -- reporting into the ONE aggregate bar
rem     (MiOS-SetupExperience.ps1) that withholds the desktop until 100%. It also re-arms
rem     interactive auto-logon (bar returns across the WSL/podman reboots), arms the bar,
rem     and kicks the driver NOW in Session 0. In that mode we deliberately do NOT also
rem     fire MiOS-Host here (the driver's firstboot phase registers + keeps MiOS-Host/
rem     Daemon alive) -- running both would DOUBLE-IMPORT the distro. The %1/%2 are the
rem     LIVE RID-500 creds set just above (net user / rename), so the driver task logs on.
rem     Fallback (no Stage-1 driver baked): today's fire-and-forget pre-logon MiOS-Host. --
if exist "%~dp0mios-provision.cmd" (
    echo [MiOS] Stage-1 provisioning: arming driver + full-screen bar via mios-provision.cmd %DATE% %TIME%>>"%LOG%"
    call "%~dp0mios-provision.cmd" "__SVCUSER__" "__SVCPW__">>"%LOG%" 2>&1
) else (
    echo [MiOS] starting pre-logon MiOS-Host (Session 0, hidden; no Stage-1 driver) %DATE% %TIME%>>"%LOG%"
    schtasks /run /tn "MiOS-Host">>"%LOG%"
) 2>&1
rem --- Custom Unattend Generator defaults -------------------------------------
echo [MiOS] Running custom Specialize script %DATE% %TIME%>>"%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\Specialize.ps1" >>"%LOG%" 2>&1

echo [MiOS] Running custom DefaultUser script %DATE% %TIME%>>"%LOG%"
reg load "HKU\DefaultUser" "%SystemDrive%\Users\Default\NTUSER.DAT" >>"%LOG%" 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\DefaultUser.ps1" >>"%LOG%" 2>&1
reg unload "HKU\DefaultUser" >>"%LOG%" 2>&1

echo [MiOS] SetupComplete done %DATE% %TIME%>>"%LOG%"
exit /b 0
