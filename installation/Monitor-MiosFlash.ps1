<#
.SYNOPSIS
  MiOS-Cat USB flash monitor -- fully branded, SSOT-themed (runtime [colors]) live GRAPHICAL
  dashboard: MiOS logo, a shimmering overall progress bar, a live stats grid (elapsed/ETA, all
  three USB partitions with mini-bars, live MiOS-Xbox.iso build size, workdir free, throughput),
  an animated two-column phase checklist with per-phase timing, and a color-coded live log tail.
  Reads the flash log written by `MiOS-Cat.bat stage`.
.PARAMETER LogPath  Path to the flash log to follow.
.PARAMETER MarkerPath  Optional completion marker written when the flash process exits.
.PARAMETER Once  Render a single frame and exit (for snapshots / non-TTY hosts).
.PARAMETER IntervalMs  Redraw interval in loop mode (default 250 for smooth animation).
#>
[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:TEMP 'mios-cat-flash.log'),
    [string]$MarkerPath = (Join-Path $env:TEMP 'mios-cat-flash.marker'),
    [switch]$Once,
    [int]$IntervalMs = 250
)

# ---- Force ANSI/VT + UTF-8 so colors, block logo, braille + bars render on bare WPS 5.1 --------
$script:NoColor = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                 '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                 '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVt' -Namespace 'MiosMon' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
    }
} catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:NoColor = $true }

# ---- SSOT theme (read [colors] from mios.toml at RUNTIME; degrade-open) ------------------------
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

# ---- Phase model (matches the current MiOS-Cat.bat stage flow) ---------------------------------
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

# animated shimmer bar: a moving bright cell sweeps across the filled region
function Bar {
    param([int]$pct,[int[]]$col,[int]$width=50,[int]$frame=0,[switch]$Pulse)
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

function Draw {
    param([int]$Frame)
    $lines = Read-LogLines $LogPath
    $joined = ($lines -join "`n")
    $now = Get-Date

    # reached phase + overall pct (refined by an in-phase download/extract %)
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

    # Prefer the runner's logged start timestamp (NTFS file-tunneling can preserve a deleted
    # log's old CreationTime when it is recreated with the same name -> bogus elapsed).
    $start = $null
    $sm = [regex]::Match($joined, 'starting.*?\bat\b\s+\w*\s*(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}:\d{2})')
    if ($sm.Success) { try { $start = [datetime]::Parse($sm.Groups[1].Value) } catch {} }
    if (-not $start) { $start = try { (Get-Item $LogPath).CreationTime } catch { $now } }
    $elapsed = $now - $start
    $eta = if ($pct -gt 3 -and -not $done) { $secs = $elapsed.TotalSeconds; $rem = ($secs / ($pct/100.0)) - $secs; [TimeSpan]::FromSeconds([math]::Max(0,$rem)) } else { $null }
    $sp = $spin[$Frame % $spin.Length]

    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success
    $rule = C $ac ([string]([char]0x2550) * 72)

    # live volume + iso stats
    $vCat = VolStat 'MiOS-Cat'; $vRepo = VolStat 'MiOS-Repo'; $vData = VolStat 'MiOS-Data'
    $vM = try { Get-Volume -DriveLetter M -ErrorAction Stop } catch { $null }
    $xbox = try { Get-Item 'D:\Live_Operating_Systems\MiOS-Xbox.iso' -ErrorAction Stop } catch { $null }
    $fedora = try { Get-Item 'D:\Live_Operating_Systems\Fedora-Server.iso' -ErrorAction Stop } catch { $null }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    # pulsing tagline color for a subtle "alive" animation
    $pulse = Lerp $pal.cursor $pal.accent (0.5 + 0.5*[math]::Sin($Frame/6.0))
    [void]$sb.AppendLine("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    [void]$sb.AppendLine("  " + (C $ac (B '████╗ ████║╚═╝██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'C A T')))
    [void]$sb.AppendLine("  " + (C $ac (B '██╔████╔██║██╗██║   ██║███████╗')) + "   " + (C $pulse 'zero-config USB forge'))
    [void]$sb.AppendLine("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    [void]$sb.AppendLine("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT'))
    [void]$sb.AppendLine("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    [void]$sb.AppendLine("  $rule")

    # STATS GRID
    $cur = if ($done) { if($ok){'Completed'}else{'FAILED'} } else { $phases[$reached].n }
    $etaStr = if ($eta) { "{0:hh\:mm\:ss}" -f $eta } else { '—' }
    [void]$sb.AppendLine("  " + (C $su 'Target ') + (C $fg (B 'D:  Lexar SS D EQ790 1TB  (USB · disk 1)')) + "        " + (C $su 'Stage ') + (C $cu (B ("{0,2}/{1}" -f ($reached+1),$phases.Count))))
    [void]$sb.AppendLine("  " + (C $su 'Elapsed ') + (C $fg (B ("{0:hh\:mm\:ss}" -f $elapsed))) + "     " + (C $su 'ETA ') + (C $fg (B $etaStr)) + "        " + (C $su 'Phase ') + (C $suc (B $cur)) + "  " + (C $cu ([string]$sp)))
    [void]$sb.AppendLine("")
    # partition mini-bars (used fraction)
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

    # OVERALL animated bar (+ download bar during fetch/extract phases)
    [void]$sb.AppendLine("  " + (C $su 'OVERALL  ') + (Bar -pct $pct -col $pal.cursor -width 52 -frame $Frame))
    if ($null -ne $dlPct -and -not $done -and $reached -ge 6 -and $reached -le 8) {
        [void]$sb.AppendLine("  " + (C $su 'CURRENT  ') + (Bar -pct $dlPct -col $pal.success -width 52 -frame $Frame))
    } else {
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("  $rule")

    # PHASE CHECKLIST -- two columns, animated status, per-phase elapsed
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

    # LIVE LOG tail
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
        if ($ok) { [void]$sb.AppendLine("  " + (C $suc (B '  ✔  MiOS-Cat USB ready — boot it, then pick "Chat with MiOS AI".'))) }
        else     { [void]$sb.AppendLine("  " + (C $pal.error (B '  ✖  Flash failed — see LIVE LOG above / the full log file.'))) }
    } else {
        $dots = '.' * (($Frame % 4))
        [void]$sb.AppendLine("  " + (C $mu ("  $sp forging your MiOS-Cat USB$dots   (close this window anytime — the flash keeps running)")))
    }
    return @{ text = $sb.ToString(); done = $done }
}

# ---- Run ---------------------------------------------------------------------------------------
try { [Console]::Title = 'MiOS-Cat · USB Forge Monitor' } catch {}
if ($Once) { (Draw -Frame 0).text | Write-Host; return }
# Best-effort widen so the 100-col dashboard does not wrap (Windows Terminal ignores buffer caps).
try { if ([Console]::WindowWidth -lt 100) { [Console]::WindowWidth = [Math]::Min(100,[Console]::LargestWindowWidth) } } catch {}
# ALTERNATE SCREEN BUFFER (what vim/htop use): no scrollback, exactly window-sized, so redraws stay
# in place and never accumulate -- the fix for the scroll-garble in BOTH classic conhost AND Windows
# Terminal (which ignores the old BufferHeight cap). Home + clear-to-EOL per line; restore on exit.
$ALT_ON = "$ESC[?1049h"; $ALT_OFF = "$ESC[?1049l"
try { [Console]::CursorVisible = $false } catch {}
[Console]::Out.Write($ALT_ON)
$finalText = $null
try {
    $frame = 0
    while ($true) {
        $r = Draw -Frame $frame
        $rows = ($r.text -replace "`r","").TrimEnd("`n") -split "`n"
        # Clip to the visible height so nothing ever scrolls the alt buffer (the log tail -- last --
        # clips first if the window is short; the logo/stats/bars/pipeline always stay on screen).
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
# Persist the final dashboard on the normal screen so the completion/failure result stays visible.
if ($finalText) { Write-Host $finalText }
