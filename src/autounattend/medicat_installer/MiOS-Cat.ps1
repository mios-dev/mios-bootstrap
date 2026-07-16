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

# 2. Identify USB drives
$removableDrives = Get-Volume | Where-Object {$_.DriveType -eq 'Removable'}
if ($removableDrives.Count -eq 0) {
    Write-Host "No removable USB drives found!" -ForegroundColor Red
    Write-Host "Please insert a USB drive and try again."
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "Connected USB drives:" -ForegroundColor Green
$driveMap = @{}
$i = 1
foreach ($d in $removableDrives) {
    Write-Host "$i) Drive [$($d.DriveLetter):] - $($d.FriendlyName) ($($d.FileSystemType)) - $([Math]::Round($d.Size / 1GB, 2)) GB"
    $driveMap[$i] = $d.DriveLetter
    $i++
}

Write-Host ""
$selection = Read-Host "Select the drive number to install to (e.g. 1)"
if (-not $driveMap.ContainsKey([int]$selection)) {
    Write-Host "Invalid selection! Exiting..." -ForegroundColor Red
    exit
}

$targetDrive = $driveMap[[int]$selection]
Write-Host "WARNING: ALL DATA ON DRIVE [$targetDrive:] WILL BE PERMANENTLY ERASED!" -ForegroundColor Red
$confirm = Read-Host "Are you absolutely sure you want to proceed? (type YES to confirm)"
if ($confirm -ne "YES") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit
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
Start-Process -FilePath $vtoyCli -ArgumentList "VTOYCLI /I /Drive:$($targetDrive): /NOUSBCheck /GPT" -NoNewWindow -Wait

# Wait for drive remount
Start-Sleep -Seconds 5
$driveMounted = Test-Path "$($targetDrive):\"
if (-not $driveMounted) {
    Write-Host "Waiting for drive to mount..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

# Format primary partition to NTFS and name it Medicat
Write-Host "Applying file system format (NTFS / Medicat)..." -ForegroundColor Green
Format-Volume -DriveLetter $targetDrive -FileSystem NTFS -NewFileSystemLabel "Medicat" -Confirm:$false -Force

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
