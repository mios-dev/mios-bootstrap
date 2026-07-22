param (
    [string]$TargetDrive = "D:"
)

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Drawing

$drive = ($TargetDrive.TrimEnd('\') + "\")
$paBase = Join-Path $drive "PortableApps"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$icoPath = "C:\mios-bootstrap\cat\resources\icon.ico"
if (-not (Test-Path $icoPath)) { $icoPath = "C:\MiOS\usr\share\mios\branding\mios-v2.ico" }

if (-not (Test-Path $icoPath)) { return }

$icon = New-Object System.Drawing.Icon($icoPath)
$bmpIcon = $icon.ToBitmap()
$msIcon = New-Object System.IO.MemoryStream
$bmpIcon.Save($msIcon, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $msIcon.ToArray()
$msIcon.Dispose()
$bmpIcon.Dispose()

function Get-ResizedPngBytes($srcIco, $width, $height) {
    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawIcon($srcIco, (New-Object System.Drawing.Rectangle 0, 0, $width, $height))
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
    return $bytes
}

$png32 = Get-ResizedPngBytes $icon 32 32
$png16 = Get-ResizedPngBytes $icon 16 16

$apps = @(
    @{
        Folder = "MiOSInstaller"
        ExeName = "MiOSInstaller.exe"
        AppName = "MiOS Live USB Flasher & Installer"
        Desc = "MiOS Live USB Flasher & Deployment Suite"
        TargetScript = "MiOS-Cat.bat"
        Category = "Utilities"
    },
    @{
        Folder = "MiOSMonitor"
        ExeName = "MiOSMonitor.exe"
        AppName = "MiOS Live Status Monitor"
        Desc = "MiOS Deployment & Build Realtime Monitor"
        TargetScript = "MiOS-Monitor.exe"
        Category = "Utilities"
    },
    @{
        Folder = "MiOSSystemRescue"
        ExeName = "MiOSSystemRescue.exe"
        AppName = "MiOS System Rescue & Recovery"
        Desc = "MiOS Bare-Metal System Rescue Suite"
        TargetScript = "MiOS-System-Rescue.exe"
        Category = "Utilities"
    },
    @{
        Folder = "SoftwareLister"
        ExeName = "SoftwareLister.exe"
        AppName = "MiOS Software & System Auditor"
        Desc = "MiOS Portable Software Listing & System Audit"
        TargetScript = "Software Lister.exe"
        Category = "Utilities"
    }
)

$csTemplate = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

class Program {
    [STAThread]
    static void Main() {
        try {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string targetScript = "TARGET_SCRIPT_PLACEHOLDER";
            string targetPath = Path.Combine(baseDir, targetScript);
            
            if (!File.Exists(targetPath)) {
                targetPath = Path.Combine(baseDir, "..", "..", targetScript);
            }
            if (!File.Exists(targetPath)) {
                targetPath = Path.Combine(@"D:\", targetScript);
            }
            if (!File.Exists(targetPath)) {
                targetPath = Path.Combine(@"C:\mios-bootstrap\cat", targetScript);
            }

            if (File.Exists(targetPath)) {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = targetPath;
                if (targetPath.EndsWith(".bat", StringComparison.OrdinalIgnoreCase) || targetPath.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)) {
                    psi.FileName = "cmd.exe";
                    psi.Arguments = "/c \"" + targetPath + "\"";
                }
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                Process.Start(psi);
            }
        } catch {}
    }
}
"@

foreach ($app in $apps) {
    $appDir = Join-Path $paBase $app.Folder
    $appInfoDir = Join-Path $appDir "App\AppInfo"
    mkdir $appInfoDir -ErrorAction SilentlyContinue | Out-Null
    
    $csCode = $csTemplate.Replace("TARGET_SCRIPT_PLACEHOLDER", $app.TargetScript)
    $srcFile = [System.IO.Path]::GetTempFileName() + ".cs"
    [System.IO.File]::WriteAllText($srcFile, $csCode)
    
    $outExe = Join-Path $appDir $app.ExeName
    if (Test-Path $csc) {
        $compileCmd = "& '$csc' /nologo /target:winexe /win32icon:'$icoPath' /out:'$outExe' '$srcFile'"
        Invoke-Expression $compileCmd
    }
    Remove-Item $srcFile -Force -ErrorAction SilentlyContinue
    
    Copy-Item $icoPath (Join-Path $appInfoDir "appicon.ico") -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllBytes((Join-Path $appInfoDir "appicon_32.png"), $png32)
    [System.IO.File]::WriteAllBytes((Join-Path $appInfoDir "appicon_16.png"), $png16)
    
    $iniContent = @"
[Format]
Type=PortableApps.comFormat
Version=3.8

[Details]
Name=$($app.AppName)
AppID=$($app.Folder)
Publisher=MiOS Team
Homepage=https://mios.local
Category=$($app.Category)
Description=$($app.Desc)
Language=Multilingual

[Control]
Icons=1
Start=$($app.ExeName)
"@
    [System.IO.File]::WriteAllText((Join-Path $appInfoDir "appinfo.ini"), $iniContent, [System.Text.Encoding]::UTF8)
}

$themeDir = Join-Path $paBase "PortableApps.com\App\Graphics\Themes\MiOSTheme"
mkdir $themeDir -ErrorAction SilentlyContinue | Out-Null

$chromeBmp = New-Object System.Drawing.Bitmap 540, 600
$g = [System.Drawing.Graphics]::FromImage($chromeBmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

$bLeft = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15, 23, 42))
$g.FillRectangle($bLeft, 0, 60, 360, 500)
$bLeft.Dispose()

$bRight = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, 27, 75))
$g.FillRectangle($bRight, 360, 60, 180, 500)
$bRight.Dispose()

$pDiv = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 2)
$g.DrawLine($pDiv, 360, 60, 360, 560)
$pDiv.Dispose()

$bHeader = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(11, 15, 25))
$g.FillRectangle($bHeader, 0, 0, 540, 60)
$bHeader.Dispose()

$pHeader = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 3)
$g.DrawLine($pHeader, 0, 59, 540, 59)
$pHeader.Dispose()

$bFooter = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(11, 15, 25))
$g.FillRectangle($bFooter, 0, 560, 540, 40)
$bFooter.Dispose()

$pFooter = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 2)
$g.DrawLine($pFooter, 0, 560, 540, 560)
$pFooter.Dispose()

$ptsShield = @(
    [System.Drawing.PointF]::new(30, 15),
    [System.Drawing.PointF]::new(44, 21),
    [System.Drawing.PointF]::new(44, 34),
    [System.Drawing.PointF]::new(30, 45),
    [System.Drawing.PointF]::new(16, 34),
    [System.Drawing.PointF]::new(16, 21)
)
$bOrange = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 92, 21))
$g.FillPolygon($bOrange, $ptsShield)
$bOrange.Dispose()

$bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$g.FillRectangle($bWhite, 27, 22, 6, 17)
$g.FillRectangle($bWhite, 21, 27, 18, 6)

$fontTitle = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$g.DrawString('MiOS RESCUE SUITE', $fontTitle, $bWhite, 56, 18)
$fontTitle.Dispose()
$bWhite.Dispose()
$g.Dispose()

$chromeBmp.Save((Join-Path $themeDir "chrome.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$chromeBmp.Dispose()

$dataDir = Join-Path $paBase "PortableApps.com\Data"
mkdir $dataDir -ErrorAction SilentlyContinue | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $dataDir "PersonalPicture.png"), $pngBytes)
[System.IO.File]::WriteAllBytes((Join-Path $themeDir "PersonalPicture.png"), $pngBytes)
[System.IO.File]::WriteAllBytes((Join-Path $themeDir "logo.png"), $pngBytes)
[System.IO.File]::WriteAllBytes((Join-Path $themeDir "header.png"), $pngBytes)

$paThemeIni = @"
[PortableApps.comTheme]
PortableApps.comThemeVersion=2.0
PortableApps.comThemeType=Simple

[ThemeDetails]
Name=MiOSTheme
Version=2.0
Author=MiOS Automated System

[ButtonApplications]
FontColor=FFFFFF
IconTransparentColor=000000
DividerColor=F35C15

[ButtonFolders]
FontColor=E7DFD3
FontColorWhite=FFFFFF

[DriveSpace]
FontColor=E7DFD3
FontShadowColor=14112E
StretchImage=true

[SearchBox]
FontColor=FFFFFF
BackgroundColor=1E293B
BorderColor=F35C15

[Menu]
Layout=modern
Chrome=custom
Background=none
DefaultBackgroundColor=Dark
"@
[System.IO.File]::WriteAllText((Join-Path $themeDir "PATheme.ini"), $paThemeIni, [System.Text.Encoding]::UTF8)

$menuIniPath = Join-Path $dataDir "PortableAppsMenu.ini"
if (Test-Path $menuIniPath) {
    $lines = [System.IO.File]::ReadAllLines($menuIniPath, [System.Text.Encoding]::Unicode)
    $newL = @()
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t.StartsWith("Theme=")) {
            $newL += "Theme=MiOSTheme"
        } elseif ($t.StartsWith("ThemeColor=")) {
            $newL += "ThemeColor=Dark"
        } elseif ($t.StartsWith("ThemeCustomColor=")) {
            $newL += "ThemeCustomColor=282262"
        } elseif ($t.StartsWith("HideLogoDecorations=")) {
            $newL += "HideLogoDecorations=False"
        } elseif ($t -eq "[AppsFavorite]") {
            $newL += $l
            $newL += "miosinstaller\miosinstaller.exe=1"
            $newL += "miosmonitor\miosmonitor.exe=1"
            $newL += "miossystemrescue\miossystemrescue.exe=1"
            $newL += "softwarelister\softwarelister.exe=1"
        } else {
            $newL += $l
        }
    }
    [System.IO.File]::WriteAllLines($menuIniPath, $newL, [System.Text.Encoding]::Unicode)
}
