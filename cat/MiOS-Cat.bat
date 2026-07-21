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
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -Raw -LiteralPath '%toml_path%'; $q=[char]34; function G([string]$k){ $m=[regex]::Match($t, ('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:'+$q+'([^'+$q+'\r\n]*)'+$q+'|(\d+))')); if($m.Success){ if($m.Groups[1].Value){ $m.Groups[1].Value -replace '\\\\','\' } else { $m.Groups[2].Value } } }; function GS([string]$sec,[string]$k){ $sm=[regex]::Match($t, ('(?ms)^\s*\['+[regex]::Escape($sec)+'\]\s*(.*?)(?=\r?\n\s*\[|\Z)')); if($sm.Success){ $m=[regex]::Match($sm.Groups[1].Value, ('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:'+$q+'([^'+$q+'\r\n]*)'+$q+'|(\d+))')); if($m.Success){ if($m.Groups[1].Value){ $m.Groups[1].Value -replace '\\\\','\' } else { $m.Groups[2].Value } } } }; $map=[ordered]@{ drivepath='drivepath'; medicatver='medicatver'; ventoy_ver='ventoy_version'; file='cache_path'; bg_color='bg'; fg_color='fg'; accent_color='accent'; cursor_color='cursor'; success_color='success'; muted_color='muted'; subtle_color='subtle'; live_chat_enabled='live_chat_enabled'; live_chat_iso_name='live_chat_iso_name'; live_chat_iso_src='live_chat_iso_src' }; $o=New-Object System.Collections.Generic.List[string]; foreach($e in $map.GetEnumerator()){ $v=G $e.Value; if($v){ $o.Add('set '+$q+$e.Key+'='+$v+$q) } }; $mg=G 'min_disk_gb'; if($mg){ $o.Add('set '+$q+'min_disk_gb='+$mg+$q) }; $rl=GS 'cat.repo_partition' 'label'; if($rl){ $o.Add('set '+$q+'repo_label='+$rl+$q) }; $dl=GS 'cat.data_partition' 'label'; if($dl){ $o.Add('set '+$q+'data_label='+$dl+$q) }; if($o.Count){ Set-Content -LiteralPath '%ssot_env%' -Value $o -Encoding ascii }" 2>nul
if exist "%ssot_env%" call "%ssot_env%"
if exist "%ssot_env%" del "%ssot_env%" /q >nul 2>&1
:no_toml

:: Self-Update Check
echo Checking for script updates...
powershell -NoProfile -Command "try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { exit 0 } else { exit 1 } } catch { exit 1 }"
if %errorlevel% equ 0 (
    cd /d "C:\MiOS" >nul 2>&1
    if %errorlevel% equ 0 (
        git fetch >nul 2>&1
        for /f "usebackq tokens=*" %%a in (`git status -uno ^| findstr /C:"behind"`) do (
            echo Updates detected in MiOS repository. Pulling latest version...
            git pull >nul 2>&1
            echo Restarting script from updated checkout...
            start "" cmd.exe /c "%~f0"
            exit /b 0
        )
    )
    cd /d "C:\mios-bootstrap" >nul 2>&1
    if %errorlevel% equ 0 (
        git fetch >nul 2>&1
        for /f "usebackq tokens=*" %%a in (`git status -uno ^| findstr /C:"behind"`) do (
            echo Updates detected in mios-bootstrap repository. Pulling latest version...
            git pull >nul 2>&1
            echo Restarting script from updated checkout...
            start "" cmd.exe /c "%~f0"
            exit /b 0
        )
    )
    cd /d "%maindir%"
) else (
    echo [OFFLINE] Skipping self-update check.
)

:: Call Preflight Checks
call :run_preflight_checks
if %errorlevel% neq 0 (
    echo [FAIL] Preflight checks failed! Exiting...
    if not "%NONINTERACTIVE%"=="1" pause
    exit /b 1
)

:: Download 7z helper if missing
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
if /i "%~1"=="build"     goto sub_build
if /i "%~1"=="stage"     goto start_install
if /i "%~1"=="install"   goto sub_deploy
if /i "%~1"=="deploy"    goto sub_deploy
if /i "%~1"=="provision" goto sub_deploy
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
if /i not "%confirm%"=="Y" goto menu

:: Ensure target drive exists
if not exist "%drivepath%:\" (
    echo [ERROR] Target drive %drivepath%: was not found!
    echo Please insert your USB drive and ensure it is mounted as %drivepath%:\
    if not "%NONINTERACTIVE%"=="1" pause
    goto menu
)

:: 4. Download Ventoy bootloader -- newest upstream GLOBALLY (resolved live from GitHub),
::    else a BUILD-recorded pin (SSOT [cat].ventoy_version). No hand-pin, no stale offline
::    fallback: if nothing resolves we fail loud below. The extracted dir is normalized to
::    a version-agnostic "Ventoy2Disk", so everything downstream is version-independent.
echo Checking Ventoy files...
if not exist "%stage_dir%\Ventoy2Disk" call :resolve_ventoy_latest
if not exist "%stage_dir%\Ventoy2Disk" if not defined ventoy_ver (
    echo.
    echo [FAIL] Could not resolve a Ventoy version: no network to reach GitHub, no
    echo        build-recorded pin in [cat].ventoy_version, and no Ventoy staged on
    echo        this USB. MiOS pins nothing by hand -- connect once to fetch the
    echo        newest release, or stage Ventoy at build. Refusing to flash blind.
    exit /b 1
)
if not exist "%stage_dir%\Ventoy2Disk" (
    echo Downloading Ventoy %ventoy_ver% ^(newest upstream^) windows release...
    curl -s -L "https://github.com/ventoy/Ventoy/releases/download/v%ventoy_ver%/ventoy-%ventoy_ver%-windows.zip" -o "%stage_dir%\ventoy.zip"
    "%maindir%\bin\7z.exe" x "%stage_dir%\ventoy.zip" -o"%stage_dir%" -aoa >nul
    for /d %%V in ("%stage_dir%\ventoy-*") do ren "%%V" Ventoy2Disk
    del "%stage_dir%\ventoy.zip" /Q >nul 2>&1
    if not exist "%stage_dir%\Ventoy2Disk\Ventoy2Disk.exe" (
        echo.
        echo [FAIL] Ventoy %ventoy_ver% download/extract failed -- no Ventoy2Disk.exe present.
        echo        The resolved version must be a REAL Ventoy release tag
        echo        ^(https://github.com/ventoy/Ventoy/releases^); refusing to flash a
        echo        USB with no bootloader.
        exit /b 1
    )
)

set "skip_format_extract=0"
if "%force_format%"=="Disabled" (
    if exist "%drivepath%:\CdUsb.Y" (
        if exist "%drivepath%:\Start.exe" (
            if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim" set "skip_format_extract=1"
            if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" set "skip_format_extract=1"
        )
    )
)

if "%skip_format_extract%"=="1" (
    echo.
    echo ==========================================================
    echo [INFO] Existing MiOS-Cat installation detected on %drivepath%:.
    echo Skipping format, Ventoy bootloader install, and archive decompression.
    echo ==========================================================
    goto skip_extraction
)

:: 5. Install Ventoy to USB drive
echo.
echo Formatting and merging all USB partitions back to a single disk letter (%drivepath%:)...
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% -ErrorAction SilentlyContinue | Get-Disk; if ($d) { Get-Partition -DiskNumber $d.Number | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue; Initialize-Disk -Number $d.Number -PartitionStyle GPT -ErrorAction SilentlyContinue; $p = New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter %drivepath% -ErrorAction SilentlyContinue; if ($p) { Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel 'MiOS-Cat' -Confirm:$false | Out-Null }; Update-HostStorageCache }" >nul 2>&1

:: Disk-size-aware partition plan (SSOT: [cat.data_partition].min_disk_gb=%min_disk_gb%). Ventoy's /R
:: reserves space at the DISK END for OUR partitions -- a hardcoded 4GB starves %repo_label% and
:: any %data_label% vault, so scale the reservation to the disk: on >=%min_disk_gb%GB reserve everything past
:: a bounded 64GB Ventoy/ISO partition (-> a tiny %repo_label% config + a %data_label% vault for the rest);
:: on disks under %min_disk_gb%GB keep the 4GB floor -- %repo_label% takes it, no %data_label% (degrade-open).
set "vtoy_reserve_mb=4096"
set "mios_repo_gb=0"
set "mios_make_data=0"
:: Capture the plan as a single CSV line (reserve_mb,repo_gb,make_data) via for/f -- robust,
:: no temp .cmd whose multi-line set-commands could collapse onto one line and cross-contaminate.
for /f "usebackq tokens=1,2,3 delims=," %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Partition -DriveLetter '%drivepath%' -ErrorAction SilentlyContinue; $disk = if ($p) { Get-Disk -Number $p.DiskNumber } else { Get-Disk | Where-Object { $_.BusType -in 'USB','SD' } | Sort-Object Size -Descending | Select-Object -First 1 }; if ($disk) { $g=[math]::Floor($disk.Size/1GB); $ventoy=64; $repo=1; $minGB=[int]'%min_disk_gb%'; if ($g -ge $minGB) { $rsv=($g-$ventoy)*1024; $mk=1 } else { $rsv=4096; $repo=0; $mk=0 }; Write-Output ('' + $rsv + ',' + $repo + ',' + $mk) }"`) do (
    set "vtoy_reserve_mb=%%a"
    set "mios_repo_gb=%%b"
    set "mios_make_data=%%c"
)
echo   Disk partition plan: reserve %vtoy_reserve_mb% MB at disk end ^(%repo_label% %mios_repo_gb% GB; %data_label%=%mios_make_data%^)

echo Installing Ventoy to %drivepath%: (%partition_scheme% partition scheme)...
cd /d "%stage_dir%\Ventoy2Disk"
set "vtoy_args=/I /Drive:%drivepath%: /%partition_scheme% /R:%vtoy_reserve_mb%"
if "%secure_boot%"=="Enabled" (
    set "vtoy_args=%vtoy_args% /S"
) else (
    set "vtoy_args=%vtoy_args% /NOUSBCheck"
)
Ventoy2Disk.exe VTOYCLI %vtoy_args%
if errorlevel 1 (
    echo [FAIL] Ventoy install to %drivepath%: FAILED -- the USB will NOT boot. Aborting instead of shipping a dead stick. >&2
    cd /d "%maindir%"
    exit /b 1
)
cd /d "%maindir%"
:: Verify Ventoy actually installed by checking for its VTOYEFI boot partition (VTOYCLI /I creates
:: a ~32MB EFI partition labeled VTOYEFI). The old check looked for %drivepath%:\ventoy\ventoy.json
:: and \grub\ventoy.cfg -- files STAGED LATER, so it false-alarmed on every fresh install.
set "vtoy_ok="
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "if (Get-Volume -FileSystemLabel 'VTOYEFI' -ErrorAction SilentlyContinue) { 'ok' }"`) do set "vtoy_ok=%%v"
if not "%vtoy_ok%"=="ok" (
    echo [WARN] VTOYEFI boot partition not detected after VTOYCLI -- Ventoy may not have installed; boot may be broken. >&2
)

echo Waiting 5s for partition remount...
ping localhost -n 6 >nul

:: Format partition
echo Formatting primary partition as %filesystem% (%partition_label%)...
format %drivepath%: /FS:%filesystem% /X /Q /V:%partition_label% /Y >nul
if errorlevel 1 echo [WARN] format of %drivepath%: returned non-zero -- the data partition may be unusable. >&2

echo Creating secure offline repository partition (%repo_label%)...
echo   (>=%min_disk_gb%GB disks: %repo_label% %mios_repo_gb% GB + a %data_label% vault in the reserved tail;
echo    smaller disks give the whole reserved tail to %repo_label% -- degrade-open, never abort)
powershell -NoProfile -Command "$d = Get-Partition -DriveLetter %drivepath% | Get-Disk; if ('%mios_make_data%' -eq '1') { $rp = New-Partition -DiskNumber $d.Number -Size %mios_repo_gb%GB -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null }; $dp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($dp) { Format-Volume -Partition $dp -FileSystem NTFS -NewFileSystemLabel '%data_label%' -Confirm:$false | Out-Null } } else { $rp = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter -ErrorAction SilentlyContinue; if ($rp) { Format-Volume -Partition $rp -FileSystem NTFS -NewFileSystemLabel '%repo_label%' -Confirm:$false | Out-Null } }" >nul 2>&1

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

:: 6b. Pull/Download the FULL Fedora Server DVD (offline-capable install source)
:: Fedora 40 is EOL (moved to archive.fedoraproject.org) -- pin a CURRENT release and
:: size-validate the download so a 404/redirect stub can never masquerade as the ISO.
set "fedora_ver=44"
set "fedora_build=-1.7"
set "fedora_file=M:\Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso"
if exist "%fedora_file%" echo [OK] Fedora Server DVD found at %fedora_file%
if exist "%fedora_file%" goto fedora_dvd_ok
echo.
echo Fedora Server DVD ISO not found in M:\
echo Pulling the FULL Fedora %fedora_ver% Server DVD ~2.5 GB -- carries packages for OFFLINE install...
curl.exe -C - -L "https://download.fedoraproject.org/pub/fedora/linux/releases/%fedora_ver%/Server/x86_64/iso/Fedora-Server-dvd-x86_64-%fedora_ver%%fedora_build%.iso" -o "%fedora_file%" -#
set "fedora_sz=0"
if exist "%fedora_file%" for %%A in ("%fedora_file%") do set "fedora_sz=%%~zA"
if not "%fedora_sz:~9,1%"=="" goto fedora_dvd_ok
echo [FAIL] Fedora DVD download failed or looks like a 404/redirect stub (%fedora_sz% bytes; a valid DVD is ~2.5 GB). >&2
echo        Confirm Fedora %fedora_ver% is current (bump fedora_ver / use archive.fedoraproject.org), or pre-stage the ISO at %fedora_file%. >&2
del "%fedora_file%" 2>nul
exit /b 1
:fedora_dvd_ok

:: 6c. Ensure the latest SystemRescue (Arch Linux rescue ISO) is staged
set "sysrescue_ver=11.02"
set "sysrescue_target=%drivepath%:\Live_Operating_Systems\SystemRescue\SystemRescue.iso"
if not exist "%sysrescue_target%" if exist "M:\systemrescue-%sysrescue_ver%-amd64.iso" (
    mkdir "%drivepath%:\Live_Operating_Systems\SystemRescue" >nul 2>&1
    copy "M:\systemrescue-%sysrescue_ver%-amd64.iso" "%sysrescue_target%" /Y >nul 2>&1
)
if not exist "%sysrescue_target%" (
    echo.
    echo SystemRescue Arch Linux ISO not found at %sysrescue_target%.
    echo Pulling SystemRescue %sysrescue_ver% Arch rescue ISO...
    mkdir "%drivepath%:\Live_Operating_Systems\SystemRescue" >nul 2>&1
    curl.exe -C - -L "https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/%sysrescue_ver%/systemrescue-%sysrescue_ver%-amd64.iso" -o "%sysrescue_target%" -#
    if errorlevel 1 echo [WARN] Could not pull SystemRescue ISO -- continuing with extraction payload. >&2
)

:: 7. Minimal/Surgical extraction to D:\ to fit the drive
if "%extract_mode%"=="Surgical" (
    echo.
    echo Extracting minimal boot files and portable apps from %file% to %drivepath%:...
    echo Extracting only PE, SystemRescue, and core startup structures...
    "%maindir%\bin\7z.exe" x "%file%" -o%drivepath%:\ Live_Operating_Systems/Mini_Windows/* Live_Operating_Systems/SystemRescue/* System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* Programs/7-Zip_x64/* Programs/Bootice/* Programs/DiskGeniusLite/* Programs/Everything_x64/* Programs/WizTree/* "Programs/HW Monitor/*" Programs/HDSentinel/* Programs/Sysinternals/* Programs/ventoy/* -aoa -y
) else (
    echo.
    echo Extracting ALL files from %file% to %drivepath%:...
    "%maindir%\bin\7z.exe" x "%file%" -o%drivepath%:\ -aoa -y
)

if "%extract_mode%"=="Surgical" (
    echo [DEBLOAT] Purging bloated program folders from %drivepath%:\Programs...
    powershell -NoProfile -Command "$keep = @('7-Zip_x64', 'Bootice', 'DiskGeniusLite', 'Everything_x64', 'WizTree', 'HW Monitor', 'HDSentinel', 'Sysinternals', 'ventoy'); if (Test-Path '%drivepath%:\Programs') { Get-ChildItem -Path '%drivepath%:\Programs' -Directory | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }" >nul 2>&1
)

:skip_extraction
call :check_drive_ready

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

:: Resolve the config + data partitions by LABEL (robust vs partition-number ordering):
::   %repo_label% = tiny shadow-config "brain" (SSOT + launcher, mere MB, always present)
::   %data_label% = the bulk vault (offline repos + CDN/CI + package/dependency/model/OCI-layer
::               caches), present only on >=%min_disk_gb%GB disks. Repos -> %data_label%; brain -> %repo_label%.
for /f "usebackq tokens=1,2 delims=," %%a in (`powershell -NoProfile -Command "$rp=(Get-Volume -FileSystemLabel '%repo_label%' -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter; $dp=(Get-Volume -FileSystemLabel '%data_label%' -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter; if (-not $rp) { $rp='_' }; if (-not $dp) { $dp='_' }; Write-Output ($rp + ',' + $dp)"`) do (
    set "repodrive=%%a"
    set "datadrive=%%b"
)
if "%repodrive%"=="_" set "repodrive=%drivepath%"
if "%datadrive%"=="_" set "datadrive=%repodrive%"
if "%repodrive%"=="" set "repodrive=%drivepath%"
if "%datadrive%"=="" set "datadrive=%repodrive%"

:: Bulk: stage the offline repos onto %data_label% (the big vault) under repos\. The Linux kickstart
:: AND the Windows bootstrap_root resolver both scan every partition/root + a repos\ subdir, so it
:: never matters which partition holds them -- no single location can strand an offline install.
echo Staging offline repositories to the %data_label% vault (%datadrive%:)...
mkdir "%datadrive%:\repos\mios-bootstrap" >nul 2>&1
robocopy "C:\mios-bootstrap" "%datadrive%:\repos\mios-bootstrap" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 >nul
mkdir "%datadrive%:\repos\MiOS" >nul 2>&1
robocopy "C:\MiOS" "%datadrive%:\repos\MiOS" /E /XD .npm node_modules build cache isobuild isobuild2 /R:2 /W:2 >nul

:: Shadow-config "brain": the live SSOT, the architecture diagram, and a self-copy of this
:: launcher on the tiny %repo_label% partition (%repodrive%:) -- always present + mere MB, so a
:: booted/target system can re-read config, re-open the topology, or re-run the flasher offline.
echo Staging shadow-config brain (SSOT + architecture + launcher) to %repo_label% (%repodrive%:)...
if exist "%toml_path%" copy "%toml_path%" "%repodrive%:\mios.toml" /Y >nul 2>&1
copy "%~f0" "%repodrive%:\MiOS-Cat.bat" /Y >nul 2>&1
if exist "%USERPROFILE%\Downloads\mios_visual_architecture_idealistic.html" copy "%USERPROFILE%\Downloads\mios_visual_architecture_idealistic.html" "%repodrive%:\mios.html" /Y >nul 2>&1
if not exist "%repodrive%:\mios.html" if exist "%USERPROFILE%\Downloads\mios_visual_architecture.html" copy "%USERPROFILE%\Downloads\mios_visual_architecture.html" "%repodrive%:\mios.html" /Y >nul 2>&1

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
        attrib -r -h -s "%drivepath%:\%%F\desktop.ini" >nul 2>&1
        attrib -r -h -s "%drivepath%:\%%F\icon.ico" >nul 2>&1
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
call :check_drive_ready
set "wim_path=%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim"
set "serviced_marker=%drivepath%:\Live_Operating_Systems\Mini_Windows\serviced.marker"

set "skip_wim_servicing=0"
if exist "%wim_path%" (
    if exist "%serviced_marker%" (
        if "%bake_drivers%"=="Disabled" (
            set "skip_wim_servicing=1"
        )
    )
)

if "%skip_wim_servicing%"=="1" (
    echo [INFO] Serviced MiOS_PE.wim and marker detected. Skipping offline DISM servicing.
    goto skip_wim_servicing
)

if not exist "%wim_path%" (
    if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" (
        echo Renaming WIM image to MiOS_PE.wim...
        move "%drivepath%:\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim" "%wim_path%" >nul
    )
)

echo Performing offline servicing on MiOS_PE.wim to inject MiOS custom wallpaper...
echo Cleaning up any stale/orphaned DISM mount points...
dism /Cleanup-Wim >nul 2>&1
mkdir "%stage_dir%\mount" >nul 2>&1
echo Mounting WIM image (Index 1)...
dism /Mount-Image /ImageFile:"%wim_path%" /Index:1 /MountDir:"%stage_dir%\mount"

if "%bake_drivers%"=="Enabled" (
    echo.
    echo [DRIVER BAKE] Exporting build-host drivers for WinPE injection...
    echo This may take several minutes depending on the number of host drivers...
    mkdir "%stage_dir%\hostdrivers" >nul 2>&1
    dism /Online /Export-Driver /Destination:"%stage_dir%\hostdrivers"
    echo.
    echo [DRIVER BAKE] Injecting host drivers into MiOS_PE.wim...
    dism /Image:"%stage_dir%\mount" /Add-Driver /Driver:"%stage_dir%\hostdrivers" /Recurse /ForceUnsigned
    rmdir /s /q "%stage_dir%\hostdrivers" >nul 2>&1
) else (
    echo [DRIVER BAKE] Skipped driver bake - disabled in config.
)

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
        echo [WARNING] Unmount failed - possibly locked. Retrying in 4 seconds - attempt %retry_count%/3...
        ping localhost -n 5 >nul
        goto unmount_retry
    )
    echo [ERROR] Failed to unmount the image after 3 attempts. Force-cleaning mount points...
    dism /Cleanup-Wim >nul 2>&1
)
rmdir "%stage_dir%\mount" /S /Q >nul 2>&1

echo Exporting and compressing MiOS_PE.wim to reclaim space...
dism /Export-Image /SourceImageFile:"%wim_path%" /SourceIndex:1 /DestinationImageFile:"%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" /Compress:max >nul 2>&1
if exist "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" (
    del "%wim_path%" /Q
    move "%drivepath%:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim.trim" "%wim_path%" >nul
)
echo Done > "%serviced_marker%"

:skip_wim_servicing

:: 9b. Stage the W10 live-chat ISO (built off-host via 'just live-chat-iso' on a Linux/podman
:: builder). MiOS-Cat.bat only COPIES the finished artifact -- same "M:\ pre-staged input" idiom
:: as fedora_file -- and degrades open (warn + continue) so a missing live-chat ISO never fails
:: the whole USB build. The grub "Chat with MiOS AI" row is media-guarded, so an absent ISO
:: simply hides the row rather than leaving a dead menu entry. Defaults are resolved BEFORE the
:: enabled-check block so the in-block %live_chat_iso_src% is never a stale/empty parse-time value.
if "%live_chat_iso_src%"==""  set "live_chat_iso_src=M:\MiOS-Live-Chat.iso"
if "%live_chat_iso_name%"=="" set "live_chat_iso_name=MiOS-Live-Chat.iso"
if not "%live_chat_enabled%"=="False" (
    if exist "%live_chat_iso_src%" (
        echo Staging W10 live-chat ISO: %live_chat_iso_src% -^> %drivepath%:\Live_Operating_Systems\%live_chat_iso_name%
        copy "%live_chat_iso_src%" "%drivepath%:\Live_Operating_Systems\%live_chat_iso_name%" /Y >nul
        if errorlevel 1 (echo [WARN] Failed to copy the live-chat ISO -- "Chat with MiOS AI" entry stays hidden.) else (echo [OK] Live-chat ISO staged.)
    ) else (
        echo [INFO] No pre-built live-chat ISO at %live_chat_iso_src% -- build it once via 'just live-chat-iso' on a Linux builder ^(automation/build/live-iso.sh^). Skipping; the "Chat with MiOS AI" row stays hidden ^(media-guarded, no dead menu row^).
    )
)

:: 10. Compile the inline live build of MiOS-Xbox ISO directly to the USB drive
if "%build_xbox%" neq "Enabled" goto skip_xbox_build

call :check_drive_ready
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autounattend\Render-MiosRunToml.ps1" -TomlPath "%toml_path%" -UupChannel "%uup_channel%" -BakeDrivers "%bake_drivers%" -GamingOptimize "%gaming_optimize%"
powershell -NoProfile -Command "$v = Get-Volume; $target = $null; $max = 0; foreach ($vol in $v) { if ($vol.DriveType -eq 'Fixed' -and $vol.SizeRemaining -gt 15GB -and $vol.SizeRemaining -gt $max) { $max = $vol.SizeRemaining; $target = $vol } }; $p = if ($target) { $target.DriveLetter + ':\MiOS\isobuild_live' } else { 'C:\MiOS\isobuild_live' }; [System.IO.File]::WriteAllText(\"%~dp0work_path.txt\", $p)"
set /p workdir_path=<"%~dp0work_path.txt"
del "%~dp0work_path.txt" /Q >nul 2>&1
powershell.exe -ExecutionPolicy Bypass -File "C:\mios-bootstrap\cat\autounattend\Build-MiOSXboxISO.ps1" -TomlPath "%temp%\mios_run.toml" -OutIso "%drivepath%:\Live_Operating_Systems\MiOS-Xbox.iso" -WorkDir "%workdir_path%" -SkipWsl -SkipPrereqs

:skip_xbox_build

echo.
echo ==========================================================
echo     MiOS-Cat DEDICATED USB INSTALLATION COMPLETED         
echo ==========================================================
echo Drive %drivepath%: is now ready to boot into MiOS-Cat!
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
for /f "usebackq tokens=*" %%d in (`powershell -NoProfile -Command "if (Get-Volume ^| Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }) { 'removable USB present' } else { 'no removable USB detected' }"`) do set "env_disk=%%d"
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


