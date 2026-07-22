# AI-hint: Generates canonical SSOT distinct high-resolution PNG-ICO drive icons and autorun.inf metadata across MiOS USB partitions, updating Explorer registry keys and flushing Explorer icon cache.
# AI-related: /usr/share/mios/ventoy/autorun/mios-stage-icons.ps1, /usr/share/mios/mios.toml, MiOS-Cat.bat, build-mios.ps1
param(
    [string]$CatDrive = "D",
    [string]$RepoDrive = "",
    [string]$DataDrive = "",
    [string]$MiosToml = "C:\MiOS\usr\share\mios\mios.toml"
)

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# Shell32 P/Invoke for broadcasting Windows Explorer icon cache flush
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MiOSShellNotifier {
    [DllImport("shell32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@ -ErrorAction SilentlyContinue

# Helper function to save System.Drawing.Bitmap as a spec-compliant 256x256 PNG-compressed ICO binary file
function Save-BitmapAsPngIco {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$OutPath
    )
    $dir = [System.IO.Path]::GetDirectoryName($OutPath)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $ms = New-Object System.IO.MemoryStream
    $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
    $ms.Dispose()

    $fs = New-Object System.IO.FileStream($OutPath, [System.IO.FileMode]::Create)
    $bw = New-Object System.IO.BinaryWriter($fs)

    # ICONDIR Header (6 bytes)
    $bw.Write([uint16]0) # Reserved
    $bw.Write([uint16]1) # Type 1 = ICO
    $bw.Write([uint16]1) # Image count

    # ICONDIRENTRY (16 bytes)
    $bw.Write([byte]0)   # Width 256 (0 = 256px)
    $bw.Write([byte]0)   # Height 256 (0 = 256px)
    $bw.Write([byte]0)   # Color count
    $bw.Write([byte]0)   # Reserved
    $bw.Write([uint16]1) # Color planes
    $bw.Write([uint16]32)# Bits per pixel
    $bw.Write([uint32]$pngBytes.Length) # Length of PNG stream
    $bw.Write([uint32]22)# Offset to image payload (6 + 16 = 22)

    # PNG Payload
    $bw.Write($pngBytes)

    $bw.Close()
    $fs.Close()
}

# Resolve brand colors from SSOT mios.toml
$ssotBgColor     = [System.Drawing.Color]::FromArgb(11, 15, 25)
$ssotAccentColor = [System.Drawing.Color]::FromArgb(243, 92, 21)
if (Test-Path $MiosToml) {
    try {
        $tomlTxt = Get-Content $MiosToml -ErrorAction SilentlyContinue | Out-String
        if ($tomlTxt -match 'brand_color\s*=\s*"#([0-9a-fA-F]{6})"') {
            $ssotAccentColor = [System.Drawing.ColorTranslator]::FromHtml("#$($Matches[1])")
        }
    } catch {}
}

function New-MiOSVectorDriveIcon {
    param(
        [string]$Path,
        [string]$LabelText = "MiOS-Cat",
        [string]$IconType = "CAT"  # CAT, REPO, DATA
    )
    try {
        $s = 256
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = 'AntiAlias'
        $g.TextRenderingHint  = 'AntiAliasGridFit'
        $g.InterpolationMode  = 'HighQualityBicubic'
        $g.PixelOffsetMode    = 'HighQuality'

        if ($IconType -eq "CAT") {
            # =========================================================================
            # NEW MiOS-Cat DESIGN: Futuristic Hexagonal Rescue Shield & Beacon
            # =========================================================================
            $g.Clear([System.Drawing.Color]::FromArgb(11, 15, 25))

            # Outer Glowing Hexagon Border (Sunset Orange #F35C15)
            $cx = 128.0; $cy = 118.0; $r = 96.0
            $hexPts = @()
            for ($i = 0; $i -lt 6; $i++) {
                $angle = ($i * 60 - 30) * [Math]::PI / 180.0
                $hexPts += [System.Drawing.PointF]::new($cx + $r * [Math]::Cos($angle), $cy + $r * [Math]::Sin($angle))
            }
            $brushHexBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 27, 45))
            $g.FillPolygon($brushHexBg, $hexPts)
            $brushHexBg.Dispose()

            $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(243, 92, 21), 10)
            $g.DrawPolygon($penGlow, $hexPts)
            $penGlow.Dispose()

            # Rescue Shield
            $shieldPts = @(
                [System.Drawing.PointF]::new(128, 52),
                [System.Drawing.PointF]::new(180, 78),
                [System.Drawing.PointF]::new(180, 130),
                [System.Drawing.PointF]::new(128, 185),
                [System.Drawing.PointF]::new(76,  130),
                [System.Drawing.PointF]::new(76,  78)
            )
            $brushShield = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 92, 21))
            $g.FillPolygon($brushShield, $shieldPts)
            $brushShield.Dispose()

            # Shield Core (Slate Navy)
            $shieldCore = @(
                [System.Drawing.PointF]::new(128, 64),
                [System.Drawing.PointF]::new(170, 86),
                [System.Drawing.PointF]::new(170, 126),
                [System.Drawing.PointF]::new(128, 172),
                [System.Drawing.PointF]::new(86,  126),
                [System.Drawing.PointF]::new(86,  86)
            )
            $brushCore = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(11, 15, 25))
            $g.FillPolygon($brushCore, $shieldCore)
            $brushCore.Dispose()

            # Glowing Center Emblem: Modern Stylized Rescue Cross + Star
            $brushCross = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $g.FillRectangle($brushCross, 121, 88, 14, 54)
            $g.FillRectangle($brushCross, 101, 108, 54, 14)
            $brushCross.Dispose()

            # Text Badge at Bottom
            $fontL = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectL = New-Object System.Drawing.RectangleF 0, 206, 256, 42
            $g.DrawString($LabelText.ToUpper(), $fontL, [System.Drawing.Brushes]::Orange, $rectL, $sf)

        } elseif ($IconType -eq "REPO") {
            # =========================================================================
            # NEW MiOS-Repo DESIGN: Modern Hexagonal Package Vault Emblem (Vibrant Cyan)
            # =========================================================================
            $g.Clear([System.Drawing.Color]::FromArgb(8, 18, 38))

            $cx = 128.0; $cy = 118.0; $r = 96.0
            $hexPts = @()
            for ($i = 0; $i -lt 6; $i++) {
                $angle = ($i * 60 - 30) * [Math]::PI / 180.0
                $hexPts += [System.Drawing.PointF]::new($cx + $r * [Math]::Cos($angle), $cy + $r * [Math]::Sin($angle))
            }
            $brushHexBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15, 30, 58))
            $g.FillPolygon($brushHexBg, $hexPts)
            $brushHexBg.Dispose()

            $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(6, 182, 212), 10)
            $g.DrawPolygon($penGlow, $hexPts)
            $penGlow.Dispose()

            # Package Cube Top, Left, Right Facets
            $hH = 42.0; $hW = 68.0
            $vTop  = [System.Drawing.PointF]::new($cx,       $cy - $hH * 1.3)
            $vTopR = [System.Drawing.PointF]::new($cx + $hW, $cy - $hH * 0.65)
            $vBotR = [System.Drawing.PointF]::new($cx + $hW, $cy + $hH * 0.65)
            $vBot  = [System.Drawing.PointF]::new($cx,       $cy + $hH * 1.3)
            $vBotL = [System.Drawing.PointF]::new($cx - $hW, $cy + $hH * 0.65)
            $vTopL = [System.Drawing.PointF]::new($cx - $hW, $cy - $hH * 0.65)
            $vMid  = [System.Drawing.PointF]::new($cx,       $cy)

            $bTop   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(6, 182, 212))   # Cyan
            $bLeft  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 232, 240)) # Warm Silver
            $bRight = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, 58, 138))  # Dark Blue

            $g.FillPolygon($bTop,   @($vTop,  $vTopR, $vMid,  $vTopL))
            $g.FillPolygon($bLeft,  @($vTopL, $vMid,  $vBot,  $vBotL))
            $g.FillPolygon($bRight, @($vTopR, $vBotR, $vBot,  $vMid))
            $bTop.Dispose(); $bLeft.Dispose(); $bRight.Dispose()

            $penOutline = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(8, 18, 38), 5)
            $g.DrawPolygon($penOutline, @($vTop, $vTopR, $vBotR, $vBot, $vBotL, $vTopL))
            $g.DrawLine($penOutline, $vMid, $vTop)
            $g.DrawLine($penOutline, $vMid, $vBot)
            $g.DrawLine($penOutline, $vMid, $vTopL)
            $g.DrawLine($penOutline, $vMid, $vTopR)
            $penOutline.Dispose()

            $fontL = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectL = New-Object System.Drawing.RectangleF 0, 206, 256, 42
            $g.DrawString($LabelText.ToUpper(), $fontL, [System.Drawing.Brushes]::Cyan, $rectL, $sf)

        } else {
            # =========================================================================
            # NEW MiOS-Data DESIGN: Modern Encrypted Storage Vault (Golden Amber)
            # =========================================================================
            $g.Clear([System.Drawing.Color]::FromArgb(22, 13, 39))

            $cx = 128.0; $cy = 118.0; $r = 96.0
            $hexPts = @()
            for ($i = 0; $i -lt 6; $i++) {
                $angle = ($i * 60 - 30) * [Math]::PI / 180.0
                $hexPts += [System.Drawing.PointF]::new($cx + $r * [Math]::Cos($angle), $cy + $r * [Math]::Sin($angle))
            }
            $brushHexBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38, 22, 60))
            $g.FillPolygon($brushHexBg, $hexPts)
            $brushHexBg.Dispose()

            $penGlow = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(245, 158, 11), 10)
            $g.DrawPolygon($penGlow, $hexPts)
            $penGlow.Dispose()

            # Encrypted Vault Disk Facets
            $hH = 42.0; $hW = 68.0
            $vTop  = [System.Drawing.PointF]::new($cx,       $cy - $hH * 1.3)
            $vTopR = [System.Drawing.PointF]::new($cx + $hW, $cy - $hH * 0.65)
            $vBotR = [System.Drawing.PointF]::new($cx + $hW, $cy + $hH * 0.65)
            $vBot  = [System.Drawing.PointF]::new($cx,       $cy + $hH * 1.3)
            $vBotL = [System.Drawing.PointF]::new($cx - $hW, $cy + $hH * 0.65)
            $vTopL = [System.Drawing.PointF]::new($cx - $hW, $cy - $hH * 0.65)
            $vMid  = [System.Drawing.PointF]::new($cx,       $cy)

            $bTop   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 158, 11))  # Amber
            $bLeft  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 232, 240)) # Silver
            $bRight = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(88, 28, 135))  # Purple

            $g.FillPolygon($bTop,   @($vTop,  $vTopR, $vMid,  $vTopL))
            $g.FillPolygon($bLeft,  @($vTopL, $vMid,  $vBot,  $vBotL))
            $g.FillPolygon($bRight, @($vTopR, $vBotR, $vBot,  $vMid))
            $bTop.Dispose(); $bLeft.Dispose(); $bRight.Dispose()

            $penOutline = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(22, 13, 39), 5)
            $g.DrawPolygon($penOutline, @($vTop, $vTopR, $vBotR, $vBot, $vBotL, $vTopL))
            $g.DrawLine($penOutline, $vMid, $vTop)
            $g.DrawLine($penOutline, $vMid, $vBot)
            $g.DrawLine($penOutline, $vMid, $vTopL)
            $g.DrawLine($penOutline, $vMid, $vTopR)
            $penOutline.Dispose()

            $fontL = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectL = New-Object System.Drawing.RectangleF 0, 206, 256, 42
            $g.DrawString($LabelText.ToUpper(), $fontL, [System.Drawing.Brushes]::Gold, $rectL, $sf)
        }

        # Save as spec-compliant PNG-ICO binary file
        Save-BitmapAsPngIco -Bitmap $bmp -OutPath $Path
        $g.Dispose()
        $bmp.Dispose()
        Write-Host "    [+] Generated Modern PNG-ICO Icon ($IconType): $Path" -ForegroundColor Green
    } catch {
        Write-Host "    [!] Icon generation warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stage-PartitionIcon {
    param([string]$Letter, [string]$Label, [string]$Type)
    if (-not $Letter -or $Letter -eq '_') { return }
    $driveRoot = "$($Letter.Trim(':')):"
    if (-not (Test-Path -LiteralPath $driveRoot)) { return }

    $autorunDir = Join-Path $driveRoot "autorun"
    # Save to BOTH mios.ico and mios-v2.ico to force Explorer cache invalidation
    $icoPath   = Join-Path $autorunDir "mios.ico"
    $icoPathV2 = Join-Path $autorunDir "mios-v2.ico"

    if (Test-Path $icoPath)   { try { Set-ItemProperty -Path $icoPath   -Name Attributes -Value Normal -ErrorAction SilentlyContinue } catch {} }
    if (Test-Path $icoPathV2) { try { Set-ItemProperty -Path $icoPathV2 -Name Attributes -Value Normal -ErrorAction SilentlyContinue } catch {} }

    New-MiOSVectorDriveIcon -Path $icoPath   -LabelText $Label -IconType $Type
    New-MiOSVectorDriveIcon -Path $icoPathV2 -LabelText $Label -IconType $Type

    # autorun.inf on drive root
    $infPath = Join-Path $driveRoot "autorun.inf"
    if (Test-Path $infPath) { try { Set-ItemProperty -Path $infPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue } catch {} }
    $infContent = @"
[autorun]
icon=autorun\mios-v2.ico
label=$Label
"@
    [System.IO.File]::WriteAllText($infPath, $infContent, [System.Text.Encoding]::ASCII)
    try { Set-ItemProperty -Path $infPath -Name Attributes -Value ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue } catch {}

    # Windows Explorer DriveIcons registry registration for BOTH HKLM and HKCU pointing to mios-v2.ico
    foreach ($hIVE in @("HKLM", "HKCU")) {
        try {
            $regPath = "${hIVE}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$Letter\DefaultIcon"
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name "(default)" -Value "$icoPathV2" -Force
            Write-Host "    [+] Registered Explorer DriveIcon ($hIVE) for $driveRoot ($Label -> mios-v2.ico)" -ForegroundColor Green
        } catch {}
    }
}

Stage-PartitionIcon -Letter $CatDrive  -Label "MiOS-Cat"  -Type "CAT"
Stage-PartitionIcon -Letter $RepoDrive -Label "MiOS-Repo" -Type "REPO"
Stage-PartitionIcon -Letter $DataDrive -Label "MiOS-Data" -Type "DATA"

# Flush Explorer Shell Icon Cache and broadcast SHCNE_ASSOCCHANGED
try {
    [MiOSShellNotifier]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-Host "    [+] Broadcasted SHCNE_ASSOCCHANGED icon cache flush to Windows Explorer" -ForegroundColor Green
} catch {}
