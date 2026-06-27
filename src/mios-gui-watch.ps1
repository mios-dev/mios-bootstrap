# AI-hint: A single-instance background PowerShell daemon that polls msrdc.exe processes to detect and resize tiny WSLg-spawned windows to a minimum usable size and center them on the screen to ensure visibility on high-resolution displays.
# AI-related: mios-gui-watch
# AI-functions: _ResolveTomlDim
# mios-gui-watch.ps1 -- background watcher that auto-centers tiny WSLg
# RDP-RAIL windows.
#
# WHY: WSLg hosts every GUI app spawned inside a WSL distro as a
# separate msrdc.exe-owned window on the Windows host. The window
# DOES render -- WSLg's pipe to the host is fully functional --
# but the X11/Wayland surface dimensions are whatever the app
# requested, which for many apps is a tiny default
# (xeyes: 129x113; old Qt apps: 100x100; sometimes WebKit: 200x200).
# On a 4K display these <1.5-inch windows spawn at arbitrary
# coordinates and look indistinguishable from "no window rendered"
# -- the operator sees a taskbar icon but the actual window is
# unfindable against a transparent / acrylic background.
#
# months of debugging assumed Mesa/Vulkan/dzn/
# Zink rendering failure when in fact xeyes (a pure-XLib zero-GPU
# app) had the same symptom: invisible 129x113 window at (1019,766).
# Force-centering it at 200x200 made it instantly visible. The
# rendering stack was never broken.
#
# This daemon polls Get-Process -Name msrdc every 500ms. For each
# msrdc.exe with a MainWindowHandle that is:
#   - Not already adopted by us (tracked via $Global:MiosAdopted hash)
#   - Smaller than the configured minimum (default 1024x768)
#   - Visible + non-minimized
# ...it calls SetWindowPos to resize to the minimum and center on
# the monitor under the cursor.
#
# Once "adopted" (resized once) the window is left alone for the
# rest of its life -- the operator can drag/resize freely without
# the daemon re-snapping it back.
#
# Reads dimensions from mios.toml [terminal.gui_min] (cols/rows in
# pixels) when present; otherwise vendor defaults (1024x768).

param(
    [int]$MinWidth   = 0,   # 0 = read from mios.toml, fall back to 1600
    [int]$MinHeight  = 0,   # 0 = read from mios.toml, fall back to 1000
    [int]$PollMs     = 500,
    [switch]$Verbose
)

$mutexName = "Global\MiOS-GuiWatch"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    if ($Verbose) { Write-Host "mios-gui-watch: already running, exiting." -ForegroundColor DarkYellow }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace MiosGui -Name Win -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
public struct RECT { public int Left, Top, Right, Bottom; }
"@
try { [void][MiosGui.Win]::SetProcessDPIAware() } catch {}

# Resolve dimensions from mios.toml [terminal.gui_min].* if not on the cmdline.
function _ResolveTomlDim {
    param([string]$Key, [int]$Default)
    # __MIOS_DRIVE__ is the install-root drive letter, substituted at stage
    # time by build-mios.ps1 from mios.toml [bootstrap.host_storage].drive_letter
    # (SSOT). The per-user override under $env:USERPROFILE is checked first and
    # is drive-independent; the install-root copies are the fallback.
    foreach ($t in @(
        (Join-Path $env:USERPROFILE '.config\mios\mios.toml'),
        '__MIOS_DRIVE__:\etc\mios\mios.toml',
        '__MIOS_DRIVE__:\usr\share\mios\mios.toml'
    )) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        try {
            $txt = [IO.File]::ReadAllText($t, (New-Object System.Text.UTF8Encoding($false)))
            $sec = [regex]::Match($txt, '(?ms)^\[terminal\.gui_min\]\s*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
            if (-not $sec.Success) { continue }
            $m = [regex]::Match($sec.Groups['body'].Value, ('(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*(\d+)'))
            if ($m.Success) { return [int]$m.Groups[1].Value }
        } catch {}
    }
    return $Default
}
if ($MinWidth  -le 0) { $MinWidth  = _ResolveTomlDim 'width'  1600 }
if ($MinHeight -le 0) { $MinHeight = _ResolveTomlDim 'height' 1000 }

if ($Verbose) {
    Write-Host "mios-gui-watch: min=${MinWidth}x${MinHeight} poll=${PollMs}ms" -ForegroundColor DarkCyan
}

# Adopted set -- HWND.ToInt64() of windows we've already resized.
$adopted = New-Object 'System.Collections.Generic.HashSet[int64]'

while ($true) {
    try {
        $procs = Get-Process -Name msrdc -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $h = $p.MainWindowHandle
            if ($h -eq [IntPtr]::Zero) { continue }
            $hLong = $h.ToInt64()
            if ($adopted.Contains($hLong)) { continue }
            if (-not [MiosGui.Win]::IsWindowVisible($h)) { continue }
            if ([MiosGui.Win]::IsIconic($h))            { continue }

            $rect = New-Object MiosGui.Win+RECT
            if (-not [MiosGui.Win]::GetWindowRect($h, [ref]$rect)) { continue }
            $w = $rect.Right - $rect.Left
            $hgt = $rect.Bottom - $rect.Top
            # Skip windows that are ALREADY larger than our minimum
            # (operator-launched at sensible sizes, e.g. terminals or
            # native MiOS hub windows hosted by msrdc).
            if ($w -ge $MinWidth -and $hgt -ge $MinHeight) {
                [void]$adopted.Add($hLong)
                continue
            }
            # Resize + center on whichever monitor the cursor is on.
            $cur  = [System.Windows.Forms.Cursor]::Position
            $work = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
            $cx = [int]($work.X + ($work.Width  - $MinWidth)  / 2)
            $cy = [int]($work.Y + ($work.Height - $MinHeight) / 2)
            # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) + SWP_SHOWWINDOW (0x40) = 0x54
            [void][MiosGui.Win]::SetWindowPos($h, [IntPtr]::Zero, $cx, $cy, $MinWidth, $MinHeight, 0x54)
            [void]$adopted.Add($hLong)
            if ($Verbose) {
                Write-Host ("mios-gui-watch: adopted '{0}' ({1}x{2} -> {3}x{4} at {5},{6})" -f `
                    $p.MainWindowTitle, $w, $hgt, $MinWidth, $MinHeight, $cx, $cy) -ForegroundColor DarkGray
            }
        }
        # Garbage-collect adopted entries whose process has exited so the
        # set doesn't grow unbounded across long sessions.
        $live = New-Object 'System.Collections.Generic.HashSet[int64]'
        foreach ($p in $procs) { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$live.Add($p.MainWindowHandle.ToInt64()) } }
        $stale = @($adopted | Where-Object { -not $live.Contains($_) })
        foreach ($s in $stale) { [void]$adopted.Remove($s) }
    } catch {
        if ($Verbose) {
            Write-Host "mios-gui-watch: poll error: $($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }
    Start-Sleep -Milliseconds $PollMs
}
