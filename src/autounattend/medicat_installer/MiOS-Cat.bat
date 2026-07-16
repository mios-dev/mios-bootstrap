@echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"
:: Resolve dynamic configuration from mios.toml (SSOT)
set "toml_path=%~dp0..\..\..\..\mios.toml"
if not exist "%toml_path%" set "toml_path=%~dp0..\..\..\..\..\mios.toml"

set "drivepath=D"
set "medicatver=21.12"
set "file=M:\MediCat.USB.v21.12.7z"
set "primary_color=#B7C9D7"
set "secondary_color=#948E8E"
set "accent_color=#3E7765"

if exist "%toml_path%" (
    echo Loading installation settings from %toml_path%...
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*drivepath\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { 'D' }"`) do set "drivepath=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*medicatver\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '21.12' }"`) do set "medicatver=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*cache_path\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { 'M:\MediCat.USB.v21.12.7z' }"`) do set "file=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*subtle\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#B7C9D7' }"`) do set "primary_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*muted\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#948E8E' }"`) do set "secondary_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*success\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#3E7765' }"`) do set "accent_color=%%i"
)


echo ==========================================================
echo       MiOS-Cat USB BOOTSTRAP DEPLOYMENT INSTALLER         
echo ==========================================================
echo Target USB Drive: %drivepath%:
echo Core Download Cache: %file%
echo ==========================================================
echo.

:: 1. Admin privilege check
net session >nul 2>&1 || (
    echo [ERROR] Please run this installer as Administrator!
    pause
    exit /b 1
)

:: 2. Ensure target drive D: exists
if not exist "%drivepath%:\" (
    echo [ERROR] Target drive %drivepath%: was not found!
    echo Please insert your USB drive and ensure it is mounted as %drivepath%:\
    pause
    exit /b 1
)

:: 3. Initial tool checks
if not exist bin md bin
if not exist bin\7z.exe (
    echo Downloading 7z helper...
    curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.exe" -o ./bin/7z.exe
    curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.dll" -o ./bin/7z.dll
)

:: 4. Download Ventoy bootloader
echo Checking Ventoy files...
if not exist Ventoy2Disk (
    echo Downloading latest Ventoy windows release...
    curl -s -L "https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-windows.zip" -o ./ventoy.zip
    bin\7z.exe x ventoy.zip -aoa >nul
    ren ventoy-1.0.99 Ventoy2Disk
    del ventoy.zip /Q
)

:: 5. Install Ventoy to USB drive D:
echo.
echo Installing Ventoy to %drivepath%: (GPT partition scheme)...
cd Ventoy2Disk
Ventoy2Disk.exe VTOYCLI /I /Drive:%drivepath%: /NOUSBCheck /GPT
cd %maindir%

echo Waiting 5s for partition remount...
ping localhost -n 6 >nul

:: Format partition NTFS / MiOS-Cat
echo Formatting primary partition as NTFS (MiOS-Cat)...
format %drivepath%: /FS:NTFS /X /Q /V:MiOS-Cat /Y >nul

:: 6. Pull/Download Medicat core archive to M:\ (large storage)
set "download_needed=0"
if not exist "%file%" (
    set "download_needed=1"
    goto do_download
)

powershell -Command "$s = (Get-Item '%file%' -ErrorAction SilentlyContinue).Length; if ($s -lt 22994783619) { exit 1 } else { exit 0 }"
if %errorlevel% neq 0 (
    echo Core Medicat archive is incomplete. Resuming download...
    set "download_needed=1"
)

:do_download
if "%download_needed%"=="1" (
    echo.
    echo Pulling/Resuming core Medicat files 23 GB from CDN...
    echo This might take a while depending on your internet connection.
    echo Saving to: %file%
    echo.
    curl.exe -C - -e "https://installer.medicatusb.com" -L "https://cat.tcbl.dev/MediCat.USB.v21.12.7z" -o "%file%" -#
) else (
    echo [OK] Core Medicat archive found and complete at %file%
)


:: 6b. Pull/Download Fedora Server Netinstall ISO
set "fedora_file=M:\Fedora-Server-netinst-x86_64-40.iso"
if not exist "%fedora_file%" (
    echo.
    echo Fedora Server Netinstall ISO not found in M:\
    echo Pulling Fedora Server minimal ISO 850 MB from mirror...
    curl.exe -L "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Server/x86_64/iso/Fedora-Server-netinst-x86_64-40.iso" -o "%fedora_file%" -#
) else (
    echo [OK] Fedora Server ISO found at %fedora_file%
)

:: 7. Minimal/Surgical extraction to D:\ to fit the drive
echo.
echo Extracting minimal boot files and portable apps from %file% to %drivepath%:...
echo (Extracting only PE, SystemRescue, and core startup structures...)
bin\7z.exe x "%file%" -o%drivepath%:\ Live_Operating_Systems/Mini_Windows/* Live_Operating_Systems/SystemRescue/* System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* -aoa -y

:: 8. Apply custom MiOS templates and layouts
echo.
echo Applying custom MiOS configurations, wallpapers, and layouts...
xcopy "%maindir%\resources\ventoy" "%drivepath%:\ventoy\" /E /I /H /Y /Q >nul
xcopy "%maindir%\resources\theme" "%drivepath%:\ventoy\theme\" /E /I /H /Y /Q >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun.sh" /Y >nul
mkdir "%drivepath%:\autorun" >nul 2>&1
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun\autorun.sh" /Y >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun\autorun" /Y >nul
copy "%maindir%\resources\CdUsb.Y" "%drivepath%:\CdUsb.Y" /Y >nul

:: Overwrite stock System images
echo Customizing System folder thumbnails...
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\System\background.jpg" /Y >nul
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\System\Antivirus.jpg" /Y >nul

:: Write autorun.inf for USB drive branding and custom icon
echo Injecting custom USB drive branding and icons...
(
echo [Autorun]
echo Icon=icon.ico
echo Label=MiOS-Cat
) > "%drivepath%:\autorun.inf"
copy "%maindir%\icon.ico" "%drivepath%:\icon.ico" /Y >nul
attrib +h +s "%drivepath%:\autorun.inf" >nul 2>&1
attrib +h +s "%drivepath%:\icon.ico" >nul 2>&1

:: Configure custom folder icons using desktop.ini
for %%F in (System ventoy Live_Operating_Systems PortableApps Documents autorun) do (
    if exist "%drivepath%:\%%F" (
        copy "%maindir%\icon.ico" "%drivepath%:\%%F\icon.ico" /Y >nul
        (
        echo [.ShellClassInfo]
        echo IconResource=icon.ico,0
        ) > "%drivepath%:\%%F\desktop.ini"
        attrib +r "%drivepath%:\%%F" >nul 2>&1
        attrib +h +s "%drivepath%:\%%F\desktop.ini" >nul 2>&1
        attrib +h +s "%drivepath%:\%%F\icon.ico" >nul 2>&1
    )
)

:: Compile custom branded launcher to replace stock Start.exe
echo Compiling custom branded Start.exe launcher...
(
echo using System;
echo using System.Diagnostics;
echo using System.IO;
echo class Launcher {
echo     static void Main^(^) {
echo         string path = Path.Combine^(AppDomain.CurrentDomain.BaseDirectory, @"PortableApps\PortableApps.com\PortableAppsPlatform.exe"^);
echo         if ^(File.Exists^(path^)^) {
echo             Process.Start^(new ProcessStartInfo {
echo                 FileName = path,
echo                 UseShellExecute = true
echo             }^);
echo         }
echo     }
echo }
) > "%temp%\launcher.cs"

C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:"%maindir%\icon.ico" /out:"%drivepath%:\Start.exe" "%temp%\launcher.cs" >nul 2>&1
del "%temp%\launcher.cs" /Q >nul 2>&1

:: Copy Fedora ISO and Kickstart to Ventoy paths
echo Copying Fedora Server ISO and Kickstart template to USB...
copy "%fedora_file%" "%drivepath%:\Live_Operating_Systems\Fedora-Server.iso" /Y >nul
copy "%maindir%\resources\ventoy\mios-kickstart.cfg" "%drivepath%:\ventoy\mios-kickstart.cfg" /Y >nul


:: Brand the PortableApps Menu to match MiOS
echo Theming PortableApps Platform...
mkdir "%drivepath%:\PortableApps\PortableApps.com\App\Graphics" >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\PortableApps\PortableApps.com\App\Graphics\logo.png" /Y >nul
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\PortableApps\PortableApps.com\App\Graphics\header.png" /Y >nul
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\PortableApps\PortableApps.com\App\Graphics\menu_bg.png" /Y >nul

:: Create custom themed ini config for PortableApps Menu
mkdir "%drivepath%:\PortableApps\PortableApps.com\Data" >nul 2>&1
(
echo [Theme]
echo Color=Custom
echo PrimaryColor=%primary_color%
echo SecondaryColor=%secondary_color%
echo AccentColor=%accent_color%
echo SetTheme=Custom
echo Logo=logo.png
echo.
echo [Files]
echo CommonDocumentsDirectory=..\..\Documents
echo CommonPicturesDirectory=..\..\Documents
echo CommonMusicDirectory=..\..\Documents
echo CommonVideoDirectory=..\..\Documents
) > "%drivepath%:\PortableApps\PortableApps.com\Data\PortableAppsMenu.ini"

:: Theme CrystalDiskInfo to Dark
mkdir "%drivepath%:\PortableApps\CrystalDiskInfoPortable\Data\settings" >nul 2>&1
(
echo [Setting]
echo Theme=Dark
) > "%drivepath%:\PortableApps\CrystalDiskInfoPortable\Data\settings\DiskInfo.ini"


:: 8b. Create integration folders and write themed README.md files (No empty folders!)
echo Creating integrated directories and documentation...
mkdir "%drivepath%:\PortableApps\MiOS-Xbox-Builder" >nul 2>&1
copy "%maindir%\resources\MiOS-Xbox-Builder.bat" "%drivepath%:\PortableApps\MiOS-Xbox-Builder\MiOS-Xbox-Builder.bat" /Y >nul
(
echo # MiOS-Xbox Builder
echo This utility executes the full offline build and servicing pipeline for the MiOS-Xbox system,
echo generating customized, debloated installation ISOs and images.
) > "%drivepath%:\PortableApps\MiOS-Xbox-Builder\README.md"

mkdir "%drivepath%:\Documents" >nul 2>&1
(
echo # MiOS-Cat Documents
echo This directory stores application data, scripts, configs, and diagnostic logs
echo compiled during system deployment and recovery. It is integrated directly with the
echo PortableApps suite on disk and mapped to host filesystems.
) > "%drivepath%:\Documents\README.md"

(
echo # MiOS-Cat Portable Applications
echo This folder contains a surgical, minimal selection of portable diagnostic
echo and imaging utilities tailored specifically for MiOS deployment.
) > "%drivepath%:\PortableApps\README.md"

(
echo # MiOS-Cat Live Boot Configurations
echo This folder stores bootloader files, Grub configuration templates, and custom theme layouts.
) > "%drivepath%:\ventoy\README.md"

(
echo # MiOS-Cat Operating Systems
echo This folder contains the live WinPE recovery image ^(MiOS_PE.wim^) and SystemRescue ISO.
) > "%drivepath%:\Live_Operating_Systems\README.md"


:: 9. Rename WIM and perform Offline DISM wallpaper servicing
echo.
echo Renaming WIM image to MiOS_PE.wim...
move "%drivepath%:\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" >nul

echo.
echo Performing offline servicing on MiOS_PE.wim to inject MiOS custom wallpaper...
mkdir "%maindir%\mount" >nul 2>&1
echo Mounting WIM image (Index 1)...
dism /Mount-Image /ImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /Index:1 /MountDir:"%maindir%\mount"

echo Replacing wallpapers inside WIM image...
takeown /f "%maindir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /a >nul 2>&1
icacls "%maindir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%maindir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /Y >nul

takeown /f "%maindir%\mount\Windows\System32\winpe.jpg" /a >nul 2>&1
icacls "%maindir%\mount\Windows\System32\winpe.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%maindir%\mount\Windows\System32\winpe.jpg" /Y >nul

takeown /f "%maindir%\mount\Windows\System32\winre.jpg" /a >nul 2>&1
icacls "%maindir%\mount\Windows\System32\winre.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%maindir%\mount\Windows\System32\winre.jpg" /Y >nul

takeown /f "%maindir%\mount\Windows\Web\Screen\img100.jpg" /a >nul 2>&1
icacls "%maindir%\mount\Windows\Web\Screen\img100.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%maindir%\mount\Windows\Web\Screen\img100.jpg" /Y >nul

echo Injecting Geist Mono font and custom Console colors into WIM image...
copy "C:\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" "%maindir%\mount\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" /Y >nul
reg load HKEY_USERS\pe-default "%maindir%\mount\Windows\System32\config\DEFAULT" >nul
reg load HKEY_USERS\pe-software "%maindir%\mount\Windows\System32\config\SOFTWARE" >nul
reg add "HKEY_USERS\pe-software\Microsoft\Windows NT\CurrentVersion\Fonts" /v "GeistMono Nerd Font Mono Regular (TrueType)" /t REG_SZ /d "GeistMonoNerdFontMono-Regular.otf" /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "ColorTable00" /t REG_DWORD /d 6431272 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "ColorTable07" /t REG_DWORD /d 13885415 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "ColorTable09" /t REG_DWORD /d 8339482 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "ColorTable12" /t REG_DWORD /d 1399923 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "ScreenColors" /t REG_DWORD /d 7 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "FaceName" /t REG_SZ /d "GeistMono Nerd Font Mono" /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "FontSize" /t REG_DWORD /d 1048576 /f >nul
reg add "HKEY_USERS\pe-default\Console" /v "FontFamily" /t REG_DWORD /d 54 /f >nul
reg add "HKEY_USERS\pe-default\Console\%%SystemRoot%%_System32_cmd.exe" /v "FaceName" /t REG_SZ /d "GeistMono Nerd Font Mono" /f >nul
reg add "HKEY_USERS\pe-default\Console\%%SystemRoot%%_System32_cmd.exe" /v "FontSize" /t REG_DWORD /d 1048576 /f >nul
reg add "HKEY_USERS\pe-default\Console\%%SystemRoot%%_System32_cmd.exe" /v "FontFamily" /t REG_DWORD /d 54 /f >nul
reg unload HKEY_USERS\pe-default >nul
reg unload HKEY_USERS\pe-software >nul


echo Committing changes and unmounting WIM image...
dism /Unmount-Image /MountDir:"%maindir%\mount" /Commit
rmdir "%maindir%\mount" /S /Q >nul 2>&1

echo Exporting and compressing MiOS_PE.wim to reclaim space...
dism /Export-Image /SourceImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /SourceIndex:1 /DestinationImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" /Compress:max >nul 2>&1
if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" (
    del "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /Q
    move "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" >nul
)


:: 10. Compile the inline live build of MiOS-Xbox ISO directly to the USB drive
echo.
echo ==========================================================
echo   Compiling Inline Live Build of MiOS-Xbox Installer ISO  
echo ==========================================================
echo This will pull the build prereqs, merge configurations,
echo and assemble the custom MiOS-Xbox installation media.
echo Output path: %drivepath%:\Live_Operating_Systems\MiOS-Xbox.iso
echo ==========================================================
echo.
powershell.exe -ExecutionPolicy Bypass -File "C:\mios-bootstrap\src\autounattend\Build-MiOSXboxISO.ps1" -OutIso "%drivepath%:\Live_Operating_Systems\MiOS-Xbox.iso" -SkipWsl

echo.
echo ==========================================================
echo     MiOS-Cat DEDICATED USB INSTALLATION COMPLETED         
echo ==========================================================
echo Drive %drivepath%: is now ready to boot into MiOS-Cat!
echo ==========================================================
pause

