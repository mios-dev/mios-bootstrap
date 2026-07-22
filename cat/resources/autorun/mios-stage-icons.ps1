# AI-hint: Generates canonical SSOT isometric 3D cube drive icons and autorun.inf metadata across MiOS-Cat target USB partitions at runtime.
# AI-related: /usr/share/mios/ventoy/autorun/mios-stage-icons.ps1, /usr/share/mios/mios.toml, MiOS-Cat.bat, build-mios.ps1
param(
    [string]$CatDrive = "D",
    [string]$RepoDrive = "",
    [string]$DataDrive = ""
)

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function New-MiOSDriveIcon {
    param([string]$Path, [string]$LabelText = "MiOS")
    try {
        $s = 256
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = 'AntiAlias'
        $g.TextRenderingHint  = 'AntiAliasGridFit'
        $g.InterpolationMode  = 'HighQualityBicubic'
        $g.PixelOffsetMode    = 'HighQuality'

        # Canonical MiOS Palette (SSOT build-mios.ps1):
        # bg = #282262 (Hokusai blue canvas), fg = #E7DFD3 (warm cream front-left), accent = #F35C15 (sunset orange top), shade = #14112E (dark right)
        $bg     = [System.Drawing.Color]::FromArgb(40, 34, 98)
        $fg     = [System.Drawing.Color]::FromArgb(231, 223, 211)
        $accent = [System.Drawing.Color]::FromArgb(243, 92, 21)
        $shade  = [System.Drawing.Color]::FromArgb(20, 17, 49)
        $g.Clear($bg)

        # Iso cube vertices
        $cx = $s / 2.0
        $cy = $s / 2.2
        $r  = $s * 0.36
        $cos30 = 0.866
        $hH = $r * 0.55
        $hW = $r * $cos30
        $vTop  = [System.Drawing.PointF]::new($cx,        $cy - $hH * 1.10)
        $vTopR = [System.Drawing.PointF]::new($cx + $hW,  $cy - $hH * 0.55)
        $vBotR = [System.Drawing.PointF]::new($cx + $hW,  $cy + $hH * 0.55)
        $vBot  = [System.Drawing.PointF]::new($cx,        $cy + $hH * 1.10)
        $vBotL = [System.Drawing.PointF]::new($cx - $hW,  $cy + $hH * 0.55)
        $vTopL = [System.Drawing.PointF]::new($cx - $hW,  $cy - $hH * 0.55)
        $vMid  = [System.Drawing.PointF]::new($cx,        $cy)

        [System.Drawing.PointF[]] $topPts   = @($vTop,  $vTopR, $vMid,  $vTopL)
        [System.Drawing.PointF[]] $leftPts  = @($vTopL, $vMid,  $vBot,  $vBotL)
        [System.Drawing.PointF[]] $rightPts = @($vTopR, $vBotR, $vBot,  $vMid)

        $brushTop   = New-Object System.Drawing.SolidBrush($accent)
        $brushLeft  = New-Object System.Drawing.SolidBrush($fg)
        $brushRight = New-Object System.Drawing.SolidBrush($shade)
        $g.FillPolygon($brushTop,   $topPts)
        $g.FillPolygon($brushLeft,  $leftPts)
        $g.FillPolygon($brushRight, $rightPts)
        $brushTop.Dispose(); $brushLeft.Dispose(); $brushRight.Dispose()

        # Face hatch lines (/:\ wireframe)
        $hatchPen = New-Object System.Drawing.Pen($bg, 4)
        for ($i = 1; $i -le 2; $i++) {
            $t = $i / 3.0
            $a = [System.Drawing.PointF]::new($vTopL.X + ($vMid.X - $vTopL.X) * $t, $vTopL.Y + ($vMid.Y - $vTopL.Y) * $t)
            $b = [System.Drawing.PointF]::new($vBotL.X + ($vBot.X - $vBotL.X) * $t, $vBotL.Y + ($vBot.Y - $vBotL.Y) * $t)
            $g.DrawLine($hatchPen, $a, $b)
        }
        for ($i = 1; $i -le 2; $i++) {
            $t = $i / 3.0
            $a = [System.Drawing.PointF]::new($vTopR.X + ($vMid.X - $vTopR.X) * $t, $vTopR.Y + ($vMid.Y - $vTopR.Y) * $t)
            $b = [System.Drawing.PointF]::new($vBotR.X + ($vBot.X - $vBotR.X) * $t, $vBotR.Y + ($vBot.Y - $vBotR.Y) * $t)
            $g.DrawLine($hatchPen, $a, $b)
        }
        $hatchPen.Dispose()

        # Outline stroke
        $edgePen = New-Object System.Drawing.Pen($bg, 6)
        $g.DrawPolygon($edgePen, @($vTop, $vTopR, $vBotR, $vBot, $vBotL, $vTopL))
        $g.DrawLine($edgePen, $vMid, $vTop)
        $g.DrawLine($edgePen, $vMid, $vBot)
        $g.DrawLine($edgePen, $vMid, $vTopL)
        $g.DrawLine($edgePen, $vMid, $vTopR)
        $edgePen.Dispose()

        # Volume label badge
        if ($LabelText) {
            $fontL = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectL = New-Object System.Drawing.RectangleF 0, 205, 256, 45
            $g.DrawString($LabelText.ToUpper(), $fontL, [System.Drawing.Brushes]::LightSkyBlue, $rectL, $sf)
        }

        $hIcon = $bmp.GetHicon()
        $icon  = [System.Drawing.Icon]::FromHandle($hIcon)

        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create)
        $icon.Save($fs)
        $fs.Close()
        Write-Host "    [+] Generated SSOT MiOS icon: $Path" -ForegroundColor Green
    } catch {
        Write-Host "    [!] Icon generation warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stage-PartitionIcon {
    param([string]$Letter, [string]$Label)
    if (-not $Letter -or $Letter -eq '_') { return }
    $driveRoot = "$($Letter.Trim(':')):"
    if (-not (Test-Path -LiteralPath $driveRoot)) { return }

    $autorunDir = Join-Path $driveRoot "autorun"
    $icoPath    = Join-Path $autorunDir "mios.ico"
    New-MiOSDriveIcon -Path $icoPath -LabelText $Label

    # autorun.inf on drive root
    $infPath = Join-Path $driveRoot "autorun.inf"
    if (Test-Path $infPath) { try { Set-ItemProperty -Path $infPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue } catch {} }
    $infContent = @"
[autorun]
icon=autorun\mios.ico
label=$Label
"@
    [System.IO.File]::WriteAllText($infPath, $infContent, [System.Text.Encoding]::ASCII)
    try { Set-ItemProperty -Path $infPath -Name Attributes -Value ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue } catch {}

    # Windows Explorer DriveIcons registry registration
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$Letter\DefaultIcon"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "(default)" -Value "$icoPath" -Force
        Write-Host "    [+] Registered Explorer DriveIcon for $driveRoot ($Label)" -ForegroundColor Green
    } catch {}
}

Stage-PartitionIcon -Letter $CatDrive  -Label "MiOS-Cat"
Stage-PartitionIcon -Letter $RepoDrive -Label "MiOS-Repo"
Stage-PartitionIcon -Letter $DataDrive -Label "MiOS-Data"
