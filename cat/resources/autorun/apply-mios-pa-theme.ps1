param (
    [string]$TargetDrive = "D:"
)

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Drawing

$icoPath = "C:\mios-bootstrap\cat\resources\icon.ico"
if (-not (Test-Path $icoPath)) { $icoPath = "C:\MiOS\usr\share\mios\branding\mios-v2.ico" }

# Extract PNG from ICO or draw high-res MiOS shield icon
$pngBytes = $null
if (Test-Path $icoPath) {
    try {
        $icon = New-Object System.Drawing.Icon($icoPath)
        $bmp = $icon.ToBitmap()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $ms.ToArray()
        $ms.Dispose()
        $bmp.Dispose()
        $icon.Dispose()
    } catch {
        $pngBytes = $null
    }
}

if ($null -eq $pngBytes) {
    $bmp = New-Object System.Drawing.Bitmap 96, 96
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(40, 34, 98))
    
    $pts = @(
        [System.Drawing.PointF]::new(48, 12),
        [System.Drawing.PointF]::new(78, 24),
        [System.Drawing.PointF]::new(78, 54),
        [System.Drawing.PointF]::new(48, 84),
        [System.Drawing.PointF]::new(18, 54),
        [System.Drawing.PointF]::new(18, 24)
    )
    $bS = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 92, 21))
    $g.FillPolygon($bS, $pts)
    $bS.Dispose()
    
    $bC = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillRectangle($bC, 42, 30, 12, 36)
    $g.FillRectangle($bC, 30, 42, 36, 12)
    $bC.Dispose()
    $g.Dispose()
    
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
}

$targetBase = Join-Path ($TargetDrive.TrimEnd('\') + "\") "PortableApps"
$targetDirs = @(
    (Join-Path $targetBase "PortableApps.com\Data"),
    (Join-Path $targetBase "PortableApps.com\App\Graphics\Themes\MiOSTheme"),
    (Join-Path $targetBase "PortableApps.com\App\Graphics\Themes\ModernDark")
)

foreach ($d in $targetDirs) {
    mkdir $d -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $d "PersonalPicture.png"), $pngBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $d "logo.png"), $pngBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $d "header.png"), $pngBytes)
}

$paThemeContent = @"
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
FontColor=FFFFFF
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
Chrome=modern_dark
Background=none
DefaultBackgroundColor=Dark
"@

$themeIniPath = Join-Path $targetBase "PortableApps.com\App\Graphics\Themes\MiOSTheme\PATheme.ini"
[System.IO.File]::WriteAllText($themeIniPath, $paThemeContent, [System.Text.Encoding]::UTF8)

$menuIniPath = Join-Path $targetBase "PortableApps.com\Data\PortableAppsMenu.ini"
if (Test-Path $menuIniPath) {
    $lines = [System.IO.File]::ReadAllLines($menuIniPath, [System.Text.Encoding]::Unicode)
    $newL = @()
    foreach ($l in $lines) {
        if ($l.Trim().StartsWith("Theme=")) {
            $newL += "Theme=MiOSTheme"
        } elseif ($l.Trim().StartsWith("ThemeColor=")) {
            $newL += "ThemeColor=Dark"
        } elseif ($l.Trim().StartsWith("ThemeCustomColor=")) {
            $newL += "ThemeCustomColor=282262"
        } else {
            $newL += $l
        }
    }
    [System.IO.File]::WriteAllLines($menuIniPath, $newL, [System.Text.Encoding]::Unicode)
}
