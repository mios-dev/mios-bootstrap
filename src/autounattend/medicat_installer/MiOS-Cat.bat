@echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"
:: Resolve dynamic configuration from mios.toml (SSOT)
set "toml_path=%~dp0..\..\..\..\mios.toml"
if not exist "%toml_path%" set "toml_path=%~dp0..\..\..\..\..\mios.toml"

set "drivepath=D"
set "medicatver=21.12"
for /f "usebackq tokens=*" %%i in ("powershell -NoProfile -Command "$v = (Get-Volume | Where-Object { @echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"
:: Resolve dynamic configuration from mios.toml (SSOT)
set "toml_path=%~dp0..\..\..\..\mios.toml"
if not exist "%toml_path%" set "toml_path=%~dp0..\..\..\..\..\mios.toml"

set "drivepath=D"
set "medicatver=21.12"
set "file=M:\MediCat.USB.v21.12.7z"
set "bg_color=#282262"
set "fg_color=#E7DFD3"
set "accent_color=#1A407F"
set "cursor_color=#F35C15"
set "success_color=#3E7765"
set "muted_color=#948E8E"
set "subtle_color=#B7C9D7"

if not exist "%toml_path%" goto no_toml
echo Loading installation settings from %toml_path%...
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*drivepath\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { 'D' }"`) do set "drivepath=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*medicatver\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '21.12' }"`) do set "medicatver=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*cache_path\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { 'M:\MediCat.USB.v21.12.7z' }"`) do set "file=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*bg\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#282262' }"`) do set "bg_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*fg\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#E7DFD3' }"`) do set "fg_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*accent\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#1A407F' }"`) do set "accent_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*cursor\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#F35C15' }"`) do set "cursor_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*success\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#3E7765' }"`) do set "success_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*muted\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#948E8E' }"`) do set "muted_color=%%i"
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*subtle\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#B7C9D7' }"`) do set "subtle_color=%%i"
:no_toml


:: 1. Admin privilege check
net session >nul 2>&1 || (
    echo [ERROR] Please run this installer as Administrator!
    pause
    exit /b 1
)

:: 2. Initial tool checks
if not exist bin md bin
if not exist bin\7z.exe (
    echo Downloading 7z helper...
    curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.exe" -o ./bin/7z.exe
    curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.dll" -o ./bin/7z.dll
)

set "partition_scheme=GPT"
set "filesystem=NTFS"
set "secure_boot=Enabled"
set "extract_mode=Surgical"
set "pa_theme=Dark"
set "build_xbox=Enabled"
set "bake_drivers=Enabled"
set "uup_channel=Dev"
set "gaming_optimize=Enabled"
set "partition_label=MiOS-Cat"

:menu
cls
echo ==========================================================
echo       MiOS-Cat Dedicated USB Deployment Tool
echo ==========================================================
echo   1. USB Target Settings    : Drive [%drivepath%:], Label [%partition_label%]
echo   2. Ventoy / FS Settings   : Format [%filesystem%], Scheme [%partition_scheme%]
echo   3. Customize Theme Colors : Subtle [%subtle_color%], Accent [%accent_color%]
echo   4. MiOS-Xbox Build Config : Drivers [%bake_drivers%], Channel [%uup_channel%]
echo   5. Repository Tools       : Open C:\MiOS, C:\mios-bootstrap, edit TOML
echo   6. START INSTALLATION WITH CURRENT CONFIG
echo   7. EXIT
echo ==========================================================
set "choice="
set /p "choice=Select an option (1-7): "

if "%choice%"=="1" goto sub_usb
if "%choice%"=="2" goto sub_ventoy
if "%choice%"=="3" goto sub_colors
if "%choice%"=="4" goto sub_xbox
if "%choice%"=="5" goto sub_repos
if "%choice%"=="6" goto start_install
if "%choice%"=="7" exit /b 0
goto menu

:sub_usb
cls
echo ==========================================================
echo               USB Target Settings
echo ==========================================================
echo   1. Target USB Drive letter  : %drivepath%:
echo   2. Format Partition Label   : %partition_label%
echo   3. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-3): "
if "%sub_choice%"=="1" goto set_drive
if "%sub_choice%"=="2" goto set_label
if "%sub_choice%"=="3" goto menu
goto sub_usb

:sub_ventoy
cls
echo ==========================================================
echo               Ventoy / FS / Extraction Settings
echo ==========================================================
echo   1. Partition Scheme         : %partition_scheme%
echo   2. Filesystem Format        : %filesystem%
echo   3. Secure Boot Support      : %secure_boot%
echo   4. Core Download Cache      : %file%
echo   5. Extraction Mode          : %extract_mode%
echo   6. PortableApps Theme       : %pa_theme%
echo   7. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-7): "
if "%sub_choice%"=="1" goto set_scheme
if "%sub_choice%"=="2" goto set_fs
if "%sub_choice%"=="3" goto set_secure
if "%sub_choice%"=="4" goto set_cache
if "%sub_choice%"=="5" goto set_extract
if "%sub_choice%"=="6" goto set_pa_theme
if "%sub_choice%"=="7" goto menu
goto sub_ventoy

:sub_colors
cls
echo ==========================================================
echo               Customize Theme Colors
echo ==========================================================
echo   1. Background Color (bg)    : %bg_color%
echo   2. Foreground Color (fg)    : %fg_color%
echo   3. Accent Color (accent)    : %accent_color%
echo   4. Cursor Color (cursor)    : %cursor_color%
echo   5. Success Color (success)  : %success_color%
echo   6. Muted Color (muted)      : %muted_color%
echo   7. Subtle Color (subtle)    : %subtle_color%
echo   8. Reset to default base colors
echo   9. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-9): "
if "%sub_choice%"=="1" goto set_color_bg
if "%sub_choice%"=="2" goto set_color_fg
if "%sub_choice%"=="3" goto set_color_accent
if "%sub_choice%"=="4" goto set_color_cursor
if "%sub_choice%"=="5" goto set_color_success
if "%sub_choice%"=="6" goto set_color_muted
if "%sub_choice%"=="7" goto set_color_subtle
if "%sub_choice%"=="8" goto reset_colors
if "%sub_choice%"=="9" goto menu
goto sub_colors

:sub_xbox
cls
echo ==========================================================
echo               MiOS-Xbox Build Config
echo ==========================================================
echo   1. Compile MiOS-Xbox ISO    : %build_xbox%
echo   2. Bake Host Drivers       : %bake_drivers%
echo   3. Microsoft UUP Channel   : %uup_channel%
echo   4. Gaming Optimizations    : %gaming_optimize%
echo   5. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-5): "
if "%sub_choice%"=="1" goto set_xbox
if "%sub_choice%"=="2" goto set_bake_drivers
if "%sub_choice%"=="3" goto set_uup_channel
if "%sub_choice%"=="4" goto set_gaming_optimize
if "%sub_choice%"=="5" goto menu
goto sub_xbox

:sub_repos
cls
echo ==========================================================
echo               Repository Tools
echo ==========================================================
echo   1. Open MiOS Repository (C:\MiOS)
echo   2. Open mios-bootstrap Repository (C:\mios-bootstrap)
echo   3. Edit base mios.toml configuration
echo   4. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-4): "
if "%sub_choice%"=="1" start explorer.exe C:\MiOS && goto sub_repos
if "%sub_choice%"=="2" start explorer.exe C:\mios-bootstrap && goto sub_repos
if "%sub_choice%"=="3" start notepad.exe "%toml_path%" && goto sub_repos
if "%sub_choice%"=="4" goto menu
goto sub_repos

:set_drive
cls
echo Current target drive: %drivepath%:
echo Available drives:
wmic logicaldisk get deviceid, volumename, description
echo.
set /p "new_drive=Enter USB drive letter (e.g. E, F, G) or press Enter to keep: "
if not "%new_drive%"=="" (
    set "drivepath=%new_drive:~0,1%"
)
goto sub_usb

:set_label
cls
echo Current partition label: %partition_label%
set /p "new_label=Enter partition volume label or press Enter to keep: "
if not "%new_label%"=="" (
    set "partition_label=%new_label%"
)
goto sub_usb

:set_scheme
if "%partition_scheme%"=="GPT" (
    set "partition_scheme=MBR"
) else (
    set "partition_scheme=GPT"
)
goto sub_ventoy

:set_fs
if "%filesystem%"=="NTFS" (
    set "filesystem=exFAT"
) else (
    set "filesystem=NTFS"
)
goto sub_ventoy

:set_secure
if "%secure_boot%"=="Enabled" (
    set "secure_boot=Disabled"
) else (
    set "secure_boot=Enabled"
)
goto sub_ventoy

:set_cache
cls
echo Current cache file path: %file%
set /p "new_cache=Enter full path to MediCat core 7z or press Enter to keep: "
if not "%new_cache%"=="" (
    set "file=%new_cache%"
)
goto sub_ventoy

:set_extract
if "%extract_mode%"=="Surgical" (
    set "extract_mode=Full"
) else (
    set "extract_mode=Surgical"
)
goto sub_ventoy

:set_pa_theme
if "%pa_theme%"=="Dark" (
    set "pa_theme=Classic"
) else (
    set "pa_theme=Dark"
)
goto sub_ventoy

:set_xbox
if "%build_xbox%"=="Enabled" (
    set "build_xbox=Disabled"
) else (
    set "build_xbox=Enabled"
)
goto sub_xbox

:set_bake_drivers
if "%bake_drivers%"=="Enabled" (
    set "bake_drivers=Disabled"
) else (
    set "bake_drivers=Enabled"
)
goto sub_xbox

:set_uup_channel
if "%uup_channel%"=="Dev" (
    set "uup_channel=Beta"
) else if "%uup_channel%"=="Beta" (
    set "uup_channel=Release"
) else (
    set "uup_channel=Dev"
)
goto sub_xbox

:set_gaming_optimize
if "%gaming_optimize%"=="Enabled" (
    set "gaming_optimize=Disabled"
) else (
    set "gaming_optimize=Enabled"
)
goto sub_xbox

:set_color_bg
set /p "bg_color=Enter background hex color (e.g. #282262): "
goto sub_colors

:set_color_fg
set /p "fg_color=Enter foreground hex color (e.g. #E7DFD3): "
goto sub_colors

:set_color_accent
set /p "accent_color=Enter accent hex color (e.g. #1A407F): "
goto sub_colors

:set_color_cursor
set /p "cursor_color=Enter cursor hex color (e.g. #F35C15): "
goto sub_colors

:set_color_success
set /p "success_color=Enter success hex color (e.g. #3E7765): "
goto sub_colors

:set_color_muted
set /p "muted_color=Enter muted hex color (e.g. #948E8E): "
goto sub_colors

:set_color_subtle
set /p "subtle_color=Enter subtle hex color (e.g. #B7C9D7): "
goto sub_colors

:reset_colors
echo Resetting to base TOML colors...
if exist "%toml_path%" (
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*bg\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#282262' }"`) do set "bg_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*fg\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#E7DFD3' }"`) do set "fg_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*accent\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#1A407F' }"`) do set "accent_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*cursor\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#F35C15' }"`) do set "cursor_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*success\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#3E7765' }"`) do set "success_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*muted\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#948E8E' }"`) do set "muted_color=%%i"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$val = (Get-Content '%toml_path%' | Select-String -Pattern '^\s*subtle\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value }); if ($val) { $val } else { '#B7C9D7' }"`) do set "subtle_color=%%i"
)
goto sub_colors

:start_install
cls
echo.
echo ==========================================================
echo             STARTING MiOS-Cat INSTALLATION
echo ==========================================================
echo Target Drive      : %drivepath%:
echo Cache File        : %file%
echo Extraction Mode   : %extract_mode%
echo Build MiOS-Xbox   : %build_xbox%
echo Partition Label   : %partition_label%
echo Partition Scheme  : %partition_scheme%
echo Filesystem        : %filesystem%
echo Secure Boot       : %secure_boot%
echo PortableApps Theme: %pa_theme%
echo Background Color  : %bg_color%
echo Foreground Color  : %fg_color%
echo Accent Color      : %accent_color%
echo Cursor Color      : %cursor_color%
echo Success Color     : %success_color%
echo Muted Color       : %muted_color%
echo Subtle Color      : %subtle_color%
echo Xbox Bake Drivers : %bake_drivers%
echo Xbox UUP Channel  : %uup_channel%
echo Xbox Gaming Opt.  : %gaming_optimize%
echo ==========================================================
echo.
set /p "confirm=Are you sure you want to format %drivepath%: and install? (Y/N): "
if /i not "%confirm%"=="Y" goto menu

:: Ensure target drive exists
if not exist "%drivepath%:\" (
    echo [ERROR] Target drive %drivepath%: was not found!
    echo Please insert your USB drive and ensure it is mounted as %drivepath%:\
    pause
    goto menu
)

:: 4. Download Ventoy bootloader
echo Checking Ventoy files...
if not exist "%stage_dir%\Ventoy2Disk" (
    echo Downloading latest Ventoy windows release...
    curl -s -L "https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-windows.zip" -o "%stage_dir%\ventoy.zip"
    "%stage_dir%\bin\7z.exe" x "%stage_dir%\ventoy.zip" -o"%stage_dir%" -aoa >nul
    ren "%stage_dir%\ventoy-1.0.99" Ventoy2Disk
    del "%stage_dir%\ventoy.zip" /Q
)

:: 5. Install Ventoy to USB drive
echo.
echo Installing Ventoy to %drivepath%: (%partition_scheme% partition scheme)...
cd /d "%stage_dir%\Ventoy2Disk"
set "vtoy_args=/I /Drive:%drivepath%: /%partition_scheme%"
if "%secure_boot%"=="Enabled" (
    set "vtoy_args=%vtoy_args% /S"
) else (
    set "vtoy_args=%vtoy_args% /NOUSBCheck"
)
Ventoy2Disk.exe VTOYCLI %vtoy_args%
cd /d "%maindir%"

echo Waiting 5s for partition remount...
ping localhost -n 6 >nul

:: Format partition
echo Formatting primary partition as %filesystem% (%partition_label%)...
format %drivepath%: /FS:%filesystem% /X /Q /V:%partition_label% /Y >nul

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
if "%extract_mode%"=="Surgical" (
    echo.
    echo Extracting minimal boot files and portable apps from %file% to %drivepath%:...
    echo (Extracting only PE, SystemRescue, and core startup structures...)
    "%stage_dir%\bin\7z.exe" x "%file%" -o%drivepath%:\ Live_Operating_Systems/Mini_Windows/* Live_Operating_Systems/SystemRescue/* System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* -aoa -y
) else (
    echo.
    echo Extracting ALL files from %file% to %drivepath%:...
    "%stage_dir%\bin\7z.exe" x "%file%" -o%drivepath%:\ -aoa -y
)

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

:: Stage offline copies of the repositories on the USB drive as fallback sources
echo Staging offline repository fallback copies...
ping -n 1 github.com >nul 2>&1
if %errorlevel% equ 0 (
    echo [ONLINE] Pulling/cloning live repositories from GitHub...
    
    if exist "%drivepath%:\ventoy\repo\mios-bootstrap\.git" (
        echo Updating mios-bootstrap repository...
        cd /d "%drivepath%:\ventoy\repo\mios-bootstrap"
        git pull >nul 2>&1
    ) else (
        echo Cloning mios-bootstrap repository...
        git clone https://github.com/mios-dev/mios-bootstrap.git "%drivepath%:\ventoy\repo\mios-bootstrap" >nul 2>&1
    )
    
    if exist "%drivepath%:\ventoy\repo\MiOS\.git" (
        echo Updating MiOS repository...
        cd /d "%drivepath%:\ventoy\repo\MiOS"
        git pull >nul 2>&1
    ) else (
        echo Cloning MiOS repository...
        git clone https://github.com/mios-dev/MiOS.git "%drivepath%:\ventoy\repo\MiOS" >nul 2>&1
    )
    cd /d "%maindir%"
) else (
    echo [OFFLINE] Internet unreachable. Falling back to local developer repository copies...
    mkdir "%drivepath%:\ventoy\repo\mios-bootstrap" >nul 2>&1
    robocopy "C:\mios-bootstrap" "%drivepath%:\ventoy\repo\mios-bootstrap" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 >nul
    mkdir "%drivepath%:\ventoy\repo\MiOS" >nul 2>&1
    robocopy "C:\MiOS" "%drivepath%:\ventoy\repo\MiOS" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 >nul
)

:: Overwrite stock System images
echo Customizing System folder thumbnails...
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\System\background.jpg" /Y >nul
copy "%maindir%\resources\theme\uefi\background.jpg" "%drivepath%:\System\Antivirus.jpg" /Y >nul

:: Write autorun.inf for USB drive branding and custom icon
echo Injecting custom USB drive branding and icons...
attrib -r -h -s "%drivepath%:\autorun.inf" >nul 2>&1
attrib -r -h -s "%drivepath%:\icon.ico" >nul 2>&1
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
echo PrimaryColor=%subtle_color%
echo SecondaryColor=%muted_color%
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
mkdir "%stage_dir%\mount" >nul 2>&1
echo Mounting WIM image (Index 1)...
dism /Mount-Image /ImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /Index:1 /MountDir:"%stage_dir%\mount"

echo Exporting build-host drivers for WinPE injection...
mkdir "%stage_dir%\hostdrivers" >nul 2>&1
dism /Online /Export-Driver /Destination:"%stage_dir%\hostdrivers" >nul 2>&1
echo Injecting host drivers into MiOS_PE.wim...
dism /Image:"%stage_dir%\mount" /Add-Driver /Driver:"%stage_dir%\hostdrivers" /Recurse /ForceUnsigned >nul 2>&1
rmdir /s /q "%stage_dir%\hostdrivers" >nul 2>&1

echo Replacing wallpapers inside WIM image...
takeown /f "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /a >nul 2>&1
icacls "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /Y >nul

takeown /f "%stage_dir%\mount\Windows\System32\winpe.jpg" /a >nul 2>&1
icacls "%stage_dir%\mount\Windows\System32\winpe.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%stage_dir%\mount\Windows\System32\winpe.jpg" /Y >nul

takeown /f "%stage_dir%\mount\Windows\System32\winre.jpg" /a >nul 2>&1
icacls "%stage_dir%\mount\Windows\System32\winre.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%stage_dir%\mount\Windows\System32\winre.jpg" /Y >nul

takeown /f "%stage_dir%\mount\Windows\Web\Screen\img100.jpg" /a >nul 2>&1
icacls "%stage_dir%\mount\Windows\Web\Screen\img100.jpg" /grant administrators:F >nul 2>&1
copy "%maindir%\resources\theme\uefi\background.jpg" "%stage_dir%\mount\Windows\Web\Screen\img100.jpg" /Y >nul

echo Injecting Geist Mono font and custom Console colors into WIM image...
copy "C:\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" "%stage_dir%\mount\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" /Y >nul
reg load HKEY_USERS\pe-default "%stage_dir%\mount\Windows\System32\config\DEFAULT" >nul
reg load HKEY_USERS\pe-software "%stage_dir%\mount\Windows\System32\config\SOFTWARE" >nul
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
set "retry_count=0"
:unmount_retry
dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Commit
if %errorlevel% neq 0 (
    set /a retry_count+=1
    if %retry_count% lss 4 (
        echo [WARNING] Unmount failed (possibly locked). Retrying in 4 seconds (attempt %retry_count%/3)...
        ping localhost -n 5 >nul
        goto unmount_retry
    )
    echo [ERROR] Failed to unmount the image after 3 attempts. Force-cleaning mount points...
    dism /Cleanup-Wim >nul 2>&1
)
rmdir "%stage_dir%\mount" /S /Q >nul 2>&1

echo Exporting and compressing MiOS_PE.wim to reclaim space...
dism /Export-Image /SourceImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /SourceIndex:1 /DestinationImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" /Compress:max >nul 2>&1
if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" (
    del "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" /Q
    move "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" >nul
)


:: 10. Compile the inline live build of MiOS-Xbox ISO directly to the USB drive
if "%build_xbox%"=="Enabled" (
    echo.
    echo ==========================================================
    echo   Compiling Inline Live Build of MiOS-Xbox Installer ISO  
    echo ==========================================================
    echo This will pull the build prereqs, merge configurations,
    echo and assemble the custom MiOS-Xbox installation media.
    echo Output path: %drivepath%:\Live_Operating_Systems\MiOS-Xbox.iso
    echo ==========================================================
    echo.
    
    echo Generating customized runtime configuration...
    powershell -NoProfile -Command ^
        "$orig = 'C:\MiOS\mios.toml';" ^
        "if (-not (Test-Path $orig)) { $orig = '%toml_path%' };" ^
        "if (Test-Path $orig) {" ^
        "  $c = Get-Content $orig -Raw;" ^
        "  $chan = '%uup_channel%'.ToLower();" ^
        "  $c = $c -replace '(?s)(\[editions\.mios-xbox\].*?autounattend\.uup_channel\s*=\s*\")[^\"]*(\")', \"${1}${chan}${2}\";" ^
        "  $bake = if ('%bake_drivers%' -eq 'Enabled') { 'true' } else { 'false' };" ^
        "  if ($c -match 'autounattend\.bake_host_drivers\s*=') {" ^
        "    $c = $c -replace 'autounattend\.bake_host_drivers\s*=\s*\w+', \"autounattend.bake_host_drivers = $bake\";" ^
        "  } else {" ^
        "    $c = $c -replace '(\[editions\.mios-xbox\])', \"`$1`r`nautounattend.bake_host_drivers = $bake\";" ^
        "  }" ^
        "  $game = if ('%gaming_optimize%' -eq 'Enabled') { 'gaming' } else { 'minimal' };" ^
        "  $c = $c -replace '(?s)(\[editions\.mios-xbox\].*?autounattend\.debloat_profile\s*=\s*\")[^\"]*(\")', \"${1}${game}${2}\";" ^
        "  $c | Set-Content \"$env:TEMP\mios_run.toml\" -Force;" ^
        "}"
    for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$v = (Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.SizeRemaining -gt 15GB } | Sort-Object SizeRemaining -Descending | Select-Object -First 1); if ($v) { $v.DriveLetter + ':\MiOS\isobuild_live' } else { 'C:\MiOS\isobuild_live' }"`) do set "workdir_path=%%i"
    powershell.exe -ExecutionPolicy Bypass -File "C:\mios-bootstrap\src\autounattend\Build-MiOSXboxISO.ps1" -TomlPath "%temp%\mios_run.toml" -OutIso "%drivepath%:\Live_Operating_Systems\MiOS-Xbox.iso" -WorkDir "%workdir_path%" -SkipWsl -SkipPrereqs
)

echo.
echo ==========================================================
echo     MiOS-Cat DEDICATED USB INSTALLATION COMPLETED         
echo ==========================================================
echo Drive %drivepath%: is now ready to boot into MiOS-Cat!
echo ==========================================================
pause
