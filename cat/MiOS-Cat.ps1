# MiOS Dedicated Multiboot USB Installer
# Installs a minimal, themed recovery environment based on the Ventoy/MediCat core

$ErrorActionPreference = "Stop"

# 1. Admin elevation check
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching script with Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "      MiOS DEDICATED RECOVERY USB DEPLOYMENT TOOL         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "This script formats a USB drive with Ventoy and sets up a"
Write-Host "minimal, themed MiOS recovery/wipe utility platform."
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Resolve dynamic configuration from mios.toml (SSOT).
# The launcher lives at <repo>\cat\, so the repo-local SSOT (which also travels
# with the MiOS-Repo USB) is one level up; fall back to the canonical MiOS SSOT
# on a MiOS-equipped host. (Future [cat] SSOT block -> T-258.)
$tomlPath = Join-Path $PSScriptRoot "..\mios.toml"
if (-not (Test-Path $tomlPath)) {
    $tomlPath = "C:\MiOS\usr\share\mios\mios.toml"
}

# Default variables
$targetDrive = "D"
$medicatVer = "21.12"
$cachePath = "M:\MediCat.USB.v21.12.7z"
$bgColor = "#282262"
$fgColor = "#E7DFD3"
$accentColor = "#1A407F"
$cursorColor = "#F35C15"
$successColor = "#3E7765"
$mutedColor = "#948E8E"
$subtleColor = "#B7C9D7"
$extractMode = "Surgical"
$buildXbox = $true
$partitionLabel = "MiOS-Cat"
$partitionScheme = "GPT"
$filesystem = "NTFS"
$secureBoot = $false
$paTheme = "Dark"
$bakeDrivers = $true
$uupChannel = "Dev"
$gamingOptimize = $true

if (Test-Path $tomlPath) {
    $tomlContent = Get-Content $tomlPath
    
    function Get-TomlValue {
        param($pattern, $default)
        $line = $tomlContent | Select-String -Pattern $pattern
        if ($line -and $line.Matches.Groups[1].Value) {
            return $line.Matches.Groups[1].Value.Trim()
        }
        return $default
    }
    
    $targetDrive = Get-TomlValue -pattern '^\s*drivepath\s*=\s*"(.*)"' -default "D"
    $medicatVer = Get-TomlValue -pattern '^\s*medicatver\s*=\s*"(.*)"' -default "21.12"
    $cachePath = Get-TomlValue -pattern '^\s*cache_path\s*=\s*"(.*)"' -default "M:\MediCat.USB.v21.12.7z"
    $bgColor = Get-TomlValue -pattern '^\s*bg\s*=\s*"(.*)"' -default "#282262"
    $fgColor = Get-TomlValue -pattern '^\s*fg\s*=\s*"(.*)"' -default "#E7DFD3"
    $accentColor = Get-TomlValue -pattern '^\s*accent\s*=\s*"(.*)"' -default "#1A407F"
    $cursorColor = Get-TomlValue -pattern '^\s*cursor\s*=\s*"(.*)"' -default "#F35C15"
    $successColor = Get-TomlValue -pattern '^\s*success\s*=\s*"(.*)"' -default "#3E7765"
    $mutedColor = Get-TomlValue -pattern '^\s*muted\s*=\s*"(.*)"' -default "#948E8E"
    $subtleColor = Get-TomlValue -pattern '^\s*subtle\s*=\s*"(.*)"' -default "#B7C9D7"
}

function Reset-MiosColors {
    if (Test-Path $tomlPath) {
        $script:bgColor = Get-TomlValue -pattern '^\s*bg\s*=\s*"(.*)"' -default "#282262"
        $script:fgColor = Get-TomlValue -pattern '^\s*fg\s*=\s*"(.*)"' -default "#E7DFD3"
        $script:accentColor = Get-TomlValue -pattern '^\s*accent\s*=\s*"(.*)"' -default "#1A407F"
        $script:cursorColor = Get-TomlValue -pattern '^\s*cursor\s*=\s*"(.*)"' -default "#F35C15"
        $script:successColor = Get-TomlValue -pattern '^\s*success\s*=\s*"(.*)"' -default "#3E7765"
        $script:mutedColor = Get-TomlValue -pattern '^\s*muted\s*=\s*"(.*)"' -default "#948E8E"
        $script:subtleColor = Get-TomlValue -pattern '^\s*subtle\s*=\s*"(.*)"' -default "#B7C9D7"
    }
}

# ---------------------------------------------------------------------------
# MiOS-Cat build / on-boarding helpers (parity with MiOS-Cat.bat).
# NOTE: the build-driver + Xbox-builder paths below have no SSOT home yet;
# sibling task T-258 adds a [cat] table to mios.toml. Until it lands these are
# clearly-marked defaults -- wire to [cat].build_driver / [cat].xbox_builder.
# ---------------------------------------------------------------------------
function Resolve-MiosBootstrapRoot {
    # Offline-first: the mios-bootstrap tree this launcher runs under (USB
    # MiOS-Repo or C:), then the dev checkout, then any staged MiOS-Repo drive.
    foreach ($c in @((Join-Path $PSScriptRoot ".."), "C:\mios-bootstrap")) {
        if ($c -and (Test-Path (Join-Path $c "build-mios.ps1"))) { return (Resolve-Path $c).Path }
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)) {
        if (Test-Path "$($d):\mios-bootstrap\build-mios.ps1") { return "$($d):\mios-bootstrap" }
    }
    return $null
}
function Resolve-MiosXboxBuilder {
    # [cat].xbox_builder SSOT override (an absolute path) wins if set + present.
    if ($script:tomlContent) {
        $o = ($script:tomlContent | Select-String -Pattern '^\s*xbox_builder\s*=\s*"(.*)"' |
              ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1)
        if ($o -and (Test-Path $o)) { return $o }
    }
    # Canonical relocated path is cat\autounattend\. Prefer the one-shot
    # self-provisioning wrapper, else the DISM orchestrator.
    foreach ($c in @(
        (Join-Path $PSScriptRoot "autounattend\Build-MiOSXbox.ps1"),
        (Join-Path $PSScriptRoot "autounattend\New-MiOSISO.ps1"),
        "C:\mios-bootstrap\cat\autounattend\Build-MiOSXbox.ps1",
        "C:\mios-bootstrap\cat\autounattend\New-MiOSISO.ps1")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}
function Get-MiosEnv {
    $h = "Windows host"
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT") { $h = "WinPE (offline servicing)" }
    $net = "Offline"; try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { $net = "Online" } } catch {}
    $b = "not provisioned (Build will self-bootstrap)"
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $b = "WSL2 present" }
    $disk = "no removable USB detected"
    if (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }) { $disk = "removable USB present" }
    return [pscustomobject]@{ HostKind = $h; Net = $net; Builder = $b; Disk = $disk }
}
function Invoke-MiosOciBuild {
    param([switch]$All)
    Clear-Host
    if ($All) {
        Write-Host "Build ALL MiOS Artifacts" -ForegroundColor Cyan
        Write-Host "  Produces : localhost/mios:latest PLUS raw/iso/qcow2/vhd/wsl2"
        Write-Host "  Where    : /var/lib/mios/build/output inside MiOS-DEV"
        Write-Host "  Size/Time: ~30-40 GB, 45-90 min (full matrix)"
    } else {
        Write-Host "Build MiOS OCI Image" -ForegroundColor Cyan
        Write-Host "  Produces : localhost/mios:latest (bootc OS image)"
        Write-Host "  Where    : MiOS-DEV podman storage on this host"
        Write-Host "  Time     : 20-60 min on first run"
    }
    Write-Host "  Toolchain (WSL2 + podman + MiOS-DEV) is auto-provisioned if"
    Write-Host "  missing, offline-first from MiOS-Repo, else online."
    if ((Read-Host "Start this build now? (Y/N)") -notmatch '^(y|Y)') { return }
    $root = Resolve-MiosBootstrapRoot
    if (-not $root) {
        Write-Host "No local build driver (build-mios.ps1) on host or MiOS-Repo payload." -ForegroundColor Yellow
        if ((Read-Host "Fetch + run the online MiOS bootstrap now? (Y/N)") -match '^(y|Y)') {
            $online = $false; try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { $online = $true } } catch {}
            if (-not $online) { Write-Host "[OFFLINE] no internet and no offline payload. Stage this USB on a connected PC first." -ForegroundColor Yellow }
            else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex" }
        }
        Read-Host "Press Enter to return to the menu" | Out-Null
        return
    }
    $driver = Join-Path $root "build-mios.ps1"
    Write-Host ""
    Write-Host "[BUILD] Driver : $driver"
    if ($All) { Write-Host "[BUILD] Mode   : full matrix (OCI + all [deployment] targets)"; Remove-Item Env:\MIOS_SKIP_BIB -ErrorAction SilentlyContinue }
    else { Write-Host "[BUILD] Mode   : OCI only (MIOS_SKIP_BIB=1)"; $env:MIOS_SKIP_BIB = '1' }
    Write-Host "[BUILD] Progress streams below and/or in the MiOS-DEV window."
    Write-Host ""
    $rc = 0
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $driver -Unattended; $rc = $LASTEXITCODE }
    catch { Write-Host "[WARN] build driver error: $($_.Exception.Message)" -ForegroundColor Yellow; $rc = 1 }
    finally { Remove-Item Env:\MIOS_SKIP_BIB -ErrorAction SilentlyContinue }
    Write-Host ""
    if ($rc -eq 0) { Write-Host "[OK] Build step finished." -ForegroundColor Green }
    else { Write-Host "[WARN] build driver exit code $rc - review the log above; you can re-run." -ForegroundColor Yellow }
    Read-Host "Press Enter to return to the menu" | Out-Null
}
function Invoke-MiosXboxBuild {
    Clear-Host
    Write-Host "Build MiOS-Xbox ISO" -ForegroundColor Cyan
    Write-Host "  Produces : MiOS-Xbox.iso (custom Windows 11 gaming edition)"
    Write-Host "  Pipeline : UUP fetch -> DISM offline servicing -> oscdimg"
    Write-Host "  Toolchain: DISM ships in Windows; UUP media offline-first"
    Write-Host "             from MiOS-Repo, else online."
    if ((Read-Host "Start the MiOS-Xbox ISO build now? (Y/N)") -notmatch '^(y|Y)') { return }
    $builder = Resolve-MiosXboxBuilder
    if (-not $builder) {
        Write-Host "MiOS-Xbox builder not found under cat\autounattend\. Stage this USB first." -ForegroundColor Yellow
        Read-Host "Press Enter to return to the menu" | Out-Null; return
    }
    Write-Host ""
    Write-Host "[BUILD] Builder: $builder"
    Write-Host ""
    $rc = 0
    try {
        if (Test-Path $tomlPath) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -TomlPath $tomlPath }
        else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder }
        $rc = $LASTEXITCODE
    } catch { Write-Host "[WARN] $($_.Exception.Message)" -ForegroundColor Yellow; $rc = 1 }
    Write-Host ""
    if ($rc -eq 0) { Write-Host "[OK] MiOS-Xbox ISO build finished." -ForegroundColor Green }
    else { Write-Host "[WARN] Xbox builder exit code $rc - review the log above." -ForegroundColor Yellow }
    Read-Host "Press Enter to return to the menu" | Out-Null
}
function Invoke-MiosDeployScript {
    param([string]$Name, [string]$Label)
    Clear-Host
    Write-Host $Label -ForegroundColor Cyan
    if ((Read-Host "Run $Label now? (Y/N)") -notmatch '^(y|Y)') { return }
    $script = $null
    foreach ($c in @((Join-Path $PSScriptRoot "autounattend\$Name"), "C:\mios-bootstrap\cat\autounattend\$Name")) {
        if (Test-Path $c) { $script = $c; break }
    }
    if (-not $script) { Write-Host "$Name not found - stage the USB payload first." -ForegroundColor Yellow; Read-Host "Press Enter to return" | Out-Null; return }
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script } catch { Write-Host "[WARN] $($_.Exception.Message)" -ForegroundColor Yellow }
    Read-Host "Press Enter to return to the menu" | Out-Null
}

# First-run default is the guided Quick Start; the full menu stays one key away.
# An optional verb argument deep-links to a surface (parity with the .bat).
$currentMenu = "quickstart"
if ($args.Count -gt 0) {
    switch -Regex ($args[0]) {
        '^(?i)menu$'                        { $currentMenu = "main" }
        '^(?i)build$'                       { $currentMenu = "build" }
        '^(?i)stage$'                       { $currentMenu = "stage" }
        '^(?i)(install|deploy|provision)$'  { $currentMenu = "deploy" }
        '^(?i)update$'                      { $currentMenu = "update" }
        '^(?i)config$'                      { $currentMenu = "config" }
        '^(?i)(manual|help)$'               { $currentMenu = "manual" }
        default                             { $currentMenu = "quickstart" }
    }
}

while ($true) {
    if ($currentMenu -eq "main") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "       M i O S - C a t     Control Center                 " -ForegroundColor Cyan
        Write-Host "       Deploy . Build . Stage . Configure                 " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  Palette  bg [$bgColor]  accent [$accentColor]  ok [$successColor]" -ForegroundColor DarkGray
        Write-Host "----------------------------------------------------------"
        Write-Host "  Quick Start"
        Write-Host "    1) On-boarding / Quick Start   (guided)"
        Write-Host "  Build"
        Write-Host "    2) Build MiOS Images           (OCI . Xbox ISO . all)"
        Write-Host "  Deploy"
        Write-Host "    3) Stage USB                   (MiOS-Repo bootable)"
        Write-Host "    4) Install / Deploy            (provision a target)"
        Write-Host "  Maintain"
        Write-Host "    5) Update                      (pull latest MiOS)"
        Write-Host "    6) Configuration               (USB . FS . theme . Xbox)"
        Write-Host "    7) Repository Tools            (open repos . edit TOML)"
        Write-Host "  Help"
        Write-Host "    8) Manual / Help"
        Write-Host "    9) Exit"
        Write-Host "==========================================================" -ForegroundColor Cyan
        
        switch (Read-Host "Select an option (1-9)") {
            "1" { $currentMenu = "quickstart" }
            "2" { $currentMenu = "build" }
            "3" { $currentMenu = "stage" }
            "4" { $currentMenu = "deploy" }
            "5" { $currentMenu = "update" }
            "6" { $currentMenu = "config" }
            "7" { $currentMenu = "repos" }
            "8" { $currentMenu = "manual" }
            "9" { exit }
        }
    }
    elseif ($currentMenu -eq "stage") {
        Clear-Host
        Write-Host "STAGE MiOS-Cat BOOTABLE USB" -ForegroundColor Cyan
        Write-Host "=============================="
        Write-Host "Target Drive      : $targetDrive`:"
        Write-Host "Cache File        : $cachePath"
        Write-Host "Extraction Mode   : $extractMode"
        Write-Host "Build MiOS-Xbox   : $buildXbox"
        Write-Host "Partition Label   : $partitionLabel"
        Write-Host "Partition Scheme  : $partitionScheme"
        Write-Host "Filesystem        : $filesystem"
        Write-Host "Secure Boot       : $(if($secureBoot){'Enabled'}else{'Disabled'})"
        Write-Host "PortableApps Theme: $paTheme"
        Write-Host "Background Color  : $bgColor"
        Write-Host "Foreground Color  : $fgColor"
        Write-Host "Accent Color      : $accentColor"
        Write-Host "Cursor Color      : $cursorColor"
        Write-Host "Success Color     : $successColor"
        Write-Host "Muted Color       : $mutedColor"
        Write-Host "Subtle Color      : $subtleColor"
        Write-Host "Xbox Bake Drivers : $bakeDrivers"
        Write-Host "Xbox UUP Channel  : $uupChannel"
        Write-Host "Xbox Gaming Opt   : $gamingOptimize"
        Write-Host "=============================="
        Write-Host "WARNING: ALL DATA ON DRIVE [$targetDrive`:] WILL BE PERMANENTLY ERASED!" -ForegroundColor Red
        $confirm = Read-Host "Are you absolutely sure you want to proceed? (type YES to confirm)"
        if ($confirm -eq "YES") {
            break
        }
        $currentMenu = "main"
    }
    elseif ($currentMenu -eq "quickstart") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "       M i O S - C a t     Quick Start  (guided)          " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  MiOS-Cat turns a shareable link + this USB + any PC into"
        Write-Host "  a complete MiOS workshop. Four things it can do:"
        Write-Host ""
        Write-Host "    [STAGE ]  build a bootable MiOS-Cat USB (recovery + repo)"
        Write-Host "    [BUILD ]  build a MiOS image (OCI / Xbox ISO / all)"
        Write-Host "    [DEPLOY]  install / provision MiOS onto a machine"
        Write-Host "    [CONFIG]  drive, filesystem, theme and build options"
        Write-Host "----------------------------------------------------------"
        $envInfo = Get-MiosEnv
        Write-Host "  Environment:"
        Write-Host "    Host        : $($envInfo.HostKind)"
        Write-Host "    Network     : $($envInfo.Net)"
        Write-Host "    Privileges  : Administrator (verified)"
        Write-Host "    Build host  : $($envInfo.Builder)"
        Write-Host "    Target disk : $($envInfo.Disk)"
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Stage a bootable USB        (recommended first run)"
        Write-Host "  2) Build a MiOS image"
        Write-Host "  3) Install / Deploy MiOS"
        Write-Host "  4) Configuration"
        Write-Host "  5) Open the full menu"
        Write-Host "  6) Exit"
        switch (Read-Host "Select an option (1-6)") {
            "1" { $currentMenu = "stage" }
            "2" { $currentMenu = "build" }
            "3" { $currentMenu = "deploy" }
            "4" { $currentMenu = "config" }
            "5" { $currentMenu = "main" }
            "6" { exit }
        }
    }
    elseif ($currentMenu -eq "build") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Build MiOS Images" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  Builds MiOS from THIS machine. A missing toolchain (WSL2"
        Write-Host "  + podman + the MiOS-DEV builder) is auto-provisioned"
        Write-Host "  offline-first from the MiOS-Repo payload, else online."
        Write-Host "  DISM (used by the Xbox ISO) already ships in Windows."
        Write-Host "----------------------------------------------------------"
        Write-Host "  1) Build MiOS OCI image   : localhost/mios:latest"
        Write-Host "  2) Build MiOS-Xbox ISO    : Windows 11 gaming edition"
        Write-Host "  3) Build ALL artifacts    : OCI + raw/iso/qcow2/vhd/wsl2"
        Write-Host "  4) Back to Main Menu"
        Write-Host "==========================================================" -ForegroundColor Cyan
        switch (Read-Host "Select an option (1-4)") {
            "1" { Invoke-MiosOciBuild }
            "2" { Invoke-MiosXboxBuild }
            "3" { Invoke-MiosOciBuild -All }
            "4" { $currentMenu = "main" }
        }
    }
    elseif ($currentMenu -eq "deploy") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Install / Deploy MiOS" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Stage a bootable MiOS-Cat USB   (full pipeline)"
        Write-Host "  2) Provision MiOS-Xbox on a target (autounattend)"
        Write-Host "  3) Deploy / test MiOS-Xbox VM      (Hyper-V)"
        Write-Host "  4) Back to Main Menu"
        Write-Host "==========================================================" -ForegroundColor Cyan
        switch (Read-Host "Select an option (1-4)") {
            "1" { $currentMenu = "stage" }
            "2" { Invoke-MiosDeployScript "Invoke-MiOSProvision.ps1" "Provision MiOS-Xbox (autounattend)" }
            "3" { Invoke-MiosDeployScript "Deploy-MiOSXbox.ps1" "Deploy / test MiOS-Xbox VM (Hyper-V)" }
            "4" { $currentMenu = "main" }
        }
    }
    elseif ($currentMenu -eq "update") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Update MiOS" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  Pulls the latest MiOS and mios-bootstrap (git fetch + pull)."
        if ((Read-Host "Check for and pull updates now? (Y/N)") -match '^(y|Y)') {
            $online = $false; try { if ([System.Net.Dns]::GetHostAddresses('github.com')) { $online = $true } } catch {}
            if (-not $online) { Write-Host "[OFFLINE] internet unreachable - cannot pull updates." -ForegroundColor Yellow }
            else {
                foreach ($repo in @(@{ P = 'C:\MiOS'; N = 'MiOS' }, @{ P = 'C:\mios-bootstrap'; N = 'mios-bootstrap' })) {
                    if (Test-Path (Join-Path $repo.P ".git")) {
                        Write-Host "Updating $($repo.N) at $($repo.P) ..." -ForegroundColor Green
                        Push-Location $repo.P; & git fetch 2>&1 | Out-Null; & git pull; Pop-Location
                    } else { Write-Host "[SKIP] $($repo.N) is not a git checkout." -ForegroundColor DarkGray }
                }
                Write-Host "[OK] Update check complete." -ForegroundColor Green
            }
            Read-Host "Press Enter to return to the menu" | Out-Null
        }
        $currentMenu = "main"
    }
    elseif ($currentMenu -eq "config") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Configuration" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) USB Target Settings    : Drive [$targetDrive`:], Label [$partitionLabel]"
        Write-Host "  2) Ventoy / FS Settings   : Format [$filesystem], Scheme [$partitionScheme]"
        Write-Host "  3) MiOS-Xbox Build Config : Drivers [$(if($bakeDrivers){'Enabled'}else{'Disabled'})], Channel [$uupChannel]"
        Write-Host "  4) Theme Colors           : Accent [$accentColor], Subtle [$subtleColor]"
        Write-Host "  5) Back to Main Menu"
        Write-Host "==========================================================" -ForegroundColor Cyan
        switch (Read-Host "Select an option (1-5)") {
            "1" { $currentMenu = "usb" }
            "2" { $currentMenu = "ventoy" }
            "3" { $currentMenu = "xbox" }
            "4" { $currentMenu = "colors" }
            "5" { $currentMenu = "main" }
        }
    }
    elseif ($currentMenu -eq "manual") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Manual / Help" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) About MiOS-Cat (what each menu does)"
        Write-Host "  2) Open MiOS-Xbox build + pipeline docs"
        Write-Host "  3) Open the mios-bootstrap folder"
        Write-Host "  4) Back to Main Menu"
        Write-Host "==========================================================" -ForegroundColor Cyan
        switch (Read-Host "Select an option (1-4)") {
            "1" {
                Clear-Host
                Write-Host "About MiOS-Cat" -ForegroundColor Cyan
                Write-Host "  Quick Start : guided on-boarding; detects env, routes you."
                Write-Host "  Build       : OCI (localhost/mios:latest), Xbox ISO, or all"
                Write-Host "                artifacts. Toolchain self-provisions if missing."
                Write-Host "  Stage USB   : Ventoy + MiOS-Cat recovery + MiOS-Repo partition."
                Write-Host "  Deploy      : provision / deploy MiOS onto a target."
                Write-Host "  Update      : pull latest MiOS + mios-bootstrap."
                Write-Host "  Config      : drive, filesystem, theme, Xbox build."
                Write-Host "  Repo Tools  : open repos, edit mios.toml SSOT."
                Read-Host "Press Enter to return" | Out-Null
            }
            "2" {
                $docs = @((Join-Path $PSScriptRoot "autounattend\docs"), "C:\mios-bootstrap\cat\autounattend\docs") | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($docs) { Start-Process explorer.exe $docs } else { Start-Process "https://github.com/mios-dev/mios-bootstrap" }
            }
            "3" { Start-Process explorer.exe (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
            "4" { $currentMenu = "main" }
        }
    }
    elseif ($currentMenu -eq "usb") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               USB Target Settings" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Target USB Drive Letter : [$targetDrive`:]"
        Write-Host "  2) Format Partition Label  : [$partitionLabel]"
        Write-Host "  3) Back to Configuration"
        Write-Host "==========================================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option (1-3)"
        switch ($choice) {
            "1" {
                Clear-Host
                Write-Host "Connected USB drives:" -ForegroundColor Green
                $removableDrives = Get-Volume | Where-Object {$_.DriveType -eq 'Removable'}
                if ($removableDrives.Count -eq 0) {
                    Write-Host "No removable USB drives found!" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                $driveMap = @{}
                $i = 1
                foreach ($d in $removableDrives) {
                    Write-Host "$i) Drive [$($d.DriveLetter):] - $($d.FriendlyName) ($($d.FileSystemType)) - $([Math]::Round($d.Size / 1GB, 2)) GB"
                    $driveMap[$i] = $d.DriveLetter
                    $i++
                }
                Write-Host ""
                $sel = Read-Host "Select the drive number"
                if ($driveMap.ContainsKey([int]$sel)) {
                    $targetDrive = $driveMap[[int]$sel]
                }
            }
            "2" {
                Clear-Host
                Write-Host "Current partition label: $partitionLabel"
                $newLabel = Read-Host "Enter partition label (or press Enter to keep)"
                if (-not [string]::IsNullOrWhiteSpace($newLabel)) {
                    $partitionLabel = $newLabel
                }
            }
            "3" { $currentMenu = "config" }
        }
    }
    elseif ($currentMenu -eq "ventoy") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Ventoy / FS / Extraction Settings" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Partition Scheme        : [$partitionScheme]"
        Write-Host "  2) Filesystem Format       : [$filesystem]"
        Write-Host "  3) Secure Boot Support     : [$(if($secureBoot){'Enabled'}else{'Disabled'})]"
        Write-Host "  4) Core Download Cache     : [$cachePath]"
        Write-Host "  5) Extraction Mode         : [$extractMode]"
        Write-Host "  6) PortableApps Theme      : [$paTheme]"
        Write-Host "  7) Back to Configuration"
        Write-Host "==========================================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option (1-7)"
        switch ($choice) {
            "1" {
                if ($partitionScheme -eq "GPT") { $partitionScheme = "MBR" } else { $partitionScheme = "GPT" }
            }
            "2" {
                if ($filesystem -eq "NTFS") { $filesystem = "exFAT" } else { $filesystem = "NTFS" }
            }
            "3" { $secureBoot = -not $secureBoot }
            "4" {
                Clear-Host
                Write-Host "Current cache path: $cachePath"
                $newCache = Read-Host "Enter full path to MediCat core 7z (or press Enter to keep)"
                if (-not [string]::IsNullOrWhiteSpace($newCache)) { $cachePath = $newCache }
            }
            "5" {
                if ($extractMode -eq "Surgical") { $extractMode = "Full" } else { $extractMode = "Surgical" }
            }
            "6" {
                if ($paTheme -eq "Dark") { $paTheme = "Classic" } else { $paTheme = "Dark" }
            }
            "7" { $currentMenu = "config" }
        }
    }
    elseif ($currentMenu -eq "colors") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Customize Theme Colors" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Background Color (bg)   : [$bgColor]"
        Write-Host "  2) Foreground Color (fg)   : [$fgColor]"
        Write-Host "  3) Accent Color (accent)   : [$accentColor]"
        Write-Host "  4) Cursor Color (cursor)   : [$cursorColor]"
        Write-Host "  5) Success Color (success) : [$successColor]"
        Write-Host "  6) Muted Color (muted)     : [$mutedColor]"
        Write-Host "  7) Subtle Color (subtle)   : [$subtleColor]"
        Write-Host "  8) Reset to base TOML colors"
        Write-Host "  9) Back to Configuration"
        Write-Host "==========================================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option (1-9)"
        switch ($choice) {
            "1" { $val = Read-Host "Enter BG hex color"; if($val){$bgColor = $val} }
            "2" { $val = Read-Host "Enter FG hex color"; if($val){$fgColor = $val} }
            "3" { $val = Read-Host "Enter Accent hex color"; if($val){$accentColor = $val} }
            "4" { $val = Read-Host "Enter Cursor hex color"; if($val){$cursorColor = $val} }
            "5" { $val = Read-Host "Enter Success hex color"; if($val){$successColor = $val} }
            "6" { $val = Read-Host "Enter Muted hex color"; if($val){$mutedColor = $val} }
            "7" { $val = Read-Host "Enter Subtle hex color"; if($val){$subtleColor = $val} }
            "8" { Reset-MiosColors }
            "9" { $currentMenu = "config" }
        }
    }
    elseif ($currentMenu -eq "xbox") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               MiOS-Xbox Build Config" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Compile MiOS-Xbox ISO   : [$(if($buildXbox){'Enabled'}else{'Disabled'})]"
        Write-Host "  2) Bake Host Drivers       : [$(if($bakeDrivers){'Enabled'}else{'Disabled'})]"
        Write-Host "  3) Microsoft UUP Channel   : [$uupChannel]"
        Write-Host "  4) Gaming Optimizations    : [$(if($gamingOptimize){'Enabled'}else{'Disabled'})]"
        Write-Host "  5) Back to Configuration"
        Write-Host "==========================================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option (1-5)"
        switch ($choice) {
            "1" { $buildXbox = -not $buildXbox }
            "2" { $bakeDrivers = -not $bakeDrivers }
            "3" {
                if ($uupChannel -eq "Dev") { $uupChannel = "Beta" }
                elseif ($uupChannel -eq "Beta") { $uupChannel = "Release" }
                else { $uupChannel = "Dev" }
            }
            "4" { $gamingOptimize = -not $gamingOptimize }
            "5" { $currentMenu = "config" }
        }
    }
    elseif ($currentMenu -eq "repos") {
        Clear-Host
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "               Repository Tools" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  1) Open MiOS Repository (C:\MiOS)"
        Write-Host "  2) Open mios-bootstrap Repository (C:\mios-bootstrap)"
        Write-Host "  3) Edit base mios.toml configuration"
        Write-Host "  4) Back to Main Menu"
        Write-Host "==========================================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option (1-4)"
        switch ($choice) {
            "1" { Start-Process explorer.exe "C:\MiOS" }
            "2" { Start-Process explorer.exe "C:\mios-bootstrap" }
            "3" { Start-Process notepad.exe "`"$tomlPath`"" }
            "4" { $currentMenu = "main" }
        }
    }
}

# 3. Download/Extract Ventoy if not already local
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ventoyDir = Join-Path $scriptDir "Ventoy2Disk"
if (-not (Test-Path $ventoyDir)) {
    Write-Host "Downloading latest Ventoy bootloader files..." -ForegroundColor Green
    $ventoyReleaseUrl = "https://api.github.com/repos/ventoy/ventoy/releases/latest"
    $response = Invoke-RestMethod -Uri $ventoyReleaseUrl -UseBasicParsing
    $tag = $response.tag_name
    $ver = $tag.Replace("v", "")
    $downloadUrl = "https://github.com/ventoy/Ventoy/releases/download/$tag/ventoy-$ver-windows.zip"
    $zipPath = Join-Path $scriptDir "ventoy.zip"
    
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $scriptDir -Force
    Remove-Item $zipPath -Force
    Rename-Item -Path (Join-Path $scriptDir "ventoy-$ver") -NewName "Ventoy2Disk" -Force
}

# 4. Install Ventoy to USB Disk
Write-Host "Formatting and installing Ventoy to USB drive [$($targetDrive):]..." -ForegroundColor Green
$vtoyCli = Join-Path $ventoyDir "Ventoy2Disk.exe"
$vtoyArgs = "VTOYCLI /I /Drive:$($targetDrive): /NOUSBCheck /$partitionScheme"
if ($secureBoot) {
    $vtoyArgs = "VTOYCLI /I /Drive:$($targetDrive): /S /$partitionScheme"
}
Start-Process -FilePath $vtoyCli -ArgumentList $vtoyArgs -NoNewWindow -Wait

# Wait for drive remount
Start-Sleep -Seconds 5
$driveMounted = Test-Path "$($targetDrive):\"
if (-not $driveMounted) {
    Write-Host "Waiting for drive to mount..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

# Format primary partition and name it $partitionLabel
Write-Host "Applying file system format ($filesystem / $partitionLabel)..." -ForegroundColor Green
Format-Volume -DriveLetter $targetDrive -FileSystem $filesystem -NewFileSystemLabel $partitionLabel -Confirm:$false -Force

# 5. Create core folders
Write-Host "Creating deployment directory structure..." -ForegroundColor Green
$folders = @(
    "ventoy",
    "ventoy\theme\uefi",
    "ventoy\theme\legacy",
    "Live_Operating_Systems\Mini_Windows",
    "Live_Operating_Systems\SystemRescue",
    "Programs",
    "PortableApps",
    "autorun"
)
foreach ($f in $folders) {
    New-Item -ItemType Directory -Force -Path "$($targetDrive):\$f" | Out-Null
}

# 6. Copy templates and customizations
Write-Host "Copying customization configurations..." -ForegroundColor Green
$resourceDir = Join-Path $scriptDir "resources"
Copy-Item -Path "$resourceDir\ventoy\*" -Destination "$($targetDrive):\ventoy\" -Recurse -Force
Copy-Item -Path "$resourceDir\theme\*" -Destination "$($targetDrive):\ventoy\theme\" -Recurse -Force
Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun.sh" -Force
Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun\autorun.sh" -Force
Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun\autorun" -Force
Copy-Item -Path "$resourceDir\CdUsb.Y" -Destination "$($targetDrive):\CdUsb.Y" -Force

# 7. Check for / copy core system images (Mini Windows WIM & SystemRescue ISO)
$targetWim = "$($targetDrive):\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim"
$targetIso = "$($targetDrive):\Live_Operating_Systems\SystemRescue\SystemRescue.iso"

# Check standard local paths first to save download time
$localWimSources = @(
    "C:\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim",
    "C:\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim"
)
$localIsoSources = @(
    "C:\Live_Operating_Systems\SystemRescue\SystemRescue.iso"
)

# Search for the files on other local drives (like M:)
foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)) {
    if ($drive -ne "C" -and $drive -ne $targetDrive) {
        $localWimSources += "$($drive):\Live_Operating_Systems\Mini_Windows\MiOS_PE.wim"
        $localWimSources += "$($drive):\Live_Operating_Systems\Mini_Windows\Mini_Windows_10.wim"
        $localIsoSources += "$($drive):\Live_Operating_Systems\SystemRescue\SystemRescue.iso"
    }
}

# Process PE Image
$copiedWim = $false
foreach ($src in $localWimSources) {
    if (Test-Path $src) {
        Write-Host "Copying local PE base image from $src..." -ForegroundColor Green
        Copy-Item -Path $src -Destination $targetWim -Force
        $copiedWim = $true
        break
    }
}
if (-not $copiedWim) {
    Write-Host "Downloading basic recovery PE image from network..." -ForegroundColor Yellow
    # Fallback to downloading a standard small WinPE payload
    $peUrl = "https://raw.githubusercontent.com/mon5termatt/medicat_installer/main/download/pe_stub_placeholder" # Replace with real small WinPE repo/CDN path if available
    # For now, print message to alert user or mock download
    Write-Host "Warning: No local MiOS_PE.wim found. Please place your custom PE .wim file at: $($targetWim)" -ForegroundColor Yellow
}

# Process SystemRescue ISO
$copiedIso = $false
foreach ($src in $localIsoSources) {
    if (Test-Path $src) {
        Write-Host "Copying local SystemRescue ISO from $src..." -ForegroundColor Green
        Copy-Item -Path $src -Destination $targetIso -Force
        $copiedIso = $true
        break
    }
}
if (-not $copiedIso) {
    Write-Host "Downloading SystemRescue ISO..." -ForegroundColor Yellow
    $isoUrl = "https://releases.system-rescue.org/9.06/systemrescue-9.06-amd64.iso"
    Invoke-WebRequest -Uri $isoUrl -OutFile $targetIso
}

# 8. Extractions from MediCat core 7z archive if present
if (Test-Path $cachePath) {
    $7z = Join-Path $scriptDir "bin\7z.exe"
    if (-not (Test-Path $7z)) {
        $7z = "7z"
    }
    if ($extractMode -eq "Surgical") {
        Write-Host "Extracting minimal boot files and portable apps from $cachePath to $($targetDrive):..." -ForegroundColor Green
        Start-Process -FilePath $7z -ArgumentList "x `"$cachePath`" -o$($targetDrive):\ Live_Operating_Systems/Mini_Windows/* Live_Operating_Systems/SystemRescue/* System/* CdUsb.Y Start.exe PortableApps/PortableApps.com/* PortableApps/7-ZipPortable/* PortableApps/AOMEIPartitionAssistantPortable/* PortableApps/CrystalDiskInfoPortable/* PortableApps/HWiNFOPortable/* PortableApps/Notepad++Portable/* PortableApps/Rufus/* PortableApps/WizTree/* PortableApps/SnappyDriverInstallerOrigin/* PortableApps/SDIO/* -aoa -y" -NoNewWindow -Wait
    } else {
        Write-Host "Extracting ALL files from $cachePath to $($targetDrive):..." -ForegroundColor Green
        Start-Process -FilePath $7z -ArgumentList "x `"$cachePath`" -o$($targetDrive):\ -aoa -y" -NoNewWindow -Wait
    }
}

# 9. Compile custom branded launcher and copy wallpapers/files
Write-Host "Applying custom MiOS configurations, wallpapers, and layouts..." -ForegroundColor Green
$resourceDir = Join-Path $scriptDir "resources"
if (Test-Path $resourceDir) {
    Copy-Item -Path "$resourceDir\ventoy\*" -Destination "$($targetDrive):\ventoy\" -Recurse -Force
    Copy-Item -Path "$resourceDir\theme\*" -Destination "$($targetDrive):\ventoy\theme\" -Recurse -Force
    Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun.sh" -Force
    Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun\autorun.sh" -Force
    Copy-Item -Path "$resourceDir\autorun.sh" -Destination "$($targetDrive):\autorun\autorun" -Force
    Copy-Item -Path "$resourceDir\CdUsb.Y" -Destination "$($targetDrive):\CdUsb.Y" -Force
}

# Custom theme configuration for PortableApps Menu
if ($paTheme -eq "Dark") {
    $paMenuDir = Join-Path "$($targetDrive):" "PortableApps\PortableApps.com\Data"
    New-Item -ItemType Directory -Force -Path $paMenuDir | Out-Null
    $paMenuIni = Join-Path $paMenuDir "PortableAppsMenu.ini"
    $iniContent = @"
[Theme]
Color=Custom
PrimaryColor=$subtleColor
SecondaryColor=$mutedColor
AccentColor=$accentColor
SetTheme=Custom
Logo=logo.png

[Files]
CommonDocumentsDirectory=..\..\Documents
CommonPicturesDirectory=..\..\Documents
CommonMusicDirectory=..\..\Documents
CommonVideoDirectory=..\..\Documents
"@
    $iniContent | Set-Content $paMenuIni -Force
}

# 10. Compile MiOS-Xbox ISO if enabled
if ($buildXbox) {
    Write-Host "Compiling Inline Live Build of MiOS-Xbox Installer ISO..." -ForegroundColor Green
    $xboxBuilder = "C:\mios-bootstrap\cat\autounattend\Build-MiOSXboxISO.ps1"
    if (Test-Path $xboxBuilder) {
        $originalToml = "C:\MiOS\mios.toml"
        if (-not (Test-Path $originalToml)) {
            $originalToml = Join-Path $scriptDir "..\..\..\..\mios.toml"
        }
        if (-not (Test-Path $originalToml)) {
            $originalToml = Join-Path $scriptDir "..\..\..\..\..\mios.toml"
        }
        
        $tempToml = Join-Path $env:TEMP "mios_run.toml"
        if (Test-Path $originalToml) {
            Write-Host "Generating custom mios.toml for this run at $tempToml..." -ForegroundColor Green
            $tomlContent = Get-Content $originalToml -Raw
            $chan = $uupChannel.ToLower()
            $tomlContent = $tomlContent -replace '(?s)(\[editions\.mios-xbox\].*?autounattend\.uup_channel\s*=\s*")[^"]*(")', "${1}${chan}${2}"
            
            $bakeVal = if ($bakeDrivers) { "true" } else { "false" }
            if ($tomlContent -match 'autounattend\.bake_host_drivers\s*=') {
                $tomlContent = $tomlContent -replace 'autounattend\.bake_host_drivers\s*=\s*\w+', "autounattend.bake_host_drivers = $bakeVal"
            } else {
                $tomlContent = $tomlContent -replace '(\[editions\.mios-xbox\])', "`$1`r`nautounattend.bake_host_drivers = $bakeVal"
            }
            
            $gameVal = if ($gamingOptimize) { "gaming" } else { "minimal" }
            $tomlContent = $tomlContent -replace '(?s)(\[editions\.mios-xbox\].*?autounattend\.debloat_profile\s*=\s*")[^"]*(")', "${1}${gameVal}${2}"
            
            $tomlContent | Set-Content $tempToml -Force
            Start-Process -FilePath powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$xboxBuilder`" -TomlPath `"$tempToml`" -OutIso `"$($targetDrive):\Live_Operating_Systems\MiOS-Xbox.iso`" -SkipWsl" -NoNewWindow -Wait
        } else {
            Start-Process -FilePath powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$xboxBuilder`" -OutIso `"$($targetDrive):\Live_Operating_Systems\MiOS-Xbox.iso`" -SkipWsl" -NoNewWindow -Wait
        }
    }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "        INSTALLATION AND BRANDING COMPLETE                " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "Drive [$($targetDrive):] is now a themed MiOS boot device."
Write-Host "It contains:"
Write-Host "  - Custom soft-diffused advected color-ocean wallpaper"
Write-Host "  - Autoload configuration to bypass boot screens"
Write-Host "  - Automated local disk-wipe rescue routines"
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Read-Host "Press Enter to exit"
