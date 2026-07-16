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

# Resolve dynamic configuration from mios.toml (SSOT)
$tomlPath = Join-Path $PSScriptRoot "..\..\..\..\mios.toml"
if (-not (Test-Path $tomlPath)) {
    $tomlPath = Join-Path $PSScriptRoot "..\..\..\..\..\mios.toml"
}

# Default variables
$targetDrive = "D"
$medicatVer = "21.12"
$cachePath = "M:\MediCat.USB.v21.12.7z"
$primaryColor = "#B7C9D7"
$secondaryColor = "#948E8E"
$accentColor = "#3E7765"
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
    $primaryColor = Get-TomlValue -pattern '^\s*subtle\s*=\s*"(.*)"' -default "#B7C9D7"
    $secondaryColor = Get-TomlValue -pattern '^\s*muted\s*=\s*"(.*)"' -default "#948E8E"
    $accentColor = Get-TomlValue -pattern '^\s*success\s*=\s*"(.*)"' -default "#3E7765"
}

while ($true) {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "      MiOS Dedicated Recovery USB Deployment Tool         " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "[USB Target settings]"
    Write-Host "  1) Target USB Drive Letter : [$targetDrive`:]"
    Write-Host "  2) Format Partition Label  : [$partitionLabel]"
    Write-Host ""
    Write-Host "[Ventoy / FileSystem settings]"
    Write-Host "  3) Partition Scheme        : [$partitionScheme]"
    Write-Host "  4) Filesystem Format       : [$filesystem]"
    Write-Host "  5) Secure Boot Support     : [$(if($secureBoot){'Enabled'}else{'Disabled'})]"
    Write-Host ""
    Write-Host "[MediCat / Extraction settings]"
    Write-Host "  6) Core Download Cache     : [$cachePath]"
    Write-Host "  7) Extraction Mode         : [$extractMode] (PE + SysRescue)"
    Write-Host "  8) PortableApps Theme      : [$paTheme]"
    Write-Host ""
    Write-Host "[Inline MiOS-Xbox Build settings]"
    Write-Host "  9) Compile MiOS-Xbox ISO   : [$(if($buildXbox){'Enabled'}else{'Disabled'})]"
    Write-Host "  10) Bake Host Drivers      : [$(if($bakeDrivers){'Enabled'}else{'Disabled'})]"
    Write-Host "  11) Microsoft UUP Channel  : [$uupChannel]"
    Write-Host "  12) Gaming Optimizations   : [$(if($gamingOptimize){'Enabled'}else{'Disabled'})]"
    Write-Host ""
    Write-Host "[Action]"
    Write-Host "  13) START INSTALLATION WITH ABOVE SETTINGS"
    Write-Host "  14) EXIT"
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $choice = Read-Host "Select an option (1-14)"
    
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
        "3" {
            if ($partitionScheme -eq "GPT") {
                $partitionScheme = "MBR"
            } else {
                $partitionScheme = "GPT"
            }
        }
        "4" {
            if ($filesystem -eq "NTFS") {
                $filesystem = "exFAT"
            } else {
                $filesystem = "NTFS"
            }
        }
        "5" {
            $secureBoot = -not $secureBoot
        }
        "6" {
            Clear-Host
            Write-Host "Current cache path: $cachePath"
            $newCache = Read-Host "Enter full path to MediCat core 7z (or press Enter to keep)"
            if (-not [string]::IsNullOrWhiteSpace($newCache)) {
                $cachePath = $newCache
            }
        }
        "7" {
            if ($extractMode -eq "Surgical") {
                $extractMode = "Full"
            } else {
                $extractMode = "Surgical"
            }
        }
        "8" {
            if ($paTheme -eq "Dark") {
                $paTheme = "Classic"
            } else {
                $paTheme = "Dark"
            }
        }
        "9" {
            $buildXbox = -not $buildXbox
        }
        "10" {
            $bakeDrivers = -not $bakeDrivers
        }
        "11" {
            if ($uupChannel -eq "Dev") {
                $uupChannel = "Beta"
            } elseif ($uupChannel -eq "Beta") {
                $uupChannel = "Release"
            } else {
                $uupChannel = "Dev"
            }
        }
        "12" {
            $gamingOptimize = -not $gamingOptimize
        }
        "13" {
            Clear-Host
            Write-Host "STARTING MiOS-Cat INSTALLATION" -ForegroundColor Cyan
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
            Write-Host "Xbox Bake Drivers : $bakeDrivers"
            Write-Host "Xbox UUP Channel  : $uupChannel"
            Write-Host "Xbox Gaming Opt.  : $gamingOptimize"
            Write-Host "=============================="
            Write-Host "WARNING: ALL DATA ON DRIVE [$targetDrive`:] WILL BE PERMANENTLY ERASED!" -ForegroundColor Red
            $confirm = Read-Host "Are you absolutely sure you want to proceed? (type YES to confirm)"
            if ($confirm -eq "YES") {
                break # Exit menu loop and start installation
            }
        }
        "14" {
            exit
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
Write-Host "Formatting and installing Ventoy to USB drive [$targetDrive:]..." -ForegroundColor Green
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

# 10. Compile MiOS-Xbox ISO if enabled
if ($buildXbox) {
    Write-Host "Compiling Inline Live Build of MiOS-Xbox Installer ISO..." -ForegroundColor Green
    $xboxBuilder = "C:\mios-bootstrap\src\autounattend\Build-MiOSXboxISO.ps1"
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
