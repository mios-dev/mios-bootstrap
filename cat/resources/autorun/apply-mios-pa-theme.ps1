$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Drawing

$drive = ($TargetDrive.TrimEnd('\') + "\")
$paBase = Join-Path $drive "PortableApps"

if (-not (Test-Path $paBase)) { return }

$paGraphics = Join-Path $paBase "PortableApps.com\App\Graphics"
$paMenuIcons = Join-Path $paGraphics "MenuIcons"
$paThemeDir = Join-Path $paGraphics "Themes\MiOSTheme"

mkdir $paMenuIcons -ErrorAction SilentlyContinue | Out-Null
mkdir $paThemeDir -ErrorAction SilentlyContinue | Out-Null

function New-GradientBrush($rect, $c1, $c2, $angle = 90) {
    return New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, $angle)
}

# -----------------------------------------------------------------------------
# 1. GENERATE MODERN SLEEK MENU ICONS (32x32 & 16x16 PNGs)
# -----------------------------------------------------------------------------

function Create-ModernIcon($name, $drawScript) {
    foreach ($size in @(32, 16)) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        
        $scale = $size / 32.0
        $g.ScaleTransform($scale, $scale)
        
        & $drawScript $g
        
        $g.Dispose()
        
        $fileName = if ($size -eq 32) { "$name.png" } else { "${name}_16.png" }
        $outPath = Join-Path $paMenuIcons $fileName
        $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
}

Create-ModernIcon "documents" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 6, 4, 20, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(254, 243, 199)) ([System.Drawing.Color]::FromArgb(251, 191, 36)) 45
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(217, 119, 6), 1.5)
    $g.DrawRectangle($pen, $rect)
    $pen.Dispose()
    
    $bHead = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 92, 21))
    $g.FillRectangle($bHead, 6, 4, 20, 5)
    $bHead.Dispose()
    
    $bLine = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 83, 9))
    $g.FillRectangle($bLine, 10, 13, 12, 2)
    $g.FillRectangle($bLine, 10, 18, 12, 2)
    $g.FillRectangle($bLine, 10, 23, 8, 2)
    $bLine.Dispose()
}

Create-ModernIcon "music" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 24, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(251, 146, 60)) ([System.Drawing.Color]::FromArgb(217, 119, 6)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillEllipse($bWhite, 9, 18, 6, 5)
    $g.FillEllipse($bWhite, 18, 15, 6, 5)
    $pStem = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
    $g.DrawLine($pStem, 14, 20, 14, 8)
    $g.DrawLine($pStem, 23, 17, 23, 5)
    $g.DrawLine($pStem, 14, 8, 23, 5)
    $pStem.Dispose()
    $bWhite.Dispose()
}

Create-ModernIcon "pictures" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 6, 24, 20
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(56, 189, 248)) ([System.Drawing.Color]::FromArgb(3, 105, 161)) 45
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    
    $bSun = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(254, 240, 138))
    $g.FillEllipse($bSun, 8, 9, 5, 5)
    $bSun.Dispose()
    
    $pts = @(
        [System.Drawing.PointF]::new(4, 22),
        [System.Drawing.PointF]::new(11, 14),
        [System.Drawing.PointF]::new(17, 20),
        [System.Drawing.PointF]::new(21, 16),
        [System.Drawing.PointF]::new(28, 22)
    )
    $bMtn = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 253, 250))
    $g.FillPolygon($bMtn, $pts)
    $bMtn.Dispose()
}

Create-ModernIcon "videos" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 5, 24, 22
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(167, 139, 250)) ([System.Drawing.Color]::FromArgb(109, 40, 217)) 45
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    
    $pts = @(
        [System.Drawing.PointF]::new(13, 11),
        [System.Drawing.PointF]::new(21, 16),
        [System.Drawing.PointF]::new(13, 21)
    )
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($bWhite, $pts)
    $bWhite.Dispose()
}

Create-ModernIcon "explore" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 24, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(243, 92, 21)) ([System.Drawing.Color]::FromArgb(180, 83, 9)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $pOuter = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)
    $g.DrawEllipse($pOuter, 7, 7, 18, 18)
    $pOuter.Dispose()
    
    $ptsRed = @([System.Drawing.PointF]::new(16, 8), [System.Drawing.PointF]::new(19, 16), [System.Drawing.PointF]::new(16, 14))
    $bRed = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(239, 68, 68))
    $g.FillPolygon($bRed, $ptsRed)
    $bRed.Dispose()
    
    $ptsWhite = @([System.Drawing.PointF]::new(16, 24), [System.Drawing.PointF]::new(13, 16), [System.Drawing.PointF]::new(16, 18))
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($bWhite, $ptsWhite)
    $bWhite.Dispose()
}

Create-ModernIcon "backup" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 24, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(52, 211, 153)) ([System.Drawing.Color]::FromArgb(5, 150, 105)) 45
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    
    $pArrow = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.5)
    $g.DrawLine($pArrow, 16, 22, 16, 10)
    $g.DrawLine($pArrow, 16, 10, 11, 15)
    $g.DrawLine($pArrow, 16, 10, 21, 15)
    $pArrow.Dispose()
}

Create-ModernIcon "manage_apps" {
    param($g)
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(192, 132, 252))
    $g.FillRectangle($b, 5, 5, 9, 9)
    $g.FillRectangle($b, 18, 5, 9, 9)
    $g.FillRectangle($b, 5, 18, 9, 9)
    $g.FillRectangle($b, 18, 18, 9, 9)
    $b.Dispose()
}

Create-ModernIcon "options" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 24, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(148, 163, 184)) ([System.Drawing.Color]::FromArgb(71, 85, 105)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $bCenter = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15, 23, 42))
    $g.FillEllipse($bCenter, 11, 11, 10, 10)
    $bCenter.Dispose()
}

Create-ModernIcon "search" {
    param($g)
    $pLens = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 189, 248), 3)
    $g.DrawEllipse($pLens, 5, 5, 15, 15)
    $pLens.Dispose()
    
    $pHandle = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 3.5)
    $g.DrawLine($pHandle, 17, 17, 26, 26)
    $pHandle.Dispose()
}

Create-ModernIcon "help" {
    param($g)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 24, 24
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(96, 165, 250)) ([System.Drawing.Color]::FromArgb(29, 78, 216)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString('?', $font, $bWhite, 9, 3)
    $font.Dispose()
    $bWhite.Dispose()
}

# -----------------------------------------------------------------------------
# 2. GENERATE HIGH-DPI DISTINCT APP ICONS FOR ALL MIOS TOOLS
# -----------------------------------------------------------------------------

function Build-MiOSAppIcon($appDir, $appName, $drawCode) {
    $infoDir = Join-Path $appDir "App\AppInfo"
    mkdir $infoDir -ErrorAction SilentlyContinue | Out-Null
    
    $bmp48 = New-Object System.Drawing.Bitmap 48, 48
    $g = [System.Drawing.Graphics]::FromImage($bmp48)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    
    & $drawCode $g 48
    $g.Dispose()
    
    $bmp32 = New-Object System.Drawing.Bitmap 32, 32
    $g32 = [System.Drawing.Graphics]::FromImage($bmp32)
    $g32.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g32.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g32.DrawImage($bmp48, 0, 0, 32, 32)
    $g32.Dispose()
    $bmp32.Save((Join-Path $infoDir "appicon_32.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    
    $bmp16 = New-Object System.Drawing.Bitmap 16, 16
    $g16 = [System.Drawing.Graphics]::FromImage($bmp16)
    $g16.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g16.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g16.DrawImage($bmp48, 0, 0, 16, 16)
    $g16.Dispose()
    $bmp16.Save((Join-Path $infoDir "appicon_16.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    
    $hIcon = $bmp48.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($hIcon)
    $fs = New-Object System.IO.FileStream((Join-Path $infoDir "appicon.ico"), [System.IO.FileMode]::Create)
    $ico.Save($fs)
    $fs.Close()
    $ico.Dispose()
    $bmp48.Dispose()
    $bmp32.Dispose()
    $bmp16.Dispose()
}

# MiOS Live Status Monitor: Glowing Cyan Pulse Waveform Shield
Build-MiOSAppIcon (Join-Path $paBase "MiOSMonitor") "MiOSMonitor" {
    param($g, $sz)
    $rect = New-Object System.Drawing.Rectangle 2, 2, ($sz-4), ($sz-4)
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(15, 23, 42)) ([System.Drawing.Color]::FromArgb(6, 78, 59)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(16, 185, 129), 3)
    $g.DrawEllipse($penGlow, $rect)
    $penGlow.Dispose()
    
    $pts = @(
        [System.Drawing.PointF]::new(8, 24),
        [System.Drawing.PointF]::new(16, 24),
        [System.Drawing.PointF]::new(20, 10),
        [System.Drawing.PointF]::new(26, 36),
        [System.Drawing.PointF]::new(32, 18),
        [System.Drawing.PointF]::new(36, 24),
        [System.Drawing.PointF]::new(40, 24)
    )
    $pWave = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 189, 248), 3)
    $g.DrawLines($pWave, $pts)
    $pWave.Dispose()
}

# MiOS Live USB Flasher & Installer: Neon Orange Lightning & Drive
Build-MiOSAppIcon (Join-Path $paBase "MiOSInstaller") "MiOSInstaller" {
    param($g, $sz)
    $rect = New-Object System.Drawing.Rectangle 2, 2, ($sz-4), ($sz-4)
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(30, 27, 75)) ([System.Drawing.Color]::FromArgb(124, 45, 18)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 3)
    $g.DrawEllipse($penGlow, $rect)
    $penGlow.Dispose()
    
    $pts = @(
        [System.Drawing.PointF]::new(26, 6),
        [System.Drawing.PointF]::new(14, 24),
        [System.Drawing.PointF]::new(24, 24),
        [System.Drawing.PointF]::new(20, 42),
        [System.Drawing.PointF]::new(34, 20),
        [System.Drawing.PointF]::new(24, 20)
    )
    $bBolt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(253, 224, 71))
    $g.FillPolygon($bBolt, $pts)
    $bBolt.Dispose()
}

# MiOS System Rescue & Recovery: Red Emergency Medical Shield
Build-MiOSAppIcon (Join-Path $paBase "MiOSSystemRescue") "MiOSSystemRescue" {
    param($g, $sz)
    $rect = New-Object System.Drawing.Rectangle 2, 2, ($sz-4), ($sz-4)
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(127, 29, 29)) ([System.Drawing.Color]::FromArgb(15, 23, 42)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(239, 68, 68), 3)
    $g.DrawEllipse($penGlow, $rect)
    $penGlow.Dispose()
    
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillRectangle($bWhite, 20, 12, 8, 24)
    $g.FillRectangle($bWhite, 12, 20, 24, 8)
    $bWhite.Dispose()
}

# MiOS Software & System Auditor: Violet Lens & Checklist
Build-MiOSAppIcon (Join-Path $paBase "SoftwareLister") "SoftwareLister" {
    param($g, $sz)
    $rect = New-Object System.Drawing.Rectangle 2, 2, ($sz-4), ($sz-4)
    $brush = New-GradientBrush $rect ([System.Drawing.Color]::FromArgb(88, 28, 135)) ([System.Drawing.Color]::FromArgb(15, 23, 42)) 45
    $g.FillEllipse($brush, $rect)
    $brush.Dispose()
    
    $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(168, 85, 247), 3)
    $g.DrawEllipse($penGlow, $rect)
    $penGlow.Dispose()
    
    $bCheck = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(236, 72, 153))
    $g.FillRectangle($bCheck, 12, 14, 6, 6)
    $g.FillRectangle($bCheck, 12, 26, 6, 6)
    $bCheck.Dispose()
    
    $bLine = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillRectangle($bLine, 22, 16, 14, 3)
    $g.FillRectangle($bLine, 22, 28, 14, 3)
    $bLine.Dispose()
}

# -----------------------------------------------------------------------------
# 3. GENERATE CHROME & LOGO ASSETS
# -----------------------------------------------------------------------------

$bmpLogo = New-Object System.Drawing.Bitmap 48, 48
$gL = [System.Drawing.Graphics]::FromImage($bmpLogo)
$gL.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

$ptsShield = @(
    [System.Drawing.PointF]::new(24, 4),
    [System.Drawing.PointF]::new(44, 12),
    [System.Drawing.PointF]::new(44, 32),
    [System.Drawing.PointF]::new(24, 44),
    [System.Drawing.PointF]::new(4, 32),
    [System.Drawing.PointF]::new(4, 12)
)
$bShield = New-GradientBrush (New-Object System.Drawing.Rectangle 4,4,40,40) ([System.Drawing.Color]::FromArgb(243, 92, 21)) ([System.Drawing.Color]::FromArgb(180, 83, 9)) 45
$gL.FillPolygon($bShield, $ptsShield)
$bShield.Dispose()

$pGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(254, 215, 170), 2)
$gL.DrawPolygon($pGlow, $ptsShield)
$pGlow.Dispose()

$bCross = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$gL.FillRectangle($bCross, 21, 14, 6, 20)
$gL.FillRectangle($bCross, 14, 21, 20, 6)
$bCross.Dispose()
$gL.Dispose()

$bmpLogo.Save((Join-Path $paThemeDir "logo.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmpLogo.Save((Join-Path $paThemeDir "PersonalPicture.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$dataDir = Join-Path $paBase "PortableApps.com\Data"
mkdir $dataDir -ErrorAction SilentlyContinue | Out-Null
$bmpLogo.Save((Join-Path $dataDir "PersonalPicture.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmpLogo.Dispose()

$chromeBmp = New-Object System.Drawing.Bitmap 540, 600
$g = [System.Drawing.Graphics]::FromImage($chromeBmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

$rLeft = New-Object System.Drawing.Rectangle 0, 60, 360, 500
$bLeft = New-GradientBrush $rLeft ([System.Drawing.Color]::FromArgb(11, 15, 25)) ([System.Drawing.Color]::FromArgb(15, 23, 42)) 90
$g.FillRectangle($bLeft, $rLeft)
$bLeft.Dispose()

$rRight = New-Object System.Drawing.Rectangle 360, 60, 180, 500
$bRight = New-GradientBrush $rRight ([System.Drawing.Color]::FromArgb(19, 17, 39)) ([System.Drawing.Color]::FromArgb(30, 27, 75)) 90
$g.FillRectangle($bRight, $rRight)
$bRight.Dispose()

$bCard = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(25, 255, 255, 255))
$pCardBorder = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 243, 92, 21), 1)

$yPositions = @(68, 102, 136, 170, 204, 248, 282, 316, 350, 384)
foreach ($yPos in $yPositions) {
    $g.FillRectangle($bCard, 366, $yPos, 168, 28)
    $g.DrawRectangle($pCardBorder, 366, $yPos, 168, 28)
}
$bCard.Dispose()
$pCardBorder.Dispose()

$pGlowLine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(100, 243, 92, 21), 6)
$g.DrawLine($pGlowLine, 360, 60, 360, 560)
$pGlowLine.Dispose()

$pCenterLine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 2)
$g.DrawLine($pCenterLine, 360, 60, 360, 560)
$pCenterLine.Dispose()

$rHeader = New-Object System.Drawing.Rectangle 0, 0, 540, 60
$bHeader = New-GradientBrush $rHeader ([System.Drawing.Color]::FromArgb(9, 13, 22)) ([System.Drawing.Color]::FromArgb(15, 23, 42)) 90
$g.FillRectangle($bHeader, $rHeader)
$bHeader.Dispose()

$pHeaderLine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 3)
$g.DrawLine($pHeaderLine, 0, 59, 540, 59)
$pHeaderLine.Dispose()

$ptsHShield = @(
    [System.Drawing.PointF]::new(30, 10),
    [System.Drawing.PointF]::new(46, 18),
    [System.Drawing.PointF]::new(46, 34),
    [System.Drawing.PointF]::new(30, 46),
    [System.Drawing.PointF]::new(14, 34),
    [System.Drawing.PointF]::new(14, 18)
)
$bHOrange = New-GradientBrush (New-Object System.Drawing.Rectangle 14,10,32,36) ([System.Drawing.Color]::FromArgb(243, 92, 21)) ([System.Drawing.Color]::FromArgb(217, 119, 6)) 45
$g.FillPolygon($bHOrange, $ptsHShield)
$bHOrange.Dispose()

$bHWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$g.FillRectangle($bHWhite, 28, 18, 4, 18)
$g.FillRectangle($bHWhite, 21, 25, 18, 4)

$fontTitle = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$g.DrawString('MiOS SOVEREIGN RESCUE', $fontTitle, $bHWhite, 56, 16)
$fontTitle.Dispose()
$bHWhite.Dispose()

$rFooter = New-Object System.Drawing.Rectangle 0, 560, 540, 40
$bFooter = New-GradientBrush $rFooter ([System.Drawing.Color]::FromArgb(9, 13, 22)) ([System.Drawing.Color]::FromArgb(15, 23, 42)) 90
$g.FillRectangle($bFooter, $rFooter)
$bFooter.Dispose()

$pFooterLine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 2)
$g.DrawLine($pFooterLine, 0, 560, 540, 560)
$pFooterLine.Dispose()

$g.Dispose()
$chromeBmp.Save((Join-Path $paThemeDir "chrome.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$chromeBmp.Dispose()

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
[System.IO.File]::WriteAllText((Join-Path $paThemeDir "PATheme.ini"), $paThemeIni, [System.Text.Encoding]::UTF8)

$menuIniPath = Join-Path $dataDir "settings\PortableAppsMenu.ini"
if (Test-Path $menuIniPath) {
    $lines = [System.IO.File]::ReadAllLines($menuIniPath, [System.Text.Encoding]::Unicode)
    $newL = @()
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t.StartsWith("Theme=")) {
            $newL += "Theme=MiOSTheme"
        } elseif ($t.StartsWith("ThemeColor=")) {
            $newL += "ThemeColor=Orange"
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

