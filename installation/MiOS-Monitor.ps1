<#
.SYNOPSIS
  MiOS-Monitor -- the ONE singular unified MiOS monitoring & dashboard engine.
  Losslessly unifies USB flash monitoring, system status dashboards (mios dash / mios mini),
  framed Win32 window grabbing applets, live log tailing, and TUI launcher delegation into a single codebase.

.PARAMETER Mode        Operating mode: 'Flash' (default), 'Dash', 'Mini', 'Full', 'Applet', 'Grab', 'Log', 'Tui'.
.PARAMETER LogPath     Path to the install/flash log to follow.
.PARAMETER MarkerPath  Path to completion marker file.
.PARAMETER Once        Render a single frame and exit.
.PARAMETER IntervalMs  Redraw interval in milliseconds (default: 250).
.PARAMETER Grab        If specified, grab and focus background/invisible installer windows.
.PARAMETER Pop         If specified, force-pop the monitor console window into the active foreground.
.PARAMETER Tui         If specified, delegate to python mios_monitor.py Rich TUI if present.
.PARAMETER TargetHint  Name or title hint of target process/window to grab.
#>
[CmdletBinding()]
param(
    [ValidateSet('Flash','Dash','Mini','Full','Applet','Grab','Log','Tui')]
    [string]$Mode = 'Flash',
    [string]$LogPath = (Join-Path $env:TEMP 'mios-cat-flash.log'),
    [string]$MarkerPath = (Join-Path $env:TEMP 'mios-cat-flash.marker'),
    [switch]$Once,
    [int]$IntervalMs = 250,
    [switch]$Grab,
    [switch]$Pop,
    [switch]$Tui,
    [string]$TargetHint = 'mios-install'
)

# Mode Aliases
if ($Tui -or $Mode -eq 'Tui') {
    $pyScript = 'C:\mios-bootstrap\cat\autounattend\mios_monitor.py'
    if (Test-Path $pyScript) {
        if (Get-Command python.exe -ErrorAction SilentlyContinue) { & python.exe $pyScript; exit $LASTEXITCODE }
        if (Get-Command python -ErrorAction SilentlyContinue)    { & python $pyScript; exit $LASTEXITCODE }
    }
}

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

# ---- SSOT theme (read [colors] from mios.toml at RUNTIME) -----------------------------
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
                [MiosMonWinGrabber]::ShowWindow($h, 9) | Out-Null # SW_RESTORE
                [MiosMonWinGrabber]::ShowWindow($h, 5) | Out-Null # SW_SHOW
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

function Read-LogLines {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
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

# ---- Render: Flash / Applet Monitor ---------------------------------------------------
function Draw-FlashMonitor {
    param([int]$Frame)
    $lines = Read-LogLines $LogPath
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
    if (-not $start) { if (Test-Path $LogPath) { try { $start = (Get-Item $LogPath -ErrorAction SilentlyContinue).CreationTime } catch {} } }
    if (-not $start) { $start = $now }
    $elapsed = $now - $start
    $eta = if ($pct -gt 3 -and -not $done) { $secs = $elapsed.TotalSeconds; $rem = ($secs / ($pct/100.0)) - $secs; [TimeSpan]::FromSeconds([math]::Max(0,$rem)) } else { $null }
    $sp = $spin[$Frame % $spin.Length]

    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success
    $rule = C $ac ([string]([char]0x2550) * 74)

    $vCat = VolStat 'MiOS-Cat'; $vRepo = VolStat 'MiOS-Repo'; $vData = VolStat 'MiOS-Data'
    $vM = try { Get-Volume -DriveLetter M -ErrorAction Stop } catch { $null }
    $xbox = try { Get-Item 'D:\Live_Operating_Systems\MiOS-Xbox.iso' -ErrorAction Stop } catch { $null }
    $fedora = try { Get-Item 'D:\Live_Operating_Systems\Fedora-Server.iso' -ErrorAction Stop } catch { $null }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    $pulse = Lerp $pal.cursor $pal.accent (0.5 + 0.5*[math]::Sin($Frame/6.0))
    [void]$sb.AppendLine("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    [void]$sb.AppendLine("  " + (C $ac (B '████╗ ████║╚═╝██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'M i O S  A P P L E T')))
    [void]$sb.AppendLine("  " + (C $ac (B '██╔████╔██║██╗██║   ██║███████╗')) + "   " + (C $pulse 'unified system & USB forge monitor'))
    [void]$sb.AppendLine("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    [void]$sb.AppendLine("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT · SSOT Active'))
    [void]$sb.AppendLine("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    [void]$sb.AppendLine("  $rule")

    $cur = if ($done) { if($ok){'Completed'}else{'FAILED'} } else { $phases[$reached].n }
    $etaStr = if ($eta) { "{0:hh\:mm\:ss}" -f $eta } else { '—' }
    [void]$sb.AppendLine("  " + (C $su 'Target ') + (C $fg (B 'D:  Lexar SS D EQ790 1TB  (USB · disk 1)')) + "        " + (C $su 'Stage ') + (C $cu (B ("{0,2}/{1}" -f ($reached+1),$phases.Count))))
    [void]$sb.AppendLine("  " + (C $su 'Elapsed ') + (C $fg (B ("{0:hh\:mm\:ss}" -f $elapsed))) + "     " + (C $su 'ETA ') + (C $fg (B $etaStr)) + "        " + (C $su 'Phase ') + (C $suc (B $cur)) + "  " + (C $cu ([string]$sp)))
    [void]$sb.AppendLine("")

    function PartLine { param($v,$name)
        if ($null -eq $v) { return "  " + (C $su ("{0,-10}" -f $name)) + (C $mu 'not present yet') }
        $used = $v.Size - $v.SizeRemaining; $frac = if ($v.Size -gt 0){ $used/$v.Size } else {0}
        "  " + (C $su ("{0,-10}" -f $name)) + (MiniBar -frac $frac -col $pal.success -width 18) + " " + (C $fg (("{0}/{1}" -f (GB $used),(GB $v.Size))))
    }
    [void]$sb.AppendLine((PartLine $vCat  'MiOS-Cat'))
    [void]$sb.AppendLine((PartLine $vRepo 'MiOS-Repo'))
    [void]$sb.AppendLine((PartLine $vData 'MiOS-Data'))
    $isoLine = "  " + (C $su ("{0,-10}" -f 'Xbox ISO')) + (C $fg (B (GB ($xbox.Length 2>$null)))) + (C $mu ' building') +
               "     " + (C $su 'Fedora ') + (C $fg (GB ($fedora.Length 2>$null))) +
               "     " + (C $su 'Workdir M: ') + (C $fg ((GB $vM.SizeRemaining) + ' free'))
    [void]$sb.AppendLine($isoLine)
    [void]$sb.AppendLine("  $rule")

    [void]$sb.AppendLine("  " + (C $su 'OVERALL  ') + (Bar -pct $pct -col $pal.cursor -width 52 -frame $Frame))
    if ($null -ne $dlPct -and -not $done -and $reached -ge 6 -and $reached -le 8) {
        [void]$sb.AppendLine("  " + (C $su 'CURRENT  ') + (Bar -pct $dlPct -col $pal.success -width 52 -frame $Frame))
    } else {
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("  $rule")

    [void]$sb.AppendLine("  " + (C $su 'PIPELINE'))
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
        [void]$sb.AppendLine("  " + ($cells -join ''))
    }
    [void]$sb.AppendLine("  $rule")

    [void]$sb.AppendLine("  " + (C $su 'LIVE LOG'))
    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 6
    foreach ($l in $tail) {
        $t = $l.Trim(); if ($t.Length -gt 84) { $t = $t.Substring(0,84) }
        $lc = $pal.muted
        if ($t -match '\[OK\]|\[PASS\]|\bdone\b') { $lc = $pal.success }
        elseif ($t -match '\[WARN\]') { $lc = $pal.warning }
        elseif ($t -match '\[FAIL\]|\[ERR') { $lc = $pal.error }
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + ' ' + (C $lc $t))
    }
    [void]$sb.AppendLine("  $rule")

    if ($done) {
        if ($ok) { [void]$sb.AppendLine("  " + (C $suc (B '  [+] MiOS-Cat USB ready - boot it, then pick "Chat with MiOS AI".'))) }
        else     { [void]$sb.AppendLine("  " + (C $pal.error (B '  [!] Flash failed - see LIVE LOG above / the full log file.'))) }
    } else {
        $dots = '.' * (($Frame % 4))
        [void]$sb.AppendLine("  " + (C $mu ("  $sp forging your MiOS-Cat USB$dots   (close this window anytime - the flash keeps running)")))
    }
    return @{ text = $sb.ToString(); done = $done }
}

# ---- Render: Rich System Status Dashboard Application ---------------------------------
function Draw-SystemDashboard {
    param([bool]$FullMode = $true)
    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success; $wa=$pal.warning
    $rule = C $ac ([string]([char]0x2550) * 74)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    [void]$sb.AppendLine("  " + (C $ac (B '████╗ ████║╚═╝██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'M i O S  A P P L I C A T I O N')))
    [void]$sb.AppendLine("  " + (C $ac (B '██╔████╔██║██╗██║   ██║███████╗')) + "   " + (C $fg 'unified system status & management applet'))
    [void]$sb.AppendLine("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    [void]$sb.AppendLine("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT · SSOT Projection Layer'))
    [void]$sb.AppendLine("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    [void]$sb.AppendLine("  $rule")

    # Host & Hardware
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

    [void]$sb.AppendLine("  " + (C $su 'SYSTEM OVERVIEW'))
    [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Host OS  : ') + (C $fg (B $osName)))
    [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $su 'CPU      : ') + (C $fg $cpuName))
    [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Memory   : ') + (MiniBar -frac $ramFrac -col $pal.cursor -width 22) + " " + (C $fg (("{0:N1}GB / {1:N1}GB ({2:P0})" -f $ramUsed, $ramTotal, $ramFrac))))
    
    if ($driveC) {
        $cUsed = ($driveC.Size - $driveC.SizeRemaining) / 1GB; $cTotal = $driveC.Size / 1GB; $cFrac = $cUsed / $cTotal
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Drive C: : ') + (MiniBar -frac $cFrac -col $pal.success -width 22) + " " + (C $fg (("{0:N0}GB / {1:N0}GB" -f $cUsed, $cTotal))))
    }
    if ($driveM) {
        $mUsed = ($driveM.Size - $driveM.SizeRemaining) / 1GB; $mTotal = $driveM.Size / 1GB; $mFrac = $mUsed / $mTotal
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $su 'Drive M: : ') + (MiniBar -frac $mFrac -col $pal.success -width 22) + " " + (C $fg (("{0:N0}GB / {1:N0}GB (MiOS-DEV)" -f $mUsed, $mTotal))))
    }
    [void]$sb.AppendLine("  $rule")

    # Services Matrix
    [void]$sb.AppendLine("  " + (C $su 'MIOS SERVICES MATRIX'))
    $svcList = @(
        @{ name='mios-agent-pipe'; port=8640; desc='Portal & Configurator' },
        @{ name='podman-machine-default'; port=0; desc='Container Engine' },
        @{ name='hermes-agent'; port=8119; desc='Hermes Agent Dashboard' },
        @{ name='wsl'; port=0; desc='WSL Subsystem Engine' }
    )
    foreach ($s in $svcList) {
        $st = 'STOPPED'; $sc = $pal.muted
        $p = Get-Process -Name $s.name -ErrorAction SilentlyContinue
        if ($p) { $st = 'RUNNING'; $sc = $pal.success }
        $portStr = if ($s.port -gt 0) { ":$($s.port)" } else { '     ' }
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $fg ("{0,-22}" -f $s.name)) + (C $su ("{0,-6}" -f $portStr)) + (C $sc (B ("{0,-8}" -f $st))) + " " + (C $mu $s.desc))
    }
    [void]$sb.AppendLine("  $rule")

    # Active grabbed applets/windows
    [void]$sb.AppendLine("  " + (C $su 'BACKGROUND WINDOW GRABBER & APPLETS'))
    $activeProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'mios|powershell|cmd|build-mios' -and $_.MainWindowTitle -ne ''
    } | Select-Object -First 4
    if ($activeProcs) {
        foreach ($ap in $activeProcs) {
            $t = if ($ap.MainWindowTitle.Length -gt 45) { $ap.MainWindowTitle.Substring(0,45) + '...' } else { $ap.MainWindowTitle }
            [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $suc ([string][char]0x2714)) + " " + (C $fg (B ("{0,-16}" -f $ap.ProcessName))) + (C $su ("PID {0,-6}" -f $ap.Id)) + " " + (C $fg $t))
        }
    } else {
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + " " + (C $mu 'No background windows attached -- system idle.'))
    }
    [void]$sb.AppendLine("  $rule")

    # Navigation Footer
    [void]$sb.AppendLine("  " + (C $cu (B '  [D] System Dash')) + "   " + (C $fg (B '[F] USB Forge Monitor')) + "   " + (C $su (B '[A] Grab Applet')) + "   " + (C $mu '[Q] Quit'))
    [void]$sb.AppendLine("  $rule")
    return $sb.ToString()
}

# ---- Entrypoint Router ----------------------------------------------------------------
try { [Console]::Title = "MiOS-Monitor · $Mode" } catch {}

if ($Mode -in 'Applet','Grab') {
    [void](Invoke-MiosWindowGrabber -Hint $TargetHint)
}

if ($Mode -in 'Dash','Mini','Full') {
    $isFull = ($Mode -eq 'Full' -or $Mode -eq 'Dash')
    $dashText = Draw-SystemDashboard -FullMode $isFull
    Write-Host $dashText
    return
}

if ($Once) {
    (Draw-FlashMonitor -Frame 0).text | Write-Host
    return
}

$ALT_ON = "$ESC[?1049h"; $ALT_OFF = "$ESC[?1049l"
try { [Console]::CursorVisible = $false } catch {}
[Console]::Out.Write($ALT_ON)
$finalText = $null
try {
    $frame = 0
    while ($true) {
        $r = Draw-FlashMonitor -Frame $frame
        $rows = ($r.text -replace "`r","").TrimEnd("`n") -split "`n"
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
        if ($r.done) { $finalText = $r.text; break }
        $frame++
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    [Console]::Out.Write($ALT_OFF)
    try { [Console]::CursorVisible = $true } catch {}
}
if ($finalText) { Write-Host $finalText }
