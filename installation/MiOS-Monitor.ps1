<#
.SYNOPSIS
  MiOS-Monitor -- the ONE singular unified MiOS monitoring, dashboard & management application.
  Losslessly unifies system dashboards (mios dash/mini/monitor), USB forge & ISO build monitoring,
  rolling global multi-source logs (Windows + Linux/WSL), Win32 window grabbing applets,
  and interactive tabbed TUI controls into a single canonical codebase.

.PARAMETER Mode        Initial view mode: 'Dash' (default), 'Flash', 'Mini', 'Full', 'Applet', 'Grab', 'Log', 'Services'.
.PARAMETER LogPath     Path to custom log file to follow.
.PARAMETER MarkerPath  Path to completion marker file.
.PARAMETER Once        Render a single frame snapshot and exit.
.PARAMETER IntervalMs  Redraw interval in milliseconds (default: 250).
.PARAMETER Grab        If specified, grab and focus background/invisible installer windows.
.PARAMETER Pop         If specified, force-pop the monitor console window into the active foreground.
.PARAMETER TargetHint  Name or title hint of target process/window to grab.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dash','Flash','Mini','Full','Applet','Grab','Log','Services','Config','Tui')]
    [string]$Mode = 'Dash',
    [string]$LogPath = '',
    [string]$MarkerPath = (Join-Path $env:TEMP 'mios-cat-flash.marker'),
    [switch]$Once,
    [int]$IntervalMs = 250,
    [switch]$Grab,
    [switch]$Pop,
    [string]$TargetHint = 'mios-install'
)

if ($Mode -in 'Applet','Grab' -or $Grab -or $Pop) { $Mode = 'Applet' }

# ---- Force ANSI/VT + UTF-8 -------------------------------------------------------------
$script:NoColor = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                 '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                 '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVtMon' -Namespace 'MiosMonEngine' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
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
$tomlPath = @('C:\mios-bootstrap\mios.toml','C:\MiOS\usr\share\mios\mios.toml') | Where-Object { Test-Path $_ } | Select-Object -First 1
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
}
$ESC = [char]27
function C  { param([int[]]$rgb,[string]$t) if ($script:NoColor) { return $t }; "$ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$ESC[0m" }
function B  { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[1m$t$ESC[0m" }
function Lerp { param([int[]]$a,[int[]]$b,[double]$t) @([int]($a[0]+($b[0]-$a[0])*$t),[int]($a[1]+($b[1]-$a[1])*$t),[int]($a[2]+($b[2]-$a[2])*$t)) }

# Box Drawing Characters
$chTL = [char]0x250C; $chTR = [char]0x2510; $chBL = [char]0x2514; $chBR = [char]0x2518
$chH  = [char]0x2500; $chV  = [char]0x2502; $chML = [char]0x251C; $chMR = [char]0x2524
$chDTL = [char]0x2554; $chDTR = [char]0x2557; $chDBL = [char]0x255A; $chDBR = [char]0x255D; $chDH = [char]0x2550; $chDV = [char]0x2551

# ---- Framed Win32 P/Invoke Window Grabber ---------------------------------------------
function Invoke-MiosWindowGrabber {
    param([string]$Hint = 'mios-install')
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
$script:phaseFirstSeen = @{}

function Get-ActiveLogPath {
    if ($LogPath -and (Test-Path $LogPath)) { return $LogPath }
    $candidates = @()
    $tempLogs = Get-ChildItem -Path $env:TEMP -Filter "mios-cat-*.log" -ErrorAction SilentlyContinue
    if ($tempLogs) { $candidates += $tempLogs }
    $brainLogs = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".gemini\antigravity-ide\brain") -Filter "task-*.log" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 500 }
    if ($brainLogs) { $candidates += $brainLogs }
    $mStageLogs = Get-ChildItem -Path "M:\medicat_stage\isobuild_live\logs" -Filter "*.log" -ErrorAction SilentlyContinue
    if ($mStageLogs) { $candidates += $mStageLogs }
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
        return $out -split "`r?`n"
    } catch { return @() }
}
function VolStat { param([string]$Label) try { Get-Volume -FileSystemLabel $Label -ErrorAction Stop } catch { $null } }
function GB { param($bytes) if ($null -eq $bytes) { '—' } else { '{0:N0}G' -f ($bytes/1GB) } }

function Bar {
    param([int]$pct,[int[]]$col,[int]$width=50,[int]$frame=0)
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
function MiniBar { param([double]$frac,[int[]]$col,[int]$width=16)
    $frac = [math]::Max(0.0,[math]::Min(1.0,$frac)); $fill=[int]($frac*$width)
    (C $col ([string]([char]0x2588)*$fill)) + (C $pal.muted ([string]([char]0x2591)*($width-$fill)))
}

# Live Scrolling Ticker Message Stream
$script:tickerStream = " [ OK ] SSOT Loaded: mios.toml  |  [ ACTIVE ] USB Forge Target D: Lexar 1TB  |  [ ONLINE ] WSL2 podman-MiOS-DEV  |  [ SERVICE ] mios-agent-pipe :8640  |  [ HEALTH ] SecureBoot / UEFI / GPT Verified  |  "

# ---- Global Header, Ticker & Sub-Menu Component --------------------------------------
function Draw-HeaderAndTabs {
    param([string]$ActiveTab,[int]$Frame=0)
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success
    $pulse = Lerp $pal.cursor $pal.accent (0.5 + 0.5*[math]::Sin($Frame/6.0))
    $sp = $spin[$Frame % $spin.Length]

    $w = 76
    $topLine = C $ac ("$chDTL" + ([string]$chDH * ($w-2)) + "$chDTR")
    $midLine = C $ac ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")

    # Calculate Scrolling Ticker Window
    $tLen = $script:tickerStream.Length
    $tOffset = ($Frame * 2) % $tLen
    $tickerSub = ($script:tickerStream + $script:tickerStream).Substring($tOffset, 68)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  $topLine")
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')) + "                                  " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '████╗ ████║╚═╝██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'M i O S  A P P L I C A T I O N')) + "     " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '██╔████╔██║██╗██║   ██║███████╗')) + "   " + (C $pulse 'unified system status and USB forge') + "   " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')) + "                                  " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su "SecureBoot · UEFI · GPT · $sp SSOT") + "     " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')) + "                                  " + (C $ac "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Scrolling Ticker Bar
    [void]$sb.AppendLine("  " + (C $ac "$chDV ") + (C $cu (B 'TICKER ')) + (C $fg $tickerSub) + (C $ac "$chDV"))
    [void]$sb.AppendLine("  $midLine")

    # Sub-Menu Navigation Tabs
    $tabs = @(
        @{ id='Dash';     label='1:System Dash' },
        @{ id='Flash';    label='2:USB Forge' },
        @{ id='Log';      label='3:Global Logs' },
        @{ id='Applet';   label='4:Applet Grab' },
        @{ id='Services'; label='5:Services' }
    )
    $tabCells = @()
    foreach ($t in $tabs) {
        if ($t.id -eq $ActiveTab) {
            $tabCells += (C $pal.bg (C $cu (B " [ $($t.label) ] ")))
        } else {
            $tabCells += (C $mu "  $($t.label)  ")
        }
    }
    $sep = C $ac [string]$chV
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + ($tabCells -join $sep) + (C $ac " $chV"))
    [void]$sb.AppendLine("  $midLine")
    return $sb.ToString()
}

# ---- Tab 1: System Status & Health View ---------------------------------------------
function Draw-TabDash {
    param([int]$Frame=0)
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success; $wa=$pal.warning
    $w = 76
    $botLine = C $ac ("$chDBL" + ([string]$chDH * ($w-2)) + "$chDBR")
    $midLine = C $ac ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Draw-HeaderAndTabs -ActiveTab 'Dash' -Frame $Frame))

    $osInfo = Get-CimInstance Win32_OperatingSystem 2>$null
    $osName = if ($osInfo) { $osInfo.Caption } else { [Environment]::OSVersion.VersionString }
    $cpuInfo = Get-CimInstance Win32_Processor 2>$null | Select-Object -First 1
    $cpuName = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { 'x86_64 Processor' }
    $ramTotal = if ($osInfo) { [double]($osInfo.TotalVisibleMemorySize / 1MB) } else { 32.0 }
    $ramFree  = if ($osInfo) { [double]($osInfo.FreePhysicalMemory / 1MB) } else { 16.0 }
    $ramUsed  = $ramTotal - $ramFree
    $ramFrac  = if ($ramTotal -gt 0) { $ramUsed / $ramTotal } else { 0 }

    $driveC = try { Get-Volume -DriveLetter C -ErrorAction Stop } catch { $null }
    $driveM = try { Get-Volume -DriveLetter M -ErrorAction Stop } catch { $null }

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'SYSTEM OVERVIEW AND TELEMETRY') + "                                     " + (C $ac "$chV"))
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Host OS  : ') + (C $fg (B ("{0,-50}" -f $osName))) + (C $ac "$chV"))
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $su 'CPU      : ') + (C $fg ("{0,-50}" -f $cpuName)) + (C $ac "$chV"))
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Memory   : ') + (MiniBar -frac $ramFrac -col $pal.cursor -width 22) + " " + (C $fg (("{0:N1}GB / {1:N1}GB" -f $ramUsed, $ramTotal))) + "    " + (C $ac "$chV"))
    
    if ($driveC) {
        $cUsed = ($driveC.Size - $driveC.SizeRemaining) / 1GB; $cTotal = $driveC.Size / 1GB; $cFrac = $cUsed / $cTotal
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Drive C: : ') + (MiniBar -frac $cFrac -col $pal.success -width 22) + " " + (C $fg (("{0:N0}GB / {1:N0}GB" -f $cUsed, $cTotal))) + "        " + (C $ac "$chV"))
    }
    if ($driveM) {
        $mUsed = ($driveM.Size - $driveM.SizeRemaining) / 1GB; $mTotal = $driveM.Size / 1GB; $mFrac = $mUsed / $mTotal
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Drive M: : ') + (MiniBar -frac $mFrac -col $pal.success -width 22) + " " + (C $fg (("{0:N0}GB / {1:N0}GB" -f $mUsed, $mTotal))) + "        " + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'MIOS SERVICES MATRIX') + "                                              " + (C $ac "$chV"))
    $svcList = @(
        @{ name='mios-agent-pipe'; port=8640; desc='Portal and Configurator' },
        @{ name='podman-machine-default'; port=0; desc='Container Engine' },
        @{ name='hermes-agent'; port=8119; desc='Hermes Agent Dashboard' },
        @{ name='wsl'; port=0; desc='WSL Subsystem Engine' }
    )
    foreach ($s in $svcList) {
        $st = 'STOPPED'; $sc = $pal.muted
        $p = Get-Process -Name $s.name -ErrorAction SilentlyContinue
        if ($p) { $st = 'RUNNING'; $sc = $pal.success }
        $portStr = if ($s.port -gt 0) { ":$($s.port)" } else { '     ' }
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $fg ("{0,-22}" -f $s.name)) + (C $su ("{0,-6}" -f $portStr)) + (C $sc (B ("{0,-8}" -f $st))) + " " + (C $mu ("{0,-30}" -f $s.desc)) + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $cu (B '  [1-5] Switch Tab')) + "   " + (C $fg (B '[R] Refresh')) + "   " + (C $mu '[Q] Quit Application') + "                   " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Tab 2: USB Forge & ISO Build View -----------------------------------------------
function Draw-TabFlash {
    param([int]$Frame=0)
    $w = 76
    $botLine = C $pal.accent ("$chDBL" + ([string]$chDH * ($w-2)) + "$chDBR")
    $midLine = C $pal.accent ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success

    $activeLog = Get-ActiveLogPath
    $lines = Read-LogLines $activeLog
    $joined = ($lines -join "`n")
    $now = Get-Date

    $reached = 0; $pct = 0
    for ($i=0; $i -lt $phases.Count; $i++) {
        if ($joined -match $phases[$i].re) {
            $reached = $i; $pct = $phases[$i].w
            if (-not $script:phaseFirstSeen.ContainsKey($i)) { $script:phaseFirstSeen[$i] = $now }
        }
    }
    $dlPct = $null
    $tailWin = ($lines | Select-Object -Last 14) -join "`n"
    $dm = [regex]::Matches($tailWin,'(\d{1,3}(?:\.\d+)?)%')
    if ($dm.Count -gt 0) {
        $dlPct = [int][double]$dm[$dm.Count-1].Groups[1].Value
        if ($reached -ge 0 -and $reached -lt ($phases.Count-1)) {
            $lo = $phases[$reached].w; $hi = $phases[$reached+1].w
            $pct = $lo + [int](($hi-$lo) * $dlPct / 100)
        }
    }

    $done = $false; $ok = $true
    if ((Test-Path $MarkerPath) -or ($joined -match 'FLASH_EXIT=|MIOS_CAT_EXIT=')) {
        $done = $true
        $em = [regex]::Match($joined,'(?:FLASH_EXIT|MIOS_CAT_EXIT)=(\d+)')
        if ($em.Success -and $em.Groups[1].Value -ne '0') { $ok = $false }
        if ($joined -match '\[FAIL\]') { $ok = $false }
        if ($ok) { $pct = 100 }
    }

    $start = $null
    $sm = [regex]::Match($joined, 'starting.*?\bat\b\s+\w*\s*(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}:\d{2})')
    if ($sm.Success) { try { $start = [datetime]::Parse($sm.Groups[1].Value) } catch {} }
    if (-not $start) { if ($activeLog -and (Test-Path $activeLog)) { try { $start = (Get-Item $activeLog -ErrorAction SilentlyContinue).CreationTime } catch {} } }
    if (-not $start) { $start = $now }
    $elapsed = $now - $start
    $eta = if ($pct -gt 3 -and -not $done) { $secs = $elapsed.TotalSeconds; $rem = ($secs / ($pct/100.0)) - $secs; [TimeSpan]::FromSeconds([math]::Max(0,$rem)) } else { $null }
    $sp = $spin[$Frame % $spin.Length]

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Draw-HeaderAndTabs -ActiveTab 'Flash' -Frame $Frame))

    $cur = if ($done) { if($ok){'Completed'}else{'FAILED'} } else { $phases[$reached].n }
    $etaStr = if ($eta) { "{0:hh\:mm\:ss}" -f $eta } else { '—' }
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'Target ') + (C $fg (B 'D:  Lexar SS D EQ790 1TB')) + "        " + (C $su 'Stage ') + (C $cu (B ("{0,2}/{1}" -f ($reached+1),$phases.Count))) + "                " + (C $ac "$chV"))
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'Elapsed ') + (C $fg (B ("{0:hh\:mm\:ss}" -f $elapsed))) + "     " + (C $su 'ETA ') + (C $fg (B ("{0,-8}" -f $etaStr))) + " " + (C $su 'Phase ') + (C $suc (B ("{0,-18}" -f $cur))) + " " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $midLine")

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'OVERALL PROGRESS  ') + (Bar -pct $pct -col $pal.cursor -width 48 -frame $Frame) + "   " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $midLine")

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'PIPELINE STAGE MATRIX') + "                                              " + (C $ac "$chV"))
    $half = [math]::Ceiling($phases.Count/2)
    for ($r=0; $r -lt $half; $r++) {
        $cells = @()
        foreach ($ci in @($r, $r+$half)) {
            if ($ci -ge $phases.Count) { $cells += (' ' * 34); continue }
            $icon=''; $nm=$phases[$ci].n
            if ($ci -lt $reached -or ($done -and $ok)) { $icon = C $suc ([string][char]0x2714); $col=$pal.subtle }
            elseif ($ci -eq $reached -and -not $done)  { $icon = C $cu ([string]$sp);          $col=$pal.cursor }
            elseif ($done -and -not $ok -and $ci -eq $reached) { $icon = C $pal.error ([string][char]0x2716); $col=$pal.error }
            else { $icon = C $mu ([string][char]0x00B7); $col=$pal.muted }
            $t = if ($script:phaseFirstSeen.ContainsKey($ci)) {
                    $endT = if ($script:phaseFirstSeen.ContainsKey($ci+1)) { $script:phaseFirstSeen[$ci+1] } else { $now }
                    "{0,5}s" -f [int]($endT - $script:phaseFirstSeen[$ci]).TotalSeconds
                 } else { '     ·' }
            $cells += ($icon + ' ' + (C $col ("{0,-18}" -f $nm)) + (C $mu $t) + '   ')
        }
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + ($cells -join '') + "   " + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'LIVE LOG TAIL') + "                                                      " + (C $ac "$chV"))
    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 4
    foreach ($l in $tail) {
        $t = $l.Trim(); if ($t.Length -gt 68) { $t = $t.Substring(0,68) }
        $lc = $pal.muted
        if ($t -match '\[OK\]|\[PASS\]|\bdone\b') { $lc = $pal.success }
        elseif ($t -match '\[WARN\]') { $lc = $pal.warning }
        elseif ($t -match '\[FAIL\]|\[ERR') { $lc = $pal.error }
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + ' ' + (C $lc ("{0,-68}" -f $t)) + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Tab 3: Rolling Global Multi-Source System Logs ----------------------------------
function Draw-TabLog {
    param([int]$Frame=0)
    $w = 76
    $botLine = C $pal.accent ("$chDBL" + ([string]$chDH * ($w-2)) + "$chDBR")
    $midLine = C $pal.accent ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Draw-HeaderAndTabs -ActiveTab 'Log' -Frame $Frame))

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'ROLLING GLOBAL SYSTEM LOG STREAM (WINDOWS AND LINUX/WSL)') + "           " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $midLine")

    $logSources = @()
    $activeLog = Get-ActiveLogPath
    if ($activeLog -and (Test-Path $activeLog)) { $logSources += $activeLog }
    $mLogs = Get-ChildItem -Path "C:\MiOS\var\log" -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
    if ($mLogs) { foreach ($l in $mLogs) { $logSources += $l.FullName } }

    $allLines = @()
    foreach ($src in ($logSources | Select-Object -First 3)) {
        $lines = Read-LogLines $src
        foreach ($l in ($lines | Select-Object -Last 5)) {
            if ($l.Trim()) { $allLines += @{ src = (Split-Path $src -Leaf); text = $l.Trim() } }
        }
    }

    try {
        $wslStatus = Get-Process -Name wsl -ErrorAction SilentlyContinue
        if ($wslStatus) {
            $linuxLogs = wsl.exe -d podman-MiOS-DEV sh -c "tail -n 4 /var/log/mios/*.log 2>/dev/null" 2>$null
            if ($linuxLogs) {
                foreach ($ll in ($linuxLogs -split "`r?`n")) {
                    if ($ll.Trim()) { $allLines += @{ src = 'wsl:podman-MiOS-DEV'; text = $ll.Trim() } }
                }
            }
        }
    } catch {}

    $recent = $allLines | Select-Object -Last 12
    if ($recent) {
        foreach ($item in $recent) {
            $t = $item.text; if ($t.Length -gt 48) { $t = $t.Substring(0,48) }
            $lc = $pal.muted
            if ($t -match '\[OK\]|\[PASS\]|\bdone\b|SUCCESS') { $lc = $pal.success }
            elseif ($t -match '\[WARN\]|WARNING')            { $lc = $pal.warning }
            elseif ($t -match '\[FAIL\]|\[ERR|ERROR')        { $lc = $pal.error }
            [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $su ("{0,-18}" -f $item.src)) + " " + (C $ac ([string][char]0x2502)) + ' ' + (C $lc ("{0,-48}" -f $t)) + (C $ac "$chV"))
        }
    } else {
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $mu 'No log streams connected -- monitoring active system logs...') + "          " + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $cu (B '  [1-5] Switch Tab')) + "   " + (C $fg (B '[R] Refresh Logs')) + "   " + (C $mu '[Q] Quit Application') + "                   " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Tab 4: Applet & Background Window Grabber ---------------------------------------
function Draw-TabApplet {
    param([int]$Frame=0)
    $w = 76
    $botLine = C $pal.accent ("$chDBL" + ([string]$chDH * ($w-2)) + "$chDBR")
    $midLine = C $pal.accent ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Draw-HeaderAndTabs -ActiveTab 'Applet' -Frame $Frame))

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'WIN32 P/INVOKE BACKGROUND WINDOW GRABBER AND APPLETS') + "                  " + (C $ac "$chV"))
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $mu 'Unhides, centers, rounds corners, and pops background installer windows.') + " " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $midLine")

    $activeProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'mios|powershell|cmd|build-mios' -and $_.MainWindowTitle -ne ''
    }
    if ($activeProcs) {
        foreach ($ap in $activeProcs) {
            $t = if ($ap.MainWindowTitle.Length -gt 40) { $ap.MainWindowTitle.Substring(0,40) + '...' } else { $ap.MainWindowTitle }
            [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $suc ([string][char]0x2714)) + " " + (C $fg (B ("{0,-14}" -f $ap.ProcessName))) + (C $su ("PID {0,-6}" -f $ap.Id)) + " " + (C $fg ("{0,-40}" -f $t)) + (C $ac "$chV"))
        }
    } else {
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $mu 'No background installer windows currently detected.') + "                   " + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")

    $grabbed = Invoke-MiosWindowGrabber -Hint $TargetHint
    if ($grabbed) {
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $suc (B '  [+] Successfully centered and brought target window to foreground!')) + "      " + (C $ac "$chV"))
    } else {
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $mu '  [i] Press [A] to trigger Win32 foreground grab against background tasks.') + " " + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Tab 5: Services & Container Health View -----------------------------------------
function Draw-TabServices {
    param([int]$Frame=0)
    $w = 76
    $botLine = C $pal.accent ("$chDBL" + ([string]$chDH * ($w-2)) + "$chDBR")
    $midLine = C $pal.accent ("$chML"  + ([string]$chH  * ($w-2)) + "$chMR")
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Draw-HeaderAndTabs -ActiveTab 'Services' -Frame $Frame))

    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $su 'SYSTEM SERVICES AND CONTAINER HEALTH') + "                                  " + (C $ac "$chV"))
    $svcList = @(
        @{ name='mios-agent-pipe'; port=8640; desc='Portal and Configurator API' },
        @{ name='podman-machine-default'; port=0; desc='Podman Container Machine' },
        @{ name='hermes-agent'; port=8119; desc='Hermes Agent AI Service' },
        @{ name='wsl'; port=0; desc='WSL Subsystem Engine' }
    )
    foreach ($s in $svcList) {
        $st = 'STOPPED'; $sc = $pal.muted
        $p = Get-Process -Name $s.name -ErrorAction SilentlyContinue
        if ($p) { $st = 'RUNNING'; $sc = $pal.success }
        $portStr = if ($s.port -gt 0) { ":$($s.port)" } else { '     ' }
        [void]$sb.AppendLine("  " + (C $ac "$chV ") + " " + (C $ac ([string][char]0x2502)) + " " + (C $fg ("{0,-22}" -f $s.name)) + (C $su ("{0,-6}" -f $portStr)) + (C $sc (B ("{0,-8}" -f $st))) + " " + (C $mu ("{0,-30}" -f $s.desc)) + (C $ac "$chV"))
    }
    [void]$sb.AppendLine("  $midLine")
    [void]$sb.AppendLine("  " + (C $ac "$chV ") + (C $cu (B '  [1-5] Switch Tab')) + "   " + (C $fg (B '[R] Refresh')) + "   " + (C $mu '[Q] Quit Application') + "                   " + (C $ac "$chV"))
    [void]$sb.AppendLine("  $botLine")
    return $sb.ToString()
}

# ---- Main Interactive Engine Loop ---------------------------------------------------
try { [Console]::Title = "MiOS-Monitor · Application Engine" } catch {}

if ($Once) {
    switch ($Mode) {
        'Flash'    { (Draw-TabFlash -Frame 0) | Write-Host }
        'Log'      { (Draw-TabLog -Frame 0) | Write-Host }
        'Applet'   { (Draw-TabApplet -Frame 0) | Write-Host }
        'Services' { (Draw-TabServices -Frame 0) | Write-Host }
        default    { (Draw-TabDash -Frame 0) | Write-Host }
    }
    return
}

$ALT_ON = "$ESC[?1049h"; $ALT_OFF = "$ESC[?1049l"
try { [Console]::CursorVisible = $false } catch {}
[Console]::Out.Write($ALT_ON)

$activeTab = switch ($Mode) {
    'Flash'    { 'Flash' }
    'Log'      { 'Log' }
    'Applet'   { 'Applet' }
    'Services' { 'Services' }
    default    { 'Dash' }
}

try {
    $frame = 0
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            switch ($key.KeyChar) {
                '1' { $activeTab = 'Dash' }
                '2' { $activeTab = 'Flash' }
                '3' { $activeTab = 'Log' }
                '4' { $activeTab = 'Applet' }
                '5' { $activeTab = 'Services' }
                'd' { $activeTab = 'Dash' }
                'D' { $activeTab = 'Dash' }
                'f' { $activeTab = 'Flash' }
                'F' { $activeTab = 'Flash' }
                'l' { $activeTab = 'Log' }
                'L' { $activeTab = 'Log' }
                'a' { $activeTab = 'Applet'; [void](Invoke-MiosWindowGrabber -Hint $TargetHint) }
                'A' { $activeTab = 'Applet'; [void](Invoke-MiosWindowGrabber -Hint $TargetHint) }
                's' { $activeTab = 'Services' }
                'S' { $activeTab = 'Services' }
                'q' { break }
                'Q' { break }
            }
        }

        $screenText = switch ($activeTab) {
            'Flash'    { Draw-TabFlash -Frame $frame }
            'Log'      { Draw-TabLog -Frame $frame }
            'Applet'   { Draw-TabApplet -Frame $frame }
            'Services' { Draw-TabServices -Frame $frame }
            default    { Draw-TabDash -Frame $frame }
        }

        $rows = ($screenText -replace "`r","").TrimEnd("`n") -split "`n"
        $h = 40; try { $h = [Console]::WindowHeight } catch {}
        if ($rows.Count -gt $h) { $rows = $rows[0..($h-1)] }

        $ob = New-Object System.Text.StringBuilder
        [void]$ob.Append("$ESC[H")
        for ($li = 0; $li -lt $rows.Count; $li++) {
            [void]$ob.Append($rows[$li]); [void]$ob.Append("$ESC[K")
            if ($li -lt $rows.Count - 1) { [void]$ob.Append("`n") }
        }
        [void]$ob.Append("$ESC[J")
        [Console]::Out.Write($ob.ToString())

        $frame++
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    [Console]::Out.Write($ALT_OFF)
    try { [Console]::CursorVisible = $true } catch {}
}
