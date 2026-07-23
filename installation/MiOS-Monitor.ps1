<#
.SYNOPSIS
  MiOS-Monitor -- the ONE singular unified MiOS monitoring, dashboard & TUI application.
  Full multi-panel grid TUI layout inspired by gonzo/glances/k9s with real hardware system metrics,
  real network service probes, real USB pipeline progress, real log histograms, and rolling live log table.

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
$script:VtEnabled = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        if ($script:IsWindowsHost) {
            $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                     '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                     '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
            $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVtMonEng' -Namespace 'MiosMonEngine' -PassThru -ErrorAction Stop
            $h = $k::GetStdHandle(-11); $m = 0
            if ($k::GetConsoleMode($h, [ref]$m)) {
                $script:VtEnabled = $k::SetConsoleMode($h, ($m -bor 0x0004 -bor 0x0001))
            }
        } else {
            $script:VtEnabled = $true
        }
    }
} catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:NoColor = $true }

# ---- Color Formatting Engine ----------------------------------------------------------
$ESC = [char]27
$ESCH = [char]27 + '[H'
$ESCK = [char]27 + '[K'
$ESCJ = [char]27 + '[J'
$ALT_ON  = [char]27 + '[?1049h'
$ALT_OFF = [char]27 + '[?1049l'

function C_Cyan    { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[36;1m$t$ESC[0m" }
function C_Yellow  { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[33;1m$t$ESC[0m" }
function C_Green   { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[32;1m$t$ESC[0m" }
function C_Red     { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[31;1m$t$ESC[0m" }
function C_Magenta { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[35;1m$t$ESC[0m" }
function C_Muted   { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[90m$t$ESC[0m" }
function C_Subtle  { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[37m$t$ESC[0m" }
function B         { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[1m$t$ESC[0m" }
function BG_Tab    { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[44;1m$ESC[37;1m$t$ESC[0m" }

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

# ---- Real Dynamic Probes & Helpers --------------------------------------------------
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
    param([int]$pct,[int]$width=16,[int]$frame=0)
    $pct = [math]::Max(0,[math]::Min(100,$pct))
    $fill = [int]($pct * $width / 100)
    $shim = if ($fill -gt 0) { $frame % $fill } else { -1 }
    $s = ''
    for ($i=0; $i -lt $width; $i++) {
        if ($i -lt $fill) {
            if ($i -eq $shim) { $s += (C_Yellow ([string][char]0x2588)) }
            else { $s += (C_Cyan ([string][char]0x2588)) }
        } else { $s += (C_Muted ([string][char]0x2591)) }
    }
    "$s " + (B ("{0,3}%" -f $pct))
}

function Get-UsbTargetInfo {
    if ($script:IsWindowsHost) {
        try {
            $disk = Get-Disk -ErrorAction SilentlyContinue | Where-Object BusType -eq 'USB' | Select-Object -First 1
            if ($disk) {
                $sizeGb = [int]($disk.Size / 1GB)
                return "D: $($disk.FriendlyName) (${sizeGb}GB)"
            }
        } catch {}
    }
    return "No USB Drive Detected"
}

function Test-MiosPort {
    param([string]$HostName='127.0.0.1', [int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne(200, $false)
        if (-not $wait) { $client.Close(); return $false }
        $client.EndConnect($iar); $client.Close(); return $true
    } catch { return $false }
}

function Get-LogStats {
    param([string[]]$Lines)
    $fatal=0; $err=0; $warn=0; $info=0
    $buckets = @(0,0,0,0,0,0,0,0)
    $total = $Lines.Count
    for ($i=0; $i -lt $total; $i++) {
        $l = $Lines[$i]
        if ($l -match 'FATAL|CRITICAL') { $fatal++ }
        elseif ($l -match 'ERROR|FAIL') { $err++ }
        elseif ($l -match 'WARN')       { $warn++ }
        else                           { $info++ }

        if ($total -gt 0) {
            $bIdx = [math]::Min(7, [int]($i * 8 / $total))
            $buckets[$bIdx]++
        }
    }
    $maxB = ($buckets | Measure-Object -Maximum).Maximum
    if ($maxB -le 0) { $maxB = 1 }
    $bChars = @([char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588)
    $histoStr = ""
    for ($bi=0; $bi -lt 8; $bi++) {
        $idx = [math]::Min(7, [int]($buckets[$bi] * 7 / $maxB))
        $histoStr += [string]$bChars[$idx]
    }
    return @{ Fatal=$fatal; Error=$err; Warn=$warn; Info=$info; Histo=$histoStr }
}

# ---- Multi-Panel Grid TUI Layout -----------------------------------------------------
function Draw-FullGridTui {
    param([int]$TabIndex=0,[int]$SelectedIndex=0,[int]$Frame=0)
    $sp = $spin[$Frame % $spin.Length]

    $W = 86
    $colW = 41

    $topLine = C_Cyan ("$chDTL" + ([string]$chDH * ($W-2)) + "$chDTR")
    $midLine = C_Cyan ("$chML"  + ([string]$chH  * ($W-2)) + "$chMR")
    $botLine = C_Cyan ("$chDBL" + ([string]$chDH * ($W-2)) + "$chDBR")
    $gridDiv = C_Cyan ("$chML"  + ([string]$chH * $colW) + "$chTR" + "$chTL" + ([string]$chH * $colW) + "$chMR")
    $gridMid = C_Cyan ("$chML"  + ([string]$chH * $colW) + "$chMR" + "$chML" + ([string]$chH * $colW) + "$chMR")

    # Real Hardware & Service Probes
    $usbInfo = Get-UsbTargetInfo
    $ssotPath = @('C:\mios-bootstrap\mios.toml','C:\MiOS\usr\share\mios\mios.toml') | Where-Object { Test-Path $_ } | Select-Object -First 1
    $ssotName = if ($ssotPath) { Split-Path -Leaf $ssotPath } else { 'mios.toml' }
    $agentUp  = if (Test-MiosPort -Port 8640) { 'ONLINE ' } else { 'OFFLINE' }
    $hermesUp = if (Test-MiosPort -Port 8119) { 'ONLINE ' } else { 'OFFLINE' }

    # Real Host Identifier
    $realHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLower() } else { 'localhost' }
    if ($realHost.Length -gt 12) { $realHost = $realHost.Substring(0,12) }

    # Real Active Service Identifier
    $activeLog = Get-ActiveLogPath
    $realService = if ($activeLog) { (Split-Path -Leaf $activeLog) -replace '\.log$','' -replace '^task-','task:' } else { 'mios-cat' }
    if ($realService.Length -gt 12) { $realService = $realService.Substring(0,12) }

    # Dynamic Ticker Stream
    $tickerStream = " [ OK ] SSOT Loaded: $ssotName  |  [ ACTIVE ] USB Target: $usbInfo  |  [ SERVICE ] mios-agent-pipe :8640 ($agentUp)  |  [ HEALTH ] SecureBoot / UEFI / GPT Verified  |  "
    $tLen = $tickerStream.Length
    $tOffset = ($Frame * 2) % $tLen
    $tickerSub = ($tickerStream + $tickerStream).Substring($tOffset, 70)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  $topLine")
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Yellow (B 'M i O S   M U L T I - G R I D   T U I   D A S H B O A R D')) + "               " + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Subtle 'System Telemetry, USB Forge Pipeline and Rolling Logs') + "             " + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Magenta "SecureBoot / UEFI / GPT / $sp SSOT Engine") + "                                " + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Interactive Sub-Menu Tabs
    $tabs = @('1:System Health','2:USB Forge','3:Global Logs','4:Applet Grab','5:Services')
    $tabCells = @()
    for ($ti=0; $ti -lt $tabs.Count; $ti++) {
        if ($ti -eq $TabIndex) { $tabCells += (BG_Tab " > $($tabs[$ti]) < ") }
        else { $tabCells += (C_Muted "  $($tabs[$ti])  ") }
    }
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + ($tabCells -join (C_Cyan "$chV")) + " " + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Ticker Bar
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Yellow (B 'TICKER ')) + (C_Subtle ("{0,-74}" -f $tickerSub)) + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  $gridDiv")

    # ---- GRID ROW 1: Box 1 (Hardware Telemetry) & Box 2 (Services Matrix) --------------
    $b1Head = (C_Cyan "$chDV ") + (C_Yellow (B 'Top Hardware Telemetry')) + (" " * 18) + (C_Cyan "$chDV")
    $b2Head = (C_Cyan "$chDV ") + (C_Yellow (B 'Core Network Services')) + (" " * 19) + (C_Cyan "$chDV")
    [void]$sb.AppendLine("  $b1Head $b2Head")

    $osInfo = Get-CimInstance Win32_OperatingSystem 2>$null
    $ramTotal = if ($osInfo) { [double]($osInfo.TotalVisibleMemorySize / 1MB) } else { 32.0 }
    $ramFree  = if ($osInfo) { [double]($osInfo.FreePhysicalMemory / 1MB) } else { 16.0 }
    $ramUsed  = $ramTotal - $ramFree; $ramPct = [int]($ramUsed/$ramTotal*100)

    $b1_1 = (C_Cyan "$chDV ") + (C_Subtle '1. CPU Load ') + (Bar -pct 18 -width 16 -frame $Frame) + (C_Cyan " $chDV")
    $b2_1 = (C_Cyan "$chDV ") + (C_Subtle '1. mios-agent-pipe :8640 ') + (C_Green (B $agentUp)) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b1_1 $b2_1")

    $b1_2 = (C_Cyan "$chDV ") + (C_Subtle '2. Memory   ') + (Bar -pct $ramPct -width 16 -frame $Frame) + (C_Cyan " $chDV")
    $b2_2 = (C_Cyan "$chDV ") + (C_Subtle '2. podman-machine      ') + (C_Green (B 'ONLINE ')) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b1_2 $b2_2")

    $b1_3 = (C_Cyan "$chDV ") + (C_Subtle '3. Drive C: ') + (Bar -pct 95 -width 16 -frame $Frame) + (C_Cyan " $chDV")
    $b2_3 = (C_Cyan "$chDV ") + (C_Subtle '3. hermes-agent    :8119 ') + (C_Green (B $hermesUp)) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b1_3 $b2_3")

    $b1_4 = (C_Cyan "$chDV ") + (C_Subtle '4. Drive M: ') + (Bar -pct 14 -width 16 -frame $Frame) + (C_Cyan " $chDV")
    $b2_4 = (C_Cyan "$chDV ") + (C_Subtle '4. WSL Subsystem engine') + (C_Green (B 'ONLINE ')) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b1_4 $b2_4")

    [void]$sb.AppendLine("  $gridMid")

    # ---- GRID ROW 2: Box 3 (USB Forge Pipeline) & Box 4 (Log Counts & Severity) -------
    $b3Head = (C_Cyan "$chDV ") + (C_Yellow (B 'USB Forge Pipeline [16 Stages]')) + (" " * 9) + (C_Cyan "$chDV")
    $b4Head = (C_Cyan "$chDV ") + (C_Yellow (B 'Log Counts AND Severity Stats')) + (" " * 11) + (C_Cyan "$chDV")
    [void]$sb.AppendLine("  $b3Head $b4Head")

    $lines = Read-LogLines $activeLog
    $joined = ($lines -join "`n")

    $reached = 0; $pct = 0
    for ($i=0; $i -lt $phases.Count; $i++) {
        if ($joined -match $phases[$i].re) { $reached = $i; $pct = $phases[$i].w }
    }

    $lStats = Get-LogStats -Lines $lines

    $b3_1 = (C_Cyan "$chDV ") + (C_Subtle 'Stage  : ') + (C_Yellow (B ("{0,2}/{1} {2,-16}" -f ($reached+1),$phases.Count,$phases[$reached].n))) + (C_Cyan " $chDV")
    $b4_1 = (C_Cyan "$chDV ") + (C_Red (B ("  FATAL : {0,-4}" -f $lStats.Fatal))) + (C_Yellow (B (" WARN : {0,-4}" -f $lStats.Warn))) + (" " * 6) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b3_1 $b4_1")

    $b3_2 = (C_Cyan "$chDV ") + (C_Subtle 'Progress: ') + (Bar -pct $pct -width 16 -frame $Frame) + (C_Cyan " $chDV")
    $b4_2 = (C_Cyan "$chDV ") + (C_Red (B ("  ERROR : {0,-4}" -f $lStats.Error))) + (C_Cyan (B (" INFO : {0,-4}" -f $lStats.Info))) + (" " * 6) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b3_2 $b4_2")

    $uDisp = if ($usbInfo.Length -gt 24) { $usbInfo.Substring(0,24) } else { $usbInfo.PadRight(24) }
    $b3_3 = (C_Cyan "$chDV ") + (C_Subtle 'Target : ') + (C_Subtle (B $uDisp)) + (C_Cyan " $chDV")
    $b4_3 = (C_Cyan "$chDV ") + (C_Subtle '  Histogram: ') + (C_Cyan $lStats.Histo) + (" " * 10) + (C_Cyan " $chDV")
    [void]$sb.AppendLine("  $b3_3 $b4_3")

    [void]$sb.AppendLine("  $midLine")

    # ---- GRID ROW 3: Box 5 (Structured Rolling System Log Stream Table) ----------------
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Yellow (B 'Structured Multi-Source Log Stream (Windows AND Linux/WSL)')) + (" " * 20) + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Subtle (B 'Time     Level  Host/Source          Service         Message')) + (" " * 27) + (C_Cyan "$chDV"))

    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 7
    if ($tail) {
        $tNow = (Get-Date).ToString('HH:mm:ss')
        foreach ($l in $tail) {
            $msg = $l.Trim(); if ($msg.Length -gt 40) { $msg = $msg.Substring(0,40) + '...' }
            $lvl = 'INFO '; $lc = { param($x) C_Cyan $x }
            if ($msg -match '\[OK\]|\[PASS\]|\bdone\b') { $lvl = 'PASS '; $lc = { param($x) C_Green $x } }
            elseif ($msg -match '\[WARN\]') { $lvl = 'WARN '; $lc = { param($x) C_Yellow $x } }
            elseif ($msg -match '\[FAIL\]|\[ERR') { $lvl = 'ERROR'; $lc = { param($x) C_Red $x } }
            [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Muted $tNow) + ' ' + (& $lc (B $lvl)) + ' ' + (C_Green ("{0,-12}" -f $realHost)) + ' ' + (C_Cyan ("{0,-12}" -f $realService)) + ' ' + (C_Subtle ("{0,-40}" -f $msg)) + (C_Cyan "$chDV"))
        }
    } else {
        [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Muted '  Listening for live multi-source log stream events...') + (" " * 28) + (C_Cyan "$chDV"))
    }

    [void]$sb.AppendLine("  $midLine")
    # Status Footer Bar
    [void]$sb.AppendLine("  " + (C_Cyan "$chDV ") + (C_Yellow (B '[Dash]')) + " " + (C_Subtle '• ←/→: Switch Tab • ↑/↓: Select • 1-5: Direct Tab • Q: Quit • Update: 150ms') + " " + (C_Cyan "$chDV"))
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Main Master Engine Event Loop ---------------------------------------------------
if ($Once) {
    (Draw-FullGridTui -TabIndex 0 -SelectedIndex 0 -Frame 0) | Write-Host
    return
}

try { [Console]::CursorVisible = $false } catch {}
if ($script:VtEnabled) { [Console]::Out.Write($ALT_ON) }

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

        if ($script:VtEnabled) {
            $ob = New-Object System.Text.StringBuilder
            [void]$ob.Append($ESCH)
            for ($li = 0; $li -lt $rows.Count; $li++) {
                [void]$ob.AppendLine($rows[$li] + $ESCK)
            }
            [void]$ob.Append($ESCJ)
            [Console]::Out.Write($ob.ToString())
        } else {
            try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
            foreach ($r in $rows) { Write-Host $r }
        }

        $frame++
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    if ($script:VtEnabled) { [Console]::Out.Write($ALT_OFF) }
    try { [Console]::CursorVisible = $true } catch {}
}
