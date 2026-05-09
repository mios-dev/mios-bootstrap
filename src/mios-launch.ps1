# mios-launch.ps1 -- native-app launcher for MiOS / MiOS-DEV WT profiles.
# Spawns wt.exe with the requested profile in focus mode (borderless,
# no titlebar, no tab row), screen-centered on whichever monitor the
# cursor is currently on, and re-centers continuously via Win32
# SetWindowPos to defeat WT's --pos-ignored-in-focus regression.
# Runs invisibly (parent shortcut uses -WindowStyle Hidden).
#
# Parameters:
#   -Profile <name>  WT profile to launch.  'MiOS-DEV' (default; the
#                    Linux dev VM via wsl.exe -d podman-MiOS-DEV) or
#                    'MiOS-WIN' (Windows pwsh + MiOS profile body).
#   -Verb <name>     Optional. Runs `mios <verb>` inside the launched
#                    Windows-side window after the profile body loads.
#                    Ignored for MiOS-DEV (the dev VM is a bash login).
#
# Operator 2026-05-09: "UNIFY all MiOS app windows/themed windows
# terminal windows to use the same profile and launch params GLOBALLY!!!"
param(
    [string]$Profile = 'MiOS-DEV',
    [string]$Verb    = ''
)
$ErrorActionPreference = 'SilentlyContinue'

try {
    Add-Type -Namespace 'MiOSLaunch.Native' -Name 'Dpi' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
"@
    # Per-monitor v2 (-4) so Screen.WorkingArea + SetWindowPos coords
    # match across monitors of different DPI. Falls back to legacy
    # SetProcessDPIAware (per-monitor v1) on older Windows.
    $_dpiOk = $false
    try { $_dpiOk = [MiOSLaunch.Native.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } catch {}
    if (-not $_dpiOk) { try { [MiOSLaunch.Native.Dpi]::SetProcessDPIAware() | Out-Null } catch {} }
} catch {}

Add-Type -AssemblyName System.Windows.Forms

# Dims in CELLS only (mios.toml [terminal] -- 80x20 portal feel).
# DON'T compute pixel dims from hardcoded cell metrics: at 100% DPI
# Geist Mono 12pt is ~10x20 px but at 200% DPI it's ~20x40 px. The
# previous `$winW = ($Cols * 10) + 20` hardcode produced a HALF-SIZE
# pixel rect on 200% DPI hosts. WT auto-pixel-sizes the window
# correctly for the active DPI when spawned with --size in cells; we
# just need to wait for the window to surface and then read its
# ACTUAL pixel dims via GetWindowRect for centering.
$Cols   = 80
$Rows   = 20

$cur    = [System.Windows.Forms.Cursor]::Position
$work   = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
$_cellW = 10
$_cellH = 20
$x = [int]($work.X + [math]::Max(0, $work.Width  - ($Cols * $_cellW + 20)) / 2)
$y = [int]($work.Y + [math]::Max(0, $work.Height - ($Rows * $_cellH + 12)) / 2)
if ($x -lt $work.X) { $x = $work.X }
if ($y -lt $work.Y) { $y = $work.Y }

$wtStable = $null
try {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
    if ($pkg -and $pkg.InstallLocation) {
        $cand = Join-Path $pkg.InstallLocation 'wt.exe'
        if (Test-Path -LiteralPath $cand) { $wtStable = $cand }
    }
} catch {}
$wtExe = if ($wtStable) { $wtStable } else { (Get-Command wt.exe -ErrorAction SilentlyContinue).Source }
if (-not $wtExe) {
    [System.Windows.Forms.MessageBox]::Show("Windows Terminal (wt.exe) not installed. Re-run irm | iex Get-MiOS.ps1.", "MiOS", 'OK', 'Error') | Out-Null
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Verb) -or $Profile -eq 'MiOS-DEV') {
    # Bare profile launch (or dev VM -- bash login takes no verb).
    $wtArgs = @('-w','MiOS','--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p',$Profile)
} else {
    # Verb dispatch on a Windows-side profile (MiOS-WIN, or legacy 'MiOS').
    $_pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $_pwsh) { $_pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $_profileBody = 'M:\MiOS\powershell\profile.ps1'
    $_inner = "if (Test-Path '$_profileBody') { . '$_profileBody' }; mios $Verb"
    $wtArgs = @('-w','MiOS','--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p',$Profile,'--',$_pwsh,'-NoLogo','-NoExit','-NoProfile','-Command',$_inner)
}
Start-Process -FilePath $wtExe -ArgumentList $wtArgs

try {
    Add-Type -Namespace 'MiOSLaunch.Native' -Name 'Win' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
public struct RECT { public int Left, Top, Right, Bottom; }
"@
} catch {}

$deadline = (Get-Date).AddMilliseconds(4000)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
    if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
        if ([MiOSLaunch.Native.Win]::IsWindowVisible($proc.MainWindowHandle)) {
            $hwnd = $proc.MainWindowHandle
            break
        }
    }
    Start-Sleep -Milliseconds 150
}

if ($hwnd -ne [IntPtr]::Zero) {
    # Persistent re-center loop. WT in focus mode ignores --pos AND
    # does its own size renegotiation 1-2x post-spawn (acrylic backdrop
    # allocation, font cache, focus-mode resize), so a single-shot
    # SetWindowPos loses every race. Re-center every 250ms for 30s
    # (120 ticks) -- after that the operator can drag manually.
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $rect = New-Object MiOSLaunch.Native.Win+RECT
        if ([MiOSLaunch.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) {
            $rw = $rect.Right - $rect.Left
            $rh = $rect.Bottom - $rect.Top
            if ($rw -gt 0 -and $rh -gt 0) {
                $_curNow  = [System.Windows.Forms.Cursor]::Position
                $_workNow = [System.Windows.Forms.Screen]::FromPoint($_curNow).WorkingArea
                $cx = [int]($_workNow.X + ($_workNow.Width  - $rw) / 2)
                $cy = [int]($_workNow.Y + ($_workNow.Height - $rh) / 2)
                # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $cx, $cy, $rw, $rh, 0x14)
            }
        }
        Start-Sleep -Milliseconds 250
    }
}
