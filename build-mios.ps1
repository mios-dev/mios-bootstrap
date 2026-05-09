#Requires -Version 5.1
# 'MiOS' Unified Installer & Builder -- Windows 11 / PowerShell
#
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# Flags:
#   -BuildOnly    Pull latest + build only (skip first-time setup)
#   -Unattended   Accept all defaults, no prompts
#
# ── ARCHITECTURE: Day-0 self-replication contract ────────────────────────────
# Per the MiOS self-replication architecture (project memory:
# project_mios_self_replication_vision.md), the Windows side of the bootstrap
# is STRICTLY an entry point with a narrow scope:
#
#   1. Acknowledgements (AGREEMENTS.md / LICENSES.md)
#   2. MiOS-DEV podman-machine setup (Phases 0-5 + 8 of this script)
#   3. SSH handoff into MiOS-DEV
#
# After step 3, EVERYTHING else runs INSIDE MiOS-DEV: local fetch + overlay,
# identity prompts, and the FULL build pipeline producing every output
# format MiOS targets (OCI bootc image, WSL2/g .tar/.vhdx, Hyper-V .vhdx,
# QEMU qcow2, Live-CD/USB ISO, USB installer, RAW dd image). The build
# dashboard renders on the MiOS-DEV tty inside the SSH-hosted Windows
# Terminal -- it is NOT streamed back across the WSL/Windows boundary.
#
# Show-PostBootstrapMenu's "Continue to build" choice IS the SSH handoff:
# it spawns a new Windows Terminal tab running `wsl.exe -d MiOS-DEV` which
# in turn invokes /usr/libexec/mios/mios-build-driver inside the dev distro.
#
# Migration status (2026-05-06): Phase 6+ legacy code (identity, OCI build,
# disk image generation, Hyper-V VM deploy) still lives in this script as
# the -FullBuild / -BuildOnly path. The new SSH-handoff flow runs alongside
# it via the menu. Subsequent migration chunks move identity prompts and
# the full output-format matrix into the Linux-side driver, then trim this
# Windows-side tail entirely.

param(
    # -BootstrapOnly / -BuildOnly / -FullBuild: LEGACY FLAGS, KEPT FOR
    # CALL-SITE COMPATIBILITY ONLY. Per the self-replication contract
    # (project memory: project_mios_self_replication_vision.md), the
    # Windows side runs ONLY: ack -> MiOS-DEV podman-machine setup ->
    # SSH handoff. Phase 6+ (Identity / OCI build / WSL2 export /
    # Hyper-V deploy) MUST run inside MiOS-DEV via /usr/libexec/mios/
    # mios-build-driver, NOT on Windows.
    #
    # These flags are now no-ops -- the script always behaves as if
    # -BootstrapOnly was the only mode. -FullBuild and -BuildOnly emit
    # a deprecation note and are otherwise ignored. Operators who want
    # the old in-Windows pipeline can revert to a pre-352aee3 build of
    # this script; nothing else honors them any more.
    [switch]$BootstrapOnly,
    [switch]$BuildOnly,
    [switch]$FullBuild,

    # -Unattended: take all defaults; no interactive prompts.
    [switch]$Unattended
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ── mios.toml layered-overlay reader (mirrors Get-MiOS.ps1's helper) ─────────
# mios.toml is THE global dotfile (per feedback_mios_toml_html_global_dotfile).
# Every tunable -- terminal dims, retry delays, dev VM image tag, distro
# names -- sources from the layered overlay. We inline the helper instead
# of dot-sourcing because build-mios.ps1 must work both in-tree (clone) and
# under irm|iex relaunch where the path to Get-MiOS.ps1 isn't guaranteed.
$script:_MiosTomlCache = @{}
function Resolve-MiosTomlText {
    if ($script:_MiosTomlCache['_text']) { return $script:_MiosTomlCache['_text'] }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE '.config\mios\mios.toml'),
        'M:\etc\mios\mios.toml',
        'M:\usr\share\mios\mios.toml'
        # C:\MiOS deliberately excluded -- dev working tree, not a consumer install path
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                # Read as UTF-8. PS 5.1's Get-Content default is the
                # system ANSI codepage (cp1252 on en-US) which decoded
                # the UTF-8 PUA glyphs in [theme.prompt] as 3-char
                # mojibake (the U+E0B4 cap's bytes EE 82 B4 became
                # 'î‚´'). The omp.json glyph substitution then took
                # 'î' as the cap and wrote U+00EE into the deployed
                # theme, producing operator-reported "powerline seconds
                # are shifted to the next row" + 'î' instead of ''.
                $script:_MiosTomlCache['_text']   = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
                $script:_MiosTomlCache['_source'] = $p
                return $script:_MiosTomlCache['_text']
            } catch {
                try {
                    $script:_MiosTomlCache['_text']   = Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop
                    $script:_MiosTomlCache['_source'] = $p
                    return $script:_MiosTomlCache['_text']
                } catch {}
            }
        }
    }
    try {
        $cb  = [int][double]::Parse((Get-Date -UFormat %s))
        $url = "https://raw.githubusercontent.com/mios-dev/MiOS/main/usr/share/mios/mios.toml?cb=$cb"
        $script:_MiosTomlCache['_text'] = Invoke-RestMethod -Uri $url `
            -Headers @{ 'Cache-Control'='no-cache, no-store, max-age=0'; 'Pragma'='no-cache' } `
            -ErrorAction Stop
        return $script:_MiosTomlCache['_text']
    } catch {
        $script:_MiosTomlCache['_text'] = ''
        return ''
    }
}
function Get-MiosTomlValue {
    param([Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Default)
    $txt = Resolve-MiosTomlText
    if (-not $txt) { return $Default }
    $rxSec = '(?ms)^\[' + [regex]::Escape($Section) + '\][ \t]*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)'
    $mSec  = [regex]::Match($txt, $rxSec)
    if (-not $mSec.Success) { return $Default }
    $rxKey = '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*(?<val>.+?)[ \t]*(?:#.*)?$'
    $mKey  = [regex]::Match($mSec.Groups['body'].Value, $rxKey)
    if (-not $mKey.Success) { return $Default }
    $raw = $mKey.Groups['val'].Value.Trim()
    if ($Default -is [int]) {
        $n = 0; if ([int]::TryParse(($raw -replace '_',''), [ref]$n)) { return $n }
        return $Default
    }
    if ($Default -is [bool]) {
        if ($raw -match '^(?i)true$')  { return $true }
        if ($raw -match '^(?i)false$') { return $false }
        return $Default
    }
    if ($Default -is [array]) {
        if ($raw -match '^\[(.*)\]$') {
            $items = @($Matches[1] -split ',' | ForEach-Object {
                $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                if ($s) { $s }
            })
            if ($Default.Length -gt 0 -and $Default[0] -is [int]) {
                $coerced = @()
                foreach ($it in $items) {
                    $n = 0
                    if ([int]::TryParse($it, [ref]$n)) { $coerced += $n } else { return $Default }
                }
                # Return without unary-comma -- callers do `@(Get-Mios...)`
                # which collects pipeline-unrolled ints into an array.
                # With `,$coerced` the result was @(@(0,5,15,30)) -- a
                # 1-element array, so $delays[0] was the array itself,
                # crashing Start-Sleep -Seconds with "cannot convert
                # System.Object[] to System.Double".
                return $coerced
            }
            return $items
        }
        return $Default
    }
    # String -- strip SURROUNDING TOML quotes only (no Trim multi-set,
    # which previously ate leading ' from values like "'MiOS' v0.2.4"
    # because Trim('"',"'") matches both chars on both ends). Unescape
    # backslash sequences for double-quoted strings per TOML 1.0.0.
    if ($raw.Length -ge 2) {
        $first = $raw[0]; $last = $raw[$raw.Length - 1]
        if ($first -eq '"' -and $last -eq '"') {
            # PS 5.1-safe sentinel ([char]0x01); `` `u{0001} `` is PS 7-only.
            $_bs = [string][char]0x01 + 'BS' + [string][char]0x01
            $inner = $raw.Substring(1, $raw.Length - 2)
            $inner = $inner -replace '\\\\', $_bs
            $inner = $inner -replace '\\"', '"'
            $inner = $inner -replace '\\n', "`n"
            $inner = $inner -replace '\\t', "`t"
            $inner = $inner -replace '\\r', "`r"
            $inner = $inner -replace [regex]::Escape($_bs), '\'
            return $inner
        }
        if ($first -eq "'" -and $last -eq "'") {
            return $raw.Substring(1, $raw.Length - 2)
        }
    }
    return $raw
}

# Resolve canonical terminal dims ONCE at script-load so every later
# resize / wt --size / stty call uses the same values from mios.toml.
#
# IMPORTANT: build-mios.ps1 runs DURING the bootstrap install. Use
# [terminal.install] dims (vendor default 80x40 -- enough rows for
# the dashboard + install logs to fit visibly without auto-scroll
# eating the banner). [terminal] dims (80x20) are reserved for the
# POST-INSTALL MiOS app spawn -- using them here would shrink the
# install conhost mid-flight, which the operator reports as "windows
# still shrink to 80x20 and are also off-center". The post-install
# wt --size spawn uses script:MiosAppCols / script:MiosAppRows.
$script:MiosCols    = Get-MiosTomlValue -Section 'terminal.install' -Key 'cols'            -Default 80
$script:MiosRows    = Get-MiosTomlValue -Section 'terminal.install' -Key 'rows'            -Default 40
$script:MiosScroll  = Get-MiosTomlValue -Section 'terminal'         -Key 'scrollback_rows' -Default 9000
# MiOS-APP dims (80x20 portal feel) -- used by the post-install wt
# launch only, NEVER by the install conhost.
$script:MiosAppCols = Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80
$script:MiosAppRows = Get-MiosTomlValue -Section 'terminal' -Key 'rows' -Default 20

# ── Console resize: mios.toml [terminal] dims BEFORE any sizing-dependent state ─
# $script:DW (~line 543) is computed from [Console]::WindowWidth at script-
# load time and never re-read. If the parent window opened wider, the
# dashboard frame draws at the wrong width and log lines bleed past it.
# Resize NOW, before $DW is computed. Dims source from mios.toml [terminal]
# (vendor default 80x20 portal feel).
# Per feedback_mios_terminal_dimensions.md.
#
# The order matters: SetWindowSize requires buffer >= window. If the
# current buffer is smaller than the target cols, SetWindowSize fails.
# If the current window is larger than the target cols, SetBufferSize
# fails (buffer can't be smaller than current window). So we branch.
$_resizeBefore = try { "$([Console]::WindowWidth)x$([Console]::WindowHeight) buf=$([Console]::BufferWidth)x$([Console]::BufferHeight)" } catch { 'unknown' }
$_resizeAfter  = 'unchanged'
$_resizeErr    = $null
try {
    $_curW = [Console]::WindowWidth
    if ($_curW -gt $script:MiosCols) {
        # Shrink window first (buffer can't be < window), then buffer.
        [Console]::SetWindowSize($script:MiosCols, $script:MiosRows)
        [Console]::SetBufferSize($script:MiosCols, $script:MiosScroll)
    } else {
        # Enlarge buffer first (window can't be > buffer), then window.
        [Console]::SetBufferSize($script:MiosCols, $script:MiosScroll)
        [Console]::SetWindowSize($script:MiosCols, $script:MiosRows)
    }
    $_resizeAfter = "$([Console]::WindowWidth)x$([Console]::WindowHeight) buf=$([Console]::BufferWidth)x$([Console]::BufferHeight)"
} catch {
    $_resizeErr = $_.Exception.Message
}
# Log to a deferred-flush variable; written to the unified log once the log
# file path is known (Write-Log isn't defined this early in load).
$script:_PendingResizeLog = "console resize: before=$_resizeBefore after=$_resizeAfter err=$_resizeErr"

# Re-center the bootstrap window on the operator's active monitor.
# Operator-reported regression: "all windows aren't recentering still!"
#
# The earlier MoveWindow approach via [Console]::GetConsoleWindow only
# worked for the legacy conhost. On Windows 11 where WT is the default
# terminal app, GetConsoleWindow returns the OpenConsole pseudo-host
# HWND, NOT the WT WindowsTerminal.exe HWND that owns the visible
# window -- so MoveWindow on the pseudo-host moved nothing the operator
# could see. The fix below tries TWO strategies:
#
#   1. SetProcessDpiAwarenessContext to per-monitor v2 so the coordinate
#      space matches the screen's DPI (was failing on high-DPI multi-
#      monitor setups: Screen.WorkingArea returned logical px while
#      MoveWindow expected physical px under the legacy
#      DPI_AWARENESS_CONTEXT_UNAWARE).
#   2. Walk up to the topmost ancestor of GetConsoleWindow(): conhost ->
#      pseudo-host -> WT main window. SetWindowPos on the topmost
#      ancestor moves the WT window itself when running inside WT, and
#      moves the conhost when running standalone. SWP_NOZORDER keeps z-
#      order, SWP_NOACTIVATE prevents focus theft.
try {
    if (-not ('MiosBuildLoad.W' -as [type])) {
        Add-Type -Namespace MiosBuildLoad -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle rect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4 (handle-pseudo)
    try { [void][MiosBuildLoad.W]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } catch {}
    Start-Sleep -Milliseconds 100   # let conhost settle the new size
    $_consoleHwnd = [MiosBuildLoad.W]::GetConsoleWindow()
    # GA_ROOT = 2 -- walk to the topmost ancestor (WT window when
    # hosted, conhost otherwise).
    $_lh = if ($_consoleHwnd -ne [IntPtr]::Zero) {
        $_root = [MiosBuildLoad.W]::GetAncestor($_consoleHwnd, 2)
        if ($_root -ne [IntPtr]::Zero) { $_root } else { $_consoleHwnd }
    } else { [IntPtr]::Zero }
    if ($_lh -ne [IntPtr]::Zero) {
        $_lr = New-Object System.Drawing.Rectangle
        [void][MiosBuildLoad.W]::GetWindowRect($_lh, [ref]$_lr)
        $_lw  = $_lr.Width  - $_lr.X
        $_lh2 = $_lr.Height - $_lr.Y
        # Anchor to the window's CURRENT monitor (stable across mouse
        # drift). FromPoint uses physical px on per-monitor v2.
        $_lcenter = New-Object System.Drawing.Point ($_lr.X + [int]($_lw / 2)), ($_lr.Y + [int]($_lh2 / 2))
        $_ls   = [System.Windows.Forms.Screen]::FromPoint($_lcenter).WorkingArea
        $_lx = $_ls.X + [int](([math]::Max(0, $_ls.Width  - $_lw )) / 2)
        $_ly = $_ls.Y + [int](([math]::Max(0, $_ls.Height - $_lh2)) / 2)
        # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14
        [void][MiosBuildLoad.W]::SetWindowPos($_lh, [IntPtr]::Zero, $_lx, $_ly, $_lw, $_lh2, 0x14)
        $script:_PendingResizeLog += " centered=$_lx,$_ly@${_lw}x${_lh2} hwnd=$([int64]$_lh)"
    } else {
        $script:_PendingResizeLog += " center-skip=no-hwnd"
    }
} catch {
    $script:_PendingResizeLog += " center-err=$($_.Exception.Message)"
}

# ── Self-replication enforcement: Windows ALWAYS halts at Phase 5 ────────────
# Per the self-replication architecture, the Windows side has STRICT scope:
# ack + MiOS-DEV podman-machine setup + SSH handoff. The legacy -FullBuild /
# -BuildOnly flags that bypassed this and ran identity / OCI / disk-image
# phases ON WINDOWS are deprecated AND IGNORED here. We force $BootstrapOnly
# to $true unconditionally so every code path that gates "stop after
# Windows phases" via `if ($BootstrapOnly)` keeps the bootstrap halted.
# Operators who need the old behavior must revert to a pre-352aee3 build.
if ($BuildOnly -or $FullBuild) {
    Write-Host ""
    Write-Host "  [warn] -BuildOnly / -FullBuild are deprecated -- the build pipeline now" -ForegroundColor Yellow
    Write-Host "         runs INSIDE MiOS-DEV. Use the post-bootstrap menu (option 1) to" -ForegroundColor Yellow
    Write-Host "         hand off to the dev distro after the Windows-side setup completes." -ForegroundColor Yellow
    Write-Host ""
}
# Override any passed-in / default value: the Windows side is always
# bootstrap-only from this commit forward. Note this is set at script scope
# so the conditional PhaseNames block below picks up the forced value.
$BootstrapOnly = $true
$script:BootstrapOnly = $true

# Acknowledgment banner. Inlined (script is irm-piped). Respects
# $env:MIOS_AGREEMENT_BANNER=quiet for unattended runs.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking build-mios.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in usr/share/doc/mios/reference/credits.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

# ── Install scope detection ───────────────────────────────────────────────────
# 'MiOS' installs as a native Windows app. Two scopes:
#
#   AllUsers  -- machine-wide install at C:\Program Files\MiOS\
#                Add/Remove Programs in HKLM. Distros + images in
#                C:\ProgramData\MiOS. Per-user logs/config still use
#                %LOCALAPPDATA%\MiOS / %APPDATA%\MiOS so each Windows
#                account on the box gets its own state.
#
#   CurrentUser -- per-user install at %LOCALAPPDATA%\Programs\MiOS\
#                  Add/Remove Programs in HKCU. Used as a fallback when
#                  the operator declines UAC elevation, or when the
#                  installer is invoked under a standard (non-admin)
#                  account.
#
# Detection: a process is "admin" if it holds the Administrators
# built-in role. The 'irm | iex' one-liner from Get-MiOS.ps1 will refuse
# to elevate itself (UAC cannot prompt mid-pipeline); operators are
# expected to run from an elevated PowerShell when AllUsers is desired.
$script:IsAdmin = $false
try {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $script:IsAdmin = $false }

$MiosScope = if ($script:IsAdmin) { "AllUsers" } else { "CurrentUser" }

# ── Paths & constants -- ALL sourced from mios.toml SSOT ─────────────────────
# Per operator: "toml is the SSOT for code too!!! no hardcoding ANYWHERE!!!".
# Every value below resolves through Get-MiosTomlValue with a vendor-default
# fallback. The configurator HTML (mios.html) exposes each key as an editable
# field; an operator edit there flows mios.toml -> these values -> the entire
# install pipeline.
$_v             = Get-MiosTomlValue -Section 'meta'      -Key 'mios_version'    -Default '0.2.4'
$MiosVersion    = if ($_v -match '^v') { $_v } else { "v$_v" }
$MiosRepoUrl    = Get-MiosTomlValue -Section 'bootstrap' -Key 'mios_repo'       -Default 'https://github.com/mios-dev/MiOS.git'
$MiosBootstrapUrl = Get-MiosTomlValue -Section 'bootstrap' -Key 'bootstrap_repo' -Default 'https://github.com/mios-dev/mios-bootstrap.git'
# Podman machine name. Backed by WSL distro `podman-MiOS-DEV` once `podman
# machine init` runs. Locked per memory feedback_mios_distro_name_locked.md
# (renaming breaks podman's distro discovery), so the TOML key carries
# vendor default 'MiOS-DEV' and operators rarely override.
$DevDistro      = Get-MiosTomlValue -Section 'bootstrap' -Key 'dev_distro'     -Default 'MiOS-DEV'
$BuilderDistro    = $DevDistro
$LegacyDevName    = "MiOS-BUILDER"
$MiosWslDistro    = "MiOS"
$LegacyDistro     = "podman-machine-default"
# MiOS-DEV's base machine-OS image. Pinned to 6.0 per operator's
# explicit instruction:
#
#   "use 6.0 machine podman-os images!!!!!"
#
# 6.0 is the newest stable non-floating tag at quay.io/podman/machine-os
# (probed 2026-05-06: tags = 5.0, 5.1, ..., 5.8, 6.0, next).
#
# IMPORTANT compatibility note: pinning a major-version-newer machine-os
# than the installed podman client requires the client to know how to
# consume it. On podman 5.8.2 (the operator's current client), `--image
# docker://quay.io/podman/machine-os:6.0` may fail at the Win32 pull-
# extraction step with:
#     Error: failed to pull ... : The system cannot find the path specified.
# That's a podman-5.8-on-WSL bug, NOT a wrong-URL bug -- 6.0 itself is
# correctly published at quay.io. The fix on the operator's side is:
#     winget upgrade Podman.Podman
# which gets a 6.x client that handles the 6.0 machine-os pull cleanly.
#
# The `docker://` prefix is required for OCI-registry refs on the
# `--image` flag; bare refs hit GetFileAttributesEx-as-file-path on
# Windows. The MIOS_MACHINE_IMAGE override hatch stays open if a
# specific operator wants to fall back to 5.8 (their bundled default)
# until they upgrade -- set MIOS_MACHINE_IMAGE='' (empty string) to
# omit --image entirely.
# Default: NO --image (use podman's bundled local file, which always
# works because podman ships its own machine-os tarball alongside the
# client). Empirical lesson from logs across this stretch:
#
#   * podman 5.8.2 on Windows / WSL provider FAILS to pull ANY OCI
#     ref via `podman machine init --image docker://...` -- both 6.0
#     AND the bundled-tag fallback to :5.8 hit the same Win32 error:
#         Error: failed to pull quay.io/podman/machine-os@sha256:<digest>:
#                The system cannot find the path specified.
#     This is a podman-on-Windows pull-extraction bug, NOT a wrong-URL
#     bug -- the digests resolve correctly; the local extraction
#     stage is broken on the WSL provider for this client version.
#
#   * Without --image, podman uses its bundled local tarball and
#     `wsl --import`s it directly -- no pull, no extraction-from-
#     registry path, just works. Operator's earlier successful runs
#     all took this path.
#
# To pin a specific machine-os tag, the operator must:
#   (a) upgrade their podman client to a version that fixes the
#       WSL pull bug (`winget upgrade Podman.Podman`, retry)
#   (b) THEN set $env:MIOS_MACHINE_IMAGE=docker://quay.io/podman/
#       machine-os:6.0 (or whatever tag) before invoking the
#       bootstrap.
#
# Until the operator's client is upgraded, pinning is wedged shut by
# podman, not by us. This default makes the bootstrap actually
# progress instead of dying at Phase 3 with "path not found."
$MachineImage = $env:MIOS_MACHINE_IMAGE
if ($MachineImage -and $MachineImage -notmatch '^(docker|https?|file)://' -and $MachineImage -match '^[a-z0-9.-]+\.[a-z]{2,}/') {
    # Operator passed a bare OCI ref via env -- auto-prefix `docker://`.
    $MachineImage = "docker://$MachineImage"
}

if ($script:IsAdmin) {
    # AllUsers (machine-wide native Windows app layout). Top-level
    # C:\MiOS as requested -- treats MiOS as a first-class Windows
    # application rather than a hidden Program Files entry.
    $MiosInstallDir   = Join-Path ${env:SystemDrive} "MiOS"             # C:\MiOS
    $MiosProgramData  = Join-Path ${env:ProgramData}  "MiOS"            # C:\ProgramData\MiOS
    $MiosRepoDir      = Join-Path $MiosInstallDir   "repo"              # boot-time default; Update-MiosInstallPaths swaps to M:\ on data disk
    $MiosBootstrapShadow = Join-Path $MiosRepoDir 'mios-bootstrap'      # boot-time default; data-disk variant goes to M:\MiOS\bootstrap-shadow
    $MiosBinDir       = Join-Path $MiosInstallDir   "bin"               # entry-point scripts + oh-my-posh
    $MiosShareDir     = Join-Path $MiosInstallDir   "share"             # mios-bootstrap etc/usr trees
    $MiosIconsDir     = Join-Path $MiosInstallDir   "icons"             # per-verb .ico files
    $MiosThemesDir    = Join-Path $MiosInstallDir   "themes"            # mios.omp.json + future themes
    $MiosFontsDir     = Join-Path $MiosInstallDir   "fonts"             # local copy of installed fonts
    $MiosDistroDir    = Join-Path $MiosProgramData  "distros"           # multi-GB WSL2 artifacts
    $MiosImagesDir    = Join-Path $MiosProgramData  "images"            # qcow2 / vhdx / iso outputs
    $MiosMachineCfg   = Join-Path $MiosProgramData  "config"            # global non-secret install.env
    $StartMenuDir     = Join-Path ${env:ProgramData} "Microsoft\Windows\Start Menu\Programs\MiOS"
    $UninstallRegKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
} else {
    # CurrentUser fallback (no write access to C:\). Mirrors the admin
    # layout under %LOCALAPPDATA%\MiOS so paths inside the install
    # root stay relative-stable (bin/, icons/, themes/, ...).
    $MiosInstallDir   = Join-Path ${env:LOCALAPPDATA} "MiOS"
    $MiosProgramData  = Join-Path $MiosInstallDir    "machine-state"
    $MiosRepoDir      = Join-Path $MiosInstallDir    "repo"
    $MiosBootstrapShadow = Join-Path $MiosRepoDir    'mios-bootstrap'
    $MiosBinDir       = Join-Path $MiosInstallDir    "bin"
    $MiosShareDir     = Join-Path $MiosInstallDir    "share"
    $MiosIconsDir     = Join-Path $MiosInstallDir    "icons"
    $MiosThemesDir    = Join-Path $MiosInstallDir    "themes"
    $MiosFontsDir     = Join-Path $MiosInstallDir    "fonts"
    $MiosDistroDir    = Join-Path $MiosInstallDir    "distros"
    $MiosImagesDir    = Join-Path $MiosInstallDir    "images"
    $MiosMachineCfg   = Join-Path $MiosInstallDir    "config"
    $StartMenuDir     = Join-Path ${env:APPDATA}     "Microsoft\Windows\Start Menu\Programs\MiOS"
    $UninstallRegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
}

# Mirror the path locals to $script: scope so functions defined in
# this file (which use $script:MiosInstallDir / $script:MiosRepoDir
# etc. for the AFTER-data-disk-bootstrap variant) ALWAYS find a
# valid value -- even when Update-MiosInstallPaths never runs (no
# admin, no M:\ provisioning). Without this mirroring,
# New-BuilderDistro's `Join-Path $script:MiosInstallDir 'machine-os'`
# threw "Cannot bind argument to parameter 'Path' because argument
# is null" the moment Phase 3 fired in CurrentUser scope.
$script:MiosInstallDir     = $MiosInstallDir
$script:MiosProgramData    = $MiosProgramData
$script:MiosRepoDir        = $MiosRepoDir
$script:MiosBootstrapShadow = $MiosBootstrapShadow
$script:MiosBinDir         = $MiosBinDir
$script:MiosShareDir       = $MiosShareDir
$script:MiosIconsDir       = $MiosIconsDir
$script:MiosThemesDir      = $MiosThemesDir
$script:MiosFontsDir       = $MiosFontsDir
$script:MiosDistroDir      = $MiosDistroDir
$script:MiosImagesDir      = $MiosImagesDir
$script:MiosMachineCfg     = $MiosMachineCfg

# Early M:\ detection: if the MIOS-DEV partition is already mounted
# (from a previous admin run), redirect EVERY install path onto it
# UNCONDITIONALLY -- regardless of whether THIS run is admin. The
# operator's expectation per memory feedback_mios_repo_context_invariant
# is "EVERY MiOS artifact lives on M:\ when M:\ is provisioned".
# Without this early redirect, a non-admin re-run of build-mios.ps1
# falls back to C:\Users\Administrator\AppData\Local\MiOS even when
# M:\ is right there waiting -- which is exactly the operator's
# "should ALL be installing to the created M:\ partition!!!" symptom.
$_miosDataLetter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER } else { 'M' }
try {
    $_miosVol = Get-Volume -DriveLetter $_miosDataLetter -ErrorAction SilentlyContinue
    if ($_miosVol -and $_miosVol.FileSystemLabel -eq 'MIOS-DEV') {
        $_miosNewRoot = Join-Path "${_miosDataLetter}:\" 'MiOS'
        if (-not (Test-Path $_miosNewRoot)) { New-Item -ItemType Directory -Path $_miosNewRoot -Force | Out-Null }
        # Update-MiosInstallPaths is defined below; do an inline
        # equivalent here so the redirect lands BEFORE Phase 0 runs.
        $script:MiosInstallDir      = $_miosNewRoot
        $script:MiosBinDir          = Join-Path $_miosNewRoot 'bin'
        $script:MiosShareDir        = Join-Path $_miosNewRoot 'share'
        $script:MiosIconsDir        = Join-Path $_miosNewRoot 'icons'
        $script:MiosThemesDir       = Join-Path $_miosNewRoot 'themes'
        $script:MiosFontsDir        = Join-Path $_miosNewRoot 'fonts'
        $script:MiosProgramData     = Join-Path $_miosNewRoot 'machine-state'
        $script:MiosDistroDir       = Join-Path $script:MiosProgramData 'distros'
        $script:MiosImagesDir       = Join-Path $script:MiosProgramData 'images'
        $script:MiosMachineCfg      = Join-Path $script:MiosProgramData 'config'
        # M:\ root IS the mios.git working tree per the 2026-05-06
        # directive ("M:\ IS git"). Repo lives at the drive root,
        # mios-bootstrap shadow at M:\MiOS\bootstrap-shadow.
        $script:MiosRepoDir         = "${_miosDataLetter}:\"
        $script:MiosBootstrapShadow = Join-Path $_miosNewRoot 'bootstrap-shadow'
        # Mirror the locals so any later code that still reads $MiosInstallDir
        # (without $script: prefix) gets the same redirect.
        $MiosInstallDir      = $script:MiosInstallDir
        $MiosBinDir          = $script:MiosBinDir
        $MiosShareDir        = $script:MiosShareDir
        $MiosIconsDir        = $script:MiosIconsDir
        $MiosThemesDir       = $script:MiosThemesDir
        $MiosFontsDir        = $script:MiosFontsDir
        $MiosProgramData     = $script:MiosProgramData
        $MiosDistroDir       = $script:MiosDistroDir
        $MiosImagesDir       = $script:MiosImagesDir
        $MiosMachineCfg      = $script:MiosMachineCfg
        $MiosRepoDir         = $script:MiosRepoDir
        $MiosBootstrapShadow = $script:MiosBootstrapShadow
        Write-Host "  [+] M:\ MIOS-DEV partition detected -- ALL install paths redirected to M:\" -ForegroundColor Green
    }
} catch {}

# Per-user state regardless of scope. These resolve via $env:USERNAME /
# $env:USERPROFILE so each Windows account on a machine-wide install
# still gets its own logs and per-user identity overlay -- the "user
# variables" half of the install contract.
$MiosConfigDir    = Join-Path ${env:APPDATA}      "MiOS"               # %APPDATA%\MiOS
$MiosDataDir      = Join-Path ${env:LOCALAPPDATA} "MiOS"               # %LOCALAPPDATA%\MiOS
$MiosLogDir       = Join-Path $MiosDataDir        "logs"

function Resolve-MiosInstallRoot {
    # Returns the best Windows-side install root, preferring the dedicated
    # MiOS data disk (created by Initialize-MiosDataDisk in Phase 3:
    # shrinks C: by 256 GB, formats NTFS, label "MIOS-DEV", default
    # mount letter M:). Falls back to the boot-time default
    # ($MiosInstallDir) when the data disk hasn't been provisioned yet.
    #
    # Honors $env:MIOS_DATA_DISK_LETTER for non-default mount letters
    # (must match Initialize-MiosDataDisk's -DriveLetter argument).
    param([string]$Default = $script:MiosInstallDir)
    $letter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER } else { 'M' }
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($vol -and $vol.FileSystemLabel -eq 'MIOS-DEV') {
        return Join-Path "${letter}:\" 'MiOS'
    }
    return $Default
}

function Update-MiosInstallPaths {
    # Full-partition overlay: re-point EVERY install path at the new
    # root so the entire MiOS pipeline (Windows app, repos, dev VM
    # VHDX, build artifacts, machine-state, logs) lives on the same
    # volume. The `MIOS-DEV` partition is the operator's choice for
    # "everything MiOS lives here"; we honor that across the board.
    #
    # Caller MUST run this BEFORE Phase 2 (repos clone) so the clones
    # land at the right place for the new "M:\ IS git" layout.
    #
    # 2026-05-06 OPERATOR DIRECTIVE -- "MIOS REPOSITORIES BOTH OVERLAYED
    # AT THE M:\ ROOT". The previous "$MiosRepoDir = M:\MiOS\repo with
    # mios/ + mios-bootstrap/ as siblings" layout is gone. New layout:
    #
    #   M:\                  mios.git working tree (M:\.git is mios.git's)
    #                          + mios-bootstrap.git files overlaid on top
    #                            (Get-MiOS.ps1, build-mios.ps1, bootstrap.ps1)
    #   M:\MiOS\               Windows install state (subdirs below)
    #   M:\MiOS\bin            entry-point .ps1 scripts
    #   M:\MiOS\share          materialized templates (legacy convenience)
    #   M:\MiOS\machine-state  podman-machine + WSL2 state
    #   M:\MiOS\distros        WSL2 distro tarballs
    #   M:\MiOS\images         BIB output artifacts
    #   M:\MiOS\logs           install logs
    #   M:\MiOS\bootstrap-shadow  mios-bootstrap.git's actual checkout (.git lives here
    #                              so fetch+reset on bootstrap doesn't fight mios.git's
    #                              .git at M:\); files are robocopied onto M:\ root.
    param([Parameter(Mandatory)] [string] $NewRoot)
    $script:MiosInstallDir  = $NewRoot
    $script:MiosBinDir      = Join-Path $NewRoot 'bin'
    $script:MiosShareDir    = Join-Path $NewRoot 'share'
    $script:MiosIconsDir    = Join-Path $NewRoot 'icons'
    $script:MiosThemesDir   = Join-Path $NewRoot 'themes'
    $script:MiosFontsDir    = Join-Path $NewRoot 'fonts'
    # State + artifacts also move onto the data disk.
    $script:MiosProgramData = Join-Path $NewRoot 'machine-state'
    # MiosRepoDir = data-disk root (M:\) when we're running on the
    # MIOS-DEV partition; legacy NewRoot\repo otherwise. Both repos
    # overlay to this path; mios.git's .git lives here, mios-bootstrap.git's
    # .git lives in $MiosBootstrapShadow.
    $_qualifier = (Split-Path $NewRoot -Qualifier)         # 'M:'
    $_drive     = if ($_qualifier) { "$_qualifier\" } else { $null }   # 'M:\'
    $_onDataDisk = $false
    if ($_drive) {
        try {
            $_vol = Get-Volume -DriveLetter $_qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
            if ($_vol -and $_vol.FileSystemLabel -eq 'MIOS-DEV') {
                $_onDataDisk = $true
            }
        } catch {}
    }
    if ($_onDataDisk) {
        $script:MiosRepoDir         = $_drive                                  # 'M:\'
        $script:MiosBootstrapShadow = Join-Path $NewRoot 'bootstrap-shadow'    # 'M:\MiOS\bootstrap-shadow'
    } else {
        $script:MiosRepoDir         = Join-Path $NewRoot 'repo'                # legacy fallback
        $script:MiosBootstrapShadow = Join-Path $script:MiosRepoDir 'mios-bootstrap'
    }
    $script:MiosDistroDir   = Join-Path $NewRoot 'distros'
    $script:MiosImagesDir   = Join-Path $NewRoot 'images'
    $script:MiosMachineCfg  = Join-Path $NewRoot 'config'
    $script:MiosLogDir      = Join-Path $NewRoot 'logs'
    # NOTE: $LogFile (the unified install log opened at script init)
    # stays on its boot-time path because file handles are already
    # open. Long-term logs from CLI verbs (mios-pull, mios-update,
    # etc.) write to the redirected $MiosLogDir.
}

function Invoke-MigrateLegacyInstallRoot {
    # NO-OP by default (2026-05-05 final). Kept callable only for legacy
    # invocation sites; the function returns immediately unless the operator
    # explicitly opts in via MIOS_FORCE_LEGACY_MIGRATE=1.
    #
    # ── Why no-op ───────────────────────────────────────────────────
    #
    # The "C:\\MiOS legacy install -> M:\\MiOS data disk" migration was a
    # design error. The two surfaces serve DIFFERENT purposes and should
    # never be merged:
    #
    #   C:\\MiOS   = developer's git working tree on the Windows host.
    #               Where the operator edits source, runs git, drives
    #               Claude Code, etc. Active dev surface.
    #
    #   M:\\MiOS\\ = bootstrap-created install root for MiOS-DEV runtime
    #               artifacts: vhdx, icons, themes, machine-state,
    #               distros, build-output images, logs, plus
    #               M:\\MiOS\\repo\\ as a Windows-side MIRROR of origin
    #               (cloned by the bootstrap from origin, NOT migrated
    #               from C:\\MiOS).
    #
    # The "full-partition overlay is the LAW" architectural rule applies
    # INSIDE a running MiOS deployment (the deployed Linux host treats
    # `/` as a full git working tree against the local Forgejo / cloud
    # GitHub). It does NOT mean "migrate the developer's Windows-side
    # working tree onto M:\\".
    #
    # The previous /MOVE behavior wiped C:\\MiOS files between bootstrap
    # turns (visible 2026-05-05 14:43-14:52 session as a 13-file working-
    # tree wipe restored via `git checkout HEAD -- ...`) -- a destructive
    # failure mode for the operator's active dev surface that no
    # combination of "make it git-aware" or "fence it behind opt-in"
    # really redeems. The cleanest fix is: don't migrate.
    #
    # ── Bypass switches (env vars; all default off) ─────────────────
    #
    #   MIOS_FORCE_LEGACY_MIGRATE=1    proceed with destructive
    #                                  robocopy /MOVE (rare cleanup
    #                                  scenarios where the operator
    #                                  KNOWS the legacy root is stale).
    #   MIOS_SKIP_LEGACY_MIGRATE=1     legacy bypass alias; now the
    #                                  default behavior, kept
    #                                  recognized so old recipes
    #                                  don't error.
    #
    param([string]$LegacyRoot)
    if (-not $LegacyRoot) { return }
    if ($LegacyRoot -ieq $script:MiosInstallDir) { return }
    if (-not (Test-Path $LegacyRoot)) { return }

    # Default no-op. The MIOS_SKIP_LEGACY_MIGRATE alias remains
    # recognized for backward compat; it's now redundant.
    if ($env:MIOS_FORCE_LEGACY_MIGRATE -notin @('1','true','TRUE','yes')) {
        Log-Ok "Legacy migration is no-op by default. C:\\MiOS (dev working tree) and M:\\MiOS\\ (bootstrap install root) coexist; neither overwrites the other. Set MIOS_FORCE_LEGACY_MIGRATE=1 only for explicit cleanup of stale plain-dir leftovers."
        return
    }

    # ── Force path: explicit operator opt-in for cleanup of stale dirs ──
    # Refuses to operate on git working trees -- those are sacrosanct.
    if (Test-Path (Join-Path $LegacyRoot '.git')) {
        Log-Warn "$LegacyRoot is a git working tree. Migration refuses to /MOVE git working trees (use a manual git remote workflow instead). Aborting even with MIOS_FORCE_LEGACY_MIGRATE=1."
        return
    }

    Log-Warn "MIOS_FORCE_LEGACY_MIGRATE=1 -- proceeding with destructive robocopy /MOVE from $LegacyRoot to $($script:MiosInstallDir) (non-git leftover dirs only)"
    Set-Step "Migrating legacy install $LegacyRoot -> $($script:MiosInstallDir) ..."
    $InstallDir = $script:MiosInstallDir
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $rcArgs = @(
        $LegacyRoot, $InstallDir,
        '/MOVE',           # delete source files after copy
        '/E',              # include all subdirs incl. empty
        '/XO', '/XN', '/XC', # skip if dest exists (older / newer / same-size-different)
        '/NFL', '/NDL', '/NJH', '/NJS',  # quiet output
        '/R:1', '/W:1'     # 1 retry, 1s wait
    )
    & robocopy.exe @rcArgs 2>&1 | ForEach-Object { Write-Log "migrate: $_" }
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Log-Warn "robocopy returned $rc on legacy migration (>= 8 = real error). Some files may remain at $LegacyRoot."
    }

    if (Test-Path $LegacyRoot) {
        $remaining = @(Get-ChildItem -Path $LegacyRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            try {
                Remove-Item $LegacyRoot -Recurse -Force -ErrorAction SilentlyContinue
                Log-Ok "Migrated and removed legacy install root: $LegacyRoot"
            } catch {
                Log-Warn "Could not remove now-empty $LegacyRoot : $_"
            }
        } else {
            Log-Warn "Migration kept $($remaining.Count) file(s) at $LegacyRoot (already-present at destination); review manually."
        }
    } else {
        Log-Ok "Legacy install root $LegacyRoot fully migrated"
    }
}

function Invoke-DataDiskBootstrap {
    # Provisions the dedicated MIOS-DEV data disk and re-points all
    # install paths onto it. Idempotent: if M:\ is already a MIOS-DEV-
    # labeled volume we just redirect; otherwise we shrink C: by the
    # configured amount and create the partition. Honors:
    #   $env:MIOS_SKIP_DATA_DISK    - skip everything (legacy C:\MiOS layout)
    #   $env:MIOS_DATA_DISK_LETTER  - drive letter (default M)
    #   $env:MIOS_DATA_DISK_MB      - shrink size in MB (default 262144)
    #
    # Called BEFORE Phase 2 so the repo clones go directly to the
    # data disk instead of having to migrate later.
    param([hashtable]$HW)
    if ($env:MIOS_SKIP_DATA_DISK -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_DATA_DISK set -- using C:\MiOS layout"
        return
    }
    if (-not $script:IsAdmin) {
        Log-Warn "Not running as admin -- skipping data disk provisioning (would need elevation to shrink C:)"
        return
    }
    # M:\ shrink amount sourced from mios.toml [bootstrap.host_storage].
    # shrink_mb (vendor default 262656 = 256 GiB + 512 MB buffer so the
    # NTFS volume rounds to "256 GB" in Explorer). MIOS_DATA_DISK_MB env
    # still wins for ad-hoc test overrides.
    $shrinkMB    = if ($env:MIOS_DATA_DISK_MB)     { [int]$env:MIOS_DATA_DISK_MB }     else { Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'shrink_mb' -Default 262656 }
    $driveLetter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER }      else { Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'drive_letter' -Default 'M' }
    $_volLabel   = Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'volume_label' -Default 'MIOS-DEV'
    try {
        $dataRoot = Initialize-MiosDataDisk -ShrinkMB $shrinkMB -DriveLetter $driveLetter -VolumeLabel $_volLabel
        Set-PodmanMachineStorageOn -DataRoot $dataRoot
        # Clamp the VHDX max-size to fit the new partition.
        $newFreeGB = [math]::Floor((Get-Volume -DriveLetter $driveLetter).SizeRemaining / 1GB)
        $clamped   = [math]::Max(80, [math]::Min($HW.DiskGB, $newFreeGB - 8))
        if ($clamped -ne $HW.DiskGB) {
            Log-Ok "Clamped VHDX max from $($HW.DiskGB) GB to $clamped GB to fit ${driveLetter}: ($newFreeGB GB free)"
            $HW.DiskGB = $clamped
        }
    } catch {
        Log-Warn "MiOS data-disk provisioning failed: $_"
        Log-Warn "Continuing with default %LOCALAPPDATA% storage (set MIOS_SKIP_DATA_DISK=1 to silence this)"
        return
    }

    # Redirect ALL install paths onto the new data disk. The full-
    # partition overlay means M:\MiOS\ is everything: bin, icons,
    # themes, repos, distros, images, machine-state, logs.
    $newRoot = Join-Path "${driveLetter}:\" 'MiOS'
    if ($newRoot -ne $script:MiosInstallDir) {
        $legacyRoot = $script:MiosInstallDir
        Log-Ok "Full-partition overlay: redirecting install root $legacyRoot -> $newRoot"
        Update-MiosInstallPaths -NewRoot $newRoot
        # Auto-migrate any leftover content from a previous boot-time
        # install (C:\MiOS, %LOCALAPPDATA%\MiOS) onto the data disk.
        Invoke-MigrateLegacyInstallRoot -LegacyRoot $legacyRoot
    }
}

function Test-DashboardCanRedraw {
    # Verify [Console]::SetCursorPosition actually moves the cursor.
    # In some hosts (Start-Transcript active, redirected stdout, certain
    # `irm | iex` parent shells, remote PSSession, captured runspace)
    # the call silently no-ops or throws -- in either case the dashboard
    # would just stack frames downward forever. Returns $true only when
    # we can confidently repaint in place.
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        $origTop  = [Console]::CursorTop
        $origLeft = [Console]::CursorLeft
        # Move to col 0 of the SAME row -- a no-op if positioning works,
        # detectable as a failure if it doesn't.
        [Console]::SetCursorPosition(0, $origTop)
        $afterLeft = [Console]::CursorLeft
        # Restore.
        [Console]::SetCursorPosition($origLeft, $origTop)
        return ($afterLeft -eq 0)
    } catch { return $false }
}

function Try-ResizeConsole {
    # Best-effort: set the host window to ~100x40 (slightly larger than
    # the 80-col dashboard frame so there's breathing room for log
    # spillover). Silently skipped if the host doesn't allow resize
    # (e.g. embedded terminals, SSH sessions, fixed-size kiosks).
    param([int]$Cols = 100, [int]$Rows = 40)
    try {
        $sz  = New-Object Management.Automation.Host.Size $Cols, $Rows
        $buf = New-Object Management.Automation.Host.Size $Cols, 3000
        # BufferSize must be >= WindowSize on both axes; set buf first.
        $Host.UI.RawUI.BufferSize = $buf
        $Host.UI.RawUI.WindowSize = $sz
    } catch {
        # Some hosts throw "WindowSize cannot exceed BufferSize" if
        # buffer wasn't accepted. Try the inverse order as a fallback.
        try {
            $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size $Cols, $Rows
        } catch {}
    }
}

# ── Log files ─────────────────────────────────────────────────────────────────
# UNIFIED COUNTING SYSTEM: there is exactly one logged counter timeline --
# the Write-Log entries written to $LogFile by [IO.File]::AppendAllText.
# Show-Dashboard writes directly to the console (in-place repaint via
# SetCursorPosition) and is NEVER captured to the log file. This keeps
# the log a single chronological event stream instead of being flooded
# by hundreds of repainted dashboard frames per minute.
#
# Why no Start-Transcript: Start-Transcript wraps stdout at the host
# layer, so [Console]::Write calls from Show-Dashboard get captured.
# Each 150ms repaint then duplicates the entire ~20-row dashboard into
# the log. Direct file append-only logging avoids this entirely.
$null = New-Item -ItemType Directory -Path $MiosLogDir -Force -ErrorAction SilentlyContinue
$LogStamp       = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
$LogFile        = Join-Path $MiosLogDir "mios-install-$LogStamp.log"
$BuildDetailLog = Join-Path $MiosLogDir "mios-build-$LogStamp.log"
[Environment]::SetEnvironmentVariable("MIOS_UNIFIED_LOG", $LogFile)
[Environment]::SetEnvironmentVariable("MIOS_BUILD_LOG",   $BuildDetailLog)

# Initialize the unified log with a session header so post-mortem readers
# can identify the run boundary the same way Start-Transcript used to.
try {
    # Capture build-mios.ps1's own commit SHA when running from a git
    # working tree. This is invaluable for diagnosing "is the user
    # actually running the latest build-mios.ps1?" -- GitHub raw +
    # Fastly caching can serve a stale outer Get-MiOS.ps1 / cached
    # mios-bootstrap clone for ~5 minutes after a push, and without
    # this stamp it's impossible to tell from the log whether a
    # specific fix was reachable.
    $scriptCommit = "(unknown)"
    try {
        $scriptDir = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent }
                     elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
                     else { $null }
        if ($scriptDir -and (Test-Path (Join-Path $scriptDir '.git'))) {
            $sha = & git -C $scriptDir rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $sha) { $scriptCommit = "$sha" }
        }
    } catch {}
    # Promote to script scope so the dashboard's title can show it on
    # every screenshot -- the operator can see at a glance which
    # commit is actually running, no log-grep required.
    $script:BuildMiosCommit = $scriptCommit
    [System.IO.File]::AppendAllText(
        $LogFile,
        ("=" * 78 + "`n" +
         "MiOS install session  start=$LogStamp  pid=$PID  user=$env:USERNAME  host=$env:COMPUTERNAME`n" +
         "                     build-mios.ps1 commit=$scriptCommit  version=$MiosVersion`n" +
         "=" * 78 + "`n"),
        [Text.Encoding]::UTF8)
    # Flush the deferred console-resize diagnostic captured at line ~70
    # (before $LogFile was known, before Write-Log existed). This makes
    # it visible in the unified log so we can tell post-mortem whether
    # the SetWindowSize(80,30) call actually took.
    if ($script:_PendingResizeLog) {
        [System.IO.File]::AppendAllText(
            $LogFile,
            ("[" + (Get-Date -Format 'HH:mm:ss.fff') + "][INFO] " + $script:_PendingResizeLog + "`n"),
            [Text.Encoding]::UTF8)
    }
} catch {}

# Dashboard mode is set after $script:DashRow is captured below in MAIN
# (initial render + Test-DashboardCanRedraw probe). Default to 'log'
# so any pre-MAIN Write-Log calls don't try to render-over a frame
# that doesn't exist yet.
$script:DashboardMode = 'log'

function Write-Log {
    param([string]$M, [string]$L = "INFO")
    $ts = [datetime]::Now.ToString("HH:mm:ss.fff")
    $line = "[$ts][$L] $M"
    # Append to the unified log directly. No transcript -> dashboard
    # frames cannot leak in. This is THE single canonical counting
    # system for the run; every event flows through here.
    try { [System.IO.File]::AppendAllText($LogFile, ($line + "`n"), [Text.Encoding]::UTF8) } catch {}
    # Console mirroring policy:
    #   * INFO/DEBUG -> file ONLY. Never Write-Host. The previous code
    #     said "interactive: mirror every line, Show-Dashboard repaints
    #     over them" but Show-Dashboard only writes ~25 rows; the
    #     quadlet-overlay seed alone emits hundreds of INFO lines (file
    #     update percent x 618, oh-my-posh sub-lines, etc.), drowning
    #     the dashboard with scrolling text and producing the
    #     stacked-frame screenshot artifact. The operator sees the
    #     current step via $script:CurStep on the dashboard's now-line;
    #     the log file is authoritative for everything else.
    #   * WARN/ERROR -> file + Write-Host. Operators MUST see these,
    #     so we surface them above the dashboard. Show-Dashboard's next
    #     tick scrolls the visible region but the log file always has
    #     the canonical record.
    if ($L -in @('WARN','ERROR')) {
        $color = if ($L -eq 'ERROR') { 'Red' } else { 'Yellow' }
        Write-Host $line -ForegroundColor $color
    }
    if ($L -eq "ERROR") { $script:ErrCount++ }
    if ($L -eq "WARN")  { $script:WarnCount++ }
}

# ── MiOS globals (ONE central loader) ────────────────────────────────────────
# Operator 2026-05-09: "EXACTLY BUT FOR ALL VARIABLES GLOBALLY!!!!".
# Every shared mios.toml value the build pipeline reads is loaded
# ONCE here into the $script:Mios* namespace and read by name from
# downstream code instead of each site re-calling Get-MiosTomlValue.
# Single source-of-truth catalog -- one call site for each toml key.
function Initialize-MiosGlobals {
    # ── [terminal] -- dims + framing ─────────────────────────
    $script:MiosCols       = [int](Get-MiosTomlValue -Section 'terminal' -Key 'cols'            -Default 80)
    $script:MiosRows       = [int](Get-MiosTomlValue -Section 'terminal' -Key 'rows'            -Default 20)
    $script:MiosScroll     = [int](Get-MiosTomlValue -Section 'terminal' -Key 'scrollback_rows' -Default 9000)
    $script:MiosFrameW     = [int](Get-MiosTomlValue -Section 'terminal' -Key 'frame_width'     -Default 75)
    $script:MiosFrameH     = [int](Get-MiosTomlValue -Section 'terminal' -Key 'frame_height'    -Default 19)
    $script:MiosRightMgn   = [int](Get-MiosTomlValue -Section 'terminal' -Key 'right_margin'    -Default 5)
    if ($script:MiosCols     -lt 40) { $script:MiosCols     = 80 }
    if ($script:MiosRows     -lt 10) { $script:MiosRows     = 20 }
    if ($script:MiosFrameW   -lt 20) { $script:MiosFrameW   = 75 }
    if ($script:MiosFrameH   -lt 5)  { $script:MiosFrameH   = 19 }
    if ($script:MiosRightMgn -lt 0)  { $script:MiosRightMgn = 5  }
    # ── [theme.font] -- font + cell metrics ──────────────────
    $script:MiosFontFamily = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'family'      -Default 'GeistMono Nerd Font Mono')
    $script:MiosFontSize   = [int]   (Get-MiosTomlValue -Section 'theme.font' -Key 'size'        -Default 12)
    $script:MiosFontWeight = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'weight'      -Default 'normal')
    $script:MiosCellW      = [int]   (Get-MiosTomlValue -Section 'theme.font' -Key 'cell_w_px'   -Default 10)
    $script:MiosCellH      = [int]   (Get-MiosTomlValue -Section 'theme.font' -Key 'cell_h_px'   -Default 20)
    $script:MiosChromeW    = [int]   (Get-MiosTomlValue -Section 'theme.font' -Key 'chrome_w_px' -Default 20)
    $script:MiosChromeH    = [int]   (Get-MiosTomlValue -Section 'theme.font' -Key 'chrome_h_px' -Default 12)
    # ── [theme.terminal] -- WT profile names ─────────────────
    $script:MiosSchemeName     = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'scheme_name'         -Default 'MiOS')
    $script:MiosProfileName    = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'profile_name'        -Default 'MiOS-WIN')
    $script:MiosDevProfileName = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'dev_profile_name'    -Default 'MiOS-DEV')
    $script:MiosHubTargetProf  = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'hub_target_profile'  -Default 'MiOS-DEV')
    $script:MiosSummonKeys     = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'summon_keys'         -Default 'win+space')
    $script:MiosSummonWindow   = [string](Get-MiosTomlValue -Section 'theme.terminal' -Key 'summon_window_name'  -Default 'MiOS-DEV')
    # ── [apps] -- shortcut / AumID names ─────────────────────
    $script:MiosAumid          = [string](Get-MiosTomlValue -Section 'apps' -Key 'aumid'             -Default 'MiOS.Workstation')
    $script:MiosStartMenuFold  = [string](Get-MiosTomlValue -Section 'apps' -Key 'start_menu_folder' -Default 'MiOS')
    $script:MiosHubLnkName     = [string](Get-MiosTomlValue -Section 'apps' -Key 'hub_shortcut_name' -Default 'MiOS')
    # ── [branding] -- taglines + dashboard frame chars ───────
    $script:MiosTagline        = [string](Get-MiosTomlValue -Section 'branding' -Key 'tagline'      -Default 'My Personal Operating System')
    $script:MiosTaglineLong    = [string](Get-MiosTomlValue -Section 'branding' -Key 'tagline_long' -Default 'My Personal Operating System  --  Immutable Fedora AI Workstation')
    $script:MiosTaglineApp     = [string](Get-MiosTomlValue -Section 'branding' -Key 'tagline_app'  -Default $script:MiosTagline)
    $script:MiosFrameChars     = [string](Get-MiosTomlValue -Section 'branding.dashboard' -Key 'frame_chars' -Default '╭─╮│╰╯')
    if ($script:MiosFrameChars.Length -lt 6) { $script:MiosFrameChars = '╭─╮│╰╯' }
}
Initialize-MiosGlobals

# UNIFIED width formula -- ONE function used by every framed surface
# in build-mios.ps1 (load-time + post-resize Show-Dashboard +
# install-complete banner) AND Show-MiosDashboard (Get-MiOS.ps1) AND
# mios-dashboard.sh (Linux).  WIDTH = min(WindowWidth - right_margin,
# frame_width) sourced from the [terminal] section loaded above.
function Get-MiosFrameWidth {
    [math]::Max(60, [math]::Min(([Console]::WindowWidth - $script:MiosRightMgn), $script:MiosFrameW))
}
$script:DW = Get-MiosFrameWidth
# Per the self-replication architecture, the Windows side (BootstrapOnly,
# the default for irm | iex entry) does ONLY:
#   ack -> hardware/env probe -> minimal mios-bootstrap clone ->
#   MiOS-DEV podman-machine setup -> .wslconfig sanity ->
#   Start Menu / shortcuts -> SSH handoff into MiOS-DEV.
# Everything else (identity prompts, OCI build, WSL2/Hyper-V/QEMU
# image exports, disk-image generation) belongs INSIDE MiOS-DEV via
# /usr/libexec/mios/mios-build-driver -- no Windows-side rendering of
# those phases. We render a 6-entry dashboard in BootstrapOnly mode
# and the historical 14-entry one in -FullBuild / -BuildOnly mode.
#
# $AppRegPhaseId is the index for the "App registration" phase in
# whichever array is active; the Start-Phase / End-Phase callers near
# the bottom of the script reference it so we don't hardcode 8 or 5.
# Phase names resolve through mios.toml [install_phases.<mode>] (SSOT).
# Operator edits via mios.html flow mios.toml -> next install run uses
# the new names. Vendor fallback below is the cold first-run set when
# no TOML is reachable.
$_phaseFallbackBootstrap = @(
    "Hardware + Prerequisites",
    "Detecting environment",
    "Directories and repos",
    "MiOS-DEV distro",
    "WSL2 configuration",
    "App registration"
)
$_phaseFallbackFull = @(
    "Hardware + Prerequisites",
    "Detecting environment",
    "Directories and repos",
    "MiOS-DEV distro",
    "WSL2 configuration",
    "Verifying build context",
    "Identity",
    "Writing identity",
    "App registration",
    "Building OCI image",
    "Exporting WSL2 image",
    "Registering 'MiOS' WSL2",
    "Building disk images",
    "Deploying Hyper-V VM"
)
$_phaseSection = if ($BootstrapOnly) { 'install_phases.bootstrap' } else { 'install_phases.full' }
$_phaseFallback = if ($BootstrapOnly) { $_phaseFallbackBootstrap } else { $_phaseFallbackFull }
$script:PhaseNames = @(Get-MiosTomlValue -Section $_phaseSection -Key 'names' -Default $_phaseFallback)
if (-not $script:PhaseNames -or $script:PhaseNames.Count -eq 0) { $script:PhaseNames = $_phaseFallback }
# AppRegPhaseId is the 0-based index of "App registration" within the
# active PhaseNames array. Resolved by name search so reordering doesn't
# break the post-phase-N callers.
$script:AppRegPhaseId = [array]::IndexOf([string[]]$script:PhaseNames, 'App registration')
if ($script:AppRegPhaseId -lt 0) {
    $script:AppRegPhaseId = if ($BootstrapOnly) { 5 } else { 8 }
}
$script:TotalPhases = $script:PhaseNames.Count
# PhStat size tracks the active PhaseNames so the dashboard's status
# row never indexes past the array. 0=pending, 1=running, 2=ok,
# 3=warn, 4=fail (see Set-Step / End-Phase).
$script:PhStat = @(0) * $script:TotalPhases
$script:PhStart       = @{}
$script:PhEnd         = @{}
$script:CurPhase      = -1
$script:CurStep       = "Starting..."
$script:ErrCount      = 0
$script:WarnCount     = 0
$script:ScriptStart   = [datetime]::Now
$script:DashRow       = 0
$script:DashHeight    = 0
# Last-rendered row count -- used by Show-Dashboard to blank rows that
# were part of a previous larger render but are no longer present in
# the current one. Without this, transitioning from a 14-phase layout
# to a 6-phase layout (BootstrapOnly mode truncating the tail) leaves
# the bottom 8 rows of the previous dashboard as ghost content.
$script:DashLastHeight = 0
# Last-rendered row WIDTH (in columns). Tracks the high-water mark
# across renders so a render that ends up narrower than a prior one
# (e.g. terminal got resized down by 1 col, [Console]::WindowWidth
# reported a smaller value, or the box width clamp dropped from 80
# to 79) still pads to the previous max -- otherwise the previous
# render's RIGHTMOST column lingers as a vertical ghost stripe of
# `+`/`|`/`=` characters running down the right edge of the new
# narrower render.
$script:DashLastWidth = 0
$script:FinalRc       = 0
# Build sub-step denominator. In -BootstrapOnly mode we never run
# the OCI build, so the 48 podman-build steps don't apply -- using
# the full 48 makes the dashboard's "0/62" denominator nonsensical
# for a 6-phase bootstrap run. Set to 0 here when bootstrap-only;
# the full path (-FullBuild / -BuildOnly) bumps it back to 48 once
# Phase 8 starts.
$script:BuildSubTotal = if ($BootstrapOnly) { 0 } else { 48 }
$script:BuildSubDone  = 0
$script:BuildSubStep  = ""
$script:GhcrToken     = ""
# Live build tracking -- updated each loop tick; shown in debug row
$script:DebugLine     = ""
$script:LineCount     = 0
$script:HWInfo        = ""   # set after Get-Hardware; shown in dashboard info row
$script:IdentInfo     = ""   # set after phase 6 identity; User/Host/Base/Model row
# Shared state between main thread and background spinner runspace.
# SpinnerRow = -1 means unknown (spinner write suppressed until first render).
$script:DashSync = [hashtable]::Synchronized(@{
    Running    = $true
    Rendering  = $false   # set by the main thread around Show-Dashboard's
                          # buffer writes so the background heartbeat skips
                          # its spinner stamp during render -- prevents the
                          # spinner from bleeding into separator rows when
                          # the row count changes between renders.
    SpinnerRow = -1
    SpinnerCol = 2        # "| X" -- spinner is the first char inside the row body
})
$script:BgPs = $null
$script:BgRs = $null

# ── Dashboard functions ───────────────────────────────────────────────────────
function fmtSpan([timespan]$s) {
    if ($s.TotalHours -ge 1) { return "{0}:{1:D2}:{2:D2}" -f [int]$s.TotalHours,$s.Minutes,$s.Seconds }
    return "{0:D2}:{1:D2}" -f [int]$s.TotalMinutes,$s.Seconds
}

function pbar([int]$done,[int]$total,[int]$width) {
    $pct = if ($total -gt 0) { [int](($done/$total)*100) } else { 0 }
    $f   = if ($total -gt 0) { [int](($done/$total)*$width) } else { 0 }
    $bar = if ($f -gt 0) { ("=" * ([math]::Max(0,$f-1))) + ">" } else { "" }
    return "[{0}] {1,3}%  {2}/{3}" -f $bar.PadRight($width),$pct,$done,$total
}

function Update-BuildSubPhase([string]$line) {
    # Strip BuildKit "#N 0.123 " prefix
    $stripped = ($line -replace '^\s*#\d+\s+[\d.]+\s+', '').TrimStart()
    $script:LineCount++

    if ($stripped -match '\+-\s*STEP\s+(\d+)/(\d+)\s*:\s*(\S+)') {
        # Step start marker: "+- STEP NN/TT : scriptname.sh"
        $script:BuildSubTotal = [int]$Matches[2]
        $script:BuildSubStep  = $Matches[3] -replace '\.sh$', ''
        $script:BuildSubDone  = [math]::Max(0, [int]$Matches[1] - 1)
        $script:CurStep       = "Step $($Matches[1])/$($Matches[2]) -- $($script:BuildSubStep)"
        $script:DebugLine     = $stripped
    } elseif ($stripped -match '\+--\s+\[') {
        # Step end marker
        $script:BuildSubDone = [math]::Min($script:BuildSubDone + 1, $script:BuildSubTotal)
        $script:DebugLine    = $stripped
    } elseif (-not [string]::IsNullOrWhiteSpace($stripped)) {
        $c = ($stripped -replace '\s+', ' ').Trim()
        if ($c.Length -gt 120) { $c = $c.Substring(0, 117) + '...' }
        $script:CurStep   = $c
        $script:DebugLine = $c
    }
}

function Show-Dashboard {
    param([switch]$Force)
    # Linear-log mode: SetCursorPosition is a no-op or the host doesn't
    # support repaint -- attempting to render the framed dashboard just
    # stacks frames downward forever (one per Set-Step / phase tick).
    # Bail entirely; Start-Phase / End-Phase / Set-Step emit their own
    # one-line log messages in this mode (see those functions below).
    if ($script:DashboardMode -eq 'log') { return }

    # ── Render throttle ──────────────────────────────────────────────────────
    # Show-Dashboard is invoked once per stdout line during heavy native
    # commands (podman build, dnf install, etc.) -- 100+ calls/second
    # during a layer pull. Each render writes ~25 rows via per-row
    # SetCursorPosition + Write, and the conhost / WT pseudo-console
    # tears visibly when repaints land mid-flush. Cap at 10 fps (100 ms
    # between renders) -- imperceptible lag, no tearing. Force overrides
    # for end-of-phase / state-change calls that must show NOW.
    if (-not $Force) {
        $nowMs = [Environment]::TickCount
        if ($script:DashLastRenderMs -and ($nowMs - $script:DashLastRenderMs) -lt 100) {
            return
        }
        $script:DashLastRenderMs = $nowMs
    } else {
        $script:DashLastRenderMs = [Environment]::TickCount
    }
    try {
    # ── Sizing -- max 80 cols (standard tty0/console) ──────────────────────────
    # Pad to BufferWidth, not just WindowWidth. The buffer can be wider
    # than the visible window (Windows console default = 120-col buffer
    # in a 80-col window), and log lines written before the dashboard
    # rendered may have left stale content at buffer columns past the
    # visible right edge. PadRight(WindowWidth) only clears up to the
    # visible width; PadRight(BufferWidth) clears every column the log
    # could have written to. Per the operator's "ics / oder:14b /
    # GB free)" right-edge bleed in repeated screenshots.
    $winW = try { [Console]::WindowWidth  } catch { 80 }
    $bufW = try { [Console]::BufferWidth  } catch { $winW }
    $bufH = try { [Console]::BufferHeight } catch { 9999 }
    # ── Width strict-clamp ────────────────────────────────────────────
    # The previous code did `winW = max(winW, bufW, DashLastWidth)` to
    # "blank stale columns from a wider previous render" -- but that
    # ratchet locks the padding wider than the live buffer for the
    # rest of the session.
    #
    # Concrete failure mode (commit 53ac9d8 stacking screenshots):
    #   1. Load-time resize: 80x30 / 80x9000
    #   2. `Try-ResizeConsole -Cols 100 -Rows 40` (~line 4501)
    #      enlarges to 100x40 transiently
    #   3. First Show-Dashboard: winW=max(100, 100, 0)=100, rows padded
    #      to 100, DashLastWidth=100
    #   4. Defensive resize (~line 4395): back to 80x30 / 80x9000
    #   5. Every later Show-Dashboard: winW=max(80, 80, 100)=100
    #   6. Writing a 100-char row on an 80-col buffer auto-wraps at
    #      col 79; 20 chars overflow to the next buffer row; the next
    #      iteration overwrites cols 0-79 of that row but the
    #      now-orphaned wrap content from the previous iteration stays
    #      visible -> the stacked-banner artifact.
    #
    # Strict-clamp: never pad wider than the LIVE current console.
    # Capped at 80 for tty0/console portability. If a previous render
    # was wider than the current, the ghost-row blanking pass below
    # handles those extra rows; we never need to keep padding wide.
    $winW = [math]::Min($winW, [math]::Min($bufW, 80))
    $w    = [math]::Max(40, [math]::Min(80, $winW - 1))
    $in = $w - 4   # inner content width: "| " + content + " |"
    # Box-drawing frame chars to match the MiOS terminal's
    # Show-MiosDashboard styling (oh-my-posh framing). $sepTop and
    # $sepBot are the rounded top/bottom corners; $sepD is the
    # divider between sections; sides use thin │.
    $sepTop = ("╭" + ("─" * ($w - 2)) + "╮").PadRight($winW)
    $sepBot = ("╰" + ("─" * ($w - 2)) + "╯").PadRight($winW)
    $sepD   = ("├" + ("─" * ($w - 2)) + "┤").PadRight($winW)
    $sepE   = $sepTop   # legacy alias -- header uses top corner the first time

    # ── Row helper -- script block closes over $in/$winW from caller scope ─────
    $mkRow = {
        param([string]$c)
        ("│ " + $c.PadRight($in) + " │").PadRight($winW)
    }

    # ── State ─────────────────────────────────────────────────────────────────
    $phDone = [int]($script:PhStat | Where-Object { $_ -ge 2 } | Measure-Object).Count
    $phFail = [int]($script:PhStat | Where-Object { $_ -eq 3 } | Measure-Object).Count
    $elapsed   = [datetime]::Now - $script:ScriptStart
    $elStr     = fmtSpan $elapsed
    $statusStr = if ($phFail -gt 0) { "FAILED" } `
                 elseif ($script:CurPhase -ge 0 -and $script:CurPhase -lt $script:PhStat.Count -and $script:PhStat[$script:CurPhase] -eq 1) { "RUNNING" } `
                 else { "IDLE" }
    $curName   = if ($script:CurPhase -ge 0 -and $script:CurPhase -lt $script:PhaseNames.Count) { [string]$script:PhaseNames[$script:CurPhase] } else { "Initializing" }

    # Spinner -- 500ms tick; visible on slow/remote consoles, animates even when
    # build output is silent.
    $spinChar = @('|','/','-',[char]92)[[int]($elapsed.TotalMilliseconds / 500) % 4]

    $step = (([string]$script:CurStep) -replace '\s+', ' ').Trim()
    $stepMax = [math]::Max(3, $in - 8)
    if ($step.Length -gt $stepMax) { $step = $step.Substring(0, $stepMax - 3) + "..." }

    # ── Single unified progress bar (phases + build steps = one global count) ─
    $stDone  = [math]::Max(0, $script:BuildSubDone)
    $stTotal = [math]::Max(1, $script:BuildSubTotal)
    $glDone  = $phDone + $stDone
    $glTotal = $script:TotalPhases + $stTotal
    $barW    = [math]::Max(4, $in - 24)
    $glPct = 0; if ($glTotal -gt 0) { $glPct = [int](($glDone / $glTotal) * 100) }
    $glFRaw = 0; if ($glTotal -gt 0) { $glFRaw = [int](($glDone / $glTotal) * $barW) }
    $glF     = [math]::Max(0, $glFRaw)
    if ($glF -gt 0) { $glFill = ("=" * ($glF - 1)) + ">" } else { $glFill = "" }
    $glFill  = $glFill.PadRight($barW)
    $glBarL  = "[{0}] {1,3}%  {2}/{3}" -f $glFill,$glPct,$glDone,$glTotal

    # ── Phase table col widths ────────────────────────────────────────────────
    # Single table layout used by header / divider / data rows:
    #
    #   "{0,2} {1,-6} {2,-nameW} {3,5}"
    #     idx  tag   name        time
    #     2  +1+ 6  +1+ nameW   +1+ 5  = 16 + nameW
    #
    # Setting nameW = $in - 16 makes every row land at exactly $in
    # characters of content, so the right "|" border sits in the same
    # column on all three rows -- no more zigzag right edge.
    $nameW = [math]::Max(8, $in - 16)
    $tableFmt = "{0,2} {1,-6} {2,-${nameW}} {3,5}"

    # ── Assemble rows ─────────────────────────────────────────────────────────
    $rows = [System.Collections.Generic.List[string]]::new()

    # Header -- gap computed so total row width = $w, then padded to $winW
    $rows.Add($sepE)
    # Stamp the commit SHA in the title so every screenshot of the
    # dashboard makes it unambiguous which build-mios.ps1 is running.
    # Diagnoses Fastly cache lag at a glance: if the operator sees
    # "(commit abc1234)" but the latest fix you just pushed is def5678,
    # they're on stale code.
    $commitTag = if ($script:BuildMiosCommit -and $script:BuildMiosCommit -ne '(unknown)') {
        " (commit $($script:BuildMiosCommit))"
    } else { '' }
    $title = " 'MiOS' $MiosVersion$commitTag  --  Build Dashboard"
    $right = "[ $elStr ] "
    $gap   = [math]::Max(0, $in - $title.Length - $right.Length)
    $hdr   = "│ $title" + (" " * $gap) + "$right │"
    $rows.Add($hdr.PadRight($winW))
    $rows.Add($sepD)

    # Hardware info row (populated after Get-Hardware; blank during early phases)
    if ($script:HWInfo) {
        $hw = ([string]$script:HWInfo)
        if ($hw.Length -gt $in) { $hw = $hw.Substring(0,$in-3)+"..." }
        $rows.Add((& $mkRow $hw))
    }

    # Identity row (populated after phase 6; blank before)
    if ($script:IdentInfo) {
        $id = ([string]$script:IdentInfo)
        if ($id.Length -gt $in) { $id = $id.Substring(0,$in-3)+"..." }
        $rows.Add((& $mkRow $id))
    }

    if ($script:HWInfo -or $script:IdentInfo) { $rows.Add($sepD) }

    # ── ONE counter, ONE bar ──────────────────────────────────────────────────
    # Single global step counter (phases + build sub-steps) rendered as
    # one progress bar. The textual "Phase [N/Total]" and "(step X/Y)"
    # rows used to duplicate this same metric three different ways and
    # are intentionally gone -- the bar's "N/M" suffix is THE counter.
    # Current operation + spinner share one row above the bar so the
    # operator sees what's running without a second phase-counter line.
    # Bounds-clamp $script:CurPhase against PhStat.Count -- defensive
    # against any code path that sets CurPhase past the end of the array
    # (e.g. Start-Phase 9 in a mode where TotalPhases=6 -- the BootstrapOnly
    # collapsed layout). Without this clamp, [Console]::Write fires a
    # "Index was outside the bounds of the array" that gets caught by
    # MAIN's try/catch and surfaces as the dashboard's FATAL banner.
    $phIdx  = [math]::Min([math]::Max(0, $script:CurPhase), $script:PhStat.Count - 1)
    $phTag = switch ([int]$script:PhStat[$phIdx]) {
        1 { "[>>]" } 2 { "[OK]" } 3 { "[XX]" } 4 { "[!!]" } default { "[ ]" }
    }
    # Now-line: phase name + live operation stream + spinner. No
    # numeric counters here -- those live in the bar below.
    $opRowIdx = $rows.Count
    $nowLine  = "$spinChar  $phTag $curName -- $step"
    if ($nowLine.Length -gt $in) { $nowLine = $nowLine.Substring(0, $in - 3) + "..." }
    $rows.Add((& $mkRow $nowLine))
    $rows.Add($sepD)

    # The single global counter -- bar + percent + N/M of the unified
    # phase+substep total. This is THE counter; nothing else displays
    # progress numerically.
    $rows.Add((& $mkRow $glBarL))
    $rows.Add($sepD)

    # Side notes (not counters): error/warning tally + status. Errors
    # are not progress, so they get their own one-line row separate from
    # the counter row above. "Lines" was meaningless to operators and
    # was contributing to the visual noise -- dropped.
    $rows.Add((& $mkRow "Errors:$($script:ErrCount)  Warnings:$($script:WarnCount)  Status:$statusStr"))
    $rows.Add($sepD)

    # Phase table -- header, divider, and data rows ALL go through the
    # single $tableFmt printf template so the right border lands at
    # the same column on every row. Status tags are padded to 6 chars
    # to align under the "[Stat]" header column.
    $rows.Add((& $mkRow ($tableFmt -f " #", "[Stat]", "Phase Name", " Time")))
    $rows.Add((& $mkRow ($tableFmt -f "--", "------", ("-" * $nameW), "-----")))
    for ($i = 0; $i -lt $script:TotalPhases; $i++) {
        $st = switch ([int]$script:PhStat[$i]) {
            0 { "[ ]"  } 1 { "[>>]" } 2 { "[OK]" } 3 { "[XX]" } 4 { "[!!]" } default { "[??]" }
        }
        $nm = [string]$script:PhaseNames[$i]
        if ($nm.Length -gt $nameW) { $nm = $nm.Substring(0,$nameW-3)+"..." }
        $t = ""
        if ($null -ne $script:PhStart[$i]) {
            try {
                $ps = [datetime]$script:PhStart[$i]
                $pe = if ($null -ne $script:PhEnd[$i]) { [datetime]$script:PhEnd[$i] } else { [datetime]::Now }
                $t  = fmtSpan ($pe - $ps)
            } catch { $t = "--:--" }
        }
        $rows.Add((& $mkRow ($tableFmt -f $i, $st, $nm, $t)))
    }
    $rows.Add($sepD)

    # Log footer -- unified log only ($BuildDetailLog is merged in at exit)
    $logLeaf = try { Split-Path $LogFile -Leaf } catch { "?" }
    $rows.Add((& $mkRow "Log: $logLeaf"))
    $rows.Add($sepBot)

    # ── Render at fixed position; full-width overwrite eliminates bleed ────────
    $dashStart = [math]::Min($script:DashRow, [math]::Max(0, $bufH - $rows.Count - 2))
    # Lock out the background heartbeat for the duration of the buffer
    # writes so the spinner can't stamp a "/" or "-" into a separator
    # row mid-render. The heartbeat sees Rendering=$true on its next
    # 120 ms tick and skips its [Console]::Write.
    $script:DashSync.Rendering = $true
    try {
        $script:DashSync.SpinnerRow = $dashStart + $opRowIdx
        # Per-row absolute cursor placement. The previous code relied on
        # NewLine to advance to col 0 of the next row; in wider hosts
        # (110-160+ col terminals against an 80-cap buffer, or when the
        # background heartbeat slipped a write between rows) the cursor
        # could land mid-row, painting subsequent rows offset to the
        # right -- the visible "side-by-side ghost dashboard" symptom.
        # SetCursorPosition before each Write guarantees col=0.
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $tgtRow = $dashStart + $i
            if ($tgtRow -lt 0 -or $tgtRow -ge $bufH) { continue }
            [Console]::SetCursorPosition(0, $tgtRow)
            # No ANSI \e[K -- the operator's terminal sometimes does NOT
            # process the escape, in which case the literal "[K" leaks
            # into the dashboard view (seen in 2026-05-06 paste). The
            # strict-clamp on $winW above caps every row at 80 chars
            # already, so stale content past col 80 from prior renders
            # is not the concern it was; rely on row-overwrite alone.
            [Console]::Write($rows[$i])
        }
        # ── Ghost-row blanking ────────────────────────────────────────
        # If a previous render placed MORE rows than this one, blank
        # those tail rows with a $winW-wide space line so the previous
        # bottom of the dashboard doesn't linger underneath the new
        # render. Common cause: BootstrapOnly mode collapses the phase
        # table from 14 -> 6 rows mid-run; without this loop, phases
        # 6-13 stay visible as orphan text below the new bottom border.
        if ($script:DashLastHeight -gt $rows.Count) {
            $blank = (' ' * $winW)
            $extra = $script:DashLastHeight - $rows.Count
            for ($k = 0; $k -lt $extra; $k++) {
                $blankRow = $dashStart + $rows.Count + $k
                if ($blankRow -lt 0 -or $blankRow -ge $bufH) { continue }
                [Console]::SetCursorPosition(0, $blankRow)
                [Console]::Write($blank)
            }
        }
        $script:DashHeight     = $rows.Count
        $script:DashLastHeight = $rows.Count
        # DashLastWidth is no longer ratcheted -- the strict-clamp on
        # $winW makes the ratchet harmful (locks padding wider than the
        # live buffer; see comment near top of Show-Dashboard).
        $script:DashLastWidth  = $winW
        [Console]::SetCursorPosition(0, [math]::Min($dashStart + $script:DashHeight, $bufH - 1))
    } finally {
        $script:DashSync.Rendering = $false
    }

    } catch {
        Write-Host "[$([datetime]::Now.ToString('HH:mm:ss.fff'))][WARN] dashboard render error: $_"
    }
}

function Start-Phase([int]$i) {
    $script:CurPhase   = $i
    $script:PhStat[$i] = 1
    $script:PhStart[$i] = [datetime]::Now
    $script:CurStep    = $script:PhaseNames[$i]
    Write-Log "START phase $i : $($script:PhaseNames[$i])"
    if ($script:DashboardMode -eq 'log') {
        $ts = [datetime]::Now.ToString("HH:mm:ss")
        Write-Host ""
        # In bootstrap-only mode, phases 6-13 never run; report just the
        # phase number + name without a misleading X/13 ratio.
        $phaseTag = if ($BootstrapOnly) { "Phase $i" } else { "Phase $i/$($script:TotalPhases - 1)" }
        Write-Host "[$ts] >> $phaseTag -- $($script:PhaseNames[$i])" -ForegroundColor Cyan
    } else {
        Show-Dashboard -Force
    }
}

function End-Phase([int]$i, [switch]$Fail, [switch]$Warn) {
    $script:PhStat[$i] = if ($Fail) { 3 } elseif ($Warn) { 4 } else { 2 }
    $script:PhEnd[$i]  = [datetime]::Now
    $spanStr = try {
        if ($null -ne $script:PhStart[$i]) { fmtSpan ([datetime]$script:PhEnd[$i] - [datetime]$script:PhStart[$i]) } else { "--:--" }
    } catch { "--:--" }
    $tag     = if ($Fail) { "FAIL" } elseif ($Warn) { "WARN" } else { "OK  " }
    $lvl     = if ($Fail) { "ERROR" } else { "INFO" }
    Write-Log "$tag  phase $i : $($script:PhaseNames[$i]) ($spanStr)" $lvl
    if ($script:DashboardMode -eq 'log') {
        $ts = [datetime]::Now.ToString("HH:mm:ss")
        $color = if ($Fail) { 'Red' } elseif ($Warn) { 'Yellow' } else { 'Green' }
        $mark  = if ($Fail) { 'XX' } elseif ($Warn) { '!!' } else { 'OK' }
        Write-Host "[$ts] [$mark] Phase $i ($spanStr)  $($script:PhaseNames[$i])" -ForegroundColor $color
        # Inline progress bar after every phase transition. Operator
        # sees how far into the build they are without having to count.
        Show-MiosProgressBar
    } else {
        Show-Dashboard -Force
    }
}

function Show-MiosProgressBar {
    # Inline progress bar -- prints once at each phase boundary
    # (called from End-Phase). Counts COMPLETED phases (PhStat
    # entries >= 2 i.e. OK/FAIL/WARN). 50-cell bar, operator-blue
    # filled, dim unfilled. NO ANSI cursor manipulation -- earlier
    # attempts at scroll-region pinning fought PowerShell's normal
    # output flow and produced garbled banners + interleaved bars.
    # The bar scrolls with the log; that's the trade-off.
    if (-not $script:PhStat) { return }
    $done = [int]($script:PhStat | Where-Object { $_ -ge 2 } | Measure-Object).Count
    $total = [int]$script:TotalPhases
    if ($total -le 0) { return }
    $pct = [int](($done / $total) * 100)
    $barW = 50
    $filled = [int](($done / $total) * $barW)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $barW) { $filled = $barW }
    $bar = ("█" * $filled) + ("░" * ($barW - $filled))
    Write-Host "  [$bar] $done/$total ($pct%)" -ForegroundColor Cyan
}

# Throttle Set-Step prints in log mode -- the build pipeline calls
# Set-Step on every line of native output, which would flood the log.
# Print at most once per 2 seconds OR on a substantially-changed step.
$script:LastStepLogTime = [datetime]::MinValue
$script:LastStepLogText = ""
function _TruncToWidth {
    # Shorten a string to fit within $maxW visible chars. Long Windows
    # paths like "C:\Users\Administrator\AppData\Local\MiOS\repo\..."
    # get middle-elided to keep both ends visible:
    #   "C:\...\MiOS\repo\subdir\file.ext"
    # Falls back to simple tail truncation with "…" for non-paths.
    param([string]$S, [int]$MaxW = 78)
    if ($S.Length -le $MaxW) { return $S }
    # Path-aware: middle-elide if the string contains backslashes.
    if ($S -match '\\' -and $S.Length -gt 30) {
        $left  = $S.Substring(0, [int]($MaxW * 0.4))
        $right = $S.Substring($S.Length - [int]($MaxW * 0.5))
        $cand  = "$left…$right"
        if ($cand.Length -le $MaxW) { return $cand }
    }
    return $S.Substring(0, $MaxW - 1) + '…'
}

function Set-Step([string]$T) {
    $script:CurStep = $T
    Write-Log "step: $T"
    if ($script:DashboardMode -eq 'log') {
        # Skip console echo for WARN:/FAIL: -- Write-Log already
        # mirrored those.
        if ($T -match '^(WARN|FAIL):') { return }
        $now = [datetime]::Now
        $clean = ($T -replace '\s+', ' ').Trim()
        $secsSince = ($now - $script:LastStepLogTime).TotalSeconds
        $isFirst   = ($script:LastStepLogTime -eq [datetime]::MinValue)
        if ($isFirst -or $secsSince -ge 2 -or $clean -ne $script:LastStepLogText) {
            $ts = $now.ToString("HH:mm:ss")
            # Truncate long paths so the line fits in the 80-col window
            # without wrapping. "  [HH:MM:SS]  " prefix is 14 chars,
            # leaving 66 chars for content in a 80-col terminal.
            $maxContent = $script:DW - 14
            $clean = _TruncToWidth -S $clean -MaxW $maxContent
            Write-Host "  [$ts]  $clean" -ForegroundColor DarkGray
            $script:LastStepLogTime = $now
            $script:LastStepLogText = $clean
        }
    } else {
        Show-Dashboard
    }
}

function Log-Ok([string]$T)   { Write-Log $T;          Set-Step $T }
function Log-Warn([string]$T) { Write-Log $T "WARN";  Set-Step "WARN: $T" }
function Log-Fail([string]$T) { Write-Log $T "ERROR"; Set-Step "FAIL: $T" }

# ── Utility helpers ───────────────────────────────────────────────────────────
function ConvertTo-WslPath([string]$P) {
    $P = $P -replace '\\','/'
    if ($P -match '^([A-Za-z]):(.*)') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
    return $P
}

function Move-BelowDash {
    try {
        $targetRow = [math]::Min($script:DashRow + $script:DashHeight, [Console]::BufferHeight - 1)
        [Console]::SetCursorPosition(0, $targetRow)
    } catch {}
}

# Scrub keys from $env:USERPROFILE\.wslconfig's [wsl2] section that
# don't belong there. The most common mis-placement is `systemd=true`,
# which is a /etc/wsl.conf [boot] directive (per-distro, INSIDE the
# distro's filesystem) -- never a .wslconfig [wsl2] directive
# (host-side, Windows). When wsl.exe parses .wslconfig and finds an
# unknown key it prints:
#
#     wsl: Unknown key 'wsl2.systemd' in C:\Users\...\.wslconfig
#
# Older wsl versions treat that as a warning, newer ones can fail
# the parse entirely. Either way the line ends up in our Phase 3
# podman-init pipeline capture and surfaces as a FATAL with the
# warning text (because the dashboard displays the LAST stderr line
# captured before podman exits non-zero).
#
# This helper runs once at the end of Phase 0 so every subsequent
# WSL/podman invocation in the build sees a clean .wslconfig.
function Repair-WslConfig {
    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $wslCfg)) { return }
    # Keys that are valid in /etc/wsl.conf but NOT in .wslconfig's
    # [wsl2] section. If we see any of these under [wsl2] we drop
    # them (they were almost certainly written by an older bootstrap
    # that confused the two config files, OR by a third-party tool).
    $bootSectionKeys = @('systemd', 'command', 'enabled', 'appendWindowsPath',
                         'default', 'options', 'mountFsTab',
                         'generateHosts', 'generateResolvConf', 'hostname')
    $lines     = Get-Content $wslCfg
    $inWsl2    = $false
    $newLines  = [System.Collections.Generic.List[string]]::new()
    $scrubbed  = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*\[wsl2\]\s*$') {
            $inWsl2 = $true
            $newLines.Add($line); continue
        }
        if ($line -match '^\s*\[') {
            # Any other section header closes [wsl2].
            $inWsl2 = $false
            $newLines.Add($line); continue
        }
        if ($inWsl2 -and $line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $Matches[1]
            if ($bootSectionKeys -contains $key) {
                Write-Log "wslconfig-repair: dropped misplaced '$key=' line from [wsl2] (belongs in /etc/wsl.conf, not .wslconfig)" "WARN"
                $scrubbed++
                continue
            }
        }
        $newLines.Add($line)
    }
    if ($scrubbed -gt 0) {
        Set-Content -Path $wslCfg -Value $newLines -Encoding UTF8
        Log-Ok ".wslconfig: scrubbed $scrubbed misplaced /etc/wsl.conf key(s) from [wsl2]"
    }
}

# Invoke a native command with stderr collected into the success stream
# but WITHOUT the "$ErrorActionPreference='Stop' + 2>&1" trap that
# causes a chatty stderr (git's "Cloning into ...", "From https://...",
# "Receiving objects: ...") to surface as a fatal exception. Returns
# the command's $LASTEXITCODE so callers can do their own checks. Kept
# minimal -- callers that want to inspect stdout/stderr can swap to
# Invoke-NativeQuiet's variable-capture variant below.
function Invoke-NativeQuiet {
    param([scriptblock]$Cmd)
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        & $Cmd 2>&1 | Out-Null
        $LASTEXITCODE
    }
}

# Post-bootstrap interactive menu. Called from the BootstrapOnly path
# in MAIN after Install-MiosLauncher has dropped the Start Menu /
# Desktop shortcuts -- the operator now has a fully-provisioned dev
# VM + Windows-side surface and chooses what to do next from here:
#
#   1. Continue to build      -> re-invoke this script with -BuildOnly
#                                so the OCI image build runs against
#                                the freshly-provisioned MiOS-DEV.
#   2. Change settings         -> open the configurator HTML for an
#                                interactive mios.toml edit pass
#                                (Open-Configurator).
#   3. System checks           -> run preflight.ps1 against the
#                                current state (MiOS-DEV health,
#                                mios.toml validation, .wslconfig,
#                                disk space, GHCR token).
#   4. Logs / reports          -> print the unified log path + the
#                                last 30 lines.
#   5. Close                   -> exit cleanly.
#
# Skipped automatically when -Unattended is set (CI / non-interactive).
function Show-PostBootstrapMenu {
    if ($Unattended) { return }
    Move-BelowDash
    # Resolve the actual WSL distro name once -- podman-machine prefixes
    # its distros with `podman-` (so the on-disk distro is podman-MiOS-DEV
    # by default), the auto-rename to plain MiOS-DEV is opt-in via
    # MIOS_RENAME_DISTRO=1, and operators commonly type `wsl -d MiOS-DEV`
    # only to hit `WSL_E_DISTRO_NOT_FOUND`. Print the live name so the
    # operator can copy-paste it.
    $devDistro = $null
    try {
        $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" |
                   ForEach-Object { ($_ -replace [char]0, '').Trim() } |
                   Where-Object { $_ }
        foreach ($c in @('MiOS-DEV','podman-MiOS-DEV','MiOS-BUILDER','podman-MiOS-BUILDER')) {
            if ($wslList -contains $c) { $devDistro = $c; break }
        }
    } catch {}
    while ($true) {
        # Clear the screen before every menu render so the canvas is
        # always clean -- whether this is the first render after
        # bootstrap OR a re-render after the operator picked an
        # option (wsl entry, configurator, etc.) and returned. Any
        # output from the previous option (wsl session output, build
        # tail, etc.) is wiped so the menu draws against blank space.
        try { Clear-Host } catch {}
        $W = $script:DW - 4    # leading "  │ " (4) + trailing " │" handled in row
        $hr   = "─" * $W
        $top  = "  ╭" + ("─── MiOS bootstrap complete " + ("─" * 99)).Substring(0, $W) + "╮"
        $div  = "  ├" + $hr + "┤"
        $bot  = "  ╰" + $hr + "╯"
        function _Row { param([string]$Inner)
            if ($Inner.Length -gt ($W - 2)) { $Inner = $Inner.Substring(0, $W - 2) }
            "  │ " + $Inner.PadRight($W - 2) + " │"
        }
        Write-Host ""
        Write-Host $top -ForegroundColor Green
        if ($devDistro) {
            Write-Host (_Row ("Dev distro:  {0}" -f $devDistro))                     -ForegroundColor DarkGray
            Write-Host (_Row ("Enter via:   wsl -d {0} --user mios" -f $devDistro))   -ForegroundColor DarkGray
            Write-Host $div -ForegroundColor Green
        }
        Write-Host (_Row "1) Continue to build (OCI image + deployables)")           -ForegroundColor White
        Write-Host (_Row "2) Change settings (open mios.toml in configurator)")       -ForegroundColor White
        Write-Host (_Row "3) System checks (preflight + dev VM health)")              -ForegroundColor White
        Write-Host (_Row "4) Logs / reports")                                         -ForegroundColor White
        Write-Host (_Row "5) Enter dev distro now (wsl -d ...)")                      -ForegroundColor White
        Write-Host (_Row "6) Close")                                                  -ForegroundColor White
        Write-Host $bot -ForegroundColor Green
        $choice = Read-Host "  Pick [1-6]"
        switch ($choice.Trim()) {
            '1' {
                # ── Windows -> MiOS-DEV handoff (per self-replication contract) ──
                # The Windows side has finished its STRICT scope: ack +
                # MiOS-DEV podman-machine setup. The actual build (OCI +
                # WSL2/g + Hyper-V + QEMU + Live-CD + USB + RAW) runs
                # INSIDE MiOS-DEV. We open a fresh Windows Terminal tab
                # hosting `wsl.exe -d <distro>` -- the MiOS-DEV tty
                # renders the dashboard there directly, no streaming
                # back across the WSL/Windows boundary.
                if (-not $devDistro) {
                    Write-Host "  ERROR: cannot find a MiOS-DEV WSL distro to hand off into." -ForegroundColor Red
                    Write-Host "         Tried: MiOS-DEV / podman-MiOS-DEV / MiOS-BUILDER / podman-MiOS-BUILDER" -ForegroundColor DarkGray
                    Write-Host "         Fix:   re-run the bootstrap to provision the dev distro." -ForegroundColor DarkGray
                    Write-Host ""
                    Write-Host "  Press Enter to return to the menu..." -ForegroundColor DarkGray -NoNewline
                    $null = Read-Host
                    continue
                }
                Write-Host "  -> Opening a new terminal into $devDistro for the build pipeline..." -ForegroundColor Cyan
                Write-Host "     The build dashboard renders in the MiOS-DEV tty (not on Windows)." -ForegroundColor DarkGray

                # The driver lives in the MiOS image at /usr/libexec/mios/mios-build-driver.
                # Phase 3's quadlet-overlay drops it into MiOS-DEV, so by the time the
                # operator picks "1" the file is present. We invoke it directly with a
                # SINGLE-LINE bash command -- multi-line heredocs survive PowerShell -> wt
                # -> wsl arg-parsing only if every layer quotes correctly, and previously
                # the chain shredded a heredoc into pseudo-args, surfacing as
                #     [error 2147942402 (0x80070002): The system cannot find the file specified.]
                # at wt.exe spawn time. Single-line, single-quoted-on-bash-side, no escapes.
                $driverPath = '/usr/libexec/mios/mios-build-driver'
                $fallback   = 'https://raw.githubusercontent.com/mios-dev/mios/main/usr/libexec/mios/mios-build-driver'
                $driverCmd  = "stty cols $($script:MiosCols) rows $($script:MiosRows) 2>/dev/null; if [ -x '$driverPath' ]; then exec bash '$driverPath'; else echo '[handoff] $driverPath not in $devDistro yet -- fetching latest...'; t=`$(mktemp); if curl -fsSL '$fallback' -o `"`$t`"; then chmod +x `"`$t`"; exec bash `"`$t`"; else echo '[handoff] FATAL: could not fetch driver from $fallback'; exec bash; fi; fi"
                # wt.exe (Windows Terminal) is the canonical multi-tab host; if it's
                # missing or the App Execution Alias is broken (per d6e8b66 / earlier
                # in this session), fall back to a plain Start-Process wsl.exe in a
                # fresh conhost window. Either way the build runs in MiOS-DEV.
                $wt = $null
                try {
                    $alias = Get-Command wt.exe -ErrorAction SilentlyContinue
                    if ($alias) { $wt = $alias.Source }
                } catch {}
                if (-not $wt) {
                    $uwp = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.WindowsTerminal_*" -Directory -ErrorAction SilentlyContinue |
                           Sort-Object LastWriteTime -Descending |
                           Select-Object -First 1
                    if ($uwp) {
                        $cand = Join-Path $uwp.FullName 'wt.exe'
                        if (Test-Path $cand) { $wt = $cand }
                    }
                }
                if ($wt) {
                    # Open a NEW Windows Terminal window at exactly 80x30 to
                    # match the dashboard frame (per feedback_mios_terminal_
                    # dimensions.md). `wt.exe --size W,H -- <cmdline>` sets
                    # the initial dimensions of a NEW wt window; `new-tab`
                    # inherits whatever the parent window already has, which
                    # is wrong for the build-pipeline tty.
                    & $wt --size "$($script:MiosCols),$($script:MiosRows)" --title "MiOS Build ($devDistro)" `
                        wsl.exe -d $devDistro --user mios --cd "~" -- bash -lc $driverCmd
                } else {
                    Write-Host "  wt.exe not found -- launching wsl.exe via a sized conhost window." -ForegroundColor Yellow
                    # conhost-side resize: spawn a pwsh window that resizes
                    # itself to mios.toml [terminal] dims before exec'ing
                    # wsl.exe. The dashboard frame then renders flush against
                    # the borders, matching the wt.exe path's geometry.
                    $_shCols = $script:MiosCols
                    $_shRows = $script:MiosRows
                    $_shScr  = $script:MiosScroll
                    $resizeShim = @"
try {
    [Console]::SetWindowSize($_shCols,$_shRows)
    [Console]::SetBufferSize($_shCols,$_shScr)
} catch {}
& wsl.exe -d '$devDistro' --user mios --cd '~' -- bash -lc @'
$driverCmd
'@
"@
                    Start-Process -FilePath 'pwsh.exe' `
                        -ArgumentList @('-NoProfile','-NoExit','-Command', $resizeShim)
                }
                Write-Host "  -> Build is running inside $devDistro. This Windows menu can close." -ForegroundColor Green
                Write-Host ""
                Write-Host "  Press Enter to return to the menu, or close this window..." -ForegroundColor DarkGray -NoNewline
                $null = Read-Host
            }
            '2' {
                if (Get-Command Open-Configurator -EA SilentlyContinue) {
                    Open-Configurator -RepoDir $MiosRepoDir
                } else {
                    $cfgHtml = Join-Path $MiosRepoDir 'usr/share/mios/configurator/mios.html'
                    if (Test-Path $cfgHtml) { Start-Process $cfgHtml }
                    else { Write-Host "  configurator HTML not found at $cfgHtml" -ForegroundColor Yellow }
                }
            }
            '3' {
                # preflight.ps1 is in mios.git, which is now overlaid AT
                # $MiosRepoDir root (M:\). Per the 2026-05-06 directive
                # "M:\ IS git", mios.git/preflight.ps1 lives at M:\preflight.ps1.
                # The legacy $MiosRepoDir\mios\preflight.ps1 fallback is kept
                # for operators on stale checkouts pre-overlay-refactor.
                $pflCandidates = @(
                    (Join-Path $MiosRepoDir 'preflight.ps1'),
                    (Join-Path $MiosRepoDir 'mios\preflight.ps1')
                )
                $pfl = $pflCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($pfl) {
                    Write-Host "  -> running preflight.ps1..." -ForegroundColor Cyan
                    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pfl
                } else {
                    Write-Host "  preflight.ps1 not found at any of:" -ForegroundColor Yellow
                    $pflCandidates | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                }
                Write-Host ""
                Write-Host "  Press Enter to return to the menu..." -ForegroundColor DarkGray -NoNewline
                $null = Read-Host
            }
            '4' {
                Write-Host ""
                Write-Host "  Unified log: $LogFile" -ForegroundColor Cyan
                Write-Host "  Log dir    : $MiosLogDir" -ForegroundColor Cyan
                Write-Host ""
                if (Test-Path $LogFile) {
                    Write-Host "  -- last 30 lines --" -ForegroundColor DarkGray
                    Get-Content -Tail 30 $LogFile | ForEach-Object { Write-Host "    $_" }
                }
                Write-Host ""
                Write-Host "  Press Enter to return to the menu..." -ForegroundColor DarkGray -NoNewline
                $null = Read-Host
            }
            '5' {
                if ($devDistro) {
                    # Resolve which user actually exists in the distro
                    # before launching. Rootful machine-os ships with
                    # `core` (and root) but no `mios` user until the
                    # OCI build completes -- in which case --user mios
                    # fails with WSL_E_USER_NOT_FOUND. Probe the
                    # distro's /etc/passwd to pick the first available
                    # account in priority order: mios > core > root.
                    $resolvedUser = 'root'
                    try {
                        $passwd = (& wsl.exe -d $devDistro --user root -- cat /etc/passwd 2>$null) -join "`n"
                        if ($passwd -match '(?m)^mios:') { $resolvedUser = 'mios' }
                        elseif ($passwd -match '(?m)^core:') { $resolvedUser = 'core' }
                    } catch {}
                    Write-Host "  -> launching wsl -d $devDistro --user $resolvedUser ..." -ForegroundColor Cyan
                    & wsl.exe -d $devDistro --user $resolvedUser
                } else {
                    Write-Host "  No registered MiOS dev distro found. Try `wsl --list` and enter manually." -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  Press Enter to return to the menu..." -ForegroundColor DarkGray -NoNewline
                    $null = Read-Host
                }
            }
            '6' { return }
            default { Write-Host "  Pick 1-6." -ForegroundColor Yellow }
        }
    }
}

function Read-Line([string]$Prompt, [string]$Default = "") {
    Move-BelowDash
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline
    if ($Unattended) { Write-Host $Default -ForegroundColor DarkGray; return $Default }
    $v = Read-Host
    # NB: Windows PowerShell 5.1 (the universal elevation fallback in
    # Get-MiOS.ps1's chain) doesn't support the PS7 ternary operator,
    # so this stays as a plain if/else.
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
}

function Read-Model([string]$Default = "qwen2.5-coder:7b") {
    # AI model menu prompt -- feature parity with build-mios.sh's
    # prompt_model. Drives MIOS_OLLAMA_BAKE_MODELS at build time and
    # MIOS_AI_MODEL in install.env at runtime. Same auto-accept
    # semantics as the rest of the Phase-6 prompts.
    Move-BelowDash
    Write-Host ""
    Write-Host "  AI model (Architectural Law 5 -- baked into the image):" -ForegroundColor White
    Write-Host "    1) qwen2.5-coder:7b   -- 12 GB RAM, code-specialized, default" -ForegroundColor DarkGray
    Write-Host "    2) qwen2.5-coder:14b  -- 24+ GB RAM, larger code reasoning" -ForegroundColor DarkGray
    Write-Host "    3) llama3.2:3b        -- 8 GB RAM, fast" -ForegroundColor DarkGray
    Write-Host "    4) custom             -- enter your own ollama model id" -ForegroundColor DarkGray
    $choice = Read-Line "Choice [1-4]" "1"
    switch ($choice) {
        "1"     { return "qwen2.5-coder:7b" }
        ""      { return "qwen2.5-coder:7b" }
        "2"     { return "qwen2.5-coder:14b" }
        "3"     { return "llama3.2:3b" }
        "4"     { return (Read-Line "Custom model id (e.g. mistral:7b)" $Default) }
        default { Write-Host "  invalid choice '$choice'; using default '$Default'" -ForegroundColor Yellow; return $Default }
    }
}

function Resolve-MiosTomlAiDefaults([string]$RepoDir) {
    # Read [ai].model / [ai].embed_model / [ai].bake_models out of the
    # unified mios.toml dotfile. Walks the same layered overlay
    # build-mios.sh's resolve_profile_layers walks, so per-host edits
    # to /etc/mios/mios.toml or ~/.config/mios/mios.toml seed the
    # interactive prompt without re-cloning. Pure regex parser; no TOML
    # library dependency. Returns a hashtable -- caller picks fields.
    $defaults = @{
        Model       = "qwen2.5-coder:7b"
        EmbedModel  = "nomic-embed-text"
        BakeModels  = "qwen2.5-coder:7b,nomic-embed-text"
    }
    $layers = @()
    foreach ($p in @(
        (Join-Path $RepoDir       "mios-bootstrap\mios.toml"),
        (Join-Path $env:APPDATA   "MiOS\mios.toml"),
        (Join-Path $env:USERPROFILE ".config\mios\mios.toml")
    )) { if (Test-Path $p) { $layers += $p } }

    foreach ($card in $layers) {
        try {
            $text = Get-Content -Raw -Path $card -ErrorAction Stop
        } catch { continue }
        # Extract the [ai] section body up to the next [section] header
        # or end-of-file. (?ms) for multiline + dot-matches-newline.
        $m = [regex]::Match($text, '(?ms)^\[ai\]\s*$(.*?)(?=^\[|\z)')
        if (-not $m.Success) { continue }
        $body = $m.Groups[1].Value
        foreach ($kv in @(
            @{ Key='model';        Slot='Model' },
            @{ Key='embed_model';  Slot='EmbedModel' },
            @{ Key='bake_models';  Slot='BakeModels' }
        )) {
            $rx = [regex]::new('(?m)^\s*' + [regex]::Escape($kv.Key) + '\s*=\s*"([^"]*)"')
            $hit = $rx.Match($body)
            if ($hit.Success) { $defaults[$kv.Slot] = $hit.Groups[1].Value }
        }
    }
    return $defaults
}

function Open-Configurator([string]$RepoDir) {
    # Open /usr/share/mios/configurator/mios.html for the operator to
    # edit the unified mios.toml. Canonical path: launch Epiphany IN
    # MiOS-DEV via WSLg so the configurator runs inside the same
    # environment that built it. The window appears on the Windows
    # desktop; the saved mios.toml lands in the dev VM's FHS-compliant
    # ~/Downloads (which IS the bootc-style home/user/Downloads
    # location, since MiOS-DEV mirrors the deployed MiOS layout). The
    # PowerShell side then picks up that file and overlays it as the
    # new source for the build pipeline -- so the operator's Epiphany
    # save IS the build's input.
    #
    # Falls back to the operator's default Windows browser if MiOS-DEV
    # isn't reachable or Epiphany is unavailable (covers fresh installs
    # before the dev distro has finished provisioning).
    if ($Unattended) { return }
    if ($env:MIOS_NO_CONFIGURATOR -eq "1") { return }

    $resp = Read-Line "Open MiOS configurator (Epiphany on MiOS-DEV via WSLg)?" "y"
    if ($resp -notmatch '^(y|yes|true|1)$') { return }

    $candidates = @(
        (Join-Path $RepoDir "mios\usr\share\mios\configurator\mios.html"),
        (Join-Path $MiosShareDir "system\usr\share\mios\configurator\mios.html"),
        (Join-Path $MiosShareDir "bootstrap\usr\share\mios\configurator\mios.html")
    )
    $html = $null
    foreach ($c in $candidates) { if (Test-Path $c) { $html = $c; break } }
    if (-not $html) {
        Write-Log "Configurator HTML not found locally -- skipping GUI step" "WARN"
        return
    }

    if (Open-ConfiguratorInDev -RepoDir $RepoDir -Html $html) { return }
    Log-Warn "MiOS-DEV / Epiphany unavailable -- falling back to Windows default browser"
    Open-ConfiguratorOnWindows -RepoDir $RepoDir -Html $html
}

function Open-ConfiguratorInDev([string]$RepoDir, [string]$Html) {
    # Probe MiOS-DEV (canonical name then legacy fallback)
    $wslDistro = $null
    foreach ($candidate in @("podman-$DevDistro", $DevDistro, "podman-$LegacyDevName")) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; break }
    }
    if (-not $wslDistro) { return $false }

    # Find the regular user (uid 1000) inside the dev VM. Podman machines
    # default to "user"; we honor whatever's actually there.
    $devUser = ((& wsl.exe -d $wslDistro --exec bash -c "getent passwd 1000 | cut -d: -f1" 2>$null) -join "").Trim()
    if (-not $devUser) { $devUser = "user" }

    # Convert C:\path\mios.html -> /mnt/c/path/mios.html
    $drive    = $Html.Substring(0,1).ToLower()
    $htmlWsl  = "/mnt/$drive" + ($Html.Substring(2) -replace '\\','/')

    # Resolve the seed mios.toml the configurator should pre-load. Pick
    # the highest-precedence existing layer; the bash side will copy it
    # into the dev VM's ~/Downloads/mios.toml as the working file.
    $sources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        (Join-Path $RepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $RepoDir "mios\usr\share\mios\mios.toml")
    )
    $seedToml = $null
    foreach ($s in $sources) { if (Test-Path $s) { $seedToml = $s; break } }
    $seedTomlWsl = ""
    if ($seedToml) {
        $sd = $seedToml.Substring(0,1).ToLower()
        $seedTomlWsl = "/mnt/$sd" + ($seedToml.Substring(2) -replace '\\','/')
    }

    Write-Host ""
    Write-Host "  Launching Epiphany on $wslDistro (user: $devUser) ..." -ForegroundColor Cyan
    Write-Host "  Configurator URL:    file://~/Downloads/mios-configurator.html" -ForegroundColor Gray
    Write-Host "  Working mios.toml:   /home/$devUser/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host "  WSLg routes the Epiphany window to the Windows desktop." -ForegroundColor Gray
    Write-Host ""

    $bashScript = @'
#!/usr/bin/env bash
# Generated by build-mios.ps1 / Open-ConfiguratorInDev.
set -euo pipefail
SRC_HTML="${1:?html path required}"
SEED_TOML="${2:-}"
USER_NAME="${3:-user}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
DL_DIR="$USER_HOME/Downloads"

sudo -u "$USER_NAME" install -d -m 0755 "$DL_DIR"

# Seed the working mios.toml in ~/Downloads. The configurator's "Pick file"
# button binds to it; "Save" overwrites in place (File System Access API)
# or, if the WebKit build lacks FSA, the operator triggers a download that
# also lands here.
if [[ -n "$SEED_TOML" && -r "$SEED_TOML" ]]; then
    sudo -u "$USER_NAME" install -m 0644 "$SEED_TOML" "$DL_DIR/mios.toml"
elif [[ ! -f "$DL_DIR/mios.toml" ]]; then
    sudo -u "$USER_NAME" touch "$DL_DIR/mios.toml"
fi

# Copy the HTML configurator into ~/Downloads where Epiphany's flatpak
# sandbox can read it via the home-portal default exposure.
sudo -u "$USER_NAME" install -m 0644 "$SRC_HTML" "$DL_DIR/mios-configurator.html"

# Ensure flathub remote + Epiphany flatpak are present (system-wide install).
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
if ! flatpak list --system --app --columns=application 2>/dev/null | grep -qx org.gnome.Epiphany; then
    echo "[configurator] installing org.gnome.Epiphany flatpak (one-time, ~250 MB)..."
    flatpak install --system --noninteractive --assumeyes --or-update flathub org.gnome.Epiphany \
        2>&1 | grep -E '^(Installing|Updating|Already|Error|Warning)' || true
fi

# Resolve the WSLg display sockets for the regular user. WSLg sets
# WAYLAND_DISPLAY=wayland-0 + DISPLAY=:0 in $HOME/.profile, but a
# sudo invocation strips those -- pull them from /run/user/1000.
RT="/run/user/$(id -u "$USER_NAME")"
[[ -d "$RT" ]] || RT="/tmp/runtime-$USER_NAME"
sudo -u "$USER_NAME" mkdir -p "$RT"

# Launch Epiphany detached. Browsers refuse to run as root, so we drop
# to the regular user. The flatpak run wrapper picks up the seat's
# Wayland socket via XDG_RUNTIME_DIR.
sudo -u "$USER_NAME" \
    XDG_RUNTIME_DIR="$RT" \
    DISPLAY=":0" \
    WAYLAND_DISPLAY="wayland-0" \
    PULSE_SERVER="unix:$RT/pulse/native" \
    flatpak run org.gnome.Epiphany \
        "file://$DL_DIR/mios-configurator.html" >/dev/null 2>&1 &
disown
echo "[configurator] Epiphany launched -- window should appear on the Windows desktop"
echo "[configurator] save target: $DL_DIR/mios.toml"
'@

    # PowerShell @'...'@ here-strings produce CRLF line endings on
    # Windows. The bash shebang then becomes "#!/usr/bin/env bash\r"
    # and `env` errors with "bash\r: No such file or directory".
    # Strip CR before base64-encoding so the script lands clean inside
    # the WSL distro.
    $bashScript = $bashScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bashScript))
    $stage = "set -e; echo '$b64' | base64 -d > /tmp/launch-config.sh && chmod +x /tmp/launch-config.sh; " +
             "/tmp/launch-config.sh '$htmlWsl' '$seedTomlWsl' '$devUser'"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "configurator: $_" }
    if ($LASTEXITCODE -ne 0) { Log-Warn "Epiphany launch returned rc=$LASTEXITCODE -- falling back"; return $false }

    Write-Host ""
    Write-Host "  In Epiphany on the Windows desktop:" -ForegroundColor Cyan
    Write-Host "    1. Click 'Pick file' (or 'Open (fallback)') -> ~/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host "    2. Edit identity / AI / desktop / flatpaks / quadlets" -ForegroundColor Gray
    Write-Host "    3. Click 'Save' -- the file overwrites ~/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host ""
    $null = Read-Host "  Press Enter when finished editing in Epiphany"

    # Pick up the saved mios.toml from MiOS-DEV's ~/Downloads and
    # promote it as the build source. We write to BOTH:
    #   1. %APPDATA%\MiOS\mios.toml   -- runtime per-user overlay
    #   2. mios-bootstrap clone root   -- seed-merge inputs to podman build
    # so the very next build/install pass uses the operator's edits.
    $tomlContent = (& wsl.exe -d $wslDistro --user $devUser --exec cat "/home/$devUser/Downloads/mios.toml" 2>$null) -join "`n"
    if ([string]::IsNullOrWhiteSpace($tomlContent)) {
        Log-Warn "No saved mios.toml found at /home/$devUser/Downloads/ -- continuing with vendor default"
        return $true
    }

    $userLayer = Join-Path $env:APPDATA "MiOS\mios.toml"
    $userDir   = Split-Path -Parent $userLayer
    if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($userLayer, $tomlContent, [Text.UTF8Encoding]::new($false))

    $bootstrapToml = Join-Path $RepoDir "mios-bootstrap\mios.toml"
    if (Test-Path (Split-Path -Parent $bootstrapToml)) {
        [System.IO.File]::WriteAllText($bootstrapToml, $tomlContent, [Text.UTF8Encoding]::new($false))
        Log-Ok "Saved mios.toml -> $userLayer + $bootstrapToml (build pipeline picks up on next pass)"
    } else {
        Log-Ok "Saved mios.toml -> $userLayer"
    }
    return $true
}

function Open-ConfiguratorOnWindows([string]$RepoDir, [string]$Html) {
    # Legacy / fallback path: run the configurator in the operator's
    # default Windows browser. Used when MiOS-DEV isn't reachable yet
    # (e.g. fresh install before Phase 3 finishes) or when WSLg is
    # disabled. Saves go through the Windows Downloads folder via the
    # standard <input type="file"> + downloads flow.
    $stagingDir = Join-Path $env:TEMP "mios-configurator"
    if (-not (Test-Path $stagingDir)) { New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null }
    $stamp   = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
    $staging = Join-Path $stagingDir "mios-$stamp.toml"
    $sources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        (Join-Path $RepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $RepoDir "mios\usr\share\mios\mios.toml")
    )
    $src = $null
    foreach ($s in $sources) { if (Test-Path $s) { $src = $s; break } }
    if ($src) { Copy-Item -Path $src -Destination $staging -Force }
    else      { New-Item -ItemType File -Path $staging -Force | Out-Null }

    $stagingForUrl = ($staging -replace '\\', '/' -replace ' ', '%20')
    $url = "file:///$($Html -replace '\\', '/' -replace ' ', '%20')?suggested_path=$stagingForUrl"
    Write-Host ""
    Write-Host "  Opening configurator: $url" -ForegroundColor Cyan
    Write-Host "  Staging file:         $staging" -ForegroundColor Cyan
    Write-Host ""
    try { Start-Process $url -ErrorAction Stop }
    catch { Log-Warn "Browser launch failed: $($_.Exception.Message). Open manually: $url" }
    $null = Read-Host "  Press Enter when finished editing in the browser"

    if ((Test-Path $staging) -and ((Get-Item $staging).Length -gt 0)) {
        $userLayer = Join-Path $env:APPDATA "MiOS\mios.toml"
        $userDir   = Split-Path -Parent $userLayer
        if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
        Copy-Item -Path $staging -Destination $userLayer -Force
        $bootstrapToml = Join-Path $RepoDir "mios-bootstrap\mios.toml"
        if (Test-Path (Split-Path -Parent $bootstrapToml)) {
            Copy-Item -Path $staging -Destination $bootstrapToml -Force
        }
        Log-Ok "Staged $staging -> $userLayer (+ bootstrap clone if present)"
    }
}

function Read-Password([string]$Prompt = "Password") {
    Move-BelowDash
    Write-Host "  $Prompt [default: mios]: " -NoNewline -ForegroundColor White
    if ($Unattended) { Write-Host "(default)" -ForegroundColor DarkGray; return "" }
    if ($PSVersionTable.PSVersion.Major -ge 7) { return (Read-Host -MaskInput) }
    $ss = Read-Host -AsSecureString
    $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-PasswordHash([string]$Plain) {
    if ($Plain -eq "mios" -or [string]::IsNullOrWhiteSpace($Plain)) {
        return '$6$miosmios0$ShHuf/TnPoEmEX//L9mrNNuP7kZ6l9aj/qV9WFj5LnjL3lunhKEwnJfY6tvlJbRiWkLTtPmdwCgWeOQB9eXuW.'
    }
    $salt = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $h = (& wsl.exe -d $d --exec openssl passwd -6 -salt $salt $Plain 2>$null) -join ""
            if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
        } catch {}
    }
    # Dev-distro shell (works pre- AND post-rename via Invoke-DistroSh
    # auto-detect): wsl-direct on MiOS-DEV, podman-machine-ssh on
    # podman-MiOS-DEV. -NoSudo because openssl needs no privilege.
    try {
        $h = (Invoke-DistroSh -Bash "openssl passwd -6 -salt '$salt' '$Plain'" -MachineName $BuilderDistro -NoSudo 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    try {
        $h = (& podman run --rm docker.io/library/alpine:latest sh -c "apk add -q openssl && openssl passwd -6 -salt '$salt' '$Plain'" 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    throw "Cannot generate sha512crypt hash -- install openssl or run from a distro."
}

function Get-Hardware {
    # Detect host capability: full CPU / RAM / disk / GPU surface.
    # Then apply mios.toml [bootstrap.dev_vm.host_reserve] to compute
    # the dev-VM allocation. The dev VM IS the builder (memory:
    # feedback_mios_dev_is_the_builder), so we err maximalist — give
    # it every resource the host can spare while keeping Windows
    # responsive.
    #
    # Override sources (highest precedence first):
    #   1. $env:MIOS_DEV_VM_{CPUS,MEMORY_MB,DISK_GB} — explicit pin
    #      from mios.toml [bootstrap.dev_vm].* if not set to "max"
    #   2. $env:MIOS_DEV_VM_*_RESERVE_* — host reserve policy from
    #      mios.toml [bootstrap.dev_vm.host_reserve]
    #   3. Hardcoded fallbacks below
    $hostRamGB = try { [math]::Round((Get-CimInstance Win32_PhysicalMemory|Measure-Object Capacity -Sum).Sum/1GB) } catch { 16 }
    # OS-reported RAM (bytes) -- this is what podman validates against; may be less than nominal GB count
    $osTotalRamMB = try { [math]::Floor((Get-CimInstance Win32_ComputerSystem -EA Stop).TotalPhysicalMemory / 1MB) } catch { $hostRamGB * 1024 }
    $hostCpus = [Environment]::ProcessorCount

    # GPU surface: enumerate every non-Microsoft-Basic display adapter.
    # The dev VM (WSL2) automatically gets host-GPU access via /dev/dxg
    # (WSLg) for compute; this enumeration drives base-image selection
    # and is reflected in the dispatched manifest.
    $allGpus = try {
        Get-CimInstance Win32_VideoController -EA Stop |
            Where-Object { $_.Name -notmatch "Microsoft Basic|Microsoft Hyper-V Video|Remote Display" }
    } catch { @() }
    $gpu       = $allGpus | Select-Object -First 1
    $gpuName   = if ($gpu) { $gpu.Name } else { "Unknown" }
    $gpuNames  = ($allGpus | ForEach-Object { $_.Name }) -join ', '
    $hasNvidia = $gpuNames -match "NVIDIA|GeForce|Quadro|RTX|GTX|Tesla"
    $hasAmd    = $gpuNames -match "AMD|Radeon|RX |R[5-9] |Vega|Navi"
    $hasIntel  = $gpuNames -match "Intel|Iris|UHD Graphics|HD Graphics"
    # Base image variants resolve through mios.toml [image].base_nvidia /
    # base_no_nvidia (SSOT). Operators can swap upstreams (ucore-minimal,
    # fedora-bootc, etc.) via mios.html without touching code.
    $_baseNvidia   = Get-MiosTomlValue -Section 'image' -Key 'base_nvidia'    -Default 'ghcr.io/ublue-os/ucore-hci:stable-nvidia'
    $_baseNoNvidia = Get-MiosTomlValue -Section 'image' -Key 'base_no_nvidia' -Default 'ghcr.io/ublue-os/ucore-hci:stable'
    $baseImage     = if ($hasNvidia) { $_baseNvidia } else { $_baseNoNvidia }
    # AI model auto-pick by host RAM. Thresholds + model IDs from mios.toml
    # [ai.host_thresholds] (NEW). Operators tune the cutoffs or swap to a
    # different family (mistral / llama / etc.) via mios.html.
    $_aiBig    = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'big_ram_gb'        -Default 32
    $_aiMid    = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'mid_ram_gb'        -Default 12
    $_aiBigM   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'big_ram_model'     -Default 'qwen2.5-coder:14b'
    $_aiMidM   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'mid_ram_model'     -Default 'qwen2.5-coder:7b'
    $_aiSmallM = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'small_ram_model'   -Default 'phi4-mini:3.8b-q4_K_M'
    $aiModel   = if ($hostRamGB -ge $_aiBig) { $_aiBigM } elseif ($hostRamGB -ge $_aiMid) { $_aiMidM } else { $_aiSmallM }

    # Free space on the data disk (M:\ if provisioned, else C:\). The
    # dev VM's VHDX lives on M:\ when Initialize-MiosDataDisk has run.
    $diskLetter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER } else { 'M' }
    $diskFreeGB = try { [math]::Floor((Get-PSDrive $diskLetter -EA Stop).Free/1GB) } catch {
        try { [math]::Floor((Get-PSDrive C -EA Stop).Free/1GB) } catch { 200 }
    }

    # Read host_reserve policy from env (synthesized from
    # mios.toml by tools/lib/userenv.sh); fall back to sane defaults.
    $cpuReservePct = if ($env:MIOS_DEV_VM_CPU_RESERVE_PCT)    { [int]$env:MIOS_DEV_VM_CPU_RESERVE_PCT }    else { 15 }
    $cpuReserveMin = if ($env:MIOS_DEV_VM_CPU_RESERVE_MIN)    { [int]$env:MIOS_DEV_VM_CPU_RESERVE_MIN }    else { 2 }
    $memReservePct = if ($env:MIOS_DEV_VM_MEMORY_RESERVE_PCT) { [int]$env:MIOS_DEV_VM_MEMORY_RESERVE_PCT } else { 15 }
    $memReserveGB  = if ($env:MIOS_DEV_VM_MEMORY_RESERVE_GB)  { [int]$env:MIOS_DEV_VM_MEMORY_RESERVE_GB }  else { 4 }
    $diskReserveGB = if ($env:MIOS_DEV_VM_DISK_RESERVE_GB)    { [int]$env:MIOS_DEV_VM_DISK_RESERVE_GB }    else { 32 }

    # Compute maximalist dev-VM allocation = host - reserve.
    $reservedCpus = [math]::Max($cpuReserveMin, [math]::Floor($hostCpus * $cpuReservePct / 100))
    $devCpus = [math]::Max(1, $hostCpus - $reservedCpus)
    $reservedRamGB = [math]::Max($memReserveGB, [math]::Floor($hostRamGB * $memReservePct / 100))
    $devRamGB = [math]::Max(4, $hostRamGB - $reservedRamGB)
    $devDiskGB = [math]::Max(80, $diskFreeGB - $diskReserveGB)

    # Apply explicit pin overrides from mios.toml [bootstrap.dev_vm].*
    # (set to "max" or empty/unset to use the computed maximalist value).
    if ($env:MIOS_DEV_VM_CPUS      -and $env:MIOS_DEV_VM_CPUS      -notmatch '^(max|0|)$') { $devCpus   = [int]$env:MIOS_DEV_VM_CPUS      }
    if ($env:MIOS_DEV_VM_MEMORY_MB -and $env:MIOS_DEV_VM_MEMORY_MB -notmatch '^(max|0|)$') { $devRamGB  = [math]::Max(4, [math]::Floor([int]$env:MIOS_DEV_VM_MEMORY_MB / 1024)) }
    if ($env:MIOS_DEV_VM_DISK_GB   -and $env:MIOS_DEV_VM_DISK_GB   -notmatch '^(max|0|)$') { $devDiskGB = [int]$env:MIOS_DEV_VM_DISK_GB   }

    Write-Log "Get-Hardware: host=${hostCpus}c/${hostRamGB}GB/${diskFreeGB}GB  reserve=${reservedCpus}c/${reservedRamGB}GB/${diskReserveGB}GB  dev-vm=${devCpus}c/${devRamGB}GB/${devDiskGB}GB  gpu=[$gpuNames]"

    return @{
        # Host-detected (informational)
        HostRamGB    = $hostRamGB
        HostCpus     = $hostCpus
        OsTotalRamMB = $osTotalRamMB
        AllGpus      = $allGpus
        GpuNames     = $gpuNames
        GpuName      = $gpuName
        HasNvidia    = $hasNvidia
        HasAmd       = $hasAmd
        HasIntel     = $hasIntel
        # Dispatched dev-VM allocation (maximalist - host_reserve)
        Cpus         = $devCpus
        RamGB        = $devRamGB
        DiskGB       = $devDiskGB
        # Image / model selection
        BaseImage    = $baseImage
        AiModel      = $aiModel
    }
}

function Find-ActiveDistro {
    # Check legacy WSL distros ('MiOS' already applied via bootc switch, has /Justfile)
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $r = (& wsl.exe -d $d --exec bash -c "test -f /Justfile && echo ready" 2>$null) -join ""
            if ($r.Trim() -eq "ready") { return $d }
        } catch {}
    }
    # Check if BuilderDistro is a running Podman machine (machine-os: no /Justfile but can still build)
    try {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "(?i)^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { return $BuilderDistro }
    } catch {}
    return $null
}

function Sync-RepoToDistro([string]$Distro, [string]$WinPath) {
    $wsl = ConvertTo-WslPath $WinPath
    # Try direct WSL file:// fetch (works when Windows drive is mounted at /mnt/)
    try {
        & wsl.exe -d $Distro --user root --exec bash -c `
            "git -C / fetch 'file://$wsl' main 2>/dev/null && git -C / reset --hard FETCH_HEAD 2>/dev/null"
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    # Dev-distro fallback: Windows drive not mounted; pull from GitHub
    # origin instead. Routed through Invoke-DistroSh so it works in both
    # the pre-rename (podman-machine-ssh) and post-rename (wsl-direct)
    # states.
    try {
        Invoke-DistroSh -Bash "cd / && git fetch --depth=1 origin main 2>/dev/null && git reset --hard FETCH_HEAD 2>/dev/null" -MachineName $Distro 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Initialize-MiosDataDisk {
    <#
    .SYNOPSIS
        Shrink C: by exactly $ShrinkMB and create a dedicated MiOS-DEV partition
        in the freed space. Redirect podman-machine storage onto that partition
        so MiOS-DEV's VHDX (which internally hosts the ext4 root) lives on the
        new drive end-to-end.

    .NOTES
        WSL2 STORES DISTROS AS VHDX FILES. The VHDX format requires a Windows-
        accessible host filesystem (NTFS or ReFS) -- a raw ext4 host partition
        cannot host a VHDX. The new partition is therefore formatted NTFS, and
        MiOS-DEV's Linux root inside the VHDX *is* ext4 (mkfs'd by WSL2 at first
        boot). Result: the operator's "ext partition for MiOS-DEV" requirement
        is satisfied at the WSL/Linux layer, with the host wrapper as the thin
        NTFS shell that WSL2 strictly requires.

        Idempotent: a partition labeled $VolumeLabel on $DriveLetter is treated
        as already-initialized and the function returns without shrinking again.
    #>
    param(
        [int]$ShrinkMB     = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'shrink_mb' -Default 262656),
        [string]$DriveLetter = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'drive_letter' -Default 'M'),
        [string]$VolumeLabel = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'volume_label' -Default 'MIOS-DEV')
    )

    # Step description from mios.toml [messages.steps].disk_sizing_template
    # (SSOT). {placeholder} substitution at render time.
    Set-Step ((Get-MiosTomlValue -Section 'messages.steps' -Key 'disk_sizing_template' -Default 'Sizing MiOS data disk ({mb} MB on {drive}:)...') -replace '\{mb\}', $ShrinkMB -replace '\{drive\}', $DriveLetter)

    # 0. Already-initialized? Skip.
    $existing = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existing -and $existing.FileSystemLabel -eq $VolumeLabel) {
        $_sgb = [math]::Round($existing.Size/1GB,1)
        Log-Ok ((Get-MiosTomlValue -Section 'messages.steps' -Key 'disk_already_template' -Default 'MiOS data disk already on {drive}: ({size_gb} GB, NTFS)') -replace '\{drive\}', $DriveLetter -replace '\{size_gb\}', $_sgb)
        return "${DriveLetter}:\"
    }
    if ($existing) {
        throw "Drive ${DriveLetter}: already exists with label '$($existing.FileSystemLabel)' -- pass a different -DriveLetter or remove the volume manually"
    }

    # 1. Locate C: partition + its disk
    $sysLetter = ([Environment]::GetEnvironmentVariable('SystemDrive')).TrimEnd(':')
    $cPart = Get-Partition -DriveLetter $sysLetter
    $supported = Get-PartitionSupportedSize -DriveLetter $sysLetter
    $shrinkBytes = [int64]$ShrinkMB * 1MB
    $newCSize = $cPart.Size - $shrinkBytes

    if ($shrinkBytes -gt ($cPart.Size - $supported.SizeMin)) {
        throw "Cannot shrink ${sysLetter}: by $ShrinkMB MB. Min partition size is $([math]::Round($supported.SizeMin/1GB,1)) GB; current $([math]::Round($cPart.Size/1GB,1)) GB; max shrinkable $([math]::Round(($cPart.Size-$supported.SizeMin)/1GB,1)) GB. Free space on ${sysLetter}: or move pagefile/hibernation file to allow more shrink."
    }

    # 2. Free space on disk after shrink (for new partition placement)
    $disk = Get-Disk -Number $cPart.DiskNumber
    if ($disk.PartitionStyle -ne 'GPT' -and $disk.PartitionStyle -ne 'MBR') {
        throw "Disk $($disk.Number) has unsupported partition style '$($disk.PartitionStyle)'"
    }

    # 3. Shrink C:
    Set-Step "Shrinking ${sysLetter}: $([math]::Round($cPart.Size/1GB,1))GB -> $([math]::Round($newCSize/1GB,1))GB ..."
    Resize-Partition -DriveLetter $sysLetter -Size $newCSize -ErrorAction Stop
    Log-Ok "${sysLetter}: shrunk by $ShrinkMB MB"

    # 4. Create new partition in freed space, exact size match
    Set-Step "Creating $VolumeLabel partition (${ShrinkMB}MB) on disk $($disk.Number)..."
    $newPart = New-Partition -DiskNumber $disk.Number -Size $shrinkBytes -DriveLetter $DriveLetter -ErrorAction Stop

    # 5. Format NTFS (host wrapper -- VHDX inside carries ext4)
    Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel $VolumeLabel `
        -AllocationUnitSize 4096 -Confirm:$false -Force | Out-Null
    Log-Ok "${DriveLetter}: created (${ShrinkMB}MB NTFS, label=$VolumeLabel) -- VHDX inside hosts ext4"

    return "${DriveLetter}:\"
}

function Set-PodmanMachineStorageOn {
    <#
    .SYNOPSIS
        Symlink ALL candidate podman-machine storage paths to
        $DataRoot\podman\machine BEFORE `podman machine init` runs,
        so MiOS-DEV's VHDX is created on the data disk from the start
        (no post-hoc move dance, no risk of leaving 100s of GBs of
        machine state on C:\).

    .NOTES
        Symlinks (mklink /D), NOT junctions (mklink /J). Verified
        empirically 2026-05-06 against podman 5.8.2 + WSL provider:

            /J -> `podman machine ls` FAILS with
                  "mkdir <path>: Cannot create a file when that file
                   already exists" (Go's os.Mkdir doesn't fall through
                  on EEXIST when the path is a junction)
            /D -> `podman machine ls` works, `init` works, files land
                  on the symlink target

        Idempotent: an existing correct symlink is left alone; an
        existing legacy junction is replaced.

        Covers all three default machineDir locations podman has used
        across versions:
          * %LOCALAPPDATA%\containers\podman\machine  (Windows-style)
          * %USERPROFILE%\.local\share\containers\podman\machine
            (Linux/XDG-style -- this is what podman 5.8.2 ACTUALLY
            uses on Windows; the reason the old single-path
            %LOCALAPPDATA% link did nothing useful)
          * %PROGRAMDATA%\containers\podman\machine  (machine-wide
            install fallback)

        Get-MiOS.ps1's Set-PodmanMachineStorageOnM does the same work
        before this function runs; this is a defensive idempotent
        re-run in case the operator launched build-mios.ps1
        directly.
    #>
    param([Parameter(Mandatory)][string]$DataRoot)

    $targetDir = Join-Path $DataRoot 'podman\machine'
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'containers\podman\machine'),
        (Join-Path $env:USERPROFILE  '.local\share\containers\podman\machine'),
        (Join-Path $env:PROGRAMDATA  'containers\podman\machine')
    )

    foreach ($defaultDir in $candidates) {
        if (-not $defaultDir) { continue }
        if (Test-Path $defaultDir) {
            $item = Get-Item $defaultDir -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $current   = ($item.Target -join '').TrimStart('\??\')
                $isSymlink = $item.LinkType -eq 'SymbolicLink'
                if ($current -ieq $targetDir -and $isSymlink) {
                    Log-Ok "podman-machine storage already symlinked -> $targetDir ($defaultDir)"
                    continue
                }
                # Wrong target OR right target wrong link type (legacy
                # junction). Remove + relink as symlink below.
                if ($current -ieq $targetDir -and -not $isSymlink) {
                    Log-Warn "$defaultDir is a JUNCTION (legacy) -- recreating as symlink so podman 5.8.2 stops failing on os.Mkdir"
                }
                cmd /c "rmdir `"$defaultDir`"" 2>$null | Out-Null
            } else {
                # Real directory -- move children to target then remove.
                Set-Step "Migrating existing podman-machine state to $targetDir ..."
                Get-ChildItem $defaultDir -Force -ErrorAction SilentlyContinue |
                    Move-Item -Destination $targetDir -Force -ErrorAction SilentlyContinue
                Remove-Item $defaultDir -Force -Recurse -ErrorAction SilentlyContinue
            }
        } else {
            $parent = Split-Path $defaultDir -Parent
            if (-not (Test-Path $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
        }

        # Create the symlink (mklink /D, NOT /J -- see .NOTES above).
        $rc = (cmd /c "mklink /D `"$defaultDir`" `"$targetDir`"" 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Log-Ok "podman-machine storage symlinked $defaultDir -> $targetDir"
        } else {
            Log-Warn "mklink /D $defaultDir -> $targetDir failed: $rc"
        }
    }
}

function Get-PodmanMachineOsImage {
    # Pre-stage a podman-machine OCI image via direct HTTPS, bypassing
    # `podman machine init`'s pull-extraction pipeline. On podman 5.8.2
    # for Windows + WSL provider that pipeline fails with:
    #     Error: failed to pull quay.io/podman/machine-os@sha256:<...>:
    #            The system cannot find the path specified.
    # for ANY ref (6.0, 5.8, bundled default). Direct GET against the
    # OCI Distribution API works fine -- the bug is in podman's own
    # cache write step on Windows. Pre-staging the layer ourselves and
    # passing the result to `--image <local-path>` skips the broken
    # path entirely.
    #
    # Returns the local file path on success; throws on failure. The
    # output filename follows the layer's
    # `org.opencontainers.image.title` annotation
    # (e.g. "podman-machine.x86_64.wsl.tar.zst") so podman recognizes
    # the format from the extension alone.
    [CmdletBinding()]
    param(
        # Default Repo + Tag resolve through mios.toml [image].machine_os_repo
        # / .machine_os_tag (SSOT). Hardcoded fallbacks below are vendor
        # defaults only -- operators bump the tag (6.0 -> 6.1) via mios.html.
        [string]$Repo = (Get-MiosTomlValue -Section 'image' -Key 'machine_os_repo' -Default 'quay.io/podman/machine-os'),
        [string]$Tag  = (Get-MiosTomlValue -Section 'image' -Key 'machine_os_tag'  -Default '6.0'),
        [string]$Architecture = 'x86_64',
        [string]$DiskType = 'wsl',
        [Parameter(Mandatory)] [string]$CacheDir
    )

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $slash    = $Repo.IndexOf('/')
    $registry = $Repo.Substring(0, $slash)
    $name     = $Repo.Substring($slash + 1)
    $base     = "https://$registry/v2/$name"

    # ── Step 1: image index ───────────────────────────────────────────
    # PowerShell 5.1's Invoke-WebRequest -UseBasicParsing returns
    # .Content as a byte[] for non-text content types (anything not
    # in its hard-coded text list -- application/json IS text but
    # application/vnd.oci.image.index.v1+json is NOT, despite the
    # `+json` suffix). Piping the byte[] to ConvertFrom-Json
    # stringifies the array to "123 34 115 ..." and produces an empty
    # object -- which is exactly the "got mediaType=" symptom seen in
    # the 16:35 log. Force UTF-8 decode so ConvertFrom-Json sees the
    # actual JSON text.
    Set-Step "Resolving $Repo`:$Tag (OCI index)"
    $idxResp = Invoke-WebRequest -UseBasicParsing -Uri "$base/manifests/$Tag" `
        -Headers @{ 'Accept' = 'application/vnd.oci.image.index.v1+json' } `
        -ErrorAction Stop
    $idxJson = if ($idxResp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($idxResp.Content)
    } else { [string]$idxResp.Content }
    $index = $idxJson | ConvertFrom-Json
    if ($index.mediaType -notlike '*image.index*' -and $index.mediaType -notlike '*manifest.list*') {
        throw "Expected OCI image index at $Repo`:$Tag, got mediaType=$($index.mediaType)"
    }

    # ── Step 2: pick the platform manifest ────────────────────────────
    $pm = $index.manifests | Where-Object {
        $_.platform.architecture -eq $Architecture -and
        $_.annotations.disktype -eq $DiskType
    } | Select-Object -First 1
    if (-not $pm) {
        $available = ($index.manifests |
            ForEach-Object { "$($_.platform.architecture)/$($_.annotations.disktype)" }) -join ', '
        throw "No platform manifest for $Architecture/$DiskType in $Repo`:$Tag (available: $available)"
    }

    # ── Step 3: platform manifest -> single layer ─────────────────────
    # Same byte[]-vs-string trap as Step 1 -- decode explicitly.
    $pmResp = Invoke-WebRequest -UseBasicParsing -Uri "$base/manifests/$($pm.digest)" `
        -Headers @{ 'Accept' = 'application/vnd.oci.image.manifest.v1+json' } `
        -ErrorAction Stop
    $pmJson = if ($pmResp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($pmResp.Content)
    } else { [string]$pmResp.Content }
    $manifest = $pmJson | ConvertFrom-Json
    $layer = $manifest.layers | Select-Object -First 1
    if (-not $layer) {
        throw "Platform manifest $($pm.digest) has no layers"
    }

    $title = $layer.annotations.'org.opencontainers.image.title'
    if (-not $title) { $title = "$Architecture-$DiskType-$Tag.tar.zst" }
    $localPath      = Join-Path $CacheDir $title
    $expectedDigest = ($layer.digest -replace '^sha256:', '').ToLower()

    # ── Step 4: cache-hit short-circuit ───────────────────────────────
    if (Test-Path $localPath) {
        $existingHash = (Get-FileHash -Path $localPath -Algorithm SHA256).Hash.ToLower()
        if ($existingHash -eq $expectedDigest) {
            Log-Ok "Reusing cached machine-os layer: $localPath"
            return $localPath
        }
        Log-Warn "Cached machine-os layer hash mismatch -- re-downloading"
        Remove-Item $localPath -Force -ErrorAction SilentlyContinue
    }

    # ── Step 5: streamed download via System.Net.Http (no RAM buffer) ─
    $sizeMB  = [math]::Round($layer.size / 1MB, 1)
    Log-Ok "Downloading machine-os layer ($sizeMB MB) -> $localPath"
    $blobUrl = "$base/blobs/$($layer.digest)"
    $tmpPath = "$localPath.tmp"

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.TimeSpan]::FromMinutes(30)
    try {
        $req  = [System.Net.Http.HttpRequestMessage]::new('Get', $blobUrl)
        $resp = $client.SendAsync(
            $req,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "HTTP $([int]$resp.StatusCode) fetching $blobUrl"
        }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $file   = [System.IO.File]::Create($tmpPath)
        try {
            $buf       = [byte[]]::new(1048576)  # 1 MiB chunks
            $total     = 0L
            $lastTickMB = -16L
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $file.Write($buf, 0, $n)
                $total += $n
                $totalMB = [int]($total / 1MB)
                if ($totalMB - $lastTickMB -ge 16) {
                    Set-Step "Downloading machine-os layer: $totalMB / $sizeMB MB"
                    Show-Dashboard
                    $lastTickMB = $totalMB
                }
            }
        } finally {
            $file.Dispose()
            $stream.Dispose()
        }
    } finally {
        $client.Dispose()
    }

    # ── Step 6: SHA256 verify ─────────────────────────────────────────
    Set-Step "Verifying machine-os layer SHA256"
    $actualHash = (Get-FileHash -Path $tmpPath -Algorithm SHA256).Hash.ToLower()
    if ($actualHash -ne $expectedDigest) {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        throw "machine-os layer SHA256 mismatch: expected $expectedDigest, got $actualHash"
    }

    Move-Item -Path $tmpPath -Destination $localPath -Force
    Log-Ok "machine-os layer staged: $localPath"
    return $localPath
}

function Move-PodmanWslDistroToM {
    # Force the podman-managed WSL2 distro VHDX onto M:\. WSL2 ignores
    # XDG_DATA_HOME; it stores VHDXs at the path passed to `wsl --import`
    # (or under %LOCALAPPDATA%\Packages\<distro-id>\LocalState if podman
    # didn't pass an explicit path). The registry HKCU\...\Lxss\<guid>\
    # BasePath records where each distro's ext4.vhdx actually lives.
    #
    # Procedure (idempotent, only fires when BasePath is NOT under M:\):
    #   1. Read BasePath from registry
    #   2. If already on M:\ -> no-op + log
    #   3. Else: wsl --shutdown, export tar, unregister, import to
    #      M:\MiOS\distros\<distroname> -- VHDX bytes now live on M:\
    #
    # podman picks the distro back up because podman locates it by name
    # via wsl.exe -- the import path doesn't matter to podman's
    # connection state.
    param(
        [Parameter(Mandatory)] [string] $DistroName,
        # Default uses $script:MiosDistroDir which already centralizes
        # the distro-storage root across admin/user/data-disk modes
        # (set in build-mios.ps1's "Paths & constants" block + updated
        # by Update-MiosInstallPaths when M:\ comes online).
        [string] $TargetRoot = $(if ($script:MiosDistroDir) { $script:MiosDistroDir } else { 'M:\MiOS\distros' })
    )
    # podman prefixes its WSL distros with `podman-`. Resolve the actual
    # registered name (callers pass either form -- `MiOS-DEV` or
    # `podman-MiOS-DEV`). WSL distro names are case-sensitive in the
    # registry; iterate Lxss/ subkeys and match.
    $candidates = @($DistroName, "podman-$DistroName")
    $lxssRoot   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxssRoot)) {
        Log-Warn "Move-PodmanWslDistroToM: WSL Lxss registry key missing -- skipping migration"
        return
    }
    $matched = $null
    foreach ($sub in (Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $dn = $props.DistributionName
        if (-not $dn) { continue }
        if ($candidates -contains $dn) {
            $matched = [pscustomobject]@{
                DistributionName = $dn
                BasePath         = $props.BasePath
                RegPath          = $sub.PSPath
            }
            break
        }
    }
    if (-not $matched) {
        Log-Warn "Move-PodmanWslDistroToM: distro $DistroName not registered -- nothing to migrate"
        return
    }
    $current = ($matched.BasePath -replace '^\\\\\?\\','').TrimEnd('\')
    if ($current -match '^[Mm]:\\') {
        Log-Ok "podman-WSL distro $($matched.DistributionName) already on M:\ ($current) -- no migration needed"
        return
    }
    # Migrate.
    Set-Step "Migrating $($matched.DistributionName) WSL distro from $current onto M:\..."
    if (-not (Test-Path $TargetRoot)) {
        New-Item -ItemType Directory -Path $TargetRoot -Force -ErrorAction Stop | Out-Null
    }
    $newPath = Join-Path $TargetRoot $matched.DistributionName
    if (Test-Path $newPath) {
        # Stale dir from a previous failed migration -- safe to wipe
        # because the registered distro still points at $current.
        Log-Warn "Removing stale $newPath before re-import"
        Remove-Item -LiteralPath $newPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    & wsl.exe --shutdown 2>&1 | ForEach-Object { Write-Log "wsl-shutdown: $_" }
    $tmpTar = Join-Path $env:TEMP "mios-podman-migrate-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar"
    try {
        Log-Ok "Exporting $($matched.DistributionName) -> $tmpTar"
        & wsl.exe --export $matched.DistributionName $tmpTar 2>&1 | ForEach-Object { Write-Log "wsl-export: $_" }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpTar)) {
            Log-Warn "wsl --export $($matched.DistributionName) failed -- aborting M:\ migration"
            return
        }
        & wsl.exe --unregister $matched.DistributionName 2>&1 | ForEach-Object { Write-Log "wsl-unregister: $_" }
        Log-Ok "Re-importing $($matched.DistributionName) at $newPath"
        & wsl.exe --import $matched.DistributionName $newPath $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import-M: $_" }
        if ($LASTEXITCODE -eq 0) {
            Log-Ok "podman-WSL distro $($matched.DistributionName) is now on M:\ ($newPath)"
        } else {
            Log-Warn "wsl --import to M:\ failed; falling back to original location"
            & wsl.exe --import $matched.DistributionName $current $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import-fallback: $_" }
        }
    } finally {
        if (Test-Path $tmpTar) { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue }
    }
}

function New-BuilderDistro([hashtable]$HW) {
    Set-Step "Initializing $DevDistro ($($HW.Cpus) CPUs / $($HW.RamGB)GB / $($HW.DiskGB)GB disk)"
    # Redirect podman-machine state (the VHDX, registry, configs) onto
    # M:\ when M:\ is mounted -- no admin required. Podman honors
    # XDG_DATA_HOME for storage paths on Windows (machine-state lands
    # at <XDG_DATA_HOME>\containers\podman\machine). This is the
    # non-admin path equivalent of Set-PodmanMachineStorageOn's
    # mklink /D approach (which requires elevation).
    # Without this, the dev distro's VHDX (multi-GB, grows during the
    # OCI build) lands on C: instead of the operator's M:\ partition.
    if ((Test-Path 'M:\') -and -not $env:XDG_DATA_HOME) {
        $miosPodmanRoot = 'M:\podman'
        if (-not (Test-Path $miosPodmanRoot)) {
            New-Item -ItemType Directory -Path $miosPodmanRoot -Force | Out-Null
        }
        $env:XDG_DATA_HOME = $miosPodmanRoot
        Log-Ok "podman-machine state redirected to M:\podman (XDG_DATA_HOME)"
    }
    # $HW.RamGB is already the maximalist-minus-host-reserve allocation
    # computed by Get-Hardware (per mios.toml [bootstrap.dev_vm.host_reserve]).
    # Multiply to MB and clamp once more against the OS-reported total
    # (what podman validates; nominal Win32_PhysicalMemory rounds up and
    # would otherwise cause podman to reject the request) minus a 512 MB
    # safety margin. Floor of 4096 MB so the dev VM is always usable.
    $ramMB = [math]::Max(4096, [math]::Min($HW.OsTotalRamMB - 512, $HW.RamGB * 1024))

    # Data disk + podman storage redirection happened earlier in
    # Invoke-DataDiskBootstrap (between Phase 1 and Phase 2). By the
    # time we reach Phase 3 the partition is provisioned and
    # CONTAINERS_STORAGE_CONF / podman.connections already point at
    # the data disk. $HW.DiskGB has also been clamped there.
    $diskGB = $HW.DiskGB

    # ── Pre-stage machine-os via direct HTTPS ──────────────────────────────────
    # On podman 5.8.2 (Windows + WSL provider) the in-process pull pipeline
    # fails for ANY machine-os ref with "system cannot find the path
    # specified". Direct OCI-Distribution GET against quay.io works fine,
    # so we fetch the wsl-x86_64 layer ourselves and hand podman a local
    # `.tar.zst` path -- no registry pull happens inside podman at all.
    #
    # Default tag: 6.0 (per operator instruction). Override with
    # MIOS_MACHINE_TAG=<tag> or MIOS_MACHINE_IMAGE=<docker:// url> for a
    # specific ref; pre-stage runs in both cases.
    # Default machine image sourced from mios.toml [bootstrap.dev_vm].
    # base_image (vendor default: quay.io/podman/machine-os:6.0). Env var
    # MIOS_MACHINE_TAG / MIOS_MACHINE_IMAGE still wins for ad-hoc overrides.
    $_tomlBase   = Get-MiosTomlValue -Section 'bootstrap.dev_vm' -Key 'base_image' -Default 'quay.io/podman/machine-os:6.0'
    if ($_tomlBase -match '^(.+):([^:]+)$') {
        $_tomlRepo = $Matches[1]; $_tomlTag = $Matches[2]
    } else {
        $_tomlRepo = $_tomlBase;  $_tomlTag = '6.0'
    }
    $machineTag = if ($env:MIOS_MACHINE_TAG) { $env:MIOS_MACHINE_TAG } else { $_tomlTag }
    $machineRepo = $_tomlRepo
    if ($MachineImage -match '^docker://(.+)$') {
        $ref = $matches[1]
        if ($ref -match '^(.+):([^:]+)$') {
            $machineRepo = $matches[1]
            $machineTag  = $matches[2]
        } elseif ($ref -match '^[^/]+/[^/]+/[^/]+$') {
            $machineRepo = $ref
        }
        $MachineImage = $null  # force re-resolution below
    }
    if (-not $MachineImage) {
        $machineCacheDir = Join-Path $script:MiosInstallDir 'machine-os'
        # Retry-with-backoff loop. quay.io has been intermittently
        # 502/503-ing during peak hours; without retry, a 5-minute
        # outage kills the entire bootstrap. 3 attempts with 5s/15s/30s
        # backoff covers most transient registry blips. Cache-hit
        # short-circuit inside Get-PodmanMachineOsImage means a
        # successful prior fetch makes subsequent retries instant.
        $MachineImage = $null
        $lastErr      = $null
        # Retry schedule from mios.toml [network.retry].delays_seconds
        # (vendor default: 0s, 5s, 15s, 30s). Operator can lengthen for
        # known-flaky upstreams via the configurator HTML.
        $delays       = @(Get-MiosTomlValue -Section 'network.retry' -Key 'delays_seconds' -Default @(0, 5, 15, 30))
        for ($i = 0; $i -lt $delays.Count; $i++) {
            if ($delays[$i] -gt 0) {
                Set-Step "Retry $i/$($delays.Count - 1) for $machineRepo`:$machineTag in $($delays[$i])s..."
                Start-Sleep -Seconds $delays[$i]
            }
            try {
                $MachineImage = Get-PodmanMachineOsImage `
                    -Repo $machineRepo `
                    -Tag  $machineTag `
                    -CacheDir $machineCacheDir
                break  # success
            } catch {
                $lastErr = $_
                $msg     = "$_"
                # 502/503/504/timeout = retryable. Anything else (404,
                # 401, parse error) = permanent, break out.
                if ($msg -notmatch '\b(50[234]|timed out|timeout|connection reset|connection refused|RemoteIO|temporarily)\b') {
                    Log-Warn "Pre-stage of $machineRepo`:$machineTag hit non-retryable error: $msg"
                    break
                }
                Log-Warn "Pre-stage attempt $($i+1) failed (retryable): $msg"
            }
        }
        if (-not $MachineImage) {
            Log-Warn "Pre-stage of $machineRepo`:$machineTag failed after retries: $lastErr"
            Log-Warn "Will let podman attempt its own pull (likely fails on this client if quay.io is still down)."
        }
    }

    $initSw = [System.Diagnostics.Stopwatch]::StartNew()
    $initOut = [System.Collections.Generic.List[string]]::new()
    if ($MachineImage) {
        Log-Ok "Provisioning MiOS-DEV from machine image: $MachineImage"
    } else {
        Log-Ok "Provisioning MiOS-DEV using podman's bundled default machine image"
    }
    # Build the arg list dynamically so --image is only passed when the
    # operator (or env override) has supplied one. With no --image,
    # podman init uses its bundled default -- always compatible with
    # the installed client version.
    $initArgs = @(
        'machine', 'init', $BuilderDistro,
        '--cpus',      $HW.Cpus,
        '--memory',    $ramMB,
        '--disk-size', $diskGB,
        '--rootful',
        '--now'
    )
    if ($MachineImage) {
        $initArgs += @('--image', $MachineImage)
    }
    # Wrap the init invocation in a fresh child scope with
    # $ErrorActionPreference='Continue'. Without this, podman's normal
    # post-start stderr line (e.g. "API forwarding for Docker API
    # clients is not available...") trips the script's outer EAP=Stop
    # via the 2>&1 stream merge and surfaces as a Phase 3 FATAL even
    # though `podman machine init` exited 0 and the machine is fully
    # up. $LASTEXITCODE survives the scope exit (it's an automatic
    # variable populated globally by every native command invocation),
    # so the if-($initRc -ne 0) check below sees the real exit code,
    # not a phantom from a stream-merged warning.
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        & podman @initArgs 2>&1 | ForEach-Object {
            Write-Log "podman-init: $_"
            $initOut.Add([string]$_) | Out-Null
            if ($initSw.ElapsedMilliseconds -ge 150) {
                $clean = ($_ -replace '\x1b\[[0-9;]*[mGKHFJ]','').Trim()
                if ($clean) { $script:CurStep = $clean.Substring(0,[math]::Min($clean.Length,80)) }
                Show-Dashboard
                $initSw.Restart()
            }
        }
    }
    $initRc      = $LASTEXITCODE
    $initJoined  = ($initOut -join " ")

    # ── Recovery branch 1: pull failed on a pinned --image ──────────────────
    # Pinning $MachineImage to a tag the operator's installed podman client
    # can't pull (typical: docker://quay.io/podman/machine-os:6.0 against a
    # podman 5.8 client) produces:
    #     Error: failed to pull quay.io/podman/machine-os@sha256:<digest>:
    #            The system cannot find the path specified.
    # init exits 125 BEFORE creating any registration, so there's no
    # cleanup needed -- just retry without --image so podman uses its
    # bundled default (which the client always knows how to handle).
    # The fallback is logged so the operator sees they're on a
    # fallback tag and can `winget upgrade Podman.Podman` to actually
    # land on their requested pin.
    if ($initRc -ne 0 -and $MachineImage `
            -and $initJoined -match '(?i)failed to pull|cannot find the path specified') {
        Log-Warn "podman machine init failed to pull $MachineImage on this client."
        Log-Warn "Falling back to podman's bundled default machine-os image."
        Log-Warn "To get the pinned image, upgrade your podman client: winget upgrade Podman.Podman"

        # Strip --image from the arg list and retry.
        $fallbackArgs = @($initArgs | Where-Object { $_ -ne '--image' -and $_ -ne $MachineImage })
        $fallbackOut = [System.Collections.Generic.List[string]]::new()
        & {
            $ErrorActionPreference = 'Continue'
            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                $PSNativeCommandUseErrorActionPreference = $false
            }
            & podman @fallbackArgs 2>&1 | ForEach-Object {
                Write-Log "podman-init-fallback: $_"
                $fallbackOut.Add([string]$_) | Out-Null
                $clean = ($_ -replace '\x1b\[[0-9;]*[mGKHFJ]','').Trim()
                if ($clean) { $script:CurStep = $clean.Substring(0,[math]::Min($clean.Length,80)) }
                Show-Dashboard
            }
        }
        $initRc = $LASTEXITCODE
        $initJoined = (($initOut + $fallbackOut) -join " ")
        if ($initRc -eq 0) {
            Log-Ok "$BuilderDistro initialized via bundled-default fallback"
        }
    }

    if ($initRc -ne 0) {
        # "VM already exists" -- recover by starting (or treating as already
        # running) instead of failing. Caller's outer loop already tried to
        # detect a running machine; we got here because the registration
        # exists but `podman machine ls` didn't expose it as running, which
        # also matches Windows Subsystem for Linux's transient ghost state
        # right after a previous interrupted init. Best response is just to
        # try starting it and verify the API.
        if ($initJoined -match '(?i)already exists|vm.*already exists') {
            Log-Warn "podman machine init: $BuilderDistro already exists -- starting instead"
            # MUST wrap in EAP=Continue + PSNativeCommandUseErrorActionPreference=$false:
            # podman returns non-zero on "already running" (which IS our happy
            # path here), and PS 7.4+ defaults PSNativeCommandUseErrorActionPreference
            # to $true -- so a non-zero exit throws BEFORE the regex match below
            # can downgrade it to a Log-Ok. The init call uses the same wrap; this
            # one was missing it and threw straight to the outer FATAL handler.
            $startOut = [System.Collections.Generic.List[string]]::new()
            & {
                $ErrorActionPreference = 'Continue'
                if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                    $PSNativeCommandUseErrorActionPreference = $false
                }
                & podman machine start $BuilderDistro 2>&1 | ForEach-Object {
                    Write-Log "podman-recover-start: $_"
                    $startOut.Add([string]$_) | Out-Null
                }
            }
            $startJoined = ($startOut -join " ")
            if ($startJoined -match '(?i)already running') {
                Log-Ok "$BuilderDistro is already running"
            } elseif ($LASTEXITCODE -eq 0) {
                Log-Ok "$BuilderDistro started"
            } else {
                # Start failed too -- registration is stale or the VM is in
                # a half-provisioned state from a SIGINT'd previous run.
                # Force-remove the registration and re-init from scratch.
                # Safe at this point in the pipeline: no MiOS image / no
                # operator data lives in the build VM yet.
                Log-Warn "$BuilderDistro start failed after init-already-exists (exit $LASTEXITCODE) -- force-removing and retrying init"
                Write-Log "podman-recover-rm-output: $startJoined"

                # Operator 2026-05-09 v3: WSL unregister chain + final
                # `wsl --shutdown` to fully reset the WSL2 service state
                # before retry-init.  Previous v2 (commit c434302) got
                # past the getpwnam crash but the retry-init then hit
                # `Wsl/Service/RegisterDistro/E_FAIL ... Error code: 6,
                # failure step: 2` (= WSL_E_VM_MODE_INVALID_STATE) --
                # the WSL service was in a transient bad state from
                # the unregister + reparse-point-removal cycle, and
                # `wsl --import` to the M:\ path failed.  `wsl
                # --shutdown` forces a clean lifebooot of the WSL2
                # subsystem so import lands cleanly.  Whole block in
                # EAP=Continue so non-zero exits don't throw to FATAL.
                & {
                    $ErrorActionPreference = 'Continue'
                    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                        $PSNativeCommandUseErrorActionPreference = $false
                    }
                    foreach ($_wslName in @("podman-$BuilderDistro", $BuilderDistro)) {
                        & wsl.exe --unregister $_wslName 2>&1 |
                            ForEach-Object { Write-Log "podman-recover-wsl-unregister-pre: $_" }
                    }
                    Start-Sleep -Seconds 2
                    & podman machine rm --force $BuilderDistro 2>&1 |
                        ForEach-Object { Write-Log "podman-recover-rm: $_" }
                    foreach ($_wslName in @("podman-$BuilderDistro", $BuilderDistro)) {
                        & wsl.exe --unregister $_wslName 2>&1 |
                            ForEach-Object { Write-Log "podman-recover-wsl-unregister-post: $_" }
                    }
                    # Shut down the WSL2 lifeboot so retry-init's
                    # `wsl --import` lands on a clean service state.
                    & wsl.exe --shutdown 2>&1 |
                        ForEach-Object { Write-Log "podman-recover-wsl-shutdown: $_" }
                    Start-Sleep -Seconds 4
                }

                # Sweep ALL candidate podman-machine storage paths
                # unconditionally. A previous run (admin or otherwise)
                # may have left:
                #   * a dangling symlink ([Test-Path] returns false on
                #     these because PS resolves the target -- so the
                #     prior dangling-only check missed them entirely)
                #   * a non-dangling symlink to a now-stale target
                #   * a real directory with stale machine state
                # ANY of these can make podman init's Mkdir() fail
                # with "Cannot create a file when that file already
                # exists". After `podman machine rm --force` the VM
                # registration is gone, so the on-disk state in these
                # paths is unambiguously safe to wipe.
                #
                # DirectoryInfo lets us probe both regular dirs AND
                # reparse points without follow-the-link semantics --
                # Test-Path's "exists" check fails on dangling links.
                $podmanMachineCands = @(
                    (Join-Path $env:LOCALAPPDATA 'containers\podman\machine'),
                    (Join-Path $env:USERPROFILE  '.local\share\containers\podman\machine'),
                    (Join-Path $env:PROGRAMDATA  'containers\podman\machine')
                )
                foreach ($p in $podmanMachineCands) {
                    $info = $null
                    try { $info = New-Object System.IO.DirectoryInfo $p } catch { continue }
                    if (-not $info) { continue }
                    $isLink   = $false
                    $linkOnly = $false
                    try {
                        if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                            $isLink   = $true
                            $linkOnly = $true
                        }
                    } catch {
                        # Attributes throws for dangling symlinks on
                        # PS 7+; we know it's a link if .Exists is
                        # false but the parent has a child with the
                        # same name. Treat as link.
                        $isLink   = $true
                        $linkOnly = $true
                    }
                    $realDirExists = $false
                    try { $realDirExists = $info.Exists -and -not $isLink } catch {}
                    if (-not ($isLink -or $realDirExists)) { continue }

                    if ($linkOnly) {
                        Log-Warn "podman-recover: removing reparse-point at $p (link, no follow)"
                        cmd /c "rmdir `"$p`"" 2>&1 | ForEach-Object { Write-Log "podman-recover-rmdir: $_" }
                    } else {
                        Log-Warn "podman-recover: removing stale podman-machine state at $p"
                        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }

                # Retry init from a clean slate. Same EAP=Continue wrap as
                # the primary init invocation above so podman's chatty
                # post-start stderr doesn't trip $ErrorActionPreference=Stop.
                $retryOut = [System.Collections.Generic.List[string]]::new()
                & {
                    $ErrorActionPreference = 'Continue'
                    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                        $PSNativeCommandUseErrorActionPreference = $false
                    }
                    & podman @initArgs 2>&1 | ForEach-Object {
                        Write-Log "podman-init-retry: $_"
                        $retryOut.Add([string]$_) | Out-Null
                        $clean = ($_ -replace '\x1b\[[0-9;]*[mGKHFJ]','').Trim()
                        if ($clean) { $script:CurStep = $clean.Substring(0,[math]::Min($clean.Length,80)) }
                        Show-Dashboard
                    }
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "podman machine init retry failed (exit $LASTEXITCODE) after force-rm: $(($retryOut | Select-Object -Last 5) -join ' / ')"
                }
                Log-Ok "$BuilderDistro re-initialized after force-rm"
            }
        } else {
            throw "podman machine init failed (exit $initRc): $(($initOut | Select-Object -Last 3) -join ' / ')"
        }
    }
    $null = Invoke-NativeQuiet { podman machine set --default $BuilderDistro }
    Log-Ok "$DevDistro ready as default Podman machine"

    # ── Force the podman-MiOS-DEV WSL distro onto M:\ ────────────────────
    # Operator: "podman-MiOS-DEV MUST also be located on M:\". XDG_DATA_HOME=
    # M:\podman + Set-PodmanMachineStorageOnM's junctions are SUPPOSED to make
    # podman init create the distro under M:\, but on some podman versions
    # the WSL2 VHDX still ends up under %LOCALAPPDATA%\Packages\<guid>\
    # LocalState (WSL2 ignores XDG_DATA_HOME -- it only respects the path
    # passed to `wsl --import`). Detect the actual BasePath via registry
    # and, if not on M:\, do export + unregister + import to force it.
    if (Test-Path 'M:\') {
        try {
            Move-PodmanWslDistroToM -DistroName $BuilderDistro
        } catch {
            Log-Warn "podman-WSL distro M:\ migration: $_"
        }
    }

    # Rootful machine-os distros are not accessible via wsl.exe or podman machine ssh.
    # Build runs from the Windows Podman client via the machine's API -- no exec needed.
    # Just verify the API is up (it should be immediately after --now).
    Set-Step "Verifying $DevDistro Podman API..."
    # Use `podman machine inspect --format {{.State}}` -- it returns the
    # canonical state string ("running" / "starting" / "stopped"). The
    # older `podman machine ls --format {{.Running}}` boolean is broken on
    # podman 5.8: it returns "false" for several seconds AFTER the machine
    # is actually up (LastUp shows "Currently starting" while State is
    # already "running"). Inspect.State flips first and is what podman
    # itself uses for socket-readiness gating.
    $deadline = (Get-Date).AddSeconds(90)
    $apiOk = $false
    $lastState = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $stateOut = & podman machine inspect $BuilderDistro --format '{{.State}}' 2>$null
            $lastState = ($stateOut | Select-Object -First 1) -as [string]
            if ($lastState) { $lastState = $lastState.Trim() }
        } catch { $lastState = '' }
        if ($lastState -eq 'running') { $apiOk = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $apiOk) {
        throw "$BuilderDistro not in running state after 90 s (last seen: '$lastState') -- check: podman machine ls"
    }
    Log-Ok "$DevDistro Podman API ready"
    # Overlay seed is invoked once at end of Phase 3 (covers both the
    # newly-created path and the already-running path); see the call
    # site directly above End-Phase 3 in the main flow.
}

function Invoke-MiosOverlaySeed {
    # DEPRECATED 2026-05-06: bare invocation is a silent no-op.
    #
    # Original purpose: read PACKAGES.md fenced ```packages-*``` blocks
    # from the cloned mios.git checkout and run `dnf5 install` per
    # block inside MiOS-DEV. Replaced by Invoke-MiosQuadletOverlay
    # (which makes / a git working tree of mios.git) plus
    # automation/lib/packages.sh (which resolves mios.toml
    # [packages.<section>].pkgs as the SSOT).
    #
    # Per project_mios_self_replication_vision.md the package surface
    # is now baked into the OCI image at build time and made live on
    # MiOS-DEV via `bootc switch` + reboot at the end of the
    # mios-build-driver flow. There's no more "live overlay" install
    # step on the Windows side -- the dev VM gets the same packages
    # by becoming the OCI image, not by running dnf at the host level.
    #
    # Force-enable for testing-only via MIOS_FORCE_LEGACY_PACKAGES_MD=1
    # (intentionally undocumented in the operator-facing flow).
    if ($env:MIOS_FORCE_LEGACY_PACKAGES_MD -ne '1') {
        return
    }
    Log-Warn "MIOS_FORCE_LEGACY_PACKAGES_MD=1 -- running deprecated PACKAGES.md overlay seed (you are off the canonical path)"
    Set-Step "Seeding MiOS package overlay onto $DevDistro (LEGACY)..."
    # Updated path: the file moved 2026-05-05 to usr/share/doc/mios/reference/.
    # Try the new path first, fall back to the old vendor location for
    # operators on stale checkouts.
    # mios.git overlay puts /usr at $MiosRepoDir root.
    $packagesMd = Join-Path $MiosRepoDir "usr\share\doc\mios\reference\PACKAGES.md"
    if (-not (Test-Path $packagesMd)) {
        $packagesMd = Join-Path $MiosRepoDir "usr\share\mios\PACKAGES.md"
    }
    if (-not (Test-Path $packagesMd)) {
        Log-Warn "PACKAGES.md not found in either canonical location -- legacy overlay seed skipped"
        return
    }
    $wslDistro = "podman-$DevDistro"

    # Confirm the distro is reachable via wsl.exe (rootful machines on
    # newer Podman builds register as podman-<Name>; older builds may
    # register without prefix -- try both).
    $sshOk = $false
    foreach ($candidate in @($wslDistro, $DevDistro)) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; $sshOk = $true; break }
    }
    if (-not $sshOk) {
        Log-Warn "Cannot wsl.exe into $DevDistro -- overlay seed deferred to first manual run"
        return
    }

    # Stage PACKAGES.md + the highest-precedence mios.toml + the overlay
    # installer inside the distro's /tmp. Using `wsl --exec cp` from the
    # Windows path avoids podman-machine-cp's rootful permission quirks.
    # The bash overlay reads [packages.dev_overlay].sections from
    # /tmp/mios.toml -- this is what consolidates the SSOT (no longer
    # blanket-installs every PACKAGES.md section; honors operator's
    # configurator-saved selection).
    $drive = $packagesMd.Substring(0,1).ToLower()
    $packagesWslPath = "/mnt/$drive" + ($packagesMd.Substring(2) -replace '\\','/')

    $tomlSources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        # Both repos are overlaid at $MiosRepoDir root, so mios.toml
        # exists once at $MiosRepoDir\mios.toml (mios-bootstrap's copy
        # last-write-wins via the robocopy overlay) AND once at
        # $MiosRepoDir\usr\share\mios\mios.toml (mios.git's vendor copy).
        (Join-Path $MiosRepoDir "mios.toml"),
        (Join-Path $MiosRepoDir "usr\share\mios\mios.toml")
    )
    $tomlPath = $null
    foreach ($t in $tomlSources) { if (Test-Path $t) { $tomlPath = $t; break } }
    $tomlWslPath = ""
    if ($tomlPath) {
        $td = $tomlPath.Substring(0,1).ToLower()
        $tomlWslPath = "/mnt/$td" + ($tomlPath.Substring(2) -replace '\\','/')
    }

    $overlayScript = @'
#!/usr/bin/env bash
# mios-overlay.sh -- live system overlay seeder for MiOS-DEV.
# Generated by build-mios.ps1 / Invoke-MiosOverlaySeed.
set -uo pipefail

SENTINEL="/var/lib/mios/.overlay-seeded"
SRC_MD="${SRC_MD:-/tmp/PACKAGES.md}"
PACKAGES_MD="/tmp/PACKAGES.lf.md"
LOG_DIR="/tmp/mios-overlay-logs"
mkdir -p "$LOG_DIR" && chmod 0777 "$LOG_DIR"

# Skip if already seeded and PACKAGES.md is older than the sentinel.
if [[ -f "$SENTINEL" && "$SENTINEL" -nt "$SRC_MD" ]]; then
    echo "[mios-overlay] sentinel newer than PACKAGES.md -> skip"
    exit 0
fi

# Normalize CRLF (OneDrive-synced source).
tr -d '\r' < "$SRC_MD" > "$PACKAGES_MD"

# Resolve the dev-overlay section list from the user's mios.toml. The
# layered resolver (highest wins): per-user (~/.config/mios/mios.toml),
# host (/etc/mios/mios.toml), bootstrap clone, vendor (PACKAGES.md
# bootstrap default). The PowerShell side stages the highest-precedence
# layer at $SRC_TOML before invoking us. Falls back to a hardcoded
# minimal list if no [packages.dev_overlay].sections array is present.
SRC_TOML="${SRC_TOML:-/tmp/mios.toml}"
DEFAULT_SECTIONS=(
    base security utils build-toolchain containers
    cockpit storage virt
    gpu-mesa gpu-nvidia gpu-amd-compute gpu-intel-compute
    gnome-flatpak-runtime
    ai sbom-tools self-build network-discovery updater
    cockpit-plugins-build k3s-selinux-build uki
)

# Naive TOML scrape: pull the array under [packages.dev_overlay].sections
# (or [packages].dev_overlay.sections inline form). Tolerates the
# single-line + multi-line array shapes the configurator emits.
parse_sections_from_toml() {
    [[ -r "$SRC_TOML" ]] || return 1
    awk '
        /^\[packages\.dev_overlay\][[:space:]]*$/ { in_block=1; next }
        in_block && /^\[/                        { in_block=0; next }
        in_block && /^[[:space:]]*sections[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0); collecting=1
        }
        collecting {
            print
            if ($0 ~ /\]/) { collecting=0 }
        }
    ' "$SRC_TOML" \
        | tr -d '[]\n' \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*"?([^"#]*)"?[[:space:]]*$/\1/' \
        | sed '/^$/d'
}

mapfile -t SECTIONS < <(parse_sections_from_toml || true)
SECTIONS_SOURCE="mios.toml [packages.dev_overlay]"
if (( ${#SECTIONS[@]} == 0 )); then
    SECTIONS=("${DEFAULT_SECTIONS[@]}")
    SECTIONS_SOURCE="hardcoded minimal default"
fi
echo "[mios-overlay] sections (${#SECTIONS[@]}, from ${SECTIONS_SOURCE}): ${SECTIONS[*]}"

get_pkgs() {
    sed -n "/^\`\`\`packages-${1}$/,/^\`\`\`$/{/^\`\`\`/d;/^$/d;/^#/d;p}" "$PACKAGES_MD"
}

# Add Fedora-version-pinned RPMFusion (free + nonfree).
fedver=$(rpm -E %fedora 2>/dev/null || echo 43)
sudo dnf5 install -y --skip-unavailable \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm" \
    >"$LOG_DIR/00-rpmfusion.log" 2>&1 || true

# Hard always-skip list. This wins even if the operator typed e.g.
# "kernel" into mios.toml -- those sections are WSL-incompatible or
# anti-pattern fences and refusing them is the right move.
ALWAYS_SKIP_RE='^(kernel|boot|moby|bloat|critical)$'

install_section() {
    local sec="$1"
    [[ "$sec" =~ $ALWAYS_SKIP_RE ]] && { echo "[mios-overlay] SKIP $sec (always-skipped)"; return; }
    local pkgs
    pkgs=$(get_pkgs "$sec" | tr '\n' ' ')
    [[ -z "${pkgs// }" ]] && { echo "[mios-overlay] EMPTY $sec"; return; }
    echo "[mios-overlay] INSTALL $sec"
    # shellcheck disable=SC2086
    sudo dnf5 install -y --skip-unavailable --skip-broken --allowerasing \
        $pkgs >"$LOG_DIR/$sec.log" 2>&1
    # rc=1 from terminal systemd scriptlets is benign on podman-machine
    # WSL distros that lack a live system D-Bus -- packages still land.
}

# Foundation (repos must be first), then user-selected sections.
install_section repos
for sec in "${SECTIONS[@]}"; do
    [[ "$sec" == "repos" ]] && continue
    install_section "$sec"
done

# Critical safe-subset (skip kernel-core/gdm/libvirt on WSL).
echo "[mios-overlay] INSTALL critical (WSL-safe subset)"
sudo dnf5 install -y --skip-unavailable --skip-broken --allowerasing \
    bootc chrony cockpit firewalld NetworkManager pipewire tuned \
    >"$LOG_DIR/critical.log" 2>&1 || true

sudo install -d -m 0755 /var/lib/mios
sudo touch "$SENTINEL"

# Install a wrapper at /usr/local/bin/mios-dev-seed so the operator can
# re-run the overlay manually inside the dev distro after editing
# PACKAGES.md (e.g. `wsl -d podman-MiOS-DEV -- sudo mios-dev-seed`).
sudo install -d -m 0755 /usr/local/bin
sudo install -m 0755 /tmp/mios-overlay.sh /usr/local/bin/mios-dev-seed

# Drop a profile.d hint so `wsl -d podman-MiOS-DEV` greets the operator
# with the dev-VM context. Quiet for non-interactive shells.
sudo tee /etc/profile.d/mios-dev-motd.sh >/dev/null <<'PROFILE'
# MiOS-DEV operator hint -- only on interactive shells.
if [[ -n "${PS1-}" && -t 1 ]]; then
    pkgs=$(rpm -qa | wc -l 2>/dev/null || echo ?)
    echo "MiOS-DEV (Podman-WSL2 dev VM, $pkgs pkgs)  --  refresh: sudo mios-dev-seed"
fi
PROFILE
sudo chmod 0644 /etc/profile.d/mios-dev-motd.sh

echo "[mios-overlay] done -- $(rpm -qa | wc -l) packages installed"
echo "[mios-overlay] manual refresh: sudo mios-dev-seed"
'@

    # Materialize the script + a copy of PACKAGES.md inside the distro
    # via stdin; avoids cross-FS quoting headaches and works for both
    # /mnt/c-mounted paths and rootful machines.
    # CRLF -> LF: PowerShell @'...'@ here-strings produce CRLF on
    # Windows; without normalization the bash shebang becomes
    # "#!/usr/bin/env bash\r" -> "env: 'bash\r': No such file or
    # directory" -> the entire overlay silently no-ops on the dev VM.
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64Script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overlayScript))
    $stageToml = ""
    if ($tomlWslPath) {
        $stageToml = "cp '$tomlWslPath' /tmp/mios.toml; "
    }
    $stage = "set -e; sudo install -d -m 0777 /tmp; " +
             "echo '$b64Script' | base64 -d > /tmp/mios-overlay.sh && chmod +x /tmp/mios-overlay.sh; " +
             "cp '$packagesWslPath' /tmp/PACKAGES.md; " +
             $stageToml +
             "/tmp/mios-overlay.sh"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "overlay-seed: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log-Warn "overlay seed exited rc=$LASTEXITCODE -- partial install possible (packages may still be present; rerun safe)"
    } else {
        Log-Ok "MiOS package overlay seeded into $DevDistro"
    }
}

function Invoke-MiosQuadletOverlay {
    # Mirror the MiOS FHS overlay (Quadlets, systemd units, sysusers,
    # tmpfiles, libexec, profile.d, /etc/mios config templates) onto the
    # dev distro so MiOS-DEV runs the same container surface as a deployed
    # MiOS host. After this:
    #   - Podman Desktop (Windows) sees mios-cockpit-link, mios-forge, etc.
    #     under the MiOS-DEV machine connection -- each carries
    #     io.podman_desktop.openInBrowser labels for one-click access.
    #   - Cockpit on the dev VM (https://localhost:9090, mirrored networking)
    #     renders the same containers + system services as a deployed host.
    #
    # Idempotent via /var/lib/mios/.quadlet-overlay-seeded; re-runs are no-ops
    # unless the source mios.git Containerfile has been touched since the
    # sentinel. Set MIOS_SKIP_DEV_QUADLETS=1 to bypass entirely.
    if ($env:MIOS_SKIP_DEV_QUADLETS -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_DEV_QUADLETS set -- Quadlet overlay skipped"
        return
    }

    Set-Step "Overlaying MiOS Quadlets + systemd units onto $DevDistro..."

    # Early-out: rootful machine-os distros are NOT wsl.exe-accessible
    # by design. The previous --exec probe-with-timeout still left
    # hung wsl.exe processes that didn't always Kill cleanly. Probe
    # the machine's rootful flag via podman's API (which IS reachable
    # because Phase 3 just verified it) and skip the entire overlay
    # if rootful -- the Quadlet provisioning happens INSIDE the
    # mios-build-driver via OCI build instead.
    try {
        $mInfo = (& podman machine inspect $DevDistro 2>$null) | ConvertFrom-Json -ErrorAction Stop
        if ($mInfo -and $mInfo[0].Rootful) {
            Log-Warn "Rootful machine-os detected -- Quadlet overlay deferred (handled by OCI build inside MiOS-DEV)"
            return
        }
    } catch {}

    # Per the 2026-05-06 directive "M:\ IS git", mios.git is overlaid AT
    # $MiosRepoDir root, not at $MiosRepoDir\mios subdir.
    $miosRoot = $MiosRepoDir
    if (-not (Test-Path (Join-Path $miosRoot "Containerfile"))) {
        Log-Warn "mios.git overlay missing at $miosRoot (no Containerfile) -- Quadlet overlay skipped"
        return
    }
    # Probe wsl.exe with a hard timeout. Rootful machine-os distros
    # are NOT wsl.exe-accessible, and `wsl.exe --exec` on them hangs
    # indefinitely instead of erroring -- which made the build freeze
    # at "Overlaying MiOS Quadlets + systemd units" with no progress.
    # 8-second timeout per candidate; if both time out, the overlay
    # is deferred (matches the rootful-machine-os documented behavior).
    function _ProbeWslAlive {
        param([string]$Distro, [int]$TimeoutMs = 8000)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'wsl.exe'
        $psi.Arguments = "-d $Distro --exec bash -c `"echo ok`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        } catch { return $false }
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            return $false
        }
        $stdout = $proc.StandardOutput.ReadToEnd().Trim()
        return ($stdout -eq 'ok')
    }
    $wslDistro = "podman-$DevDistro"
    $sshOk = $false
    foreach ($candidate in @($wslDistro, $DevDistro)) {
        if (_ProbeWslAlive -Distro $candidate -TimeoutMs 8000) {
            $wslDistro = $candidate; $sshOk = $true; break
        }
    }
    if (-not $sshOk) {
        Log-Warn "Cannot wsl.exe into $DevDistro within 8s (rootful machine-os is not wsl.exe-accessible by design) -- Quadlet overlay deferred"
        return
    }

    # Convert C:\path\to\mios -> /mnt/c/path/to/mios for the WSL side.
    # Trim trailing backslash so M:\ -> /mnt/m (no trailing slash, which
    # would produce /mnt/m/ and break sentinel comparisons in the seed
    # script that compare against $1).
    $miosRootTrimmed = $miosRoot.TrimEnd('\')
    $drive = $miosRootTrimmed.Substring(0,1).ToLower()
    $miosRootWsl = if ($miosRootTrimmed.Length -le 2) {
        "/mnt/$drive"     # bare drive root e.g. M:\ -> /mnt/m
    } else {
        "/mnt/$drive" + ($miosRootTrimmed.Substring(2) -replace '\\','/')
    }

    $enableAi     = if ($env:MIOS_DEV_ENABLE_AI     -in @('1','true','TRUE','yes')) { '1' } else { '0' }
    $enableRunner = if ($env:MIOS_DEV_ENABLE_RUNNER -in @('1','true','TRUE','yes')) { '1' } else { '0' }

    $overlayScript = @'
#!/usr/bin/env bash
# mios-quadlet-overlay.sh -- mirror MiOS FHS overlay into MiOS-DEV.
# Generated by build-mios.ps1 / Invoke-MiosQuadletOverlay.
set -uo pipefail

SRC="${1:?source mios.git path required}"
SENTINEL="/var/lib/mios/.quadlet-overlay-seeded"

# Skip if sentinel is newer than the source mios.git's Containerfile
# (cheap proxy for "has the source tree changed since last overlay").
if [[ -f "$SENTINEL" && "$SENTINEL" -nt "$SRC/Containerfile" ]]; then
    echo "[quadlet-overlay] sentinel newer than mios.git -> skip"
    exit 0
fi

echo "[quadlet-overlay] making / a git working tree of mios.git ($SRC) ..."

# PROJECT INVARIANT: MiOS treats the deployed root `/` AS the git
# working tree of mios.git on EVERY deploy shape -- bare-metal,
# Hyper-V, QEMU, WSL distro, AND the Windows-side podman-WSL2 dev VM.
# `git init` at `/`, point origin at the cloned mios.git checkout
# (later swappable to the self-hosted Forgejo at localhost:3000),
# `fetch + reset --hard`, and now every mios.git tracked file is at
# its FHS path on `/` in one operation -- no tar-list to maintain,
# no missing-file bugs, full parity with the deployed system.
#
# Safety: `git reset --hard FETCH_HEAD` only touches FILES TRACKED
# IN mios.git. Untracked Fedora-base paths (/etc/passwd, /var/lib/
# dnf, ~/.bash_history, /var/log, etc.) are left alone -- they are
# not in mios.git and git's reset doesn't enumerate them. The repo's
# root .gitignore further declares which `/etc/*`, `/var/*`, etc.
# subtrees stay host-managed.

# Refresh the local Windows-side mios.git clone to origin/main first
# so the dev VM sees the latest commits. Without this the dev VM
# fetches from a stale clone if the Windows side hasn't been pulled
# since `irm | iex` started.
if [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" fetch --depth=1 origin main 2>&1 | tail -2 || true
    git -C "$SRC" reset --hard origin/main 2>&1 | tail -2 || true
fi

# Mark `/` as a safe git directory -- root-owned `.git` triggers
# git's "dubious ownership" rejection when a non-root user later
# inspects state (`git -C / log`, dashboard's git panel, etc.).
sudo git config --system --add safe.directory / 2>/dev/null || \
    sudo git config --global --add safe.directory /

sudo git -C / init -b main 2>&1 | head -1 || true
sudo git -C / config --bool core.fileMode false
sudo git -C / config --bool core.autocrlf false
sudo git -C / config --bool core.symlinks true
sudo git -C / remote remove origin 2>/dev/null || true
sudo git -C / remote add origin "$SRC/.git"
echo "[quadlet-overlay] git fetch ..."
fetch_out=$(sudo git -C / fetch --depth=1 origin main 2>&1)
fetch_rc=$?
echo "$fetch_out" | tail -3
if [[ $fetch_rc -ne 0 ]]; then
    echo "[quadlet-overlay] ERROR: git fetch failed (rc=$fetch_rc)"
    echo "[quadlet-overlay] $fetch_out"
fi
echo "[quadlet-overlay] git reset --hard FETCH_HEAD ..."
reset_out=$(sudo git -C / reset --hard FETCH_HEAD 2>&1)
reset_rc=$?
echo "$reset_out" | tail -3
if [[ $reset_rc -ne 0 ]]; then
    echo "[quadlet-overlay] ERROR: git reset failed (rc=$reset_rc)"
    # Most common cause: /usr is read-only (ostree-managed FCOS).
    # Attempt to enable a writable overlay and retry once.
    if echo "$reset_out" | grep -qiE 'read-only|ostree'; then
        echo "[quadlet-overlay] /usr appears read-only -- enabling rpm-ostree usroverlay"
        sudo rpm-ostree usroverlay 2>&1 | tail -2 || true
        echo "[quadlet-overlay] retrying git reset --hard FETCH_HEAD"
        sudo git -C / reset --hard FETCH_HEAD 2>&1 | tail -3
        reset_rc=$?
    fi
fi

count=$(sudo git -C / ls-tree -r --name-only HEAD 2>/dev/null | wc -l)
echo "[quadlet-overlay] / now contains $count tracked mios.git files"
echo "[quadlet-overlay] / HEAD: $(sudo git -C / rev-parse --short HEAD 2>/dev/null)"

# Sanity: the smoke test expects /usr/share/mios. If git reset
# succeeded but the dir isn't there, surface that loudly so we
# don't silently ship a half-applied overlay.
if [[ ! -d /usr/share/mios ]]; then
    echo "[quadlet-overlay] ERROR: /usr/share/mios still missing after git reset"
    echo "[quadlet-overlay]   tracked usr/share/mios entries in HEAD:"
    sudo git -C / ls-tree -r --name-only HEAD 2>/dev/null | grep '^usr/share/mios/' | head -5 || true
    echo "[quadlet-overlay]   filesystem state of /usr/share:"
    ls -ld /usr/share/mios 2>&1 || true
    ls -la /usr/share/ 2>&1 | head -10 || true
fi

# Top-of-root SSOT shortcuts: mios.toml + configurator HTML at /
# so operators can `cat /mios.toml` and open `file:///configurator.html`
# from the dev VM browser. The deployed root IS the git working tree
# of mios.git, so these symlinks live in the same view as /.git --
# the operator's "single source of truth" surface is one cd / away.
sudo ln -sf usr/share/mios/mios.toml             /mios.toml             2>/dev/null || true
sudo ln -sf usr/share/mios/configurator/mios.html /configurator.html  2>/dev/null || true
echo "[quadlet-overlay] root symlinks: /mios.toml, /configurator.html"

# Realize sysusers + tmpfiles, then reload systemd so the new units
# (and Quadlet-generated *.service files) are visible.
#
# Critical: `wsl --exec` lands in the OUTER WSL namespace, not the
# nested process namespace where systemd actually runs (per the
# podman-machine welcome banner). Bare `systemctl daemon-reload`
# from this context fails with "Failed to set unit properties:
# Transport endpoint is not connected" / "Reload daemon failed".
# nsenter into systemd's PID with -a (all namespaces) gives the same
# view an interactive `wsl -d <distro>` session has, so systemctl
# reaches its bus and units register correctly.
SYSTEMD_PID=$(pidof systemd 2>/dev/null | tr ' ' '\n' | head -1)
if [[ -n "$SYSTEMD_PID" ]]; then
    NS="sudo nsenter -t $SYSTEMD_PID -a"
    echo "[quadlet-overlay] entering systemd ns (PID $SYSTEMD_PID) for systemctl calls"
else
    NS="sudo"
    echo "[quadlet-overlay] WARN: systemd PID not found -- systemctl calls may fail"
fi

echo "[quadlet-overlay] realizing sysusers / tmpfiles / daemon-reload ..."
$NS systemd-sysusers 2>&1 | tail -3 || true
$NS systemd-tmpfiles --create 2>&1 | tail -3 || true
$NS systemctl daemon-reload 2>&1 | tail -3 || true

# Set MiOS-DEV's default WSL2 user to mios (sysusers just created uid
# 1000=mios above). Without this, `wsl -d podman-MiOS-DEV` lands on
# whatever the machine-os tarball seeded as default (typically a bare
# `user` UID 1000, which exists but has none of the mios HOME / shell
# / groups setup). /etc/wsl.conf is read once at distro start, so the
# next `wsl --terminate podman-MiOS-DEV` + reentry picks this up.
# Idempotent: only ADDS [user] block if not already present.
echo "[quadlet-overlay] setting wsl.conf default user to mios"
if id mios >/dev/null 2>&1; then
    if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
        printf '\n[user]\ndefault=mios\n' | sudo tee -a /etc/wsl.conf >/dev/null
        echo "[quadlet-overlay] /etc/wsl.conf: appended [user] default=mios"
    elif ! grep -qE '^[[:space:]]*default[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
        sudo sed -i '/^\[user\]/a default=mios' /etc/wsl.conf
        echo "[quadlet-overlay] /etc/wsl.conf: inserted default=mios under existing [user]"
    elif ! grep -qE '^[[:space:]]*default[[:space:]]*=[[:space:]]*mios[[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
        sudo sed -i 's|^[[:space:]]*default[[:space:]]*=.*|default=mios|' /etc/wsl.conf
        echo "[quadlet-overlay] /etc/wsl.conf: rewrote default=<other> to default=mios"
    else
        echo "[quadlet-overlay] /etc/wsl.conf: default=mios already set"
    fi
else
    echo "[quadlet-overlay] WARN: mios user not found after sysusers; skipping wsl.conf default-user write"
fi

# Container-host prerequisites for the mios user. Manifesto says MiOS-DEV
# "should have the mios user appended as it will be needed for this MiOS-DEV
# machine to host its containers (mirroring the layered containers in MiOS
# at build time; guacamole, ollama, forgejo, cockpit etc-etc)". The
# systemd-sysusers run above creates the mios login user (uid 1000); the
# three steps below complete the container-hosting plumbing:
#
#   1. subuid/subgid append -- rootless podman needs an unprivileged uid
#      range available for user-namespace mapping. Standard convention is
#      one 64K-uid range starting at 524288 (well outside the host's
#      regular uid space). Idempotent: skip if mios is already present.
#
#   2. linger enable -- so systemd --user services (the Quadlets) start
#      at boot without an active interactive login session. Required for
#      `systemctl --user enable mios-forge.service` etc. to actually
#      launch the daemon at boot rather than waiting for a TTY login.
#
#   3. /var/home/mios skeleton seeded from /etc/skel -- FCOS / atomic-
#      desktops home convention; the deployed MiOS image uses
#      /var/home/<user> as $HOME so /etc 3-way merge doesn't have to
#      manage home-dir state. Establish the same on MiOS-DEV so any
#      operator-side configs (.bashrc, .config/) match across substrates.
echo "[quadlet-overlay] container-host prerequisites for mios user ..."
if id mios >/dev/null 2>&1; then
    if ! grep -q '^mios:' /etc/subuid 2>/dev/null; then
        echo 'mios:524288:65536' | sudo tee -a /etc/subuid >/dev/null
        echo "[quadlet-overlay]   /etc/subuid: mios:524288:65536"
    fi
    if ! grep -q '^mios:' /etc/subgid 2>/dev/null; then
        echo 'mios:524288:65536' | sudo tee -a /etc/subgid >/dev/null
        echo "[quadlet-overlay]   /etc/subgid: mios:524288:65536"
    fi
    if command -v loginctl >/dev/null 2>&1; then
        sudo loginctl enable-linger mios 2>/dev/null || true
        echo "[quadlet-overlay]   loginctl enable-linger mios"
    fi
    sudo install -d -m 0755 /var/home 2>/dev/null || true
    sudo install -d -m 0755 -o mios -g mios /var/home/mios 2>/dev/null || \
        sudo install -d -m 0755 /var/home/mios
    if [[ -d /etc/skel ]] && [[ ! -e /var/home/mios/.bashrc ]]; then
        sudo rsync -aH --ignore-existing /etc/skel/ /var/home/mios/ 2>/dev/null || true
        sudo chown -R mios:mios /var/home/mios 2>/dev/null || true
        echo "[quadlet-overlay]   /var/home/mios seeded from /etc/skel"
    fi
fi

# ALWAYS-ON LIGHTWEIGHT SET: Cockpit (web console at :9090), the
# Podman-Desktop discovery shim that surfaces MiOS containers in PD's
# UI, and the self-hosted Forgejo forge (small SQLite-backed git host).
# Plus NVIDIA CDI plumbing (mios-cdi-detect + nvidia-cdi-refresh) so
# Podman containers on MiOS-DEV can claim /dev/dxg (WSL2 GPU surface)
# via the same Container Device Interface spec a deployed bare-metal
# MiOS host uses. mios-cdi-detect.service auto-no-ops when no GPU is
# present (no /dev/nvidia0 / no /dev/dxg) and explicitly passes
# --mode=wsl to `nvidia-ctk cdi generate` when systemd-detect-virt
# reports wsl, so it works correctly on the dev VM out of the box.
# Each enable is best-effort -- a unit that ConditionVirtualization-skips
# itself just no-ops with status=inactive (success).
# Quadlet-generated *.service files (from etc/containers/systemd/*.container)
# live at /run/systemd/generator/ and are AUTO-WANTED via the [Install]
# section Quadlet's generator already processed at daemon-reload time.
# `systemctl enable` on them errors with "transient or generated" -- use
# `start` instead. Native systemd units (cockpit.socket, mios-cdi-detect,
# nvidia-cdi-refresh.path) take the standard `enable --now` path.
NATIVE_SET=(cockpit.socket mios-cdi-detect.service nvidia-cdi-refresh.path mios-ollama-firstboot.service)
QUADLET_SET=(mios-cockpit-link.service mios-forge.service ollama.service)

for svc in "${NATIVE_SET[@]}"; do
    if $NS systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
        echo "[quadlet-overlay] enable --now $svc"
        $NS systemctl enable --now "$svc" 2>&1 | grep -vE 'created symlink' || true
    else
        echo "[quadlet-overlay] skip $svc (unit not present -- pkg may be missing)"
    fi
done
for svc in "${QUADLET_SET[@]}"; do
    if $NS systemctl cat "$svc" >/dev/null 2>&1; then
        echo "[quadlet-overlay] start $svc (Quadlet-generated, auto-wanted)"
        $NS systemctl start "$svc" 2>&1 | grep -vE 'created symlink' || true
    else
        echo "[quadlet-overlay] skip $svc (Quadlet not yet rendered)"
    fi
done

# OPT-IN HEAVY SET: AI inference + Forgejo Runner. Gated by env vars
# threaded through from the PowerShell side -- defaults to skip so
# the dev VM doesn't pull multi-GB images on first boot.
if [[ "${MIOS_DEV_ENABLE_AI:-0}" == "1" ]]; then
    echo "[quadlet-overlay] start mios-ai + ollama (Quadlet-generated)"
    $NS systemctl start mios-ai.service ollama.service 2>&1 || true
fi
if [[ "${MIOS_DEV_ENABLE_RUNNER:-0}" == "1" ]]; then
    echo "[quadlet-overlay] start mios-forgejo-runner (Quadlet-generated)"
    $NS systemctl start mios-forgejo-runner.service 2>&1 || true
fi

# Install the operator-facing terminal flatpak so MiOS-DEV mirrors a
# deployed MiOS host's UX: open Ptyxis on the Windows desktop via WSLg
# -> default tab spawns into the host shell via flatpak-spawn --host
# -> the operator types `ollama list`, `mios "..."`, `mios-ollama chat
# "..."` and hits the Ollama Quadlet on :11434 + LocalAI on :8080
# directly. Idempotent (--or-update). Also pulls the few other
# substrate-class flatpaks (Nautilus, Bazaar, Flatseal) so the
# emulated MiOS environment carries its file manager and app store.
# Run the same canonical automation scripts the build pipeline uses,
# now that `/` IS mios.git's working tree. One install path, no
# parallel fetch logic to drift. Each script is best-effort
# (rc != 0 doesn't kill the overlay) and self-skips when the relevant
# binary already exists.
#
# 09-fonts.sh         Geist (Vercel) + Symbols-Only Nerd Font
# 38-oh-my-posh.sh    Oh-My-Posh static binary -> /usr/bin/oh-my-posh
# 37-ollama-prep.sh   ollama CLI tarball -> /usr/bin/ollama (build
#                     pipeline only baked models too; for the dev
#                     overlay we want the binary only -- the .container
#                     pulls models on first run)
echo "[quadlet-overlay] running canonical fetchers (fonts + oh-my-posh + ollama)..."
for script in /automation/09-fonts.sh \
              /automation/38-oh-my-posh.sh; do
    if [[ -x "$script" ]]; then
        echo "[quadlet-overlay] => $script"
        sudo bash "$script" 2>&1 | grep -vE '^\+ |^\+\+' | tail -5 || true
    fi
done

# ollama CLI: minimal install (binary only, no model bake). The
# in-build automation/37-ollama-prep.sh starts a transient ollama
# serve and pulls models -- skip that on the dev overlay; the
# Ollama Quadlet handles serving + the operator pulls models via
# `ollama pull <model>` on demand.
if ! command -v ollama >/dev/null 2>&1; then
    echo "[quadlet-overlay] fetching ollama CLI binary..."
    olm_arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && olm_arch="arm64"
    olm_tmp="$(mktemp -d)"
    olm_extract=""
    if curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${olm_arch}.tar.zst" \
            -o "$olm_tmp/ollama.tar.zst" 2>/dev/null \
            && tar --zstd -xf "$olm_tmp/ollama.tar.zst" -C "$olm_tmp" 2>/dev/null; then
        olm_extract="$olm_tmp"
    elif curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${olm_arch}.tgz" \
            -o "$olm_tmp/ollama.tgz" 2>/dev/null \
            && tar -xzf "$olm_tmp/ollama.tgz" -C "$olm_tmp" 2>/dev/null; then
        olm_extract="$olm_tmp"
    fi
    if [[ -n "$olm_extract" ]]; then
        olm_bin="$(find "$olm_extract" -type f -name ollama -perm -u+x 2>/dev/null | head -1)"
        if [[ -n "$olm_bin" ]]; then
            sudo install -m 0755 "$olm_bin" /usr/bin/ollama
            if [[ -d "$olm_extract/lib/ollama" ]]; then
                sudo install -d -m 0755 /usr/lib/ollama
                sudo cp -a "$olm_extract/lib/ollama/." /usr/lib/ollama/
            fi
            echo "[quadlet-overlay] ollama installed: $(/usr/bin/ollama --version 2>&1 | head -1)"
        fi
    else
        echo "[quadlet-overlay] WARN: ollama download failed -- /usr/bin/ollama not installed"
    fi
    rm -rf "$olm_tmp"
fi

echo "[quadlet-overlay] installing GNOME Flatpaks for WSLg portal (one-time, ~600MB)..."
sudo install -d -m 0755 /var/lib/flatpak
sudo flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
# Refresh the appstream index so the install loop below can resolve
# the app IDs. Without this step `flatpak install` errors with
# "Nothing matches <ref> in remote flathub" on a fresh remote.
sudo flatpak update --system --appstream flathub 2>&1 | tail -3 || true
# Substrate-class Flatpaks: terminal, file manager, app store, Flatpak
# permissions UI, default browser. Each routes through WSLg as a Windows
# desktop window; the gnome-flatpak-runtime RPM section provides the
# host-side portals/audio/theming these need to render correctly.
declare -A FLATPAK_SHORT=(
    [org.gnome.Ptyxis]=ptyxis
    [org.gnome.Nautilus]=nautilus
    [org.gnome.Software]=gnome-software
    [com.github.tchx84.Flatseal]=flatseal
    [org.gnome.Epiphany]=epiphany
    [com.vscodium.codium]=codium
)
for ref in "${!FLATPAK_SHORT[@]}"; do
    if ! flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$ref"; then
        # sudo prefix bypasses polkit's "Deploy not allowed for user"
        # gate on a fresh dev VM where polkit auth hasn't been
        # established yet. The sudoers drop-in below grants
        # passwordless sudo for the dev user, so this is silent.
        sudo flatpak install --system --noninteractive --assumeyes --or-update flathub "$ref" \
            2>&1 | grep -E '^(Installing|Updating|Already|Error|Warning)' || true
    fi
    # Drop a /usr/local/bin/<short> wrapper so operators can run
    # `nautilus`, `epiphany`, `ptyxis` directly instead of the
    # `flatpak run org.gnome.<App>` long form. /var/lib/flatpak/exports/
    # bin already publishes the AppID-named symlink; this adds the
    # short alias on top.
    #
    # The wrapper delegates to /usr/libexec/mios/flatpak-launch, which
    # restores the WSLg / Wayland / X11 / PulseAudio / D-Bus environment
    # whenever the parent shell stripped it (`su -`, `nsenter -m`, sudo
    # without -E, systemd-run, cron). Login shells under WSL pick those
    # vars up via /etc/profile.d/mios-wslg.sh, but a `bash -c 'nautilus'`
    # from a non-login context bypasses profile.d entirely -- which was
    # the failure mode the operator hit when `epiphany` errored with
    # "Cannot autolaunch D-Bus without X11 \$DISPLAY" after `su - mios`
    # under nsenter. The helper is idempotent: it only sets variables
    # that are unset, so a bare-metal GNOME session that already has a
    # working environment passes straight through.
    #
    # If /usr/libexec/mios/flatpak-launch is absent (older deployment
    # before this fix landed), fall back to the original direct-exec
    # form so the wrapper still launches the flatpak -- it just won't
    # benefit from the env restore.
    short="${FLATPAK_SHORT[$ref]}"
    # Regenerate the shim if it's missing OR if it doesn't reference
    # the flatpak-launch helper -- a previous bootstrap run before the
    # WSLg-env-restore fix landed produced shims that just `exec flatpak
    # run`, and those leave the operator with silent-window-failures
    # whenever they invoke the shim from a non-login shell. The grep
    # below makes the regeneration idempotent: re-runs are no-ops once
    # the shim already points at the helper.
    if [[ -n "$short" ]] \
       && { [[ ! -e "/usr/local/bin/$short" ]] \
            || ! grep -q '/usr/libexec/mios/flatpak-launch' "/usr/local/bin/$short" 2>/dev/null; }
    then
        sudo tee "/usr/local/bin/$short" >/dev/null <<WRAPPER
#!/bin/sh
# /usr/local/bin/$short -- MiOS shim for the $ref flatpak.
# Generated by mios-bootstrap/build-mios.ps1 :: Invoke-MiosQuadletOverlay.
if [ -x /usr/libexec/mios/flatpak-launch ]; then
    exec /usr/libexec/mios/flatpak-launch $ref "\$@"
fi
exec flatpak run --system $ref "\$@"
WRAPPER
        sudo chmod 0755 "/usr/local/bin/$short"
    fi
done

# Passwordless sudo for the dev VM's regular user account (uid 1000)
# so `sudo -u mios -i` and similar account-switch commands work without
# the mios user having a password set. /etc/sudoers.d/00-mios-dev is
# installed mode 0440 (the only mode sudoers.d will load) and has
# both the dev `user` account and the canonical `mios` account in the
# wheel-equivalent set.
DEV_USER=$(getent passwd 1000 | cut -d: -f1)
[[ -z "$DEV_USER" ]] && DEV_USER=user
if [[ ! -f /etc/sudoers.d/00-mios-dev ]]; then
    sudo tee /etc/sudoers.d/00-mios-dev >/dev/null <<SUDO
# MiOS-DEV passwordless sudo. Generated by Invoke-MiosQuadletOverlay.
# The dev VM is single-tenant on Windows; the operator already has
# host-level admin to reach the VM, so passwordless sudo here is no
# weaker than the surrounding trust boundary.
$DEV_USER ALL=(ALL) NOPASSWD: ALL
mios     ALL=(ALL) NOPASSWD: ALL
SUDO
    sudo chmod 0440 /etc/sudoers.d/00-mios-dev
    sudo visudo -c -f /etc/sudoers.d/00-mios-dev >/dev/null \
        && echo "[quadlet-overlay] sudoers drop-in installed for $DEV_USER + mios" \
        || { echo "[quadlet-overlay] WARN: sudoers drop-in failed visudo check; removing"; sudo rm -f /etc/sudoers.d/00-mios-dev; }
fi

# Default dev passwords for both `user` (uid 1000) and `mios` (uid >=1000
# system user from sysusers.d) so Cockpit's PAM auth at https://localhost:
# 9090/ works without manual passwd setup. The MiOS dashboard prints these
# credentials inline next to the Cockpit endpoint so the operator doesn't
# have to remember them. Single-tenant dev VM trust model -- documented
# on the dashboard, never used outside the dev surface.
echo "${DEV_USER}:mios" | sudo chpasswd 2>/dev/null && \
    echo "[quadlet-overlay] $DEV_USER password set to 'mios' (Cockpit login)"
echo "mios:mios" | sudo chpasswd 2>/dev/null && \
    echo "[quadlet-overlay] mios password set to 'mios'"

# ── Layer the FULL mios.toml [packages].sections set into MiOS-DEV ───────
# Per feedback_mios_dev_equals_mios.md and the 2026-05-06 directive
# "MIOS MUST CONTAIN EVERYTHING NEEDED TO SELF; dev, build, run, host,
# hosting, etc-etc TOML/HTML SHOULD BOTH REFLECT EACHOTHER AND DICTATE
# ANY AND ALL MIOS DEPLOYMENTS AND ENTRIES INCLUDING DEPLOYING MIOS DEV":
# the same package set that lands in a deployed MiOS host must land in
# MiOS-DEV at Phase 3 time, NOT deferred to mios-build-driver. Operator
# expects `just`, `btop`, `fastfetch`, `ripgrep`, etc. to be available
# the moment they enter the dev distro.
#
# Approach: parse /usr/share/mios/mios.toml [packages].sections (master
# inclusion list, configurator-controlled), filter by per-section
# .enable, dedupe pkgs, layer them via `rpm-ostree install` (machine-os
# is FCOS-based + ostree-managed; rpm-ostree is the canonical layered-
# package mechanism). --idempotent skips already-installed, --allow-
# inactive doesn't fail when a layered package's services can't start
# yet (e.g. needs reboot or kernel module not in WSL kernel).
#
# Best-effort: a non-zero rpm-ostree exit doesn't abort the seed. The
# dashboard MOTD's `untracked 28` cosmetic note is unrelated and
# unaffected.
TOML_FILE="/usr/share/mios/mios.toml"
# Tool inventory: log explicitly which package manager is available so
# the operator can see why a given fallback was chosen on this host.
echo "[quadlet-overlay] package manager inventory:"
echo "[quadlet-overlay]   rpm-ostree: $(command -v rpm-ostree 2>/dev/null || echo MISSING)"
echo "[quadlet-overlay]   dnf:        $(command -v dnf 2>/dev/null || echo MISSING)"
echo "[quadlet-overlay]   dnf5:       $(command -v dnf5 2>/dev/null || echo MISSING)"
echo "[quadlet-overlay]   python3:    $(command -v python3 2>/dev/null || echo MISSING)"
echo "[quadlet-overlay]   awk:        $(command -v awk 2>/dev/null || echo MISSING)"
echo "[quadlet-overlay]   toml file:  $TOML_FILE ($([[ -f "$TOML_FILE" ]] && echo present || echo MISSING))"

if [[ -f "$TOML_FILE" ]] && command -v awk >/dev/null 2>&1; then
    # Pure-awk TOML parser. machine-os 6.0's stripped FCOS base often
    # ships without python3, so the previous tomllib-based approach
    # silently skipped (visible in the 19:24 log as "WARN: rpm-ostree
    # or python3 not available"). Awk is in coreutils-equivalents on
    # every Linux base.
    #
    # Two-stage parse:
    #   1. Read [packages].sections array -> the master inclusion list.
    #   2. For each section name, read [packages.<name>].pkgs IF
    #      [packages.<name>].enable != false. Append to the global
    #      package list.
    # Output: deduped space-separated package names on stdout.
    parse_pkgs() {
        local toml="$1"
        # Stage 1: extract sections array
        local sections
        sections=$(awk '
            $0 == "[packages]" { in_master=1; line=""; next }
            /^\[/ && in_master { in_master=0 }
            in_master && /^[[:space:]]*sections[[:space:]]*=/ { collecting=1; line=$0 }
            in_master && collecting && NR > 1 {
                if (line != $0) line = line "\n" $0
                if ($0 ~ /\]/) {
                    sub(/^[^[]*\[/, "", line)
                    sub(/\].*$/, "", line)
                    gsub(/[[:space:]]/, "", line)
                    gsub(/,/, " ", line)
                    gsub(/"/, "", line)
                    print line
                    exit
                }
            }
        ' "$toml")
        # Stage 2: for each section, extract pkgs[] when enable != false
        local sec
        for sec in $sections; do
            awk -v target="[packages.$sec]" '
                $0 == target { in_sect=1; enable=1; collecting=0; next }
                /^\[/ && in_sect { exit }
                in_sect && /^[[:space:]]*enable[[:space:]]*=[[:space:]]*false/ { enable=0 }
                in_sect && /^[[:space:]]*pkgs[[:space:]]*=/ { collecting=1; line=$0 }
                in_sect && collecting {
                    if (line != $0) line = line "\n" $0
                    if ($0 ~ /\]/) {
                        if (enable) {
                            sub(/^[^[]*\[/, "", line)
                            sub(/\].*$/, "", line)
                            n = split(line, arr, /[,\n]/)
                            for (i=1; i<=n; i++) {
                                p = arr[i]
                                gsub(/[[:space:]]/, "", p)
                                gsub(/"/, "", p)
                                gsub(/#.*/, "", p)
                                if (p != "") print p
                            }
                        }
                        exit
                    }
                }
            ' "$toml"
        done | awk '!seen[$0]++' | tr '\n' ' '
    }

    PKG_LIST=$(parse_pkgs "$TOML_FILE")
    PKG_COUNT=$(echo "$PKG_LIST" | wc -w)
    echo "[quadlet-overlay] resolved $PKG_COUNT packages from mios.toml [packages].sections"

    if [[ $PKG_COUNT -gt 0 ]]; then
        # Try package managers in order of preference:
        # 1. rpm-ostree install (canonical on FCOS / machine-os; layered + apply-live)
        # 2. rpm-ostree usroverlay + dnf install (reset-on-deployment-switch but
        #    immediate effect; survives wsl --terminate within same boot)
        # 3. dnf install standalone (mutable-fs base or already-overlayed)
        installed_via=""
        if command -v rpm-ostree >/dev/null 2>&1; then
            echo "[quadlet-overlay] rpm-ostree install: $PKG_COUNT packages (first run 10-15 min; cached after)"
            # shellcheck disable=SC2086
            if sudo rpm-ostree install --idempotent --allow-inactive $PKG_LIST 2>&1 | tail -40; then
                installed_via="rpm-ostree"
                echo "[quadlet-overlay] rpm-ostree apply-live (best-effort, layered packages active immediately where possible)..."
                sudo rpm-ostree apply-live --allow-replacement 2>&1 | tail -10 || true
            else
                echo "[quadlet-overlay] WARN: rpm-ostree install returned non-zero, falling back to dnf"
            fi
        fi
        if [[ -z "$installed_via" ]] && command -v dnf >/dev/null 2>&1; then
            echo "[quadlet-overlay] dnf install fallback (rpm-ostree usroverlay -> dnf)..."
            sudo rpm-ostree usroverlay 2>&1 | tail -3 || true
            # shellcheck disable=SC2086
            if sudo dnf install -y --skip-unavailable $PKG_LIST 2>&1 | tail -40; then
                installed_via="dnf"
            fi
        fi
        if [[ -z "$installed_via" ]] && command -v dnf5 >/dev/null 2>&1; then
            echo "[quadlet-overlay] dnf5 install fallback..."
            sudo rpm-ostree usroverlay 2>&1 | tail -3 || true
            # shellcheck disable=SC2086
            if sudo dnf5 install -y --skip-unavailable $PKG_LIST 2>&1 | tail -40; then
                installed_via="dnf5"
            fi
        fi
        if [[ -n "$installed_via" ]]; then
            echo "[quadlet-overlay] package install: SUCCESS via $installed_via"
        else
            echo "[quadlet-overlay] ERROR: all package managers failed (rpm-ostree / dnf / dnf5)"
            echo "[quadlet-overlay]        machine-os may be locked-down past what live-install supports;"
            echo "[quadlet-overlay]        full set will land via mios-build-driver -> bootc switch"
        fi
    else
        echo "[quadlet-overlay] WARN: parser yielded EMPTY package list -- check awk parse logic vs $TOML_FILE"
    fi
else
    echo "[quadlet-overlay] WARN: $TOML_FILE absent or awk missing; cannot resolve package list"
fi

sudo install -d -m 0755 /var/lib/mios
sudo touch "$SENTINEL"

active=$($NS systemctl --no-legend list-units 'mios-*' 2>/dev/null | wc -l)
echo "[quadlet-overlay] done -- $active mios-* units active"
echo "[quadlet-overlay] Cockpit:        https://localhost:9090/  (host LAN reachable via mirrored networking)"
echo "[quadlet-overlay] Podman Desktop: containers under MiOS-DEV machine carry openInBrowser labels"
echo "[quadlet-overlay] Terminal:       Ptyxis flatpak ready -- launch via WSLg, default tab is host shell"
echo "[quadlet-overlay] Ollama:         set MIOS_DEV_ENABLE_AI=1 then re-run for the local Ollama Quadlet"
'@

    # CRLF -> LF: bash on Linux is allergic to \r in shebang lines /
    # heredoc terminators. The PowerShell here-string ships CRLF on
    # Windows; normalize before the script ever leaves the host.
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"

    # Stage the seed to a file on M:\ instead of base64-inlining it
    # through `bash -c`. f67e5ad (rpm-ostree install + python3 toml
    # parse) pushed the seed past Windows' CreateProcess arg-length
    # cap (~32K), and `wsl.exe -d <distro> --exec bash -c $stage`
    # died with "FATAL: Program 'wsl.exe' failed to run: The
    # filename or extension is too long" before the seed could even
    # touch the distro. Writing to a file + invoking by path keeps
    # the command line tiny.
    $stagingDir  = Join-Path $MiosBootstrapShadow '.tmp'
    if (-not (Test-Path $stagingDir)) {
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    }
    $stagedPath  = Join-Path $stagingDir 'quadlet-overlay-seed.sh'
    [System.IO.File]::WriteAllText($stagedPath, $overlayScript, [System.Text.UTF8Encoding]::new($false))

    # Convert Windows path -> WSL /mnt/<drive>/... path so the seed
    # script can be invoked from the WSL side without re-mounting.
    $stagedDrive = $stagedPath.Substring(0,1).ToLower()
    $stagedWsl   = "/mnt/$stagedDrive" + ($stagedPath.Substring(2) -replace '\\','/')

    $stage = "set -e; export MIOS_DEV_ENABLE_AI='$enableAi' MIOS_DEV_ENABLE_RUNNER='$enableRunner'; " +
             "bash '$stagedWsl' '$miosRootWsl'"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "quadlet-overlay: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log-Warn "Quadlet overlay rc=$LASTEXITCODE -- partial overlay possible (units may still be present; rerun safe)"
    } else {
        Log-Ok "MiOS Quadlet overlay applied to $DevDistro"
    }
}

function Invoke-GhcrLogin([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Log "ghcr-login: no token (set MIOS_GITHUB_TOKEN or provide one in phase 6)"
        return
    }
    Set-Step "Authenticating podman to ghcr.io..."
    $Token | & podman login ghcr.io --username "mios-dev" --password-stdin 2>&1 |
        ForEach-Object { Write-Log "ghcr-login: $_" }
    if ($LASTEXITCODE -eq 0) { Log-Ok "Authenticated to ghcr.io" }
    else { Log-Warn "ghcr.io login failed -- build may fail pulling base image" }
}

# ============================================================================
# DEPRECATED: Invoke-WindowsPodmanBuild
# ----------------------------------------------------------------------------
# This function (and its sibling helpers Invoke-WslBuild,
# Invoke-DeployPipeline, New-MiosHyperVVm below) belongs to the
# pre-self-replication architecture where Windows ran `podman build`
# directly. As of v0.2.4 (memory: feedback_mios_dev_is_the_builder)
# the dev VM IS the builder; Windows is provisioning + handoff ONLY.
# All Phase 9 Build paths run inside MiOS-DEV via mios-build-driver,
# triggered by the `mios build` verb (M:\MiOS\bin\mios-build.ps1).
#
# These functions are now UNREACHABLE: -BuildOnly / -FullBuild are
# force-deprecated at line 202 ($BootstrapOnly = $true), and every
# control-flow gate (`if ($BootstrapOnly)` returns; `if (-not
# $BootstrapOnly)` blocks) routes around them.
#
# Kept in-tree for one release cycle so git-blame still resolves the
# legacy callers; a follow-up commit will delete them outright.
# ============================================================================
function Invoke-WindowsPodmanBuild([string]$BaseImage, [string]$MiosUser, [string]$MiosHostname,
                                   [string]$AiModel = "qwen2.5-coder:7b",
                                   [string]$EmbedModel = "nomic-embed-text",
                                   [string]$BakeModels = "qwen2.5-coder:7b,nomic-embed-text") {
    # mios.git is now overlaid AT $MiosRepoDir root (M:\), per the
    # 2026-05-06 directive. The build context IS the overlay root.
    $repoPath = $MiosRepoDir

    # ── Universal MiOS-SEED merge ────────────────────────────────────────────
    # The Phase 2 overlay (lines ~4823+) already robocopies mios-bootstrap.git
    # onto $MiosRepoDir, so by the time we reach podman build the bootstrap
    # files (etc/skel/.config/mios/, etc/mios/profile.toml, mios.toml at root,
    # agent entry-point .md files) are already present in the build context.
    # seed-merge.ps1 is kept as a defensive idempotent re-run -- if the
    # operator added new files to mios-bootstrap.git between Phase 2 and
    # this phase, they get pulled in.
    $bootstrapPath = $MiosBootstrapShadow
    $seedScript    = Join-Path $bootstrapPath "seed-merge.ps1"
    if (Test-Path $seedScript) {
        Set-Step "Universal MiOS-SEED: overlay mios-bootstrap onto mios.git"
        try {
            & $seedScript -MiosDir $repoPath -BootstrapDir $bootstrapPath
            Log-Ok "Bootstrap overlay merged into build context (mios.git tree)"
        } catch {
            Log-Warn "seed-merge failed: $_"
            Log-Warn "Build will proceed with mios.git tree only -- bootstrap files (skel, mios.toml, agent .md) will NOT be in the OCI image"
        }
    } else {
        Log-Warn "seed-merge.ps1 not found at $seedScript -- skipping Universal SEED merge"
    }

    Set-Step "podman build (Windows client → $BuilderDistro)"
    Write-Log "BUILD START (Windows API build)  base=$BaseImage  user=$MiosUser  host=$MiosHostname  ai=$AiModel"

    # Run via cmd.exe so 2>&1 merges stderr (podman build progress) into stdout stream.
    # Build args propagate operator selections from the Phase-6 prompts
    # (or layered mios.toml [ai] defaults) into the Containerfile ARGs of
    # the same name. 37-ollama-prep.sh reads MIOS_OLLAMA_BAKE_MODELS to
    # decide which model set to bake into /usr/share/ollama/models.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman build --progress=plain --no-cache " +
                      "--build-arg `"BASE_IMAGE=$BaseImage`" " +
                      "--build-arg `"MIOS_USER=$MiosUser`" " +
                      "--build-arg `"MIOS_HOSTNAME=$MiosHostname`" " +
                      "--build-arg `"MIOS_FLATPAKS=`" " +
                      "--build-arg `"MIOS_AI_MODEL=$AiModel`" " +
                      "--build-arg `"MIOS_AI_EMBED_MODEL=$EmbedModel`" " +
                      "--build-arg `"MIOS_OLLAMA_BAKE_MODELS=$BakeModels`" " +
                      "-t localhost/mios:latest . 2>&1")
    $psi.WorkingDirectory       = $repoPath
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        # Write to detail log only -- no Write-Host here.
        # Printing raw build lines to the console scrolls the terminal buffer
        # and drifts the dashboard position on every tick.
        try { [System.IO.File]::AppendAllText($BuildDetailLog, $line + "`n", [Text.Encoding]::UTF8) } catch {}
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 150) { Show-Dashboard; $sw.Restart() }
    }
    $proc.WaitForExit()
    Write-Log "BUILD END (Windows)  exit=$($proc.ExitCode)  lines=$($script:LineCount)"
    return $proc.ExitCode
}

function Invoke-WslBuild([string]$Distro, [string]$BaseImage, [string]$AiModel,
                          [string]$MiosUser = "mios", [string]$MiosHostname = "mios",
                          [string]$EmbedModel = "nomic-embed-text",
                          [string]$BakeModels = "") {
    if ([string]::IsNullOrWhiteSpace($BakeModels)) {
        $BakeModels = "$AiModel,$EmbedModel"
    }
    # Authenticate to ghcr.io before any pull/build.  GHCR now returns 403 on
    # anonymous bearer-token requests for ublue-os images; a GitHub PAT is required.
    $tok = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
           elseif ($env:GITHUB_TOKEN)  { $env:GITHUB_TOKEN }
           else                         { $script:GhcrToken }
    Invoke-GhcrLogin -Token $tok

    # Detect access method: wsl.exe > podman machine ssh > Windows podman build
    $useWsl      = $false
    $useSsh      = $false
    $useWinBuild = $false
    try {
        $r = (& wsl.exe -d $Distro --exec bash -c "echo ok" 2>$null) -join ""
        if ($r.Trim() -eq "ok") { $useWsl = $true }
    } catch {}
    if (-not $useWsl) {
        try {
            $r = (& podman machine ssh $Distro -- bash -c "echo ok" 2>$null) -join ""
            if ($r.Trim() -eq "ok") { $useSsh = $true }
        } catch {}
    }
    if (-not $useWsl -and -not $useSsh) { $useWinBuild = $true }

    if ($useWinBuild) {
        return Invoke-WindowsPodmanBuild -BaseImage $BaseImage -MiosUser $MiosUser -MiosHostname $MiosHostname `
                                          -AiModel $AiModel -EmbedModel $EmbedModel -BakeModels $BakeModels
    }

    $justCheck = "command -v just &>/dev/null || dnf install -y just"
    if ($useSsh) {
        & podman machine ssh $Distro -- bash -c $justCheck 2>$null | Out-Null
    } else {
        & wsl.exe -d $Distro --user root --exec bash -c $justCheck 2>$null | Out-Null
    }

    # ── Universal MiOS-SEED merge (inside WSL distro) ─────────────────────────
    # Sync-RepoToDistro brought mios.git into / via `git fetch + reset --hard`.
    # That path strips untracked files, so we can't pre-merge on the Windows
    # side -- the merge has to happen INSIDE WSL after the sync, before
    # `just build` invokes podman build. Clone mios-bootstrap into
    # /tmp/mios-bootstrap, run seed-merge.sh against /, then build.
    Set-Step "Universal MiOS-SEED: overlay mios-bootstrap onto / inside $Distro"
    $bootstrapRepoUrl = if ($env:MIOS_BOOTSTRAP_REPO) { $env:MIOS_BOOTSTRAP_REPO } else { $MiosBootstrapUrl }
    $bootstrapRef     = if ($env:MIOS_BOOTSTRAP_REF)  { $env:MIOS_BOOTSTRAP_REF  } else { "main" }
    $seedScript = @"
set -e
if [ ! -d /tmp/mios-bootstrap/.git ]; then
    rm -rf /tmp/mios-bootstrap
    git clone --depth=1 --branch '$bootstrapRef' '$bootstrapRepoUrl' /tmp/mios-bootstrap
fi
if [ -x /tmp/mios-bootstrap/seed-merge.sh ]; then
    /tmp/mios-bootstrap/seed-merge.sh / /tmp/mios-bootstrap
else
    echo '[seed-merge] WARN: /tmp/mios-bootstrap/seed-merge.sh not found -- bootstrap overlay skipped' >&2
fi
"@
    if ($useSsh) {
        & podman machine ssh $Distro -- bash -c $seedScript 2>&1 | ForEach-Object { Write-Log "seed-merge: $_" }
    } else {
        & wsl.exe -d $Distro --user root --exec bash -c $seedScript 2>&1 | ForEach-Object { Write-Log "seed-merge: $_" }
    }
    if ($LASTEXITCODE -eq 0) {
        Log-Ok "Bootstrap overlay merged into WSL distro / (Universal MiOS-SEED)"
    } else {
        Log-Warn "seed-merge inside ${Distro} returned non-zero -- build will proceed; bootstrap files may be missing from the image"
    }

    Set-Step "Launching: just build (inside $Distro)"
    Write-Log "BUILD START  base=$BaseImage  model=$AiModel"

    # Stream build output line-by-line: update dashboard Step, write to log.
    #
    # Quoting note: the bash script body is wrapped in OUTER double
    # quotes (CreateProcess-recognized) so the script body stays a
    # single argv element through the wsl.exe / podman.exe handoff.
    # The inner single quotes around $BaseImage / $AiModel are then
    # bash-literal quoting -- preserved verbatim because CreateProcess
    # treats them as ordinary characters inside the "..." block.
    #
    # Earlier the script wrapped the whole thing in single quotes
    # (`'A=''val'' B=''val'' just build'`) which CreateProcess does
    # NOT recognize as quoting, so it split on the spaces between the
    # env-var pairs and bash got an unbalanced fragment, failing with:
    #   MIOS_AI_MODEL='':'-c: line 1: unexpected EOF...
    $bashScript = "cd / && MIOS_BASE_IMAGE='$BaseImage' MIOS_AI_MODEL='$AiModel' just build 2>&1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($useSsh) {
        $psi.FileName  = "podman"
        $psi.Arguments = "machine ssh $Distro -- bash -c `"$bashScript`""
    } else {
        $psi.FileName  = "wsl.exe"
        $psi.Arguments = "-d $Distro --user root --cd / --exec bash -c `"$bashScript`""
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        try { [System.IO.File]::AppendAllText($BuildDetailLog, $line + "`n", [Text.Encoding]::UTF8) } catch {}
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 150) { Show-Dashboard; $sw.Restart() }
    }

    $proc.WaitForExit()
    $rc = $proc.ExitCode
    Write-Log "BUILD END (WSL/SSH)  exit=$rc  lines=$($script:LineCount)"
    return $rc
}

function Export-WslTar([string]$OutFile) {
    # Stream localhost/mios:latest filesystem from machine → Windows tar via podman socket API
    Set-Step "Creating container snapshot of localhost/mios:latest..."
    $contLines = (& podman create localhost/mios:latest /bin/true 2>$null)
    $contId = ($contLines | Where-Object { $_ -match '^[0-9a-f]{12,64}$' } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($contId)) {
        $contId = ($contLines | Select-Object -Last 1)
    }
    if ([string]::IsNullOrWhiteSpace($contId)) { throw "podman create returned no container ID" }
    $contId = $contId.Trim()
    Write-Log "export container: $contId"
    try {
        Set-Step "Streaming container filesystem → $([System.IO.Path]::GetFileName($OutFile))..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "podman"
        $psi.Arguments              = "export $contId"
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $fs   = [System.IO.File]::Create($OutFile)
        $sw   = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $buf    = New-Object byte[] 65536
            $stream = $proc.StandardOutput.BaseStream
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $fs.Write($buf, 0, $n)
                if ($sw.ElapsedMilliseconds -ge 2000) {
                    $mb = [math]::Round($fs.Length / 1MB)
                    Set-Step "Exporting WSL2 tar... ${mb} MB"
                    $sw.Restart()
                }
            }
        } finally { $fs.Close() }
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "podman export exited $($proc.ExitCode)" }
        return $true
    } finally {
        & podman rm $contId 2>$null | Out-Null
    }
}

function Import-MiosWsl([string]$TarFile, [string]$InstallDir) {
    # Register WSL2 distro from tar (replaces existing 'MiOS' distro if present)
    if (-not (Test-Path $TarFile)) { throw "WSL2 tar not found: $TarFile" }
    try { & wsl.exe --unregister $MiosWslDistro 2>$null | Out-Null } catch {}
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    Set-Step "wsl --import $MiosWslDistro ..."
    & wsl.exe --import $MiosWslDistro $InstallDir $TarFile --version 2 2>&1 |
        ForEach-Object { Write-Log "wsl-import: $_" }
    if ($LASTEXITCODE -ne 0) { throw "wsl --import exited $LASTEXITCODE" }
    # Set default user in the new distro
    try {
        & wsl.exe -d $MiosWslDistro --user root --exec bash -c `
            "id mios &>/dev/null && echo '[user]\ndefault=mios' >> /etc/wsl.conf || true" 2>$null | Out-Null
    } catch {}
    return $true
}

function Invoke-BibBuild([string[]]$Types, [string]$MachineOutDir, [int]$TimeoutMin = 60) {
    # Run bootc-image-builder inside the machine via Windows podman API (→ machine socket)
    # Types: 'qcow2', 'raw', 'anaconda-iso', 'vmdk'
    $typeArgs = ($Types | ForEach-Object { "--type $_" }) -join " "
    Set-Step "BIB: $($Types -join '+')..."
    Write-Log "BIB start: types=$($Types -join ',')  out=$MachineOutDir"

    # Pre-create the output directory on the BUILDER MACHINE filesystem.
    # podman volume bind-mounts require the host-side path to exist before
    # the container starts; otherwise crun fails with `statfs ENOENT`.
    # CRITICAL: must run on the dev distro itself -- running `mkdir`
    # inside a transient alpine container only creates the dir in the
    # container's ephemeral fs, which evaporates before BIB starts.
    # Routed through Invoke-DistroSh so it works in both rename states.
    Set-Step "BIB: creating output dir on dev distro..."
    $machineName = if ($env:MIOS_BUILDER_MACHINE) { $env:MIOS_BUILDER_MACHINE } else { $DevDistro }
    Invoke-DistroSh -Bash "mkdir -p '$MachineOutDir' && chmod 0755 '$MachineOutDir'" -MachineName $machineName 2>&1 |
        ForEach-Object { Write-Log "bib-mkdir: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN: BIB output-dir mkdir returned $LASTEXITCODE -- BIB will likely fail with statfs ENOENT"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman run --rm --privileged --pull=newer " +
        "--security-opt label=type:unconfined_t " +
        "-v /var/lib/containers/storage:/var/lib/containers/storage " +
        "-v ${MachineOutDir}:/output:z " +
        "quay.io/centos-bootc/bootc-image-builder:latest " +
        "$typeArgs --local localhost/mios:latest 2>&1")
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $done = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        Write-Log "bib: $line"
        if ($sw.ElapsedMilliseconds -ge 2000) {
            $elapsed = [math]::Floor($timer.Elapsed.TotalMinutes)
            Set-Step "BIB ${elapsed}min: $($line.Substring(0,[math]::Min($line.Length,60)))"
            $sw.Restart()
        }
        if ($timer.Elapsed.TotalMinutes -ge $TimeoutMin) {
            Write-Log "WARN: BIB timeout after ${TimeoutMin}min -- killing"
            $proc.Kill()
            break
        }
    }
    $proc.WaitForExit()
    Write-Log "BIB end: exit=$($proc.ExitCode)"
    return $proc.ExitCode -eq 0
}

function Copy-FromMachine([string]$MachinePath, [string]$WinDest) {
    # podman machine cp MiOS-DEV:/path/in/machine C:\windows\path
    Set-Step "Copying $([System.IO.Path]::GetFileName($MachinePath)) from machine..."
    & podman machine cp "${BuilderDistro}:${MachinePath}" $WinDest 2>&1 |
        ForEach-Object { Write-Log "machine-cp: $_" }
    return ($LASTEXITCODE -eq 0)
}

function New-MiosHyperVVm([string]$RawPath, [int]$RamGB = 8) {
    if (-not (Get-Command New-VM -EA SilentlyContinue)) {
        Write-Log "Hyper-V module not available -- skipping VM creation"
        return $false
    }
    # Convert raw → vhdx if Convert-VHD is available
    $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhdx")
    if (Get-Command Convert-VHD -EA SilentlyContinue) {
        Set-Step "Converting raw → vhdx..."
        try {
            Convert-VHD -Path $RawPath -DestinationPath $vhdxPath -VHDType Dynamic -EA Stop
        } catch {
            Write-Log "Convert-VHD failed: $_ -- trying raw rename"
            $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhd")
            Copy-Item $RawPath $vhdxPath -Force
        }
    } else {
        # Raw can be used as a fixed VHD by Hyper-V if renamed .vhd
        $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhd")
        Copy-Item $RawPath $vhdxPath -Force
    }
    if (-not (Test-Path $vhdxPath)) { throw "VHDX/VHD not found after conversion" }

    # Remove existing VM if present
    $vmName = $MiosWslDistro
    try { Remove-VM -Name $vmName -Force -EA SilentlyContinue } catch {}

    Set-Step "Creating Hyper-V VM: $vmName..."
    $vm = New-VM -Name $vmName -MemoryStartupBytes ($RamGB * 1GB) `
                 -VHDPath $vhdxPath -Generation 2 -EA Stop
    Set-VMFirmware  -VMName $vmName -EnableSecureBoot Off
    Set-VMProcessor -VMName $vmName -Count ([math]::Max(2, [int]([Environment]::ProcessorCount / 2)))
    Set-VMMemory    -VMName $vmName -DynamicMemoryEnabled $true `
                    -MinimumBytes 2GB -MaximumBytes ($RamGB * 1GB)
    Log-Ok "Hyper-V VM '$vmName' created from $([System.IO.Path]::GetFileName($vhdxPath))"
    return $true
}

function Invoke-DeployPipeline([hashtable]$HW) {
    $artifactDir = Join-Path $MiosDistroDir "artifacts"
    $wslFsDir    = Join-Path $MiosDistroDir "MiOS"
    if (-not (Test-Path $artifactDir)) { New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null }
    if (-not (Test-Path $wslFsDir))    { New-Item -ItemType Directory -Path $wslFsDir    -Force | Out-Null }

    # ── Phase 10: Export WSL2 tar ──────────────────────────────────────────────
    Start-Phase 10
    $wslTar = Join-Path $artifactDir "mios-wsl2.tar"
    $wslOk  = $false
    try {
        $wslOk = Export-WslTar -OutFile $wslTar
        $sizeMB = [math]::Round((Get-Item $wslTar).Length / 1MB)
        Log-Ok "WSL2 tar: ${sizeMB}MB → $wslTar"
        End-Phase 10
    } catch {
        Log-Warn "WSL2 export: $_"
        End-Phase 10 -Warn
    }

    # ── Phase 11: Register WSL2 distro ────────────────────────────────────────
    Start-Phase 11
    if ($wslOk) {
        try {
            $null = Import-MiosWsl -TarFile $wslTar -InstallDir $wslFsDir
            Log-Ok "WSL2 distro '$MiosWslDistro' registered at $wslFsDir"
            End-Phase 11
        } catch {
            Log-Warn "WSL2 import: $_"
            End-Phase 11 -Warn
        }
    } else {
        Log-Warn "Skipped (no WSL2 tar)"
        End-Phase 11 -Warn
    }

    # ── Phase 12: BIB disk images (qcow2 + raw) ───────────────────────────────
    Start-Phase 12
    $bibMachineDir = "/tmp/mios-bib-output"
    $bibOk = $false
    try {
        $bibOk = Invoke-BibBuild -Types @('qcow2','raw') -MachineOutDir $bibMachineDir
        if ($bibOk) {
            # Copy artifacts from machine to Windows
            $cpOk = @{}
            foreach ($pair in @(
                @{ src="$bibMachineDir/qcow2/disk.qcow2"; dst=Join-Path $artifactDir "mios.qcow2" },
                @{ src="$bibMachineDir/image/disk.raw";   dst=Join-Path $artifactDir "mios.raw"   }
            )) {
                try {
                    $cpOk[$pair.dst] = Copy-FromMachine $pair.src $pair.dst
                    if ($cpOk[$pair.dst]) {
                        $sz = [math]::Round((Get-Item $pair.dst).Length / 1GB, 1)
                        Log-Ok "$([System.IO.Path]::GetFileName($pair.dst)): ${sz}GB"
                    }
                } catch { Write-Log "WARN: copy $($pair.src): $_" }
            }
            End-Phase 12
        } else {
            Log-Warn "BIB build failed (non-fatal -- OCI image still available in $BuilderDistro)"
            End-Phase 12 -Warn
        }
    } catch {
        Log-Warn "BIB phase: $_"
        End-Phase 12 -Warn
    }

    # ── Phase 13: Hyper-V VM from raw disk ────────────────────────────────────
    Start-Phase 13
    $rawPath = Join-Path $artifactDir "mios.raw"
    if ($bibOk -and (Test-Path $rawPath)) {
        try {
            $vmOk = New-MiosHyperVVm -RawPath $rawPath -RamGB ([math]::Max(4, [math]::Min($HW.RamGB / 2, 16)))
            if ($vmOk) { End-Phase 13 } else { Log-Warn "Hyper-V not available"; End-Phase 13 -Warn }
        } catch {
            Log-Warn "Hyper-V VM: $_"
            End-Phase 13 -Warn
        }
    } else {
        Log-Warn "Skipped (no raw disk image)"
        End-Phase 13 -Warn
    }
}

function Test-MiosDevDistroHealthy {
    # Smoke-test the freshly-provisioned MiOS-DEV podman machine before
    # we commit to renaming it. Verifies:
    #   1. wsl.exe can reach the distro (basic VM bootstrap done)
    #   2. systemd is running inside (services can be enabled)
    #   3. /usr tree has the MiOS overlay (33-mios-overlay sentinel present)
    #   4. podman API socket is reachable from the Windows host
    #
    # Returns $true on full success, $false otherwise (caller decides
    # whether to abort the rename or warn-and-continue). Errors bubble
    # up as warnings -- does NOT throw, so a partial-overlay state
    # doesn't kill the bootstrap.
    Set-Step "Smoke-testing $DevDistro before rename..."

    # The pre-rename distro is "podman-$DevDistro"; post-rename it's
    # just "$DevDistro". This function is called pre-rename so we
    # check both for safety.
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}
    $candidates = @("podman-$DevDistro", $DevDistro)
    $name = $wslList | Where-Object { $candidates -contains $_ } | Select-Object -First 1
    if (-not $name) {
        Log-Warn "smoke: neither podman-$DevDistro nor $DevDistro is registered"
        return $false
    }

    # 1. Basic responsiveness.
    $echoOut = ""
    try { $echoOut = (& wsl.exe -d $name -- /bin/sh -c 'echo ready' 2>&1) -join "" } catch {}
    if ($echoOut.Trim() -ne 'ready') {
        Log-Warn "smoke: $name did not respond to 'echo ready' (got: '$echoOut')"
        return $false
    }
    Log-Ok "smoke 1/4: $name is responsive"

    # 2. systemd up.
    $sysOut = ""
    try { $sysOut = (& wsl.exe -d $name --user root -- /bin/sh -c 'systemctl is-system-running 2>&1 || true' 2>&1) -join "" } catch {}
    # `running` (clean), `degraded` (some failed but functional), or
    # `starting` (still booting) are all acceptable -- only `offline`
    # / `unknown` (no systemd PID) blocks the rename.
    if ($sysOut.Trim() -match '^(offline|unknown)\s*$' -or [string]::IsNullOrWhiteSpace($sysOut)) {
        Log-Warn "smoke: systemd not reachable in $name (state: '$sysOut')"
        # Non-fatal -- some build flows skip systemd. Continue.
    } else {
        Log-Ok "smoke 2/4: systemd state '$($sysOut.Trim())' in $name"
    }

    # 3. MiOS overlay present.
    $overlayOut = ""
    try { $overlayOut = (& wsl.exe -d $name --user root -- /bin/sh -c 'test -d /usr/share/mios && echo present || echo missing' 2>&1) -join "" } catch {}
    if ($overlayOut.Trim() -ne 'present') {
        Log-Warn "smoke: /usr/share/mios overlay missing in $name (got: '$overlayOut')"
        # Non-fatal -- the overlay is applied at build time, not
        # bootstrap. The dev distro's Fedora rootfs is the only thing
        # we need pre-build.
    } else {
        Log-Ok "smoke 3/4: /usr/share/mios overlay present in $name"
    }

    # 4. Podman API reachable. Skipped post-rename (podman client
    # speaks to the SSH socket regardless of WSL distro name).
    # Retried with backoff: Phase 3's wsl --terminate (added in
    # 4a8e7f6 to make /etc/wsl.conf [user] default=mios take effect)
    # restarts the distro right before this smoke check runs, so
    # the podman API is warming up. Without retry the check fires
    # before the API socket is ready and emits a confusing warning.
    if ($name -eq "podman-$DevDistro") {
        $podOut = ""
        $okFmt = '^[0-9]+\.[0-9]+'
        $attempts = 5
        for ($i = 1; $i -le $attempts; $i++) {
            try { $podOut = (& podman --connection "${DevDistro}-root" version --format '{{.Server.Version}}' 2>&1) -join "" } catch { $podOut = "$_" }
            if ($podOut -match $okFmt) { break }
            if ($i -lt $attempts) { Start-Sleep -Seconds 2 }
        }
        if ($podOut -match $okFmt) {
            Log-Ok "smoke 4/4: podman API server v$($podOut.Trim())"
        } else {
            Log-Warn "smoke: podman API not responding after $attempts attempts (got: '$podOut')"
            # Non-fatal -- machine may still be warming up; first
            # `podman machine inspect` call after this will succeed.
        }
    }

    return $true
}

function Invoke-DistroSh {
    # Run a bash snippet inside the dev distro, picking the right
    # transport based on the rename state:
    #
    #   * Pre-rename (distro = "podman-MiOS-DEV"): use `podman machine
    #     ssh` -- works because podman's WSLDistroName() = podman-<name>.
    #   * Post-rename (distro = "MiOS-DEV"):       use `wsl -d MiOS-DEV`
    #     directly -- `podman machine ssh` here fails because podman
    #     hardcodes the `podman-` prefix in WSLDistroName().
    #
    # Both transports base64-encode the script to avoid CRLF mangling
    # by stdin pipelines, then `echo BASE64 | base64 -d | bash`
    # decodes and pipes the script to a fresh bash via stdin (bash
    # auto-execs when stdin is a pipe).
    #
    # Returns: the inner script's stdout. After invocation,
    # $LASTEXITCODE holds the inner bash exit code (set by the
    # native wsl.exe / podman.exe process, which propagates the
    # last pipeline stage).
    #
    # Callers MUST NOT do `return Invoke-DistroSh ...` if they want
    # both stdout and exit code -- assign to a variable and check
    # $LASTEXITCODE separately:
    #
    #     $out = Invoke-DistroSh -Bash "echo hello"
    #     if ($LASTEXITCODE -ne 0) { ... }
    #
    # All build-pipeline call sites that previously called
    # `podman machine ssh $BuilderDistro -- sudo bash -c "..."`
    # should route through this helper so the rename is transparent.
    param(
        [Parameter(Mandatory)] [string] $Bash,
        [string] $MachineName = $script:DevDistro,
        [switch] $NoSudo
    )
    $Bash = $Bash -replace "`r`n", "`n" -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Bash))
    # --user root makes sudo redundant on the wsl path; pre-rename
    # podman-machine-ssh runs as `core` so sudo is needed unless the
    # script is itself root-safe. Default = sudo on the ssh path,
    # bare bash on the wsl path.
    $sudoPrefix = if ($NoSudo) { '' } else { 'sudo ' }

    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}

    if ($wslList -contains $MachineName) {
        # Post-rename: wsl --user root, no sudo (already root).
        $inner = "echo $encoded | base64 -d | bash"
        & wsl.exe -d $MachineName --user root -- /bin/sh -c $inner
        return
    }
    if ($wslList -contains "podman-$MachineName") {
        # Pre-rename: podman machine ssh, sudo unless caller opts out.
        $inner = "echo $encoded | base64 -d | ${sudoPrefix}bash"
        & podman machine ssh $MachineName -- /bin/sh -c $inner
        return
    }
    Write-Log "Invoke-DistroSh: neither '$MachineName' nor 'podman-$MachineName' is registered" "ERROR"
    # Synthesize a non-zero exit code so callers' $LASTEXITCODE check fires.
    cmd /c "exit 127" | Out-Null
}

function Restore-PodmanPrefix {
    # Recovery: if a previous run of Rename-PodmanDevDistro renamed
    # the WSL distro from `podman-MiOS-DEV` to `MiOS-DEV`, every
    # subsequent `podman machine start/init/ssh` invocation fails
    # with WSL_E_DISTRO_NOT_FOUND -- podman hardcodes the `podman-`
    # prefix in WSLDistroName() and can't see the renamed distro.
    #
    # This function detects the renamed-but-broken state and reverses
    # the rename via export -> unregister -> import-with-prefix.
    # User-facing surfaces (dashboard, mios-dev launcher, icons)
    # already hide the prefix, so the operator still sees "MiOS-DEV"
    # everywhere they look.
    #
    # Idempotent: bails if podman-$DevDistro already exists or if
    # $DevDistro isn't registered at all.
    # Bypass: $env:MIOS_SKIP_PODMAN_RESTORE=1.
    if ($env:MIOS_SKIP_PODMAN_RESTORE -in @('1','true','TRUE','yes')) {
        return
    }
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}
    $renamed  = $wslList -contains $DevDistro
    $prefixed = $wslList -contains "podman-$DevDistro"
    if ($prefixed) { return }                # already correct
    if (-not $renamed) { return }            # nothing to restore from

    Set-Step "Restoring podman- prefix on $DevDistro (recovery)..."
    & wsl.exe --shutdown 2>$null | Out-Null
    $tmpTar = Join-Path $env:TEMP "mios-podman-restore-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar.gz"
    try {
        Log-Ok "Exporting $DevDistro -> $tmpTar"
        & wsl.exe --export $DevDistro $tmpTar 2>&1 | ForEach-Object { Write-Log "wsl-export: $_" }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpTar)) {
            Log-Warn "wsl --export $DevDistro failed; cannot restore podman prefix"
            return
        }
        & wsl.exe --unregister $DevDistro 2>&1 | ForEach-Object { Write-Log "wsl-unregister: $_" }
        if (-not (Test-Path $script:MiosDistroDir)) { New-Item -ItemType Directory -Path $script:MiosDistroDir -Force | Out-Null }
        $newPath = Join-Path $script:MiosDistroDir "podman-$DevDistro"
        Log-Ok "Re-importing as podman-$DevDistro at $newPath"
        & wsl.exe --import "podman-$DevDistro" $newPath $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import: $_" }
        if ($LASTEXITCODE -eq 0) {
            Log-Ok "Recovery complete: $DevDistro restored as podman-$DevDistro"
            Log-Warn "podman machine commands work again. User-facing labels still show '$DevDistro'."
        } else {
            Log-Warn "wsl --import podman-$DevDistro failed; restoring original $DevDistro"
            & wsl.exe --import $DevDistro (Join-Path $script:MiosDistroDir $DevDistro) $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import-fallback: $_" }
        }
    } finally {
        if (Test-Path $tmpTar) { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue }
    }
}

function Rename-PodmanDevDistro {
    # Drops the `podman-` prefix that `podman machine init` auto-adds
    # to its WSL2 distro: renames podman-MiOS-DEV -> MiOS-DEV so the
    # operator-facing distro name matches the project name everywhere
    # (Start Menu, dashboard, `wsl -d MiOS-DEV`, mios-dev shortcut).
    #
    # Procedure: export -> unregister -> import-with-new-name. Only
    # safe to call AFTER all `podman machine ssh` and `podman build`
    # operations have completed (subsequent `podman machine start/ssh`
    # commands will FAIL because podman hardcodes the `podman-` prefix
    # in WSLDistroName(); the operator's daily workflow uses `wsl -d
    # MiOS-DEV` or the `mios-dev` shortcut, both of which work).
    #
    # The Windows-side podman client connection (a fixed SSH URI at
    # 127.0.0.1:<port>/run/podman/podman.sock) is unaffected: the
    # socket lives inside the distro, the port-forward survives the
    # rename, and `podman cp / commit / build` continue to work as
    # long as the distro is started via `wsl -d MiOS-DEV`.
    #
    # Idempotent: if `podman-$DevDistro` is already absent and
    # `$DevDistro` is registered, skip with a no-op.
    # Bypass: $env:MIOS_SKIP_DISTRO_RENAME=1.
    if ($env:MIOS_SKIP_DISTRO_RENAME -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_DISTRO_RENAME set -- WSL distro rename skipped"
        return
    }
    Set-Step "Renaming podman-$DevDistro -> $DevDistro (drops podman- prefix)..."

    $oldName = "podman-$DevDistro"
    $newName = $DevDistro

    # Snapshot current registrations.
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}

    if ($wslList -contains $newName -and -not ($wslList -contains $oldName)) {
        Log-Ok "$newName already registered and $oldName absent -- nothing to rename"
        return
    }
    if (-not ($wslList -contains $oldName)) {
        Log-Warn "$oldName not registered -- nothing to rename (skipping)"
        return
    }
    if ($wslList -contains $newName) {
        Log-Warn "$newName already exists alongside $oldName -- skipping rename to avoid clobbering an existing distro. Run 'wsl --unregister $newName' manually if you want to redo this."
        return
    }

    # Stop the machine so the WSL VM has no active mounts when we
    # export. Errors here are non-fatal -- if podman wasn't running we
    # just proceed straight to wsl --shutdown.
    try { & podman machine stop $DevDistro 2>$null | Out-Null } catch {}
    & wsl.exe --shutdown 2>$null | Out-Null

    # Pick the new home path -- prefer the dedicated MiOS data disk if
    # present (already redirected by Update-MiosInstallPaths during
    # Install-WindowsBranding), else fall back to the standard distros
    # dir under %ProgramData%/%LOCALAPPDATA%.
    $newDistroDir = Join-Path $MiosDistroDir $newName
    if (-not (Test-Path $MiosDistroDir)) { New-Item -ItemType Directory -Path $MiosDistroDir -Force | Out-Null }

    # Export to a temp tarball, unregister the old, import with the
    # new name. wsl --export uses gzip-compressed tar by default since
    # Win11; we keep .tar.gz suffix explicit so the format is obvious.
    $tmpTar = Join-Path $env:TEMP "mios-distro-rename-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar.gz"
    try {
        Log-Ok "Exporting $oldName -> $tmpTar"
        & wsl.exe --export $oldName $tmpTar 2>&1 | ForEach-Object { Write-Log "wsl-export: $_" }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpTar)) {
            throw "wsl --export $oldName failed (exit $LASTEXITCODE)"
        }
        Log-Ok "Unregistering $oldName"
        & wsl.exe --unregister $oldName 2>&1 | ForEach-Object { Write-Log "wsl-unregister: $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "wsl --unregister $oldName failed (exit $LASTEXITCODE)"
        }
        Log-Ok "Importing as $newName at $newDistroDir"
        & wsl.exe --import $newName $newDistroDir $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import: $_" }
        if ($LASTEXITCODE -ne 0) {
            # Recovery: re-import as the old name so the operator isn't
            # left with NO dev distro at all.
            Log-Warn "wsl --import $newName failed -- restoring $oldName from tarball"
            & wsl.exe --import $oldName (Join-Path $MiosDistroDir $oldName) $tmpTar --version 2 2>&1 | ForEach-Object { Write-Log "wsl-import-recovery: $_" }
            throw "wsl --import $newName failed (exit $LASTEXITCODE) -- $oldName restored"
        }

        # Boot the new distro once so subsequent podman commands hit a
        # running VM. `wsl -d <name> -- echo` is the lightest possible
        # warm-start that doesn't depend on the distro's default user
        # being configured.
        & wsl.exe -d $newName -- /bin/sh -c 'echo ready' 2>&1 | ForEach-Object { Write-Log "wsl-warm: $_" }

        Log-Ok "Renamed: $oldName -> $newName ($newDistroDir)"
        Log-Warn "Note: 'podman machine start/ssh $newName' will fail (podman hardcodes the 'podman-' prefix). Use 'wsl -d $newName' or the 'mios-dev' shortcut instead. The Windows-side podman client (podman build/cp/commit) still works via the existing SSH connection."
    } catch {
        Log-Warn "Distro rename aborted: $_"
    } finally {
        if (Test-Path $tmpTar) {
            try { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function New-Shortcut([string]$Path,[string]$Target,[string]$Args="",[string]$Desc="",[string]$Dir="") {
    $ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Args) { $sc.Arguments = $Args }
    if ($Desc) { $sc.Description = $Desc }
    if ($Dir)  { $sc.WorkingDirectory = $Dir }
    $sc.Save()
}

function Install-MiosWindowsTools {
    # Install [packages.windows] CLI tools via winget BEFORE
    # Install-WindowsBranding runs. Reads the SSOT (mios.toml's
    # [packages.windows] table) so the package list is operator-tunable
    # via mios.html. Includes Microsoft.PowerShell (pwsh 7),
    # fastfetch, btop, sharkdp.bat/.fd, ripgrep, fzf, jq, gh, etc. --
    # everything the MiOS terminal experience depends on.
    #
    # Idempotent: probes existing install per-package (winget list
    # --exact) before re-installing. Refreshes $env:PATH on completion
    # so newly-installed binaries are reachable for the rest of this
    # session (Install-WindowsBranding's mios-launch.ps1 generation,
    # the M:\ profile body, etc.).
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log-Warn "winget not available -- [packages.windows] CLI tools NOT installed (fastfetch / btop / pwsh / etc. will be missing)"
        return
    }

    Set-Step "Installing [packages.windows] CLI tools via winget (SSOT: mios.toml)..."

    # Resolve [packages.windows].pkgs from mios.toml.  Layered overlay:
    # operator host override > vendor on M:\ > bootstrap shadow.  Each
    # candidate is read AND its [packages.windows].pkgs section is
    # checked -- the FIRST candidate that yields a non-empty list wins.
    # A host override at M:\etc\mios\mios.toml that lacks [packages.windows]
    # falls through to the vendor copy (the previous bug: the first
    # `Test-Path` hit broke the loop, then the regex failed against a
    # partial overlay, then the hardcoded fallback fired -- which the
    # operator flagged 2026-05-09 as "you are hardcoding mios build to
    # build a smaller version of itself").
    $rx        = '(?ms)^\[packages\.windows\]\s*$.*?^\s*pkgs\s*=\s*\[(?<list>.*?)\]\s*$'
    $pkgs      = @()
    $sourceOk  = ''
    $candidates = @('M:\etc\mios\mios.toml', 'M:\usr\share\mios\mios.toml', (Join-Path $MiosBootstrapShadow 'mios.toml'))
    foreach ($cand in $candidates) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
            $tomlText = [IO.File]::ReadAllText($cand, (New-Object System.Text.UTF8Encoding($false)))
        } catch { continue }
        $m = [regex]::Match($tomlText, $rx)
        if (-not $m.Success) { continue }
        $stripped = ($m.Groups['list'].Value -split "`n" |
                     ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
        $tryPkgs = @(
            $stripped -split ',' |
            ForEach-Object {
                $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                if ($s) { $s }
            }
        )
        if ($tryPkgs.Count -gt 0) {
            $pkgs     = $tryPkgs
            $sourceOk = $cand
            break
        }
    }
    if ($pkgs.Count -eq 0) {
        throw "Cannot resolve [packages.windows].pkgs from any of: $($candidates -join ', '). Per operator SSOT directive 'ALL values source from the toml' there is no hardcoded fallback. Verify [packages.windows] section is intact in mios.toml (vendor copy at M:\usr\share\mios\mios.toml is canonical -- run 'mios pull' to refresh, or re-run the irm|iex one-liner)."
    }
    Log-Ok "[packages.windows] resolved $($pkgs.Count) package(s) from $sourceOk"

    $installed = 0
    $skipped   = 0
    $failed    = 0
    foreach ($pkg in $pkgs) {
        try {
            $probe = & winget list --id $pkg --exact 2>$null
            if ($LASTEXITCODE -eq 0 -and (($probe -join "`n") -match [regex]::Escape($pkg))) {
                Log-Ok ("winget already-present: {0}" -f $pkg)
                $skipped++
                continue
            }
            Log-Ok ("winget installing: {0}..." -f $pkg)
            # NOT silenced -- visible output so failures are diagnosable.
            & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget --scope user 2>&1 |
                ForEach-Object { Write-Log ("winget[{0}]: {1}" -f $pkg, $_) }
            if ($LASTEXITCODE -eq 0) {
                Log-Ok "winget install: $pkg [OK]"
                $installed++
            } else {
                # Retry without --scope user (machine scope -- some packages
                # like Microsoft.PowerShell don't accept user scope).
                Log-Warn ("winget install: {0} user-scope exit {1} -- retrying without --scope" -f $pkg, $LASTEXITCODE)
                & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 |
                    ForEach-Object { Write-Log ("winget[{0}-retry]: {1}" -f $pkg, $_) }
                if ($LASTEXITCODE -eq 0) {
                    Log-Ok "winget install (retry): $pkg [OK]"
                    $installed++
                } else {
                    Log-Warn ("winget install: {0} FAILED (exit {1})" -f $pkg, $LASTEXITCODE)
                    $failed++
                }
            }
        } catch {
            Log-Warn ("winget install: {0} -- {1}" -f $pkg, $_.Exception.Message)
            $failed++
        }
    }
    Log-Ok ("[packages.windows] winget summary: {0} installed / {1} already-present / {2} failed" -f $installed, $skipped, $failed)

    # Aggressive PATH augmentation. winget install --scope user lands
    # binaries under %LOCALAPPDATA%\Microsoft\WinGet\Packages\<id>_*\
    # and updates User PATH -- but only on NEXT shell launch. Probe
    # those install dirs NOW + add them to both this-session $env:PATH
    # AND persist the additions to User PATH so next-launch shells
    # (the WT MiOS profile) inherit them.
    # winget binaries live in MULTIPLE places depending on scope and
    # whether the package's manifest registers a shim:
    #
    #   1. %LOCALAPPDATA%\Microsoft\WinGet\Links\        <-- THE WIN
    #      winget auto-creates .exe shims here for every user-scope
    #      package whose manifest declares a Commands entry. This is
    #      the canonical "winget bin dir" -- adding it to PATH makes
    #      EVERY winget user-scope package callable by its canonical
    #      name (rg, fzf, jq, bat, fd, gh, ...).
    #   2. %LOCALAPPDATA%\Microsoft\WinGet\Packages\<id>_*\...        <-- user-scope install root
    #   3. %ProgramFiles%\WinGet\Packages\<id>_*\...                  <-- machine-scope install root
    #
    # All three get walked + their binary-containing dirs added to PATH.
    $exeDirs = New-Object System.Collections.Generic.HashSet[string]
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    if (Test-Path $linksDir) { [void]$exeDirs.Add($linksDir) }

    foreach ($wingetRoot in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages')
    )) {
        if (-not (Test-Path $wingetRoot)) { continue }
        # Walk every package install dir up to 5 levels deep; if any
        # subdir contains a .exe, add that subdir to PATH. winget nests
        # binaries under various depths (vendor / arch / version / etc).
        try {
            Get-ChildItem -Path $wingetRoot -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue -Depth 5 |
                ForEach-Object {
                    if ($_.DirectoryName) { [void]$exeDirs.Add($_.DirectoryName) }
                }
        } catch {}
    }
    $extraPaths = @($exeDirs)
    # MiOS app bin directory (oh-my-posh.exe, etc. that build-mios.ps1 stages itself).
    if (Test-Path $MiosBinDir) { $extraPaths += $MiosBinDir }
    $extraPaths = $extraPaths | Sort-Object -Unique

    # Refresh + augment $env:PATH for the current session.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $combined  = (@($_machPath, $_userPath) + $extraPaths | Where-Object { $_ }) -join ';'
        $env:PATH  = $combined
        Log-Ok ('$env:PATH refreshed (+{0} winget package dirs)' -f $extraPaths.Count)
    } catch {
        Log-Warn "PATH refresh failed: $($_.Exception.Message)"
    }

    # Persist the extra dirs to User PATH so future shell launches (the
    # WT MiOS profile spawn) see fastfetch / btop / etc. without
    # depending on this session.
    if ($extraPaths.Count -gt 0) {
        try {
            $userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
            $userParts = if ($userPath) { $userPath -split ';' } else { @() }
            $newParts  = @($userParts) + ($extraPaths | Where-Object { $_ -and ($userParts -notcontains $_) })
            $newUserPath = ($newParts | Where-Object { $_ }) -join ';'
            if ($newUserPath -ne $userPath) {
                [System.Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
                Log-Ok ('User PATH persisted (+{0} new dirs)' -f ($newParts.Count - $userParts.Count))
            }
        } catch {
            Log-Warn "User PATH persist failed: $($_.Exception.Message)"
        }
    }

    # Direct-download fallbacks for binaries that winget either failed
    # to install (broken Store manifest, missing applicable installer)
    # or installed under a non-canonical name (btop4win.exe instead of
    # btop.exe). Land them in $MiosBinDir so they're on PATH alongside
    # oh-my-posh.exe.
    if (-not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Log-Ok 'fastfetch: winget unsuccessful -- attempting direct download from GitHub releases...'
        try {
            $api = 'https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest'
            $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
            $asset = $rel.assets | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1
            if ($asset) {
                $zip = Join-Path $env:TEMP "fastfetch-$(Get-Random).zip"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                $extractRoot = Join-Path $env:TEMP "fastfetch-$(Get-Random)"
                Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
                $exe = Get-ChildItem -Path $extractRoot -Recurse -Filter 'fastfetch.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) {
                    Copy-Item -Path $exe.FullName -Destination (Join-Path $MiosBinDir 'fastfetch.exe') -Force
                    Log-Ok ("fastfetch installed direct: {0} -> {1}" -f $asset.name, (Join-Path $MiosBinDir 'fastfetch.exe'))
                }
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Log-Warn 'fastfetch: no windows-amd64.zip asset found in latest release'
            }
        } catch { Log-Warn ("fastfetch direct-download failed: {0}" -f $_.Exception.Message) }
    }

    # btop: winget package id is `aristocratos.btop4win` and the
    # binary is `btop4win.exe` (not `btop.exe`). Find the install,
    # symlink/copy it as `btop.exe` into $MiosBinDir so the canonical
    # `btop` command works. Also fall back to direct download from
    # GitHub releases if the winget install missed.
    if (-not (Get-Command btop -ErrorAction SilentlyContinue)) {
        Log-Ok 'btop: probing winget btop4win install + GitHub fallback...'
        $btopExe = $null
        $wingetBtop = Get-ChildItem -Path $wingetRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^aristocratos\.btop4win' } |
            Select-Object -First 1
        if ($wingetBtop) {
            $cand = Get-ChildItem -Path $wingetBtop.FullName -Recurse -Filter 'btop4win.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $btopExe = $cand.FullName }
        }
        if (-not $btopExe) {
            try {
                $api = 'https://api.github.com/repos/aristocratos/btop4win/releases/latest'
                $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
                $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
                if ($asset) {
                    $zip = Join-Path $env:TEMP "btop4win-$(Get-Random).zip"
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                    $extractRoot = Join-Path $env:TEMP "btop4win-$(Get-Random)"
                    Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
                    $cand = Get-ChildItem -Path $extractRoot -Recurse -Filter 'btop4win.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($cand) { $btopExe = $cand.FullName }
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    # Don't delete $extractRoot -- $btopExe needs to keep existing.
                }
            } catch { Log-Warn ("btop direct-download failed: {0}" -f $_.Exception.Message) }
        }
        if ($btopExe -and (Test-Path -LiteralPath $btopExe)) {
            $dst = Join-Path $MiosBinDir 'btop.exe'
            try {
                Copy-Item -Path $btopExe -Destination $dst -Force
                Log-Ok ("btop installed: {0} -> {1}" -f $btopExe, $dst)
            } catch { Log-Warn ("btop copy failed: {0}" -f $_.Exception.Message) }
        }
    }

    # Re-run final PATH refresh -- pick up any direct-download binaries.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH  = (@($_machPath, $_userPath, $MiosBinDir) | Where-Object { $_ }) -join ';'
    } catch {}

    # Final verification -- which targeted binaries are actually on PATH
    # now? Probe list resolves through mios.toml [packages.windows].
    # verify_probes (NEW key) so operators can extend/shrink the
    # post-install verification surface via mios.html.
    $_probes = @(Get-MiosTomlValue -Section 'packages.windows' -Key 'verify_probes' -Default @('fastfetch','btop','rg','fzf','jq','gh','bat','fd','pwsh','oh-my-posh'))
    foreach ($probe in $_probes) {
        if (Get-Command $probe -ErrorAction SilentlyContinue) {
            Log-Ok ("verify: '{0}' is on PATH" -f $probe)
        } else {
            Log-Warn ("verify: '{0}' NOT on PATH (winget install may have failed; check above)" -f $probe)
        }
    }
}

function Install-WindowsBranding {
    # Mirror MiOS's Linux branding (Geist + Symbols-Only Nerd Font +
    # oh-my-posh) onto the Windows host so PowerShell, Windows Terminal,
    # and any Windows-side terminal that opens MiOS-DEV (Ptyxis flatpak
    # via WSLg, or just `wsl -d podman-MiOS-DEV`) renders the same
    # MiOS-themed prompt with the same glyphs.
    #
    # Installs:
    #   1. Geist + Symbols-Only Nerd Font in %LOCALAPPDATA%\Microsoft\
    #      Windows\Fonts (per-user, no admin needed). Registered via
    #      HKCU registry so all Windows apps see them.
    #   2. oh-my-posh.exe in %LOCALAPPDATA%\Programs\oh-my-posh\bin\
    #      and added to the user's PATH.
    #   3. PowerShell profile snippet that initializes oh-my-posh with
    #      the MiOS theme (mios.omp.json from the cloned mios.git repo,
    #      copied to %APPDATA%\MiOS\mios.omp.json so the profile can
    #      reach it without depending on $MiosRepoDir resolution).
    #
    # Idempotent: each step probes for existing installs first.
    # Bypass: $env:MIOS_SKIP_WINDOWS_BRANDING=1.
    if ($env:MIOS_SKIP_WINDOWS_BRANDING -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_WINDOWS_BRANDING set -- Windows branding install skipped"
        return
    }

    # Re-resolve the install root: if the MIOS-DEV data disk is up
    # (M:\ by default) ALL install paths move onto it (full-partition
    # overlay). On a re-run that started before the data disk
    # existed, this is also where leftover C:\MiOS content gets
    # auto-migrated onto M:\MiOS so the operator never has to clean
    # up split-state across drives.
    $resolvedRoot = Resolve-MiosInstallRoot
    if ($resolvedRoot -ne $script:MiosInstallDir) {
        $legacyRoot = $script:MiosInstallDir
        Log-Ok "MiOS data disk detected -- redirecting install root: $legacyRoot -> $resolvedRoot"
        Update-MiosInstallPaths -NewRoot $resolvedRoot
        Invoke-MigrateLegacyInstallRoot -LegacyRoot $legacyRoot
    }
    Set-Step "Installing oh-my-posh + Geist + Nerd fonts under $($script:MiosInstallDir)..."

    # ── 1. Fonts (per-user; no admin needed) ─────────────────────────
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
    $regKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }

    function Install-FontFile([string]$Source) {
        try {
            $name = [System.IO.Path]::GetFileName($Source)
            $dest = Join-Path $fontDir $name
            if (Test-Path $dest) { return $false }
            Copy-Item -Path $Source -Destination $dest -Force
            $ext  = [System.IO.Path]::GetExtension($name).ToLower()
            $face = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $regName = if ($ext -eq '.otf') { "$face (OpenType)" } else { "$face (TrueType)" }
            New-ItemProperty -Path $regKey -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            return $true
        } catch { Write-Log "font-install: $name : $($_.Exception.Message)" "WARN"; return $false }
    }

    # Geist (Vercel) -- shallow clone the upstream repo, copy *.otf + *.ttf
    $geistTmp = Join-Path $env:TEMP "mios-geist-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        $null = Invoke-NativeQuiet { git clone --depth=1 --quiet https://github.com/vercel/geist-font.git $geistTmp }
        if (Test-Path $geistTmp) {
            $count = 0
            Get-ChildItem -Path $geistTmp -Recurse -Include '*.otf','*.ttf' | ForEach-Object {
                if (Install-FontFile -Source $_.FullName) { $count++ }
            }
            Log-Ok "Geist fonts installed (Windows per-user, $count new)"
        } else { Log-Warn "Geist clone failed -- skipping Windows font install" }
    } finally {
        if (Test-Path $geistTmp) { Remove-Item $geistTmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Symbols-Only Nerd Font (Powerline + Devicon glyphs the omp theme uses)
    $nerdTmp = Join-Path $env:TEMP "mios-nerd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $nerdTmp -Force | Out-Null
    try {
        $nerdUrl = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip'
        $nerdZip = Join-Path $nerdTmp 'NerdFontsSymbolsOnly.zip'
        Invoke-WebRequest -Uri $nerdUrl -OutFile $nerdZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $nerdZip -DestinationPath $nerdTmp -Force
        $count = 0
        Get-ChildItem -Path $nerdTmp -Recurse -Include '*.otf','*.ttf' | ForEach-Object {
            if (Install-FontFile -Source $_.FullName) { $count++ }
        }
        Log-Ok "Symbols-Only Nerd Font installed (Windows per-user, $count new)"
    } catch { Log-Warn "Nerd Font fetch failed: $($_.Exception.Message)" }
    finally { if (Test-Path $nerdTmp) { Remove-Item $nerdTmp -Recurse -Force -ErrorAction SilentlyContinue } }

    # ── 2. oh-my-posh.exe (installed into $MiosBinDir) ───────────────
    # Single canonical install location: $MiosInstallDir\bin (= C:\MiOS\bin
    # for admin installs, %LOCALAPPDATA%\MiOS\bin otherwise) so all MiOS
    # tooling lives under one root and a single PATH entry covers them.
    New-Item -ItemType Directory -Path $MiosBinDir -Force | Out-Null
    $ompExe  = Join-Path $MiosBinDir 'oh-my-posh.exe'
    if (-not (Test-Path $ompExe)) {
        try {
            $arch = if ([Environment]::Is64BitOperatingSystem) {
                if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
            } else { '386' }
            $url = "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-windows-$arch.exe"
            Invoke-WebRequest -Uri $url -OutFile $ompExe -UseBasicParsing -ErrorAction Stop
            Log-Ok "oh-my-posh.exe installed at $ompExe"
        } catch { Log-Warn "oh-my-posh download failed: $($_.Exception.Message)"; return }
    }

    # Add $MiosBinDir to PATH (machine-wide for admin installs, user
    # otherwise) so `oh-my-posh`, `mios-dash`, `mios-dev`, etc. all
    # resolve from any new shell.
    $pathScope = if ($script:IsAdmin) { 'Machine' } else { 'User' }
    $envPath = [Environment]::GetEnvironmentVariable('Path', $pathScope)
    if (-not ($envPath -split ';' | Where-Object { $_ -ieq $MiosBinDir })) {
        [Environment]::SetEnvironmentVariable('Path', "$envPath;$MiosBinDir", $pathScope)
        Log-Ok "Added $MiosBinDir to $pathScope PATH"
    }

    # ── 3. PowerShell profile + theme ────────────────────────────────
    # mios.git overlay puts the theme at $MiosRepoDir\usr\share\mios\...
    # (per 2026-05-06 "M:\ IS git" directive). The mios-bootstrap shadow
    # is checked as a defensive fallback.
    $miosThemeSrc = Join-Path $MiosRepoDir 'usr\share\mios\oh-my-posh\mios.omp.json'
    if (-not (Test-Path $miosThemeSrc)) {
        $miosThemeSrc = Join-Path $MiosBootstrapShadow 'usr\share\mios\oh-my-posh\mios.omp.json'
    }
    if (Test-Path $miosThemeSrc) {
        New-Item -ItemType Directory -Path $MiosThemesDir -Force | Out-Null
        $themeDst = Join-Path $MiosThemesDir 'mios.omp.json'
        Copy-Item -Path $miosThemeSrc -Destination $themeDst -Force
        # Substitute powerline glyphs from mios.toml [theme.prompt] (SSOT).
        # The on-disk omp.json ships with vendor-default rounded caps
        # ( / ); operators who switch to sharp triangles or
        # flat separators via mios.html overwrite [theme.prompt].
        # powerline_right / .powerline_left / .leading_diamond / .trailing_diamond
        # which we patch into the staged copy here. Per operator: "no
        # hardcoding ANYWHERE -- everything from the toml/html".
        try {
            $_pwRight = Get-MiosTomlValue -Section 'theme.prompt' -Key 'powerline_right'  -Default ''
            $_pwLeft  = Get-MiosTomlValue -Section 'theme.prompt' -Key 'powerline_left'   -Default ''
            $_ldDia   = Get-MiosTomlValue -Section 'theme.prompt' -Key 'leading_diamond'  -Default ''
            $_trDia   = Get-MiosTomlValue -Section 'theme.prompt' -Key 'trailing_diamond' -Default ''
            $_omp = Get-Content -LiteralPath $themeDst -Raw -Encoding UTF8
            # Map each TOML glyph to its JSON-escaped \uXXXX equivalent
            # so the on-disk file remains ASCII-safe (the source omp.json
            # explicitly notes "Nerd Font private-use-area glyphs are
            # encoded as \uXXXX so the file roundtrips through any editor
            # without losing the U+E000..F8FF code points").
            function _Esc([string]$s) {
                if (-not $s) { return $null }
                $cp = [int][char]$s[0]
                return ('\u{0:x4}' -f $cp)
            }
            $_eR = _Esc $_pwRight; $_eL = _Esc $_pwLeft; $_eLD = _Esc $_ldDia; $_eTD = _Esc $_trDia
            # Replace every powerline_symbol occurrence by VALUE -- the
            # current vendor default is  (right) or  (left);
            # we don't know which segments use which without parsing,
            # so we substitute by current literal in two passes.
            if ($_eR -and $_eR -ne '') { $_omp = $_omp -replace '\\ue0b4', $_eR }
            if ($_eL -and $_eL -ne '') { $_omp = $_omp -replace '\\ue0b6', $_eL }
            # leading_diamond / trailing_diamond appear only on diamond-
            # style segments (the leading text + trailing time caps).
            # Patch by JSON key: "leading_diamond": "" -> the new
            # value. Same for trailing_diamond.
            if ($_eLD -and $_eLD -ne '') {
                $_omp = $_omp -replace '("leading_diamond"\s*:\s*")\\u[0-9a-fA-F]{4}', ('${1}' + $_eLD)
            }
            if ($_eTD -and $_eTD -ne '') {
                $_omp = $_omp -replace '("trailing_diamond"\s*:\s*")\\u[0-9a-fA-F]{4}', ('${1}' + $_eTD)
            }
            # ── Color substitution from mios.toml [colors] (SSOT) ───
            # Per operator 2026-05-09: "oh my posh and other settings
            # should source from the same toml sections for all
            # platform for theme/branding to be truly unified in code."
            # The on-disk omp.json ships with vendor-default Hokusai
            # palette hex codes that EXACTLY match the [colors] vendor
            # defaults; substituting by literal hex lets operator
            # palette overrides via mios.html flow into every MiOS
            # terminal without touching this script.  Brand colors
            # (Python yellow, Node green, Rust orange, Go cyan) stay
            # hardcoded -- they're universal language identity, not
            # MiOS palette.
            $_palette = @(
                @{ Token='accent';  VendorHex='#1A407F' }
                @{ Token='fg';      VendorHex='#E7DFD3' }
                @{ Token='bg';      VendorHex='#282262' }
                @{ Token='cursor';  VendorHex='#F35C15' }
                @{ Token='success'; VendorHex='#3E7765' }
                @{ Token='error';   VendorHex='#DC271B' }
                @{ Token='muted';   VendorHex='#948E8E' }
                @{ Token='subtle';  VendorHex='#B7C9D7' }
                @{ Token='earth';   VendorHex='#734F39' }
            )
            foreach ($_pe in $_palette) {
                $_resolved = Get-MiosTomlValue -Section 'colors' -Key $_pe.Token -Default $_pe.VendorHex
                if ($_resolved -and $_resolved -ne $_pe.VendorHex -and $_resolved -match '^#[0-9A-Fa-f]{3,8}$') {
                    $_omp = [regex]::Replace($_omp, [regex]::Escape($_pe.VendorHex), $_resolved, 'IgnoreCase')
                }
            }
            Set-Content -LiteralPath $themeDst -Value $_omp -Encoding UTF8 -NoNewline
            Log-Ok "omp.json glyphs + palette synced from mios.toml [theme.prompt] + [colors]"
        } catch {
            Log-Warn "omp.json [theme.prompt] substitution failed: $($_.Exception.Message) -- shipped defaults retained"
        }
        Log-Ok "MiOS oh-my-posh theme staged at $themeDst"

        # Inject (or refresh) a thin REDIRECTOR in the user's PowerShell
        # profile. The redirector dot-sources M:\MiOS\powershell\profile.ps1
        # (the SSOT). Per operator: "EVERYTHING MIOS RELATED--EVEN WINDOWS
        # COMPONENTS INSTALLED--ARE ALL INSTALLED ON THE CREATED M:\
        # Drive/Partition!!!". The previous behaviour wrote the full
        # oh-my-posh init body into $PROFILE.CurrentUserAllHosts (i.e.
        # %USERPROFILE%\Documents\PowerShell\profile.ps1, on C:\) which
        # duplicated logic between the redirector and the M:\ profile.
        # Now $PROFILE is a 4-line shim: M:\ has the actual body. Marker
        # comments delimit the MiOS-managed block so re-runs are
        # idempotent (we replace the block, not append).
        $profilePath = $PROFILE.CurrentUserAllHosts
        if (-not $profilePath) { $profilePath = $PROFILE }
        $profileDir  = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
        $marker   = '# >>> MiOS oh-my-posh init >>>'
        $endMark  = '# <<< MiOS oh-my-posh init <<<'
        $miosProfilePath = if (Test-Path 'M:\') { 'M:\MiOS\powershell\profile.ps1' }
                            else { Join-Path $env:USERPROFILE 'MiOS-bootstrap\powershell\profile.ps1' }
        $block = @"
$marker
# Auto-generated redirector. The MiOS profile body (PSReadLine reload +
# oh-my-posh init + fastfetch MOTD + dashboard) lives at M:\ as the
# SSOT; this block is replaced on every re-run between the markers.
`$_miosProfile = '$miosProfilePath'
if (Test-Path `$_miosProfile) { . `$_miosProfile }
$endMark
"@
        # Marker-delimited block replace (idempotent across re-runs).
        # The replacement string is fed to .NET Regex.Replace which
        # treats $0/$1/$& specially -- escape any literal $ inside the
        # block content so a `$miosTheme` template substring doesn't
        # accidentally turn into a backreference.
        if ($existing -match [regex]::Escape($marker)) {
            $pattern  = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMark))"
            $safeRepl = $block -replace '\$', '$$$$'
            $existing = [regex]::Replace($existing, $pattern, $safeRepl)
        } else {
            $existing = ($existing.TrimEnd() + "`n`n" + $block + "`n").TrimStart()
        }
        Set-Content -Path $profilePath -Value $existing -Encoding UTF8 -NoNewline
        Log-Ok "PowerShell profile updated: $profilePath"
    } else {
        Log-Warn "MiOS oh-my-posh theme not found in cloned repos -- profile not updated"
    }

    Log-Ok "Windows-side branding installed (open a NEW pwsh window to see the MiOS prompt)"
}

function New-MiosIcon {
    # Generate one multi-size .ico (16/32/48/64/256) styled to match the
    # MiOS dashboard ASCII art: an isometric 3D cube (top + left-front +
    # right-front faces) with `/:\`-style hatch marks on each face,
    # echoing the wireframe blocks of the MIOS letters in the dashboard
    # banner. The cube is rendered in the MiOS palette (Hokusai bg,
    # cream front, accent orange top), with an optional badge in the
    # bottom-right corner for action-verb shortcuts.
    #
    # Visual rationale: at 16-32 px the letter "M" is unrecognizable,
    # but the iso-cube silhouette + hatched faces stay readable and
    # clearly map back to the dashboard art. The badge layer
    # disambiguates verbs (mios-build vs mios-pull etc.).
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('plain','dev','pull','dash','build','update','config','help')] [string] $Badge = 'plain'
    )
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $sizes = @(16, 32, 48, 64, 256)
    $bitmaps = @()
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = 'AntiAlias'
        $g.TextRenderingHint  = 'AntiAlias'
        $g.InterpolationMode  = 'HighQualityBicubic'
        $g.PixelOffsetMode    = 'HighQuality'

        # MiOS palette (Hokusai + operator):
        #   bg     = #282262   deep Hokusai blue (canvas)
        #   fg     = #E7DFD3   warm cream (front-left face)
        #   accent = #F35C15   sunset orange (top face -- "lit" surface)
        #   shade  = #14112E   near-black blue (right face -- shadowed)
        #   green  = #3E7765   forest green (non-destructive verb badges)
        $bg     = [System.Drawing.Color]::FromArgb(40, 34, 98)
        $fg     = [System.Drawing.Color]::FromArgb(231, 223, 211)
        $accent = [System.Drawing.Color]::FromArgb(243, 92, 21)
        $shade  = [System.Drawing.Color]::FromArgb(20, 17, 49)
        $green  = [System.Drawing.Color]::FromArgb(62, 119, 101)
        $g.Clear($bg)

        # ── Iso cube vertices ────────────────────────────────────────
        # Six visible vertices of an isometric cube silhouette, plus
        # the front (vMid) corner. The cube is centered at (cx, cy)
        # with extent $r. All face polygons share these vertices so
        # edges line up exactly.
        $cx = $s / 2.0
        $cy = $s / 2.0
        $r  = $s * 0.36
        $cos30 = 0.866
        $hH = $r * 0.55          # half-height (vertical)
        $hW = $r * $cos30        # half-width (horizontal)
        $vTop  = [System.Drawing.PointF]::new($cx,        $cy - $hH * 1.10)
        $vTopR = [System.Drawing.PointF]::new($cx + $hW,  $cy - $hH * 0.55)
        $vBotR = [System.Drawing.PointF]::new($cx + $hW,  $cy + $hH * 0.55)
        $vBot  = [System.Drawing.PointF]::new($cx,        $cy + $hH * 1.10)
        $vBotL = [System.Drawing.PointF]::new($cx - $hW,  $cy + $hH * 0.55)
        $vTopL = [System.Drawing.PointF]::new($cx - $hW,  $cy - $hH * 0.55)
        $vMid  = [System.Drawing.PointF]::new($cx,        $cy)

        # Cast to PointF[] explicitly: PowerShell's overload resolver
        # otherwise picks DrawPolygon(Pen, Point[]) (the int variant)
        # and tries to coerce PointF -> Point, which throws.
        [System.Drawing.PointF[]] $topPts   = @($vTop,  $vTopR, $vMid,  $vTopL)
        [System.Drawing.PointF[]] $leftPts  = @($vTopL, $vMid,  $vBot,  $vBotL)
        [System.Drawing.PointF[]] $rightPts = @($vTopR, $vBotR, $vBot,  $vMid)

        # Fill the three faces.
        $brushTop   = New-Object System.Drawing.SolidBrush($accent)
        $brushLeft  = New-Object System.Drawing.SolidBrush($fg)
        $brushRight = New-Object System.Drawing.SolidBrush($shade)
        $g.FillPolygon($brushTop,   $topPts)
        $g.FillPolygon($brushLeft,  $leftPts)
        $g.FillPolygon($brushRight, $rightPts)
        $brushTop.Dispose(); $brushLeft.Dispose(); $brushRight.Dispose()

        # ── Hatch marks (`/:\` echoes of the ASCII art) ──────────────
        # Skip at 16 px -- the lines turn to mush. At 32+ each face
        # gets two parallel diagonal strokes to mimic the wireframe
        # `/:\` cross-hatching of the dashboard letters.
        if ($s -ge 32) {
            $hatchPen = New-Object System.Drawing.Pen($bg, [math]::Max(1, $s / 64))
            # Left face: lines parallel to the top-left -> bottom edge.
            for ($i = 1; $i -le 2; $i++) {
                $t = $i / 3.0
                $a = [System.Drawing.PointF]::new(
                    $vTopL.X + ($vMid.X  - $vTopL.X) * $t,
                    $vTopL.Y + ($vMid.Y  - $vTopL.Y) * $t)
                $b = [System.Drawing.PointF]::new(
                    $vBotL.X + ($vBot.X  - $vBotL.X) * $t,
                    $vBotL.Y + ($vBot.Y  - $vBotL.Y) * $t)
                $g.DrawLine($hatchPen, $a, $b)
            }
            # Right face: lines parallel to the top-right -> bottom edge.
            for ($i = 1; $i -le 2; $i++) {
                $t = $i / 3.0
                $a = [System.Drawing.PointF]::new(
                    $vTopR.X + ($vMid.X  - $vTopR.X) * $t,
                    $vTopR.Y + ($vMid.Y  - $vTopR.Y) * $t)
                $b = [System.Drawing.PointF]::new(
                    $vBotR.X + ($vBot.X  - $vBotR.X) * $t,
                    $vBotR.Y + ($vBot.Y  - $vBotR.Y) * $t)
                $g.DrawLine($hatchPen, $a, $b)
            }
            # Top face: a single cross-stroke from top-left corner
            # to mid (just a hint -- two lines clutter the small face).
            $tA = [System.Drawing.PointF]::new(
                $vTopL.X + ($vTop.X - $vTopL.X) * 0.5,
                $vTopL.Y + ($vTop.Y - $vTopL.Y) * 0.5)
            $tB = [System.Drawing.PointF]::new(
                $vTopR.X + ($vMid.X - $vTopR.X) * 0.5,
                $vTopR.Y + ($vMid.Y - $vTopR.Y) * 0.5)
            $g.DrawLine($hatchPen, $tA, $tB)
            $hatchPen.Dispose()
        }

        # ── Edge strokes (cube outline) ──────────────────────────────
        $edgePen = New-Object System.Drawing.Pen($bg, [math]::Max(1, $s / 36))
        $g.DrawPolygon($edgePen, $topPts)
        $g.DrawPolygon($edgePen, $leftPts)
        $g.DrawPolygon($edgePen, $rightPts)
        # Inner spine (top-vertex -> mid) for the iso "Y" silhouette.
        $g.DrawLine($edgePen, $vTop, $vMid)
        $edgePen.Dispose()

        # ── Badge (verb-specific glyph in bottom-right) ──────────────
        if ($Badge -ne 'plain' -and $s -ge 32) {
            $bSize = [int]($s * 0.36)
            $bX    = $s - $bSize - 1
            $bY    = $s - $bSize - 1
            # Green for read-only verbs (dev shell, dashboard, config-edit);
            # orange for state-mutating verbs (build, pull, update).
            $badgeFill = if ($Badge -in @('dev','dash','config')) { $green } else { $accent }
            $badgeBrush = New-Object System.Drawing.SolidBrush($badgeFill)
            $g.FillEllipse($badgeBrush, $bX, $bY, $bSize, $bSize)
            $badgeBrush.Dispose()
            $glyphFont = New-Object System.Drawing.Font("Segoe UI Symbol", [int]($bSize * 0.65), [System.Drawing.FontStyle]::Bold)
            $glyphChar = switch ($Badge) {
                'dev'    { [char]0x276F }   # ❯ chevron right
                'pull'   { [char]0x2193 }   # ↓ down arrow
                'dash'   { [char]0x25A6 }   # ▦ grid
                'build'  { [char]0x2699 }   # ⚙ gear
                'update' { [char]0x21BB }   # ↻ clockwise
                'config' { [char]0x2699 }   # ⚙ gear
                'help'   { [char]0x003F }   # ? question mark
            }
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
            $glyphBrush = New-Object System.Drawing.SolidBrush($fg)
            $g.DrawString([string]$glyphChar, $glyphFont, $glyphBrush,
                [System.Drawing.RectangleF]::FromLTRB($bX, $bY, $bX + $bSize, $bY + $bSize), $sf)
            $glyphFont.Dispose(); $glyphBrush.Dispose()
        }
        $g.Dispose()
        $bitmaps += ,$bmp
    }
    # Multi-image .ico writer (ICONDIR + ICONDIRENTRY[] + PNG payloads).
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)                    # reserved
    $bw.Write([UInt16]1)                    # type = icon
    $bw.Write([UInt16]$bitmaps.Count)
    $payloads = @()
    foreach ($bmp in $bitmaps) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $payloads += ,$ms.ToArray()
    }
    $offset = 6 + (16 * $bitmaps.Count)
    for ($i = 0; $i -lt $bitmaps.Count; $i++) {
        $b = $bitmaps[$i]; $p = $payloads[$i]
        $bw.Write([byte]($(if ($b.Width  -ge 256) { 0 } else { $b.Width  })))
        $bw.Write([byte]($(if ($b.Height -ge 256) { 0 } else { $b.Height })))
        $bw.Write([byte]0)              # palette
        $bw.Write([byte]0)              # reserved
        $bw.Write([UInt16]1)            # color planes
        $bw.Write([UInt16]32)           # bpp
        $bw.Write([UInt32]$p.Length)
        $bw.Write([UInt32]$offset)
        $offset += $p.Length
    }
    foreach ($p in $payloads) { $bw.Write($p) }
    $bw.Flush(); $bw.Close(); $fs.Close()
    foreach ($bmp in $bitmaps) { $bmp.Dispose() }
}

function Install-MiosLauncher {
    # Builds out the Windows-side MiOS install tree and shortcuts:
    #
    #   $MiosInstallDir/                 (= C:\MiOS for admin installs,
    #     bin/                            %LOCALAPPDATA%\MiOS otherwise)
    #       oh-my-posh.exe               (already staged by Install-WindowsBranding)
    #       mios-dash.ps1                Windows dashboard
    #       mios-dev.ps1                 wsl -d <dev-distro> launcher
    #       mios-pull.ps1                wsl --user root sudo /usr/bin/mios-pull
    #       mios-update.ps1              re-runs build-mios.ps1 to refresh
    #     icons/                         per-verb .ico files (M + badge)
    #       mios.ico, mios-dev.ico, mios-pull.ico, mios-dash.ico,
    #       mios-build.ico, mios-update.ico, mios-config.ico
    #     themes/mios.omp.json           (already staged by Install-WindowsBranding)
    #
    #   Start Menu\Programs\MiOS\        $StartMenuDir
    #     MiOS.lnk                       (main launcher; wt -p MiOS or pwsh)
    #     MiOS Dev VM.lnk                (wsl into MiOS-DEV)
    #     MiOS Update.lnk                (mios-pull)
    #     MiOS Dashboard.lnk             (standalone dash)
    #     MiOS Configurator.lnk          (HTML configurator on MiOS-DEV WSLg)
    #
    #   Desktop\MiOS.lnk                 single primary shortcut
    #   PowerShell profile               mios-dash / mios-dev / mios-pull functions
    #   Windows Terminal settings.json   "MiOS" profile + color scheme
    #
    # Idempotent: regenerates / replaces in place.
    # Bypass: $env:MIOS_SKIP_LAUNCHER=1.
    if ($env:MIOS_SKIP_LAUNCHER -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_LAUNCHER set -- launcher install skipped"
        return
    }
    Set-Step "Installing MiOS desktop launcher under $MiosInstallDir..."

    foreach ($d in @($MiosInstallDir, $MiosBinDir, $MiosIconsDir, $MiosThemesDir, $StartMenuDir)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # ── 1. Generate the icon family (one .ico per verb) ───────────────
    $iconMap = @{
        'mios'         = 'plain'
        'mios-dev'     = 'dev'
        'mios-pull'    = 'pull'
        'mios-dash'    = 'dash'
        'mios-build'   = 'build'
        'mios-update'  = 'update'
        'mios-config'  = 'config'
        'mios-help'    = 'help'
    }
    $icoPaths = @{}
    foreach ($name in $iconMap.Keys) {
        $p = Join-Path $MiosIconsDir "$name.ico"
        try {
            New-MiosIcon -Path $p -Badge $iconMap[$name]
            $icoPaths[$name] = $p
        } catch {
            Log-Warn "icon $name : $($_.Exception.Message)"
        }
    }
    $icoPath = $icoPaths['mios']
    if ($icoPath) { Log-Ok "Generated $($iconMap.Count) MiOS icons under $MiosIconsDir" }
    else          { Log-Warn "icon generation failed -- shortcuts will use default WT icon"; $icoPath = "" }

    # ── 2. Bin scripts: mios-dash + mios-dev + mios-pull + mios-update ──
    $dashPath = Join-Path $MiosBinDir 'mios-dash.ps1'
    $dashScript = @'
# <MiOSRoot>\bin\mios-dash.ps1
# Windows-side dashboard. Mirrors /usr/libexec/mios/mios-dashboard.sh
# layout: 80-col frame, centered MiOS ASCII art, services probe, hint.
# Auto-installed by mios-bootstrap (Install-MiosLauncher).
$ErrorActionPreference = 'SilentlyContinue'

# Self-locate the MiOS install root (this script is at <root>\bin\mios-dash.ps1).
$Script:MiOSRoot = Split-Path -Parent $PSScriptRoot

# Frame width: read [terminal].cols + [terminal].right_margin from
# mios.toml at runtime so the operator's mios.html edits flow through
# without rebuilding. Vendor defaults: cols=80, right_margin=2 -> total
# frame width 78 (matches Get-MiOS.ps1's Show-MiOSBanner). Operator
# reported "framing too wide STILL" with the previous hardcoded 80 ->
# the previous setting consumed the entire 80-col terminal width with
# no slack and WT's pseudo-console reported width 1 cell over visible
# during first paint, so the right frame char wrapped.
$_dashCols = 80; $_dashRightMargin = 2
foreach ($_dashTomlPath in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $Script:MiOSRoot 'usr\share\mios\mios.toml'))) {
    if (Test-Path -LiteralPath $_dashTomlPath) {
        try {
            $_dashTomlText = [IO.File]::ReadAllText($_dashTomlPath, (New-Object System.Text.UTF8Encoding($false)))
            $_dashTermSection = [regex]::Match($_dashTomlText, '(?ms)^\[terminal\]\s*$(?<body>.*?)(?=^\[|\z)')
            if ($_dashTermSection.Success) {
                $_dashBody = $_dashTermSection.Groups['body'].Value
                $_dashColsM = [regex]::Match($_dashBody, '(?m)^\s*cols\s*=\s*(?<v>\d+)')
                if ($_dashColsM.Success) { $_dashCols = [int]$_dashColsM.Groups['v'].Value }
                $_dashRMM = [regex]::Match($_dashBody, '(?m)^\s*right_margin\s*=\s*(?<v>\d+)')
                if ($_dashRMM.Success) { $_dashRightMargin = [int]$_dashRMM.Groups['v'].Value }
            }
            break
        } catch {}
    }
}
$WIDTH = [math]::Max(20, $_dashCols - $_dashRightMargin)
$INNER = $WIDTH - 4
$F_TL = [char]0x256D; $F_TR = [char]0x256E
$F_BL = [char]0x2570; $F_BR = [char]0x256F
$F_LT = [char]0x251C; $F_RT = [char]0x2524
$F_V  = [char]0x2502; $HR   = [char]0x2500
$DOT_UP = [char]0x25CF; $DOT_DOWN = [char]0x25CB

function Repeat-Char([char]$c, [int]$n) { return ([string]$c) * [math]::Max(0, $n) }
function Frame-Top    { Write-Host ($F_TL + (Repeat-Char $HR ($WIDTH - 2)) + $F_TR) -ForegroundColor DarkCyan }
function Frame-Bot    { Write-Host ($F_BL + (Repeat-Char $HR ($WIDTH - 2)) + $F_BR) -ForegroundColor DarkCyan }
function Frame-Divide { Write-Host ($F_LT + (Repeat-Char $HR ($WIDTH - 2)) + $F_RT) -ForegroundColor DarkCyan }

function Frame-Line([string]$content, [ConsoleColor]$color = 'Gray') {
    $vis = $content
    if ($vis.Length -gt $INNER) { $vis = $vis.Substring(0, $INNER - 1) + [char]0x2026 }
    $pad = $INNER - $vis.Length
    if ($pad -lt 0) { $pad = 0 }
    Write-Host -NoNewline $F_V        -ForegroundColor DarkCyan
    Write-Host -NoNewline " "
    Write-Host -NoNewline $vis        -ForegroundColor $color
    Write-Host -NoNewline (' ' * $pad)
    Write-Host -NoNewline " "
    Write-Host           $F_V         -ForegroundColor DarkCyan
}

function Probe-Endpoint([string]$url) {
    try {
        $iwrParams = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = 2 }
        $r = Invoke-WebRequest @iwrParams -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Show-MiosDashboard {
    Clear-Host
    Frame-Top

    # Centered ASCII art header. Width 54, art lines as-is.
    $art = @(
        '      ___                       ___           ___',
        '     /\__\          ___        /\  \         /\  \',
        '    /::|  |        /\  \      /::\  \       /::\  \',
        '   /:|:|  |        \:\  \    /:/\:\  \     /:/\ \  \',
        '  /:/|:|__|__      /::\__\  /:/  \:\  \   _\:\~\ \  \',
        ' /:/ |::::\__\  __/:/\/__/ /:/__/ \:\__\ /\ \:\ \ \__\',
        ' \/__/~~/:/  / /\/:/  /    \:\  \ /:/  / \:\ \:\ \/__/',
        '       /:/  /  \::/__/      \:\  /:/  /   \:\ \:\__\',
        '      /:/  /    \:\__\       \:\/:/  /     \:\/:/  /',
        '     /:/  /      \/__/        \::/  /       \::/  /',
        '     \/__/                     \/__/         \/__/'
    )
    $maxw = ($art | Measure-Object -Property Length -Maximum).Maximum
    $padL = [math]::Max(0, [int](($INNER - $maxw) / 2))
    foreach ($line in $art) {
        Frame-Line ((' ' * $padL) + $line) 'Cyan'
    }
    Frame-Divide

    # Title + version row. VERSION lives at <MiOSRoot>\VERSION.
    $verFile = Join-Path $Script:MiOSRoot 'VERSION'
    $ver = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '0.2.2' }
    $left = " MiOS v$ver  --  Windows Launcher"
    $right = " $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion) "
    $gap = $INNER - $left.Length - $right.Length
    if ($gap -lt 1) { $gap = 1 }
    Frame-Line ($left + (' ' * $gap) + $right) 'White'
    Frame-Divide

    # Self-replication endpoints (probe each host).
    Frame-Line "  Self-replication loop" 'Cyan'
    $endpoints = @(
        @{ Name = 'Forge   '; Url = 'http://localhost:3000/'   ; Probe = 'http://localhost:3000/api/v1/version' },
        @{ Name = 'AI      '; Url = 'http://localhost:8080/v1'; Probe = 'http://localhost:8080/v1/models'      },
        @{ Name = 'Cockpit '; Url = 'https://localhost:9090/' ; Probe = 'https://localhost:9090/'              },
        @{ Name = 'Ollama  '; Url = 'http://localhost:11434'  ; Probe = 'http://localhost:11434/'              }
    )
    foreach ($ep in $endpoints) {
        $up  = Probe-Endpoint $ep.Probe
        $dot = if ($up) { $DOT_UP } else { $DOT_DOWN }
        Frame-Line ("    $dot  $($ep.Name)   $($ep.Url)") (if ($up) { 'Green' } else { 'DarkGray' })
    }
    Frame-Divide

    # MiOS-DEV distro state. After build-mios.ps1's Rename-PodmanDevDistro
    # pass the WSL distro is just "MiOS-DEV"; before the rename (or in
    # partial-install states) it shows up as "podman-MiOS-DEV". Probe
    # both, canonical-first, plus the legacy MiOS-BUILDER names from
    # earlier project versions for full backwards-compat.
    Frame-Line "  MiOS-DEV (WSL2 dev VM)" 'Cyan'
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}
    $devCandidates = @('MiOS-DEV', 'podman-MiOS-DEV', 'MiOS-BUILDER', 'podman-MiOS-BUILDER')
    $matched = $wslList | Where-Object { $devCandidates -contains $_ } | Select-Object -First 1
    if ($matched) {
        Frame-Line "    $DOT_UP  registered : $matched" 'Green'
        Frame-Line "    enter      : wsl -d $matched"   'Gray'
    } else {
        Frame-Line "    $DOT_DOWN  not registered yet"            'DarkGray'
        Frame-Line "    setup      : run build-mios.ps1 to provision" 'Gray'
    }
    Frame-Divide

    Frame-Line "  Edit /  ->  git commit  ->  git push  ->  Forgejo runner  ->  bootc switch" 'DarkGray'
    Frame-Bot
    Write-Host ""
}

Show-MiosDashboard
'@
    Set-Content -Path $dashPath -Value $dashScript -Encoding UTF8
    Log-Ok "Windows mios-dash staged at $dashPath"

    # mios-dev.ps1 / mios-pull.ps1 -- self-resolving wrappers.
    # The Rename-PodmanDevDistro pass at the end of build-mios.ps1
    # drops the `podman-` prefix, so the canonical post-install name
    # is `$DevDistro` (= "MiOS-DEV"). These wrappers probe at RUNTIME
    # so they Just Work whether the rename has happened yet or not
    # (e.g. during a partial install or after a failed rename), and
    # they pick up future renames without needing regeneration.
    $devResolveBlock = @"
`$Global:MiosDevCandidates = @('$DevDistro', 'podman-$DevDistro', '$LegacyDevName', 'podman-$LegacyDevName')
function Resolve-MiosDevDistro {
    `$wslList = @()
    try { `$wslList = (& wsl.exe -l -q 2>`$null) -split "``r?``n" | ForEach-Object { (`$_ -replace [char]0, '').Trim() } | Where-Object { `$_ } } catch {}
    `$match = `$Global:MiosDevCandidates | Where-Object { `$wslList -contains `$_ } | Select-Object -First 1
    if (-not `$match) { `$match = '$DevDistro' }
    return `$match
}
"@
    $devPath = Join-Path $MiosBinDir 'mios-dev.ps1'
    Set-Content -Path $devPath -Value @"
$devResolveBlock
# Bare invocation -> mios user, login shell at /, with the MiOS Linux-side
# dashboard rendering on entry (banner + ASCII logo + fastfetch + framing).
# The dashboard is wired by /etc/profile.d/zz-mios-motd.sh inside the dev
# VM (seeded by Phase 3 of the bootstrap) which auto-runs
# /usr/libexec/mios/mios-dashboard.sh on every interactive bash login.
# `bash -l` (login shell) ensures /etc/profile.d/* is sourced.
#
# Args pass through verbatim so callers can still do `mios-dev --user user
# -- some-cmd` etc.
`$distro = Resolve-MiosDevDistro
if (`$args.Count -eq 0) {
    # --user mios matches the WT MiOS-DEV profile so dashboard / theming
    # / mios.toml resolution all hit the per-user MiOS layout. --cd /
    # because `.git IS /` (Architectural Law 3) -- the dev VM's git
    # working tree is the filesystem root.
    wsl.exe -d `$distro --user mios --cd / -- bash -l
} else {
    wsl.exe -d `$distro @args
}
"@ -Encoding UTF8

    $pullPath = Join-Path $MiosBinDir 'mios-pull.ps1'
    Set-Content -Path $pullPath -Value @"
# <MiOSRoot>\bin\mios-pull.ps1 -- refreshes BOTH the Windows-side M:\
# overlay AND the dev VM root (/) from origin/main. Two distinct git
# working trees:
#   1. M:\ (Windows-side mios.git overlay) -- backs every M:\usr/share/mios
#      lookup, M:\usr/share/mios/configurator/mios.html (MiOS Config
#      shortcut), and what the dev VM sees at /mnt/m/.
#   2. / inside MiOS-DEV (the dev VM's mios.git working tree per
#      Architectural Law 3, ".git IS /") -- /usr/bin/mios-pull does the
#      git fetch + reset --hard inside the dev distro.
# Operator confirmed bug 2026-05-08: previous mios-pull.ps1 only did
# step 2, leaving M:\ stale -> `mios build` rendered an old MiOS.
$devResolveBlock
`$ErrorActionPreference = 'Continue'

# Step 1: Windows-side M:\ refresh.
`$miosRoot = 'M:\'
if ((Test-Path (Join-Path `$miosRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  [mios-pull] Windows-side: git fetch + reset --hard origin/main on M:\...' -ForegroundColor Cyan
    try {
        & git -C `$miosRoot fetch --depth=1 origin main 2>&1 | ForEach-Object { Write-Host ('    ' + `$_) -ForegroundColor DarkGray }
        if (`$LASTEXITCODE -eq 0) {
            & git -C `$miosRoot reset --hard origin/main 2>&1 | ForEach-Object { Write-Host ('    ' + `$_) -ForegroundColor DarkGray }
            if (`$LASTEXITCODE -eq 0) {
                `$_head = (& git -C `$miosRoot rev-parse --short HEAD 2>`$null)
                Write-Host ('  [mios-pull] M:\ now at origin/main HEAD = ' + `$_head) -ForegroundColor Green
            } else {
                Write-Host '  [mios-pull] M:\ git reset --hard failed' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [mios-pull] M:\ git fetch failed (offline?)' -ForegroundColor Yellow
        }
    } catch {
        Write-Host ('  [mios-pull] M:\ git refresh threw: ' + `$_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    Write-Host '  [mios-pull] M:\ is not a git working tree -- skipping Windows-side refresh' -ForegroundColor Yellow
}

# Step 2: dev VM root refresh.
Write-Host '  [mios-pull] dev VM: syncing / overlay to origin/main...' -ForegroundColor Cyan
wsl.exe -d (Resolve-MiosDevDistro) --user root sudo /usr/bin/mios-pull @args
"@ -Encoding UTF8

    # mios-update.ps1 -- self-updates the bootstrap from origin BEFORE
    # re-running build-mios.ps1. This is what makes `mios update` actually
    # pick up upstream changes: previously it ran the LOCAL stale
    # build-mios.ps1 directly, so any fix shipped to origin/main never
    # reached the operator until they manually re-paste the irm|iex
    # one-liner. The new flow:
    #
    #   1. git -C M:\MiOS\bootstrap-shadow fetch + reset --hard origin/main
    #   2. robocopy mios-bootstrap shadow -> M:\ overlay (refreshes the
    #      build-mios.ps1 the next step will run)
    #   3. pwsh -File <freshly-overlaid build-mios.ps1>
    #
    # Step 1 is idempotent (no-op if the shadow's HEAD already matches
    # origin/main); step 2 is destructive over the overlay paths but
    # those are managed by mios-bootstrap anyway.
    $bootstrapBuild = Join-Path $MiosRepoDir 'mios-bootstrap\build-mios.ps1'
    $updatePath = Join-Path $MiosBinDir 'mios-update.ps1'
    $updateScript = @"
# <MiOSRoot>\bin\mios-update.ps1 -- self-updating bootstrap re-runner.
# Fetches latest mios-bootstrap from origin/main, re-overlays it onto
# M:\, then re-runs build-mios.ps1 with whatever args were passed.
`$ErrorActionPreference = 'SilentlyContinue'
`$shadow      = "$MiosBootstrapShadow"
`$repoDir     = "$MiosRepoDir"
`$bootstrapBs = "$bootstrapBuild"

# 1. Self-update the shadow if .git is present and the operator's
#    network can reach origin. Falls through silently on failure --
#    the next step still runs the (possibly stale) local copy.
if (Test-Path (Join-Path `$shadow '.git')) {
    Write-Host '  [mios update] Fetching latest mios-bootstrap from origin/main...' -ForegroundColor Cyan
    Push-Location `$shadow
    try {
        & git remote set-url origin '$MiosBootstrapUrl' 2>&1 | Out-Null
        & git fetch --depth=1 origin main 2>&1 | Out-Null
        if (`$LASTEXITCODE -eq 0) {
            & git reset --hard FETCH_HEAD 2>&1 | Out-Null
            if (`$LASTEXITCODE -eq 0) {
                Write-Host '  [mios update] mios-bootstrap shadow updated to origin/main HEAD.' -ForegroundColor Green
            } else {
                Write-Host '  [mios update] git reset failed; running with possibly-stale shadow.' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [mios update] git fetch failed (offline?); running with possibly-stale shadow.' -ForegroundColor Yellow
        }
    } finally { Pop-Location }

    # 2. Re-overlay shadow onto M:\ so the build-mios.ps1 we run is
    #    the fresh one. /XD .git keeps mios.git's .git intact.
    Write-Host '  [mios update] Re-overlaying mios-bootstrap files onto M:\...' -ForegroundColor Cyan
    & robocopy `$shadow `$repoDir /E /XD .git /NJH /NJS /NFL /NDL /NP 2>&1 | Out-Null
} else {
    Write-Host "  [mios update] No mios-bootstrap shadow at `$shadow -- running local build-mios.ps1 as-is." -ForegroundColor Yellow
}

# 3. Re-run build-mios.ps1 (now refreshed) with all forwarded args.
if (Test-Path `$bootstrapBs) {
    & pwsh.exe -NoProfile -File `$bootstrapBs @args
} else {
    Write-Host "  [mios update] build-mios.ps1 not found at `$bootstrapBs" -ForegroundColor Red
    Write-Host "  [mios update] Re-paste the canonical irm|iex one-liner to recover:" -ForegroundColor Yellow
    Write-Host '    powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"' -ForegroundColor DarkGray
}
"@
    Set-Content -Path $updatePath -Value $updateScript -Encoding UTF8

    # mios-config.ps1 -- opens the HTML configurator in the operator's
    # default browser. Walks a candidate list so we hit the M:\ overlay
    # (canonical operator-edit copy) first, then bootstrap-shadow, then
    # legacy paths. Per operator: "have the MiOS config link open the
    # webpage directly in the local browser (opens the mios.html
    # directly installed on the newly created M:\ directories)".
    $cfgPath = Join-Path $MiosBinDir 'mios-config.ps1'
    $_shadowCfg = (Join-Path $MiosBootstrapShadow 'usr\share\mios\configurator\mios.html') -replace '\\','\\'
    $_legacyCfg = (Join-Path $MiosShareDir 'mios\usr\share\mios\configurator\mios.html') -replace '\\','\\'
    $cfgScript = @"
# mios-config.ps1 -- the `mios config` verb / MiOS Config app.
# Resolves mios.html in priority order and shell-executes it so the
# operator's default browser opens the page. Edit fields, save -- the
# browser writes a copy to %USERPROFILE%\Downloads; `mios build` step 2
# promotes it back to M:\etc\mios + M:\usr\share\mios.
`$_candidates = @(
    'M:\usr\share\mios\configurator\mios.html',
    "$_shadowCfg",
    "$_legacyCfg"
)
`$_html = `$null
foreach (`$_c in `$_candidates) { if (`$_c -and (Test-Path -LiteralPath `$_c)) { `$_html = `$_c; break } }
if (`$_html) { Start-Process `$_html }
else {
    Write-Host "MiOS configurator HTML not found. Tried:" -ForegroundColor Yellow
    foreach (`$_c in `$_candidates) { Write-Host "  `$_c" -ForegroundColor DarkGray }
    Write-Host "Run 'mios update' to refresh the M:\ overlay." -ForegroundColor DarkGray
}
"@
    Set-Content -Path $cfgPath -Value $cfgScript -Encoding UTF8

    # mios-help.ps1 -- comprehensive help / verb listing. Standalone
    # script (not just the M:\ profile's mios-help function) so the
    # `MiOS Help.lnk` Start Menu shortcut can target it. The script
    # uses the same MiOS palette as the rest of the surface.
    $helpPath   = Join-Path $MiosBinDir 'mios-help.ps1'
    $helpScript = @'
# <MiOSRoot>\bin\mios-help.ps1 -- the `mios help` verb.
# Comprehensive verb + functionality listing. Run from any MiOS
# terminal (`mios help` or click the MiOS Help Start Menu shortcut).
$ErrorActionPreference = 'SilentlyContinue'

# Color palette -- mirrors mios.toml [colors]. Hardcoded fallbacks
# so this script works even when mios.toml isn't yet on disk.
$accent = 'Cyan'      # operator blue (#1A407F)
$muted  = 'DarkGray'  # silver
$ok     = 'Green'     # wave green
$warn   = 'Yellow'    # sunset orange

function Header {
    param([string]$T, [string]$Sub = '')
    Write-Host ''
    Write-Host "  $T" -ForegroundColor $accent
    Write-Host ('  ' + ('─' * [math]::Min(76, $T.Length + 4))) -ForegroundColor $muted
    if ($Sub) { Write-Host "  $Sub" -ForegroundColor $muted; Write-Host '' }
}

function Verb {
    param([string]$V, [string]$D)
    Write-Host ('  {0,-12} {1}' -f $V, $D) -ForegroundColor White
}

function Note {
    param([string]$T)
    Write-Host "  $T" -ForegroundColor $muted
}

Clear-Host
Write-Host ''
Write-Host '  ╭──────────────────────────────────────────────────────────────────────────╮' -ForegroundColor $accent
Write-Host '  │                   MiOS  --  Help / Verb Reference                        │' -ForegroundColor $accent
# Tagline resolves through mios.toml [branding].tagline_long at runtime
# (SSOT). No hardcoding -- per operator: "no hardcoding ANYWHERE".
$_helpTagline = 'Immutable Fedora AI Workstation  --  Self-replicating bootc OS'
foreach ($_tcand in @("$env:USERPROFILE\.config\mios\mios.toml",'M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
    # C:\MiOS deliberately excluded -- dev working tree, not consumer path
    if (Test-Path -LiteralPath $_tcand) {
        try {
            $_tt = [IO.File]::ReadAllText($_tcand, (New-Object System.Text.UTF8Encoding($false)))
            $_m = [regex]::Match($_tt, '(?ms)^\[branding\].*?^\s*tagline_long\s*=\s*"([^"]+)"')
            if ($_m.Success) { $_helpTagline = $_m.Groups[1].Value; break }
        } catch {}
    }
}
$_helpTagPad = $_helpTagline.PadRight(72).Substring(0, [math]::Min(72, $_helpTagline.Length))
Write-Host ('  │   ' + $_helpTagPad.PadRight(72) + '   │') -ForegroundColor $accent
Write-Host '  ╰──────────────────────────────────────────────────────────────────────────╯' -ForegroundColor $accent

Header 'Core verbs' 'Type any of these in a MiOS terminal, OR click the matching Start Menu shortcut.'
Verb 'mios'         '(no arg) -- open this help; runs `mios help` by default'
Verb 'mios build'   'Promote Downloads edits, sync the overlay, SSH into MiOS-DEV,'
Note '               ignite mios-build-driver -- the full OCI build pipeline.'
Verb 'mios config'  'Open the HTML configurator (mios.toml editor) in your browser.'
Note '               Edit identity, AI, packages, ports, services, theme, etc.'
Verb 'mios dash'    'Render the framed MiOS dashboard (banner + fastfetch + verbs).'
Verb 'mios dev'     'Drop into the MiOS-DEV podman machine as user `mios` at /.'
Verb 'mios pull'    'git fetch + hard reset M:\ overlay to origin/main (no rebuild).'
Verb 'mios update'  'Re-run the bootstrap (cache-busted) -- refresh terminal + dev VM.'
Verb 'mios help'    'This list.'

Header 'Native Windows apps' 'The five-app MiOS surface (Start Menu + Desktop).'
Verb 'MiOS'         'The MiOS terminal. Themed Windows Terminal MiOS profile, 80x20,'
Note '                acrylic 50%%, MiOS color palette, oh-my-posh + dashboard on'
Note '                every launch. Right-click -> Pin to Start / Pin to Taskbar.'
Verb 'MiOS-DEV'     'Drops you into the MiOS-DEV podman machine immediately.'
Verb 'MiOS Config'  'Opens mios.html (the configurator) in the default browser.'
Note '                Edit identity, AI, packages, ports, services, theme. Save'
Note '                writes mios.toml to %USERPROFILE%\Downloads; `mios build`'
Note '                step 2 promotes it into the M:\ overlay automatically.'
Verb 'MiOS Help'    'This help screen, as a clickable app.'
Verb 'Uninstall MiOS' 'Remove MiOS (preserves per-user config).'

Header 'How MiOS is laid out' 'Every operator-tunable value lives in mios.toml.'
Note '   M:\                            Data partition (256 GB NTFS, label MIOS-DEV)'
Note '   M:\MiOS\bin\                   Verb scripts (mios-build, mios-dev, mios-help, ...)'
Note '   M:\MiOS\repo\mios              The mios.git working tree (`.git IS /` on deploy)'
Note '   M:\MiOS\repo\mios-bootstrap    The mios-bootstrap.git working tree'
Note '   M:\etc\mios\mios.toml          Host overlay (operator overrides)'
Note '   M:\usr\share\mios\mios.toml    Vendor SSOT (default values)'
Note '   M:\MiOS\themes\mios.omp.json   oh-my-posh theme (MiOS palette)'
Note '   M:\MiOS\powershell\profile.ps1 PowerShell profile (dashboard + oh-my-posh init)'
Note '   M:\MiOS\fastfetch\config.jsonc fastfetch theme (banner + system info)'

Header 'The Day-0 -> Day-N self-replication flow'
Note '   Day-0 (Windows host): irm | iex Get-MiOS.ps1'
Note '          -> ack + M:\ provision + Podman Desktop + MiOS-DEV machine'
Note '          -> install Windows Terminal + pwsh 7 + Geist Mono + oh-my-posh'
Note '          -> register MiOS as a native Windows app (Start Menu + Desktop)'
Note '          -> STOP. Operator opens the MiOS app and types `mios build`.'
Note ''
Note '   `mios build` (operator-typed) -- triggers the full build pipeline:'
Note '          -> promote Downloads/mios.toml edits to M:\etc\mios\mios.toml'
Note '          -> mios-pull (sync M:\ to origin/main)'
Note '          -> SSH into MiOS-DEV -> /usr/libexec/mios/mios-build-driver'
Note '          -> overlay -> account -> install -> smoketest -> build -> deploy'
Note '          -> bootc switch + reboot -> MiOS-DEV IS MiOS (full parity)'
Note ''
Note '   Day-N (inside MiOS-DEV / any Fedora bootc host):'
Note '          -> dev environment runs INSIDE MiOS-DEV (Epiphany via WSLg)'
Note '          -> dual-push: local Forgejo + GitHub -> CI/CD -> bootc switch'
Note '          -> test deployments: Hyper-V, WSL2/g, QEMU, OCI, ISO, USB, RAW'

Header 'Architectural laws (every contribution obeys these)'
Note '   1. USR-OVER-ETC          static config in /usr/lib, /etc is admin-override only'
Note '   2. NO /VAR WRITES AT BUILD   tmpfiles.d realises /var at first boot'
Note '   3. GIT-MANAGED ROOT      `.git` IS `/` on every deployed host'
Note '   4. BOOTC-CONTAINER-LINT  every build ends with `bootc container lint`'
Note '   5. UNIFIED-AI-REDIRECTS  every OpenAI-API client targets MIOS_AI_ENDPOINT'
Note '                            (default http://localhost:8080/v1 -- LocalAI Quadlet)'
Note '   6. UNPRIVILEGED-QUADLETS every Quadlet declares User=, Group=, Delegate=yes'

Header 'Where to dig deeper'
Note '   mios.html    /usr/share/mios/configurator/mios.html   (HTML editor for mios.toml)'
Note '   AGENTS.md    M:\MiOS\repo\mios\AGENTS.md              (canonical agents.md doc)'
Note '   README.md    M:\MiOS\repo\mios\README.md              (project overview)'
Note '   GitHub       https://github.com/mios-dev/MiOS'
Note ''
Note '   Press any key to close...'
[void]([System.Console]::ReadKey($true))
'@
    Set-Content -Path $helpPath -Value $helpScript -Encoding UTF8
    Log-Ok "mios-help.ps1 (full verb + functionality reference) staged at $helpPath"

    # mios-build.ps1 -- THE operator-typed `mios build` verb. The Day-0
    # contract: Windows host does ack + MiOS-DEV provisioning, then
    # STOPS. `mios build` is the operator-triggered next step that
    # promotes any operator edits saved to %USERPROFILE%\Downloads, syncs
    # the M:\ overlay to origin/main, then SSHes into MiOS-DEV and
    # ignites mios-build-driver. The dev VM is THE builder; Windows is
    # provisioning + handoff ONLY.
    $buildPath  = Join-Path $MiosBinDir 'mios-build.ps1'
    $miosEtcDir = Join-Path $MiosRepoDir 'etc\mios'
    $miosShareDirInRepo = Join-Path $MiosRepoDir 'mios\usr\share\mios'
    $buildScript = @"
# <MiOSRoot>\bin\mios-build.ps1 -- the operator-triggered `mios build` verb.
# Self-replication contract: edit mios.toml in mios.html (browser saves
# it to %USERPROFILE%\Downloads on Windows because file:// can't write
# back), then run this script. It promotes the newest mios*.toml /
# *mios*.html from Downloads into M:\etc\mios + M:\usr\share\mios,
# archives the source as .imported-<timestamp>, syncs the M:\ overlay
# to origin/main, then SSHes into MiOS-DEV to run mios-build-driver
# (the actual build pipeline). Architectural Law 5 + the .git IS /
# invariant flow through end-to-end.
$devResolveBlock
`$ErrorActionPreference = 'Continue'
`$downloads = Join-Path `$env:USERPROFILE 'Downloads'
`$promoteTargets = @(
    @{ Pattern = 'mios*.toml';  TargetDir = "$miosEtcDir";       Filename = 'mios.toml' }
    @{ Pattern = '*mios*.html'; TargetDir = "$miosShareDirInRepo\configurator"; Filename = 'mios.html' }
)
`$promoted = `$false
foreach (`$pt in `$promoteTargets) {
    `$candidates = Get-ChildItem -Path `$downloads -Filter `$pt.Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not `$candidates) { continue }
    `$src = `$candidates[0]
    if (-not (Test-Path `$pt.TargetDir)) {
        New-Item -ItemType Directory -Path `$pt.TargetDir -Force | Out-Null
    }
    `$dst = Join-Path `$pt.TargetDir `$pt.Filename
    Copy-Item -Path `$src.FullName -Destination `$dst -Force
    `$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
    `$archive = Join-Path `$src.DirectoryName ("{0}.imported-{1}" -f `$src.Name, `$ts)
    Move-Item -Path `$src.FullName -Destination `$archive -Force
    Write-Host ("  [promote] {0} -> {1}" -f `$src.Name, `$dst) -ForegroundColor Green
    Write-Host ("            archived as {0}" -f (Split-Path `$archive -Leaf)) -ForegroundColor DarkGray
    `$promoted = `$true
}
if (-not `$promoted) {
    Write-Host '  [promote] no mios*.toml / *mios*.html in Downloads -- proceeding with current overlay' -ForegroundColor DarkGray
}

# Sync M:\ overlay to origin/main BEFORE the dev VM handoff. Two
# distinct git working trees need refreshing:
#
#   1. M:\ (the Windows-side mios.git overlay) -- THIS is what backs
#      M:\usr\share\mios\configurator\mios.html (opened by MiOS Config),
#      M:\usr\share\mios\mios.toml (read by every Get-MiosTomlValue),
#      and what the dev VM sees at /mnt/m/. Without a Windows-side
#      `git fetch + reset --hard origin/main` here, M:\ stays frozen
#      to whatever was on origin at the LAST install run, so:
#        - MiOS Config opens an OLD mios.html
#        - mios.toml reads return OLD values
#        - the dev VM's build-driver via /mnt/m/ uses OLD overlay
#      Operator confirmed bug 2026-05-08: `mios build` rendered an
#      "old MiOS build" because M:\ was stale.
#   2. / inside MiOS-DEV (the dev VM's mios.git working tree -- Architectural
#      Law 3, ".git IS /") -- mios-pull.ps1 delegates to
#      /usr/bin/mios-pull inside the dev distro for this.
#
# Step 1 (M:\ Windows-side) MUST run BEFORE step 2 because the dev
# distro's mios-build-driver reads from /mnt/m/ for some inputs (e.g.
# mios.toml lookups via Get-MiosTomlValue). Refreshing M:\ first
# guarantees the dev VM build sees the latest overlay.
`$miosRoot = 'M:\'
if ((Test-Path (Join-Path `$miosRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  [pull] Windows-side: git fetch + reset --hard origin/main on M:\...' -ForegroundColor Cyan
    try {
        & git -C `$miosRoot fetch --depth=1 origin main 2>&1 | ForEach-Object { Write-Host ('    ' + `$_) -ForegroundColor DarkGray }
        if (`$LASTEXITCODE -eq 0) {
            & git -C `$miosRoot reset --hard origin/main 2>&1 | ForEach-Object { Write-Host ('    ' + `$_) -ForegroundColor DarkGray }
            if (`$LASTEXITCODE -eq 0) {
                `$_head = (& git -C `$miosRoot rev-parse --short HEAD 2>`$null)
                Write-Host ('  [pull] M:\ now at origin/main HEAD = ' + `$_head) -ForegroundColor Green
            } else {
                Write-Host '  [pull] M:\ git reset --hard failed -- build will run against possibly-stale overlay' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [pull] M:\ git fetch failed (offline?) -- build will run against possibly-stale overlay' -ForegroundColor Yellow
        }
    } catch {
        Write-Host ('  [pull] M:\ git refresh threw: ' + `$_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    Write-Host '  [pull] M:\ is not a git working tree OR git is missing -- skipping Windows-side refresh' -ForegroundColor Yellow
}

# Now refresh the dev VM root (/) via mios-pull.ps1.
`$pull = Join-Path `$PSScriptRoot 'mios-pull.ps1'
if (Test-Path `$pull) {
    Write-Host '  [pull] dev VM: syncing / overlay to origin/main...' -ForegroundColor Cyan
    & pwsh.exe -NoProfile -File `$pull
} else {
    Write-Host '  [pull] mios-pull.ps1 not found -- skipping dev VM pull, build will run against staged dev tree' -ForegroundColor Yellow
}

# Start the WSL-Podman machine. `wsl.exe -d <distro>` later will
# auto-start the WSL distro alone, but the podman MACHINE wraps the
# distro with the rootful podman daemon + OCI builder services that
# mios-build-driver uses to actually build MiOS. Without this explicit
# start, the build can fail on first invocation after a reboot with
# "Cannot connect to Podman" because the daemon isn't up yet.
# Idempotent: no-op if the machine is already running. Operator-confirmed
# 2026-05-08: `mios build` should actually open the WSL-Podman machine
# AND build MiOS AND overlay newest MiOS repos at /ROOT.
`$distro = Resolve-MiosDevDistro
Write-Host ''
Write-Host ('  [build] starting WSL-Podman machine: {0} ...' -f `$distro) -ForegroundColor Cyan
try {
    & podman machine start `$distro 2>&1 | ForEach-Object {
        `$line = `$_.ToString()
        # Filter the noisy "already running" line into something less alarming.
        if (`$line -match 'is already running') {
            Write-Host '    (machine already running)' -ForegroundColor DarkGray
        } else {
            Write-Host ('    ' + `$line) -ForegroundColor DarkGray
        }
    }
} catch {
    Write-Host ('  [build] podman machine start threw: ' + `$_.Exception.Message) -ForegroundColor Yellow
    Write-Host '  [build] continuing -- wsl.exe -d will fall back to starting the distro alone (build may fail if podman daemon isn''t reachable)' -ForegroundColor Yellow
}

# Brief settling pause so podman API socket is reachable before the
# build driver's first `podman ...` invocation.
Start-Sleep -Milliseconds 800

# SSH handoff into MiOS-DEV. mios-build-driver is THE build pipeline:
# fetch + overlay newest mios.git at / (Architectural Law 3 ".git IS /")
# -> account/identity -> install -> smoketest -> build -> deploy -> boot.
# The build dashboard renders here in this WT tab (live, not proxied).
# We pass --user mios because the WT MiOS-DEV profile and operator
# expectations land on the mios login user (uid 1000) -- created by the
# seed script in Phase 3, with passwordless sudo for the build pipeline's
# privileged steps.
Write-Host ''
Write-Host ('  [build] handing off to {0}:/usr/libexec/mios/mios-build-driver' -f `$distro) -ForegroundColor Cyan
Write-Host '  [build] (this builds the OCI image inside MiOS-DEV; first run takes 10-30 min)' -ForegroundColor DarkGray
Write-Host ''
& wsl.exe -d `$distro --user mios --cd / -- bash -lc '/usr/libexec/mios/mios-build-driver'
"@
    Set-Content -Path $buildPath -Value $buildScript -Encoding UTF8
    Log-Ok "mios-build.ps1 (the `mios build` verb) staged at $buildPath"

    # mios.ps1 -- THE MiOS app dispatcher.  Operator 2026-05-09:
    # "U.N.I.F.I.E.D EVERYTHING MiOS related!!!".  This file used to
    # render a SECOND, NON-UNIFIED layout (a numbered TUI menu) when
    # the operator typed `mios <anything>` -- diverging from the
    # canonical Show-MiosDashboard ([dashboard].rows) layout the
    # M:\MiOS\powershell\profile.ps1 renders.  The redundancy is
    # gone: `function mios <verb>` in the profile body now dispatches
    # to mios-<verb> directly, so this file just exists as a
    # thin pass-through (some legacy code paths Start-Process this
    # script).  The body re-defines the per-verb mios-<name> wrapper
    # functions and dispatches the requested verb.  No TUI menu, no
    # divergent dashboard.
    $hubPath   = Join-Path $MiosBinDir 'mios.ps1'
    $hubScript = @'
# <MiOSRoot>\bin\mios.ps1 -- thin verb-dispatch pass-through.
# Auto-installed by mios-bootstrap (Install-MiosLauncher).  Operator
# 2026-05-09: "U.N.I.F.I.E.D EVERYTHING MiOS related!!!".  This file
# used to render its own Show-MiosApp TUI menu (a different layout
# from the canonical Show-MiosDashboard that [dashboard].rows
# drives) -- that has been REMOVED.  Now the file dot-sources the
# canonical M:\MiOS\powershell\profile.ps1 (so the operator gets
# the same Show-MiosDashboard render + `mios <verb>` dispatcher
# every other entry path uses) then dispatches the verb passed as
# argv if any.  No TUI menu, no second dashboard layout.
$ErrorActionPreference = 'SilentlyContinue'
$Script:MiOSBin  = $PSScriptRoot
$Script:MiOSRoot = Split-Path -Parent $Script:MiOSBin

# Canonical profile body (Show-MiosDashboard + mios <verb> dispatcher).
$_miosProfile = Join-Path $Script:MiOSRoot 'powershell\profile.ps1'
if (Test-Path -LiteralPath $_miosProfile) {
    try { . $_miosProfile } catch {
        Write-Host "  [!] Failed to load $_miosProfile : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# If a verb was passed (e.g. `mios.ps1 build`), dispatch through the
# `mios` function the profile body just defined; else just leave the
# operator at the loaded prompt.
if ($args.Count -gt 0) {
    $verb = $args[0]
    $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
    if (Get-Command mios -ErrorAction SilentlyContinue) {
        & mios $verb @rest
    } else {
        # Fallback when the profile didn't load: invoke the per-verb
        # bin script directly.
        $vScript = Join-Path $Script:MiOSBin "mios-$verb.ps1"
        if (Test-Path -LiteralPath $vScript) {
            & $vScript @rest
        } else {
            Write-Host "  [!] mios verb '$verb' not found ($vScript)." -ForegroundColor Yellow
        }
    }
}
'@
    Set-Content -Path $hubPath -Value $hubScript -Encoding UTF8
    Log-Ok "MiOS app staged at $hubPath"

    Log-Ok "Bin scripts staged: mios (app), mios-dash, mios-dev, mios-pull, mios-update, mios-config"

    # Also drop a VERSION file so mios-dash can render the current ver.
    Set-Content -Path (Join-Path $MiosInstallDir 'VERSION') -Value $MiosVersion.TrimStart('v') -Encoding UTF8

    # ── 3. PowerShell profile: mios-* functions (idempotent block) ────
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not $profilePath) { $profilePath = $PROFILE }
    $profileDir  = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    $marker   = '# >>> MiOS dash function >>>'
    $endMark  = '# <<< MiOS dash function <<<'
    $miosBinForProfile = $MiosBinDir -replace '\\', '\\'
    $dashFn = @"
$marker
# Auto-generated by mios-bootstrap/build-mios.ps1. Block is replaced
# on every re-run between the markers. ONLY the per-verb script
# wrappers live here.  The `mios <verb>` dispatcher lives in
# Get-MiOS.ps1's M:\MiOS\powershell\profile.ps1 -- this redirector
# dot-sources that profile FIRST, then runs this block.  Previous
# revisions had a `function mios { ... mios.ps1 ... }` here that
# REDEFINED the canonical dispatcher to call the legacy
# Show-MiosApp TUI hub -- operator 2026-05-09: "not unified
# dashboards!!!" (TWO different layouts rendering: the legacy hub
# AND the [dashboard].rows-driven Show-MiosDashboard).  Removed
# `function mios` here so the canonical dispatcher (which routes
# to mios-<verb> functions sharing the same Show-MiosDashboard
# layout) wins.
`$Global:MiosBin = "$miosBinForProfile"
function mios-dash    { & (Join-Path `$Global:MiosBin 'mios-dash.ps1')   @args }
function mios-dev     { & (Join-Path `$Global:MiosBin 'mios-dev.ps1')    @args }
function mios-pull    { & (Join-Path `$Global:MiosBin 'mios-pull.ps1')   @args }
function mios-update  { & (Join-Path `$Global:MiosBin 'mios-update.ps1') @args }
function mios-config  { & (Join-Path `$Global:MiosBin 'mios-config.ps1') @args }
$endMark
"@
    if ($existing -match [regex]::Escape($marker)) {
        $pattern  = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMark))"
        $safeRepl = $dashFn -replace '\$', '$$$$'
        $existing = [regex]::Replace($existing, $pattern, $safeRepl)
    } else {
        $existing = ($existing.TrimEnd() + "`n`n" + $dashFn + "`n").TrimStart()
    }
    Set-Content -Path $profilePath -Value $existing -Encoding UTF8 -NoNewline
    Log-Ok "PowerShell profile updated with mios-* functions"

    # ── 4. Windows Terminal "MiOS" profile (settings.json patch) ──────
    #
    # The canonical implementation now lives in mios-bootstrap/Get-MiOS.ps1
    # (Install-MiOSGeistFont + Install-MiOSTerminalProfile + Get-MiOSCenteredWindowPosition).
    # Get-MiOS.ps1 runs FIRST on the irm|iex entry path, before this script
    # even starts, so the WT profile is already in place by the time
    # build-mios.ps1 lands here. The only thing we still rebind here is
    # the profile's commandline, so launching the "MiOS" tab from a
    # standalone WT (after install) opens the staged hub script (mios.ps1)
    # rather than a bare pwsh. Get-MiOS.ps1's commandline is just `pwsh
    # -NoLogo`; once the install dir exists we want it to launch the menu.
    $wtSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path $wtSettings)) {
        $wtSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
    }
    $hubPathForJson = $hubPath -replace '\\', '\\'
    # Per operator (clarified 2026-05-07): "MiOS app opens to a windows
    # terminal wherein 'mios *' invocations are done on the windows
    # host first and relevant MiOS-DEV 'mios *' invocations are
    # directly passed through to the podman-MiOS-DEV machine and then
    # the terminal is sshd in to the MiOS-DEV environment directly".
    #
    # So MiOS profile commandline = Windows-side pwsh (loads MiOS PS
    # profile body with dashboard + `mios <verb>` dispatcher). The
    # dispatcher decides per-verb: Windows-host or pass-through to
    # MiOS-DEV via wsl/ssh. MiOS and MiOS-DEV WT profiles are
    # DIFFERENT entry points to the SAME branded experience -- MiOS
    # = Windows terminal, MiOS-DEV = direct dev VM shell.
    #
    # Get-MiOS.ps1's Install-MiOSTerminalProfile owns commandline +
    # startingDirectory; we ONLY refresh the icon here (Pass-2 has
    # access to mios.ico after Generate-MiosIcons ran).
    if (Test-Path $wtSettings) {
        try {
            $wtRaw = Get-Content $wtSettings -Raw
            $wtRaw = [regex]::Replace($wtRaw, '(?ms)/\*.*?\*/', '')
            $wtRaw = [regex]::Replace($wtRaw, '(?m)^\s*//.*$', '')
            $wtRaw = [regex]::Replace($wtRaw, ',(\s*[}\]])', '$1')
            $wtJson = $wtRaw | ConvertFrom-Json

            $miosGuid    = '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}'
            $miosDevGuid = '{a8b5c2d3-e4f5-6789-abcd-ef0123456790}'
            if ($wtJson.profiles -and $wtJson.profiles.list) {
                foreach ($p in $wtJson.profiles.list) {
                    if ($p.guid -eq $miosGuid -or $p.guid -eq $miosDevGuid) {
                        # ICON ONLY -- commandline + startingDirectory
                        # owned by Get-MiOS.ps1's Pass-1 patcher.
                        if ($icoPath -and (-not $p.PSObject.Properties['icon'])) {
                            $p | Add-Member -NotePropertyName icon -NotePropertyValue $icoPath -Force
                        } elseif ($icoPath) {
                            $p.icon = $icoPath
                        }
                    }
                }
                $wtJson | ConvertTo-Json -Depth 32 | Set-Content -Path $wtSettings -Encoding UTF8
                Log-Ok "Windows Terminal MiOS + MiOS-DEV profile icons refreshed (commandline left untouched)"
            } else {
                Log-Warn "Windows Terminal MiOS profile not found (Get-MiOS.ps1 entry didn't run?) -- skipping rebind"
            }
        } catch {
            Log-Warn "Windows Terminal settings.json rebind failed: $($_.Exception.Message)"
        }
    } else {
        Log-Warn "Windows Terminal not installed (no settings.json found) -- launcher will fall back to bare pwsh"
    }

    # ── 5. Desktop primary launcher + Start Menu MiOS folder ──────────
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $shell      = New-Object -ComObject WScript.Shell

    # Resolve toolchain paths once.
    $wtExe   = (Get-Command wt.exe   -ErrorAction SilentlyContinue).Source
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwshExe) {
        Log-Warn "pwsh.exe / powershell.exe not found -- launcher shortcuts skipped"
        return
    }

    # New-MiosShortcut -- helper that drops a single .lnk. Returns the
    # path so callers can log it.
    function New-MiosShortcut {
        param(
            [string]$LnkPath,
            [string]$TargetExe,
            [string]$ArgsString,
            [string]$IconFile,
            [string]$Description
        )
        $lnk = $shell.CreateShortcut($LnkPath)
        $lnk.TargetPath       = $TargetExe
        $lnk.Arguments        = $ArgsString
        $lnk.WorkingDirectory = $env:USERPROFILE
        if ($IconFile -and (Test-Path $IconFile)) { $lnk.IconLocation = "$IconFile,0" }
        $lnk.Description      = $Description
        $lnk.WindowStyle      = 1
        $lnk.Save()
        # Brand the shortcut with an AppUserModelID so Windows treats it
        # as a distinct first-class app -- not a generic "PowerShell
        # shortcut". This makes (a) Pin-to-Start group all MiOS launches
        # under the same tile, (b) the taskbar group spawned wt.exe
        # windows under the MiOS app, and (c) Start search surface MiOS
        # as its own entry instead of collapsing under "Windows
        # PowerShell".
        try { Set-MiosShortcutAppUserModelID -LnkPath $LnkPath -AppId 'MiOS.Workstation' } catch { Log-Warn "AppUserModelID set failed: $($_.Exception.Message)" }
        return $LnkPath
    }

    # Install the C# IPropertyStore helper once per session so each
    # New-MiosShortcut call doesn't re-Add-Type. PS 5.1 + 7 compatible.
    if (-not ('MiOS.Native.Aumid' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MiOS.Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr p;
        public IntPtr p2;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PROPERTYKEY pkey);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        [PreserveSig] int Commit();
    }
    public static class Aumid {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
        public static extern void SHGetPropertyStoreFromParsingName(
            string pszPath, IntPtr pbc, int flags, ref Guid riid, out IPropertyStore ppv);
        [DllImport("ole32.dll", PreserveSig=false)]
        public static extern void PropVariantClear(ref PROPVARIANT pvar);
        public static void SetAppUserModelID(string lnkPath, string appId) {
            Guid ipsGuid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore ps;
            SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2, ref ipsGuid, out ps);
            try {
                PROPERTYKEY pk = new PROPERTYKEY {
                    fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                    pid = 5
                };
                IntPtr strPtr = Marshal.StringToCoTaskMemUni(appId);
                PROPVARIANT pv = new PROPVARIANT { vt = 31, p = strPtr };
                try {
                    ps.SetValue(ref pk, ref pv);
                    ps.Commit();
                } finally {
                    PropVariantClear(ref pv);
                }
            } finally {
                Marshal.FinalReleaseComObject(ps);
            }
        }
    }
}
'@ -Language CSharp -ErrorAction SilentlyContinue
    }

    function Set-MiosShortcutAppUserModelID {
        param([string]$LnkPath, [string]$AppId)
        if (-not (Test-Path -LiteralPath $LnkPath)) { return }
        if (-not ('MiOS.Native.Aumid' -as [type])) { return }
        [MiOS.Native.Aumid]::SetAppUserModelID($LnkPath, $AppId)
    }

    # Try programmatic Pin to Start. Works on Windows 10; no-op on
    # Windows 11 (Microsoft removed the "Pin to Start" verb in 21H2+).
    # Operators on Win11 see a hint to right-click -> Pin manually.
    function Invoke-MiosPinToStart {
        param([string]$LnkPath)
        if (-not (Test-Path -LiteralPath $LnkPath)) { return $false }
        try {
            $shellApp = New-Object -ComObject Shell.Application
            $folderObj = $shellApp.Namespace((Split-Path $LnkPath -Parent))
            $itemObj = $folderObj.ParseName((Split-Path $LnkPath -Leaf))
            $pinVerb = $itemObj.Verbs() | Where-Object { $_.Name -replace '&', '' -match '^(Pin to Start|Pin to taskbar)$' } | Select-Object -First 1
            if ($pinVerb) {
                $pinVerb.DoIt()
                return $true
            }
        } catch {}
        return $false
    }

    # ── ONE shortcut: MiOS (the hub) ─────────────────────────────────
    # Replaces the previous six per-verb shortcuts. Operators launch
    # MiOS, get the hub menu, pick a verb. All verbs reachable from
    # one icon. Desktop and Start Menu both point at the same hub.
    #
    # Native-app behavior: the .lnk targets a tiny launcher script
    # (mios-launch.ps1) staged under $MiosBinDir. The launcher computes
    # the screen-centered pixel position for an 80x30 acrylic window on
    # whichever monitor the cursor is on, runs `wt.exe -p MiOS --focus`
    # at that position, then re-centers via Win32 SetWindowPos using
    # the WT window's actual outer rect. Result: every double-click
    # lands a borderless, screen-centered MiOS terminal -- even on
    # multi-monitor + scaled-DPI hosts.
    $hubResizePrelude = "try { `$H=Get-Host; `$H.UI.RawUI.WindowSize=(New-Object Management.Automation.Host.Size 80,30) } catch {}"
    $miosLauncher = Join-Path $MiosBinDir 'mios-launch.ps1'
    $launcherSrc = @'
# mios-launch.ps1 -- native-app launcher for MiOS / MiOS-DEV WT profiles.
# Spawns wt.exe with the requested profile in focus mode (borderless,
# no titlebar, no tab row), screen-centered on whichever monitor the
# cursor is currently on, and re-centers continuously via Win32
# SetWindowPos to defeat WT's --pos-ignored-in-focus regression.
# Runs invisibly (parent shortcut uses -WindowStyle Hidden).
#
# Parameters:
#   -Profile <name>  WT profile to launch.  'MiOS' (hub, default) or
#                    'MiOS-DEV' (wsl.exe -d podman-MiOS-DEV --user mios).
#   -Verb <name>     Optional. If set AND Profile=MiOS, the launched
#                    pwsh runs `mios <verb>` after the dashboard so
#                    the operator lands inside the verb's output (e.g.
#                    `mios help` for the MiOS Help.lnk shortcut).
#                    For Profile=MiOS-DEV, -Verb is currently ignored
#                    -- the dev profile drops the operator straight
#                    into the dev VM bash shell.
param(
    [string]$Profile = 'MiOS',
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
# pixel rect on 200% DPI hosts -- operator-reported regression: "MiOS
# app has launched with 1/2 sized window now". WT auto-pixel-sizes
# the window correctly for the active DPI when spawned with --size
# in cells; we just need to wait for the window to surface and then
# read its ACTUAL pixel dims via GetWindowRect for centering.
$Cols   = 80
$Rows   = 20

# Pre-spawn target position is a best-effort estimate using the
# operator's primary-screen DPI. If WT honors --pos, this is where it
# lands initially; the post-launch SetWindowPos retry corrects to the
# ACTUAL cell-derived pixel dims regardless.
$cur    = [System.Windows.Forms.Cursor]::Position
$work   = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
# Rough estimate -- only used for initial --pos hint; final pos is
# computed AFTER the window surfaces using the real dims.
$_cellW = 10
$_cellH = 20
$x = [int]($work.X + [math]::Max(0, $work.Width  - ($Cols * $_cellW + 20)) / 2)
$y = [int]($work.Y + [math]::Max(0, $work.Height - ($Rows * $_cellH + 12)) / 2)
if ($x -lt $work.X) { $x = $work.X }
if ($y -lt $work.Y) { $y = $work.Y }

# Resolve wt.exe to WT STABLE -- per operator pivot: target the base
# Windows Terminal install, not Preview. Get-AppxPackage InstallLocation
# is canonical; App Execution Alias is the fallback.
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
    [System.Windows.Forms.MessageBox]::Show("Windows Terminal Preview (wt.exe) is not installed. Run 'irm | iex' Get-MiOS.ps1 to install it.", "MiOS", 'OK', 'Error') | Out-Null
    exit 1
}

# `-w MiOS` names the window so it matches the post-bootstrap spawn
# AND the Win+Space global summon binding can target it.
# When -Verb is set on the MiOS hub profile, append the verb to the
# wt.exe commandline so the spawned pwsh runs `mios <verb>` after
# loading the profile body.  For MiOS-DEV (or no verb), the profile's
# bound commandline runs unchanged.
$wtArgs = @('-w','MiOS','--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p',$Profile)
if ($Verb -and $Profile -eq 'MiOS') {
    # `--` separates wt.exe args from the COMMANDLINE that the spawned
    # tab runs.  Override the profile commandline by passing pwsh.exe
    # explicitly with the MiOS profile body dot-sourced and the verb
    # dispatched.  The mios-launch.exe / mios-launch.ps1 has already
    # resolved $defaultPwsh so we re-resolve here for the same value.
    $_pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $_pwsh) { $_pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $_profileBody = 'M:\MiOS\powershell\profile.ps1'
    $_inner = "if (Test-Path '$_profileBody') { . '$_profileBody' }; mios $Verb"
    $wtArgs += @('--', $_pwsh, '-NoLogo', '-NoExit', '-NoProfile', '-Command', $_inner)
}
Start-Process -FilePath $wtExe -ArgumentList $wtArgs

# Post-launch re-center: WT in focus mode often ignores --pos. Wait
# briefly for the WT hwnd to surface, then SetWindowPos to the true
# screen-centered coords using the actual outer-rect dims.
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
    # NO frame-style strip -- DWM acrylic compositor needs WS_THICKFRAME
    # / WS_CAPTION to allocate the per-window swap chain that backs the
    # blur surface. Stripping them was killing acrylic. WT's --focus +
    # padding=0 + suppressApplicationTitle deliver the closest-to-
    # frameless WT can do while keeping acrylic alive.

    # Persistent re-center loop. Operator-reported regression 2026-05-09:
    # "window should refresh its position by tick(s) always homing to
    # the active screen's center". WT in focus mode ignores --pos AND
    # does its own size renegotiation 1-2x post-spawn (acrylic backdrop
    # allocation, font cache, focus-mode resize), so a single-shot
    # SetWindowPos loses every race.
    #
    # Re-center every 250ms for 30 seconds (120 ticks) so:
    #  * the operator sees the window land centered immediately
    #  * subsequent WT-internal size adjustments get re-centered
    #  * after 30s the loop exits so the operator can manually drag
    #    the window without it teleporting back
    #
    # Each tick re-reads the cursor's current screen so if the
    # operator moves the mouse to a different monitor mid-launch,
    # the window follows.
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $rect = New-Object MiOSLaunch.Native.Win+RECT
        if ([MiOSLaunch.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) {
            $rw = $rect.Right - $rect.Left
            $rh = $rect.Bottom - $rect.Top
            if ($rw -gt 0 -and $rh -gt 0) {
                # Re-read cursor position each tick so multi-monitor
                # operators can pull the window to whichever screen
                # has the cursor.
                $_curNow  = [System.Windows.Forms.Cursor]::Position
                $_workNow = [System.Windows.Forms.Screen]::FromPoint($_curNow).WorkingArea
                $cx = [int]($_workNow.X + ($_workNow.Width  - $rw) / 2)
                $cy = [int]($_workNow.Y + ($_workNow.Height - $rh) / 2)
                # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14 --
                # don't steal focus or fight z-order with other windows.
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $cx, $cy, $rw, $rh, 0x14)
            }
        }
        Start-Sleep -Milliseconds 250
    }
}
'@
    if (-not (Test-Path $MiosBinDir)) { New-Item -ItemType Directory -Path $MiosBinDir -Force | Out-Null }
    Set-Content -Path $miosLauncher -Value $launcherSrc -Encoding UTF8
    Log-Ok "MiOS native launcher staged: $miosLauncher"

    # Compile a TINY native .exe launcher with subsystem:Windows (no
    # console). Operator-reported requirement: "opening apps shouldn't
    # open a regular windows terminal/powershell window before launching
    # the MiOS app ecosystem(s)" + "opening the app window now opens NOT
    # centered at all". The previous wt.exe-direct .lnk eliminated the
    # pwsh pre-flash but lost the post-launch centering. The pwsh-File
    # .lnk had centering but flashed. A native .exe with no console gets
    # us BOTH: zero flash + post-launch SetWindowPos centering loop.
    $miosLauncherExe = Join-Path $MiosBinDir 'mios-launch.exe'
    $launcherCs = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class MiOSLaunch {
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int q, uint f);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }

    static int Main(string[] args) {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {}
        string profile = (args.Length > 0) ? args[0] : "MiOS";
        string cols = (args.Length > 1) ? args[1] : "80";
        string rows = (args.Length > 2) ? args[2] : "20";
        // Resolve wt.exe via APPX install location (preferred) or PATH.
        string wt = null;
        try {
            string ps = "powershell.exe";
            var psi = new ProcessStartInfo(ps, "-NoProfile -Command \"(Get-AppxPackage Microsoft.WindowsTerminal).InstallLocation\"");
            psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
            var p = Process.Start(psi); string loc = p.StandardOutput.ReadToEnd().Trim(); p.WaitForExit();
            if (!string.IsNullOrEmpty(loc)) {
                string cand = Path.Combine(loc, "wt.exe");
                if (File.Exists(cand)) wt = cand;
            }
        } catch {}
        if (wt == null) {
            foreach (string d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';')) {
                if (string.IsNullOrEmpty(d)) continue;
                try { string c = Path.Combine(d, "wt.exe"); if (File.Exists(c)) { wt = c; break; } } catch {}
            }
        }
        if (wt == null) { MessageBox.Show("Windows Terminal (wt.exe) not found. Re-run the MiOS bootstrap.","MiOS",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
        DateTime spawnAt = DateTime.UtcNow;
        try {
            var psi = new ProcessStartInfo(wt, "-w " + profile + " --size " + cols + "," + rows + " --focus -p " + profile);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process.Start(psi);
        } catch (Exception ex) { MessageBox.Show("wt.exe spawn failed: " + ex.Message,"MiOS",MessageBoxButtons.OK,MessageBoxIcon.Error); return 2; }
        // Find the WT window we just spawned + center it on the
        // operator's active monitor. 12 ticks @ 500ms = ~6s of
        // persistent re-centering to defeat WT's post-spawn layout
        // renegotiations.
        IntPtr hwnd = IntPtr.Zero;
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(8000);
        while (DateTime.UtcNow < deadline && hwnd == IntPtr.Zero) {
            try {
                var ps = Process.GetProcessesByName("WindowsTerminal").Where(p => p.StartTime.ToUniversalTime() >= spawnAt.AddSeconds(-1)).OrderByDescending(p => p.StartTime).FirstOrDefault();
                if (ps != null && ps.MainWindowHandle != IntPtr.Zero && IsWindowVisible(ps.MainWindowHandle)) hwnd = ps.MainWindowHandle;
            } catch {}
            if (hwnd == IntPtr.Zero) Thread.Sleep(150);
        }
        if (hwnd == IntPtr.Zero) return 0;
        Point cur = Cursor.Position;
        Screen scr = Screen.FromPoint(cur);
        for (int i = 0; i < 12; i++) {
            RECT r;
            if (GetWindowRect(hwnd, out r)) {
                int w = r.R - r.L, h = r.B - r.T;
                if (w > 0 && h > 0) {
                    int x = scr.WorkingArea.X + Math.Max(0, scr.WorkingArea.Width  - w) / 2;
                    int y = scr.WorkingArea.Y + Math.Max(0, scr.WorkingArea.Height - h) / 2;
                    // SWP_NOZORDER | SWP_NOACTIVATE = 0x14
                    SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, 0x14);
                }
            }
            Thread.Sleep(500);
        }
        return 0;
    }
}
'@
    # PS 5.1's Add-Type rejects -OutputType WindowsApplication. Invoke
    # the .NET Framework C# compiler (csc.exe) directly. Ships with
    # every Windows machine that has .NET 4.x installed (which is all
    # supported Windows versions). The /target:winexe flag sets PE
    # subsystem:Windows so the resulting .exe has no console.
    $_csc = $null
    foreach ($_cscCand in @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )) {
        if (Test-Path -LiteralPath $_cscCand) { $_csc = $_cscCand; break }
    }
    if ($_csc) {
        $_launcherCs = Join-Path $env:TEMP ('mios-launch-' + [guid]::NewGuid().Guid.Substring(0,8) + '.cs')
        try {
            Set-Content -LiteralPath $_launcherCs -Value $launcherCs -Encoding UTF8
            $_cscArgs = @(
                '/nologo',
                '/target:winexe',                # subsystem:Windows -- no console host
                '/optimize+',
                '/reference:System.Drawing.dll',
                '/reference:System.Windows.Forms.dll',
                ('/out:' + $miosLauncherExe),
                $_launcherCs
            )
            $_cscOut = & $_csc @_cscArgs 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $miosLauncherExe)) {
                Log-Ok "MiOS native .exe launcher compiled via csc.exe: $miosLauncherExe (subsystem:Windows -- zero pre-flash)"
            } else {
                Log-Warn ("mios-launch.exe csc compile failed (exit {0}): {1}" -f $LASTEXITCODE, (($_cscOut | Select-Object -Last 5) -join ' / '))
                $miosLauncherExe = $null
            }
        } catch {
            Log-Warn "mios-launch.exe csc compile failed: $($_.Exception.Message) -- falling back to pwsh launcher (will pre-flash)"
            $miosLauncherExe = $null
        } finally {
            if (Test-Path -LiteralPath $_launcherCs) { Remove-Item -LiteralPath $_launcherCs -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Log-Warn "csc.exe not found under %WINDIR%\Microsoft.NET\Framework{,64}\v4.0.30319 -- mios-launch.exe not compiled"
        $miosLauncherExe = $null
    }

    # Shortcut targets WT.EXE DIRECTLY -- no pwsh launcher pre-flash.
    # Operator-reported regression: "opening apps shouldn't open a regular
    # windows terminal/powershell window before launching the MiOS app
    # ecosystem(s) -- MiOS app icons opens the app windows directly -- no
    # flashing a prompt that then launches the correct MiOS terminal
    # profile/application(s)".
    #
    # The previous launcher pwsh.exe -NoProfile -WindowStyle Hidden -File
    # mios-launch.ps1 still produced a brief conhost flash before wt.exe
    # spawned (Windows shows the host process briefly even with
    # WindowStyle=Hidden). wt.exe is itself a windowed application -- the
    # .lnk pointing at wt.exe with the right args produces zero flash
    # because there's no intermediate console host.
    #
    # Trade-off: lose the centering retry loop that mios-launch.ps1
    # provided. WT's --pos flag honors the initial position; the post-
    # bootstrap auto-launch path (in Get-MiOS.ps1's elevation block) still
    # runs the persistent re-center for the post-install spawn, but the
    # ongoing daily-shortcut path leans on WT's own positioning. If WT's
    # placement drifts the operator can edit globals.initialPosition in
    # mios.toml or right-click + drag.
    if ($miosLauncherExe -and (Test-Path -LiteralPath $miosLauncherExe)) {
        # Native .exe launcher with subsystem:Windows -- ZERO console
        # flash + post-launch SetWindowPos centering. Best of both worlds.
        $hubTarget = $miosLauncherExe
        $hubArgs   = "MiOS $($script:MiosAppCols) $($script:MiosAppRows)"
    } elseif ($wtExe) {
        # Fallback: wt.exe direct (no flash but no centering).
        $hubTarget = $wtExe
        $hubArgs   = "-w MiOS --size $($script:MiosAppCols),$($script:MiosAppRows) --focus -p MiOS"
    } else {
        # Fallback: no wt.exe found -- run the bare hub script in a pwsh
        # console (still pre-flashes but at least gives the operator a
        # working shell). This branch should be unreachable on a
        # successful install since WT is a Phase 5 prerequisite.
        $hubTarget = $pwshExe
        $hubArgs   = "-NoExit -ExecutionPolicy Bypass -Command `"& { $hubResizePrelude; & '$hubPath' }`""
    }

    $hubDesc = 'MiOS -- Immutable Fedora AI workstation. One launcher; all verbs accessible from the menu inside.'
    $smLnk   = Join-Path $StartMenuDir 'MiOS.lnk'
    New-MiosShortcut -LnkPath $smLnk -TargetExe $hubTarget -ArgsString $hubArgs -IconFile $icoPath -Description $hubDesc | Out-Null
    Log-Ok "Start Menu: $smLnk (AppUserModelID = MiOS.Workstation)"

    if (Test-Path $desktopDir) {
        $deskLnk = Join-Path $desktopDir 'MiOS.lnk'
        New-MiosShortcut -LnkPath $deskLnk -TargetExe $hubTarget -ArgsString $hubArgs -IconFile $icoPath -Description $hubDesc | Out-Null
        Log-Ok "Desktop: $deskLnk"
    }

    # Programmatic Pin to Start. On Windows 10 this works -- the MiOS
    # tile lands in the operator's Start menu pinned area. On Windows
    # 11 (21H2+) Microsoft removed the "Pin to Start" verb and there's
    # no supported programmatic replacement; the no-op falls through
    # and we log a hint so the operator knows to right-click → Pin
    # to Start themselves.
    if (Invoke-MiosPinToStart -LnkPath $smLnk) {
        Log-Ok "MiOS pinned to Start menu (Windows 10 verb path)"
    } else {
        # Determine whether we're on Win11 to tailor the hint.
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        if ($os -match 'Windows 11') {
            Log-Warn "Windows 11 removed programmatic Pin-to-Start. Right-click MiOS in Start search → Pin to Start to add the tile manually."
        } else {
            Log-Warn "Pin-to-Start verb unavailable. Right-click '$smLnk' → Pin to Start to add the tile."
        }
    }

    # ── Per-verb native-app shortcuts ────────────────────────────────
    # Per operator: every MiOS verb appears as its own native Windows
    # app so MiOS-DEV / Dashboard / Configurator / Build are findable
    # in Start search and pinnable to taskbar/Start individually --
    # not just as items inside the hub menu. Each shortcut targets the
    # corresponding bin/mios-*.ps1 script with its dedicated icon.
    # The main MiOS.lnk above stays as the unified hub.
    # Per-verb shortcuts -- minimal, operator-curated set.
    # The hub 'MiOS.lnk' is created earlier at line ~5743 (the terminal
    # itself). Operator-typed verbs (build / dash / update / pull) are
    # NOT separate apps -- they're commands typed inside the MiOS
    # terminal. The native-app surface is exactly five:
    #
    #   1. MiOS              The Windows-side terminal (themed WT MiOS
    #                        profile, dashboard on launch). Created at
    #                        line ~5743 as the hub.
    #   2. MiOS-DEV          Drops directly into podman-MiOS-DEV with
    #                        the Linux-side dashboard rendering at
    #                        login (full piping/framing/ASCII logo,
    #                        all theming).
    #   3. MiOS Config       Opens mios.html (the configurator) in the
    #                        operator's default browser. Browser saves
    #                        edited mios.toml to %USERPROFILE%\Downloads;
    #                        `mios build` step 2 promotes Downloads
    #                        edits into M:\etc\mios + M:\usr\share\mios.
    #   4. MiOS Help         Full verb + functionality reference.
    #   5. Uninstall MiOS    Created in the legacy block ~line 7126.
    #
    # Both Start Menu .lnk AND Desktop .lnk for each.
    # The native-app catalog resolves through mios.toml [apps] (SSOT).
    # Operator-renames the apps via mios.html -- the configurator writes
    # mios.toml -- next install regenerates Start Menu / Desktop shortcuts
    # against the new name+bin+icon set. Vendor fallback below mirrors
    # what mios.toml [apps] ships with for cold first-run before any
    # operator edit.
    $verbShortcuts = @(
        @{ Name = 'MiOS-DEV';    Bin = 'mios-dev.ps1';    Icon = 'mios-dev.ico';    Desc = 'Open MiOS-DEV (podman machine) directly to its themed dashboard' },
        @{ Name = 'MiOS Config'; Bin = 'mios-config.ps1'; Icon = 'mios-config.ico'; Desc = 'Open mios.html (the HTML configurator) in your default browser to edit mios.toml' },
        @{ Name = 'MiOS Help';   Bin = 'mios-help.ps1';   Icon = 'mios-help.ico';   Desc = 'Full verb + functionality reference (every MiOS command and where things live)' }
    )
    try {
        $_appsTomlText = $null
        foreach ($_cand in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $MiosBootstrapShadow 'mios.toml'))) {
            # C:\MiOS deliberately excluded -- dev working tree, not consumer path
            if (Test-Path -LiteralPath $_cand) { try { $_appsTomlText = [IO.File]::ReadAllText($_cand, (New-Object System.Text.UTF8Encoding($false))); break } catch {} }
        }
        if ($_appsTomlText) {
            # Source of truth: [apps.shortcuts] -- not [apps] (which holds
            # hub-app metadata: aumid, start_menu_folder, hub_shortcut_name).
            $_appsBlock = [regex]::Match($_appsTomlText, '(?ms)^\[apps\.shortcuts\]\s*\r?\n(.*?)(?=^\[|\z)')
            if ($_appsBlock.Success) {
                $_resolvedApps = @()
                foreach ($_ln in ($_appsBlock.Groups[1].Value -split "`n")) {
                    $_am = [regex]::Match($_ln, '^\s*[a-z0-9_-]+\s*=\s*\{[^}]*name\s*=\s*"([^"]+)"[^}]*bin\s*=\s*"([^"]+)"[^}]*icon\s*=\s*"([^"]+)"[^}]*description\s*=\s*"([^"]+)"')
                    if ($_am.Success) {
                        $_resolvedApps += @{ Name = $_am.Groups[1].Value; Bin = $_am.Groups[2].Value; Icon = $_am.Groups[3].Value; Desc = $_am.Groups[4].Value }
                    }
                }
                if ($_resolvedApps.Count -gt 0) { $verbShortcuts = $_resolvedApps }
            }
        }
    } catch {}
    # UNIFIED launcher path: every per-verb shortcut goes through
    # mios-launch.ps1 -Verb <name> -- same dims, same focus mode, same
    # centering on cursor monitor, same WT MiOS profile chrome (acrylic
    # 50% opacity, scrollbar hidden, padding=0, no titlebar/tab-row).
    # Per operator 2026-05-08: "MiOS apps windows aren't the unified
    # MiOS terminal apps at all!! no center launching--broken--EVERYTHING".
    # Each verb opens its OWN named window (MiOS-<verb>) so a verb click
    # doesn't pile a tab into the hub MiOS window OR onto the operator's
    # most-recently-focused WT window (which `-w 0` does -- the prior
    # behaviour that broke center-launching).
    #
    # Special case: MiOS Config opens mios.html directly in the default
    # browser (zero terminal needed) -- operator-pinned design from
    # earlier turn. All other verbs route through the launcher.
    $miosLaunchPs1 = Join-Path $MiosBinDir 'mios-launch.ps1'
    foreach ($v in $verbShortcuts) {
        $vBin  = Join-Path $MiosBinDir $v.Bin
        $vIcon = Join-Path $MiosIconsDir $v.Icon
        $vLnk  = Join-Path $StartMenuDir ("{0}.lnk" -f $v.Name)
        $vTarget = $pwshExe
        $vArgs   = $null
        # MiOS Config short-circuits to the browser (no WT/pwsh needed).
        if ($v.Name -eq 'MiOS Config') {
            $_cfgCandidates = @(
                'M:\usr\share\mios\configurator\mios.html',
                (Join-Path $MiosBootstrapShadow 'usr\share\mios\configurator\mios.html'),
                (Join-Path $MiosShareDir 'mios\usr\share\mios\configurator\mios.html')
            )
            $_cfgHtml = $null
            foreach ($_cand in $_cfgCandidates) {
                if ($_cand -and (Test-Path -LiteralPath $_cand)) { $_cfgHtml = $_cand; break }
            }
            if ($_cfgHtml) {
                $vTarget = $_cfgHtml
                $vArgs   = ''
            } else {
                Log-Warn "MiOS Config: mios.html not found at any candidate -- shortcut falls back to mios-config.ps1 via launcher"
                $vTarget = $pwshExe
                $vArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$miosLaunchPs1`" -Verb config"
            }
        }
        # All other verbs (MiOS-DEV, MiOS Help, and any future verbs)
        # route through mios-launch.ps1 -Verb. The launcher itself
        # handles centering, focus mode, MiOS profile selection, and
        # spawning a new WT window (NOT a tab in the existing one).
        else {
            # Verb token: derive from .Bin (e.g. mios-help.ps1 -> 'help').
            $verbToken = ($v.Bin -replace '^mios-' -replace '\.ps1$').Trim().ToLower()
            if ([string]::IsNullOrWhiteSpace($verbToken)) { $verbToken = $v.Name.ToLower() }
            $vTarget = $pwshExe
            $vArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$miosLaunchPs1`" -Verb $verbToken"
        }
        # Start Menu (admin-installed all-users path).
        New-MiosShortcut -LnkPath $vLnk -TargetExe $vTarget -ArgsString $vArgs -IconFile $vIcon -Description $v.Desc | Out-Null
        # Desktop -- so the verb is also one click from the desktop.
        if ($desktopDir -and (Test-Path $desktopDir)) {
            $vDesk = Join-Path $desktopDir ("{0}.lnk" -f $v.Name)
            New-MiosShortcut -LnkPath $vDesk -TargetExe $vTarget -ArgsString $vArgs -IconFile $vIcon -Description $v.Desc | Out-Null
        }
        Log-Ok ("Per-verb Start Menu + Desktop shortcut: {0} -> {1}" -f $v.Name, $v.Bin)
    }

    # Garbage-collect any stale shortcuts from earlier revisions whose
    # names don't match the current 5-app set (MiOS, MiOS-DEV, MiOS
    # Config, MiOS Help, Uninstall MiOS). Idempotent: if absent, skip.
    # Cleans up both the per-verb shortcuts that were created in
    # earlier revisions AND legacy-named shortcuts.
    # NOTE: 'MiOS Configurator.lnk' is the older long-form name for
    # what is now 'MiOS Config.lnk' -- listed here so an upgrade from
    # a prior install doesn't leave both shortcuts visible.
    $staleLnks = @(
        # Removed verbs (now operator-typed inside the MiOS terminal):
        'MiOS Build.lnk', 'MiOS Configurator.lnk', 'MiOS Dashboard.lnk',
        'MiOS Update.lnk', 'MiOS Pull.lnk',
        # Legacy names from older revisions:
        'Build MiOS.lnk', 'MiOS Dev VM.lnk', 'MiOS Rebuild.lnk',
        'MiOS Setup.lnk', 'MiOS Terminal.lnk', 'MiOS Dev Shell.lnk',
        'MiOS Podman Shell.lnk'
    )
    foreach ($legacy in $staleLnks) {
        foreach ($dir in @($StartMenuDir, $desktopDir)) {
            if (-not $dir) { continue }
            $stale = Join-Path $dir $legacy
            if (Test-Path $stale) {
                try { Remove-Item $stale -Force -ErrorAction SilentlyContinue; Log-Ok "Removed stale shortcut: $stale" } catch {}
            }
        }
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

    # ── 6. Verify the dev distro is registered (or warn) ──────────────
    # Phase 3 ("MiOS-DEV distro") provisions the dev distro as
    # "podman-$DevDistro" (= "podman-MiOS-DEV"); the post-Phase-13
    # Rename-PodmanDevDistro pass drops that prefix to plain
    # "$DevDistro" (= "MiOS-DEV"). Probe canonical-first.
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}
    $devCandidates = @($DevDistro, "podman-$DevDistro", $LegacyDevName, "podman-$LegacyDevName")
    $matched = $wslList | Where-Object { $devCandidates -contains $_ } | Select-Object -First 1
    if ($matched) {
        Log-Ok "$matched distro registered -- launcher ready"
    } else {
        Log-Warn "$DevDistro distro not registered yet (Phase 3 should have provisioned it). The launcher's mios-dash will show 'not registered'; rerun this script or `podman machine init` to create it."
    }

    Log-Ok "MiOS launcher installed (Desktop + Start Menu). Open it to enter an 80x32 pwsh window with the MiOS dashboard."

    # ── 7. Re-run Get-MiOS.ps1's Install-MiOSPowerShellProfile +
    # Install-MiOSTerminalProfile so EVERY install path (irm|iex Get-MiOS,
    # mios-update, build-mios.ps1 BootstrapOnly, etc.) deterministically
    # re-substitutes:
    #   - M:\MiOS\powershell\profile.ps1 (Show-MiosDashboard frame_width /
    #     right_margin / cell budget literals from current mios.toml
    #     [terminal])
    #   - WT settings.json globals (root launchMode, profiles.defaults
    #     scrollbarState/padding/useAcrylic/opacity/systemBackdrop/
    #     suppressApplicationTitle/disableAnimations/useAtlasEngine/
    #     experimental.* from current mios.toml [theme])
    # Before this hook, ONLY the irm|iex Get-MiOS.ps1 entry path triggered
    # those substitutions. Every install.ps1 / mios-update / re-run of
    # build-mios.ps1 left the deployed dashboard + WT settings.json STALE,
    # so toml/omp.json edits looked like they had no effect (operator
    # iteration loop on 2026-05-08, which uninstalled + reinstalled
    # multiple times waiting for the dashboard to update -- it never did
    # because the Step 1-8 chain never ran).
    #
    # Operator pivot 2026-05-08: "irm|iex is the main entry point for ALL
    # things MiOS... FIX all in code!" -> all entry paths now route through
    # the same Install-MiOS* function bodies, sourced from the canonical
    # Get-MiOS.ps1 via the MIOS_GETMIOS_FUNCTIONS_ONLY=1 dot-source gate.
    $_getMiosCandidates = @(
        Join-Path $MiosRepoDir 'Get-MiOS.ps1'
        Join-Path $MiosBootstrapShadow 'Get-MiOS.ps1'
        'M:\Get-MiOS.ps1'
    )
    $_getMios = $_getMiosCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($_getMios) {
        try {
            $env:MIOS_GETMIOS_FUNCTIONS_ONLY = '1'
            # CRITICAL: do NOT use `. $path` -- PowerShell's parser
            # default encoding is cp1252 in many host configs (PS 5.1
            # always; pwsh 7 only when launched from a non-UTF8
            # console), and Get-MiOS.ps1 contains UTF-8 box-drawing
            # chars (│ ╭ ╮ ╰ ╯ ─). cp1252 reads `│` (UTF-8 E2 94 82)
            # as `â”‚` (mojibake) which crashes the parser with
            # "Unexpected token 'â”‚'". Read the file as explicit
            # UTF-8 and create a scriptblock from the string. dot-
            # sourcing the scriptblock runs in caller scope so all
            # function defs land here (build-mios.ps1's scope).
            $_gmSrc = [System.IO.File]::ReadAllText($_getMios, [System.Text.UTF8Encoding]::new($false))
            $_gmBlock = [scriptblock]::Create($_gmSrc)
            . $_gmBlock
            Remove-Item env:\MIOS_GETMIOS_FUNCTIONS_ONLY -ErrorAction SilentlyContinue
            if (Get-Command Install-MiOSPowerShellProfile -ErrorAction SilentlyContinue) {
                Install-MiOSPowerShellProfile | Out-Null
                Log-Ok "Get-MiOS Install-MiOSPowerShellProfile re-substituted (M:\MiOS\powershell\profile.ps1 from current mios.toml)"
            } else {
                Log-Warn "Install-MiOSPowerShellProfile not defined after Get-MiOS.ps1 dot-source -- gate may have triggered too early"
            }
            if (Get-Command Install-MiOSTerminalProfile -ErrorAction SilentlyContinue) {
                Install-MiOSTerminalProfile | Out-Null
                Log-Ok "Get-MiOS Install-MiOSTerminalProfile re-substituted (WT settings.json from current mios.toml)"
            }
        } catch {
            Remove-Item env:\MIOS_GETMIOS_FUNCTIONS_ONLY -ErrorAction SilentlyContinue
            Log-Warn "Get-MiOS.ps1 functions-only dot-source failed: $($_.Exception.Message). Dashboard + WT settings.json may be stale -- run 'irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex' to refresh."
        }
    } else {
        Log-Warn "Get-MiOS.ps1 not found in any candidate path ($($_getMiosCandidates -join ', ')) -- dashboard + WT settings.json patches skipped. Run 'irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex' to refresh."
    }
}

# =============================================================================
# MAIN -- wrapped so the window NEVER closes on error
# =============================================================================
$ExitCode = 0
try {

# ── Window resize (best-effort) + dashboard mode ──────────────────────────────
# Default = 'log' (linear, sequential phase + step log lines). The
# framed in-place dashboard has been a recurring source of
# host-compat issues -- some hosts honor [Console]::SetCursorPosition
# only intermittently, the probe can't catch every misbehavior, and
# the failure mode (frames stacking forever) is awful. Linear log is
# always correct.
#
# Operators who specifically want the framed live dashboard can
# opt in by setting $env:MIOS_DASHBOARD_MODE='interactive' before
# launching. The probe is still run as a sanity-check in that case
# so the opt-in falls back to log mode if the host is genuinely
# broken.
# 80x30 EXACTLY -- per feedback_mios_terminal_dimensions.md: "every
# spawned window must open at exactly 80 cols x 40 rows to match the
# dashboard frame." Anything wider creates transient state that the
# dashboard's strict-clamp width logic in Show-Dashboard would have
# to compensate for; cleaner to never go wide in the first place.
Try-ResizeConsole -Cols 80 -Rows 30
# Linear-log mode is the DEFAULT. Operator complaint:
#   "the spawned powershell window from irm|iex mios.bat entry still
#    flickers/pins to shells top row and flashes everytime a new print
#    occurs"
# That's the symptom of interactive (in-place repaint) mode -- every
# Show-Dashboard call rewrites the framed dashboard at the cursor-tracked
# top row, and conhost/WT pseudo-console tears visibly on per-row
# SetCursorPosition + Write. Linear log mode just streams Write-Host
# lines, no repaint, no flicker. Operators who specifically want the
# framed live dashboard opt in via $env:MIOS_DASHBOARD_MODE='interactive'.
$script:DashboardMode = if ($env:MIOS_DASHBOARD_MODE -eq 'interactive' -and (Test-DashboardCanRedraw)) {
    'interactive'
} else {
    'log'
}

# ── Banner ───────────────────────────────────────────────────────────────────
Clear-Host
$bTop = "╭" + ("─" * ($script:DW - 2)) + "╮"
$bBot = "╰" + ("─" * ($script:DW - 2)) + "╯"

# Box-row helper -- guarantees every banner row is exactly $DW visible
# chars wide, regardless of content length, so the right border lines
# up with the top/bottom corners. Previous hand-rolled padding used
# the wrong length for the inner string (counted "MiOS $version ..."
# instead of "'MiOS' $version ..." -- the apostrophes added 2 chars
# the pad math missed, so the title row was 2 cols wider than the
# top frame -- the operator's "framing is broken" symptom).
function _BoxRow {
    param([string]$Inner)
    $maxInner = $script:DW - 4
    if ($Inner.Length -gt $maxInner) {
        $Inner = $Inner.Substring(0, $maxInner)
    }
    "│ " + $Inner.PadRight($maxInner) + " │"
}

# Top-of-script banner. Title + tagline lines resolve through mios.toml
# [messages.installer_banner] (SSOT). Operator rebrands via mios.html.
# Vendor fallbacks below preserve the existing wording when no TOML
# is reachable. {version} placeholder substitutes $MiosVersion.
$_bannerTitle    = Get-MiosTomlValue -Section 'messages.installer_banner' -Key 'title'    -Default "'MiOS' {version}  --  Unified Windows Installer"
$_bannerTaglines = @(Get-MiosTomlValue -Section 'messages.installer_banner' -Key 'taglines' -Default @(
    'Immutable Fedora AI Workstation',
    'WSL2 + Podman  │  Offline Build Pipeline'
))
$_bannerTitle = $_bannerTitle -replace '\{version\}', $MiosVersion
Write-Host $bTop -ForegroundColor Cyan
Write-Host (_BoxRow $_bannerTitle) -ForegroundColor Cyan
foreach ($_tg in $_bannerTaglines) {
    Write-Host (_BoxRow ($_tg -replace '\{version\}', $MiosVersion)) -ForegroundColor Cyan
}
Write-Host $bBot -ForegroundColor Cyan
Write-Host ""

if ($script:DashboardMode -eq 'log') {
    # Resolve linear-log mode header lines from mios.toml
    # [messages.build_pipeline] (SSOT).  Vendor fallback below
    # preserves the existing wording when no toml is reachable.
    $_llNote = Get-MiosTomlValue -Section 'messages.build_pipeline' -Key 'linear_log_note' -Default "Note: console doesn't support in-place repaint -- running in linear log mode."
    $_llHint = Get-MiosTomlValue -Section 'messages.build_pipeline' -Key 'linear_log_hint' -Default "      Phase transitions + throttled step updates print sequentially below."
    Write-Host $_llNote -ForegroundColor Yellow
    Write-Host $_llHint -ForegroundColor DarkYellow
    Write-Host ""
}

# Capture the row where the dashboard will be drawn (right after banner)
$script:DashRow = try { [Console]::CursorTop } catch { 0 }

# ── Background heartbeat (interactive mode only) ─────────────────────────────
# Runs on a dedicated runspace so the spinner animates even when the
# main render loop is blocked on a long sub-process. Skipped in log
# mode -- without working SetCursorPosition the heartbeat would just
# stamp characters at the bottom of the buffer forever.
if ($script:DashboardMode -eq 'interactive') {
    $script:BgRs = [runspacefactory]::CreateRunspace()
    $script:BgRs.Open()
    $script:BgRs.SessionStateProxy.SetVariable('dashSync', $script:DashSync)
    $script:BgPs = [powershell]::Create()
    $script:BgPs.Runspace = $script:BgRs
    $null = $script:BgPs.AddScript({
        # Background spinner heartbeat. Writes a single character at
        # (SpinnerRow, SpinnerCol) every 120 ms so the operator sees the
        # script is still alive even when the main render loop is blocked
        # on a long sub-process.
        #
        # Race protection: dashSync.Rendering is set to $true by the main
        # thread immediately before Show-Dashboard writes its rows, and
        # cleared afterwards. The heartbeat skips its write while that
        # flag is set.
        $chars = @('|', '/', '-', [char]92)
        $i = 0
        while ($dashSync.Running) {
            [System.Threading.Thread]::Sleep(120)
            if ($dashSync.Rendering) { continue }
            $row = $dashSync.SpinnerRow
            $col = $dashSync.SpinnerCol
            if ($row -ge 0) {
                try {
                    $prevTop = [Console]::CursorTop
                    $prevLeft = [Console]::CursorLeft
                    [Console]::SetCursorPosition($col, $row)
                    [Console]::Write($chars[$i % 4])
                    [Console]::SetCursorPosition($prevLeft, $prevTop)
                } catch {}
                $i++
            }
        }
    })
    $script:BgHandle = $script:BgPs.BeginInvoke()
}

# Re-set console size again right before the first Show-Dashboard render.
# The earlier resize (~line 70) is the LOAD-TIME resize that fixes the $DW
# computation. This second resize is defensive: if some other code in the
# load path between line 70 and here changed the window size, this restores
# it. Idempotent. Dims source from mios.toml [terminal] (script:Mios* vars).
try {
    [Console]::SetWindowSize($script:MiosCols, $script:MiosRows)
    [Console]::SetBufferSize($script:MiosCols, $script:MiosScroll)
} catch {}

# Re-call the SAME Get-MiosFrameWidth helper so post-resize $DW is
# computed by ONE function (operator: "I said Unified!!!").
$script:DW = Get-MiosFrameWidth

Show-Dashboard -Force   # draw initial (all phases pending)

# ── Phase 0 -- Hardware + Prerequisites ──────────────────────────────────────
Start-Phase 0
$HW = Get-Hardware
Write-Log "hw: CPU=$($HW.Cpus)  RAM=$($HW.RamGB)GB  Disk=$($HW.DiskGB)GB  GPU=$($HW.GpuName)"
Write-Log "hw: Base=$($HW.BaseImage)  Model=$($HW.AiModel)"
$gpuShort = $HW.GpuName -replace 'NVIDIA GeForce ','RTX ' -replace 'NVIDIA Quadro ','Quadro '
$script:HWInfo    = "Host:$($env:COMPUTERNAME)  RAM:$($HW.RamGB)GB  CPU:$($HW.Cpus)c  GPU:$gpuShort  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')"
$script:IdentInfo = "Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$($HW.AiModel)"
Show-Dashboard -Force

$preOk = $true
# Auto-install Phase 0 prerequisites via winget. Per operator: "the
# irm|iex web invoke should also install all windows side pre-requisites".
# Phase 0 used to JUST CHECK + fail. Now we winget-install on miss
# so a fresh-system irm|iex carries the bootstrap end-to-end. The
# prereq catalog resolves through mios.toml [bootstrap.prereqs] (SSOT)
# so operators can swap to alternative implementations (Mercurial
# instead of Git, Hyper-V instead of WSL2 -- not that we recommend
# either, but the SSOT lets it happen) via mios.html.
$_prereqs = @(
    @{ Cmd = 'git';    Pkg = (Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'git_pkg'    -Default 'Git.Git');                 Label = 'Git';    Required = $true  }
    @{ Cmd = 'wsl';    Pkg = (Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'wsl_pkg'    -Default 'Microsoft.WSL');           Label = 'WSL2';   Required = $true  }
    @{ Cmd = 'podman'; Pkg = (Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'podman_pkg' -Default 'RedHat.Podman-Desktop');   Label = 'Podman'; Required = $true  }
)
foreach ($_pq in $_prereqs) {
    if (Get-Command $_pq.Cmd -EA SilentlyContinue) {
        $_ver = ''
        try {
            switch ($_pq.Cmd) {
                'git'    { $_ver = ((& git --version 2>&1) -replace 'git version ','') }
                'wsl'    { $_ver = 'available' }
                'podman' { $_ver = ((& podman --version 2>&1) -replace 'podman version ','') }
            }
        } catch {}
        Log-Ok ("{0} {1}" -f $_pq.Label, $_ver)
        continue
    }
    if (-not (Get-Command winget -EA SilentlyContinue)) {
        Log-Fail ("{0} not found and winget unavailable -- cannot auto-install. Install {1} manually." -f $_pq.Label, $_pq.Pkg)
        if ($_pq.Required) { $preOk = $false }
        continue
    }
    Log-Ok ("{0} not found -- winget installing {1}..." -f $_pq.Label, $_pq.Pkg)
    & winget install --id $_pq.Pkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 |
        ForEach-Object { Write-Log ("winget[{0}]: {1}" -f $_pq.Cmd, $_) }
    $_rc = $LASTEXITCODE
    # Refresh PATH so the just-installed tool is reachable in this session
    # (winget appends to the user's PATH but only NEW shells see it).
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH  = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
    } catch {}
    if (Get-Command $_pq.Cmd -EA SilentlyContinue) {
        Log-Ok ("{0} installed via winget" -f $_pq.Label)
    } elseif ($_pq.Cmd -eq 'wsl' -and $_rc -eq 0) {
        # WSL install often requires a reboot; the wsl.exe stub may not be
        # on PATH until then, but the install itself succeeded.
        Log-Warn ("{0} installed -- a reboot may be required for wsl.exe to surface on PATH" -f $_pq.Label)
    } else {
        Log-Fail ("{0} winget install exit {1} -- bootstrap cannot proceed without {2}" -f $_pq.Label, $_rc, $_pq.Cmd)
        if ($_pq.Required) { $preOk = $false }
    }
}

if (-not $preOk) { End-Phase 0 -Fail; throw "Prerequisites missing -- see log: $LogFile" }

# Pre-flight: scrub misplaced /etc/wsl.conf keys from .wslconfig's [wsl2]
# section BEFORE Phase 3 (podman machine init) talks to wsl.exe. A stale
# `systemd=true` here would otherwise crash Phase 3 with the FATAL
# "wsl: Unknown key 'wsl2.systemd' in <path>" surfaced as the last
# captured stderr line of the podman pipeline.
Repair-WslConfig

End-Phase 0

# ── Phase 1 -- Detecting existing build environment ──────────────────────────
Start-Phase 1
$activeDistro = Find-ActiveDistro

if ($activeDistro) {
    Log-Ok "MiOS repo found in $activeDistro"
    # mios.git is overlaid AT $MiosRepoDir root (M:\). Per 2026-05-06.
    $miosRepo = $MiosRepoDir
    if (Test-Path (Join-Path $miosRepo ".git")) {
        # Hard reset to origin/main -- a soft `pull --ff-only` was
        # silently failing on dirty working trees (e.g. after a
        # legacy-install migration kept old files at destination)
        # and the build kept running pre-fix scripts.
        Set-Step "Updating Windows-side repo (fetch + hard reset) and syncing to $activeDistro"
        Push-Location $miosRepo
        try {
            $fetchExit = Invoke-NativeQuiet { git fetch --depth=1 origin main }
            if ($fetchExit -eq 0) {
                $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                if ($resetExit -ne 0) {
                    Log-Warn "git reset --hard returned $resetExit"
                }
            } else {
                Log-Warn "git fetch returned $fetchExit -- working tree may be stale"
            }
        } finally { Pop-Location }
        Sync-RepoToDistro -Distro $activeDistro -WinPath $miosRepo | Out-Null
        Log-Ok "Repo synced to $activeDistro"
    }
    End-Phase 1
    # Skip the intermediate phases, go straight to build. BootstrapOnly
    # mode has TotalPhases=6 (PhStat indices 0..5) and FullBuild has
    # 14 (indices 0..13). Capping the loop at TotalPhases-1 keeps both
    # modes safe -- the previous unbounded `2..8` indexed PhStat[6..8]
    # in BootstrapOnly mode and threw "Index was outside the bounds
    # of the array" the moment phase 6 was touched. Caught by MAIN's
    # try/catch and surfaced as the dashboard's FATAL banner.
    $skipMax = [math]::Min(8, $script:TotalPhases - 1)
    for ($s = 2; $s -le $skipMax; $s++) {
        $script:PhStat[$s] = 2
        $script:PhStart[$s] = [datetime]::Now
        $script:PhEnd[$s]   = [datetime]::Now
    }
    Show-Dashboard -Force

    # Collect GHCR token in rebuild path (phase 6 is skipped above).
    $script:GhcrToken = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
                        elseif ($env:GITHUB_TOKEN)   { $env:GITHUB_TOKEN }
                        else { Read-Line "GitHub PAT for ghcr.io base image pull" "" }

    # Existing-distro fast path: smoke test + Windows install. The
    # auto-rename (Rename-PodmanDevDistro) is opt-in only via
    # $env:MIOS_RENAME_DISTRO=1 because podman hardcodes the
    # `podman-` prefix in WSLDistroName() -- after a rename, every
    # `podman machine start/init/ssh` fails with WSL_E_DISTRO_NOT_FOUND.
    # Hidden in user-facing labels is enough; the actual WSL distro
    # stays as `podman-MiOS-DEV` for podman compatibility.
    Restore-PodmanPrefix   # auto-recover from any previous rename
    if (Test-MiosDevDistroHealthy) {
        if ($env:MIOS_RENAME_DISTRO -in @('1','true','TRUE','yes')) {
            Rename-PodmanDevDistro
        }
    }
    Install-MiosWindowsTools   # winget install [packages.windows] (fastfetch, btop, pwsh, ...)
    Install-WindowsBranding
    Install-MiosLauncher
    if ($BootstrapOnly) {
        Log-Ok "-BootstrapOnly mode: existing $DevDistro is healthy, Windows install refreshed."
        End-Phase 1   # we never entered Phase 9 here
        return
    }

    # DEPRECATED PATH: Phase 9 Build on Windows. Unreachable since
    # $BootstrapOnly is force-set to $true at line 202; the
    # `if ($BootstrapOnly) { return }` block above catches every operator-
    # reachable invocation. The actual build pipeline runs INSIDE MiOS-DEV
    # via /usr/libexec/mios/mios-build-driver, triggered by the
    # `mios build` verb. Kept here as dead code so git-blame still resolves
    # legacy refs; a follow-up commit will delete this branch.
    Start-Phase 9
    $rc = Invoke-WslBuild -Distro $activeDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel
    if ($rc -eq 0) {
        End-Phase 9
        Invoke-DeployPipeline -HW $HW
    } else { End-Phase 9 -Fail; $ExitCode = $rc }
} else {

    if ($BuildOnly) { End-Phase 1 -Fail; throw "-BuildOnly: no 'MiOS' build environment found. Run without -BuildOnly first." }
    Log-Ok "No existing distro -- starting full install"
    End-Phase 1

    # ── Data disk first (full-partition overlay) ─────────────────────────────
    # Provision M:\ before Phase 2 clones repos, so EVERYTHING (repos,
    # dev VM VHDX, build artifacts, state, logs) lands on the data
    # disk instead of needing to migrate later. Phase 3 sees the disk
    # already in place and skips its own Initialize-MiosDataDisk call.
    Invoke-DataDiskBootstrap -HW $HW

    # ── Phase 2 -- Directories and repos ─────────────────────────────────────
    Start-Phase 2
    Write-Log "install scope: $MiosScope  install dir: $MiosInstallDir  programdata: $MiosProgramData"
    foreach ($d in @(
        $MiosInstallDir, $MiosRepoDir, $MiosBinDir, $MiosShareDir,
        $MiosProgramData, $MiosDistroDir, $MiosImagesDir, $MiosMachineCfg,
        $MiosConfigDir, $MiosDataDir, $MiosLogDir
    )) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Log-Ok "Directories under $MiosInstallDir ($MiosScope scope)"

    # ── Repos: BOTH overlaid at $MiosRepoDir root (M:\) ──────────────────────
    # Per the 2026-05-06 directive: M:\ root IS the mios.git working tree
    # AND has mios-bootstrap.git's files overlaid on top. The previous
    # "M:\MiOS\repo\mios + M:\MiOS\repo\mios-bootstrap as siblings" layout
    # is gone. Operator opens M:\ in Explorer and sees Get-MiOS.ps1,
    # Containerfile, automation/, install.sh, mios.toml, configurator.html,
    # /usr/, /etc/ -- everything at root.
    #
    # mios.git is the PRIMARY tree (M:\.git points here). mios-bootstrap.git
    # is cloned to $MiosBootstrapShadow (so its .git stays separate -- you
    # can't have two .gits at the same path), and its files are robocopied
    # onto M:\ root excluding .git.

    # ── Step 1: mios.git as the M:\ working tree ────────────────────────────
    # `git clone` refuses non-empty target dirs (M:\ has System Volume
    # Information / $RECYCLE.BIN / possibly $MiosInstallDir already), so
    # use `git init + remote add + fetch + reset --hard` to bring the tree
    # in WITHOUT touching pre-existing untracked files.
    if (Test-Path (Join-Path $MiosRepoDir ".git")) {
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_git_update' -Default "Updating mios.git (fetch + hard reset @ $MiosRepoDir)")
        Push-Location $MiosRepoDir
        try {
            $null = Invoke-NativeQuiet { git remote set-url origin $MiosRepoUrl }
            $fetchExit = Invoke-NativeQuiet { git fetch --depth=1 origin main }
            if ($fetchExit -eq 0) {
                $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                if ($resetExit -ne 0) { Log-Warn "mios.git: git reset --hard returned $resetExit" }
            } else {
                Log-Warn "mios.git: git fetch returned $fetchExit -- working tree may be stale"
            }
        } finally { Pop-Location }
    } else {
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_git_init' -Default "Initializing mios.git as the $MiosRepoDir working tree")
        # Pre-emptively whitelist M:\ as a safe.directory for git on
        # Windows. Git 2.35+ rejects operations in repos owned by a
        # different SID with: "fatal: detected dubious ownership in
        # repository at 'M:\'". Admin-spawned pwsh runs under
        # NT AUTHORITY\SYSTEM (or the elevated token's primary SID)
        # while M:\ was created by the operator's user SID. Without
        # this allowlist, every git operation in M:\ fails with
        # exit 128 and the operator-reported "git fetch from
        # https://github.com/mios-dev/MiOS.git failed (exit 128)
        # at M:\". Use --global so the setting persists across the
        # entire bootstrap (Phase 3+ may also git-operate at M:\).
        # `*` allowlist is acceptable here -- this is a single-user
        # workstation install on a freshly-shrunk partition; the
        # operator already accepted the agreement that authorizes
        # the bootstrap to mutate the system.
        & git config --global --add safe.directory '*' 2>&1 | ForEach-Object { Write-Log "git-safe-dir: $_" }
        & git config --global --add safe.directory $MiosRepoDir 2>&1 | ForEach-Object { Write-Log "git-safe-dir: $_" }
        Push-Location $MiosRepoDir
        try {
            $null = Invoke-NativeQuiet { git init -q }
            # ── git-for-windows quirk: `git init` at a DRIVE ROOT (M:\)
            # writes `core.worktree = M:/` to .git/config. That's a
            # Windows-style absolute path that breaks the Linux side of
            # the pipeline -- when Phase 3's quadlet-overlay-seed runs
            # `git fetch /mnt/m/.git`, upload-pack reads `core.worktree`,
            # tries to `chdir to 'M:/'` (literal Windows path on Linux),
            # and dies with:
            #     fatal: cannot chdir to 'M:/': No such file or directory
            # which cascades into:
            #     fatal: protocol error: bad pack header
            #     fatal: ambiguous argument 'FETCH_HEAD'
            #     [quadlet-overlay] / now contains 0 tracked mios.git files
            # Unsetting worktree (or pinning to '.' relative) restores the
            # default behavior: worktree = parent of .git dir, which on
            # Windows is M:\ and on Linux (via /mnt/m) is /mnt/m. Both
            # ends agree, fetch succeeds, the seed populates / inside
            # MiOS-DEV.
            $null = Invoke-NativeQuiet { git config --unset core.worktree }
            $null = Invoke-NativeQuiet { git remote add origin $MiosRepoUrl }
            # Capture stderr+stdout from git fetch so a failure surfaces
            # with diagnostic text. Wrapped in $ErrorActionPreference=
            # 'Continue' + PSNativeCommandUseErrorActionPreference=$false
            # so git's INFORMATIONAL stderr (the "From https://..." line
            # that fetch always prints on success) doesn't terminate the
            # script. Operator-reported regression: that informational
            # line was being thrown as a PowerShell exception under the
            # default 'Stop' preference, surfacing as
            # `FATAL: From https://github.com/mios-dev/MiOS` even though
            # fetch had succeeded.
            $fetchOut  = $null
            $fetchExit = & {
                $ErrorActionPreference = 'Continue'
                if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                    $PSNativeCommandUseErrorActionPreference = $false
                }
                $script:_fetchOut = & git fetch --depth=1 origin main 2>&1
                $LASTEXITCODE
            }
            $fetchOut = $script:_fetchOut
            $fetchOut | ForEach-Object { Write-Log "git-fetch: $_" }
            if ($fetchExit -ne 0) {
                $tail = ($fetchOut | Select-Object -Last 5) -join ' / '
                throw "mios.git: git fetch from $MiosRepoUrl failed (exit $fetchExit) at $MiosRepoDir`n        last: $tail"
            }
            $null = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
            $null = Invoke-NativeQuiet { git branch -f main FETCH_HEAD }
            $null = Invoke-NativeQuiet { git checkout -q main }
        } finally { Pop-Location }
    }
    # Defensive: even on the existing-clone update path, scrub a bad
    # core.worktree that an older bootstrap may have left in config.
    Push-Location $MiosRepoDir
    try {
        $existingWt = & git config --get core.worktree 2>$null
        if ($existingWt -and ($existingWt -match '^[A-Za-z]:[\\/]')) {
            Log-Warn "Scrubbing stale Windows-shaped core.worktree '$existingWt' from $MiosRepoDir\.git\config"
            $null = Invoke-NativeQuiet { git config --unset core.worktree }
        }
    } finally { Pop-Location }
    Log-Ok (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_git_overlaid' -Default "mios.git overlaid at $MiosRepoDir")

    # ── Step 2: mios-bootstrap.git in shadow checkout, files overlaid ──────
    if (Test-Path (Join-Path $MiosBootstrapShadow ".git")) {
        Set-Step "Updating mios-bootstrap.git shadow (fetch + hard reset)"
        Push-Location $MiosBootstrapShadow
        try {
            $null = Invoke-NativeQuiet { git remote set-url origin $MiosBootstrapUrl }
            $fetchExit = Invoke-NativeQuiet { git fetch --depth=1 origin main }
            if ($fetchExit -eq 0) {
                $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                if ($resetExit -ne 0) { Log-Warn "mios-bootstrap.git: git reset --hard returned $resetExit" }
            } else {
                Log-Warn "mios-bootstrap.git: git fetch returned $fetchExit -- shadow may be stale"
            }
        } finally { Pop-Location }
    } else {
        if (-not (Test-Path $MiosBootstrapShadow)) {
            New-Item -ItemType Directory -Path $MiosBootstrapShadow -Force | Out-Null
        }
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_bootstrap_clone' -Default "Cloning mios-bootstrap.git -> shadow $MiosBootstrapShadow")
        $cloneExit = Invoke-NativeQuiet { git clone --depth 1 $MiosBootstrapUrl $MiosBootstrapShadow }
        if ($cloneExit -ne 0) {
            throw "mios-bootstrap.git: clone from $MiosBootstrapUrl failed (exit $cloneExit)"
        }
    }

    # Overlay mios-bootstrap files onto $MiosRepoDir (M:\) -- excluding .git
    # so we don't clobber mios.git's .git dir at M:\.
    Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_bootstrap_overlay' -Default "Overlaying mios-bootstrap files onto $MiosRepoDir")
    $robocopyExit = Invoke-NativeQuiet {
        robocopy $MiosBootstrapShadow $MiosRepoDir `
            /E /XD .git /NJH /NJS /NFL /NDL /NP
    }
    # robocopy exit codes 0-7 = success; 8+ = error
    if ($robocopyExit -ge 8) {
        Log-Warn "mios-bootstrap overlay: robocopy exit $robocopyExit (>=8 means error)"
    }
    Log-Ok "mios-bootstrap files overlaid at $MiosRepoDir (shadow at $MiosBootstrapShadow)"

    # Drop a VERSION marker at the Windows install dir so external tools
    # (and the uninstaller) can identify the installed release without
    # a git query.
    Set-Content -Path (Join-Path $MiosInstallDir "VERSION") -Value $MiosVersion -Encoding ASCII -Force

    # Stage entry-point scripts under $MiosBinDir for Start Menu shortcuts /
    # PATH integration that target a stable non-git location. Files come
    # from M:\ (overlay) since both repos' contents are now there.
    foreach ($script in @("Get-MiOS.ps1","build-mios.ps1","build-mios.sh","bootstrap.ps1","bootstrap.sh")) {
        $srcFile = Join-Path $MiosRepoDir $script
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $MiosBinDir $script) -Force
        }
    }
    Log-Ok (Get-MiosTomlValue -Section 'messages.steps' -Key 'entry_scripts_staged' -Default "Entry scripts staged at $MiosBinDir")
    End-Phase 2

    # ── Phase 3 -- MiOS-DEV distro (formerly MiOS-BUILDER) ───────────────────
    Start-Phase 3
    $machineRunning = $false
    # Check via Podman API first (covers rootful machine-os distros inaccessible via wsl.exe).
    # Accept BOTH the canonical "MiOS-DEV" and the legacy "MiOS-BUILDER" names so existing
    # installs don't get redundantly recreated. If only the legacy name is found we adopt it
    # in-place by re-pointing $BuilderDistro -- the operator can `podman machine rm` and
    # re-run for the canonical name.
    try {
        $names = @($DevDistro, $LegacyDevName)
        foreach ($n in $names) {
            # `(?i)` = case-insensitive. Different podman versions print
            # the Running column as `true`/`false` (lowercase) or
            # `True`/`False` (capitalized); the previous regex was
            # case-sensitive on `true` and silently missed running
            # machines on capitalized-output builds, leading the script
            # to fall through into init and then hit "vm already exists".
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "(?i)^$([regex]::Escape($n))\s+true" }
            if ($ml) {
                if ($n -eq $LegacyDevName) {
                    Log-Warn "Detected legacy machine '$LegacyDevName' -- reusing in place. Rename: 'podman machine rm $LegacyDevName' then re-run."
                    $script:BuilderDistro = $n
                }
                $machineRunning = $true
                break
            }
        }
    } catch {}
    # Also accept a stopped machine and start it. The pattern is
    # case-insensitive so podman builds that print `True`/`False`
    # don't slip past as "no entry" and fall into init (which then
    # crashes on "vm already exists").
    if (-not $machineRunning) {
        try {
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "(?i)^$([regex]::Escape($BuilderDistro))\s" }
            if ($ml) {
                Set-Step "Starting existing $BuilderDistro machine..."
                $startOut = @(& podman machine start $BuilderDistro 2>&1)
                $startOut | ForEach-Object { Write-Log "podman-start: $_" }
                $startJoined = ($startOut -join " ")
                if ($LASTEXITCODE -eq 0) {
                    $machineRunning = $true; Log-Ok "$BuilderDistro started"
                } elseif ($startJoined -match '(?i)already running') {
                    # Non-zero exit + 'already running' message: machine
                    # IS running, podman is just being noisy. Treat as OK.
                    $machineRunning = $true
                    Log-Ok "$BuilderDistro already running (podman reported the state non-fatally)"
                } elseif ($startJoined -match "(?i)DISTRO_NOT_FOUND|bootstrap script failed|WSL_E_DISTRO") {
                    # Stale Podman machine metadata -- WSL distro was deleted but Podman registry entry remains.
                    # Force-remove the stale entry so New-BuilderDistro can re-init cleanly.
                    Write-Log "podman-start: stale machine registration detected -- removing $BuilderDistro" "WARN"
                    & podman machine rm --force $BuilderDistro 2>&1 | ForEach-Object { Write-Log "podman-rm: $_" }
                } else {
                    # Generic start failure -- registration exists but won't start.
                    # Force-remove so the subsequent New-BuilderDistro init has a
                    # clean slate. This catches cases where the previous run was
                    # SIGINT'd mid-init and left the machine in an unstartable
                    # half-provisioned state. podman machine rm with --force is
                    # destructive of THE BUILD VM only -- no MiOS image / no
                    # operator data lives there yet at Phase 3, so this is
                    # always safe at this point in the pipeline.
                    Log-Warn "podman machine start $BuilderDistro failed -- force-removing stale registration so init can re-create it"
                    & podman machine rm --force $BuilderDistro 2>&1 | ForEach-Object { Write-Log "podman-rm: $_" }
                }
            }
        } catch {}
    }
    # Legacy: accept wsl.exe-accessible distro too ('MiOS' already applied)
    if (-not $machineRunning) {
        try {
            $r = (& wsl.exe -d $BuilderDistro --exec bash -c "echo ok" 2>$null) -join ""
            if ($r.Trim() -eq "ok") { $machineRunning = $true }
        } catch {}
    }

    if ($machineRunning) {
        Log-Ok "$BuilderDistro already running"
    } else {
        # Belt-and-braces sweep: even if NONE of the three detection
        # paths above (Running probe, Stopped+start probe, wsl.exe
        # legacy probe) flagged the machine as live, podman may still
        # have a registration on disk for $BuilderDistro from a prior
        # SIGINT'd / aborted run. Hitting `podman machine init` on an
        # existing registration produces:
        #     Error: vm "MiOS-DEV" already exists on hypervisor
        # which the dashboard surfaces as a Phase 3 FATAL with no
        # recovery path that the operator can act on.
        #
        # Pre-purge: ask `podman machine ls` (any state, any case) for
        # the registration. If it exists we KNOW the previous detection
        # paths considered it not-startable, otherwise $machineRunning
        # would already be $true. Force-remove so init has a clean
        # slate. Safe at Phase 3: no MiOS image / operator data lives
        # in the dev VM yet, and the rebuild is what the operator
        # signed up for by re-running the bootstrap.
        try {
            $registered = (& podman machine ls --format "{{.Name}}" 2>$null) |
                          Where-Object { $_ -match "(?i)^$([regex]::Escape($BuilderDistro))\s*$" }
            if ($registered) {
                Log-Warn "Stale $BuilderDistro registration detected (not running, not startable) -- force-removing before re-init"
                & podman machine rm --force $BuilderDistro 2>&1 | ForEach-Object { Write-Log "podman-rm-prepurge: $_" }
            }
            # Even if podman-machine has NO registration, the underlying
            # WSL distro side can still hold a leftover registration --
            # especially after `podman machine rm` succeeded but the
            # WSL distro unregister step failed (or was never reached
            # by an interrupted run). The init then explodes with:
            #     Error: vm "MiOS-DEV" already exists on hypervisor
            # because the WSL-side hypervisor already has the distro.
            # Sweep both candidate names: the canonical "podman-MiOS-DEV"
            # that podman init creates, and the bare "MiOS-DEV" that the
            # rename step (Rename-PodmanDevDistro) produces.
            $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" |
                       ForEach-Object { ($_ -replace [char]0,'').Trim() } |
                       Where-Object { $_ }
            foreach ($cand in @("podman-$BuilderDistro", $BuilderDistro)) {
                if ($wslList -contains $cand) {
                    Log-Warn "Stale WSL distro '$cand' detected -- unregistering before init"
                    & wsl.exe --unregister $cand 2>&1 | ForEach-Object { Write-Log "wsl-unregister: $_" }
                }
            }
        } catch {}
        New-BuilderDistro -HW $HW
    }

    # Invoke-MiosOverlaySeed is deliberately NOT called anymore.
    # It was the legacy PACKAGES.md fenced-block parser that ran
    # `dnf5 install` per ```packages-*``` block. As of 2026-05-05 the
    # SSOT is mios.toml `[packages.<section>].pkgs` (resolved via
    # automation/lib/packages.sh), and PACKAGES.md was relegated to
    # docs at usr/share/doc/mios/reference/PACKAGES.md. The legacy
    # function's path check now warns "overlay seed skipped" on every
    # run because it looks at the moved path -- pure noise that
    # confused the operator's "ignition failed" reading on 2026-05-06.
    # Removed from the call chain. The function body itself is left
    # in place under a deprecation guard so any stale external caller
    # still loads cleanly; bare invocation is now a no-op.
    #
    # The actual overlay work happens below in Invoke-MiosQuadletOverlay,
    # which `git fetch + reset --hard FETCH_HEAD`s mios.git to / inside
    # MiOS-DEV (the canonical "/ IS the git working tree" surface).

    # Quadlet/systemd overlay -- mounts mios.git into MiOS-DEV's / via
    # `git fetch + reset --hard`, enables sysusers/tmpfiles, runs the
    # canonical fetcher set (fonts, oh-my-posh, ollama). Heavy services
    # (mios-ai, mios-forgejo-runner) are opt-in via MIOS_DEV_ENABLE_AI=1
    # / MIOS_DEV_ENABLE_RUNNER=1. Idempotent via
    # /var/lib/mios/.quadlet-overlay-seeded sentinel.
    Invoke-MiosQuadletOverlay

    # Layer MiOS build essentials onto MiOS-DEV.
    #
    # Per feedback_mios_dev_equals_mios.md: the dev VM is MiOS in full
    # parity. machine-os 6+ is the LOCKED base (per operator), but it
    # ships stripped down -- no mkpasswd, no openssl, no passlib, no
    # bootc -- so MiOS content has to LAYER ON TOP at provisioning time
    # (NOT at runtime inside the driver, which would paper over broken
    # provisioning). Install the minimum the build pipeline needs so the
    # driver can assume "everything MiOS has" is present when it starts.
    #
    # Full feature parity (every package, container, flatpak, model)
    # still happens via `bootc switch localhost/mios:latest + reboot`
    # at the end of mios-build-driver -- this step is just the seed for
    # the build to RUN.
    $_wslDistroForTerm = "podman-$BuilderDistro"
    Set-Step "Layering MiOS build essentials onto $_wslDistroForTerm..."
    # NB: on Fedora 44 the `mkpasswd` binary moved out of `whois` into
    # its own `mkpasswd` package -- include both so the build essentials
    # set is correct on every Fedora vintage the dev VM might run.
    #
    # iptables/nftables: machine-os 6+ ships without a firewall backend,
    # which makes podman's netavark networking refuse to set up the
    # build-container's network ("Must provide a valid firewall backend,
    # got iptables"). Without one, every `podman build` in the dev VM
    # dies at the first RUN step that needs network. Install BOTH so
    # netavark picks whichever is preferred on a given Fedora vintage.
    #
    # MUST wrap in EAP=Continue + PSNativeCommandUseErrorActionPreference=$false:
    # dnf emits "Failed to set locale, defaulting to C.UTF-8" to stderr
    # (a harmless warning when LANG isn't set in the WSL distro), and
    # also "Transaction failed:" lines for non-critical post-scriptlet
    # errors (e.g. whois symlink-creation, which doesn't actually break
    # the install). Under PS 7.4+ defaults (EAP=Stop +
    # PSNativeCommandUseErrorActionPreference=$true), either of those
    # throws straight to the outer FATAL handler. The actual install
    # success is checked via $LASTEXITCODE below.
    # SSOT: dev VM essentials list comes from the layered mios.toml
    # chain. Per operator: Epiphany configurator HTML edits flow
    # through to every consumer.
    #
    # Layered resolution (highest → lowest precedence):
    #   1. M:\etc\mios\mios.toml          -- HOST overlay (Epiphany
    #                                        configurator's save target;
    #                                        visible from Windows AND
    #                                        from MiOS-DEV via /mnt/m/)
    #   2. M:\usr\share\mios\mios.toml    -- VENDOR copy from mios.git
    # First layer with a non-empty [packages.dev_vm_essentials] wins.
    $devVmTomlCands = @(
        'M:\etc\mios\mios.toml',
        (Join-Path $script:MiosRepoDir 'usr\share\mios\mios.toml'),
        'M:\usr\share\mios\mios.toml'
    )
    $miosEssentials  = ''
    $essentialsSource = ''
    foreach ($p in $devVmTomlCands) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $tomlText = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
            $rx = '(?ms)^\[packages\.dev_vm_essentials\]\s*$.*?^\s*pkgs\s*=\s*\[(?<list>.*?)\]\s*$'
            $m  = [regex]::Match($tomlText, $rx)
            if ($m.Success) {
                # Strip TOML inline comments per line FIRST, then split.
                # PS regex without (?m) makes `$` match end-of-string, which
                # would let `# comment` text bleed across newlines into the
                # next package entry.
                $stripped = ($m.Groups['list'].Value -split "`n" |
                             ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
                $pkgs = @(
                    $stripped -split ',' |
                    ForEach-Object {
                        $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                        if ($s) { $s }
                    }
                )
                if ($pkgs.Count -gt 0) {
                    $miosEssentials  = ($pkgs -join ' ')
                    $essentialsSource = $p
                    Log-Ok "Sourced $($pkgs.Count) dev-VM essentials from $p [packages.dev_vm_essentials]"
                    break
                }
            }
        } catch {
            Log-Warn "Failed to parse $p for [packages.dev_vm_essentials]: $($_.Exception.Message)"
        }
    }
    if (-not $miosEssentials) {
        $miosEssentials = 'mkpasswd whois openssl python3-passlib bootc git iptables nftables fastfetch oh-my-posh bash-completion'
        Log-Warn "Using fallback dev-VM essentials list (mios.toml [packages.dev_vm_essentials] not found / unparseable)"
    }
    $essentialsRc = -1
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "dnf install -y --quiet $miosEssentials" 2>&1 |
            ForEach-Object { Write-Log "mios-essentials: $_" }
        $script:_essentialsRc = $LASTEXITCODE
    }
    # dnf's exit code is unreliable on rootful machine-os: %post / %triggerin
    # scriptlets fail with "Transport endpoint is not connected" because there's
    # no systemd PID 1 to take daemon-reload, and harmless cosmetic ones (e.g.
    # whois-man alternatives symlink) also exit non-zero. Verify by `rpm -q`
    # against the actual package names instead. Note: `iptables` resolves to
    # `iptables-legacy` on Fedora 44; rpm -q on the source name returns
    # "package iptables is not installed" even when the alternatives provider
    # IS installed -- so query the resolved provider too.
    $checkPkgs = ($miosEssentials -split ' ' | Where-Object { $_ } | ForEach-Object { $_ })
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $rpmCmd = "rpm -q --whatprovides $($checkPkgs -join ' ') 2>&1; echo '---'; rpm -q $($checkPkgs -join ' ') 2>&1"
        $script:_rpmCheck = (& wsl.exe -d $_wslDistroForTerm --user root -- bash -c $rpmCmd 2>&1) -join "`n"
    }
    # Count how many of our requested packages have a verified provider on the
    # system. `rpm -q --whatprovides foo` prints lines like "foo-1.2-3.fc44.x86_64"
    # for installed providers, "no package provides foo" for missing.
    $missing = @()
    foreach ($p in $checkPkgs) {
        if ($script:_rpmCheck -notmatch [regex]::Escape("provides $p")) {
            # whatprovides returned a real package; only flag if BOTH queries
            # come up empty.
            if ($script:_rpmCheck -match "package $([regex]::Escape($p)) is not installed" -and
                $script:_rpmCheck -match "no package provides $([regex]::Escape($p))") {
                $missing += $p
            }
        }
    }
    if ($missing.Count -eq 0) {
        Log-Ok "MiOS build essentials layered onto $_wslDistroForTerm ($($checkPkgs.Count) packages verified)"
    } else {
        Log-Warn "MiOS build essentials partial: missing [$($missing -join ', ')] -- driver may fail when it tries to use those"
    }

    # ── Full MiOS OCI image parity at overlay time ──────────────────
    # Operator 2026-05-09: "podman-MiOS-DEV machine doesn't have the
    # full packages list and flatpaks installed at overlay time --
    # ALL sourced from the toml embeds ... podman-MiOS-DEV = full
    # MiOS OCI image(s) parity".  This step iterates
    # [packages.dev_overlay].sections (22 sections by default --
    # base/security/utils/build-toolchain/containers/cockpit/storage/
    # virt/gpu-*/gnome-flatpak-runtime/ai/sbom-tools/self-build/
    # network-discovery/updater/cockpit-plugins-build/k3s-selinux-build/
    # uki) and layers every [packages.<section>].pkgs into the dev VM.
    # Then installs every ref in [desktop].flatpaks.
    #
    # Toggle via mios.toml [bootstrap].dev_overlay_full = false for a
    # minimal overlay (essentials only).  Default = full parity per
    # operator directive.  The trade-off is bootstrap time -- full
    # parity adds 20-40 min of dnf + flatpak network/disk work on
    # first install.  The reward: every layered RPM and flatpak the
    # MiOS OCI image carries is already present in podman-MiOS-DEV
    # without a `bootc switch` reboot.
    $_doFull = $true
    if ($_devOverlayTomlText -or ($miosEssentials -and (Test-Path -LiteralPath ($devVmTomlCands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)))) {
        try {
            $_topPath = $devVmTomlCands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($_topPath) {
                $_topToml = [IO.File]::ReadAllText($_topPath, (New-Object System.Text.UTF8Encoding($false)))
                $_bsM = [regex]::Match($_topToml, '(?ms)^\[bootstrap\]\s*$.*?^\s*dev_overlay_full\s*=\s*(?<v>true|false)\s*$')
                if ($_bsM.Success -and $_bsM.Groups['v'].Value -eq 'false') { $_doFull = $false }
            }
        } catch {}
    }
    if (-not $_doFull) {
        Log-Ok "[packages.dev_overlay] full layer SKIPPED ([bootstrap].dev_overlay_full=false)"
    } else {
        $_devOverlayTomlText2 = $null
        foreach ($p in $devVmTomlCands) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try { $_devOverlayTomlText2 = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false))); break } catch {}
        }
        if ($_devOverlayTomlText2) {
            # Pull section list from [packages.dev_overlay].sections
            $_doSec = [regex]::Match($_devOverlayTomlText2, '(?ms)^\[packages\.dev_overlay\]\s*$.*?^\s*sections\s*=\s*\[(?<arr>.*?)\]\s*$')
            $_allOverlayPkgs = @()
            $_secList = @()
            if ($_doSec.Success) {
                $_secStripped = ($_doSec.Groups['arr'].Value -split "`n" |
                                ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
                $_secList = @($_secStripped -split ',' | ForEach-Object { $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n") } | Where-Object { $_ })
                Log-Ok "[packages.dev_overlay].sections -> $($_secList -join ', ')"
                # Enable repos FIRST so packages from rpmfusion / fedora-workstation
                # resolve. Insert the repos section if it's not already first.
                if ($_secList -notcontains 'repos') { $_secList = @('repos') + $_secList }
                # Process each section. Read [packages.<section>].pkgs.
                # NOTE: build the regex via SINGLE-QUOTED concat so `$`
                # inside the pattern stays a literal `$` for PS-string-eval
                # then resolves to the regex line-end anchor.  The previous
                # double-quoted `"...\$..."` form had PowerShell collapse
                # `\$` to `$` which the regex engine then treated correctly
                # -- BUT the `$` mid-string was being seen as a sub-expr
                # opener by some PS hosts (operator's run hit zero matches
                # on every section), so single-quoted is the safer shape.
                foreach ($_sec in $_secList) {
                    $_rxSec = '(?ms)^\[packages\.' + [regex]::Escape($_sec) + '\]\s*$.*?^\s*pkgs\s*=\s*\[(?<list>.*?)\]\s*$'
                    $_secM  = [regex]::Match($_devOverlayTomlText2, $_rxSec)
                    if (-not $_secM.Success) { continue }
                    $_stripped = ($_secM.Groups['list'].Value -split "`n" |
                                  ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
                    $_secPkgs = @($_stripped -split ',' | ForEach-Object { $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n") } | Where-Object { $_ })
                    if ($_secPkgs.Count -gt 0) {
                        $_allOverlayPkgs += $_secPkgs
                    }
                }
            }
            $_allOverlayPkgs = @($_allOverlayPkgs | Select-Object -Unique)
            if ($_allOverlayPkgs.Count -gt 0) {
                Log-Ok "Layering $($_allOverlayPkgs.Count) packages from [packages.dev_overlay].sections (full MiOS OCI parity, est. 20-40 min)..."
                # Chunk to keep wsl.exe argv under Windows' command-line cap.
                $_chunkSize = 60
                $_chunkN = 0
                $_chunkTotal = [math]::Ceiling($_allOverlayPkgs.Count / $_chunkSize)
                for ($i = 0; $i -lt $_allOverlayPkgs.Count; $i += $_chunkSize) {
                    $_chunkN++
                    $_endIdx = [math]::Min($i + $_chunkSize - 1, $_allOverlayPkgs.Count - 1)
                    $_chunk = $_allOverlayPkgs[$i..$_endIdx]
                    Set-Step ("[overlay] dnf chunk {0}/{1} ({2} pkgs)..." -f $_chunkN, $_chunkTotal, $_chunk.Count)
                    & {
                        $ErrorActionPreference = 'Continue'
                        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                            $PSNativeCommandUseErrorActionPreference = $false
                        }
                        & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "dnf install -y --skip-unavailable --skip-broken --quiet $($_chunk -join ' ')" 2>&1 |
                            ForEach-Object { Write-Log "mios-overlay: $_" }
                    }
                }
                Log-Ok "[packages.dev_overlay] full layer complete ($($_allOverlayPkgs.Count) requested)"
            }
            # Flatpaks from [desktop].flatpaks
            $_fpSec = [regex]::Match($_devOverlayTomlText2, '(?ms)^\[desktop\]\s*$.*?^\s*flatpaks\s*=\s*\[(?<arr>.*?)\]\s*$')
            if ($_fpSec.Success) {
                $_fpStripped = ($_fpSec.Groups['arr'].Value -split "`n" |
                                ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
                $_flatpaks = @($_fpStripped -split ',' | ForEach-Object { $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n") } | Where-Object { $_ })
                if ($_flatpaks.Count -gt 0) {
                    Log-Ok "Installing $($_flatpaks.Count) flatpak refs from [desktop].flatpaks..."
                    # Add flathub remote first (idempotent).
                    & {
                        $ErrorActionPreference = 'Continue'
                        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                            $PSNativeCommandUseErrorActionPreference = $false
                        }
                        & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "command -v flatpak >/dev/null 2>&1 && flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>&1 || echo 'flatpak not installed -- skipping flathub remote'" 2>&1 |
                            ForEach-Object { Write-Log "mios-flatpak: $_" }
                    }
                    # Per-ref install with explicit exit-code check.
                    # Operator 2026-05-09: "NOT AT ALL A MIOS OVERLAY ...
                    # nautilus / epiphany not found".  Previous version
                    # silently succeeded on every flatpak install
                    # regardless of actual outcome (the inner bash used
                    # `command -v flatpak ... && flatpak install ... ||
                    # echo deferred` which always exits 0 because of the
                    # `|| echo`).  Now we run flatpak directly, capture
                    # the exit code, and log Pass / Fail per ref so the
                    # operator can see exactly what made it into the dev
                    # VM.  `rpm -q flatpak` first to gate -- if flatpak
                    # isn't even installed (machine-os 6.0 base ships
                    # without it), skip the whole pass with one warn
                    # instead of N "deferred" lines.
                    $_flatpakInstalled = $false
                    & {
                        $ErrorActionPreference = 'Continue'
                        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                            $PSNativeCommandUseErrorActionPreference = $false
                        }
                        $_probe = & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "command -v flatpak >/dev/null 2>&1 && echo OK || echo MISS" 2>&1
                        if ($_probe -match 'OK') { $script:_flatpakInstalledRef = $true }
                    }
                    if (-not $script:_flatpakInstalledRef) {
                        Log-Warn "flatpak binary not present in $_wslDistroForTerm -- all $($_flatpaks.Count) [desktop].flatpaks deferred to bootc-switch (full MiOS OCI image has flatpak baked in)"
                    } else {
                        $_fpOk = 0; $_fpFail = 0
                        foreach ($_fp in $_flatpaks) {
                            Set-Step ("[overlay] flatpak install {0}..." -f $_fp)
                            $_fpRc = -1
                            & {
                                $ErrorActionPreference = 'Continue'
                                if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                    $PSNativeCommandUseErrorActionPreference = $false
                                }
                                & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "flatpak install -y --noninteractive --or-update flathub $_fp" 2>&1 |
                                    ForEach-Object { Write-Log "mios-flatpak: $_" }
                                $script:_fpLastRc = $LASTEXITCODE
                            }
                            if ($script:_fpLastRc -eq 0) {
                                Log-Ok "[overlay] flatpak install OK: $_fp"
                                $_fpOk++
                            } else {
                                Log-Warn "[overlay] flatpak install FAILED (exit $($script:_fpLastRc)): $_fp"
                                $_fpFail++
                            }
                        }
                        Log-Ok "[desktop].flatpaks install pass: $_fpOk OK / $_fpFail failed (of $($_flatpaks.Count) total)"
                    }
                }
            }
        }
    }

    # Disable netavark's firewall management. WSL2's kernel doesn't ship
    # the iptables/nf_tables netfilter modules that netavark expects, so
    # even with the iptables BINARY present (whois package above) the
    # build container's network setup fails with:
    #   "setup network: netavark: Must provide a valid firewall backend"
    # The build doesn't need iptables-managed isolation -- it just needs
    # outbound network for package pulls. firewall_driver=none tells
    # netavark to skip firewall rule installation; the bridge interface
    # still works for outbound traffic via WSL2's normal NAT.
    Set-Step "Configuring podman netavark for WSL2 (firewall_driver=none)..."
    $netavarkConf = @'
[network]
firewall_driver = "none"
'@
    $confDropIn = "/etc/containers/containers.conf.d/mios-wsl2.conf"
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        # Use a here-doc piped through wsl so we don't have to escape
        # the [section] brackets through bash -c.
        $netavarkConf | & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "mkdir -p /etc/containers/containers.conf.d && cat > $confDropIn" 2>&1 |
            ForEach-Object { Write-Log "netavark-conf: $_" }
        $script:_netavarkRc = $LASTEXITCODE
    }
    if ($script:_netavarkRc -eq 0) {
        Log-Ok "netavark configured for WSL2 (firewall_driver=none in $confDropIn)"
    } else {
        Log-Warn "Failed to write netavark drop-in (exit $($script:_netavarkRc)) -- podman build may fail at first network step"
    }

    # ── MiOS terminal experience seed inside dev VM ──────────────────
    # Symlink /usr/libexec/mios + /usr/share/mios to the M:\ overlay
    # (mios.git's working tree visible at /mnt/m/ via WSL automount)
    # so mios.git's existing /etc/profile.d/mios-*.sh scripts can find
    # /usr/libexec/mios/mios-dashboard.sh + /usr/share/mios/oh-my-posh/
    # at the canonical paths -- without doing a heavy file-by-file
    # copy. After bootc switch at end-of-build, the OCI image's real
    # /usr/{libexec,share}/mios ride on top via composefs and the
    # symlinks become irrelevant.
    #
    # Drop a single bridge in /etc/profile.d/ that sources mios.git's
    # profile.d scripts FROM /mnt/m/ on every interactive login. Auto-
    # disables once /usr/share/mios is real (post-bootc-switch).
    Set-Step "Seeding MiOS terminal experience inside $_wslDistroForTerm..."
    $miosSeedScript = @'
set -e
# Symlink the canonical MiOS dirs to the M:\ overlay so existing
# profile.d scripts (mios-prompt.sh, zz-mios-motd.sh) resolve their
# dependencies. -e check skips re-symlinking if the path is already
# real (post-bootc-switch state).
if [ -d /mnt/m/usr/libexec/mios ] && [ ! -e /usr/libexec/mios ]; then
    ln -snf /mnt/m/usr/libexec/mios /usr/libexec/mios
fi
if [ -d /mnt/m/usr/share/mios ] && [ ! -e /usr/share/mios ]; then
    ln -snf /mnt/m/usr/share/mios /usr/share/mios
fi
# ── Ensure the `mios` user exists (idempotent) ────────────────────────
# Per operator 2026-05-08 (`getpwnam(mios) failed 17 / User not found`):
# in BootstrapOnly mode, the OCI build's quadlet-overlay step (which
# runs systemd-sysusers and creates uid 1000=mios) is DEFERRED and
# never executes. Without the mios user, /etc/wsl.conf default=mios
# fails on the next `wsl -d podman-MiOS-DEV` invocation (the prior
# behaviour log message "[Phase 3] -- next entry uses mios as default"
# was a lie -- the user didn't exist yet). Create it here so every
# verb that enters the dev distro (mios dev, mios-dev.lnk, the
# mios-launch.ps1 -Verb dev path) lands as a real user.
if ! id mios >/dev/null 2>&1; then
    set +e
    useradd -m -s /bin/bash -G wheel mios 2>/dev/null || \
        useradd -m -s /bin/bash mios 2>/dev/null
    _useradd_rc=$?
    set -e
    if id mios >/dev/null 2>&1; then
        # Set a known password so Cockpit PAM and operator-typed sudo
        # prompts work. Operator can change it any time inside the dev
        # VM with `passwd`. The MiOS canonical default is `mios`.
        echo 'mios:mios' | chpasswd 2>/dev/null || true
        # Passwordless sudo for mios so build-mios.ps1's later steps
        # (smoke test, container-host setup) don't prompt.
        if [ -d /etc/sudoers.d ]; then
            printf 'mios ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/10-mios-nopasswd
            chmod 0440 /etc/sudoers.d/10-mios-nopasswd
        fi
        echo "[mios-seed] mios user created (uid=$(id -u mios), groups=$(id -Gn mios))"
    else
        echo "[mios-seed] WARN: useradd mios failed (rc=$_useradd_rc) -- wsl.conf default=mios will fail until the user exists"
    fi
fi
# ── /etc/wsl.conf [user].default=mios ─────────────────────────────────
# So `wsl -d podman-MiOS-DEV` (no --user flag) and `wsl -d MiOS-DEV`
# both land in the mios user shell. Only write if mios user actually
# exists -- writing default=<missing-user> bricks the distro entry.
if id mios >/dev/null 2>&1; then
    if [ ! -f /etc/wsl.conf ]; then
        printf '[user]\ndefault=mios\n' > /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf created with [user].default=mios"
    elif ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
        printf '\n[user]\ndefault=mios\n' >> /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf: appended [user].default=mios"
    elif ! grep -qE '^[[:space:]]*default[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
        sed -i '/^\[user\]/a default=mios' /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf: inserted default=mios under existing [user]"
    elif ! grep -qE '^[[:space:]]*default[[:space:]]*=[[:space:]]*mios[[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
        sed -i 's|^[[:space:]]*default[[:space:]]*=.*|default=mios|' /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf: rewrote default=<other> to default=mios"
    else
        echo "[mios-seed] /etc/wsl.conf: default=mios already set"
    fi
fi
# Pre-bootc bridge: source mios.git profile.d scripts from /mnt/m/ on
# every interactive bash login, IF the canonical /etc/profile.d/mios-*
# scripts aren't installed yet (pre-bootc-switch). After bootc switch,
# the canonical scripts exist and this bridge skips silently.
mkdir -p /etc/profile.d
cat > /etc/profile.d/00-mios-pre-bootc.sh <<'EOPROFILE'
# /etc/profile.d/00-mios-pre-bootc.sh
# Pre-bootc-switch MiOS terminal-experience bridge.
# Sources mios.git's profile.d scripts from /mnt/m/ until the OCI
# image's bootc-switch lands them at the canonical /etc/profile.d/.
# Auto-disables once /etc/profile.d/mios-prompt.sh exists at root.
if [ ! -e /etc/profile.d/mios-prompt.sh ] && [ -d /mnt/m/etc/profile.d ]; then
    for _miosf in /mnt/m/etc/profile.d/mios-*.sh /mnt/m/etc/profile.d/zz-mios-*.sh; do
        [ -r "$_miosf" ] && . "$_miosf"
    done
    unset _miosf
fi
EOPROFILE
chmod 0644 /etc/profile.d/00-mios-pre-bootc.sh
echo "[mios-seed] symlinks + pre-bootc bridge installed"
'@
    # Write the seed script to a tempfile on M:\ (visible inside the dev
    # VM at /mnt/m/) and invoke bash on the path. Piping the script to
    # `bash` via PowerShell stdin gets CRLF-mangled -- bash sees `set -\r`
    # and aborts with "set: -: invalid option" on line 1, killing the
    # whole script before any work runs (operator log: "bash: line 1:
    # set: -: invalid option ... syntax error: unexpected end of file
    # from `if' command on line 9").
    $seedTmpWin = Join-Path $env:TEMP 'mios-seed.sh'
    $seedTmpWsl = '/mnt/m/MiOS/.tmp-seed.sh'
    # Write LF-only via [System.IO.File]::WriteAllText with no-BOM UTF-8;
    # also drop a copy at /mnt/m/MiOS/.tmp-seed.sh so bash inside the
    # dev VM has a known automounted path.
    $utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
    $miosSeedLF   = $miosSeedScript -replace "`r`n", "`n"
    $miosTmpDir   = 'M:\MiOS'
    if (-not (Test-Path -LiteralPath $miosTmpDir)) { New-Item -ItemType Directory -Path $miosTmpDir -Force | Out-Null }
    [System.IO.File]::WriteAllText('M:\MiOS\.tmp-seed.sh', $miosSeedLF, $utf8NoBom)
    [System.IO.File]::WriteAllText($seedTmpWin,            $miosSeedLF, $utf8NoBom)
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        & wsl.exe -d $_wslDistroForTerm --user root -- bash $seedTmpWsl 2>&1 |
            ForEach-Object { Write-Log "mios-seed: $_" }
        $script:_seedRc = $LASTEXITCODE
    }
    Remove-Item -LiteralPath 'M:\MiOS\.tmp-seed.sh' -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $seedTmpWin -Force -ErrorAction SilentlyContinue
    if ($script:_seedRc -eq 0) {
        Log-Ok "MiOS terminal experience seeded onto $_wslDistroForTerm"
    } else {
        Log-Warn "MiOS terminal experience seed failed (exit $($script:_seedRc)) -- bare bash login until bootc switch"
    }

    # The overlay seed wrote /etc/wsl.conf [user] default=mios so future
    # `wsl -d podman-MiOS-DEV` invocations land in the mios user (not the
    # bundled `user` UID 1000). But /etc/wsl.conf is read at distro
    # START -- the live instance running RIGHT NOW was launched with the
    # pre-seed config and still defaults to `user`. Terminate the distro
    # so the next entry (menu option 1 or 5) re-launches with the new
    # default user. Idempotent: if the distro isn't running, --terminate
    # is a no-op.
    Set-Step "Terminating $_wslDistroForTerm so /etc/wsl.conf takes effect on next entry..."
    & wsl.exe --terminate $_wslDistroForTerm 2>&1 |
        ForEach-Object { Write-Log "wsl-terminate: $_" }
    Log-Ok "$_wslDistroForTerm terminated -- next entry uses mios as default user"

    End-Phase 3

    # ── Phase 4 -- WSL2 .wslconfig ───────────────────────────────────────────
    Start-Phase 4
    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"

    # Required keys -- always ensure these are present regardless of existing config.
    # Mirrored networking + localhostForwarding are essential for Cockpit (port 9090)
    # and general WSL2 → Windows host reachability.
    $requiredKeys = [ordered]@{
        memory              = "$($HW.RamGB)GB"
        processors          = "$($HW.Cpus)"
        swap                = "4GB"
        localhostForwarding = "true"
        networkingMode      = "mirrored"
        guiApplications     = "true"
    }

    $cfgRaw = if (Test-Path $wslCfg) { Get-Content $wslCfg -Raw } else { "" }

    if ($cfgRaw -notmatch "\[wsl2\]") {
        # No [wsl2] section at all -- append one wholesale
        $block = "`n[wsl2]`n# MiOS-managed -- host resources for MiOS-DEV`n"
        foreach ($kv in $requiredKeys.GetEnumerator()) { $block += "$($kv.Key)=$($kv.Value)`n" }
        Add-Content -Path $wslCfg -Value $block
        Log-Ok ".wslconfig: wrote [wsl2] -- $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    } else {
        # [wsl2] exists -- patch each required key in place; append missing ones
        $lines    = (Get-Content $wslCfg)
        $inWsl2   = $false
        $patched  = [System.Collections.Generic.List[string]]::new()
        $inserted = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($line in $lines) {
            if ($line -match "^\[wsl2\]") { $inWsl2 = $true }
            elseif ($line -match "^\[")   { $inWsl2 = $false }

            if ($inWsl2 -and $line -match "^(\w+)\s*=") {
                $key = $Matches[1]
                if ($requiredKeys.Contains($key)) {
                    $patched.Add("$key=$($requiredKeys[$key])")
                    $null = $inserted.Add($key)
                    continue
                }
            }
            $patched.Add($line)

            # After [wsl2] header, inject any keys not yet seen in the section
            if ($line -match "^\[wsl2\]") {
                foreach ($kv in $requiredKeys.GetEnumerator()) {
                    if (-not $inserted.Contains($kv.Key)) {
                        # We will add them below after scanning the full section;
                        # set a sentinel so the post-loop block fires once.
                    }
                }
            }
        }

        # Append any required keys that never appeared in [wsl2]
        $missing = $requiredKeys.Keys | Where-Object { -not $inserted.Contains($_) }
        if ($missing) {
            # Find insertion point: after [wsl2] header line
            $insertIdx = ($patched | Select-String -Pattern "^\[wsl2\]" | Select-Object -First 1).LineNumber
            $offset = 0
            foreach ($key in $missing) {
                $patched.Insert($insertIdx + $offset, "$key=$($requiredKeys[$key])")
                $offset++
            }
        }

        Set-Content -Path $wslCfg -Value $patched -Encoding UTF8
        Log-Ok ".wslconfig: merged [wsl2] -- $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    }
    End-Phase 4

    # ── Phase 5 -- Verify Windows build context ──────────────────────────────
    # Build runs via 'podman build' from the Windows clone -- no machine exec needed.
    Start-Phase 5
    # mios.git is overlaid AT $MiosRepoDir root, per 2026-05-06.
    $repoPath = $MiosRepoDir
    if (Test-Path (Join-Path $repoPath "Containerfile")) {
        Log-Ok "Build context ready at $repoPath"
    } else {
        throw "mios.git Containerfile missing at $repoPath -- re-run without -BuildOnly to reclone"
    }
    End-Phase 5

    # ── Bootstrap finalize: smoke test -> Windows install -> launcher ───────
    # The auto-rename (podman-MiOS-DEV -> MiOS-DEV) is OFF by default
    # because podman's WSLDistroName() hardcodes the `podman-` prefix
    # -- a renamed distro breaks every `podman machine start/init/ssh`
    # with WSL_E_DISTRO_NOT_FOUND. User-facing surfaces (dashboard,
    # mios-dev launcher, icons, app menu) already hide the prefix, so
    # operators see "MiOS-DEV" everywhere they look while the actual
    # WSL distro stays as "podman-MiOS-DEV" for podman's sake. Set
    # $env:MIOS_RENAME_DISTRO=1 to opt in.
    Restore-PodmanPrefix   # auto-recover from any previous rename
    Install-MiosWindowsTools   # winget install [packages.windows] (fastfetch, btop, pwsh, ...)
    Install-WindowsBranding

    $devHealthy = Test-MiosDevDistroHealthy
    if ($devHealthy -and ($env:MIOS_RENAME_DISTRO -in @('1','true','TRUE','yes'))) {
        Rename-PodmanDevDistro
    }

    Install-MiosLauncher

    # ── -BootstrapOnly: exit cleanly here ─────────────────────────────────────
    # The curl/iex entry path stops here. The operator now has:
    #   * MiOS-DEV WSL2 distro (renamed, podman-managed, overlay applied)
    #   * Windows-side oh-my-posh / Geist / Nerd Font / theme installed
    #   * MiOS install root on M:\MiOS\ (or fallback) with bin/icons/themes
    #   * Desktop + Start Menu shortcuts including "Build MiOS"
    # They can now click "Build MiOS" to drive the OCI image build (which
    # re-runs this script with -BuildOnly).
    if ($BootstrapOnly) {
        Log-Ok "-BootstrapOnly mode: dev VM provisioned, Windows install complete."
        # Hard gate the script-level auto-chain at line ~6915. The
        # `return` below exits this function but the script-level
        # epilogue still fires the auto-chain unless we set the env
        # sentinel here. Per feedback_mios_bootstrap_stops_at_dev_ready:
        # bootstrap MUST stop at the hint banner; build is operator-
        # triggered via `mios build`.
        $env:MIOS_NO_AUTO_CHAIN = '1'
        # ── Operator-facing end-of-Pass-2 summary ────────────────────
        # The bootstrap STOPS here. The operator decides when to fire
        # the build pipeline by typing `mios build` (or clicking the
        # MiOS Build shortcut). Per
        # feedback_mios_bootstrap_stops_at_mios_dev_ready memory: the
        # Windows entry installs everything UP TO MiOS-DEV being a
        # native app, then prints hint lines and returns. No auto-chain.
        $_dispGb = 256
        try { $v = Get-Volume -DriveLetter M -ErrorAction SilentlyContinue; if ($v) { $_dispGb = [math]::Round($v.Size/1GB,0) } } catch {}
        # Banner title + bullet list resolve through mios.toml
        # [messages.install_complete] (SSOT). Operator edits via mios.html
        # for any custom branding text. Vendor fallback below is the cold
        # first-run set when no TOML is reachable.
        $_completeTitle = Get-MiosTomlValue -Section 'messages.install_complete' -Key 'title' -Default 'MiOS Windows-side install complete'
        $_completeBullets = @(Get-MiosTomlValue -Section 'messages.install_complete' -Key 'bullets' -Default @(
            ('M:\ partition ({0} GB NTFS, label MIOS-DEV)' -f $_dispGb),
            'Podman Desktop + podman-MiOS-DEV machine',
            'mios.git + mios-bootstrap overlaid at M:\',
            'MiOS terminal essentials layered into MiOS-DEV',
            'Native Windows app: Start Menu + Desktop + per-verb shortcuts',
            'MiOS PowerShell profile (oh-my-posh, dashboard, mios <verb>)'
        ))
        # Substitute {disk_gb} placeholder if the operator templated it
        # in a custom mios.toml entry.
        $_completeBullets = @($_completeBullets | ForEach-Object { $_ -replace '\{disk_gb\}', $_dispGb })
        # Frame chars come from mios.toml [branding.dashboard].frame_chars
        # so the install-complete banner matches every other framed surface
        # (Show-MiosDashboard, mios-dashboard.sh, agreement gate, etc.).
        # Per operator 2026-05-09: "headers and dashboards and framing/
        # piping are all scattered and not fitting because they aren't
        # TRULY based off the toml code as source for everything".
        # Vendor default '╭─╮│╰╯' if mios.toml is unreachable.
        $_fc = Get-MiosTomlValue -Section 'branding.dashboard' -Key 'frame_chars' -Default '╭─╮│╰╯'
        if (-not $_fc -or $_fc.Length -lt 6) { $_fc = '╭─╮│╰╯' }
        $_TL = $_fc[0]; $_TH = $_fc[1]; $_TR = $_fc[2]
        $_TV = $_fc[3]; $_BL = $_fc[4]; $_BR = $_fc[5]
        # Frame width comes from the SAME Get-MiosFrameWidth helper that
        # drives every other framed surface in this script -- one
        # formula, one source.  Subtract 2 for the 2-cell left-indent
        # the install-complete banner uses ('  ╭...╯').
        $_inner = (Get-MiosFrameWidth) - 2
        if ($_inner -lt 40) { $_inner = 40 }
        $_titlePadded = '  ' + $_TV + ' ' + $_completeTitle.PadRight($_inner - 1) + ' ' + $_TV
        Write-Host ''
        Write-Host ('  ' + $_TL + ([string]$_TH * $_inner) + $_TR) -ForegroundColor DarkCyan
        Write-Host $_titlePadded -ForegroundColor Cyan
        Write-Host ('  ' + $_BL + ([string]$_TH * $_inner) + $_BR) -ForegroundColor DarkCyan
        Write-Host ''
        # Section labels resolve through mios.toml [messages.install_complete]
        # (SSOT). Operators rebrand the installer's end-of-flow narrative via
        # mios.html without touching code.
        $_lblInstalled = Get-MiosTomlValue -Section 'messages.install_complete' -Key 'installed_lead' -Default '    Installed ...............................................................'
        $_lblNextSteps = Get-MiosTomlValue -Section 'messages.install_complete' -Key 'next_steps'     -Default "    What's next? Type any of these in the MiOS terminal:"
        Write-Host $_lblInstalled -ForegroundColor DarkGray
        foreach ($_b in $_completeBullets) {
            Write-Host ('      [+] ' + $_b) -ForegroundColor Green
        }
        Write-Host ''
        Write-Host $_lblNextSteps -ForegroundColor White
        # Verb list resolves through mios.toml [verbs] (SSOT). Operator
        # edits mios.html -> mios.toml -> this banner regenerates on the
        # next install. No hardcoded verb names. Per operator: "toml is
        # the SSOT for code too!!! no hardcoding ANYWHERE!!!"
        $_verbHints = @(
            @{ name = 'build';  desc = 'open mios.html, save, then build the OCI image' },
            @{ name = 'config'; desc = 'edit mios.toml in the HTML configurator (no build)' },
            @{ name = 'dash';   desc = 'show the MiOS dashboard (framed banner + fastfetch)' },
            @{ name = 'dev';    desc = 'enter the MiOS-DEV podman machine' },
            @{ name = 'pull';   desc = 'sync M:\ overlay to origin/main' },
            @{ name = 'update'; desc = 're-run the bootstrap (cache-busted)' },
            @{ name = 'help';   desc = 'list every verb' }
        )
        $_tomlText = $null
        foreach ($_cand in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $MiosBootstrapShadow 'mios.toml'))) {
            if (Test-Path -LiteralPath $_cand) { try { $_tomlText = [IO.File]::ReadAllText($_cand, (New-Object System.Text.UTF8Encoding($false))); break } catch {} }
        }
        if ($_tomlText) {
            $_verbsBlock = [regex]::Match($_tomlText, '(?ms)^\[verbs\]\s*\r?\n(.*?)(?=^\[|\z)')
            if ($_verbsBlock.Success) {
                $_resolved = @()
                foreach ($_ln in ($_verbsBlock.Groups[1].Value -split "`n")) {
                    $_m = [regex]::Match($_ln, '^\s*([a-z][a-z0-9_-]*)\s*=\s*\{[^}]*description\s*=\s*"([^"]+)"')
                    if ($_m.Success) {
                        $_resolved += @{ name = $_m.Groups[1].Value; desc = $_m.Groups[2].Value }
                    }
                }
                if ($_resolved.Count -gt 0) { $_verbHints = $_resolved }
            }
        }
        $_maxName = ($_verbHints | ForEach-Object { $_.name.Length } | Measure-Object -Maximum).Maximum
        foreach ($_v in $_verbHints) {
            $_pad = ' ' * ($_maxName - $_v.name.Length + 2)
            Write-Host ("      mios {0}{1}-- {2}" -f $_v.name, $_pad, $_v.desc) -ForegroundColor Cyan
        }
        Write-Host ''
        $_lblHubHint = Get-MiosTomlValue -Section 'messages.install_complete' -Key 'hub_hint' -Default '    The MiOS hub shortcut is in your Start Menu / Desktop / Win+Search.'
        Write-Host $_lblHubHint -ForegroundColor DarkGray
        Write-Host ''
        try { [Console]::Out.Flush() } catch {}
        return
    }

    # Operator can pre-fill mios.toml fields via the HTML page; the
    # Phase-6 prompts that follow then default to whatever was saved.
    # Skipped when -Unattended or MIOS_NO_CONFIGURATOR=1.
    Open-Configurator -RepoDir $MiosRepoDir

    # ── Phase 6 -- Identity ───────────────────────────────────────────────────
    Start-Phase 6
    $script:CurStep = "Waiting for identity input..."
    Show-Dashboard -Force
    # Re-resolve mios.toml [ai] defaults after the configurator step so
    # the prompts seed from whatever the operator saved in the GUI.
    $aiDefaultsPre = Resolve-MiosTomlAiDefaults -RepoDir $MiosRepoDir
    $MiosUser     = Read-Line "Linux username" "mios"
    $MiosHostname = Read-Line "Hostname"       "mios"
    $pwPlain      = Read-Password "Password"
    if ([string]::IsNullOrWhiteSpace($pwPlain)) { $pwPlain = "mios" }
    $MiosHash     = Get-PasswordHash $pwPlain
    # GitHub PAT is required to pull ghcr.io/ublue-os/ucore-hci (GHCR anon bearer token returns 403).
    # Check env first; fall back to prompt so interactive installs work without pre-setting the var.
    $script:GhcrToken = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
                        elseif ($env:GITHUB_TOKEN)   { $env:GITHUB_TOKEN }
                        else { Read-Line "GitHub PAT for ghcr.io base image pull (github.com/settings/tokens)" "" }
    $tokStatus = if ($script:GhcrToken) { "provided (masked)" } else { "none -- anonymous pull (may fail)" }

    # AI model selection (feature parity with build-mios.sh:prompt_model).
    # Defaults seed from the layered mios.toml [ai] section so per-host
    # overrides flow through automatically; Get-Hardware's RAM-driven
    # suggestion is used as the fallback if mios.toml didn't supply one.
    $aiDefaults = Resolve-MiosTomlAiDefaults -RepoDir $MiosRepoDir
    $defaultModel = if ($aiDefaults.Model) { $aiDefaults.Model } else { $HW.AiModel }
    $MiosAiModel       = Read-Model -Default $defaultModel
    $MiosAiEmbedModel  = Read-Line "AI embedding model" $aiDefaults.EmbedModel
    $MiosOllamaBakeModels = "$MiosAiModel,$MiosAiEmbedModel"

    Log-Ok "Identity: user=$MiosUser  host=$MiosHostname  password=(hashed)  ghcr=$tokStatus  ai=$MiosAiModel"
    $script:IdentInfo = "User:$MiosUser  Host:$MiosHostname  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$MiosAiModel"
    End-Phase 6

    # ── Phase 7 -- Write identity ─────────────────────────────────────────────
    Start-Phase 7
    $envContent = @"
MIOS_USER="$MiosUser"
MIOS_HOSTNAME="$MiosHostname"
MIOS_USER_PASSWORD_HASH="$MiosHash"
MIOS_AI_MODEL="$MiosAiModel"
MIOS_AI_EMBED_MODEL="$MiosAiEmbedModel"
MIOS_OLLAMA_BAKE_MODELS="$MiosOllamaBakeModels"
"@.Trim()
    $writeCmd  = "mkdir -p /etc/mios && cat > /etc/mios/install.env && chmod 0640 /etc/mios/install.env"
    $written = $false

    # Try wsl.exe (works when machine runs 'MiOS' after bootc switch).
    # `*>$null` discards stdout AND stderr without funneling stderr to
    # the success pipeline, so $ErrorActionPreference='Stop' can't trip
    # on a chatty native-command stderr line. $LASTEXITCODE is set
    # independently of stream redirection.
    $envContent | & wsl.exe -d $BuilderDistro --user root --exec bash -c $writeCmd *>$null
    if ($LASTEXITCODE -eq 0) { $written = $true }

    # Try the dev-distro shell via Invoke-DistroSh (auto-picks
    # wsl-direct post-rename, podman-machine-ssh pre-rename). Bakes
    # the env content into the script as base64 so we don't need a
    # second stdin channel (Invoke-DistroSh's stdin is already used
    # for the base64-encoded script body).
    if (-not $written) {
        $envB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($envContent))
        $writeBaked = @"
mkdir -p /etc/mios
printf '%s' '$envB64' | base64 -d > /etc/mios/install.env
chmod 0640 /etc/mios/install.env
"@
        Invoke-DistroSh -Bash $writeBaked -MachineName $BuilderDistro *>$null
        if ($LASTEXITCODE -eq 0) { $written = $true }
    }

    # Fallback: write via privileged container that mounts the machine's host filesystem.
    # Rootful machine-os exposes / to privileged containers via -v /:/host.
    if (-not $written) {
        Set-Step "Writing identity via privileged container..."
        $envContent | & podman run --rm -i --privileged --security-opt label=disable `
            -v /:/host:z `
            docker.io/library/alpine:latest `
            sh -c "mkdir -p /host/etc/mios && cat > /host/etc/mios/install.env && chmod 0640 /host/etc/mios/install.env" `
            *>$null
        if ($LASTEXITCODE -eq 0) { $written = $true }
    }

    if ($written) { Log-Ok "/etc/mios/install.env written" } `
    else { Log-Warn "install.env write failed (non-fatal -- firstboot will use default identity; set MIOS_* vars manually)" }
    End-Phase 7

    # ── App registration + Start Menu ─────────────────────────────────────────
    # Phase index varies by mode -- 5 in BootstrapOnly (the trimmed
    # 6-phase Windows-side layout) and 8 in -FullBuild / -BuildOnly
    # (the full 14-phase legacy layout).
    Start-Phase $script:AppRegPhaseId
    $pwsh      = if (Get-Command pwsh -EA SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
    # Entry-point scripts live under $MiosBinDir (materialized in Phase 2).
    # Prefer build-mios.ps1 (current canonical entry); fall back to the
    # legacy install.ps1 redirector if an old install is being re-run.
    $selfSc    = if (Test-Path (Join-Path $MiosBinDir "build-mios.ps1")) {
                     Join-Path $MiosBinDir "build-mios.ps1"
                 } elseif (Test-Path (Join-Path $MiosRepoDir "build-mios.ps1")) {
                     # mios-bootstrap is overlaid at $MiosRepoDir root.
                     Join-Path $MiosRepoDir "build-mios.ps1"
                 } else {
                     Join-Path $MiosBootstrapShadow "install.ps1"
                 }
    $uninstSc  = Join-Path $MiosBinDir "uninstall.ps1"
    $uninstCmd = "$pwsh -ExecutionPolicy Bypass -File `"$uninstSc`""

    if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }
    # DisplayName / Publisher / URLInfoAbout all resolve through mios.toml
    # so operators rebrand the Add/Remove Programs entry via mios.html.
    # Per operator 2026-05-09: "the Applications tag/description when
    # installed 'MiOS - Immutable Fedora AI Workstation' should be
    # defined as My Personal Operating System or similar".
    # Prefer [branding].tagline_app (the explicit Application-tag value);
    # fall back to .tagline; final fallback to the literal default.
    $_arDisplayTagline = Get-MiosTomlValue -Section 'branding' -Key 'tagline_app' -Default (Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'My Personal Operating System')
    $_arPublisher      = Get-MiosTomlValue -Section 'branding' -Key 'publisher' -Default 'MiOS-DEV'
    $_arAboutUrl       = Get-MiosTomlValue -Section 'branding' -Key 'about_url' -Default 'https://github.com/mios-dev/mios'
    @{
        DisplayName="MiOS - $_arDisplayTagline"; DisplayVersion=$MiosVersion
        Publisher=$_arPublisher; InstallLocation=$MiosInstallDir
        UninstallString=$uninstCmd; QuietUninstallString="$uninstCmd -Quiet"
        URLInfoAbout=$_arAboutUrl
        InstallScope=$MiosScope
        NoModify=[int]1; NoRepair=[int]1
    }.GetEnumerator() | ForEach-Object {
        $regType = if ($_.Value -is [int]) { "DWord" } else { "String" }
        Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type $regType
    }

    if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }

    # MiOS Configurator launcher script in the install dir. Calls the
    # in-VM launcher (/usr/libexec/mios/mios-configurator-launch) via
    # `wsl --exec` so the same code path drives both surfaces:
    #   - Windows Start Menu / Desktop "MiOS Configurator.lnk"
    #   - GNOME Dock / Activities entry on a deployed host (mios-
    #     configurator.desktop -> the same launcher)
    # On Windows this opens Epiphany flatpak via WSLg -> the configurator
    # window appears on the Windows desktop.
    $cfgScript = Join-Path $MiosInstallDir 'mios-configurator.ps1'
    @"
#Requires -Version 5.1
# Generated by build-mios.ps1. Launches the MiOS HTML configurator
# inside MiOS-DEV via WSLg. Saved mios.toml lands in the dev VM's
# `~/Downloads/mios.toml` and is auto-promoted as the next build's
# source on the next `irm | iex`.
`$ErrorActionPreference = 'SilentlyContinue'
`$d = '$DevDistro'
# Probe canonical name first (post-rename), then podman- prefix
# (pre-rename), then legacy MiOS-BUILDER fallbacks. First responder wins.
foreach (`$cand in @(`$d, "podman-`$d", '$LegacyDevName', "podman-$LegacyDevName")) {
    `$probe = (& wsl.exe -d `$cand --exec bash -c 'echo ok' 2>`$null) -join ''
    if (`$probe.Trim() -eq 'ok') {
        & wsl.exe -d `$cand --exec /usr/libexec/mios/mios-configurator-launch
        exit `$LASTEXITCODE
    }
}
Write-Host '  MiOS-DEV not reachable -- run bootstrap.ps1 first to provision the dev VM' -ForegroundColor Yellow
exit 1
"@ | Set-Content -Path $cfgScript -Encoding UTF8 -Force

    # MiOS Dev Shell points at the canonical post-rename name first
    # ($DevDistro = "MiOS-DEV"); pre-rename installs still get a usable
    # entry via the launcher's Resolve-MiosDevDistro fallback in
    # mios-dev.ps1 (under $MiosBinDir). The legacy Podman Shell entry
    # was removed -- `podman machine ssh MiOS-DEV` fails post-rename
    # because podman hardcodes the `podman-` prefix in WSLDistroName(),
    # and "MiOS Dev Shell" already covers the same use case.
    # MiOS Terminal / MiOS Dev Shell route through the centering launcher
    # (mios-launch.ps1) so every double-click lands a borderless 80x30
    # acrylic window screen-centered, regardless of last-window position
    # WT might have remembered. -WindowStyle Hidden keeps the wrapper
    # pwsh invisible -- only the WT window appears.
    # Final native-app shortcut set (5 apps total, per operator):
    #   MiOS              the terminal hub (created earlier in
    #                     Install-MiosLauncher line ~5743)
    #   MiOS-DEV          dev VM dashboard (created in verbShortcuts
    #                     loop line ~5904)
    #   MiOS Config       opens mios.html in default browser
    #                     (created in verbShortcuts loop line ~5904)
    #   MiOS Help         verb reference (created in verbShortcuts
    #                     loop line ~5904)
    #   Uninstall MiOS    Add/Remove-style uninstaller (this block)
    #
    # The legacy MiOS Setup / Build MiOS / MiOS Configurator / MiOS
    # Terminal / MiOS Dev Shell shortcuts have been retired -- those
    # verbs are operator-typed inside the MiOS terminal, NOT separate
    # native apps. ('MiOS Configurator' is the legacy long-form name
    # for the new 'MiOS Config' app.)
    @(
        @{ F="Uninstall MiOS.lnk";  T=$pwsh;  A="-ExecutionPolicy Bypass -File `"$uninstSc`"";  D="Remove MiOS (preserves per-user config)" }
    ) | ForEach-Object { New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir }

    # Stale-shortcut cleanup -- if a legacy revision dropped any of
    # these names, remove them so the operator's Start Menu / Desktop
    # match the canonical 5-app set.
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    foreach ($legacy in @('MiOS Setup.lnk','Build MiOS.lnk','MiOS Configurator.lnk','MiOS Terminal.lnk','MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','MiOS Build.lnk','MiOS Dashboard.lnk','MiOS Update.lnk','MiOS Pull.lnk')) {
        foreach ($dir in @($StartMenuDir, $desktopDir)) {
            if (-not $dir) { continue }
            $stale = Join-Path $dir $legacy
            if (Test-Path $stale) {
                try { Remove-Item $stale -Force -ErrorAction SilentlyContinue; Log-Ok "Removed stale shortcut: $stale" } catch {}
            }
        }
    }
    Log-Ok "Add/Remove Programs + Start Menu created (5 native apps: MiOS, MiOS-DEV, MiOS Config, MiOS Help, Uninstall MiOS)"

    # Uninstaller script. Operator-asserted contract 2026-05-08:
    # "EVERY failure will result in an uninstallation!! Plus make sure
    # MiOS uninstaller ACTUALLY removes and cleans everything up after."
    #
    # Goal: every uninstall leaves Windows in EXACTLY the state it was
    # in before MiOS was first installed. The next install starts from
    # zero, no stale state to confuse the next debug iteration.
    #
    # What gets removed (12 artifact categories):
    #   1. Podman machine ($BuilderDistro) -- stop + rm
    #   2. WSL distros -- $BuilderDistro + $MiosWslDistro + every
    #      podman-MiOS-* + MiOS-BUILDER variant (defensive, since the
    #      install pipeline has gone through several distro names)
    #   3. M:\MiOS install dir, M:\ overlay files, M:\ProgramData,
    #      M:\ data dir
    #   4. WT settings.json -- launchMode root key (only if MiOS-set),
    #      profiles.defaults globals (only the keys MiOS writes), MiOS
    #      scheme, MiOS profile, MiOS-DEV profile, podman-MiOS-* auto
    #      profiles
    #   5. PowerShell profile redirector blocks -- both pwsh 7
    #      ($PROFILE.CurrentUserAllHosts) AND WindowsPowerShell 5.1
    #      (~\Documents\WindowsPowerShell\profile.ps1) -- marker-
    #      delimited block removal preserves any operator-added content
    #      outside the markers
    #   6. Fonts -- Geist*.otf/.ttf + Symbols-Only Nerd Font from
    #      %LOCALAPPDATA%\Microsoft\Windows\Fonts + matching HKCU font
    #      registry entries
    #   7. PATH env -- M:\MiOS\bin removed from HKCU + HKLM Path
    #   8. HKCU uninstall reg key
    #   9. Start Menu folder + Desktop .lnk shortcuts (MiOS, MiOS-DEV,
    #      MiOS Config, MiOS Help, Uninstall MiOS, plus stale legacy
    #      names from prior install revisions)
    #  10. AppUserModelID HKCU registrations
    #  11. podman-machine state symlinks (the symlinks to M:\podman from
    #      AppData\Local, .local\share, ProgramData\containers\podman\machine)
    #  12. MIOS_* environment variables (HKCU + HKLM scope)
    #
    # Default preserves $MiosConfigDir (per-user identity / mios.toml
    # operator overrides) so a re-install picks up the operator's
    # last config. -Purge nukes that too for true zero-state uninstall.
    #
    # Non-destructive: never touches C:\MiOS, C:\mios-bootstrap (the
    # operator's source repos), the operator's own pwsh profile content
    # outside the >>> MiOS oh-my-posh init >>> markers, or any non-MiOS
    # WT profiles / schemes / fonts.
    $B = $BuilderDistro
    @"
#Requires -Version 5.1
param([switch]`$Quiet, [switch]`$Purge)
`$ErrorActionPreference = 'SilentlyContinue'
`$I='$($MiosInstallDir-replace"'","''")'
`$P='$($MiosProgramData-replace"'","''")'
`$D='$($MiosDataDir-replace"'","''")'
`$C='$($MiosConfigDir-replace"'","''")'
`$S='$($StartMenuDir-replace"'","''")'
`$K='$($UninstallRegKey-replace"'","''")'
`$B='$B'
`$M='$MiosWslDistro'
`$BIN='$($MiosBinDir-replace"'","''")'
`$DESK = [Environment]::GetFolderPath('Desktop')
`$WT='$($env:LOCALAPPDATA-replace"'","''")\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
`$WT_PREVIEW='$($env:LOCALAPPDATA-replace"'","''")\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
`$FONTDIR='$($env:LOCALAPPDATA-replace"'","''")\Microsoft\Windows\Fonts'
`$FONTREG='HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

if (-not `$Quiet) {
    Write-Host ''; Write-Host '  ''MiOS'' Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes:"
    Write-Host "    - Podman machine + WSL distros (`$B, `$M, podman-MiOS-*)"
    Write-Host "    - M:\\MiOS install dir + overlay files + ProgramData (`$I, `$P, `$D)"
    Write-Host "    - Start Menu folder + Desktop shortcuts"
    Write-Host "    - WT settings.json: launchMode, profiles.defaults, MiOS scheme + profiles"
    Write-Host "    - PowerShell profile redirector blocks (pwsh 7 + WindowsPowerShell 5.1)"
    Write-Host "    - Geist + Symbols-Only Nerd Font files + registry entries"
    Write-Host "    - HKCU/HKLM Path entries pointing into MiOS bin"
    Write-Host "    - HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\MiOS"
    Write-Host "    - podman-machine state symlinks"
    Write-Host "    - MIOS_* environment variables"
    if (`$Purge) {
        Write-Host "    - Per-user config at `$C (PURGE mode)" -ForegroundColor Yellow
    } else {
        Write-Host "  Preserves: `$C (per-user config -- pass -Purge to also remove)"
    }
    Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}

# 1. Podman machine
Write-Host '  [1/12] Stopping + removing podman machine...' -ForegroundColor Cyan
try { & podman machine stop `$B 2>`$null } catch {}
try { & podman machine rm -f `$B 2>`$null } catch {}

# 2. WSL distros (every variant the install has used across revisions)
Write-Host '  [2/12] Unregistering WSL distros...' -ForegroundColor Cyan
foreach (`$d in @(`$B, `$M, 'MiOS-DEV', 'podman-MiOS-DEV', 'MiOS-BUILDER', 'podman-MiOS-BUILDER')) {
    if ([string]::IsNullOrWhiteSpace(`$d)) { continue }
    try { & wsl.exe --unregister `$d 2>`$null | Out-Null } catch {}
}

# 3. Install dirs (preserve `$C unless -Purge)
Write-Host '  [3/12] Removing install dirs (M:\\MiOS + overlay)...' -ForegroundColor Cyan
`$dirsToRemove = @(`$I, `$P, `$D, `$S)
if (`$Purge) { `$dirsToRemove += `$C }
foreach (`$p in `$dirsToRemove) {
    if ([string]::IsNullOrWhiteSpace(`$p)) { continue }
    if (Test-Path -LiteralPath `$p) { Remove-Item -LiteralPath `$p -Recurse -Force -ErrorAction SilentlyContinue }
}
# M:\ root overlay files (only the ones MiOS overlaid; never wipe drive root structure)
if (Test-Path -LiteralPath 'M:\') {
    foreach (`$mRoot in @('M:\etc','M:\usr','M:\var','M:\automation','M:\config','M:\tools','M:\v1','M:\winget','M:\.devcontainer','M:\.forgejo','M:\.github','M:\.git','M:\Get-MiOS.ps1','M:\install.ps1','M:\bootstrap.ps1','M:\bootstrap.sh','M:\build-mios.ps1','M:\build-mios.sh','M:\install.sh','M:\install-mios-agents.sh','M:\seed-merge.ps1','M:\seed-merge.sh','M:\push-to-github.ps1','M:\preflight.ps1','M:\mios-pipeline.ps1','M:\mios-build-local.ps1','M:\Justfile','M:\Containerfile','M:\Containerfile.minimal','M:\manifest.json','M:\image-versions.yml','M:\renovate.json','M:\system-prompt.md','M:\identity.env.example','M:\mios.toml','M:\AGENTS.md','M:\AGREEMENTS.md','M:\CLAUDE.md','M:\GEMINI.md','M:\CONTRIBUTING.md','M:\SECURITY.md','M:\README.md','M:\LICENSE','M:\VERSION','M:\MiOS-SBOM.csv','M:\llms.txt','M:\llms-full.txt','M:\.clinerules','M:\.cursorrules','M:\.editorconfig','M:\.env.mios','M:\.gitattributes','M:\.gitignore','M:\podman')) {
        if (Test-Path -LiteralPath `$mRoot) { Remove-Item -LiteralPath `$mRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# 4. WT settings.json -- remove only MiOS-set keys, preserve everything else
Write-Host '  [4/12] Cleaning Windows Terminal settings.json...' -ForegroundColor Cyan
foreach (`$wtPath in @(`$WT, `$WT_PREVIEW)) {
    if (-not (Test-Path -LiteralPath `$wtPath)) { continue }
    try {
        `$raw = Get-Content -LiteralPath `$wtPath -Raw
        `$stripped = [regex]::Replace(`$raw, '(?ms)/\*.*?\*/', '')
        `$stripped = [regex]::Replace(`$stripped, '(?m)^\s*//.*$', '')
        `$stripped = [regex]::Replace(`$stripped, ',(\s*[\}\]])', '`$1')
        `$j = `$stripped | ConvertFrom-Json -ErrorAction Stop
        `$changed = `$false
        # Root-level launchMode (only remove if = 'focus' or 'maximizedFocus' -- our values)
        if (`$j.PSObject.Properties['launchMode'] -and `$j.launchMode -in @('focus','maximizedFocus','focusFullscreen')) {
            `$j.PSObject.Properties.Remove('launchMode'); `$changed = `$true
        }
        # profiles.defaults: only the keys MiOS writes
        if (`$j.profiles -and `$j.profiles.defaults) {
            foreach (`$k in @('scrollbarState','padding','useAcrylic','opacity','systemBackdrop','suppressApplicationTitle','disableAnimations','useAtlasEngine','experimental.detectURLs','experimental.input.forceVT','experimental.rendering.forceFullRepaint')) {
                if (`$j.profiles.defaults.PSObject.Properties[`$k]) {
                    `$j.profiles.defaults.PSObject.Properties.Remove(`$k); `$changed = `$true
                }
            }
        }
        # MiOS scheme
        if (`$j.schemes) {
            `$keepSchemes = @(`$j.schemes | Where-Object { `$_.name -ne 'MiOS' })
            if (`$keepSchemes.Count -ne `$j.schemes.Count) { `$j.schemes = [object[]]`$keepSchemes; `$changed = `$true }
        }
        # MiOS / MiOS-DEV / podman-MiOS-* profiles
        if (`$j.profiles -and `$j.profiles.list) {
            `$keepProfiles = @(`$j.profiles.list | Where-Object {
                `$_.name -ne 'MiOS' -and `$_.name -ne 'MiOS-DEV' -and `$_.name -ne 'MiOS-Bootstrap' -and `$_.name -notmatch '^podman-MiOS-' -and `$_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}' -and `$_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456790}'
            })
            if (`$keepProfiles.Count -ne `$j.profiles.list.Count) { `$j.profiles.list = [object[]]`$keepProfiles; `$changed = `$true }
        }
        if (`$changed) {
            (`$j | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath `$wtPath -Encoding UTF8
        }
    } catch {}
}

# 5. PowerShell profile redirector blocks (both pwsh 7 + WindowsPowerShell 5.1)
Write-Host '  [5/12] Removing PowerShell profile redirector blocks...' -ForegroundColor Cyan
function Remove-MarkerBlock {
    param([string]`$Text, [string]`$StartMarker, [string]`$EndMarker)
    while (`$true) {
        `$si = `$Text.IndexOf(`$StartMarker)
        if (`$si -lt 0) { return `$Text }
        `$ei = `$Text.IndexOf(`$EndMarker, `$si)
        if (`$ei -lt 0) { return `$Text }
        `$endPos = `$ei + `$EndMarker.Length
        # Trim a trailing newline if present so the removal is clean.
        if (`$endPos -lt `$Text.Length -and `$Text[`$endPos] -eq "``r") { `$endPos++ }
        if (`$endPos -lt `$Text.Length -and `$Text[`$endPos] -eq "``n") { `$endPos++ }
        `$Text = `$Text.Substring(0, `$si) + `$Text.Substring(`$endPos)
    }
}
`$pwshProfileCandidates = @(
    `$PROFILE.CurrentUserAllHosts,
    `$PROFILE.CurrentUserCurrentHost,
    (Join-Path `$env:USERPROFILE 'Documents\PowerShell\profile.ps1'),
    (Join-Path `$env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path `$env:USERPROFILE 'Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path `$env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path `$env:USERPROFILE 'OneDrive\Documents\PowerShell\profile.ps1'),
    (Join-Path `$env:USERPROFILE 'OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path `$env:USERPROFILE 'OneDrive\Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path `$env:USERPROFILE 'OneDrive\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
) | Where-Object { `$_ } | Sort-Object -Unique
foreach (`$pp in `$pwshProfileCandidates) {
    if (-not (Test-Path -LiteralPath `$pp)) { continue }
    try {
        `$body = Get-Content -LiteralPath `$pp -Raw
        `$body = Remove-MarkerBlock -Text `$body -StartMarker '# >>> MiOS oh-my-posh init >>>' -EndMarker '# <<< MiOS oh-my-posh init <<<'
        `$body = Remove-MarkerBlock -Text `$body -StartMarker '# >>> MiOS dash function >>>' -EndMarker '# <<< MiOS dash function <<<'
        `$body = `$body.Trim()
        if ([string]::IsNullOrWhiteSpace(`$body)) {
            Remove-Item -LiteralPath `$pp -Force -ErrorAction SilentlyContinue
        } else {
            Set-Content -LiteralPath `$pp -Value `$body -Encoding UTF8 -NoNewline
        }
    } catch {}
}

# 6. Fonts (Geist + Symbols-Only Nerd Font)
Write-Host '  [6/12] Removing MiOS fonts...' -ForegroundColor Cyan
if (Test-Path -LiteralPath `$FONTDIR) {
    Get-ChildItem -LiteralPath `$FONTDIR -File -ErrorAction SilentlyContinue |
        Where-Object { `$_.Name -match '^(Geist|.*NerdFontMono|.*NerdFontPropo|.*NerdFont|SymbolsOnly|.*Symbols.*)' } |
        ForEach-Object {
            `$fname = `$_.Name
            try { Remove-Item -LiteralPath `$_.FullName -Force -ErrorAction SilentlyContinue } catch {}
            # Matching reg entries (TrueType / OpenType suffixes)
            if (Test-Path -LiteralPath `$FONTREG) {
                `$face = [System.IO.Path]::GetFileNameWithoutExtension(`$fname)
                foreach (`$suffix in @(' (TrueType)',' (OpenType)')) {
                    `$regName = "`$face`$suffix"
                    try { Remove-ItemProperty -LiteralPath `$FONTREG -Name `$regName -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
}

# 7. PATH env (HKCU + HKLM if admin)
Write-Host '  [7/12] Removing PATH env entries...' -ForegroundColor Cyan
foreach (`$scope in @('User','Machine')) {
    try {
        `$cur = [Environment]::GetEnvironmentVariable('Path', `$scope)
        if (-not `$cur) { continue }
        `$parts = `$cur -split ';' | Where-Object { `$_ -and `$_ -notmatch '[Mm]:\\\\?MiOS\\\\bin' -and `$_ -notmatch [regex]::Escape(`$BIN) }
        `$new = (`$parts -join ';')
        if (`$new -ne `$cur) {
            [Environment]::SetEnvironmentVariable('Path', `$new, `$scope)
        }
    } catch {}
}

# 8. HKCU uninstall reg key
Write-Host '  [8/12] Removing HKCU uninstall reg key...' -ForegroundColor Cyan
if (Test-Path -LiteralPath `$K) { Remove-Item -LiteralPath `$K -Recurse -Force -ErrorAction SilentlyContinue }

# 9. Start Menu folder + Desktop .lnk shortcuts
Write-Host '  [9/12] Removing Start Menu + Desktop shortcuts...' -ForegroundColor Cyan
`$lnkNames = @(
    'MiOS.lnk','MiOS-DEV.lnk','MiOS Config.lnk','MiOS Help.lnk','Uninstall MiOS.lnk',
    # Legacy names from prior install revisions
    'MiOS Setup.lnk','Build MiOS.lnk','MiOS Configurator.lnk','MiOS Terminal.lnk',
    'MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','MiOS Build.lnk','MiOS Dashboard.lnk',
    'MiOS Update.lnk','MiOS Pull.lnk'
)
`$shortcutDirs = @(`$DESK, `$S,
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\MiOS',
    (Join-Path `$env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MiOS'),
    (Join-Path `$env:USERPROFILE 'OneDrive\Desktop')
) | Where-Object { `$_ -and (Test-Path -LiteralPath `$_) } | Sort-Object -Unique
foreach (`$dir in `$shortcutDirs) {
    foreach (`$ln in `$lnkNames) {
        `$lp = Join-Path `$dir `$ln
        if (Test-Path -LiteralPath `$lp) {
            try { Remove-Item -LiteralPath `$lp -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    # If dir is the MiOS Start Menu folder and now empty, remove it
    if (`$dir -match 'Start Menu\\Programs\\MiOS$') {
        if ((Get-ChildItem -LiteralPath `$dir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            try { Remove-Item -LiteralPath `$dir -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# 10. AppUserModelID HKCU registrations
Write-Host '  [10/12] Removing AppUserModelID registrations...' -ForegroundColor Cyan
foreach (`$aumKey in @('HKCU:\Software\Classes\AppUserModelId\MiOS.Workstation',
                       'HKLM:\Software\Classes\AppUserModelId\MiOS.Workstation')) {
    if (Test-Path -LiteralPath `$aumKey) {
        try { Remove-Item -LiteralPath `$aumKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# 11. podman-machine state symlinks
Write-Host '  [11/12] Removing podman-machine state symlinks...' -ForegroundColor Cyan
foreach (`$pmLink in @(
    (Join-Path `$env:LOCALAPPDATA 'containers\podman\machine'),
    (Join-Path `$env:USERPROFILE  '.local\share\containers\podman\machine'),
    'C:\ProgramData\containers\podman\machine'
)) {
    if (Test-Path -LiteralPath `$pmLink) {
        try {
            `$item = Get-Item -LiteralPath `$pmLink -Force -ErrorAction SilentlyContinue
            if (`$item.LinkType -eq 'SymbolicLink' -or `$item.LinkType -eq 'Junction' -or `$item.Target) {
                Remove-Item -LiteralPath `$pmLink -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# 12. MIOS_* environment variables
Write-Host '  [12/12] Removing MIOS_* environment variables...' -ForegroundColor Cyan
foreach (`$scope in @('User','Machine')) {
    try {
        `$envKey = if (`$scope -eq 'User') { 'HKCU:\Environment' }
                   else { 'HKLM:\System\CurrentControlSet\Control\Session Manager\Environment' }
        if (Test-Path -LiteralPath `$envKey) {
            (Get-Item -LiteralPath `$envKey).Property | Where-Object { `$_ -match '^(MIOS_|MiOS_)' } |
                ForEach-Object { try { Remove-ItemProperty -LiteralPath `$envKey -Name `$_ -ErrorAction SilentlyContinue } catch {} }
        }
    } catch {}
}

Write-Host ''
if (`$Purge) {
    Write-Host "  'MiOS' fully removed (zero-state). Per-user config at `$C also purged." -ForegroundColor Green
} else {
    Write-Host "  'MiOS' removed. Per-user config at `$C preserved." -ForegroundColor Green
    Write-Host "  Run with -Purge to also remove per-user config." -ForegroundColor DarkGray
}
"@ | Set-Content $uninstSc -Encoding UTF8
    Log-Ok "uninstall.ps1 written (12-category cleanup)"
    End-Phase $script:AppRegPhaseId

    # ── Phase 9 -- Build (DEPRECATED) ─────────────────────────────────────────
    # Same self-replication enforcement applies: $BootstrapOnly is forced
    # to $true at line 202, so this Phase-9 invocation is unreachable from
    # the operator-facing flow. The build pipeline runs INSIDE MiOS-DEV
    # via /usr/libexec/mios/mios-build-driver; the `mios build` verb
    # (M:\MiOS\bin\mios-build.ps1) is the canonical operator trigger.
    # Kept here as dead code so git-blame still resolves legacy refs;
    # a follow-up commit will delete this branch outright.
    Start-Phase 9
    # Pass the operator-chosen model selection (Phase 6 prompt) through
    # to the build so 37-ollama-prep.sh bakes the right pair into
    # /usr/share/ollama/models. MIOS_AI_MODEL takes precedence over the
    # hardware-driven default in Get-Hardware.
    $rc = Invoke-WslBuild -Distro $BuilderDistro -BaseImage $HW.BaseImage `
                          -AiModel $MiosAiModel -EmbedModel $MiosAiEmbedModel `
                          -BakeModels $MiosOllamaBakeModels `
                          -MiosUser $MiosUser -MiosHostname $MiosHostname
    if ($rc -eq 0) {
        End-Phase 9
        Invoke-DeployPipeline -HW $HW
        # NOTE: Rename-PodmanDevDistro now runs DURING bootstrap (after
        # Phase 5 + smoke test + Install-WindowsBranding) so the dev VM
        # is already named MiOS-DEV by the time the OCI build (Phase 9
        # above) completes. The build pipeline reaches the distro via
        # podman's API socket (SSH-forwarded) which is unaffected by
        # the WSL rename, OR via Invoke-DistroSh which probes both
        # names. No post-build rename is needed.
    } else { End-Phase 9 -Fail; $ExitCode = $rc }

} # end full-install branch

} catch {
    $ExitCode = 1   # set FIRST -- must be reached even if Show-Dashboard below also fails
    $errMsg = "$_"
    Write-Log "FATAL: $errMsg" "ERROR"
    $script:CurStep = "FATAL: $($errMsg.Substring(0,[math]::Min($errMsg.Length,120)))"
    if ($script:CurPhase -ge 0 -and $script:CurPhase -lt $script:PhStat.Count -and $script:PhStat[$script:CurPhase] -eq 1) {
        try { End-Phase $script:CurPhase -Fail } catch {}
    }
    Show-Dashboard -Force
} finally {
    # Drain stdout + Install-MiosLauncher's still-flushing log lines
    # before the final summary writes -- avoids the success-box-rows-
    # racing-with-launcher-tails rendering issue.
    try { [Console]::Out.Flush() } catch {}
    Start-Sleep -Milliseconds 500

    $totalTime = fmtSpan ([datetime]::Now - $script:ScriptStart)
    Write-Host ""
    if ($ExitCode -eq 0) {
        # In BootstrapOnly mode, the hint banner at line ~6584 already
        # printed the "Windows-side install complete" + verb hints.
        # Skip the second summary here -- printing it AGAIN duplicates
        # the operator-facing post-bootstrap UX. Per
        # feedback_mios_bootstrap_stops_at_dev_ready.
        if (-not $BootstrapOnly) {
            # Plain-text summary (no box drawing). The previous boxed
            # success summary was racing with Install-MiosLauncher's tail
            # log lines and producing fragmented output. Plain Write-Host
            # lines can't be partially overwritten by stragglers.
            Write-Host "  MiOS bootstrap complete." -ForegroundColor Green
            Write-Host "    Total time:   $totalTime"   -ForegroundColor DarkGray
            Write-Host "    Dev distro:   $BuilderDistro" -ForegroundColor DarkGray
            Write-Host "    Logs:         $MiosLogDir" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Next steps (run in any MiOS terminal):" -ForegroundColor Cyan
            Write-Host "    mios-build    full OCI image build inside MiOS-DEV" -ForegroundColor White
            Write-Host "    mios-config   open mios.toml configurator"          -ForegroundColor White
            Write-Host "    mios-dev      enter the dev distro shell"           -ForegroundColor White
            Write-Host "    mios-help     full command list"                    -ForegroundColor White
        }
    } else {
        Write-Host "  MiOS bootstrap FAILED (exit $ExitCode)" -ForegroundColor Red
        Write-Host "    Errors: $($script:ErrCount)" -ForegroundColor Yellow
        Write-Host "    Log:    $LogFile" -ForegroundColor Yellow
    }
    Write-Host ""
    # NO "Press Enter to close..." pause. The bootstrap finishes with
    # an automatic chain into the dev distro to run mios-build-driver
    # (the actual OCI build). Operator's terminal stays open in the
    # distro shell after the driver finishes; if they want the
    # bootstrap log they read $LogFile directly.
    Write-Log "auto-chain gate: ExitCode=$ExitCode Unattended=$Unattended MIOS_NO_AUTO_CHAIN='$($env:MIOS_NO_AUTO_CHAIN)'"
    if ($ExitCode -eq 0 -and -not $Unattended -and -not $env:MIOS_NO_AUTO_CHAIN) {
        Write-Log "auto-chain: gate open; resolving dev distro"
        $devDistro = $null
        try {
            $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" |
                       ForEach-Object { ($_ -replace [char]0,'').Trim() } |
                       Where-Object { $_ }
            foreach ($c in @('MiOS-DEV','podman-MiOS-DEV','MiOS-BUILDER','podman-MiOS-BUILDER')) {
                if ($wslList -contains $c) { $devDistro = $c; break }
            }
        } catch {}
        Write-Log "auto-chain: resolved dev distro = '$devDistro'"
        if ($devDistro) {
            $resolvedUser = 'root'
            try {
                $passwd = (& wsl.exe -d $devDistro --user root -- cat /etc/passwd 2>$null) -join "`n"
                if ($passwd -match '(?m)^mios:') { $resolvedUser = 'mios' }
                elseif ($passwd -match '(?m)^core:') { $resolvedUser = 'core' }
            } catch {}
            Write-Log "auto-chain: resolved user = '$resolvedUser'"
            Write-Host "  -> Launching $devDistro (--user $resolvedUser) to run mios-build-driver..." -ForegroundColor Cyan
            Write-Host "     Output streams below; the OCI build runs inside MiOS-DEV." -ForegroundColor DarkGray
            Write-Host ""

            # The driver lives at M:\usr\libexec\mios\mios-build-driver
            # (Phase 2 cloned mios.git to M:\). WSL automounts every
            # Windows drive at /mnt/<letter>/, so the dev distro can
            # see it directly at /mnt/m/usr/libexec/mios/mios-build-driver --
            # no need to base64-stage the file via stdin (which had
            # its own dragons: PowerShell `|` corrupting binary stdin,
            # ProcessStartInfo.ArgumentList not existing in PS 5.1,
            # etc.). Just exec it from the mount.
            #
            # Probe automount first so we surface a clear error if the
            # operator's WSL config has [automount].enabled=false. The
            # default machine-os config has automount on; this is a
            # belt-and-braces check.
            $localDriver = Join-Path $script:MiosRepoDir 'usr\libexec\mios\mios-build-driver'
            Write-Log "auto-chain: localDriver = '$localDriver' exists=$(Test-Path -LiteralPath $localDriver)"
            if (-not (Test-Path -LiteralPath $localDriver)) {
                Write-Log "auto-chain: ABORT -- mios-build-driver not found" "WARN"
                Write-Host "  [!] mios-build-driver not found at $localDriver" -ForegroundColor Yellow
                Write-Host "      Re-run the bootstrap; Phase 2 should have cloned mios.git to M:\." -ForegroundColor DarkGray
            } else {
                # Convert M:\path\to\file -> /mnt/m/path/to/file (WSL automount).
                $wslDriver = '/mnt/' + $localDriver.Substring(0, 1).ToLower() + ($localDriver.Substring(2) -replace '\\','/')
                $automountOk = $false
                try {
                    & wsl.exe -d $devDistro --user root -- test -r $wslDriver 2>$null
                    if ($LASTEXITCODE -eq 0) { $automountOk = $true }
                } catch {}
                Write-Log "auto-chain: wslDriver = '$wslDriver' automountOk=$automountOk"
                if (-not $automountOk) {
                    Write-Log "auto-chain: ABORT -- /mnt/m/ not readable inside $devDistro" "WARN"
                    Write-Host "  [!] /mnt/m/ not readable inside $devDistro (automount disabled?)" -ForegroundColor Yellow
                    Write-Host "      Manually run inside $devDistro :  bash $wslDriver" -ForegroundColor DarkGray
                } else {
                    # Exec the driver. As root, no sudo needed (avoids
                    # PAM/sudoers edge cases inside rootful machine-os).
                    Write-Log "auto-chain: EXEC bash $wslDriver inside $devDistro as $resolvedUser"
                    if ($resolvedUser -eq 'root') {
                        & wsl.exe -d $devDistro --user root -- bash -lc "exec bash $wslDriver"
                    } else {
                        & wsl.exe -d $devDistro --user $resolvedUser -- bash -lc "exec sudo bash $wslDriver"
                    }
                    Write-Log "auto-chain: driver exited with code $LASTEXITCODE"
                }
            }
        } else {
            Write-Log "auto-chain: ABORT -- no dev distro found in WSL list" "WARN"
        }
    } else {
        Write-Log "auto-chain: SKIPPED (gate closed)"
    }
    # Stop the background heartbeat runspace cleanly before exit. There is
    # no transcript to close (the unified log is written directly via
    # [IO.File]::AppendAllText), so dashboard frames never reach the log.
    try {
        $script:DashSync.Running = $false
        [System.Threading.Thread]::Sleep(200)   # let background loop exit its Sleep(120)
        if ($script:BgPs)  { try { $script:BgPs.Stop() }    catch {}; try { $script:BgPs.Dispose() }  catch {} }
        if ($script:BgRs)  { try { $script:BgRs.Close() }   catch {} }
    } catch {}
    # Merge raw build output (BuildDetailLog) into the unified log so a
    # post-mortem reader has a single file with the full picture.
    if (Test-Path $BuildDetailLog) {
        try {
            [System.IO.File]::AppendAllText($LogFile, "`n`n---- BUILD OUTPUT ----`n", [Text.Encoding]::UTF8)
            $detail = [System.IO.File]::ReadAllText($BuildDetailLog, [Text.Encoding]::UTF8)
            [System.IO.File]::AppendAllText($LogFile, $detail, [Text.Encoding]::UTF8)
            Remove-Item $BuildDetailLog -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    # Inject unified log into OCI image at /usr/share/mios/build-log.txt
    if ($ExitCode -eq 0) {
        try {
            $cid = (& podman create localhost/mios:latest 2>$null) -join ""
            if ($LASTEXITCODE -eq 0 -and $cid.Trim()) {
                $cid = $cid.Trim()
                & podman cp $LogFile "${cid}:/usr/share/mios/build-log.txt" 2>$null
                & podman commit --quiet $cid localhost/mios:latest 2>$null | Out-Null
                & podman rm -f $cid 2>$null | Out-Null
            }
        } catch {}
    }
    exit $ExitCode
}
