<#
.SYNOPSIS
  MiOS-Cat USB flash monitor -- fully branded, SSOT-themed (runtime [colors]) live dashboard:
  MiOS logo, overall + per-download progress bars, a phase checklist, total status, and a
  live log tail. Reads the flash log written by `MiOS-Cat.bat stage`.
.PARAMETER LogPath  Path to the flash log to follow.
.PARAMETER MarkerPath  Optional completion marker written when the flash process exits.
.PARAMETER Once  Render a single frame and exit (for snapshots / non-TTY hosts).
.PARAMETER IntervalMs  Redraw interval in loop mode (default 1000).
#>
[CmdletBinding()]
param(
    [string]$LogPath = 'C:\Users\ADMINI~1\AppData\Local\Temp\claude\c--\f3261662-e926-4a58-a106-1600bd500498\scratchpad\mios-cat-flash.log',
    [string]$MarkerPath = 'C:\Users\ADMINI~1\AppData\Local\Temp\claude\c--\f3261662-e926-4a58-a106-1600bd500498\scratchpad\mios-cat-flash.marker',
    [switch]$Once,
    [int]$IntervalMs = 1000
)

# ---- SSOT theme (read [colors] from mios.toml at RUNTIME; degrade-open) --------------------
$script:NoColor = $false
# Force-enable ANSI/VT processing so the colors + branded logo render even in Windows PowerShell
# 5.1 windows (VT is off there by default) -- otherwise the dashboard shows raw escape codes or is
# stripped to nothing. UTF-8 output so the block-letter logo draws. Falls back to no-color on error.
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
function C { param([int[]]$rgb,[string]$t) if ($script:NoColor) { return $t }; "$ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$ESC[0m" }
function B { param([string]$t) if ($script:NoColor) { return $t }; "$ESC[1m$t$ESC[0m" }

# ---- Phase model (matches the current MiOS-Cat.bat stage flow) -----------------------------
$phases = @(
    @{ n='SSOT Load';        re='Loading installation settings';                 w=2  }
    @{ n='Preflight';        re='RUNNING PREFLIGHT CHECKS';                       w=4  }
    @{ n='Ventoy Fetch';     re='Downloading Ventoy|Checking Ventoy files';       w=7  }
    @{ n='Format USB';       re='Formatting and merging all USB';                 w=11 }
    @{ n='Ventoy Install';   re='Installing Ventoy to';                           w=15 }
    @{ n='Repo Partition';   re='Creating secure offline repository|MiOS-Data';   w=19 }
    @{ n='MediCat Core';     re='core Medicat|Medicat archive|Pulling/Resuming';  w=52 }
    @{ n='Extract Payload';  re='Extracting minimal boot|Extracting only';        w=62 }
    @{ n='Fedora DVD';       re='Fedora-Server|FULL Fedora|Pulling the FULL';      w=70 }
    @{ n='Stage Repos';      re='Staging offline repository';                     w=76 }
    @{ n='Shadow Brain';     re='shadow-config brain';                            w=80 }
    @{ n='Live-Chat ISO';    re='live-chat ISO|Live-chat ISO';                    w=83 }
    @{ n='WIM Servicing';    re='offline servicing on MiOS_PE|DISM /';            w=88 }
    @{ n='MiOS-Xbox ISO';    re='MiOS-Xbox ISO|Compiling.*Xbox|build of MiOS-Xbox'; w=96 }
    @{ n='Complete';         re='INSTALLATION COMPLET|MIOS_CAT_EXIT=0';           w=100 }
)
$spin = '|/-\'.ToCharArray()

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

function Bar {
    param([int]$pct,[int[]]$col,[int]$width=44)
    $pct = [math]::Max(0,[math]::Min(100,$pct))
    $fill = [int]($pct * $width / 100)
    $s = (C $col ([string]([char]0x2588) * $fill)) + (C $pal.muted ([string]([char]0x2591) * ($width - $fill)))
    "$s " + (B ("{0,3}%" -f $pct))
}

function Draw {
    param([int]$Frame)
    $lines = Read-LogLines $LogPath
    $joined = ($lines -join "`n")

    # resolve reached phase + overall pct
    $reached = 0; $pct = 0
    for ($i=0; $i -lt $phases.Count; $i++) { if ($joined -match $phases[$i].re) { $reached = $i; $pct = $phases[$i].w } }
    # refine with an in-phase download percentage (curl prints e.g. 42.7%)
    $dlPct = $null
    $tailWin = ($lines | Select-Object -Last 12) -join "`n"
    $dm = [regex]::Matches($tailWin,'(\d{1,3}(?:\.\d+)?)%')
    if ($dm.Count -gt 0) {
        $dlPct = [int][double]$dm[$dm.Count-1].Groups[1].Value
        if ($reached -ge 0 -and $reached -lt ($phases.Count-1)) {
            $lo = $phases[$reached].w; $hi = $phases[$reached+1].w
            $pct = $lo + [int](($hi-$lo) * $dlPct / 100)
        }
    }

    $done = $false; $ok = $true
    if ((Test-Path $MarkerPath) -or ($joined -match 'MIOS_CAT_EXIT=')) {
        $done = $true
        $em = [regex]::Match($joined,'MIOS_CAT_EXIT=(\d+)')
        if ($em.Success -and $em.Groups[1].Value -ne '0') { $ok = $false }
        if ($joined -match '\[FAIL\]') { $ok = $false }
        $pct = if ($ok) { 100 } else { $pct }
    }

    $start = try { (Get-Item $LogPath).CreationTime } catch { Get-Date }
    $elapsed = (Get-Date) - $start
    $sp = $spin[$Frame % $spin.Length]

    $ac=$pal.accent; $fg=$pal.fg; $su=$pal.subtle; $mu=$pal.muted; $cu=$pal.cursor; $suc=$pal.success
    $rule = C $ac ([string]([char]0x2550) * 62)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    [void]$sb.AppendLine("  " + (C $ac (B '████╗ ████║██║██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'C A T')))
    [void]$sb.AppendLine("  " + (C $ac (B '██╔████╔██║██║██║   ██║███████╗')) + "   " + (C $mu 'zero-config USB forge'))
    [void]$sb.AppendLine("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    [void]$sb.AppendLine("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT'))
    [void]$sb.AppendLine("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    [void]$sb.AppendLine("  $rule")

    $cur = if ($done) { if($ok){'Completed'}else{'FAILED'} } else { $phases[$reached].n }
    [void]$sb.AppendLine("  " + (C $su 'Target ') + (C $fg (B 'D:  Lexar SS D EQ790 1TB (USB, disk 1)')))
    [void]$sb.AppendLine("  " + (C $su 'Elapsed') + ' ' + (C $fg ("{0:hh\:mm\:ss}" -f $elapsed)) + "    " + (C $su 'Stage') + ' ' + (C $cu (B ("{0,2}/{1}" -f ($reached+1),$phases.Count))) + "    " + (C $su 'Phase') + ' ' + (C $suc (B $cur)))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  " + (C $su 'OVERALL ') + (Bar -pct $pct -col $pal.cursor -width 44))
    if ($null -ne $dlPct -and -not $done -and $reached -ge 6 -and $reached -le 8) {
        [void]$sb.AppendLine("  " + (C $su 'DOWNLOAD') + ' ' + (Bar -pct $dlPct -col $pal.success -width 44))
    }
    [void]$sb.AppendLine("  $rule")

    # compact pipeline: ONE marker row + the current stage name. Keeps the whole dashboard short
    # enough to fit any console window, so the logo/banner never scroll off the top.
    $marks = ''
    for ($i=0; $i -lt $phases.Count; $i++) {
        if ($i -lt $reached -or ($done -and $ok)) { $marks += (C $suc ([string][char]0x2714)) }
        elseif ($i -eq $reached -and -not $done) { $marks += (C $cu ([string]$sp)) }
        elseif ($done -and -not $ok -and $i -eq $reached) { $marks += (C $pal.error ([string][char]0x2716)) }
        else { $marks += (C $mu ([string][char]0x00B7)) }
    }
    $dl = ''
    if ($null -ne $dlPct -and -not $done -and $reached -ge 6 -and $reached -le 8) { $dl = "  " + (C $mu "$dlPct%") }
    [void]$sb.AppendLine("  " + (C $su 'PIPELINE ') + $marks + '   ' + (C $cu (B $cur)) + $dl)
    [void]$sb.AppendLine("  $rule")

    # live log tail
    [void]$sb.AppendLine("  " + (C $su 'LIVE LOG'))
    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 7
    foreach ($l in $tail) {
        $t = $l.Trim(); if ($t.Length -gt 74) { $t = $t.Substring(0,74) }
        $lc = $pal.muted
        if ($t -match '\[OK\]|\[PASS\]') { $lc = $pal.success }
        elseif ($t -match '\[WARN\]') { $lc = $pal.warning }
        elseif ($t -match '\[FAIL\]|\[ERR') { $lc = $pal.error }
        [void]$sb.AppendLine("   " + (C $ac ([string][char]0x2502)) + ' ' + (C $lc $t))
    }
    [void]$sb.AppendLine("  $rule")

    if ($done) {
        if ($ok) { [void]$sb.AppendLine("  " + (C $suc (B '  ✔  MiOS-Cat USB ready — boot it, then pick “Chat with MiOS AI”.'))) }
        else     { [void]$sb.AppendLine("  " + (C $pal.error (B '  ✖  Flash failed — see LIVE LOG above / the full log file.'))) }
    } else {
        [void]$sb.AppendLine("  " + (C $mu "  $sp working…  (Ctrl+C to stop watching; the flash keeps running)"))
    }
    return @{ text = $sb.ToString(); done = $done }
}

# ---- Run ----------------------------------------------------------------------------------
try { [Console]::Title = 'MiOS-Cat · USB Forge Monitor' } catch {}
if ($Once) {
    (Draw -Frame 0).text | Write-Host
    return
}
# Size the window so the WHOLE dashboard (~44 rows) fits -- otherwise writing the lower rows
# scrolls the logo off the top. Buffer height == window height means no scrollback to drift into.
try {
    $wantW = [Math]::Min([Math]::Max([Console]::WindowWidth, 96), [Console]::LargestWindowWidth)
    $wantH = [Math]::Min(46, [Console]::LargestWindowHeight)
    [Console]::SetWindowSize([Math]::Min([Console]::WindowWidth,$wantW), [Math]::Min([Console]::WindowHeight,$wantH))
    [Console]::BufferWidth = $wantW
    [Console]::SetWindowSize($wantW, $wantH)
    [Console]::BufferHeight = $wantH
} catch {}
try { [Console]::CursorVisible = $false } catch {}
$frame = 0
while ($true) {
    $r = Draw -Frame $frame
    try { [Console]::Clear() } catch { Clear-Host }
    [Console]::Out.Write($r.text)
    if ($r.done) { break }
    $frame++
    Start-Sleep -Milliseconds $IntervalMs
}
try { [Console]::CursorVisible = $true } catch {}
