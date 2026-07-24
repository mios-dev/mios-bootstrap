@echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"

:: Self-elevate so a plain double-click on factory-fresh Windows just works (UAC
:: prompt) instead of failing the Administrator preflight. Get-MiOS / the
:: scheduled task launch already-elevated and pass straight through this gate.
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%NONINTERACTIVE%"=="1" (
        echo FAIL: Administrator privileges required for non-interactive execution!
        exit /b 1
    )
    echo Requesting administrator privileges...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)
call :ensure_live_monitor
:: Resolve dynamic configuration from mios.toml (SSOT).
:: The launcher lives at <repo>\cat\, so the repo-local SSOT (which also travels
:: with the MiOS-Repo USB) is one level up; fall back to the canonical MiOS SSOT
:: on a MiOS-equipped host. (Future [cat] SSOT block -> T-258.)
set "toml_path=%~dp0..\mios.toml"
if not exist "%toml_path%" set "toml_path=C:\MiOS\usr\share\mios\mios.toml"

set "drivepath=D"
set "medicatver=21.12"
:: Ventoy version is NEVER hand-pinned. MiOS targets the NEWEST upstream GLOBALLY and
:: GENERATES the pin at runtime (resolved live from GitHub) or at build (recorded into the
:: SSOT SBOM as [cat].ventoy_version). Empty here on purpose -- no hardcoded fallback. If
:: it cannot be resolved (offline + no build-recorded pin + no Ventoy already staged) the
:: flash fails loud rather than silently pinning a stale version.
set "ventoy_ver="
set "min_disk_gb=512"
set "repo_label=MiOS-Repo"
set "data_label=MiOS-Data"
set "stage_dir=M:\MiOS\medicat_stage"
if not exist "M:\" set "stage_dir=%TEMP%\medicat_stage"
mkdir "%stage_dir%" >nul 2>&1
set "file=M:\MediCat.USB.v21.12.7z"
set "bg_color=#282262"
set "fg_color=#E7DFD3"
set "accent_color=#1A407F"
set "cursor_color=#F35C15"
set "success_color=#3E7765"
set "muted_color=#948E8E"
set "subtle_color=#B7C9D7"

:: Load the SSOT palette + settings from mios.toml in ONE powershell pass, writing a temp
:: `set` script we then `call`. Replaces a stack of fragile per-key `for /f`-backtick loops
:: whose escaped-quote regex broke cmd parsing -- so the whole block had been `goto`-skipped
:: and NOTHING was actually SSOT-driven. [char]34 supplies the double-quotes so there are no
:: nested \" to trip cmd. The hardcoded defaults above stand as fallbacks for any key
:: mios.toml omits (degrade-open on a missing/partial SSOT). TOML values are quoted or numeric.
if not exist "%toml_path%" goto no_toml
echo Loading installation settings from mios.toml SSOT...
set "ssot_env=%TEMP%\mios-cat-ssot.cmd"
del "%ssot_env%" /q >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -Raw -LiteralPath '%toml_path%'; $q=[char]34; function G([string]$k){ $m=[regex]::Match($t, ('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:'+$q+'([^'+$q+'\r\n]*)'+$q+'|(\d+)|(true|false))')); if($m.Success){ if($m.Groups[1].Value){ $m.Groups[1].Value -replace '\\\\','\' } elseif($m.Groups[2].Value){ $m.Groups[2].Value } else { $m.Groups[3].Value } } }; function GS([string]$sec,[string]$k){ $sm=[regex]::Match($t, ('(?ms)^\s*\['+[regex]::Escape($sec)+'\]\s*(.*?)(?=\r?\n\s*\[|\Z)')); if($sm.Success){ $m=[regex]::Match($sm.Groups[1].Value, ('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:'+$q+'([^'+$q+'\r\n]*)'+$q+'|(\d+)|(true|false))')); if($m.Success){ if($m.Groups[1].Value){ $m.Groups[1].Value -replace '\\\\','\' } elseif($m.Groups[2].Value){ $m.Groups[2].Value } else { $m.Groups[3].Value } } } }; $map=[ordered]@{ drivepath='drivepath'; medicatver='medicatver'; ventoy_ver='ventoy_version'; file='cache_path'; bg_color='bg'; fg_color='fg'; accent_color='accent'; cursor_color='cursor'; success_color='success'; muted_color='muted'; subtle_color='subtle'; live_chat_enabled='live_chat_enabled'; live_chat_iso_name='live_chat_iso_name'; live_chat_iso_src='live_chat_iso_src'; monitor_enabled='monitor_enabled'; show_live_monitor='show_live_monitor' }; $o=New-Object System.Collections.Generic.List[string]; foreach($e in $map.GetEnumerator()){ $v=G $e.Value; if($v){ $o.Add('set '+$q+$e.Key+'='+$v+$q) } }; $mg=G 'min_disk_gb'; if($mg){ $o.Add('set '+$q+'min_disk_gb='+$mg+$q) }; $rl=GS 'cat.repo_partition' 'label'; if($rl){ $o.Add('set '+$q+'repo_label='+$rl+$q) }; $dl=GS 'cat.data_partition' 'label'; if($dl){ $o.Add('set '+$q+'data_label='+$dl+$q) }; if($o.Count){ Set-Content -LiteralPath '%ssot_env%' -Value $o -Encoding ascii }" 2>nul
if exist "%ssot_env%" call "%ssot_env%"
if exist "%ssot_env%" del "%ssot_env%" /q >nul 2>&1
:no_toml

:: Self-Update Check
if not "%NONINTERACTIVE%"=="1" (
    echo Checking for script updates...
    powershell -NoProfile -Command "try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
    if errorlevel 0 (
        cd /d "C:\MiOS" >nul 2>&1
        if errorlevel 0 (
            git fetch >nul 2>&1
            for /f "usebackq tokens=*" %%a in (`git status -uno 2^>nul ^| findstr /C:"behind"`) do (
                echo Updates detected in MiOS repository. Pulling latest version...
                git pull >nul 2>&1
            )
        )
        cd /d "C:\mios-bootstrap" >nul 2>&1
        if errorlevel 0 (
            git fetch >nul 2>&1
            for /f "usebackq tokens=*" %%a in (`git status -uno 2^>nul ^| findstr /C:"behind"`) do (
                echo Updates detected in mios-bootstrap repository. Pulling latest version...
                git pull >nul 2>&1
            )
        )
        cd /d "%maindir%"
    ) else (
        echo OFFLINE: Skipping self-update check.
    )
)

:: Call Preflight Checks
call :run_preflight_checks
if %errorlevel% neq 0 (
    echo FAIL: Preflight checks failed! Exiting...
    if not "%NONINTERACTIVE%"=="1" pause
    exit /b 1
)

:: Ensure 7z helper availability (local bin, system PATH, or default installs)
if not exist bin md bin >nul 2>&1
if not exist bin\7z.exe (
    if exist "C:\Program Files\7-Zip\7z.exe" (
        copy "C:\Program Files\7-Zip\7z.exe" bin\7z.exe >nul 2>&1
        if exist "C:\Program Files\7-Zip\7z.dll" copy "C:\Program Files\7-Zip\7z.dll" bin\7z.dll >nul 2>&1
    ) else (
        echo Downloading 7z helper...
        curl.exe -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.exe" -o ./bin/7z.exe 2>nul || powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.exe' -OutFile './bin/7z.exe' -UseBasicParsing -Headers @{'User-Agent'='MiOS-Cat'}" >nul 2>&1
        curl.exe -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.dll" -o ./bin/7z.dll 2>nul || powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.dll' -OutFile './bin/7z.dll' -UseBasicParsing -Headers @{'User-Agent'='MiOS-Cat'}" >nul 2>&1
    )
)

set "partition_scheme=GPT"
set "filesystem=NTFS"
set "secure_boot=Enabled"
set "extract_mode=Surgical"
set "pa_theme=Dark"
set "build_xbox=Enabled"
:: Default OFF: bake NO host-specific drivers. The MiOS-Xbox image ships with PURE Windows
:: inbox/base drivers for GLOBAL all-platform support -- baking the build host's own drivers
:: (dism /Online /Export-Driver, below) would tie the universal image to that one machine's
:: hardware, the opposite of what we want. The universal VM drivers (virtio + ivshmem for
:: Looking-Glass) are injected separately by New-MiOSISO and always ship. Operator can still
:: toggle this on for a hardware-specific build via the Xbox config menu.
set "bake_drivers=Disabled"
set "uup_channel=Dev"
set "gaming_optimize=Enabled"
set "partition_label=MiOS-Cat"
set "force_format=Enabled"

:: ------------------------------------------------------------------
:: mios-install.ps1 is the sole unified interface for the project.
:: MiOS-Cat.bat is now strictly the USB flash executor.
:: ------------------------------------------------------------------
goto start_install

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
set "confirm="
if "%NONINTERACTIVE%"=="1" set "confirm=Y"
if not "%NONINTERACTIVE%"=="1" set /p "confirm=Are you sure you want to format %drivepath%: and install? (Y/N): "
if /i "%confirm%"=="y" set "confirm=Y"
if /i "%confirm%"=="yes" set "confirm=Y"
if /i "%confirm%"=="1" set "confirm=Y"
if not "%confirm%"=="Y" (
    echo Installation cancelled.
    exit /b 1
)

:: Ensure target drive exists
set "log_file=C:\Windows\Temp\mios-cat-install.log"
echo [START] MiOS-Cat Flash Execution Started at %DATE% %TIME% > "%log_file%"

if not exist "%drivepath%:\" (
    echo ERROR: Target drive %drivepath%: was not found! | tee -a "%log_file%" 2>nul
    echo Please insert your USB drive and ensure it is mounted as %drivepath%:\
    if not "%NONINTERACTIVE%"=="1" pause
    exit /b 1
)

:: Full visible monitor defaults to ON (SSOT cat.monitor_enabled = true / show_live_monitor = true)
setlocal enabledelayedexpansion
if not "%monitor_enabled%"=="false" if not "%show_live_monitor%"=="false" (
    echo Launching live interactive monitor on user desktop...
    set "py_exe=python.exe"
    if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "py_exe=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
    if not "!mon_py!"=="" (
        start "MiOS Monitor" "%py_exe%" "!mon_py!"
    )
)
endlocal

:: 4. Download Ventoy bootloader -- newest upstream GLOBALLY
echo Checking Ventoy files...
if not exist "%stage_dir%\Ventoy2Disk" call :resolve_ventoy_latest
if not exist "%stage_dir%\Ventoy2Disk" if not defined ventoy_ver (
    echo.
    echo FAIL: Could not resolve a Ventoy version: no network to reach GitHub, no
    echo        build-recorded pin in cat:.ventoy_version, and no Ventoy staged.
    exit /b 1
)
if not exist "%stage_dir%\Ventoy2Disk" (
    echo Downloading Ventoy %ventoy_ver% ^(newest upstream^) windows release...
    curl -s -L "https://github.com/ventoy/Ventoy/releases/download/v%ventoy_ver%/ventoy-%ventoy_ver%-windows.zip" -o "%stage_dir%\ventoy.zip"
    "%maindir%\bin\7z.exe" x "%stage_dir%\ventoy.zip" -o"%stage_dir%" -aoa >nul
    for /d %%V in ("%stage_dir%\ventoy-*") do ren "%%V" Ventoy2Disk
    del "%stage_dir%\ventoy.zip" /Q >nul 2>&1
    if not exist "%stage_dir%\Ventoy2Disk\Ventoy2Disk.exe" (
        echo FAIL: Ventoy %ventoy_ver% download/extract failed -- no Ventoy2Disk.exe present.
        exit /b 1
    )
)

:: 5. Prepare Localhost AIO Staging Directory
set "aio_stage=%stage_dir%\AIO_Stage"
if exist "%aio_stage%" rmdir "%aio_stage%" /S /Q >nul 2>&1
mkdir "%aio_stage%\Live_Operating_Systems\Mini_Windows" >nul 2>&1
mkdir "%aio_stage%\Live_Operating_Systems\SystemRescue" >nul 2>&1

echo.
echo ==========================================================
echo    PHASE 1: ALL-IN-ONE (AIO) LOCALHOST STAGING AND COMPILATION
echo ==========================================================
echo Staging and compiling all images on localhost SSD: %aio_stage%
echo Zero USB writes until ALL images pass fail-fast verification!
echo ==========================================================
echo.

:: 6. Pull/Download Medicat core archive to M:\
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
    echo Pulling/Resuming core Medicat files 23 GB from CDN to %file%...
    curl.exe -C - -e "https://installer.medicatusb.com" -L "https://cat.tcbl.dev/MediCat.USB.v21.12.7z" -o "%file%" -#
) else (
    echo OK: Core Medicat archive found and complete at %file%
)

:: 6b. Extract WIM payload & PortableApps suite to Localhost AIO Stage
echo Extracting Mini_Windows WIM and PortableApps suite from core archive to Localhost SSD...
"%maindir%\bin\7z.exe" x "%file%" -o"%aio_stage%" "Live_Operating_Systems/Mini_Windows/*" "PortableApps/*" -mmt=on -aoa -y >nul

:: 6c. Pull/Download Fedora Server DVD
set "fedora_ver=44"
set "fedora_build=-1.7"
set "fedora_file=M:\Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso"
if exist "%fedora_file%" (
    echo OK: Fedora Server DVD found at "%fedora_file%"
) else (
    echo Pulling FULL Fedora %fedora_ver% Server DVD ~2.5 GB...
    curl.exe -C - -L "https://download.fedoraproject.org/pub/fedora/linux/releases/%fedora_ver%/Server/x86_64/iso/Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso" -o "%fedora_file%" -#
)
copy "%fedora_file%" "%aio_stage%\Live_Operating_Systems\Fedora-Server.iso" /Y >nul

:: 6d. Ensure SystemRescue Arch Linux ISO is staged with LATEST upstream version
set "sysrescue_ver=13.01"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0get_sysrescue_ver.ps1" >nul 2>&1
if exist "%TEMP%\sysrescue_ver.txt" (
    for /f "usebackq delims=" %%i in ("%TEMP%\sysrescue_ver.txt") do set "sysrescue_ver=%%i"
    del "%TEMP%\sysrescue_ver.txt" /q >nul 2>&1
)
set "sysrescue_local=%aio_stage%\Live_Operating_Systems\SystemRescue\SystemRescue.iso"
set "sysrescue_cache=M:\systemrescue-%sysrescue_ver%-amd64.iso"
if exist "%sysrescue_cache%" (
    copy "%sysrescue_cache%" "%sysrescue_local%" /Y >nul 2>&1
)
if not exist "%sysrescue_local%" (
    echo Pulling SystemRescue %sysrescue_ver% - LATEST upstream release...
    curl.exe -C - -L --connect-timeout 10 --retry 3 "https://fastly-cdn.system-rescue.org/releases/%sysrescue_ver%/systemrescue-%sysrescue_ver%-amd64.iso" -o "%sysrescue_cache%" -#
    if exist "%sysrescue_cache%" copy "%sysrescue_cache%" "%sysrescue_local%" /Y >nul 2>&1
)
if not exist "%sysrescue_local%" (
    echo Fallback: Pulling SystemRescue %sysrescue_ver% from SourceForge...
    curl.exe -C - -L --connect-timeout 10 --retry 3 "https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/%sysrescue_ver%/systemrescue-%sysrescue_ver%-amd64.iso" -o "%sysrescue_local%" -#
)
if not exist "%sysrescue_local%" (
    echo FATAL ERROR: SystemRescue ISO download failed! & exit /b 1
)

:: 7. Perform Localhost Offline DISM Servicing on MiOS_PE.wim (Zero USB mounting!)
set "wim_path=%aio_stage%\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim"
if not exist "%wim_path%" (
    if exist "%aio_stage%\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" (
        move "%aio_stage%\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" "%wim_path%" >nul
    )
)

if not exist "%wim_path%" (
    echo FATAL ERROR: Required WIM image file not found at %wim_path%!
    exit /b 1
)

echo Performing offline DISM servicing on Localhost WIM image: %wim_path%
reg unload HKEY_USERS\pe-default >nul 2>&1
reg unload HKEY_USERS\pe-software >nul 2>&1
dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
dism /Cleanup-Wim >nul 2>&1
powershell -NoProfile -Command "Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mount*' -or $_.ImagePath -like '*MiOS_PE.wim*' } | ForEach-Object { Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue }" >nul 2>&1
dism /Cleanup-Wim >nul 2>&1
if exist "%stage_dir%\mount" rmdir "%stage_dir%\mount" /S /Q >nul 2>&1
mkdir "%stage_dir%\mount" >nul 2>&1

echo Mounting WIM image on Localhost SSD (%stage_dir%\mount)...
dism /Mount-Image /ImageFile:"%wim_path%" /Index:1 /MountDir:"%stage_dir%\mount"
if %errorlevel% neq 0 (
    echo WARN: DISM mount failed, retrying after DISM cleanup...
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    dism /Cleanup-Wim >nul 2>&1
    ping localhost -n 4 >nul
    dism /Mount-Image /ImageFile:"%wim_path%" /Index:1 /MountDir:"%stage_dir%\mount"
)
if %errorlevel% neq 0 (
    echo FATAL ERROR: DISM failed to mount %wim_path% with exit code %errorlevel%!
    dism /Cleanup-Wim >nul 2>&1
    exit /b %errorlevel%
)

if "%bake_drivers%"=="Enabled" (
    echo DRIVER BAKE: Exporting build-host drivers for WinPE injection...
    mkdir "%stage_dir%\hostdrivers" >nul 2>&1
    dism /Online /Export-Driver /Destination:"%stage_dir%\hostdrivers"
    if %errorlevel% neq 0 (
        echo FATAL ERROR: DISM Export-Driver failed!
        dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
        exit /b %errorlevel%
    )
    dism /Image:"%stage_dir%\mount" /Add-Driver /Driver:"%stage_dir%\hostdrivers" /Recurse /ForceUnsigned
    if %errorlevel% neq 0 (
        echo FATAL ERROR: DISM Add-Driver failed!
        dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
        exit /b %errorlevel%
    )
    rmdir /s /q "%stage_dir%\hostdrivers" >nul 2>&1
)

echo Injecting custom wallpaper, Geist Mono font, and Console colors into WIM...
set "wallpaper_src="
if exist "%maindir%\resources\theme\uefi\background.jpg" set "wallpaper_src=%maindir%\resources\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" if exist "%~dp0..\resources\theme\uefi\background.jpg" set "wallpaper_src=%~dp0..\resources\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" if exist "D:\ventoy\theme\uefi\background.jpg" set "wallpaper_src=D:\ventoy\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" (
    echo FATAL ERROR: background.jpg missing!
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    exit /b 1
)

takeown /f "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /a >nul 2>&1
icacls "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /grant administrators:F >nul 2>&1
copy "%wallpaper_src%" "%stage_dir%\mount\Windows\Web\Wallpaper\Windows\img0.jpg" /Y >nul
copy "%wallpaper_src%" "%stage_dir%\mount\Windows\System32\winpe.jpg" /Y >nul
copy "%wallpaper_src%" "%stage_dir%\mount\Windows\System32\winre.jpg" /Y >nul
copy "%wallpaper_src%" "%stage_dir%\mount\Windows\Web\Screen\img100.jpg" /Y >nul

set "font_src="
if exist "C:\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" set "font_src=C:\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf"
if "%font_src%"=="" if exist "%maindir%\resources\fonts\GeistMonoNerdFontMono-Regular.otf" set "font_src=%maindir%\resources\fonts\GeistMonoNerdFontMono-Regular.otf"
if "%font_src%"=="" if exist "%~dp0..\resources\fonts\GeistMonoNerdFontMono-Regular.otf" set "font_src=%~dp0..\resources\fonts\GeistMonoNerdFontMono-Regular.otf"
if "%font_src%"=="" (
    echo FATAL ERROR: GeistMono font missing!
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    exit /b 1
)
copy "%font_src%" "%stage_dir%\mount\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" /Y >nul

reg unload HKEY_USERS\pe-default >nul 2>&1
reg unload HKEY_USERS\pe-software >nul 2>&1
reg load HKEY_USERS\pe-default "%stage_dir%\mount\Windows\System32\config\DEFAULT" >nul 2>&1
if %errorlevel% neq 0 (
    echo FATAL ERROR: Failed to load DEFAULT hive!
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    exit /b 1
)
reg load HKEY_USERS\pe-software "%stage_dir%\mount\Windows\System32\config\SOFTWARE" >nul 2>&1
if %errorlevel% neq 0 (
    echo FATAL ERROR: Failed to load SOFTWARE hive!
    reg unload HKEY_USERS\pe-default >nul 2>&1
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    exit /b 1
)

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

reg unload HKEY_USERS\pe-default >nul 2>&1
reg unload HKEY_USERS\pe-software >nul 2>&1
powershell -NoProfile -Command "[System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()" >nul 2>&1
ping localhost -n 3 >nul

echo Committing changes and unmounting Localhost WIM image...
dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Commit
if %errorlevel% neq 0 (
    echo Retrying WIM unmount commit...
    ping localhost -n 4 >nul
    reg unload HKEY_USERS\pe-default >nul 2>&1
    reg unload HKEY_USERS\pe-software >nul 2>&1
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Commit
)
if %errorlevel% neq 0 (
    echo FATAL ERROR: Failed to unmount and commit Localhost WIM image!
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    dism /Cleanup-Wim >nul 2>&1
    exit /b 1
)
if exist "%stage_dir%\mount" rmdir "%stage_dir%\mount" /S /Q >nul 2>&1

echo Exporting and compressing Localhost MiOS_PE.wim...
set "trim_path=%aio_stage%\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim"
dism /Export-Image /SourceImageFile:"%wim_path%" /SourceIndex:1 /DestinationImageFile:"%trim_path%" /Compress:max
if %errorlevel% neq 0 (
    echo FATAL ERROR: DISM Export-Image failed!
    exit /b %errorlevel%
)
del "%wim_path%" /Q >nul 2>&1
move "%trim_path%" "%wim_path%" >nul

mkdir "%aio_stage%\MiOS-PE" >nul 2>&1
copy "%wim_path%" "%aio_stage%\MiOS-PE\MiOS_PE.wim" /Y >nul 2>&1
mkdir "%aio_stage%\Documents" >nul 2>&1
if exist "%toml_path%" copy "%toml_path%" "%aio_stage%\Documents\mios.toml" /Y >nul 2>&1

:: 8. Compile MiOS-Xbox ISO on Localhost SSD
if "%build_xbox%"=="Enabled" call :compile_xbox_iso
if errorlevel 1 exit /b 1

:: 9. Stage Live-Chat ISO if available
if "%live_chat_iso_src%"=="" set "live_chat_iso_src=M:\MiOS-Live-Chat.iso"
if exist "%live_chat_iso_src%" (
    copy "%live_chat_iso_src%" "%aio_stage%\Live_Operating_Systems\MiOS-Live-Chat.iso" /Y >nul 2>&1
)

:: 10. FAIL FAST VERIFICATION GATE (Check all compiled images before touching USB drive)
echo.
echo Checking AIO compiled images verification gate...
if not exist "%aio_stage%\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" (
    echo FATAL ERROR: AIO verification failed: MiOS_PE.wim missing from stage! & exit /b 1
)
if "%build_xbox%"=="Enabled" (
    if not exist "%aio_stage%\Live_Operating_Systems\MiOS-Xbox.iso" (
        echo FATAL ERROR: AIO verification failed: MiOS-Xbox.iso missing from stage! & exit /b 1
    )
)
if not exist "%aio_stage%\Live_Operating_Systems\SystemRescue\SystemRescue.iso" (
    echo FATAL ERROR: AIO verification failed: SystemRescue.iso missing from stage! & exit /b 1
)
echo [AIO] All required images are PRESENT on localhost SSD (existence-checked only).
echo [AIO] NOTE: image CONTENT / provisioning is NOT asserted here -- boot or mount-inspect to verify the bake actually applied (logs can lie).

echo.
echo ==========================================================
echo    PHASE 2: TARGET DRIVE FORMAT ^& SINGLE-PASS FLASH WRITE
echo ==========================================================
echo Target Drive: %drivepath%:
echo ==========================================================
echo.

set "flash_log=%TEMP%\mios-cat-flash.log"
set "flash_marker=%TEMP%\mios-cat-flash.marker"
del "%flash_marker%" /q >nul 2>&1
echo [INFO] Starting MiOS-Cat USB flash operations... > "%flash_log%"

if /i "%MIOS_NO_MONITOR%"=="1" goto skip_monitor
if /i "%MIOS_UNIFIED%"=="1" goto skip_monitor
if /i "%MIOS_HEADLESS%"=="1" goto skip_monitor

echo Spawning live graphical MiOS Flash Monitor...
if exist "C:\MiOS\usr\libexec\mios\MiOS-Mon.py" (
    set "py_exe=python.exe"
    if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "py_exe=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
    start "MiOS Monitor" "%py_exe%" "C:\MiOS\usr\libexec\mios\MiOS-Mon.py"
)
:skip_monitor

:: 11. Format & Initialize Target USB Drive
echo Formatting and merging all USB partitions back to a single disk letter (%drivepath%:)...
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% -ErrorAction SilentlyContinue | Get-Disk; if ($d) { Get-Partition -DiskNumber $d.Number | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue; Initialize-Disk -Number $d.Number -PartitionStyle GPT -ErrorAction SilentlyContinue; $p = New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter %drivepath% -ErrorAction SilentlyContinue; if ($p) { Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel 'MiOS-Cat' -Confirm:$false | Out-Null }; Update-HostStorageCache }" >nul 2>&1

set "vtoy_reserve_mb=4096"
set "mios_repo_gb=0"
set "mios_make_data=0"
for /f "usebackq tokens=1,2,3 delims=," %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Partition -DriveLetter '%drivepath%' -ErrorAction SilentlyContinue; $disk = if ($p) { Get-Disk -Number $p.DiskNumber } else { Get-Disk | Where-Object { $_.BusType -in 'USB','SD' } | Sort-Object Size -Descending | Select-Object -First 1 }; if ($disk) { $g=[math]::Floor($disk.Size/1GB); $ventoy=64; $repo=1; $minGB=[int]'%min_disk_gb%'; if ($g -ge $minGB) { $rsv=($g-$ventoy)*1024; $mk=1 } else { $rsv=4096; $repo=0; $mk=0 }; Write-Output ('' + $rsv + ',' + $repo + ',' + $mk) }"`) do (
    set "vtoy_reserve_mb=%%a"
    set "mios_repo_gb=%%b"
    set "mios_make_data=%%c"
)

echo Installing Ventoy bootloader to %drivepath%:...
cd /d "%stage_dir%\Ventoy2Disk"
set "vtoy_args=/I /Drive:%drivepath%: /%partition_scheme% /R:%vtoy_reserve_mb% /y"
if "%secure_boot%"=="Enabled" ( set "vtoy_args=%vtoy_args% /S" ) else ( set "vtoy_args=%vtoy_args% /NOUSBCheck" )
Ventoy2Disk.exe VTOYCLI %vtoy_args%
if errorlevel 1 ( echo [FATAL ERROR] Ventoy install failed! & exit /b 1 )
cd /d "%maindir%"

echo Waiting 5s for partition remount...
ping localhost -n 6 >nul
powershell -NoProfile -Command "Format-Volume -DriveLetter %drivepath% -FileSystem %filesystem% -AllocationUnitSize 65536 -NewFileSystemLabel '%partition_label%' -Confirm:$false -Force | Out-Null" >nul 2>&1

echo Creating secure offline repository partition (%repo_label%)...
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% | Get-Disk; if ('%mios_make_data%' -eq '1') { $rp = New-Partition -DiskNumber $d.Number -Size %mios_repo_gb%GB -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null }; $dp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($dp) { Format-Volume -Partition $dp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%data_label%' -Confirm:$false | Out-Null } } else { $rp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null } }" >nul 2>&1

:: 12. Multithreaded extraction of Medicat payload
set "SURGICAL_LIST=System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/CrystalDiskMarkPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstaller/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* PortableApps/SDIO_*/* PortableApps/SDI_*/* PortableApps/SDI/* Programs/7-Zip_x64/* Programs/Bootice/* Programs/DiskGeniusLite/* Programs/Everything_x64/* Programs/WizTree/* Programs/HDSentinel/* Programs/Sysinternals/* Programs/ventoy/* Programs/SDIO/* Programs/SnappyDriverInstaller/* Programs/SnappyDriverInstallerOrigin/*"
echo Extracting payload to %drivepath%: (-mmt=on)...
"%maindir%\bin\7z.exe" x "%file%" -o%drivepath%:\ %SURGICAL_LIST% -mmt=on -aoa -y >nul

:: 13. Apply custom MiOS templates, PortableApps & shadow-config brain
attrib -r -h -s "%drivepath%:\autorun.inf" >nul 2>&1
attrib -r -h -s "%drivepath%:\autorun\*" /S /D >nul 2>&1
attrib -r -h -s "%drivepath%:\ventoy\*" /S /D >nul 2>&1
xcopy "%maindir%\resources\ventoy" "%drivepath%:\ventoy\" /E /I /H /Y /Q >nul
xcopy "%maindir%\resources\theme" "%drivepath%:\ventoy\theme\" /E /I /H /Y /Q >nul
mkdir "%drivepath%:\autorun" >nul 2>&1
if exist "%maindir%\resources\autorun" xcopy "%maindir%\resources\autorun" "%drivepath%:\autorun\" /E /I /H /Y /Q >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun.sh" /Y >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun\autorun.sh" /Y >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun\autorun" /Y >nul
copy "%maindir%\resources\CdUsb.Y" "%drivepath%:\CdUsb.Y" /Y >nul

for /f "usebackq tokens=1,2 delims=," %%a in (`powershell -NoProfile -Command "$rp=(Get-Volume -FileSystemLabel '%repo_label%' -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter; $dp=(Get-Volume -FileSystemLabel '%data_label%' -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter; if (-not $rp) { $rp='_' }; if (-not $dp) { $dp='_' }; Write-Output ($rp + ',' + $dp)"`) do (
    set "repodrive=%%a"
    set "datadrive=%%b"
)
if "%repodrive%"=="_" set "repodrive=%drivepath%"
if "%datadrive%"=="_" set "datadrive=%repodrive%"
if "%repodrive%"=="" set "repodrive=%drivepath%"
if "%datadrive%"=="" set "datadrive=%repodrive%"

echo Staging offline repositories to the %repo_label% vault (%repodrive%:)...
mkdir "%repodrive%:\repos\mios-bootstrap" >nul 2>&1
robocopy "C:\mios-bootstrap" "%repodrive%:\repos\mios-bootstrap" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 /MT:32 >nul
mkdir "%repodrive%:\repos\MiOS" >nul 2>&1
robocopy "C:\MiOS" "%repodrive%:\repos\MiOS" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 /MT:32 >nul

echo Staging shadow-config brain to %repo_label% (%repodrive%:)...
if exist "%toml_path%" copy "%toml_path%" "%repodrive%:\mios.toml" /Y >nul 2>&1
copy "%~f0" "%repodrive%:\MiOS-Cat.bat" /Y >nul 2>&1

echo Staging MiOS drive icons and autorun.inf across all partitions...
if exist "%~dp0..\cat\resources\autorun\mios-stage-icons.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\cat\resources\autorun\mios-stage-icons.ps1" -CatDrive "%drivepath%" -RepoDrive "%repodrive%" -DataDrive "%datadrive%" >nul 2>&1
)

if exist "%drivepath%:\PortableApps" (
    echo Debloating PortableApps suite to MiOS specifications...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$keep = @('7-ZipPortable', 'AOMEIPartitionAssistantPortable', 'CrystalDiskInfoPortable', 'CrystalDiskMarkPortable', 'HWiNFOPortable', 'Notepad++Portable', 'Rufus', 'WizTree', 'SnappyDriverInstaller', 'SnappyDriverInstallerOrigin', 'SDIO', 'SDIO_x64', 'SDI_x64', 'SDI', 'PortableApps.com', 'MiOSInstaller', 'MiOSMonitor', 'MiOSSystemRescue', 'SoftwareLister'); $targets = @('%drivepath%:\PortableApps', '%aio_stage%\PortableApps'); foreach ($t in $targets) { if (Test-Path -LiteralPath $t) { Get-ChildItem -LiteralPath $t -Directory | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }" >nul 2>&1
    echo Applying MiOSTheme branding to PortableApps Menu...
    if exist "%~dp0..\cat\resources\autorun\apply-mios-pa-theme.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\cat\resources\autorun\apply-mios-pa-theme.ps1" -TargetDrive "%drivepath%" >nul 2>&1
    )
)

:: 14. SINGLE-PASS FLASH WRITE: Copy all compiled AIO images to target drive D: in one go!
echo.
echo ==========================================================
echo   SINGLE FLASH PASS: WRITING ALL AIO IMAGES TO USB (%drivepath%:)
echo ==========================================================
mkdir "%drivepath%:\Live_Operating_Systems" >nul 2>&1
robocopy "%aio_stage%\Live_Operating_Systems" "%drivepath%:\Live_Operating_Systems" /E /R:2 /W:2 /MT:32
if errorlevel 8 (
    echo FATAL ERROR: Robocopy failed to write AIO images to %drivepath%:\Live_Operating_Systems!
    exit /b 1
)

if exist "%aio_stage%\PortableApps" (
    echo Writing PortableApps suite to USB %drivepath%:\PortableApps:...
    mkdir "%drivepath%:\PortableApps" >nul 2>&1
    robocopy "%aio_stage%\PortableApps" "%drivepath%:\PortableApps" /E /R:2 /W:2 /MT:32
    if errorlevel 8 (
        echo FATAL ERROR: Robocopy failed to write PortableApps to %drivepath%:\PortableApps!
        exit /b 1
    )
    echo Debloating PortableApps suite to MiOS specifications...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$keep = @('7-ZipPortable', 'AOMEIPartitionAssistantPortable', 'CrystalDiskInfoPortable', 'CrystalDiskMarkPortable', 'HWiNFOPortable', 'Notepad++Portable', 'Rufus', 'WizTree', 'SnappyDriverInstallerOrigin', 'SDIO', 'PortableApps.com'); $targets = @('%drivepath%:\PortableApps', '%aio_stage%\PortableApps'); foreach ($t in $targets) { if (Test-Path -LiteralPath $t) { Get-ChildItem -LiteralPath $t -Directory | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }" >nul 2>&1
    echo Applying MiOSTheme branding to PortableApps Menu...
    if exist "%~dp0..\cat\resources\autorun\apply-mios-pa-theme.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\cat\resources\autorun\apply-mios-pa-theme.ps1" -TargetDrive "%drivepath%" >nul 2>&1
    )
)

if exist "%aio_stage%\MiOS-PE" (
    echo Writing MiOS-PE rescue directory to USB %drivepath%:\MiOS-PE:...
    mkdir "%drivepath%:\MiOS-PE" >nul 2>&1
    robocopy "%aio_stage%\MiOS-PE" "%drivepath%:\MiOS-PE" /E /R:2 /W:2 /MT:32 >nul
)

if exist "%aio_stage%\Documents" (
    echo Writing Documents vault to USB %drivepath%:\Documents:...
    mkdir "%drivepath%:\Documents" >nul 2>&1
    robocopy "%aio_stage%\Documents" "%drivepath%:\Documents" /E /R:2 /W:2 /MT:32 >nul
)

:: 15. Finalize SSOT Branding & Start.exe launcher
echo Finalizing SSOT MiOS drive icons and autorun metadata across target partitions...
if exist "%~dp0..\cat\resources\autorun\mios-stage-icons.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\cat\resources\autorun\mios-stage-icons.ps1" -CatDrive "%drivepath%" -RepoDrive "%repodrive%" -DataDrive "%datadrive%" >nul 2>&1
)

set "ico_file="
if exist "%drivepath%:\autorun\icon.ico" set "ico_file=%drivepath%:\autorun\icon.ico"
if "%ico_file%"=="" if exist "%drivepath%:\autorun\mios-v2.ico" set "ico_file=%drivepath%:\autorun\mios-v2.ico"
if "%ico_file%"=="" if exist "%drivepath%:\autorun\mios.ico" set "ico_file=%drivepath%:\autorun\mios.ico"
if "%ico_file%"=="" if exist "%maindir%\resources\icon.ico" (
    copy "%maindir%\resources\icon.ico" "%drivepath%:\autorun\icon.ico" /Y >nul 2>&1
    copy "%maindir%\resources\icon.ico" "%drivepath%:\icon.ico" /Y >nul 2>&1
    set "ico_file=%drivepath%:\autorun\icon.ico"
)

echo using System; using System.Diagnostics; using System.IO; class Launcher { static void Main() { string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "PortableApps\\PortableApps.com\\PortableAppsPlatform.exe"); if (File.Exists(path)) { Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true }); } } } > "%temp%\launcher.cs"

if exist "%drivepath%:\Start.exe" attrib -r -h -s "%drivepath%:\Start.exe" >nul 2>&1
if exist "%drivepath%:\Start.exe" del /f /q /a "%drivepath%:\Start.exe" >nul 2>&1

if not "%ico_file%"=="" (
    C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:"%ico_file%" /out:"%drivepath%:\Start.exe" "%temp%\launcher.cs" >nul 2>&1
)
del "%temp%\launcher.cs" /Q >nul 2>&1

if exist "%flash_marker%" ( echo SUCCESS > "%flash_marker%" ) else if defined TEMP ( echo SUCCESS > "%TEMP%\mios-cat-flash.marker" )

echo.
echo ==========================================================
echo     MiOS-Cat ALL-IN-ONE USB FLASHING SUCCESSFULLY COMPLETED
echo ==========================================================
echo All images were compiled on localhost SSD and written in one pass.
echo Target drive %drivepath%: is now ready to boot!
echo ==========================================================
if not "%NONINTERACTIVE%"=="1" pause
goto :eof

:run_preflight_checks
echo.
echo ==========================================================
echo               RUNNING PREFLIGHT CHECKS
echo ==========================================================

:: 1. Admin privilege check
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo FAIL: Administrator privileges required. Please run this script as Admin.
    exit /b 1
)
echo [PASS] Administrator privileges verified.

:: 2. Target Disk Safety Check (Ensure D: is not an internal drive)
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% -ErrorAction SilentlyContinue | Get-Disk; if ($d) { if ($d.IsBoot -or $d.IsSystem) { exit 2 } }; exit 0"
set "disk_check=%errorlevel%"
if %disk_check% equ 2 (
    echo FAIL: Target drive %drivepath%: is the Windows System/Boot drive! Formatting OS drive is blocked.
    echo        Please specify a non-boot target drive letter.
    exit /b 1
)
echo [PASS] Target drive %drivepath%: safety check completed.

:: 3. Storage Space Check on Cache drive (Ensure at least 25GB free)
if not exist "%file%" (
    powershell -NoProfile -Command "$cacheDrive = Split-Path -Path '%file%' -Qualifier; $v = Get-Volume -DriveLetter $cacheDrive.Trim(':') -ErrorAction SilentlyContinue; if ($v -and $v.SizeRemaining -lt 25GB) { exit 1 }; exit 0"
    if errorlevel 1 (
        echo FAIL: Insufficient disk space on cache drive to download Medicat - 25GB required.
        exit /b 1
    )
    echo PASS: Cache drive storage space verified.
)

:: 4. Dependency checks (git, curl)
where git >nul 2>&1
if %errorlevel% neq 0 (
    echo FAIL: Git is missing from system PATH.
    exit /b 1
)
where curl >nul 2>&1
if %errorlevel% neq 0 (
    echo FAIL: Curl is missing from system PATH.
    exit /b 1
)
echo [PASS] System dependencies (git, curl) verified.
echo ==========================================================
echo.
exit /b 0

:check_drive_ready
if not exist "%drivepath%:\CdUsb.Y" (
    echo.
    echo WARNING: USB drive %drivepath%: is temporarily busy or disconnected.
    echo Waiting 3 seconds for link remount...
    ping localhost -n 4 >nul
    if not exist "%drivepath%:\CdUsb.Y" (
        echo ERROR: USB drive %drivepath%: is missing.
        echo Please ensure the USB drive is plugged in correctly.
        if not "%NONINTERACTIVE%"=="1" pause
    )
    goto check_drive_ready
)
exit /b

:: ==================================================================
:: Helper subroutines for the on-boarding / build surfaces.
:: NOTE: the build-driver + Xbox-builder paths below have no SSOT home
:: yet -- sibling task T-258 adds a [cat] table to mios.toml. Until it
:: lands these are clearly-marked defaults; wire them to
:: [cat].build_driver / [cat].xbox_builder when that table exists.
:: ==================================================================

:detect_env
:: Populate env_host / env_net / env_builder / env_disk for Quick Start.
set "env_host=Windows host"
reg query "HKLM\System\CurrentControlSet\Control\MiniNT" >nul 2>&1
if "%errorlevel%"=="0" set "env_host=WinPE (offline servicing)"
set "env_net=Offline"
powershell -NoProfile -Command "try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { exit 0 } else { exit 1 } } catch { exit 1 }"
if "%errorlevel%"=="0" set "env_net=Online"
set "env_builder=not provisioned (Build will self-bootstrap)"
where wsl >nul 2>&1
if "%errorlevel%"=="0" set "env_builder=WSL2 present"
set "env_disk=no removable USB detected"
for /f "usebackq tokens=*" %%d in (`powershell -NoProfile -Command "if (Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }) { 'removable USB present' } else { 'no removable USB detected' }"`) do set "env_disk=%%d"
goto :eof

:resolve_bootstrap_root
:: Offline-first: prefer the mios-bootstrap tree THIS launcher runs
:: under (USB MiOS-Repo or C:), then the standard dev checkout, then
:: any staged MiOS-Repo partition holding the payload.
set "bootstrap_root="
if exist "%~dp0..\build-mios.ps1" (
    set "bootstrap_root=%~dp0.."
    goto :eof
)
if exist "C:\mios-bootstrap\build-mios.ps1" (
    set "bootstrap_root=C:\mios-bootstrap"
    goto :eof
)
for %%D in (E F G H I J K L N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\mios-bootstrap\build-mios.ps1" (
        set "bootstrap_root=%%D:\mios-bootstrap"
        goto :eof
    )
    if exist "%%D:\repos\mios-bootstrap\build-mios.ps1" (
        set "bootstrap_root=%%D:\repos\mios-bootstrap"
        goto :eof
    )
)
goto :eof

:resolve_ventoy_latest
:: MiOS targets newest upstream GLOBALLY + never hand-pins. A "latest"/empty SSOT value is
:: an INTENT sentinel, not a pin -- neutralize it, then resolve the newest release live from
:: GitHub. On success the runtime pin wins (newest). On failure keep whatever the build
:: recorded in [cat].ventoy_version (a real version) or stay empty -> caller fails loud.
if /i "%ventoy_ver%"=="latest" set "ventoy_ver="
set "ventoy_latest="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { $h=@{'User-Agent'='MiOS-Cat'}; $r=Invoke-RestMethod -UseBasicParsing -TimeoutSec 8 -Headers $h 'https://api.github.com/repos/ventoy/Ventoy/releases/latest'; ($r.tag_name -replace '^v','') } catch { '' }"`) do set "ventoy_latest=%%i"
if defined ventoy_latest if not "%ventoy_latest%"=="" set "ventoy_ver=%ventoy_latest%"
goto :eof

:resolve_xbox_builder
:: Offline-first MiOS-Xbox builder resolution. Canonical relocated
:: path is cat\autounattend\. Prefer the one-shot self-provisioning
:: wrapper (Build-MiOSXbox.ps1), else the DISM orchestrator
:: (New-MiOSISO.ps1).
set "xbox_builder="
:: [cat].xbox_builder SSOT override (an absolute path) wins if set + present.
if exist "%toml_path%" for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "$v=(Get-Content '%toml_path%' | Select-String -Pattern '^\s*xbox_builder\s*=\s*\"(.*)\"' | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1); if ($v -and (Test-Path $v)) { $v }"`) do set "xbox_builder=%%i"
if defined xbox_builder if not "%xbox_builder%"=="" goto :eof
if exist "%~dp0..\cat\autounattend\Build-MiOSXbox.ps1" (
    set "xbox_builder=%~dp0..\cat\autounattend\Build-MiOSXbox.ps1"
    goto :eof
)
if exist "%~dp0..\cat\autounattend\New-MiOSISO.ps1" (
    set "xbox_builder=%~dp0..\cat\autounattend\New-MiOSISO.ps1"
    goto :eof
)
if exist "C:\mios-bootstrap\cat\autounattend\Build-MiOSXbox.ps1" (
    set "xbox_builder=C:\mios-bootstrap\cat\autounattend\Build-MiOSXbox.ps1"
    goto :eof
)
if exist "C:\mios-bootstrap\cat\autounattend\New-MiOSISO.ps1" (
    set "xbox_builder=C:\mios-bootstrap\cat\autounattend\New-MiOSISO.ps1"
    goto :eof
)
goto :eof

:update_repo
:: %1 = repo path, %2 = display name
if not exist "%~1\.git" (
    echo SKIP: %~2 is not a git checkout at %~1
    goto :eof
)
echo Updating %~2 at %~1 ...
cd /d "%~1"
git fetch >nul 2>&1
git pull
goto :eof

:check_drive_ready
if exist "%drivepath%:\" goto :eof
echo [WARN] Drive %drivepath%: not mounted! Attempting auto-reassign...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Where-Object BusType -eq 'USB' | Get-Partition | Where-Object Size -gt 100MB | Select-Object -First 1 | Set-Partition -NewDriveLetter '%drivepath%' -ErrorAction SilentlyContinue" >nul 2>&1
timeout /t 2 /nobreak >nul
:compile_xbox_iso
echo.
echo Compiling MiOS-Xbox Installer ISO on Localhost SSD...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\cat\autounattend\Render-MiosRunToml.ps1" -TomlPath "%toml_path%" -UupChannel "%uup_channel%" -BakeDrivers "%bake_drivers%" -GamingOptimize "%gaming_optimize%"
if errorlevel 1 ( echo [FATAL ERROR] Render-MiosRunToml failed! & exit /b 1 )

set "xbox_builder_script=%~dp0..\cat\autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" set "xbox_builder_script=%~dp0cat\autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" set "xbox_builder_script=C:\mios-bootstrap\cat\autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" ( echo [FATAL ERROR] Build-MiOSXboxISO.ps1 script missing! & exit /b 1 )

powershell.exe -ExecutionPolicy Bypass -File "%xbox_builder_script%" -TomlPath "%temp%\mios_run.toml" -OutIso "%aio_stage%\Live_Operating_Systems\MiOS-Xbox.iso" -WorkDir "%stage_dir%\isobuild_live" -SkipWsl -SkipPrereqs
if errorlevel 1 ( echo [FATAL ERROR] Build-MiOSXboxISO.ps1 failed! & exit /b 1 )
exit /b 0

:ensure_live_monitor
if /i "%MIOS_NO_MONITOR%"=="1" exit /b 0
if /i "%MIOS_UNIFIED%"=="1" exit /b 0
if /i "%MIOS_HEADLESS%"=="1" exit /b 0
if exist "C:\MiOS\usr\libexec\mios\MiOS-Mon.py" (
    set "py_exe=python.exe"
    if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "py_exe=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
    start "MiOS Monitor" "%py_exe%" "C:\MiOS\usr\libexec\mios\MiOS-Mon.py"
)
exit /b 0


