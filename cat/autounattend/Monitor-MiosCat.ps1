param(
    [string]$LogPath
)

if (-not $LogPath) {
    $candidates = @(
        'C:\Windows\Temp\mios-cat-install.log',
        'C:\Windows\Temp\mios-setupcomplete.log'
    ) + (Get-ChildItem "$env:USERPROFILE\.gemini\antigravity-ide\brain\*\.system_generated\tasks\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | Select-Object -ExpandProperty FullName)
    
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $LogPath = $c; break }
    }
    if (-not $LogPath) { $LogPath = 'C:\Windows\Temp\mios-setupcomplete.log' }
}
# ANSI Color Code Helpers
$esc = [char]27
$cBg = "$esc[48;2;40;34;98m"
$cFg = "$esc[38;2;231;223;211m"
$cAcc = "$esc[38;2;26;64;127m"
$cOk = "$esc[38;2;62;119;101m"
$cWarn = "$esc[38;2;243;92;21m"
$cMuted = "$esc[38;2;148;142;142m"
$cReset = "$esc[0m"

# Set Console Title
[Console]::Title = "MiOS-Cat USB Installation Monitor"

function Render-ProgressBar {
    param([int]$pct, [string]$color)
    $width = 40
    $filled = [math]::Min($width, [math]::Max(0, [int]($pct * $width / 100)))
    $empty = $width - $filled
    $bar = "$color" + ("#" * $filled) + "$cMuted" + ("-" * $empty) + "$cReset"
    return "[$bar] $pct%"
}

while ($true) {
    if (-not (Test-Path $logPath)) {
        Clear-Host
        Write-Host "Waiting for log file to be created..."
        Start-Sleep -Seconds 2
        continue
    }

    # Read log safely
    $lines = @()
    try {
        $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        while (-not $reader.EndOfStream) {
            $lines += $reader.ReadLine()
        }
        $reader.Close()
        $stream.Close()
    } catch {
        # log lock, ignore and retry next loop
    }

    # Detect current phase and percentage
    $phase = "Initializing"
    $pct = 0
    $stage = 1
    $logTail = @()
    
    # Process lines
    foreach ($line in $lines) {
        if ($line -match "RUNNING PREFLIGHT CHECKS") { $phase = "Preflight Checks"; $pct = 5; $stage = 1 }
        elseif ($line -match "Formatting and merging all USB partitions") { $phase = "Formatting USB Drive"; $pct = 10; $stage = 2 }
        elseif ($line -match "Installing Ventoy to D:") { $phase = "Installing Ventoy Bootloader"; $pct = 15; $stage = 3 }
        elseif ($line -match "Formatting primary partition as") { $phase = "Formatting Ventoy Partitions"; $pct = 20; $stage = 3 }
        elseif ($line -match "Pulling the FULL Fedora") { $phase = "Downloading Fedora 44 Server DVD"; $stage = 4; $pct = 25 }
        elseif ($line -match "Extracting minimal boot files") { $phase = "Extracting Boot Files & Apps (7-Zip)"; $stage = 5; $pct = 40 }
        elseif ($line -match "Staging offline repository fallback") { $phase = "Staging Repositories (Robocopy)"; $stage = 6; $pct = 60 }
        elseif ($line -match "Applying custom MiOS configurations") { $phase = "Applying MiOS Identity & Customizations"; $stage = 7; $pct = 70 }
        elseif ($line -match "Performing offline servicing on MiOS_PE.wim") { $phase = "DISM WIM Image Servicing"; $stage = 8; $pct = 80 }
        elseif ($line -match "Compiling Inline Live Build of MiOS-Xbox") { $phase = "Compiling MiOS-Xbox Installer ISO"; $stage = 9; $pct = 90 }
        elseif ($line -match "MiOS-Cat DEDICATED USB INSTALLATION COMPLETED") { $phase = "Installation Completed Successfully"; $pct = 100; $stage = 10 }
        
        # Extract curl percentage if downloading
        if ($stage -eq 4 -and $line -match "(\d+\.\d+)%") {
            $dlPct = [int][double]$Matches[1]
            # Map 0-100% download to 25-39% overall progress
            $pct = 25 + [int]($dlPct * 0.15)
        }
    }

    # Get last 8 non-empty lines for tail log
    $nonEmpty = $lines | Where-Object { $_.Trim() }
    $logTail = $nonEmpty | Select-Object -Last 8

    # Render Screen
    Clear-Host
    Write-Host "$cBg$cFg" -NoNewline
    
    # ASCII Banner
    Write-Host "  $cAcc __  __ _  ___  ___        ___      _   "
    Write-Host "  $cAcc|  \/  (_)/ _ \/ __| ___  / __|__ _| |_ "
    Write-Host "  $cAcc| |\/| | | (_) \__ \/___|| (__/ _` |  _|"
    Write-Host "  $cAcc|_|  |_|_|\___/|___/      \___\__,_|\__|"
    Write-Host "  $cWarn   D E D I C A T E D   I N S T A L L E R   "
    Write-Host "  $cMuted----------------------------------------------"
    
    Write-Host "  $cFgCurrent Stage: $cWarn$stage / 10"
    Write-Host "  $cFgCurrent Task : $cOk$phase"
    
    # Progress Bar
    $pbar = Render-ProgressBar -pct $pct -color $cOk
    Write-Host "  $cFgProgress     : $pbar"
    Write-Host "  $cMuted----------------------------------------------"
    Write-Host "  $cFgLive Logs:"
    foreach ($l in $logTail) {
        $trimmed = $l.Trim()
        # strip progress bars from tail lines if they are too long/repetitive
        if ($trimmed -match "#") {
            if ($trimmed -match "(\d+\.\d+)%") { $trimmed = "Downloading Fedora... $($Matches[1])%" }
        }
        Write-Host "   $cMuted> $cFg$trimmed"
    }
    Write-Host "  $cMuted----------------------------------------------$cReset"

    if ($pct -eq 100) {
        Write-Host "`n  $cOk[+] Installation Completed! You can close this window.$cReset"
        break
    }

    Start-Sleep -Seconds 2
}
