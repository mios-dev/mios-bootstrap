@echo off
title MiOS-Cat Dedicated USB Installer
cd /d %~dp0
set "maindir=%CD%"

:: Self-elevate so a plain double-click on factory-fresh Windows just works (UAC
:: prompt) instead of failing the Administrator preflight. Get-MiOS / the
:: scheduled task launch already-elevated and pass straight through this gate.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)
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
powershell -NoProfile -Command "$v = Get-Volume; $target = $null; $max = 0; foreach ($vol in $v) { if ($vol.DriveType -eq 'Fixed' -and $vol.SizeRemaining -gt 25GB -and $vol.SizeRemaining -gt $max) { $max = $vol.SizeRemaining; $target = $vol } }; $p = if ($target) { $target.DriveLetter + ':\MiOS\medicat_stage' } else { $env:TEMP + '\medicat_stage' }; [System.IO.File]::WriteAllText(\"%~dp0stage_path.txt\", $p)"
set /p stage_dir=<"%~dp0stage_path.txt"
del "%~dp0stage_path.txt" /Q >nul 2>&1
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
                echo Restarting script from updated checkout...
                start "" cmd.exe /c "%~f0" %*
                exit /b 0
            )
        )
        cd /d "C:\mios-bootstrap" >nul 2>&1
        if errorlevel 0 (
            git fetch >nul 2>&1
            for /f "usebackq tokens=*" %%a in (`git status -uno 2^>nul ^| findstr /C:"behind"`) do (
                echo Updates detected in mios-bootstrap repository. Pulling latest version...
                git pull >nul 2>&1
                echo Restarting script from updated checkout...
                start "" cmd.exe /c "%~f0" %*
                exit /b 0
            )
        )
        cd /d "%maindir%"
    ) else (
        echo [OFFLINE] Skipping self-update check.
    )
)

:: Call Preflight Checks
call :run_preflight_checks
if %errorlevel% neq 0 (
    echo [FAIL] Preflight checks failed! Exiting...
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
        curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.exe" -o ./bin/7z.exe
        curl -s -L "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/7z/64.dll" -o ./bin/7z.dll
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
:: First-run default + verb routing.  With no argument (or an unknown
:: one) MiOS-Cat opens the guided Quick Start on-boarding; the full
:: menu stays one keypress away.  Verbs map to the WS-CAT surfaces
:: (stage / build / install / update / provision / manual) so the
:: launcher and scripts can deep-link straight to an action.
:: ------------------------------------------------------------------
if /i "%~1"=="menu"      goto menu
if /i "%~1"=="build"     set "NONINTERACTIVE=1" & goto sub_build
if /i "%~1"=="stage"     set "NONINTERACTIVE=1" & goto start_install
if /i "%~1"=="install"   set "NONINTERACTIVE=1" & goto sub_deploy
if /i "%~1"=="deploy"    set "NONINTERACTIVE=1" & goto sub_deploy
if /i "%~1"=="provision" set "NONINTERACTIVE=1" & goto sub_deploy
if /i "%~1"=="update"    goto sub_update
if /i "%~1"=="config"    goto sub_config
if /i "%~1"=="manual"    goto sub_manual
if /i "%~1"=="help"      goto sub_manual
goto quickstart

:menu
cls
echo ==========================================================
echo        M i O S - C a t     Control Center
echo        Deploy . Build . Stage . Configure
echo ==========================================================
echo   Palette  bg [%bg_color%]  accent [%accent_color%]  ok [%success_color%]
echo ----------------------------------------------------------
echo   Quick Start
echo     1. On-boarding / Quick Start    (guided)
echo   Build
echo     2. Build MiOS Images            (OCI . Xbox ISO . all)
echo   Deploy
echo     3. Stage USB                    (MiOS-Repo bootable)
echo     4. Install / Deploy             (provision a target)
echo   Maintain
echo     5. Update                       (pull latest MiOS)
echo     6. Configuration                (USB . FS . theme . Xbox)
echo     7. Repository Tools             (open repos . edit TOML)
echo   Help
echo     8. Manual / Help
echo     9. Exit
echo ==========================================================
set "choice="
set /p "choice=Select an option (1-9): "

if "%choice%"=="1" goto quickstart
if "%choice%"=="2" goto sub_build
if "%choice%"=="3" goto start_install
if "%choice%"=="4" goto sub_deploy
if "%choice%"=="5" goto sub_update
if "%choice%"=="6" goto sub_config
if "%choice%"=="7" goto sub_repos
if "%choice%"=="8" goto sub_manual
if "%choice%"=="9" exit /b 0
goto menu

:sub_usb
cls
echo ==========================================================
echo               USB Target Settings
echo ==========================================================
echo   1. Target USB Drive letter  : %drivepath%:
echo   2. Format Partition Label   : %partition_label%
echo   3. Back to Configuration
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-3): "
if "%sub_choice%"=="1" goto set_drive
if "%sub_choice%"=="2" goto set_label
if "%sub_choice%"=="3" goto sub_config
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
echo   7. Force Disk Re-Format     : %force_format%
echo   8. Back to Configuration
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-8): "
if "%sub_choice%"=="1" goto set_scheme
if "%sub_choice%"=="2" goto set_fs
if "%sub_choice%"=="3" goto set_secure
if "%sub_choice%"=="4" goto set_cache
if "%sub_choice%"=="5" goto set_extract
if "%sub_choice%"=="6" goto set_pa_theme
if "%sub_choice%"=="7" goto set_force_format
if "%sub_choice%"=="8" goto sub_config
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
echo   9. Back to Configuration
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
if "%sub_choice%"=="9" goto sub_config
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
echo   5. Back to Configuration
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-5): "
if "%sub_choice%"=="1" goto set_xbox
if "%sub_choice%"=="2" goto set_bake_drivers
if "%sub_choice%"=="3" goto set_uup_channel
if "%sub_choice%"=="4" goto set_gaming_optimize
if "%sub_choice%"=="5" goto sub_config
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

:: ==================================================================
:: On-boarding / Quick Start  (guided first-run flow, Step 4)
:: ==================================================================
:quickstart
cls
echo ==========================================================
echo        M i O S - C a t     Quick Start  (guided)
echo ==========================================================
echo   MiOS-Cat turns a shareable link + this USB + any PC into
echo   a complete MiOS workshop. Four things it can do:
echo.
echo     [STAGE ]  build a bootable MiOS-Cat USB (recovery + repo)
echo     [BUILD ]  build a MiOS image (OCI / Xbox ISO / all)
echo     [DEPLOY]  install / provision MiOS onto a machine
echo     [CONFIG]  drive, filesystem, theme and build options
echo ----------------------------------------------------------
echo   Environment:
call :detect_env
echo     Host        : %env_host%
echo     Network     : %env_net%
echo     Privileges  : Administrator (verified at preflight)
echo     Build host  : %env_builder%
echo     Target disk : %env_disk%
echo ==========================================================
echo   Where would you like to start?
echo     1. Stage a bootable USB        (recommended first run)
echo     2. Build a MiOS image
echo     3. Install / Deploy MiOS
echo     4. Configuration
echo     5. Open the full menu
echo     6. Exit
echo ==========================================================
set "qs_choice="
set /p "qs_choice=Select an option (1-6): "
if "%qs_choice%"=="1" goto start_install
if "%qs_choice%"=="2" goto sub_build
if "%qs_choice%"=="3" goto sub_deploy
if "%qs_choice%"=="4" goto sub_config
if "%qs_choice%"=="5" goto menu
if "%qs_choice%"=="6" exit /b 0
goto quickstart

:: ==================================================================
:: Build  (native WS-CAT build surface, Step 2)
:: ==================================================================
:sub_build
cls
echo ==========================================================
echo               Build MiOS Images
echo ==========================================================
echo   Builds MiOS from THIS machine. A missing build toolchain
echo   (WSL2 + podman + the MiOS-DEV builder) is auto-provisioned
echo   offline-first from the MiOS-Repo payload, else online.
echo   DISM (used by the Xbox ISO) already ships in Windows.
echo ----------------------------------------------------------
echo   1. Build MiOS OCI image     : localhost/mios:latest
echo   2. Build MiOS-Xbox ISO      : Windows 11 gaming edition
echo   3. Build ALL artifacts      : OCI + raw/iso/qcow2/vhd/wsl2
echo   4. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-4): "
if "%sub_choice%"=="1" goto build_oci
if "%sub_choice%"=="2" goto build_xbox_iso
if "%sub_choice%"=="3" goto build_all
if "%sub_choice%"=="4" goto menu
goto sub_build

:build_oci
cls
echo ==========================================================
echo               Build MiOS OCI Image
echo ==========================================================
echo   Produces : localhost/mios:latest  (bootc OS image)
echo   Where    : MiOS-DEV podman storage on this host
echo   Toolchain: WSL2 + podman + MiOS-DEV builder auto-provisioned
echo              if missing (offline-first from MiOS-Repo, else online)
echo   Time     : 20-60 min on first run (image pulls + build)
echo ==========================================================
set "confirm="
set /p "confirm=Start the OCI image build now? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_build
call :resolve_bootstrap_root
if "%bootstrap_root%"=="" goto build_need_online
if not exist "%bootstrap_root%\build-mios.ps1" goto build_need_online
echo.
echo [BUILD] Driver : %bootstrap_root%\build-mios.ps1
echo [BUILD] Mode   : OCI only (MIOS_SKIP_BIB=1)
echo [BUILD] Progress streams below and/or in the MiOS-DEV window.
echo.
set "MIOS_SKIP_BIB=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%bootstrap_root%\build-mios.ps1" -Unattended
set "build_rc=%errorlevel%"
set "MIOS_SKIP_BIB="
echo.
if "%build_rc%"=="0" echo [OK] OCI build step finished. Image target: localhost/mios:latest
if not "%build_rc%"=="0" echo [WARN] Build driver exit code %build_rc% - review the log above; you can re-run this item.
echo.
pause
goto sub_build

:build_xbox_iso
cls
echo ==========================================================
echo               Build MiOS-Xbox ISO
echo ==========================================================
echo   Produces : MiOS-Xbox.iso  (custom Windows 11 gaming edition)
echo   Pipeline : UUP fetch - DISM offline servicing - oscdimg
echo   Toolchain: DISM ships in Windows; UUP media fetched
echo              offline-first from MiOS-Repo, else online
echo   Config   : Channel [%uup_channel%]  Drivers [%bake_drivers%]  Gaming [%gaming_optimize%]
echo ==========================================================
set "confirm="
set /p "confirm=Start the MiOS-Xbox ISO build now? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_build
call :resolve_xbox_builder
if "%xbox_builder%"=="" goto build_xbox_missing
echo.
echo [BUILD] Builder: %xbox_builder%
echo [BUILD] Progress streams below. This can take a while.
echo.
if exist "%toml_path%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%xbox_builder%" -TomlPath "%toml_path%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%xbox_builder%"
)
set "build_rc=%errorlevel%"
echo.
if "%build_rc%"=="0" echo [OK] MiOS-Xbox ISO build finished.
if not "%build_rc%"=="0" echo [WARN] Xbox builder exit code %build_rc% - review the log above; you can re-run this item.
echo.
pause
goto sub_build

:build_all
cls
echo ==========================================================
echo               Build ALL MiOS Artifacts
echo ==========================================================
echo   Produces : localhost/mios:latest PLUS deployment artifacts
echo              raw - iso - qcow2 - vhd - wsl2 tarball
echo   Where    : /var/lib/mios/build/output inside MiOS-DEV
echo   Requires : a Linux/podman build host - auto-provisioned
echo              (WSL2 + podman + MiOS-DEV) if missing, offline-first
echo   Size/Time: ~30-40 GB, 45-90 min for the full matrix
echo ==========================================================
set "confirm="
set /p "confirm=Build the FULL artifact matrix now? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_build
call :resolve_bootstrap_root
if "%bootstrap_root%"=="" goto build_need_online
if not exist "%bootstrap_root%\build-mios.ps1" goto build_need_online
echo.
echo [BUILD] Driver : %bootstrap_root%\build-mios.ps1
echo [BUILD] Mode   : full matrix (OCI + all [deployment] targets)
echo [BUILD] Progress streams below and/or in the MiOS-DEV window.
echo.
set "MIOS_SKIP_BIB="
powershell -NoProfile -ExecutionPolicy Bypass -File "%bootstrap_root%\build-mios.ps1" -Unattended
set "build_rc=%errorlevel%"
echo.
if "%build_rc%"=="0" echo [OK] Full artifact build finished. Output: /var/lib/mios/build/output in MiOS-DEV.
if not "%build_rc%"=="0" echo [WARN] Build driver exit code %build_rc% - review the log above; you can re-run this item.
echo.
pause
goto sub_build

:build_need_online
echo.
echo [INFO] No local MiOS build driver (build-mios.ps1) was found on
echo        this host or on the MiOS-Repo payload of this drive.
echo        MiOS-Cat can fetch the mios-bootstrap repo ONCE (git, else a
echo        GitHub zip) into C:\mios-bootstrap and then build LOCALLY --
echo        it no longer re-enters the online one-liner (that was a loop
echo        back through the web door; MiOS-Cat is the flash/build executor).
echo.
set "confirm="
set /p "confirm=Fetch the mios-bootstrap repo now and build locally? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_build
powershell -NoProfile -Command "try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { exit 0 } else { exit 1 } } catch { exit 1 }"
if not "%errorlevel%"=="0" (
    echo [OFFLINE] Internet is unreachable and no offline payload is present.
    echo           Stage this USB on a connected PC first, then retry offline.
    pause
    goto sub_build
)
echo Fetching mios-bootstrap into C:\mios-bootstrap ...
:: Self-contained fetch (mirrors mios-common's Ensure-MiosRepo -- can't source
:: it here since the repo is exactly what's missing). git first, else GitHub zip.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $root='C:\mios-bootstrap'; $drv=Join-Path $root 'build-mios.ps1'; if (-not (Test-Path $drv)) { if (Get-Command git -ErrorAction SilentlyContinue) { git clone --depth 1 'https://github.com/mios-dev/mios-bootstrap.git' $root | Out-Null }; if (-not (Test-Path $drv)) { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $zip=Join-Path $env:TEMP 'mios-bootstrap.zip'; $tmp=Join-Path $env:TEMP ('mios-bs-'+[guid]::NewGuid().ToString('N').Substring(0,8)); Invoke-WebRequest -Uri 'https://codeload.github.com/mios-dev/mios-bootstrap/zip/refs/heads/main' -OutFile $zip -UseBasicParsing; Expand-Archive -Path $zip -DestinationPath $tmp -Force; $inner=Get-ChildItem $tmp -Directory | Select-Object -First 1; if ($inner) { New-Item -ItemType Directory -Force -Path $root | Out-Null; Copy-Item (Join-Path $inner.FullName '*') $root -Recurse -Force }; Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue } }; if (Test-Path $drv) { exit 0 } else { exit 3 }"
if not "%errorlevel%"=="0" (
    echo [ERR ] Could not fetch mios-bootstrap. Check connectivity / proxy and retry.
    pause
    goto sub_build
)
set "bootstrap_root=C:\mios-bootstrap"
echo [OK] Fetched. Local build driver ready at %bootstrap_root%\build-mios.ps1
echo      Re-open the Build menu and pick your build again -- it now runs LOCALLY.
pause
goto sub_build

:build_xbox_missing
echo.
echo [INFO] MiOS-Xbox builder was not found under:
echo        %~dp0autounattend\  or  C:\mios-bootstrap\cat\autounattend\
echo        Stage this USB (Stage USB) to place the payload, or pull
echo        mios-bootstrap, then retry this item.
echo.
pause
goto sub_build

:: ==================================================================
:: Install / Deploy  (provision surface)
:: ==================================================================
:sub_deploy
cls
echo ==========================================================
echo               Install / Deploy MiOS
echo ==========================================================
echo   1. Stage a bootable MiOS-Cat USB   (full pipeline)
echo   2. Provision MiOS-Xbox on a target (autounattend)
echo   3. Deploy / test MiOS-Xbox VM      (Hyper-V)
echo   4. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-4): "
if "%sub_choice%"=="1" goto start_install
if "%sub_choice%"=="2" goto deploy_provision
if "%sub_choice%"=="3" goto deploy_xbox
if "%sub_choice%"=="4" goto menu
goto sub_deploy

:deploy_provision
cls
echo ==========================================================
echo          Provision MiOS-Xbox (autounattend)
echo ==========================================================
echo   Runs the MiOS provisioning entry (Invoke-MiOSProvision.ps1)
echo   using the SSOT configuration. Confirm before running.
echo ==========================================================
set "confirm="
set /p "confirm=Run MiOS provisioning now? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_deploy
set "prov_ps="
if exist "%~dp0autounattend\Invoke-MiOSProvision.ps1" set "prov_ps=%~dp0autounattend\Invoke-MiOSProvision.ps1"
if "%prov_ps%"=="" if exist "C:\mios-bootstrap\cat\autounattend\Invoke-MiOSProvision.ps1" set "prov_ps=C:\mios-bootstrap\cat\autounattend\Invoke-MiOSProvision.ps1"
if "%prov_ps%"=="" (
    echo [INFO] Invoke-MiOSProvision.ps1 not found - stage the USB payload first.
    pause
    goto sub_deploy
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%prov_ps%"
echo.
pause
goto sub_deploy

:deploy_xbox
cls
echo ==========================================================
echo          Deploy / Test MiOS-Xbox VM
echo ==========================================================
echo   Runs Deploy-MiOSXbox.ps1 to (re)create and boot a Hyper-V
echo   test VM from the built MiOS-Xbox media. Confirm to run.
echo ==========================================================
set "confirm="
set /p "confirm=Deploy the MiOS-Xbox test VM now? (Y/N): "
if /i not "%confirm%"=="Y" goto sub_deploy
set "dep_ps="
if exist "%~dp0autounattend\Deploy-MiOSXbox.ps1" set "dep_ps=%~dp0autounattend\Deploy-MiOSXbox.ps1"
if "%dep_ps%"=="" if exist "C:\mios-bootstrap\cat\autounattend\Deploy-MiOSXbox.ps1" set "dep_ps=C:\mios-bootstrap\cat\autounattend\Deploy-MiOSXbox.ps1"
if "%dep_ps%"=="" (
    echo [INFO] Deploy-MiOSXbox.ps1 not found - stage the USB payload first.
    pause
    goto sub_deploy
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%dep_ps%"
echo.
pause
goto sub_deploy

:: ==================================================================
:: Update  (pull latest MiOS + mios-bootstrap)
:: ==================================================================
:sub_update
cls
echo ==========================================================
echo               Update MiOS
echo ==========================================================
echo   Pulls the latest MiOS and mios-bootstrap from their remotes
echo   (git fetch + pull). Requires internet.
echo ==========================================================
set "confirm="
set /p "confirm=Check for and pull updates now? (Y/N): "
if /i not "%confirm%"=="Y" goto menu
powershell -NoProfile -Command "try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { exit 0 } else { exit 1 } } catch { exit 1 }"
if not "%errorlevel%"=="0" (
    echo [OFFLINE] Internet unreachable - cannot pull updates right now.
    pause
    goto menu
)
call :update_repo "C:\MiOS" "MiOS"
call :update_repo "C:\mios-bootstrap" "mios-bootstrap"
cd /d "%maindir%"
echo.
echo [OK] Update check complete.
pause
goto menu

:: ==================================================================
:: Configuration  (hub grouping the existing setting sub-menus)
:: ==================================================================
:sub_config
cls
echo ==========================================================
echo               Configuration
echo ==========================================================
echo   1. USB Target Settings    : Drive [%drivepath%:], Label [%partition_label%]
echo   2. Ventoy / FS Settings   : Format [%filesystem%], Scheme [%partition_scheme%]
echo   3. MiOS-Xbox Build Config : Drivers [%bake_drivers%], Channel [%uup_channel%]
echo   4. Theme Colors           : Accent [%accent_color%], Subtle [%subtle_color%]
echo   5. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-5): "
if "%sub_choice%"=="1" goto sub_usb
if "%sub_choice%"=="2" goto sub_ventoy
if "%sub_choice%"=="3" goto sub_xbox
if "%sub_choice%"=="4" goto sub_colors
if "%sub_choice%"=="5" goto menu
goto sub_config

:: ==================================================================
:: Manual / Help
:: ==================================================================
:sub_manual
cls
echo ==========================================================
echo               Manual / Help
echo ==========================================================
echo   1. About MiOS-Cat (what each menu does)
echo   2. Open MiOS-Xbox build + pipeline docs
echo   3. Open the mios-bootstrap folder
echo   4. Back to Main Menu
echo ==========================================================
set "sub_choice="
set /p "sub_choice=Select an option (1-4): "
if "%sub_choice%"=="1" goto manual_about
if "%sub_choice%"=="2" goto manual_docs
if "%sub_choice%"=="3" goto manual_open
if "%sub_choice%"=="4" goto menu
goto sub_manual

:manual_about
cls
echo ==========================================================
echo               About MiOS-Cat
echo ==========================================================
echo   Quick Start : guided on-boarding - detects your environment
echo                 and routes you to the right action.
echo   Build       : builds MiOS images from this machine -
echo                 OCI (localhost/mios:latest), MiOS-Xbox ISO,
echo                 or the full artifact matrix. The toolchain is
echo                 self-provisioned (WSL2 + podman) if missing.
echo   Stage USB   : formats a USB with Ventoy + MiOS-Cat recovery
echo                 payload and a secure MiOS-Repo partition.
echo   Deploy      : provision / deploy MiOS onto a target machine.
echo   Update      : pull the latest MiOS + mios-bootstrap.
echo   Config      : drive, filesystem, theme colors, Xbox build.
echo   Repo Tools  : open the repos and edit the mios.toml SSOT.
echo ==========================================================
pause
goto sub_manual

:manual_docs
set "docs_dir="
if exist "%~dp0autounattend\docs" set "docs_dir=%~dp0autounattend\docs"
if "%docs_dir%"=="" if exist "C:\mios-bootstrap\cat\autounattend\docs" set "docs_dir=C:\mios-bootstrap\cat\autounattend\docs"
if "%docs_dir%"=="" (
    echo [INFO] Local docs not found; opening the online project instead...
    start "" "https://github.com/mios-dev/mios-bootstrap"
    goto sub_manual
)
start "" explorer.exe "%docs_dir%"
goto sub_manual

:manual_open
if exist "%~dp0.." start "" explorer.exe "%~dp0.."
goto sub_manual

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

:set_force_format
if "%force_format%"=="Enabled" (
    set "force_format=Disabled"
) else (
    set "force_format=Enabled"
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
set "confirm="
if "%NONINTERACTIVE%"=="1" set "confirm=Y"
if not "%NONINTERACTIVE%"=="1" set /p "confirm=Are you sure you want to format %drivepath%: and install? (Y/N): "
if /i "%confirm%"=="y" set "confirm=Y"
if /i "%confirm%"=="yes" set "confirm=Y"
if /i "%confirm%"=="1" set "confirm=Y"
if not "%confirm%"=="Y" goto menu

:: Ensure target drive exists
if not exist "%drivepath%:\" (
    echo [ERROR] Target drive %drivepath%: was not found!
    echo Please insert your USB drive and ensure it is mounted as %drivepath%:\
    if not "%NONINTERACTIVE%"=="1" pause
    goto menu
)

:: Full visible monitor defaults to ON (SSOT cat.monitor_enabled = true / show_live_monitor = true)
if not "%monitor_enabled%"=="false" if not "%show_live_monitor%"=="false" (
    echo Launching live interactive monitor on user desktop...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-Interactive-Monitor.ps1" >nul 2>&1
)

:: 4. Download Ventoy bootloader -- newest upstream GLOBALLY
echo Checking Ventoy files...
if not exist "%stage_dir%\Ventoy2Disk" call :resolve_ventoy_latest
if not exist "%stage_dir%\Ventoy2Disk" if not defined ventoy_ver (
    echo.
    echo [FAIL] Could not resolve a Ventoy version: no network to reach GitHub, no
    echo        build-recorded pin in [cat].ventoy_version, and no Ventoy staged.
    exit /b 1
)
if not exist "%stage_dir%\Ventoy2Disk" (
    echo Downloading Ventoy %ventoy_ver% ^(newest upstream^) windows release...
    curl -s -L "https://github.com/ventoy/Ventoy/releases/download/v%ventoy_ver%/ventoy-%ventoy_ver%-windows.zip" -o "%stage_dir%\ventoy.zip"
    "%maindir%\bin\7z.exe" x "%stage_dir%\ventoy.zip" -o"%stage_dir%" -aoa >nul
    for /d %%V in ("%stage_dir%\ventoy-*") do ren "%%V" Ventoy2Disk
    del "%stage_dir%\ventoy.zip" /Q >nul 2>&1
    if not exist "%stage_dir%\Ventoy2Disk\Ventoy2Disk.exe" (
        echo [FAIL] Ventoy %ventoy_ver% download/extract failed -- no Ventoy2Disk.exe present.
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
    echo [OK] Core Medicat archive found and complete at %file%
)

:: 6b. Extract WIM payload & PortableApps suite to Localhost AIO Stage
echo Extracting Mini_Windows WIM and PortableApps suite from core archive to Localhost SSD...
"%maindir%\bin\7z.exe" x "%file%" -o"%aio_stage%" "Live_Operating_Systems/Mini_Windows/*" "PortableApps/*" -mmt=on -aoa -y >nul

:: 6c. Pull/Download Fedora Server DVD
set "fedora_ver=44"
set "fedora_build=-1.7"
set "fedora_file=M:\Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso"
if exist "%fedora_file%" echo [OK] Fedora Server DVD found at %fedora_file%
if exist "%fedora_file%" goto fedora_dvd_ok
echo Pulling FULL Fedora %fedora_ver% Server DVD ~2.5 GB...
curl.exe -C - -L "https://download.fedoraproject.org/pub/fedora/linux/releases/%fedora_ver%/Server/x86_64/iso/Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso" -o "%fedora_file%" -#
set "fedora_sz=0"
if exist "%fedora_file%" for %%A in ("%fedora_file%") do set "fedora_sz=%%~zA"
if not "%fedora_sz:~9,1%"=="" goto fedora_dvd_ok
echo [FATAL ERROR] Fedora DVD download failed! & exit /b 1
:fedora_dvd_ok
copy "%fedora_file%" "%aio_stage%\Live_Operating_Systems\Fedora-Server.iso" /Y >nul

:: 6d. Ensure SystemRescue Arch Linux ISO is staged
set "sysrescue_ver=13.01"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "try { $r=(Invoke-WebRequest -Uri 'https://www.system-rescue.org/Download/' -UseBasicParsing -TimeoutSec 6 -Headers @{'User-Agent'='MiOS-Cat'}).Content; if ($r -match 'systemrescue-([0-9]+\.[0-9]+)-amd64\.iso') { $Matches[1] } else { '13.01' } } catch { '13.01' }"`) do set "sysrescue_ver=%%i"
set "sysrescue_local=%aio_stage%\Live_Operating_Systems\SystemRescue\SystemRescue.iso"
if exist "M:\systemrescue-%sysrescue_ver%-amd64.iso" (
    copy "M:\systemrescue-%sysrescue_ver%-amd64.iso" "%sysrescue_local%" /Y >nul 2>&1
)
if not exist "%sysrescue_local%" (
    echo Pulling SystemRescue %sysrescue_ver%...
    curl.exe -C - -L --connect-timeout 10 --retry 2 "https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/%sysrescue_ver%/systemrescue-%sysrescue_ver%-amd64.iso" -o "%sysrescue_local%" -#
)
if not exist "%sysrescue_local%" (
    echo [FATAL ERROR] SystemRescue ISO download failed! & exit /b 1
)

:: 7. Perform Localhost Offline DISM Servicing on MiOS_PE.wim (Zero USB mounting!)
set "wim_path=%aio_stage%\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim"
if not exist "%wim_path%" (
    if exist "%aio_stage%\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" (
        move "%aio_stage%\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" "%wim_path%" >nul
    )
)

if not exist "%wim_path%" (
    echo [FATAL ERROR] Required WIM image file not found at %wim_path%!
    exit /b 1
)

echo Performing offline DISM servicing on Localhost WIM image: %wim_path%
dism /Cleanup-Wim >nul 2>&1
if exist "%stage_dir%\mount" rmdir "%stage_dir%\mount" /S /Q >nul 2>&1
mkdir "%stage_dir%\mount" >nul 2>&1
echo Mounting WIM image on Localhost SSD (%stage_dir%\mount)...
dism /Mount-Image /ImageFile:"%wim_path%" /Index:1 /MountDir:"%stage_dir%\mount"
if %errorlevel% neq 0 (
    echo [FATAL ERROR] DISM failed to mount %wim_path% with exit code %errorlevel%!
    dism /Cleanup-Wim >nul 2>&1
    exit /b %errorlevel%
)

if "%bake_drivers%"=="Enabled" (
    echo [DRIVER BAKE] Exporting build-host drivers for WinPE injection...
    mkdir "%stage_dir%\hostdrivers" >nul 2>&1
    dism /Online /Export-Driver /Destination:"%stage_dir%\hostdrivers"
    if %errorlevel% neq 0 ( echo [FATAL ERROR] DISM Export-Driver failed! & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b %errorlevel% )
    dism /Image:"%stage_dir%\mount" /Add-Driver /Driver:"%stage_dir%\hostdrivers" /Recurse /ForceUnsigned
    if %errorlevel% neq 0 ( echo [FATAL ERROR] DISM Add-Driver failed! & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b %errorlevel% )
    rmdir /s /q "%stage_dir%\hostdrivers" >nul 2>&1
)

echo Injecting custom wallpaper, Geist Mono font, and Console colors into WIM...
set "wallpaper_src="
if exist "%maindir%\resources\theme\uefi\background.jpg" set "wallpaper_src=%maindir%\resources\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" if exist "%~dp0..\resources\theme\uefi\background.jpg" set "wallpaper_src=%~dp0..\resources\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" if exist "D:\ventoy\theme\uefi\background.jpg" set "wallpaper_src=D:\ventoy\theme\uefi\background.jpg"
if "%wallpaper_src%"=="" ( echo [FATAL ERROR] background.jpg missing! & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b 1 )

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
if "%font_src%"=="" ( echo [FATAL ERROR] GeistMono font missing! & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b 1 )
copy "%font_src%" "%stage_dir%\mount\Windows\Fonts\GeistMonoNerdFontMono-Regular.otf" /Y >nul

reg load HKEY_USERS\pe-default "%stage_dir%\mount\Windows\System32\config\DEFAULT" >nul 2>&1
if %errorlevel% neq 0 ( echo [FATAL ERROR] Failed to load DEFAULT hive! & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b 1 )
reg load HKEY_USERS\pe-software "%stage_dir%\mount\Windows\System32\config\SOFTWARE" >nul 2>&1
if %errorlevel% neq 0 ( echo [FATAL ERROR] Failed to load SOFTWARE hive! & reg unload HKEY_USERS\pe-default /f >nul 2>&1 & dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1 & exit /b 1 )

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

echo Committing changes and unmounting Localhost WIM image...
dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Commit
if %errorlevel% neq 0 (
    echo [FATAL ERROR] Failed to unmount and commit Localhost WIM image!
    dism /Unmount-Image /MountDir:"%stage_dir%\mount" /Discard >nul 2>&1
    dism /Cleanup-Wim >nul 2>&1
    exit /b 1
)
if exist "%stage_dir%\mount" rmdir "%stage_dir%\mount" /S /Q >nul 2>&1

echo Exporting and compressing Localhost MiOS_PE.wim...
set "trim_path=%aio_stage%\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim"
dism /Export-Image /SourceImageFile:"%wim_path%" /SourceIndex:1 /DestinationImageFile:"%trim_path%" /Compress:max
if %errorlevel% neq 0 ( echo [FATAL ERROR] DISM Export-Image failed! & exit /b %errorlevel% )
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
    echo [FATAL ERROR] AIO verification failed: MiOS_PE.wim missing from stage! & exit /b 1
)
if "%build_xbox%"=="Enabled" (
    if not exist "%aio_stage%\Live_Operating_Systems\MiOS-Xbox.iso" (
        echo [FATAL ERROR] AIO verification failed: MiOS-Xbox.iso missing from stage! & exit /b 1
    )
)
if not exist "%aio_stage%\Live_Operating_Systems\SystemRescue\SystemRescue.iso" (
    echo [FATAL ERROR] AIO verification failed: SystemRescue.iso missing from stage! & exit /b 1
)
echo [AIO SUCCESS] All images 100%% compiled, serviced, and verified on Localhost SSD!

echo.
echo ==========================================================
echo    PHASE 2: TARGET DRIVE FORMAT & SINGLE-PASS FLASH WRITE
echo ==========================================================
echo Target Drive: %drivepath%:
echo ==========================================================
echo.

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
format %drivepath%: /FS:%filesystem% /A:64K /X /Q /V:%partition_label% /Y >nul

echo Creating secure offline repository partition (%repo_label%)...
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% | Get-Disk; if ('%mios_make_data%' -eq '1') { $rp = New-Partition -DiskNumber $d.Number -Size %mios_repo_gb%GB -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null }; $dp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($dp) { Format-Volume -Partition $dp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%data_label%' -Confirm:$false | Out-Null } } else { $rp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null } }" >nul 2>&1

:: 12. Multithreaded extraction of Medicat payload
set "SURGICAL_LIST=System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* Programs/7-Zip_x64/* Programs/Bootice/* Programs/DiskGeniusLite/* Programs/Everything_x64/* Programs/WizTree/* Programs/HDSentinel/* Programs/Sysinternals/* Programs/ventoy/*"
echo Extracting payload to %drivepath%: (-mmt=on)...
"%maindir%\bin\7z.exe" x "%file%" -o%drivepath%:\ %SURGICAL_LIST% -mmt=on -aoa -y >nul

:: 13. Apply custom MiOS templates, PortableApps & shadow-config brain
xcopy "%maindir%\resources\ventoy" "%drivepath%:\ventoy\" /E /I /H /Y /Q >nul
xcopy "%maindir%\resources\theme" "%drivepath%:\ventoy\theme\" /E /I /H /Y /Q >nul
copy "%maindir%\resources\autorun.sh" "%drivepath%:\autorun.sh" /Y >nul
mkdir "%drivepath%:\autorun" >nul 2>&1
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

echo Staging offline repositories to the %data_label% vault (%datadrive%:)...
mkdir "%datadrive%:\repos\mios-bootstrap" >nul 2>&1
robocopy "C:\mios-bootstrap" "%datadrive%:\repos\mios-bootstrap" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 /MT:32 >nul
mkdir "%datadrive%:\repos\MiOS" >nul 2>&1
robocopy "C:\MiOS" "%datadrive%:\repos\MiOS" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 /MT:32 >nul

echo Staging shadow-config brain to %repo_label% (%repodrive%:)...
if exist "%toml_path%" copy "%toml_path%" "%repodrive%:\mios.toml" /Y >nul 2>&1
copy "%~f0" "%repodrive%:\MiOS-Cat.bat" /Y >nul 2>&1

:: 14. SINGLE-PASS FLASH WRITE: Copy all compiled AIO images to target drive D: in one go!
echo.
echo ==========================================================
echo   SINGLE FLASH PASS: WRITING ALL AIO IMAGES TO USB (%drivepath%:)
echo ==========================================================
mkdir "%drivepath%:\Live_Operating_Systems" >nul 2>&1
robocopy "%aio_stage%\Live_Operating_Systems" "%drivepath%:\Live_Operating_Systems" /E /R:2 /W:2 /MT:32
if errorlevel 8 (
    echo [FATAL ERROR] Robocopy failed to write AIO images to %drivepath%:\Live_Operating_Systems!
    exit /b 1
)

if exist "%aio_stage%\PortableApps" (
    echo Writing PortableApps suite to USB (%drivepath%:\PortableApps)...
    mkdir "%drivepath%:\PortableApps" >nul 2>&1
    robocopy "%aio_stage%\PortableApps" "%drivepath%:\PortableApps" /E /R:2 /W:2 /MT:32
    if errorlevel 8 (
        echo [FATAL ERROR] Robocopy failed to write PortableApps to %drivepath%:\PortableApps!
        exit /b 1
    )
)

if exist "%aio_stage%\MiOS-PE" (
    echo Writing MiOS-PE rescue directory to USB (%drivepath%:\MiOS-PE)...
    mkdir "%drivepath%:\MiOS-PE" >nul 2>&1
    robocopy "%aio_stage%\MiOS-PE" "%drivepath%:\MiOS-PE" /E /R:2 /W:2 /MT:32 >nul
)

if exist "%aio_stage%\Documents" (
    echo Writing Documents vault to USB (%drivepath%:\Documents)...
    mkdir "%drivepath%:\Documents" >nul 2>&1
    robocopy "%aio_stage%\Documents" "%drivepath%:\Documents" /E /R:2 /W:2 /MT:32 >nul
)

:: 15. Finalize Branding & Start.exe launcher
attrib -r -h -s "%drivepath%:\autorun.inf" >nul 2>&1
(
echo [Autorun]
echo Icon=icon.ico
echo Label=MiOS-Cat
) > "%drivepath%:\autorun.inf"
copy "%maindir%\icon.ico" "%drivepath%:\icon.ico" /Y >nul
attrib +h +s "%drivepath%:\autorun.inf" >nul 2>&1
attrib +h +s "%drivepath%:\icon.ico" >nul 2>&1

(
echo using System;
echo using System.Diagnostics;
echo using System.IO;
echo class Launcher {
echo     static void Main^(^) {
echo         string path = Path.Combine^(AppDomain.CurrentDomain.BaseDirectory, @"PortableApps\PortableApps.com\PortableAppsPlatform.exe"^);
echo         if ^(File.Exists^(path^)^) {
echo             Process.Start^(new ProcessStartInfo { FileName = path, UseShellExecute = true }^);
echo         }
echo     }
echo }
) > "%temp%\launcher.cs"

C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:"%maindir%\icon.ico" /out:"%drivepath%:\Start.exe" "%temp%\launcher.cs" >nul 2>&1
del "%temp%\launcher.cs" /Q >nul 2>&1

echo.
echo ==========================================================
echo     MiOS-Cat ALL-IN-ONE USB FLASHING SUCCESSFULLY COMPLETED
echo ==========================================================
echo All images were compiled on localhost SSD & written in one pass.
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
    echo [FAIL] Administrator privileges required. Please run this script as Admin.
    exit /b 1
)
echo [PASS] Administrator privileges verified.

:: 2. Target Disk Safety Check (Ensure D: is not an internal drive)
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% -ErrorAction SilentlyContinue | Get-Disk; if ($d) { if ($d.BusType -eq 'SATA' -or $d.BusType -eq 'NVMe') { exit 2 } }; exit 0"
set "disk_check=%errorlevel%"
if %disk_check% equ 2 (
    echo [FAIL] Target drive %drivepath%: is detected as an internal drive - SATA or NVMe.
    echo        To prevent data loss, formatting internal drives is restricted.
    echo        Please specify a USB/Removable target drive letter.
    exit /b 1
)
echo [PASS] Target drive %drivepath%: safety check completed.

:: 3. Storage Space Check on Cache drive (Ensure at least 25GB free)
if not exist "%file%" (
    powershell -NoProfile -Command "$cacheDrive = Split-Path -Path '%file%' -Qualifier; $v = Get-Volume -DriveLetter $cacheDrive.Trim(':') -ErrorAction SilentlyContinue; if ($v -and $v.SizeRemaining -lt 25GB) { exit 1 }; exit 0"
    if errorlevel 1 (
        echo [FAIL] Insufficient disk space on cache drive to download Medicat - 25GB required.
        exit /b 1
    )
    echo [PASS] Cache drive storage space verified.
)

:: 4. Dependency checks (git, curl)
where git >nul 2>&1
if %errorlevel% neq 0 (
    echo [FAIL] Git is missing from system PATH.
    exit /b 1
)
where curl >nul 2>&1
if %errorlevel% neq 0 (
    echo [FAIL] Curl is missing from system PATH.
    exit /b 1
)
echo [PASS] System dependencies (git, curl) verified.
echo ==========================================================
echo.
exit /b 0

:check_drive_ready
if not exist "%drivepath%:\CdUsb.Y" (
    echo.
    echo [WARNING] USB drive %drivepath%: is temporarily busy or disconnected.
    echo Waiting 3 seconds for link remount...
    ping localhost -n 4 >nul
    if not exist "%drivepath%:\CdUsb.Y" (
        echo [ERROR] USB drive %drivepath%: is missing.
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
if exist "%~dp0autounattend\Build-MiOSXbox.ps1" (
    set "xbox_builder=%~dp0autounattend\Build-MiOSXbox.ps1"
    goto :eof
)
if exist "%~dp0autounattend\New-MiOSISO.ps1" (
    set "xbox_builder=%~dp0autounattend\New-MiOSISO.ps1"
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
    echo [SKIP] %~2 is not a git checkout at %~1
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autounattend\Render-MiosRunToml.ps1" -TomlPath "%toml_path%" -UupChannel "%uup_channel%" -BakeDrivers "%bake_drivers%" -GamingOptimize "%gaming_optimize%"
if errorlevel 1 ( echo [FATAL ERROR] Render-MiosRunToml failed! & exit /b 1 )

set "xbox_builder_script=%~dp0autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" set "xbox_builder_script=%~dp0cat\autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" set "xbox_builder_script=C:\mios-bootstrap\cat\autounattend\Build-MiOSXboxISO.ps1"
if not exist "%xbox_builder_script%" ( echo [FATAL ERROR] Build-MiOSXboxISO.ps1 script missing! & exit /b 1 )

powershell.exe -ExecutionPolicy Bypass -File "%xbox_builder_script%" -TomlPath "%temp%\mios_run.toml" -OutIso "%aio_stage%\Live_Operating_Systems\MiOS-Xbox.iso" -WorkDir "%stage_dir%\isobuild_live" -SkipWsl -SkipPrereqs
if errorlevel 1 ( echo [FATAL ERROR] Build-MiOSXboxISO.ps1 failed! & exit /b 1 )
exit /b 0
