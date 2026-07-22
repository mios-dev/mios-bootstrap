# Powershell runtime helper to generate & stage MiOS drive icons across MiOS-Cat USB partitions.
param(
    [string]$CatDrive = "D",
    [string]$RepoDrive = "",
    [string]$DataDrive = ""
)

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function New-MiOSDriveIcon {
    param([string]$Path, [string]$LabelText = "MiOS")
    try {
        $bmp = New-Object System.Drawing.Bitmap 256, 256
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = 'AntiAlias'
        $g.TextRenderingHint  = 'AntiAliasGridFit'
        $g.InterpolationMode  = 'HighQualityBicubic'
        $g.PixelOffsetMode    = 'HighQuality'

        # Colors: Hokusai deep blue bg (#282262), sunset orange badge (#F35C15), warm cream text (#E7DFD3)
        $g.Clear([System.Drawing.Color]::FromArgb(40, 34, 98))

        # Circle badge
        $brushBadge = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 92, 21))
        $g.FillEllipse($brushBadge, 24, 24, 208, 208)

        # Outer ring
        $penRing = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(231, 223, 211), 6)
        $g.DrawEllipse($penRing, 24, 24, 208, 208)

        # Emblem Text 'M'
        $fontM = New-Object System.Drawing.Font('Arial', 96, [System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment     = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF 0, 0, 256, 230
        $g.DrawString('M', $fontM, [System.Drawing.Brushes]::White, $rect, $sf)

        # Bottom label badge
        if ($LabelText) {
            $fontL = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)
            $rectL = New-Object System.Drawing.RectangleF 0, 195, 256, 45
            $g.DrawString($LabelText.ToUpper(), $fontL, [System.Drawing.Brushes]::LightGray, $rectL, $sf)
        }

        $hIcon = $bmp.GetHicon()
        $icon  = [System.Drawing.Icon]::FromHandle($hIcon)

        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create)
        $icon.Save($fs)
        $fs.Close()
        Write-Host "    [+] Generated MiOS icon: $Path" -ForegroundColor Green
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
    $infContent = @"
[autorun]
icon=autorun\mios.ico
label=$Label
"@
    [System.IO.File]::WriteAllText($infPath, $infContent, [System.Text.Encoding]::ASCII)
    attrib +h +s $infPath 2>$null

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
