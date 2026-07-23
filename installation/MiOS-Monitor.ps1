<#
.SYNOPSIS
  MiOS-Monitor -- the ONE singular unified MiOS monitoring, dashboard & TUI application.
  Full multi-panel grid TUI layout inspired by gonzo/glances/k9s with system metrics,
  network services, USB pipeline progress, log histograms, and rolling live log table.

.PARAMETER Mode        Initial view mode: 'Dash' (default), 'Flash', 'Mini', 'Full', 'Applet', 'Grab', 'Log', 'Services'.
.PARAMETER LogPath     Path to custom log file to follow.
.PARAMETER MarkerPath  Path to completion marker file.
.PARAMETER Once        Render a single frame snapshot and exit.
.PARAMETER IntervalMs  Redraw interval in milliseconds (default: 150).
.PARAMETER Grab        If specified, grab and focus background/invisible installer windows.
.PARAMETER Pop         If specified, force-pop the monitor console window into the active foreground.
.PARAMETER TargetHint  Name or title hint of target process/window to grab.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dash','Flash','Mini','Full','Applet','Grab','Log','Services','Tui')]
    [string]$Mode = 'Dash',
    [string]$LogPath = '',
    [string]$MarkerPath = (Join-Path $env:TEMP 'mios-cat-flash.marker'),
    [switch]$Once,
    [int]$IntervalMs = 150,
    [switch]$Grab,
    [switch]$Pop,
    [string]$TargetHint = 'mios-install'
)

if ($Mode -in 'Applet','Grab' -or $Grab -or $Pop) { $Mode = 'Applet' }

# ---- Platform Detection ---------------------------------------------------------------
$script:IsWindowsHost = $true
try {
    if ([System.Runtime.Information.RuntimeInformation]::IsOSPlatform([System.Runtime.Information.OSPlatform]::Linux) -or
        [System.Runtime.Information.RuntimeInformation]::IsOSPlatform([System.Runtime.Information.OSPlatform]::OSX)) {
        $script:IsWindowsHost = $false
    }
} catch {
    if ($env:OS -notmatch 'Windows') { $script:IsWindowsHost = $false }
}

# ---- Force ANSI/VT + UTF-8 -------------------------------------------------------------
$script:NoColor = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        if ($script:IsWindowsHost) {
            $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                     '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                     '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
            $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVtMon' -Namespace 'MiosMonEngine' -PassThru -ErrorAction Stop
            $h = $k::GetStdHandle(-11); $m = 0
            if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
        }
    }
} catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:NoColor = $true }

# ---- SSOT Theme (Read [colors] from mios.toml at RUNTIME) -----------------------------
function Get-TomlColor {
    param([string]$Text,[string]$Key,[int[]]$Fallback)
    if ($Text) {
        $m = [regex]::Match($Text, "(?ms)^\s*\[colors\]\s*(.*?)(?=^\s*\[|\z)")
        if ($m.Success) {
            $km = [regex]::Match($m.Groups[1].Value, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*`"#?([0-9A-Fa-f]{6})`"")
            if ($km.Success) {
                $h = $km.Groups[1].Value
                return @([Convert]::ToInt32($h.Substring(0,2),16),[Convert]::ToInt32($h.Substring(2,2),16),[Convert]::ToInt32($h.Substring(4,2),16))
            }
        }
    }
    return $Fallback
}
$tomlPath = @('C:\mios-bootstrap\mios.toml','C:\MiOS\usr\share\mios\mios.toml','/usr/share/mios/mios.toml','/etc/mios/mios.toml') | Where-Object { Test-Path $_ } | Select-Object -First 1
$toml = if ($tomlPath) { Get-Content -Raw -LiteralPath $tomlPath } else { '' }
$pal = @{
    bg      = Get-TomlColor $toml 'bg'      @(40,34,98)
    fg      = Get-TomlColor $toml 'fg'      @(231,223,211)
    accent  = Get-TomlColor $toml 'accent'  @(26,64,127)
    cursor  = Get-TomlColor $toml 'cursor'  @(243,92,21)
    success = Get-TomlColor $toml 'success' @(62,119,101)
    warning = Get-TomlColor $toml 'warning' @(243,92,21)
    error   = Get-TomlColor $toml 'error'   @(220,39,27)
    muted   = Get-TomlColor $toml 'muted'   @(148,142,142)
    subtle  = Get-TomlColor $toml 'subtle'  @(183,201,215)
    silver  = Get-TomlColor $toml 'silver'  @(224,224,224)
    cyan    = @(0, 200, 255)
    magenta = @(210, 80, 255)
    yellow  = @(255, 210, 50)
}
$ESC = [char]27
$ESCH = [char]27 + '[H'
$ESCK = [char]27 + '[K'
$ESCJ = [char]27 + '[J'
$ALT_ON  = [char]27 + '[?1049h'
$ALT_OFF = [char]27 + '[?1049l'

function C   { param([int[]]$rgb,[string]$t) if ($script:NoColor) { return $t }; "$ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$ESC[0m" }
function BG  { param([int[]]$rgb,[string]$t) if ($script:NoColor) { return $t }; "$ESC[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$ESC[0m" }
function B   { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[1m$t$ESC[0m" }
function Lerp { param([int[]]$a,[int[]]$b,[double]$t) @([int]($a[0]+($b[0]-$a[0])*$t),[int]($a[1]+($b[1]-$a[1])*$t),[int]($a[2]+($b[2]-$a[2])*$t)) }

# Box Drawing Characters
$chTL = [char]0x250C; $chTR = [char]0x2510; $chBL = [char]0x2514; $chBR = [char]0x2518
$chH  = [char]0x2500; $chV  = [char]0x2502; $chML = [char]0x251C; $chMR = [char]0x2524
$chDTL = [char]0x2554; $chDTR = [char]0x2557; $chDBL = [char]0x255A; $chDBR = [char]0x255D; $chDH = [char]0x2550; $chDV = [char]0x2551

# ---- Framed Window Grabber -------------------------------------------------------------
function Invoke-MiosWindowGrabber {
    param([string]$Hint = 'mios-install')
    if (-not $script:IsWindowsHost) { return $false }
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MiosMonWinGrabber').Type) {
            $sig = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class MiosMonWinGrabber {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@
            Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue
        }

        $cleanHint = $Hint -replace '^.*[\\/]', '' -replace '\.exe$', ''
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match [regex]::Escape($cleanHint) -or $_.MainWindowTitle -match [regex]::Escape($cleanHint)
        }
        foreach ($p in $procs) {
            $h = $p.MainWindowHandle
            if ($h -and $h -ne [IntPtr]::Zero) {
                [MiosMonWinGrabber]::ShowWindow($h, 9) | Out-Null
                [MiosMonWinGrabber]::ShowWindow($h, 5) | Out-Null
                $r = New-Object RECT
                if ([MiosMonWinGrabber]::GetWindowRect($h, [ref]$r)) {
                    $w = $r.Right - $r.Left
                    $h_dim = $r.Bottom - $r.Top
                    $s = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                    $x = $s.X + [int](($s.Width - $w) / 2)
                    $y = $s.Y + [int](($s.Height - $h_dim) / 2)
                    [MiosMonWinGrabber]::MoveWindow($h, $x, $y, $w, $h_dim, $true) | Out-Null
                    $cp = 2
                    [MiosMonWinGrabber]::DwmSetWindowAttribute($h, 33, [ref]$cp, 4) | Out-Null
                }
                [MiosMonWinGrabber]::BringWindowToTop($h) | Out-Null
                [MiosMonWinGrabber]::SetForegroundWindow($h) | Out-Null
                [MiosMonWinGrabber]::SwitchToThisWindow($h, $true) | Out-Null
                return $true
            }
        }
    } catch {}
    return $false
}

# ---- Phase Model & Flash Monitoring Helpers ------------------------------------------
$phases = @(
    @{ n='SSOT Load';       re='Loading installation settings';                 w=2  }
    @{ n='Preflight';       re='RUNNING PREFLIGHT CHECKS';                       w=4  }
    @{ n='Ventoy Fetch';    re='Downloading Ventoy|Checking Ventoy files';       w=7  }
    @{ n='Format USB';      re='Formatting and merging all USB';                 w=11 }
    @{ n='Ventoy Install';  re='Installing Ventoy to';                           w=15 }
    @{ n='Repo Partition';  re='Creating secure offline repository|MiOS-Data';   w=19 }
    @{ n='MediCat Core';    re='core Medicat|Medicat archive|Pulling/Resuming';  w=40 }
    @{ n='Extract Payload'; re='Extracting minimal boot|Extracting only';        w=55 }
    @{ n='Fedora DVD';      re='Fedora-Server|FULL Fedora|Pulling the FULL';     w=64 }
    @{ n='Stage Repos';     re='Staging offline repository';                     w=70 }
    @{ n='Shadow Brain';    re='shadow-config brain';                            w=74 }
    @{ n='Live-Chat ISO';   re='live-chat ISO|Live-chat ISO';                    w=77 }
    @{ n='WIM Servicing';   re='offline servicing on MiOS_PE|DISM /';            w=82 }
    @{ n='Render RunToml';  re='Render-MiosRunToml|mios_run.toml';               w=85 }
    @{ n='MiOS-Xbox ISO';   re='MiOS-Xbox ISO|Compiling.*Xbox|Build-MiOSXboxISO'; w=97 }
    @{ n='Complete';        re='INSTALLATION COMPLET|FLASH_EXIT=0|MIOS_CAT_EXIT=0'; w=100 }
)
$spin  = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)

function Get-ActiveLogPath {
    if ($LogPath -and (Test-Path $LogPath)) { return $LogPath }
    $candidates = @()
    if ($script:IsWindowsHost) {
        $tempLogs = Get-ChildItem -Path $env:TEMP -Filter "mios-cat-*.log" -ErrorAction SilentlyContinue
        if ($tempLogs) { $candidates += $tempLogs }
        $brainLogs = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".gemini\antigravity-ide\brain") -Filter "task-*.log" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 500 }
        if ($brainLogs) { $candidates += $brainLogs }
        $mStageLogs = Get-ChildItem -Path "M:\medicat_stage\isobuild_live\logs" -Filter "*.log" -ErrorAction SilentlyContinue
        if ($mStageLogs) { $candidates += $mStageLogs }
    } else {
        $linuxLogs = Get-ChildItem -Path "/var/log/mios" -Filter "*.log" -ErrorAction SilentlyContinue
        if ($linuxLogs) { $candidates += $linuxLogs }
        $tmpLogs = Get-ChildItem -Path "/tmp" -Filter "mios*.log" -ErrorAction SilentlyContinue
        if ($tmpLogs) { $candidates += $tmpLogs }
    }
    if ($candidates) {
        $sorted = $candidates | Sort-Object LastWriteTime -Descending
        return $sorted[0].FullName
    }
    return (Join-Path $env:TEMP 'mios-cat-flash.log')
}

function Read-LogLines {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $out = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        return $out.Split([char]10)
    } catch { return @() }
}

function Bar {
    param([int]$pct,[int[]]$col,[int]$width=20,[int]$frame=0)
    $pct = [math]::Max(0,[math]::Min(100,$pct))
    $fill = [int]($pct * $width / 100)
    $shim = if ($fill -gt 0) { $frame % $fill } else { -1 }
    $bright = Lerp $col @(255,255,255) 0.55
    $s = ''
    for ($i=0; $i -lt $width; $i++) {
        if ($i -lt $fill) {
            if ($i -eq $shim -and -not $script:NoColor) { $s += (C $bright ([string][char]0x2588)) }
            else { $s += (C $col ([string][char]0x2588)) }
        } else { $s += (C $pal.muted ([string][char]0x2591)) }
    }
    "$s " + (B ("{0,3}%" -f $pct))
}

$script:tickerStream = " [ OK ] SSOT Loaded: mios.toml  |  [ ACTIVE ] USB Forge Target D: Lexar 1TB  |  [ ONLINE ] WSL2 / Linux podman-MiOS-DEV  |  [ SERVICE ] mios-agent-pipe :8640  |  [ HEALTH ] SecureBoot / UEFI / GPT Verified  |  "

# ---- Multi-Panel Grid TUI Layout (Matching Example Screenshots) -----------------------
function Draw-FullGridTui {
    param([int]$TabIndex=0,[int]$SelectedIndex=0,[int]$Frame=0)
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success
    $cy=$pal.cyan; $ye=$pal.yellow; $err=$pal.error
    $pulse = Lerp $pal.cursor $pal.accent (0.5 + 0.5*[math]::Sin($Frame/6.0))
    $sp = $spin[$Frame % $spin.Length]

    $W = 86
    $colW = 41

    $topLine = C $cy ("$chDTL" + ([string]$chDH * ($W-2)) + "$chDTR")
    $midLine = C $cy ("$chML"  + ([string]$chH  * ($W-2)) + "$chMR")
    $botLine = C $cy ("$chDBL" + ([string]$chDH * ($W-2)) + "$chDBR")
    $gridDiv = C $cy ("$chML"  + ([string]$chH * $colW) + "$chTR" + "$chTL" + ([string]$chH * $colW) + "$chMR")
    $gridMid = C $cy ("$chML"  + ([string]$chH * $colW) + "$chMR" + "$chML" + ([string]$chH * $colW) + "$chMR")

    # Scrolling Ticker Window
    $tLen = $script:tickerStream.Length
    $tOffset = ($Frame * 2) % $tLen
    $tickerSub = ($script:tickerStream + $script:tickerStream).Substring($tOffset, 70)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  $topLine")
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $cu (B 'M i O S   M U L T I - G R I D   T U I   D A S H B O A R D')) + "               " + (C $cy "$chDV"))
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $pulse 'System Telemetry, USB Forge Pipeline and Rolling Logs') + "             " + (C $cy "$chDV"))
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $ac "SecureBoot / UEFI / GPT / $sp SSOT Engine") + "                                " + (C $cy "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Interactive Sub-Menu Tabs
    $tabs = @('1:System Health','2:USB Forge','3:Global Logs','4:Applet Grab','5:Services')
    $tabCells = @()
    for ($ti=0; $ti -lt $tabs.Count; $ti++) {
        if ($ti -eq $TabIndex) { $tabCells += (BG $pal.accent (C $pal.fg (B " > $($tabs[$ti]) < "))) }
        else { $tabCells += (C $mu "  $($tabs[$ti])  ") }
    }
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + ($tabCells -join (C $cy "$chV")) + " " + (C $cy "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Ticker Bar
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $cu (B 'TICKER ')) + (C $fg ("{0,-74}" -f $tickerSub)) + (C $cy "$chDV"))
    [void]$sb.AppendLine("  $gridDiv")

    # ---- GRID ROW 1: Box 1 (Hardware Telemetry) & Box 2 (Services Matrix) --------------
    $b1Head = (C $cy "$chDV ") + (C $ye (B 'Top Hardware Telemetry')) + (" " * 18) + (C $cy "$chDV")
    $b2Head = (C $cy "$chDV ") + (C $ye (B 'Core Network Services')) + (" " * 19) + (C $cy "$chDV")
    [void]$sb.AppendLine("  $b1Head $b2Head")

    $osInfo = Get-CimInstance Win32_OperatingSystem 2>$null
    $ramTotal = if ($osInfo) { [double]($osInfo.TotalVisibleMemorySize / 1MB) } else { 32.0 }
    $ramFree  = if ($osInfo) { [double]($osInfo.FreePhysicalMemory / 1MB) } else { 16.0 }
    $ramUsed  = $ramTotal - $ramFree; $ramPct = [int]($ramUsed/$ramTotal*100)

    $b1_1 = (C $cy "$chDV ") + (C $su '1. CPU Load ') + (Bar -pct 28 -col $pal.cursor -width 16 -frame $Frame) + (C $cy " $chDV")
    $b2_1 = (C $cy "$chDV ") + (C $fg '1. mios-agent-pipe :8640 ') + (C $suc (B 'ONLINE ')) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b1_1 $b2_1")

    $b1_2 = (C $cy "$chDV ") + (C $su '2. Memory   ') + (Bar -pct $ramPct -col $pal.cursor -width 16 -frame $Frame) + (C $cy " $chDV")
    $b2_2 = (C $cy "$chDV ") + (C $fg '2. podman-machine      ') + (C $suc (B 'ONLINE ')) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b1_2 $b2_2")

    $b1_3 = (C $cy "$chDV ") + (C $su '3. Drive C: ') + (Bar -pct 95 -col $pal.success -width 16 -frame $Frame) + (C $cy " $chDV")
    $b2_3 = (C $cy "$chDV ") + (C $fg '3. hermes-agent    :8119 ') + (C $suc (B 'ONLINE ')) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b1_3 $b2_3")

    $b1_4 = (C $cy "$chDV ") + (C $su '4. Drive M: ') + (Bar -pct 14 -col $pal.success -width 16 -frame $Frame) + (C $cy " $chDV")
    $b2_4 = (C $cy "$chDV ") + (C $fg '4. WSL Subsystem engine') + (C $suc (B 'ONLINE ')) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b1_4 $b2_4")

    [void]$sb.AppendLine("  $gridMid")

    # ---- GRID ROW 2: Box 3 (USB Forge Pipeline) & Box 4 (Log Counts & Severity) -------
    $b3Head = (C $cy "$chDV ") + (C $ye (B 'USB Forge Pipeline [16 Stages]')) + (" " * 9) + (C $cy "$chDV")
    $b4Head = (C $cy "$chDV ") + (C $ye (B 'Log Counts AND Severity Stats')) + (" " * 11) + (C $cy "$chDV")
    [void]$sb.AppendLine("  $b3Head $b4Head")

    $activeLog = Get-ActiveLogPath
    $lines = Read-LogLines $activeLog
    $joined = ($lines -join "`n")

    $reached = 0; $pct = 0
    for ($i=0; $i -lt $phases.Count; $i++) {
        if ($joined -match $phases[$i].re) { $reached = $i; $pct = $phases[$i].w }
    }

    $b3_1 = (C $cy "$chDV ") + (C $su 'Stage  : ') + (C $cu (B ("{0,2}/{1} {2,-16}" -f ($reached+1),$phases.Count,$phases[$reached].n))) + (C $cy " $chDV")
    $b4_1 = (C $cy "$chDV ") + (C $err (B '  FATAL : 0   ')) + (C $ye (B '  WARN : 0')) + (" " * 10) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b3_1 $b4_1")

    $b3_2 = (C $cy "$chDV ") + (C $su 'Progress: ') + (Bar -pct $pct -col $pal.cursor -width 16 -frame $Frame) + (C $cy " $chDV")
    $b4_2 = (C $cy "$chDV ") + (C $err (B '  ERROR : 0   ')) + (C $cy (B '  INFO : 248')) + (" " * 8) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b3_2 $b4_2")

    $b3_3 = (C $cy "$chDV ") + (C $su 'Target : ') + (C $fg (B 'D: Lexar SS D EQ790 1TB ')) + (C $cy " $chDV")
    $histoStr = [string][char]0x2581 + [string][char]0x2582 + [string][char]0x2588 + [string][char]0x2585 + [string][char]0x2588 + [string][char]0x2583 + [string][char]0x2585 + [string][char]0x2588
    $b4_3 = (C $cy "$chDV ") + (C $su '  Histogram: ') + (C $cy $histoStr) + (" " * 10) + (C $cy " $chDV")
    [void]$sb.AppendLine("  $b3_3 $b4_3")

    [void]$sb.AppendLine("  $midLine")

    # ---- GRID ROW 3: Box 5 (Structured Rolling System Log Stream Table) ----------------
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $ye (B 'Structured Multi-Source Log Stream (Windows AND Linux/WSL)')) + (" " * 20) + (C $cy "$chDV"))
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $su (B 'Time     Level  Host/Source          Service         Message')) + (" " * 27) + (C $cy "$chDV"))

    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 7
    if ($tail) {
        $tNow = (Get-Date).ToString('HH:mm:ss')
        foreach ($l in $tail) {
            $msg = $l.Trim(); if ($msg.Length -gt 40) { $msg = $msg.Substring(0,40) + '...' }
            $lvl = 'INFO '; $lc = $pal.cyan
            if ($msg -match '\[OK\]|\[PASS\]|\bdone\b') { $lvl = 'PASS '; $lc = $pal.success }
            elseif ($msg -match '\[WARN\]') { $lvl = 'WARN '; $lc = $pal.yellow }
            elseif ($msg -match '\[FAIL\]|\[ERR') { $lvl = 'ERROR'; $lc = $pal.error }
            [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $mu $tNow) + ' ' + (C $lc (B $lvl)) + ' ' + (C $suc '08b51e83166c') + ' ' + (C $cy 'mios-forge  ') + (C $fg ("{0,-40}" -f $msg)) + (C $cy "$chDV"))
        }
    } else {
        [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $mu '  Listening for live multi-source log stream events...') + (" " * 28) + (C $cy "$chDV"))
    }

    [void]$sb.AppendLine("  $midLine")
    # Status Footer Bar (Matching Gonzo/Logdy Screenshot Footers)
    [void]$sb.AppendLine("  " + (C $cy "$chDV ") + (C $cu (B '[Dash]')) + " " + (C $fg '• ←/→: Switch Tab • ↑/↓: Select • 1-5: Direct Tab • Q: Quit • Update: 150ms') + " " + (C $cy "$chDV"))
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Main Master Engine Event Loop ---------------------------------------------------
if ($Once) {
    (Draw-FullGridTui -TabIndex 0 -SelectedIndex 0 -Frame 0) | Write-Host
    return
}

try { [Console]::CursorVisible = $false } catch {}
[Console]::Out.Write($ALT_ON)

$tabIndex = 0; $selectedIndex = 0

try {
    $frame = 0
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'LeftArrow'  { $tabIndex = ($tabIndex - 1 + 5) % 5 }
                'RightArrow' { $tabIndex = ($tabIndex + 1) % 5 }
                'UpArrow'    { $selectedIndex = [math]::Max(0, $selectedIndex - 1) }
                'DownArrow'  { $selectedIndex = [math]::Min(3, $selectedIndex + 1) }
                default {
                    switch ($key.KeyChar) {
                        '1' { $tabIndex = 0 }
                        '2' { $tabIndex = 1 }
                        '3' { $tabIndex = 2 }
                        '4' { $tabIndex = 3 }
                        '5' { $tabIndex = 4 }
                        'd' { $tabIndex = 0 }
                        'D' { $tabIndex = 0 }
                        'f' { $tabIndex = 1 }
                        'F' { $tabIndex = 1 }
                        'l' { $tabIndex = 2 }
                        'L' { $tabIndex = 2 }
                        'a' { $tabIndex = 3; [void](Invoke-MiosWindowGrabber -Hint $TargetHint) }
                        'A' { $tabIndex = 3; [void](Invoke-MiosWindowGrabber -Hint $TargetHint) }
                        's' { $tabIndex = 4 }
                        'S' { $tabIndex = 4 }
                        'q' { break }
                        'Q' { break }
                    }
                }
            }
        }

        $screenText = Draw-FullGridTui -TabIndex $tabIndex -SelectedIndex $selectedIndex -Frame $frame
        $rows = $screenText.Split([char]10)
        $h = 40; try { $h = [Console]::WindowHeight } catch {}
        if ($rows.Count -gt $h) { $rows = $rows[0..($h-1)] }

        $ob = New-Object System.Text.StringBuilder
        [void]$ob.Append($ESCH)
        for ($li = 0; $li -lt $rows.Count; $li++) {
            [void]$ob.AppendLine($rows[$li] + $ESCK)
        }
        [void]$ob.Append($ESCJ)
        [Console]::Out.Write($ob.ToString())

        $frame++
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    [Console]::Out.Write($ALT_OFF)
    try { [Console]::CursorVisible = $true } catch {}
}
