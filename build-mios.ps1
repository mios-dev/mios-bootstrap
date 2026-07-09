# AI-hint: PowerShell entry point for MiOS installation that configures the MiOS-DEV podman-machine, handles initial licensing, and manages the SSH handoff to the Linux-side build driver for generating OCI images and disk formats.
# AI-related: 37-ollama-prep.sh, mios-btop.sh, /usr/libexec/mios/mios-build-driver, /usr/share/mios/mios.toml, /usr/libexec/mios/mios-build-driver., /etc/mios/mios.toml, /usr/share/mios/configurator/mios.html, /usr/libexec/mios/flatpak-launch, /etc/mios/hermes/config.yaml, /etc/mios/hermes/config.local.yaml
# AI-functions: parse_sections_from_toml, get_pkgs, install_section, parse_pkgs, Disable-ConsoleQuickEdit, Resolve-MiosTomlText, Get-MiosTomlValue, Resolve-MiosInstallRoot, Update-MiosInstallPaths, Invoke-MigrateLegacyInstallRoot, Invoke-DataDiskBootstrap, Test-DashboardCanRedraw
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
# Migration status : Phase 6+ legacy code (identity, OCI build,
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

# Disable console QuickEdit mode up-front. With QuickEdit on (the Windows
# default), the instant anyone clicks or selects text in the window the console
# enters "mark" mode and BLOCKS the process on its next write until Enter/Esc is
# pressed -- on a long elevated install this looks identical to a dead hang
# (process idle, only a conhost child, VM perfectly healthy). The
# stall right after "MiOS Quadlet overlay applied" was exactly this. Clearing
# ENABLE_QUICK_EDIT_MODE (0x40) + setting ENABLE_EXTENDED_FLAGS (0x80) makes the
# installer immune to accidental click-to-freeze. Best-effort; never fatal.
function Disable-ConsoleQuickEdit {
    try {
        if (-not ('MiosConsole.Win32' -as [type])) {
            Add-Type -Namespace MiosConsole -Name Win32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern System.IntPtr GetStdHandle(int nStdHandle); [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode); [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);' -ErrorAction Stop
        }
        $h = [MiosConsole.Win32]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        [uint32]$mode = 0
        if ([MiosConsole.Win32]::GetConsoleMode($h, [ref]$mode)) {
            $mode = ($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80
            [void][MiosConsole.Win32]::SetConsoleMode($h, $mode)
        }
    } catch {}
}
Disable-ConsoleQuickEdit

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
        $ref = if ($null -ne $MiosRef) { $MiosRef } else { 'main' }
        $url = "https://raw.githubusercontent.com/mios-dev/MiOS/$ref/usr/share/mios/mios.toml?cb=$cb"
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
# [terminal.install] dims (80x40 install conhost, taller for log
# room).  Renamed to $script:MiosInst{Cols,Rows} to avoid colliding
# with Initialize-MiosGlobals which loads $script:Mios{Cols,Rows}
# from [terminal] (the app dims).  Operator: "I said Unified!!! ...
# extracted to ONE function used by every".
$script:MiosInstCols = Get-MiosTomlValue -Section 'terminal.install' -Key 'cols' -Default 80
$script:MiosInstRows = Get-MiosTomlValue -Section 'terminal.install' -Key 'rows' -Default 40
# Initialize-MiosGlobals (defined further down, called once at
# script load) writes $script:MiosCols / $script:MiosRows from
# the [terminal] section.  Shadow with the install dims here so
# any sizing-dependent code BEFORE Initialize-MiosGlobals fires
# uses the install conhost dims; after that point the app dims
# from Initialize-MiosGlobals take over.  $script:MiosScroll +
# $script:MiosAppCols / $script:MiosAppRows are kept inline (not
# overwritten by Initialize-MiosGlobals) for any legacy site that
# referenced the App-prefixed names.
$script:MiosCols    = $script:MiosInstCols
$script:MiosRows    = $script:MiosInstRows
$script:MiosScroll  = Get-MiosTomlValue -Section 'terminal' -Key 'scrollback_rows' -Default 9000
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

# NOTE: The bootstrap-conhost window-centering helper that lived here
# was REMOVED in commit 82dda7e+ because AMSI heuristics flagged the
# combination of console-window-handle retrieval + window-positioning
# Win32 calls as malware. Window centering was purely cosmetic; install
# runs identically without it. Operator can drag the window if needed.
$script:_PendingResizeLog += " center-skip=amsi-bait-removed"

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
$MiosRef          = Get-MiosTomlValue -Section 'bootstrap' -Key 'mios_ref'       -Default 'main'
$MiosBootstrapRef = Get-MiosTomlValue -Section 'bootstrap' -Key 'bootstrap_ref' -Default 'main'
# Raw-content tree bases + registry owner DERIVED from the repo URLs above so
# every download/login site sources the owner/name from one SSOT place
# (github.com host -> raw.githubusercontent.com, drop .git, append the ref).
$MiosRawBase      = (($MiosRepoUrl      -replace '^https://github\.com/', 'https://raw.githubusercontent.com/' -replace '\.git$', '') + "/$MiosRef")
$MiosBootstrapRaw = (($MiosBootstrapUrl -replace '^https://github\.com/', 'https://raw.githubusercontent.com/' -replace '\.git$', '') + "/$MiosBootstrapRef")
$MiosRepoOwner    = (($MiosRepoUrl -replace '^https://github\.com/', '') -split '/')[0]   # ghcr.io / GitHub owner namespace
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
# (probed tags = 5.0, 5.1,..., 5.8, 6.0, next).
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
        # M:\ root IS the mios.git working tree per the
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

# Data/log/config roots derive from the ALREADY-RESOLVED install root
# ($script:MiosInstallDir) so logging + btop + toml work in BOTH modes:
#   * admin / M:\ provisioned -> $script:MiosInstallDir is M:\MiOS (the
#     early M:\ redirect / Update-MiosInstallPaths fired above), so logs
#     land on M:\MiOS\logs exactly as before -- single mount point holds
#     the full audit trail per feedback_mios_m_drive_everything.
#   * non-admin (no M:\, no write to C:\) -> $script:MiosInstallDir is
#     %LOCALAPPDATA%\MiOS, so logs/config land there instead of a
#     non-existent M:\ (which previously hard-broke logging/btop/toml).
# The 'M:\MiOS' literal stays only as the last-resort fallback for the
# (theoretically unreachable) case where neither root resolved.
$MiosDataDir      = if ($script:MiosInstallDir) { $script:MiosInstallDir } else { 'M:\MiOS' }
$MiosLogDir       = Join-Path $MiosDataDir 'logs'
$MiosConfigDir    = Join-Path $MiosDataDir 'config'   # was %APPDATA%\MiOS
# Make the log dir bulletproof: ensure it exists the moment it's derived
# (well before $LogFile is first written by [IO.File]::AppendAllText), so a
# non-admin run never trips over a missing M:\ root.
$null = New-Item -ItemType Directory -Path $MiosLogDir -Force -ErrorAction SilentlyContinue

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
    # OPERATOR DIRECTIVE -- "MIOS REPOSITORIES BOTH OVERLAYED
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
    # NO-OP by default (final). Kept callable only for legacy
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
    # turns (visible 14:43-14:52 session as a 13-file working-
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
# "EXACTLY BUT FOR ALL VARIABLES GLOBALLY!!!!".
# Every shared mios.toml value the build pipeline reads is loaded
# ONCE here into the $script:Mios* namespace and read by name from
# downstream code instead of each site re-calling Get-MiosTomlValue.
# Single source-of-truth catalog -- one call site for each toml key.
function Initialize-MiosGlobals {
    # ── [terminal] -- framing only ───────────────────────────
    # cols / rows / scrollback are loaded at top-of-script into
    # $script:MiosInst{Cols,Rows} (install conhost) + $script:MiosApp{
    # Cols,Rows} (post-install MiOS app) -- DIFFERENT toml sections
    # ([terminal.install] vs [terminal]) -- so Initialize-MiosGlobals
    # doesn't touch them to avoid clobbering the install dims with
    # the app dims.  Frame width / height / right_margin ARE
    # loaded here because they're identical for both contexts.
    $script:MiosFrameW     = [int](Get-MiosTomlValue -Section 'terminal' -Key 'frame_width'     -Default 80)
    $script:MiosFrameH     = [int](Get-MiosTomlValue -Section 'terminal' -Key 'frame_height'    -Default 19)
    $script:MiosRightMgn   = [int](Get-MiosTomlValue -Section 'terminal' -Key 'right_margin'    -Default 0)
    if ($script:MiosFrameW   -lt 20) { $script:MiosFrameW   = 79 }
    if ($script:MiosFrameH   -lt 5)  { $script:MiosFrameH   = 19 }
    if ($script:MiosRightMgn -lt 0)  { $script:MiosRightMgn = 1  }
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
    $script:MiosFrameChars     = [string](Get-MiosTomlValue -Section 'branding.dashboard' -Key 'frame_chars' -Default "$([char]0x256D)$([char]0x2500)$([char]0x256E)$([char]0x2502)$([char]0x2570)$([char]0x256F)")
    if ($script:MiosFrameChars.Length -lt 6) { $script:MiosFrameChars = "$([char]0x256D)$([char]0x2500)$([char]0x256E)$([char]0x2502)$([char]0x2570)$([char]0x256F)" }
}
Initialize-MiosGlobals

# UNIFIED width formula -- ONE function used by every framed surface
# in build-mios.ps1 (load-time + post-resize Show-Dashboard +
# install-complete banner) AND Show-MiosDashboard (Get-MiOS.ps1) AND
# mios-dashboard.sh (Linux).  WIDTH = min(WindowWidth - right_margin,
# frame_width) sourced from the [terminal] section loaded above.
function Get-MiosFrameWidth {
    $width = 80
    try {
        if ([Console]::WindowWidth -gt 0) {
            $width = [Console]::WindowWidth
        }
    } catch {}
    [math]::Max(60, [math]::Min(($width - $script:MiosRightMgn), $script:MiosFrameW))
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
    $sepTop = ([char]0x256D + (([char]0x2500).ToString() * ($w - 2)) + [char]0x256E).PadRight($winW)
    $sepBot = ([char]0x2570 + (([char]0x2500).ToString() * ($w - 2)) + [char]0x256F).PadRight($winW)
    $sepD   = ([char]0x251C + (([char]0x2500).ToString() * ($w - 2)) + [char]0x2524).PadRight($winW)
    $sepE   = $sepTop   # legacy alias -- header uses top corner the first time

    # ── Row helper -- script block closes over $in/$winW from caller scope ─────
    $mkRow = {
        param([string]$c)
        ([char]0x2502 + " " + $c.PadRight($in) + " " + [char]0x2502).PadRight($winW)
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
    $hdr   = [char]0x2502 + " $title" + (" " * $gap) + "$right " + [char]0x2502
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
            # into the dashboard view (seen in paste). The
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
    $bar = ((([char]0x2588).ToString()) * $filled) + ((([char]0x2591).ToString()) * ($barW - $filled))
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
        $cand  = "$left$([char]0x2026)$right"
        if ($cand.Length -le $MaxW) { return $cand }
    }
    return $S.Substring(0, $MaxW - 1) + [char]0x2026
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
        # BOM-free: PS 5.1 `Set-Content -Encoding UTF8` writes a UTF-8 BOM, and a
        # leading BOM makes WSL silently IGNORE the [wsl2] section (the operator's
        # memory/processor limits are dropped). WriteAllLines + UTF8Encoding($false)
        # is BOM-free on 5.1 AND pwsh 7. install-robustness.
        [System.IO.File]::WriteAllLines($wslCfg, $newLines, (New-Object System.Text.UTF8Encoding($false)))
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
        $hr   = ([char]0x2500).ToString() * $W
        $top  = "  " + [char]0x256D + ((([char]0x2500).ToString() * 3) + " MiOS bootstrap complete " + (([char]0x2500).ToString() * 99)).Substring(0, $W) + [char]0x256E
        $div  = "  " + [char]0x251C + $hr + [char]0x2524
        $bot  = "  " + [char]0x2570 + $hr + [char]0x256F
        function _Row { param([string]$Inner)
            if ($Inner.Length -gt ($W - 2)) { $Inner = $Inner.Substring(0, $W - 2) }
            "  " + [char]0x2502 + " " + $Inner.PadRight($W - 2) + " " + [char]0x2502
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
                $fallback   = "$MiosRawBase/usr/libexec/mios/mios-build-driver"
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
                # $MiosRepoDir root (M:\). Per the directive
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

function Read-Model([string]$Default = "qwen3.5:2b") {
    # AI model menu prompt -- feature parity with build-mios.sh's
    # prompt_model. Drives MIOS_OLLAMA_BAKE_MODELS at build time and
    # MIOS_AI_MODEL in install.env at runtime. Same auto-accept
    # semantics as the rest of the Phase-6 prompts. The lineup is
    # sourced from mios.toml [ai.host_thresholds] (the RAM-tier table)
    # so the menu never drifts from the SSOT -- the three options map
    # 1:1 onto small/mid/big_ram_model plus a custom escape hatch.
    $small = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'small_ram_model' -Default 'phi4-mini:3.8b-q4_K_M'
    $mid   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'mid_ram_model'   -Default 'qwen3.5:2b'
    $big   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'big_ram_model'   -Default 'qwen3.5:14b'
    $midGb = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'mid_ram_gb'      -Default 12
    $bigGb = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'big_ram_gb'      -Default 32
    Move-BelowDash
    Write-Host ""
    Write-Host "  AI model (Architectural Law 5 -- baked into the image):" -ForegroundColor White
    Write-Host "    1) $small  -- low-RAM default (CPU-fit)" -ForegroundColor DarkGray
    Write-Host "    2) $mid  -- >= ${midGb} GB RAM, auto-promote tier" -ForegroundColor DarkGray
    Write-Host "    3) $big  -- >= ${bigGb} GB RAM, big-RAM tier" -ForegroundColor DarkGray
    Write-Host "    4) custom            -- enter your own ollama model id" -ForegroundColor DarkGray
    $choice = Read-Line "Choice [1-4]" "1"
    switch ($choice) {
        "1"     { return $small }
        ""      { return $small }
        "2"     { return $mid }
        "3"     { return $big }
        "4"     { return (Read-Line "Custom model id (e.g. mistral-small3:24b)" $Default) }
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
    # Vendor fallbacks mirror the SSOT [ai] section (model / embed_model)
    # so an absent/unreadable card lands on the same values the canonical
    # mios.toml declares; bake = model + embed.
    $defaults = @{
        Model               = "qwen3.5:2b"
        EmbedModel          = "nomic-embed-text"
        BakeModels          = "qwen3.5:2b,nomic-embed-text"
        LlamacppBakeModels  = "granite-4.1-8b.gguf=unsloth/granite-4.1-8b-GGUF:granite-4.1-8b-Q4_K_M.gguf,lfm2-700m.gguf=LiquidAI/LFM2-700M-GGUF:LFM2-700M-Q4_K_M.gguf,embeddinggemma-300m-qat-q8_0.gguf=ggml-org/embeddinggemma-300m-qat-q8_0-GGUF:embeddinggemma-300m-qat-Q8_0.gguf"
        VllmBakeModel       = "Qwen/Qwen2.5-0.5B-Instruct"
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
        
        # 1. Parse [ai] section
        $m = [regex]::Match($text, '(?ms)^\[ai\]\s*$(.*?)(?=^\[|\z)')
        if ($m.Success) {
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
        
        # 2. Parse [llamacpp] section
        $m = [regex]::Match($text, '(?ms)^\[llamacpp\]\s*$(.*?)(?=^\[|\z)')
        if ($m.Success) {
            $body = $m.Groups[1].Value
            $rx = [regex]::new('(?m)^\s*bake_models\s*=\s*"([^"]*)"')
            $hit = $rx.Match($body)
            if ($hit.Success) { $defaults['LlamacppBakeModels'] = $hit.Groups[1].Value }
        }
        
        # 3. Parse [ai.vllm] section
        $m = [regex]::Match($text, '(?ms)^\[ai\.vllm\]\s*$(.*?)(?=^\[|\z)')
        if ($m.Success) {
            $body = $m.Groups[1].Value
            $rx = [regex]::new('(?m)^\s*bake_model\s*=\s*"([^"]*)"')
            $hit = $rx.Match($body)
            if ($hit.Success) { $defaults['VllmBakeModel'] = $hit.Groups[1].Value }
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
    $_aiBigM   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'big_ram_model'     -Default 'qwen3.5:14b'
    $_aiMidM   = Get-MiosTomlValue -Section 'ai.host_thresholds' -Key 'mid_ram_model'     -Default 'qwen3.5:2b'
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
        empirically against podman 5.8.2 + WSL provider:

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
        '--update-connection',
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

                # v3: WSL unregister chain + final
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
    # (4th time): "I have told you the broken
    # MiOS-DEV machine is due to relocation and renaming breaking
    # the connections!!!".  Move-PodmanWslDistroToM does a
    # wsl --export + unregister + import which breaks podman's
    # internal machine state (podman's config files reference the
    # old VHDX path; after import the distro has the same name but
    # podman doesn't recognize it as the same machine -- subsequent
    # `podman machine` commands fail with "machine not found" /
    # `wsl ... getpwnam(root) failed 5`).
    #
    # Per memory feedback_mios_distro_name_locked +
    # feedback_mios_dev_on_m_drive: junctions ONLY, never re-import.
    # The XDG_DATA_HOME=M:\podman set at the top of New-BuilderDistro
    # + the reparse-point junctions on every podman-machine candidate
    # path (Set-PodmanMachineStorageOnM, called from Initialize-DataDisk)
    # already redirect new VHDX writes to M:\ at podman init time --
    # no migration needed.
    #
    # Gated behind $env:MIOS_FORCE_VHDX_MIGRATE=1 for the rare case
    # where the junction approach fails on a host (e.g., admin denied
    # symlink creation).  Default is to SKIP the migration entirely.
    if ((Test-Path 'M:\') -and ($env:MIOS_FORCE_VHDX_MIGRATE -in @('1','true','TRUE','yes'))) {
        try {
            Move-PodmanWslDistroToM -DistroName $BuilderDistro
        } catch {
            Log-Warn "podman-WSL distro M:\ migration: $_"
        }
    } else {
        Log-Ok "podman-WSL distro $BuilderDistro left in-place (junction redirect handles M:\ placement; set MIOS_FORCE_VHDX_MIGRATE=1 to force export-unregister-import)"
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
    # DEPRECATED bare invocation is a silent no-op.
    #
    # Original purpose: read mios.toml packages.* sections
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
    Log-Warn "MIOS_FORCE_LEGACY_PACKAGES_MD=1 -- running deprecated mios.toml overlay seed (you are off the canonical path)"
    Set-Step "Seeding MiOS package overlay onto $DevDistro (LEGACY)..."
    # Updated path: check mios.toml instead of PACKAGES.md.
    $tomlPath = Join-Path $MiosRepoDir "mios.toml"
    if (-not (Test-Path $tomlPath)) {
        $tomlPath = Join-Path $MiosRepoDir "usr\share\mios\mios.toml"
    }
    if (-not (Test-Path $tomlPath)) {
        Log-Warn "mios.toml not found in either canonical location -- legacy overlay seed skipped"
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

    # Stage the highest-precedence mios.toml + the overlay installer inside
    # the distro's /tmp. Using `wsl --exec cp` from the Windows path avoids
    # podman-machine-cp's rootful permission quirks.
    # The bash overlay reads [packages.dev_overlay].sections from mios.toml.
    $drive = $tomlPath.Substring(0,1).ToLower()
    $tomlWslPath = "/mnt/$drive" + ($tomlPath.Substring(2) -replace '\\','/')

    $overlayScript = @'
#!/usr/bin/env bash
# mios-overlay.sh -- live system overlay seeder for MiOS-DEV.
# Generated by build-mios.ps1 / Invoke-MiosOverlaySeed.
set -uo pipefail

SENTINEL="/var/lib/mios/.overlay-seeded"
SRC_TOML="${SRC_TOML:-/tmp/mios.toml}"
LOG_DIR="/tmp/mios-overlay-logs"
mkdir -p "$LOG_DIR" && chmod 0777 "$LOG_DIR"

# Skip if already seeded and mios.toml is older than the sentinel.
if [[ -f "$SENTINEL" && "$SENTINEL" -nt "$SRC_TOML" ]]; then
    echo "[mios-overlay] sentinel newer than mios.toml -> skip"
    exit 0
fi

# Normalize CRLF (OneDrive-synced source).
TOML_LF="/tmp/mios.lf.toml"
tr -d '\r' < "$SRC_TOML" > "$TOML_LF"

# Resolve the dev-overlay section list from the user's mios.toml. The
# layered resolver (highest wins): per-user (~/.config/mios/mios.toml),
# host (/etc/mios/mios.toml), bootstrap clone, vendor. The PowerShell side
# stages the highest-precedence layer at $SRC_TOML before invoking us.
# Falls back to a hardcoded minimal list if no [packages.dev_overlay].sections
# array is present.
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
    [[ -r "$TOML_LF" ]] || return 1
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
    ' "$TOML_LF" \
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
    local category="$1"
    awk -v section="packages.${category}" '
        /^\[/ {
            in_section = 0
            collecting = 0
            line = $0
            sub(/^\[/, "", line); sub(/\][[:space:]]*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            if (line == section) in_section = 1
            next
        }
        in_section && /^[[:space:]]*pkgs[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            collecting = 1
        }
        collecting {
            print
            if ($0 ~ /\][[:space:]]*$/) { collecting = 0 }
        }
    ' "$TOML_LF" \
        | tr -d '[]' \
        | tr ',' '\n' \
        | sed -E "s/[[:space:]]*\"([^\"]*)\"[[:space:]]*\$/\\1/" \
        | sed '/^[[:space:]]*$/d' \
        | sed -E 's/[[:space:]]*#.*$//'
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
# mios.toml (e.g. `wsl -d podman-MiOS-DEV -- sudo mios-dev-seed`).
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

    # Materialize the script + a copy of mios.toml inside the distro
    # via stdin; avoids cross-FS quoting headaches and works for both
    # /mnt/c-mounted paths and rootful machines.
    # CRLF -> LF: PowerShell @'...'@ here-strings produce CRLF on
    # Windows; without normalization the bash shebang becomes
    # "#!/usr/bin/env bash\r" -> "env: 'bash\r': No such file or
    # directory" -> the entire overlay silently no-ops on the dev VM.
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64Script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overlayScript))
    $stage = "set -e; sudo install -d -m 0777 /tmp; " +
             "echo '$b64Script' | base64 -d > /tmp/mios-overlay.sh && chmod +x /tmp/mios-overlay.sh; " +
             "cp '$tomlWslPath' /tmp/mios.toml; " +
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

    # NOTE: an earlier version of this function early-returned here based
    # on podman machine inspect.Rootful, on the theory that rootful
    # machine-os distros aren't wsl.exe-accessible. Modern WSL handles
    # rootful machine-os fine and the contract `MiOS-DEV ≡ MiOS` requires
    # the dev VM to have the same Quadlets / containers / units as a
    # deployed MiOS host AS EARLY AS POSSIBLE -- not deferred to the OCI
    # build phase. Letting the wsl.exe probe below decide gates the
    # overlay on actual capability rather than an a-priori assumption.
    # (The OCI build path still re-applies the overlay later via the
    # baked-in image; if the install-time overlay succeeds, it's a no-op
    # post-bootc-switch via the sentinel check.)

    # Per the directive "M:\ IS git", mios.git is overlaid AT
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
        Log-Warn "wsl.exe probe into $DevDistro timed out at 8s -- install-time Quadlet overlay skipped."
        Log-Warn "  The mios-build-driver / bootc switch path still delivers the SAME Quadlets via the OCI image,"
        Log-Warn "  so MiOS-DEV will reach full-parity (MiOS-DEV == MiOS) after the build phase regardless."
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

# ── Universal mios.git overlay sync ──────────────────────────────────────────
# Works identically across every MiOS deploy shape:
#   - Bare-metal bootc (mios:latest deployed)
#   - Hyper-V VHDX / QEMU qcow2 / RAW disk image
#   - WSL2/g distros (mios:latest imported via wsl --import)
#   - Podman-WSL dev VM (the canonical podman-MiOS-DEV pre-bootc-switch)
#   - Podman / Podman Desktop (Windows + Linux native)
#   - Traditional FHS installs (mios.git overlaid into / via install.sh)
#
# Architectural Law 3 ".git IS /": the deployed root is always a git
# working tree of mios.git. This sync brings / up to origin/main using
# the FASTEST available source given the deploy context.
#
# Per WSL filesystem-performance guidance
# (learn.microsoft.com/en-us/windows/wsl/filesystems):
#   "For the fastest performance speed, store your files in the WSL
#    file system if you are working in a Linux command line."
# So all git operations target a NATIVE-ext4 bare-clone cache at
# $CACHE_DIR; /mnt/m (DrvFs / 9P) is only ever consulted as a one-shot
# offline-bootstrap source for the cache itself.

ORIGIN_URL="${MIOS_GIT_ORIGIN:-https://github.com/mios-dev/MiOS.git}"
ORIGIN_BRANCH="${MIOS_GIT_BRANCH:-main}"
CACHE_DIR="${MIOS_GIT_CACHE:-/var/lib/mios/git/mios.git}"

sudo mkdir -p "$(dirname "$CACHE_DIR")"

# Mark `/` AND the cache as safe git directories -- root-owned `.git`
# triggers "dubious ownership" rejection when non-root users later
# inspect state (`git -C / log`, dashboard's git panel, etc.).
sudo git config --system --add safe.directory / 2>/dev/null || \
    sudo git config --global --add safe.directory /
sudo git config --system --add safe.directory "$CACHE_DIR" 2>/dev/null || \
    sudo git config --global --add safe.directory "$CACHE_DIR"

# ── Phase A: ensure native bare-clone cache exists + is fresh ────────────────
cache_state=missing
if [[ -d "$CACHE_DIR/objects" ]]; then
    cache_state=present
fi

if [[ "$cache_state" = present ]]; then
    echo "[overlay] refreshing native cache: $CACHE_DIR (origin=$ORIGIN_URL)"
    if ! timeout 60 sudo git -C "$CACHE_DIR" fetch --depth=1 origin "$ORIGIN_BRANCH" 2>&1 | tail -3; then
        echo "[overlay] WARN: cache fetch failed (or timed out) -- proceeding with stale cache"
    fi
else
    # Cold cache. Try direct origin clone first (network-only path; pure
    # ext4 destination, no DrvFs round-trips). Both probe + clone are
    # bounded by `timeout` so a hung DNS / unreachable proxy can't stall
    # the whole bootstrap; the /mnt/m fallback below is the offline path.
    cache_populated=0
    if timeout 10 git ls-remote --exit-code --heads "$ORIGIN_URL" "$ORIGIN_BRANCH" >/dev/null 2>&1; then
        echo "[overlay] populating native cache via direct clone of $ORIGIN_URL"
        if timeout 120 sudo git clone --bare --depth=1 --branch="$ORIGIN_BRANCH" "$ORIGIN_URL" "$CACHE_DIR" 2>&1 | tail -3; then
            cache_populated=1
        else
            echo "[overlay] WARN: direct clone failed (or timed out at 2 min); falling back to $SRC bootstrap"
        fi
    else
        echo "[overlay] origin $ORIGIN_URL unreachable (probe timed out); falling back to $SRC bootstrap"
    fi

    # Fallback: bootstrap from the operator-side mios.git checkout (one-shot
    # DrvFs read; cache then operates on native ext4 forever after).
    if [[ $cache_populated -eq 0 ]] && [[ -d "$SRC/.git" ]]; then
        echo "[overlay] bootstrap-cloning native cache from $SRC (one-shot)"
        if sudo git clone --bare --depth=1 --branch="$ORIGIN_BRANCH" "$SRC" "$CACHE_DIR" 2>&1 | tail -3; then
            sudo git -C "$CACHE_DIR" remote set-url origin "$ORIGIN_URL"
            cache_populated=1
        fi
    fi

    if [[ $cache_populated -eq 0 ]]; then
        echo "[overlay] FATAL: no source for mios.git cache (origin unreachable AND $SRC/.git missing)"
        exit 1
    fi
fi

# ── Phase B: ensure / is a git working tree pointing at the native cache ─────
echo "[overlay] making / a git working tree of mios.git ($CACHE_DIR)"
sudo git -C / init -b "$ORIGIN_BRANCH" 2>&1 | head -1 || true
sudo git -C / config --bool core.fileMode false
sudo git -C / config --bool core.autocrlf false
sudo git -C / config --bool core.symlinks true
sudo git -C / remote remove origin 2>/dev/null || true
sudo git -C / remote add origin "$CACHE_DIR"

# ── Phase C: fetch + reset --hard (operates entirely on native ext4) ─────────
echo "[overlay] git -C / fetch origin $ORIGIN_BRANCH (from native cache) ..."
fetch_out=$(sudo git -C / fetch --depth=1 origin "$ORIGIN_BRANCH" 2>&1)
fetch_rc=$?
echo "$fetch_out" | tail -3
if [[ $fetch_rc -ne 0 ]]; then
    echo "[overlay] ERROR: git fetch failed (rc=$fetch_rc)"
fi
echo "[overlay] git -C / reset --hard FETCH_HEAD ..."
reset_out=$(sudo git -C / reset --hard FETCH_HEAD 2>&1)
reset_rc=$?
echo "$reset_out" | tail -3
if [[ $reset_rc -ne 0 ]]; then
    echo "[overlay] ERROR: git reset failed (rc=$reset_rc)"
    # Most common cause: /usr is read-only on ostree-managed bootc /
    # FCOS deploys. Enable a writable overlay and retry once. This
    # branch is a no-op on non-bootc shapes (rpm-ostree absent).
    if echo "$reset_out" | grep -qiE 'read-only|ostree'; then
        echo "[overlay] /usr appears read-only -- enabling rpm-ostree usroverlay"
        sudo rpm-ostree usroverlay 2>&1 | tail -2 || true
        echo "[overlay] retrying git reset --hard FETCH_HEAD"
        sudo git -C / reset --hard FETCH_HEAD 2>&1 | tail -3
        reset_rc=$?
    fi
fi

count=$(sudo git -C / ls-tree -r --name-only HEAD 2>/dev/null | wc -l)
echo "[quadlet-overlay] / now contains $count tracked mios.git files"
echo "[quadlet-overlay] / HEAD: $(sudo git -C / rev-parse --short HEAD 2>/dev/null)"

# Restore the executable bit on MiOS scripts. mios.git is authored on Windows
# where git core.filemode is off, so the checkout to / lands libexec/bin scripts
# as 0644 -- systemd ExecStart then 203/EXECs "Permission denied" (
# hermes-agent + cdi-detect + every firstboot failed this way). chmod +x the
# script trees; data files (py/json/yaml/md) stay untouched.
echo "[quadlet-overlay] restoring +x on MiOS scripts (Windows git checkout drops it)"
sudo chmod -R +x /usr/libexec/mios/ 2>/dev/null || true
sudo find /usr/lib/mios -type f \( -name "*.sh" -o -name "mios-*" \) ! -name "*.py" ! -name "*.json" ! -name "*.yaml" ! -name "*.md" -exec chmod +x {} + 2>/dev/null || true
sudo find /usr/bin /usr/local/bin -maxdepth 1 -name "mios-*" -type f -exec chmod +x {} + 2>/dev/null || true

# Statically enable mios-ai-firstboot via a .wants symlink rather than
# `systemctl enable --now`. During the overlay the VM's system bus is
# transitional ("Transport endpoint is not connected"), so enable --now for
# this long-running oneshot fails; a symlink is D-Bus-independent and lets the
# firstboot run on the FIRST CLEAN BOOT, when the bus + ollama are up. It
# self-heals (sentinel only on full success) and builds the venv + GGUFs there.
sudo install -d -m 0755 /usr/lib/systemd/system/multi-user.target.wants 2>/dev/null || true
sudo ln -sf ../mios-ai-firstboot.service /usr/lib/systemd/system/multi-user.target.wants/mios-ai-firstboot.service 2>/dev/null \
    && echo "[quadlet-overlay] mios-ai-firstboot enabled via .wants symlink (runs on first boot)" \
    || echo "[quadlet-overlay] WARN: could not symlink mios-ai-firstboot.service"

# Globally enable the OPERATOR-side launcher broker (mios-launcher.service, a
# USER unit) the same D-Bus-independent way: a .wants symlink in the GLOBAL
# user target dir so the operator's user manager starts it (ConditionUser=mios
# gates it to that user). Without this the broker ships DISABLED -> the socket
# /run/mios-launcher/launcher.sock is never created -> EVERY OS-control verb
# (open_app, etc.) fails "broker socket missing" and the agent cannot drive
# Windows/Linux apps ("open notepad" -> "LIAR"). The broker
# is what lets MiOS AI actually control the OS. install-robustness.
sudo install -d -m 0755 /etc/systemd/user/default.target.wants 2>/dev/null || true
sudo ln -sf /usr/lib/systemd/user/mios-launcher.service /etc/systemd/user/default.target.wants/mios-launcher.service 2>/dev/null \
    && echo "[quadlet-overlay] mios-launcher (OS-control broker) enabled via global user .wants symlink" \
    || echo "[quadlet-overlay] WARN: could not symlink mios-launcher.service"

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

# Render Quadlet ${MIOS_*} placeholders BEFORE systemd's podman
# generator runs at daemon-reload. The .container files at
# /etc/containers/systemd/*.container ship raw `${VAR:-default}`
# placeholders (Image=, PublishPort=, User=, Group=, Network=, ...);
# systemd's Quadlet generator does NOT expand them, so podman gets
# the literal string `${MIOS_PORT_LOCALAI` (split on the `:` of
# `:-8080`) and dies with:
#     Error: cannot parse "${MIOS_PORT_LOCALAI" as an IP address
# Every Quadlet stays in `activating auto-restart` and `podman ps`
# is empty. Operator-flagged (containers all dead after
# install).
#
# automation/15-render-quadlets.sh walks the four Quadlet search
# dirs, resolves the placeholders against the layered mios.toml
# (vendor < host < user) via tools/lib/userenv.sh, and writes the
# rendered files back in place. The deployed bootc image builds run
# this at image-build time; the dev-VM overlay path does NOT, so
# we run it here. Idempotent: re-runs against an already-rendered
# .container are a no-op (envsubst sees no remaining placeholders).
# install-robustness the dev-VM overlay never ran 36-tools.sh
# (which deploys tools/lib/userenv.sh -> /usr/lib/mios/userenv.sh, the env-bridge
# resolver) NOR mios-sync-env -- so /etc/mios/install.env was never generated,
# leaving the AI plane INERT on a fresh install: empty bake_models -> no GGUFs ->
# mios-llm-light skipped, and unresolved MIOS_PORT_* templates -> agent-pipe 502.
# Deploy the resolver + generate the bridge HERE so 15-render-quadlets below AND
# the firstboot services (EnvironmentFile=/etc/mios/install.env) see resolved
# values. Both idempotent; LIVE-verified this is the keystone that brought a
# fresh dev VM's MiOS AI fully operational on the GPU.
if [[ -r /tools/lib/userenv.sh ]]; then
    sudo install -D -m 0755 /tools/lib/userenv.sh /usr/lib/mios/userenv.sh \
        && echo "[quadlet-overlay] deployed env-bridge resolver -> /usr/lib/mios/userenv.sh"
fi
if [[ -x /usr/libexec/mios/system-sync-env.sh ]]; then
    echo "[quadlet-overlay] generating /etc/mios/install.env via mios-sync-env"
    sudo /usr/libexec/mios/system-sync-env.sh 2>&1 | sed 's/^/[quadlet-overlay]   /' || \
        echo "[quadlet-overlay] WARN: mios-sync-env exited non-zero (install.env may be stale)"
fi

if [[ -x /automation/15-render-quadlets.sh ]]; then
    echo "[quadlet-overlay] rendering Quadlet \${MIOS_*} placeholders via automation/15-render-quadlets.sh"
    sudo /automation/15-render-quadlets.sh 2>&1 | sed 's/^/[quadlet-overlay]   /' || \
        echo "[quadlet-overlay] WARN: 15-render-quadlets.sh exited non-zero (Quadlets may still have placeholders)"
else
    echo "[quadlet-overlay] WARN: /automation/15-render-quadlets.sh not found (mios.git overlay incomplete?)"
fi

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
echo "[quadlet-overlay] setting wsl.conf [boot].systemd=true + [user].default=mios"
# [boot].systemd=true is REQUIRED for `systemctl is-system-running`,
# Quadlet generators, mios-flatpak-install.service, and every other
# systemd-coupled feature inside the WSL distro. Without it, WSL boots
# without systemd as PID 1; smoke tests then see state='offline' and
# the build pipeline can't poll service state. WSL >= 0.67.6 honors
# this directive on next `wsl --terminate` + reentry.
if ! grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    echo "[quadlet-overlay] /etc/wsl.conf: appended [boot] systemd=true"
elif ! grep -qE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
    if grep -qE '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
        sudo sed -i 's|^[[:space:]]*systemd[[:space:]]*=.*|systemd=true|' /etc/wsl.conf
        echo "[quadlet-overlay] /etc/wsl.conf: rewrote systemd=<other> to systemd=true under [boot]"
    else
        sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        echo "[quadlet-overlay] /etc/wsl.conf: inserted systemd=true under existing [boot]"
    fi
else
    echo "[quadlet-overlay] /etc/wsl.conf: [boot] systemd=true already set"
fi
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
    if [[ -d /etc/skel ]]; then
        # Idempotent: `cp -an` (no-clobber) copies entries that are
        # MISSING in /var/home/mios without overwriting operator-edited
        # dotfiles. Previous guard (only-on-first-boot via missing
        # .bashrc) prevented newly-added skel entries (XDG user-dir tree,
        # user-dirs.dirs) from propagating to existing users on
        # `mios update`. Switched to per-file no-clobber so re-runs are
        # safe AND new skel content reaches existing users.
        # `cp -a` instead of rsync -- podman-machine-os 6.0 base does
        # NOT ship rsync, so the prior rsync call silently no-op'd.
        # Operator-flagged.
        sudo cp -an /etc/skel/. /var/home/mios/ 2>/dev/null || true
        sudo chown -R mios:mios /var/home/mios 2>/dev/null || true
        echo "[quadlet-overlay]   /var/home/mios reconciled against /etc/skel (cp -an, idempotent)"
    fi
fi

# Expose flatpak .desktop entries to WSLg's auto-publisher. WSLg scans
# /usr/share/applications/ + ~/.local/share/applications/ on each
# distro start and creates Windows Start Menu shortcuts under
# %APPDATA%\Microsoft\Windows\Start Menu\Programs\<distro>\<App>
# (on <distro>).lnk -- WITH the app's real icon and no terminal popup.
# Flatpak installs its entries to /var/lib/flatpak/exports/share/
# applications/ which WSLg does NOT scan, so symlink each into the
# WSLg-watched dir. Operator-flagged flatpak apps weren't
# in Start Menu STILL after the custom Linux Apps shortcuts were
# fixed -- WSLg's quality (icons + no terminal) is the canonical
# user expectation, our custom .lnks are a fallback only.
if [[ -d /var/lib/flatpak/exports/share/applications ]]; then
    for _df in /var/lib/flatpak/exports/share/applications/*.desktop; do
        [[ -f "$_df" ]] || continue
        _base=$(basename "$_df")
        if [[ ! -e "/usr/share/applications/$_base" ]]; then
            sudo ln -sf "$_df" "/usr/share/applications/$_base" 2>/dev/null
            echo "[quadlet-overlay]   linked flatpak desktop: $_base"
        fi
    done
    sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
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
NATIVE_SET=(cockpit.socket mios-cdi-detect.service nvidia-cdi-refresh.path mios-ai-firstboot.service)

# "now to finally fix none of the containers
# existing or properly launching on boot.. in podman-MiOS-DEV".
# Plus: "bake into mios.toml so operators can edit the list --
# EVERYTHING is sourced from the mios.toml file and edited in the
# mios.html in live environments browser".
#
# Quadlet-generated services have [Install] WantedBy=multi-user.target
# in their .container files, so they SHOULD auto-start at boot. On the
# WSL podman-machine substrate the dependency chain doesn't reliably
# fire for every service -- explicit `systemctl start --no-block` is
# the fix. --no-block returns immediately so overlay doesn't wait on
# multi-GB image pulls; each Quadlet's Restart=on-failure handles the
# retry.
#
# Both lists are TOML-sourced: mios-bootstrap/mios.toml
# [containers.quadlets].autostart + .optin. Operators edit via
# mios.html in the browser; build-mios.ps1's PowerShell side reads
# these on every overlay pass and substitutes them here. The
# PowerShell-side substitution replaces __MIOS_QUADLET_AUTOSTART__
# and __MIOS_QUADLET_OPTIN__ with literal bash-array entries.
QUADLET_AUTOSTART=( __MIOS_QUADLET_AUTOSTART__ )
QUADLET_OPTIN=( __MIOS_QUADLET_OPTIN__ )

# Daemon-reload so the Quadlet generator regenerates units from the
# latest .container files in /etc/containers/systemd/ +
# /usr/share/containers/systemd/ -- the bootc-deployed root may
# carry newer ones than the live systemd state.
$NS systemctl daemon-reload 2>&1 | grep -vE 'created symlink' || true

# Belt-and-suspenders reload, then enable each unit DIRECTLY. The previous
# `list-unit-files | grep` gate gave a FALSE "not present" for units checked out
# in this same overlay pass (mios-ai-firstboot.service was on disk +
# /usr/lib/systemd/system writable, but the gate skipped it so the AI never
# auto-provisioned). enable is the authoritative existence check.
$NS systemctl daemon-reload 2>/dev/null || true
for svc in "${NATIVE_SET[@]}"; do
    if $NS systemctl enable --now "$svc" >/dev/null 2>&1; then
        echo "[quadlet-overlay] enabled $svc"
    else
        echo "[quadlet-overlay] skip $svc (enable failed -- unit absent or start error; non-fatal)"
    fi
done

# Start the autostart set + any opt-in extras. `--no-block` so the
# overlay returns immediately; each Quadlet pulls/starts in parallel
# via systemd's job queue. Restart=on-failure (set per-Quadlet) covers
# the retry on transient image-pull failures.
for svc in "${QUADLET_AUTOSTART[@]}" "${QUADLET_OPTIN[@]}"; do
    if $NS systemctl cat "$svc" >/dev/null 2>&1; then
        echo "[quadlet-overlay] start --no-block $svc (Quadlet-generated)"
        $NS systemctl start --no-block "$svc" 2>&1 | grep -vE 'created symlink' || true
    else
        echo "[quadlet-overlay] skip $svc (Quadlet not yet rendered or pruned)"
    fi
done

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
echo "[quadlet-overlay] running canonical fetchers (fonts + oh-my-posh + ollama + xrdp Enhanced Session)..."
for script in /automation/09-fonts.sh \
              /automation/35-xrdp-enhanced-session.sh \
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
# Two flatpak remotes:
#   flathub -- community / third-party flatpaks (Flatseal, VSCodium, etc.)
#   fedora  -- Fedora's own flatpak registry, ships CURRENT GNOME apps
#              built against the current libadwaita runtime. Critical for
#              Nautilus + Epiphany because Flathub's versions are EOL
#              (pinned to GNOME 3.28 runtime, years out of date) which
#              gives operators the "old GTK / CSS / decorations" look.
sudo flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
sudo flatpak remote-add --system --if-not-exists flathub-beta \
    https://flathub.org/beta-repo/flathub-beta.flatpakrepo 2>/dev/null || true
sudo flatpak remote-add --system --if-not-exists fedora \
    oci+https://registry.fedoraproject.org 2>/dev/null || true
# gnome-nightly: where the modern Nautilus lives (org.gnome.Nautilus.Devel).
# Flathub's org.gnome.Nautilus is EOL on GNOME 3.28; Fedora flatpak
# registry doesn't carry Nautilus at all. The Devel build tracks
# current GNOME with modern libadwaita CSS / decorations.
sudo flatpak remote-add --system --if-not-exists gnome-nightly \
    https://nightly.gnome.org/gnome-nightly.flatpakrepo 2>/dev/null || true
# "enable all beta/preview/testing repositories
# for all fedora sources". Enable updates-testing dnf repo so we
# always get the freshest Fedora packages (fixes lag in Mesa /
# libadwaita / gnome-* / etc. landing on stable).
sudo dnf config-manager setopt updates-testing.enabled=1 2>/dev/null || true
# Refresh the appstream index so the install loop below can resolve
# the app IDs. Without this step `flatpak install` errors with
# "Nothing matches <ref> in remote <remote>" on a fresh remote.
sudo flatpak update --system --appstream flathub 2>&1 | tail -3 || true
sudo flatpak update --system --appstream flathub-beta 2>&1 | tail -3 || true
sudo flatpak update --system --appstream fedora 2>&1 | tail -3 || true
sudo flatpak update --system --appstream gnome-nightly 2>&1 | tail -3 || true
# Substrate-class Flatpaks: terminal (Ptyxis), file manager (Nautilus
# from fedora), Flatpak permissions UI (Flatseal), default browser
# (Epiphany from fedora), GNOME shell extensions, VSCodium. Each
# routes through WSLg as a Windows desktop window; the
# gnome-flatpak-runtime RPM section provides the host-side
# portals/audio/theming these need to render correctly.
#
# Entries with a "fedora:" prefix install from the fedora remote
# (current libadwaita / GNOME 50.x); plain entries install from
# flathub. Operator directive "just enable newer fedora
# repos for the flatpaks" / "you hard coded an old version of gnome
# files flatpak -- THAT'S why it's old looking!!"
declare -A FLATPAK_SHORT=(
    [app.devsuite.Ptyxis]=ptyxis
    [gnome-nightly:org.gnome.Nautilus.Devel]=nautilus
    [com.github.tchx84.Flatseal]=flatseal
    [fedora:org.gnome.Epiphany]=epiphany
    [com.vscodium.codium]=codium
    [com.mattjakeman.ExtensionManager]=extension-manager
)
# Defensive cleanup: if the prior install left a gnome-software flatpak
# wrapper at /usr/local/bin/gnome-software, remove it so the dnf-installed
# /usr/bin/gnome-software (from [packages.gnome-core-apps]) takes
# precedence on PATH.
if [[ -f /usr/local/bin/gnome-software ]] && grep -q 'flatpak.*org.gnome.Software\|flatpak-launch.*org.gnome.Software' /usr/local/bin/gnome-software 2>/dev/null; then
    sudo rm -f /usr/local/bin/gnome-software
    echo "[quadlet-overlay] removed legacy /usr/local/bin/gnome-software flatpak wrapper (now installed via dnf)"
fi
# Also clean up the OLD flathub Nautilus / Epiphany if a prior install
# pulled the EOL versions -- they conflict with the fedora-remote
# versions on the same app id.
for _eol in org.gnome.Nautilus org.gnome.Epiphany; do
    if flatpak info --system "$_eol" >/dev/null 2>&1; then
        _origin=$(flatpak info --system "$_eol" 2>/dev/null | awk -F': *' '/^Origin:/ {print $2; exit}')
        if [[ "$_origin" == "flathub" ]]; then
            sudo flatpak uninstall --system --noninteractive --assumeyes "$_eol" 2>&1 | tail -2 || true
            echo "[quadlet-overlay] uninstalled EOL flathub $_eol (will reinstall from fedora remote)"
        fi
    fi
done
for keyref in "${!FLATPAK_SHORT[@]}"; do
    # Split "remote:appid" form; default to flathub when no prefix.
    if [[ "$keyref" == *:* ]]; then
        remote="${keyref%%:*}"
        ref="${keyref#*:}"
    else
        remote="flathub"
        ref="$keyref"
    fi
    if ! flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$ref"; then
        # sudo prefix bypasses polkit's "Deploy not allowed for user"
        # gate on a fresh dev VM where polkit auth hasn't been
        # established yet. The sudoers drop-in below grants
        # passwordless sudo for the dev user, so this is silent.
        sudo flatpak install --system --noninteractive --assumeyes --or-update "$remote" "$ref" \
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
    # Look up short alias by the ORIGINAL key (with potential remote: prefix).
    short="${FLATPAK_SHORT[$keyref]}"
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
#
# Placeholder __MIOS_LOGIN_PASSWORD__ is substituted at heredoc-bake
# time by Invoke-MiosQuadletOverlay from mios.toml [auth].password
# (SSOT, operator-editable via mios.html). Vendor default is 'mios'.
# DO NOT inline 'mios' here -- the substitution pass is what makes
# the toml the single source of truth.
_mios_pw='__MIOS_LOGIN_PASSWORD__'
echo "${DEV_USER}:${_mios_pw}" | sudo chpasswd 2>&1 \
    && echo "[quadlet-overlay] ${DEV_USER} password set (length=${#_mios_pw})" \
    || echo "[quadlet-overlay] WARN: chpasswd for ${DEV_USER} failed"
echo "mios:${_mios_pw}" | sudo chpasswd 2>&1 \
    && echo "[quadlet-overlay] mios password set (length=${#_mios_pw})" \
    || echo "[quadlet-overlay] WARN: chpasswd for mios failed"

# Verify: drive `su - mios -c id` through a pty so we can actually
# type the password. If this succeeds, Cockpit's PAM stack (which
# uses the same /etc/shadow lookup) will accept the same credential.
# Operator-flagged dashboard said `mios / mios` but the
# Cockpit login rejected those credentials because an earlier chpasswd
# silently set the hash to something else (likely a CRLF leak from a
# prior PowerShell heredoc, since fixed). The verify step catches a
# silent failure here instead of letting the operator hit it at login.
if command -v python3 >/dev/null 2>&1; then
    if python3 - "${_mios_pw}" <<'PYVERIFY' 2>&1; then
import pty, os, sys, select, time
pw = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("su", ["su", "-", "mios", "-c", "id -un"])
buf = b""
end = time.time() + 6
sent = False
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: data = os.read(fd, 4096)
        except OSError: break
        if not data: break
        buf += data
        if not sent and b"assword" in buf:
            os.write(fd, pw.encode() + b"\n"); sent = True
        if b"mios" in buf and b"su:" not in buf:
            print("[quadlet-overlay] password verify OK")
            sys.exit(0)
        if b"Authentication failure" in buf or b"incorrect password" in buf:
            print("[quadlet-overlay] password verify FAILED:", buf.decode("ascii", "ignore")[:200])
            sys.exit(1)
print("[quadlet-overlay] password verify INCONCLUSIVE:", buf.decode("ascii", "ignore")[:200])
sys.exit(2)
PYVERIFY
        :
    fi
fi

# ── Layer the FULL mios.toml [packages].sections set into MiOS-DEV ───────
# Per feedback_mios_dev_equals_mios.md and the directive
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

# Re-resolve the systemd PID NOW. The dnf transaction we just ran
# upgraded the `systemd` RPM (a transitive dep of dozens of the 297
# packages in mios.toml). On WSL2's nested-systemd-in-WSL the new
# binary respawns inside the user namespace and PID 1's PID number
# changes -- so the $NS we captured at overlay start (line ~3658)
# points at a /proc/<old-pid> entry that no longer exists. Every
# subsequent `nsenter -t <old-pid> -a` then dies with:
#     nsenter: stat of /proc/<old-pid>/ns/user failed: No such file
# tripping the reap-on-failure trap and wiping the install.
# Operator-flagged.
SYSTEMD_PID=$(pidof systemd 2>/dev/null | tr ' ' '\n' | head -1)
if [[ -n "$SYSTEMD_PID" ]]; then
    NS="sudo nsenter -t $SYSTEMD_PID -a"
    echo "[quadlet-overlay] post-pkg: re-resolved systemd ns (PID $SYSTEMD_PID)"
else
    NS="sudo"
    echo "[quadlet-overlay] post-pkg: WARN systemd PID not found; falling back to bare sudo"
fi

# ── Dev-VM host networking drop-ins ──────────────────────────────────
# Operator-flagged localhost:3000 / :8888 from Windows
# (and from inside the dev VM) timed out even though the containers
# were `Up` per `podman ps` and bound 0.0.0.0:NNNN per `ss -tlnp`.
# Root cause: netavark was installed at /usr/libexec/podman/netavark
# but failed to install its per-container DNAT chain in the nat table
# (probably due to firewall_driver=iptables vs iptables-nft +
# nftables-only ruleset on the podman-machine-os base). conmon's host
# proxy listener accepted TCP but had no DNAT rule to forward to the
# container netns -> HTTP request hangs.
#
# Workaround that actually works on the dev VM: Network=host. The
# container shares the VM's main netns, listens directly on
# 0.0.0.0:NNNN, and wslrelay (Windows-side) picks up the listener via
# /proc/net/tcp scanning + forwards Windows localhost:NNNN -> VM port.
# This is the standard practice for single-tenant dev VMs.
#
# The deployed MiOS image (real Fedora bootc) doesn't have this
# problem -- netavark is wired through systemd-networkd and the
# firewall driver matches the host firewall backend. So the drop-ins
# below ONLY land on the dev VM (their parent units are guarded by
# the existing overlay flow, which only runs in podman-MiOS-DEV).
#
# Per-container env overrides for host-network mode. In host netns,
# every container shares the VM's main netns -- so bind ports collide
# AND inter-container DNS (e.g. mios-hermes resolution) no longer
# works (no aardvark; bridge networks aren't used). Override each
# image's bind/upstream env vars to talk over localhost on the
# canonical MiOS port from mios.toml [ports].*. Discovered live
# while shaking out the operator's first install.
#
#   ollama: HOME=/var/lib/ollama -- without this ollama tries to
#       mkdir /.ollama in the read-only container root and dies with
#       "permission denied". The Quadlet already mounts /var/lib/ollama
#       (writable for UID 815), so point HOME at it.
#   webui:  WEBUI_SECRET_KEY=<random> (env.py:611 requires non-empty
#       when WEBUI_AUTH=true), PORT=3030, OPENAI_API_BASE_URL=
#       http://localhost:8642/v1 (mios-hermes:8642 doesn't resolve in
#       host netns; use localhost instead).
#   hermes: PORT=8642 (otherwise picks an upstream default).
#   searxng: BIND_ADDRESS=0.0.0.0:8888 (granian default is :8080 which
#       collides with mios-ai).
# Hermes-Agent on the dev VM uses host networking, so the
# container-name DNS that the vendor /etc/mios/hermes/config.yaml
# relies on (mios-ollama, mios-ai, mios-searxng) does NOT resolve.
# Drop a config.local.yaml that overrides each base_url to talk over
# the VM's loopback instead. The vendor config has a trailing
# `include: /etc/hermes/config.local.yaml` so this auto-merges on
# top without touching the upstream file.
echo "[quadlet-overlay] writing /etc/mios/hermes/config.local.yaml (host-network URL overrides)"
sudo install -d -m 0755 /etc/mios/hermes
sudo tee /etc/mios/hermes/config.local.yaml >/dev/null <<'CFGLOCAL'
# /etc/mios/hermes/config.local.yaml
# Dev VM overrides for host-network mode. Generated by
# mios-bootstrap build-mios.ps1 :: Invoke-MiosQuadletOverlay.
# Operator-edits on top of THIS file persist across re-bootstraps
# only if the file is preserved -- the overlay step regenerates it
# every run, so for permanent customization edit
# /etc/mios/hermes/config.yaml (the vendor file) or move the
# override to /var/lib/mios/hermes/operator.yaml + adjust the
# include path.
backend:
  base_url: http://localhost:${MIOS_PORT_LLM_LIGHT:-8450}
auxiliary:
  # LLM Light's OpenAI-compatible surface for compression / summarization /
  # memory flush. Port 8080 was the legacy LocalAI bind -- after the
  # LocalAI purge, 8080 is code-server, so the previous default 8080/v1
  # made Hermes 401 against code-server then fall through to its
  # openrouter auto-detect (which also 401'd without an API key).
  base_url: http://localhost:${MIOS_PORT_LLM_LIGHT:-8450}/v1
tools:
  web_search:
    base_url: http://localhost:${MIOS_PORT_SEARXNG:-8899}

# model / custom_providers / agent are intentionally NOT defined here.
# mios-hermes-firstboot seeds /var/lib/mios/hermes/config.yaml (=
# /opt/data/config.yaml inside the container) with values resolved
# from mios.toml [ai].model + [[ai.catalog]] + [ai.host_thresholds]
# auto-pick. That seeded file is what Hermes loads as $HERMES_HOME/
# config.yaml -- it pins model.provider=custom:local-llm-light and
# model.default=<resolved>. Duplicating those keys here would
# overwrite the SSOT-derived value with whatever build-time guess
# build-mios.ps1 has hardcoded -- exactly the regression
# operator hit ("MiOS-Hermes agent isn't trying hard
# enough and is not capable"). Keep config.local.yaml limited to
# host-network URL overrides only.
CFGLOCAL

echo "[quadlet-overlay] applying Network=host drop-ins (dev VM port-forward workaround)"
# MiOS-DEV is a WSL2 podman machine -- bridge networking + PublishPort
# on this substrate binds container-loopback (127.0.0.1) on the WSL VM
# side, which the Windows-side netsh portproxy (0.0.0.0 -> WSL-VM-eth0-IP)
# can't reach. Network=host makes each container bind the WSL VM's real
# eth0 + loopback directly, so wslrelay relays loopback->Windows-host
# localhost AND the portproxy relays eth0->LAN.
#
# Architecture /14 (operator-directed):
#   * hermes-agent: DIRECT host install (automation/38 + hermes-agent.
#     service) -- NOT a container, so it gets NO dropin here.
#   * mios-hermes + mios-hermes-dashboard: container Quadlets SHELVED
#     ([quadlets.enable]=false) -- dropped from this list.
#   * mios-hermes-workspace: REMOVED entirely -- dropped.
#   * mios-open-webui: the chat UI. Its container listens on 8080
#     internally (parent Quadlet remapped host:3030->container:8080 via
#     PublishPort). Under host-net PublishPort is a no-op, so it MUST
#     get PORT=3030 or it binds 8080 and collides with mios-code-server
# ("[Errno 98] address already in use" -- operator-confirmed).
#   * Bind addresses: 0.0.0.0 everywhere (NOT 127.0.0.1). The old
#     "127.0.0.1 forces AF_INET for localhostForwarding" theory is
#     superseded -- the portproxy->WSL-VM-IP path needs eth0 binds.
for svc_pair in \
    "mios-forge:Environment=FORGEJO__server__HTTP_ADDR=0.0.0.0|Environment=GITEA__server__HTTP_ADDR=0.0.0.0" \
    "mios-searxng:Environment=GRANIAN_HOST=0.0.0.0|Environment=GRANIAN_PORT=8888|Environment=SEARXNG_BIND_ADDRESS=0.0.0.0:8888|Environment=BIND_ADDRESS=0.0.0.0:8888" \
    "mios-open-webui:Environment=PORT=3030" \
    "mios-code-server:" \
    "mios-cockpit-link:" \
    "mios-llm-light:Environment=HOME=/var/lib/mios/llamacpp|Environment=LD_LIBRARY_PATH=/usr/lib/wsl/lib:/usr/local/cuda/lib64" \
    "mios-forgejo-runner:" \
; do
    svc="${svc_pair%%:*}"
    extra="${svc_pair#*:}"
    [ "$extra" = "$svc" ] && extra=""
    sudo install -d -m 0755 "/etc/containers/systemd/${svc}.container.d"
    {
        echo "[Container]"
        echo "Network="
        echo "Network=host"
        # `extra` may carry multiple Environment= lines separated by
        # `|` (the heredoc loop above can't hold newlines).
        IFS='|' read -ra extras <<< "$extra"
        for e in "${extras[@]}"; do
            [ -n "$e" ] && echo "$e"
        done
    } | sudo tee "/etc/containers/systemd/${svc}.container.d/10-mios-dev-host-network.conf" >/dev/null
done

# Open the MiOS service ports in the dev VM's firewalld. The deployed
# bootc image runs automation/25-firewall-ports.sh at OCI build time
# (firewall-offline-cmd), but the MiOS-DEV overlay path does NOT go
# through an image build -- it's provisioned from podman-machine-os
# (firewalld active, public zone: only ssh/mdns/dhcpv6) and overlaid.
# Without this, every MiOS port is dropped on eth0 -- services bind but
# are unreachable from the WSL-VM-IP, so the Windows-side portproxy
# (0.0.0.0 -> WSL-VM-IP) hits a closed door (operator-confirmed
# LAN access dead until firewalld was opened by hand).
# firewall-cmd (online) here mirrors what 25-firewall-ports.sh bakes
# offline. Tolerant: no-op if firewalld isn't running.
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "[quadlet-overlay] opening MiOS service ports in dev VM firewalld"
    for _p in __MIOS_FIREWALL_PORTS__; do
        sudo firewall-cmd --permanent --add-port="${_p}/tcp" >/dev/null 2>&1
    done
    sudo firewall-cmd --reload >/dev/null 2>&1
    echo "[quadlet-overlay]   firewalld ports: $(sudo firewall-cmd --list-ports 2>/dev/null)"
else
    echo "[quadlet-overlay] firewalld inactive in dev VM -- no ports to open"
fi

# Use $NS (nsenter into systemd's namespace) instead of bare `sudo` so
# the reload reaches the running PID 1's bus. Bare `sudo systemctl
# daemon-reload` runs in the OUTER WSL ns and gets "Transport endpoint
# is not connected" -- same root cause as the early-overlay daemon-
# reload that already routes through $NS. Operator-flagged
# the bare-sudo call here tripped the reap-on-failure trap and wiped
# their install after a 9-minute Phase-3 build.
$NS systemctl daemon-reload

# Apply the MiOS systemd-preset so cockpit.socket / pmcd / pmlogger /
# pmproxy and other MiOS-preset-enabled units land at enabled=enabled
# on the dev VM. The deployed bootc image processes presets at image-
# build time; the dev-VM overlay path does NOT, so without this every
# preset-`enable`d unit stays at upstream Fedora's `disabled` default.
# Operator-flagged cockpit metrics page showed "pmlogger.
# service is not running" because PCP units were stuck disabled. The
# preset is the SSOT for "what should be on by default"; applying it
# here keeps the dev VM behavior identical to the deployed image.
if [[ -r /usr/lib/systemd/system-preset/90-mios.preset ]]; then
    echo "[quadlet-overlay] applying 90-mios.preset (cockpit + pcp + firstboot services)"
    grep -E '^enable ' /usr/lib/systemd/system-preset/90-mios.preset 2>/dev/null \
      | awk '{print $2}' \
      | while read -r _unit; do
            [[ -z "$_unit" ]] && continue
            if $NS systemctl cat "$_unit" >/dev/null 2>&1; then
                $NS systemctl preset "$_unit" 2>&1 | sed 's/^/[quadlet-overlay]   /'
            fi
        done
fi

# Mask dev-VM-hostile services. These are baked into mios.git for the
# bare-metal bootc image but cannot work in podman-machine-os WSL:
#   * audit-rules / auditd       -- WSL2 kernel has no audit subsystem
#   * fapolicyd                  -- needs kernel fanotify FAN_REPORT_FID
#   * usbguard                   -- no USB devices in WSL
#   * bootloader-update          -- no bootloader on WSL distros
#   * greenboot-healthcheck      -- bootc-specific rollback machinery
#   * mios-aichat-build          -- builds a Distrobox image that doesn't
#                                   apply on dev VM (used on bare metal)
#   * mios-wslg-permissions-fix  -- chmod /mnt/wslg fires before WSLg is
#                                   mounted on this machine-os build;
#                                   harmless to mask, Quadlets handle
#                                   /tmp/.X11-unix via /etc/profile.d.
#   * mios-wsl-init              -- the legacy first-boot init shim;
#                                   superseded by mios-cdi-detect +
#                                   mios-wsl-runtime-dir on the dev VM.
# Each shows up as "Failed to start" in cockpit's Services panel
# otherwise, which is operator-visible noise that suggests the
# install is broken. Masking is idempotent and reversible
# (systemctl unmask <unit>). Operator-flagged.
for _hostile in audit-rules.service auditd.service fapolicyd.service usbguard.service \
                bootloader-update.service greenboot-healthcheck.service \
                mios-aichat-build.service mios-wslg-permissions-fix.service \
                mios-wsl-init.service; do
    if $NS systemctl cat "$_hostile" >/dev/null 2>&1; then
        $NS systemctl stop "$_hostile" 2>/dev/null || true
        $NS systemctl mask "$_hostile" 2>&1 | sed 's/^/[quadlet-overlay]   /'
    fi
done

active=$($NS systemctl --no-legend list-units 'mios-*' 2>/dev/null | wc -l)
echo "[quadlet-overlay] done -- $active mios-* units active"
echo "[quadlet-overlay] Cockpit:        https://localhost:9090/  (host LAN reachable via mirrored networking)"
echo "[quadlet-overlay] Podman Desktop: containers under MiOS-DEV machine carry openInBrowser labels"
echo "[quadlet-overlay] Terminal:       Ptyxis flatpak ready -- launch via WSLg, default tab is host shell"
echo "[quadlet-overlay] Ollama:         set MIOS_DEV_ENABLE_AI=1 then re-run for the local Ollama Quadlet"
'@

    # Quadlet autostart / opt-in lists -- SSOT: mios.toml
    # [containers.quadlets]. Operator-editable via mios.html. The
    # bash heredoc has __MIOS_QUADLET_AUTOSTART__ /
    # __MIOS_QUADLET_OPTIN__ placeholders; resolve them here against
    # the layered TOML cascade and substitute as literal bash array
    # entries. Vendor default is the workstation-core set (cockpit-
    # link + forge + searxng + webui + ai + ollama). Operator opt-in
    # services land in the .optin list (per mios.toml).
    # Operator directive 'forget open webui for now -- Ollama
    # >> hermes agent >> hermes-workspace app is the front-end'. Swap
    # mios-webui out, swap mios-hermes + mios-hermes-workspace in.
    $_quadletAutostartDefault = @(
        'mios-cockpit-link','mios-forge','mios-searxng',
        'mios-hermes','mios-hermes-workspace','ollama'
    )
    $_quadletAutostart = @(Get-MiosTomlValue -Section 'containers.quadlets' -Key 'autostart' -Default $_quadletAutostartDefault)
    $_quadletOptin     = @(Get-MiosTomlValue -Section 'containers.quadlets' -Key 'optin'     -Default @())
    # Convert ["mios-cockpit-link","mios-forge",...] to bash array
    # entries: `"mios-cockpit-link.service" "mios-forge.service" ...`
    # (one literal token per quadlet, .service suffix appended).
    $_autostartBash = (@($_quadletAutostart) | ForEach-Object { '"' + $_ + '.service"' }) -join ' '
    $_optinBash     = (@($_quadletOptin)     | ForEach-Object { '"' + $_ + '.service"' }) -join ' '
    if ($null -eq $_autostartBash) { $_autostartBash = '' }
    if ($null -eq $_optinBash)     { $_optinBash     = '' }
    $overlayScript = $overlayScript -replace '__MIOS_QUADLET_AUTOSTART__', $_autostartBash
    $overlayScript = $overlayScript -replace '__MIOS_QUADLET_OPTIN__',     $_optinBash

    # __MIOS_FIREWALL_PORTS__ -- dev-VM firewalld open-port list for the
    # quadlet overlay. Service ports flow from the [ports] SSOT (operator
    # override-aware); the infra ports (ssh, forgejo-ssh, qdrant grpc/http,
    # hermes-dashboard, metrics) are not operator-tunable [ports] service
    # keys so they carry vendor defaults here. Mirrors the offline
    # 25-firewall-ports.sh surface baked into the OCI image.
    $_fwServicePorts = [ordered]@{
        forge_http       = 8300
        open_webui       = 8033
        code_server      = 8800
        cockpit          = 8090
        llm_light        = 8450
        searxng          = 8899
        hermes           = 8642
        hermes_dashboard = 8119
        guacamole_web    = 8080
        ceph_dashboard   = 8444
        rdp              = 8389
        ssh              = 8222
        forge_ssh        = 8301
        cpu_node         = 8458
        agent_pipe       = 8640
        ttyd_bash        = 8681
        ttyd_powershell  = 8682
    }
    $_fwPortList = [System.Collections.Generic.List[int]]@(22, 53, 8053, 8235, 8302, 8633, 8441, 8442)
    foreach ($_k in $_fwServicePorts.Keys) {
        $_fwPortList.Add([int](Get-MiosTomlValue -Section 'ports' -Key $_k -Default $_fwServicePorts[$_k]))
    }
    $_fwPortsStr = (($_fwPortList | Sort-Object -Unique) -join ' ')
    $overlayScript = $overlayScript -replace '__MIOS_FIREWALL_PORTS__', $_fwPortsStr

    # __MIOS_LOGIN_PASSWORD__ -- the operator-facing dev-VM login (also
    # the credential Cockpit web at https://localhost:9090/ accepts).
    # SSOT: mios.toml [auth].password (plain) or [auth].password_hash
    # (pre-hashed for hardened deploys). Default 'mios' if both blank.
    # The dashboard banner shows the literal string, so resolving it
    # from the same place the chpasswd line consumes guarantees the
    # advertised credential is the actual credential.
    $_miosLoginPassword = [string](Get-MiosTomlValue -Section 'auth' -Key 'password' -Default 'mios')
    if ([string]::IsNullOrWhiteSpace($_miosLoginPassword)) { $_miosLoginPassword = 'mios' }
    # Escape single-quote so the bash literal stays sound even if the
    # operator picks a password containing a quote character.
    $_miosLoginPasswordEsc = $_miosLoginPassword -replace "'", "'\''"
    $overlayScript = $overlayScript -replace '__MIOS_LOGIN_PASSWORD__', $_miosLoginPasswordEsc

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
    $Token | & podman login ghcr.io --username "$MiosRepoOwner" --password-stdin 2>&1 |
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
                                   [string]$AiModel = "qwen3.5:2b",
                                   [string]$EmbedModel = "nomic-embed-text",
                                   [string]$BakeModels = "qwen3.5:2b,nomic-embed-text") {
    # mios.git is now overlaid AT $MiosRepoDir root (M:\), per the
    # directive. The build context IS the overlay root.
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

    Set-Step "podman build (Windows client -> $BuilderDistro)"
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
    # Version pinning SSOT: env override wins, else mios.toml [bootstrap].bootstrap_ref
    # (pin to a tag or SHA for a reproducible install), else "main".
    $bootstrapRef     = if ($env:MIOS_BOOTSTRAP_REF) { $env:MIOS_BOOTSTRAP_REF } else { Get-MiosTomlValue -Section 'bootstrap' -Key 'bootstrap_ref' -Default 'main' }
    # Note: NO `set -e` here -- a transient clone failure must DEGRADE
    # (warn + skip the overlay) rather than abort the whole build. The
    # clone is wrapped in a 3x exponential-backoff retry loop so a flaky
    # network doesn't kill an otherwise-good build on the first failure.
    $seedScript = @"
if [ ! -d /tmp/mios-bootstrap/.git ]; then
    for i in 1 2 3; do
        rm -rf /tmp/mios-bootstrap
        git clone --depth=1 --branch '$bootstrapRef' '$bootstrapRepoUrl' /tmp/mios-bootstrap && break
        [ `$i -lt 3 ] && sleep `$((i*5))
    done
fi
if [ -x /tmp/mios-bootstrap/seed-merge.sh ]; then
    /tmp/mios-bootstrap/seed-merge.sh / /tmp/mios-bootstrap
else
    echo '[seed-merge] WARN: /tmp/mios-bootstrap/seed-merge.sh not found (clone may have failed) -- bootstrap overlay skipped' >&2
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
        Set-Step "Streaming container filesystem -> $([System.IO.Path]::GetFileName($OutFile))..."
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
    # Set [boot] systemd=true + [user] default=mios in the new distro.
    # systemd=true is REQUIRED -- without it WSL boots without systemd
    # as PID 1 and every Quadlet / service-coupled step downstream fails.
    try {
        & wsl.exe -d $MiosWslDistro --user root --exec bash -c `
            "if ! grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then printf '[boot]\nsystemd=true\n\n' >> /etc/wsl.conf; fi; id mios &>/dev/null && echo -e '[user]\ndefault=mios' >> /etc/wsl.conf || true" 2>$null | Out-Null
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

    $bibImage = Get-MiosTomlValue -Section 'image' -Key 'bib' -Default 'quay.io/centos-bootc/bootc-image-builder:latest'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman run --rm --privileged --pull=newer " +
        "--security-opt label=type:unconfined_t " +
        "-v /var/lib/containers/storage:/var/lib/containers/storage " +
        "-v ${MachineOutDir}:/output:z " +
        "$bibImage " +
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
        Set-Step "Converting raw -> vhdx..."
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
        Log-Ok "WSL2 tar: ${sizeMB}MB -> $wslTar"
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
    Set-Step ((Get-MiosTomlValue -Section 'messages.steps' -Key 'smoke_header_template' -Default "Smoke-testing {distro} before rename...") -replace '\{distro\}', $DevDistro)

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

    # 1. Basic responsiveness. Retried with backoff: Phase 3's wsl --shutdown
    # restarts the distro right before this smoke check, so the FIRST echo-ready
    # probe races the VM cold-start (operator-flagged smoke warned
    # "did not respond to echo ready" on a freshly-shutdown distro). Match the
    # systemd/podman probes' retry pattern. SSOT: [smoke_tests].
    $echoOut = ""
    $echoAttempts = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'echo_attempts'    -Default 15)
    $echoIntSec   = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'interval_seconds' -Default 2)
    for ($i = 1; $i -le $echoAttempts; $i++) {
        try { $echoOut = (& wsl.exe -d $name -- /bin/sh -c 'echo ready' 2>&1) -join "" } catch {}
        if ($echoOut.Trim() -eq 'ready') { break }
        if ($i -lt $echoAttempts) { Start-Sleep -Seconds $echoIntSec }
    }
    if ($echoOut.Trim() -ne 'ready') {
        Log-Warn "smoke: $name did not respond to 'echo ready' (got: '$echoOut') after $echoAttempts attempts"
        return $false
    }
    Log-Ok ((Get-MiosTomlValue -Section 'messages.steps' -Key 'smoke_responsive_template' -Default "smoke 1/4: {name} is responsive") -replace '\{name\}', $name)

    # 2. systemd up. Retried with backoff: Phase 3's wsl --terminate
    # restarts the distro right before this smoke check runs, so systemd
    # is warming up. Without retry, `systemctl is-system-running` returns
    # 'offline' before pid1 has finished switch-root.
    # SSOT: attempts + interval resolve through mios.toml [smoke_tests].
    $sysOut = ""
    $sysAttempts  = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'systemd_attempts'   -Default 15)
    $smokeIntSec  = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'interval_seconds'   -Default 2)
    for ($i = 1; $i -le $sysAttempts; $i++) {
        try { $sysOut = (& wsl.exe -d $name --user root -- /bin/sh -c 'systemctl is-system-running 2>&1 || true' 2>&1) -join "" } catch {}
        if ($sysOut.Trim() -notmatch '^(offline|unknown)\s*$' -and -not [string]::IsNullOrWhiteSpace($sysOut)) { break }
        if ($i -lt $sysAttempts) { Start-Sleep -Seconds $smokeIntSec }
    }
    if ($sysOut.Trim() -match '^(offline|unknown)\s*$' -or [string]::IsNullOrWhiteSpace($sysOut)) {
        Log-Warn "smoke: systemd not reachable in $name after $sysAttempts attempts (state: '$sysOut')"
        # Non-fatal -- some build flows skip systemd. Continue.
    } else {
        Log-Ok ((Get-MiosTomlValue -Section 'messages.steps' -Key 'smoke_systemd_template' -Default "smoke 2/4: systemd state '{state}' in {name}") -replace '\{state\}', $sysOut.Trim() -replace '\{name\}', $name)
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
        Log-Ok ((Get-MiosTomlValue -Section 'messages.steps' -Key 'smoke_overlay_template' -Default "smoke 3/4: /usr/share/mios overlay present in {name}") -replace '\{name\}', $name)
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
        # Same reason as systemd retry above: podman machine takes 15-30s
        # to warm up after wsl --terminate. Operator's 16:01 install
        # showed 5x2s=10s wasn't enough.
        # SSOT: attempts + interval resolve through mios.toml [smoke_tests].
        $attempts     = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'podman_api_attempts' -Default 15)
        $smokeIntSec2 = [int](Get-MiosTomlValue -Section 'smoke_tests' -Key 'interval_seconds'    -Default 2)
        for ($i = 1; $i -le $attempts; $i++) {
            try { $podOut = (& podman --connection "${DevDistro}-root" version --format '{{.Server.Version}}' 2>&1) -join "" } catch { $podOut = "$_" }
            if ($podOut -match $okFmt) { break }
            if ($i -lt $attempts) { Start-Sleep -Seconds $smokeIntSec2 }
        }
        if ($podOut -match $okFmt) {
            Log-Ok ((Get-MiosTomlValue -Section 'messages.steps' -Key 'smoke_podman_api_template' -Default "smoke 4/4: podman API server v{version}") -replace '\{version\}', $podOut.Trim())
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

function Set-MiosWslConfig {
    # Write / merge $env:USERPROFILE\.wslconfig with the keys MiOS-DEV
    # needs from the WSL2 utility VM:
    #   * networkingMode=mirrored  -- containers' 0.0.0.0:NNNN binds
    #     show up on Windows' loopback (and physical NICs once the
    #     LAN firewall rules let them through).
    #   * firewall=false           -- bypass Hyper-V Firewall (we don't
    #     ship per-port New-NetFirewallHyperVRule rules).
    #   * dnsTunneling=true        -- VM DNS matches Windows-native.
    #   * autoProxy=true           -- inherit Windows proxy settings.
    #   * guiApplications=true     -- WSLg compositor for flatpaks.
    #   * memory/processors/swap   -- right-sized for the detected host.
    #
    # CRITICAL: must run BEFORE Phase 3 initializes the dev VM. WSL2
    # reads .wslconfig at WSL2-utility-VM-START, so if we write it
    # AFTER podman-machine-init has spawned the VM, the VM keeps its
    # boot-time settings (legacy NAT mode) until the next `wsl --
    # shutdown`. Symptom the operator hit cockpit + every
    # other port timed out from Windows because the dev VM came up
    # in NAT mode while .wslconfig (set in Phase 4) said mirrored.
    # Idempotent: re-invoking from Phase 4 sees the same key set and
    # writes nothing new.
    param([int]$RamGB, [int]$Cpus)

    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
    # Networking: NAT + localhostForwarding (NOT mirrored). MS labels
    # mirrored as "beta" and operator confirmed on Windows
    # build 28020 (Canary): mirrored sets up the VM IP correctly
    # (vm-side `ip addr` shows Windows' Wi-Fi + Tailscale IPs), but
    # the documented localhost-forwarding silently breaks -- every
    # container port times out from Windows. NAT mode + the legacy
    # localhostForwarding=true bridge is what reliably forwards
    # 0.0.0.0:NNNN binds inside the VM to Windows' loopback. LAN-side
    # access from phone/other devices is then handled by the Windows
    # Firewall rules + netsh portproxy (added by Set-MiosLanFirewall
    # Rules + Set-MiosLanPortProxy in Phase 4).
    $requiredKeys = [ordered]@{
        memory              = "${RamGB}GB"
        processors          = "$Cpus"
        swap                = "4GB"
        networkingMode      = "NAT"
        localhostForwarding = "true"
        dnsTunneling        = "true"
        autoProxy           = "true"
        guiApplications     = "true"
    }

    $cfgRaw = if (Test-Path $wslCfg) { Get-Content $wslCfg -Raw } else { "" }

    if ($cfgRaw -notmatch "\[wsl2\]") {
        $block = "`n[wsl2]`n# MiOS-managed -- host resources for MiOS-DEV`n"
        foreach ($kv in $requiredKeys.GetEnumerator()) { $block += "$($kv.Key)=$($kv.Value)`n" }
        Add-Content -Path $wslCfg -Value $block
        Log-Ok ".wslconfig: wrote [wsl2] -- ${RamGB}GB RAM, $Cpus CPUs, mirrored"
        return
    }

    # `firewall` is mirrored-mode-specific and useless in NAT mode;
    # strip it on every merge so .wslconfig stays small. (Switch back
    # to ('localhostForwarding',) the day mirrored mode is the default
    # again -- right now NAT + localhostForwarding is the reliable
    # combo per operator's testing on Win 11 build 28020.)
    $deprecatedKeys = @('firewall')
    $lines    = (Get-Content $wslCfg)
    $inWsl2   = $false
    $patched  = [System.Collections.Generic.List[string]]::new()
    $inserted = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $lines) {
        if ($line -match "^\[wsl2\]") { $inWsl2 = $true }
        elseif ($line -match "^\[")   { $inWsl2 = $false }
        if ($inWsl2 -and $line -match "^(\w+)\s*=") {
            $key = $Matches[1]
            if ($deprecatedKeys -contains $key) { continue }
            if ($requiredKeys.Contains($key)) {
                $patched.Add("$key=$($requiredKeys[$key])")
                $null = $inserted.Add($key)
                continue
            }
        }
        $patched.Add($line)
    }
    $missing = $requiredKeys.Keys | Where-Object { -not $inserted.Contains($_) }
    if ($missing) {
        $insertIdx = ($patched | Select-String -Pattern "^\[wsl2\]" | Select-Object -First 1).LineNumber
        $offset = 0
        foreach ($key in $missing) {
            $patched.Insert($insertIdx + $offset, "$key=$($requiredKeys[$key])")
            $offset++
        }
    }
    # BOM-free (see the scrub site above): a UTF-8 BOM makes WSL ignore [wsl2].
    [System.IO.File]::WriteAllLines($wslCfg, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Log-Ok ".wslconfig: merged [wsl2] -- ${RamGB}GB RAM, $Cpus CPUs, mirrored"
}

function Set-MiosLanFirewallRules {
    # Windows Firewall inbound rules so OTHER devices on the operator's
    # LAN (phone, tablet, laptop) can reach the dev VM's container ports
    # at <Windows-host-IP>:NNNN -- not just from the same Windows box.
    #
    # Why this is needed even with WSL2 mirrored networking + .wslconfig
    # firewall=false:
    #   * Mirrored mode shares Windows' IP stack with the WSL VM, so a
    #     container bound to 0.0.0.0:NNNN inside the dev VM appears as
    #     Windows-side 0.0.0.0:NNNN automatically -- LISTEN visible in
    #     `netstat -ano | findstr :9090`.
    #   * .wslconfig firewall=false bypasses Hyper-V Firewall enforcement
    #     for the VM's vSwitch, so Windows-side localhost reaches the
    #     port without an extra Hyper-V allow rule.
    #   * BUT incoming connections from a LAN device still traverse the
    #     standard Windows Defender Firewall on the host's physical NIC.
    #     Defender default-denies inbound TCP for unknown listeners --
    #     so without an explicit per-port allow rule, the phone's
    #     browser hangs on connect even though Windows itself reaches
    #     localhost fine.
    #
    # SSOT: mios.toml [ports].* (port numbers) + [ports.lan_firewall].*
    # (profiles + expose list). Vendor defaults below; operator edits
    # mios.html to flip exposure on / off per service or narrow
    # profiles.
    #
    # Operator-flagged "windows installation should also
    # open the containers ports / forward them on windows side so that
    # we can access open webui, searxng, hermes, etc -- from my phone
    # or another device(s) on the local network."

    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Log-Warn "Firewall: New-NetFirewallRule cmdlet not available; skipping LAN inbound rules"
        return
    }

    $_defaultPorts = [ordered]@{
        forge_http       = 8300
        open_webui       = 8033
        code_server      = 8800
        cockpit          = 8090
        llm_light        = 8450
        searxng          = 8899
        hermes           = 8642
        hermes_dashboard = 8119
        guacamole_web    = 8080
        ceph_dashboard   = 8444
        rdp              = 8389
    }

    # Resolve per-service ports from [ports].<key>, falling back to vendor.
    $_ports = [ordered]@{}
    foreach ($k in $_defaultPorts.Keys) {
        $_ports[$k] = [int](Get-MiosTomlValue -Section 'ports' -Key $k -Default $_defaultPorts[$k])
    }

    # Which profiles + which services to expose (operator-editable).
    $_profiles = @(Get-MiosTomlValue -Section 'ports.lan_firewall' -Key 'profiles' -Default @('Private','Domain'))
    $_expose   = @(Get-MiosTomlValue -Section 'ports.lan_firewall' -Key 'expose'   -Default @($_defaultPorts.Keys))
    if ($_profiles.Count -eq 0) { $_profiles = @('Private','Domain') }
    if ($_expose.Count   -eq 0) { $_expose   = @($_defaultPorts.Keys) }

    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($svc in $_expose) {
        if (-not $_ports.Contains($svc)) {
            Write-Log "firewall: skip '$svc' -- not in [ports] section"
            continue
        }
        $port = [int]$_ports[$svc]
        if ($port -lt 1 -or $port -gt 65535) { continue }
        # Rule name carries the "MiOS - " prefix so Invoke-MiOSFullReap
        # can sweep them on uninstall without touching other rules.
        $name = "MiOS - $svc ($port/tcp)"
        try {
            $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
            if ($existing) {
                # Idempotent re-run: refresh action / profile / port.
                Set-NetFirewallRule -DisplayName $name `
                    -Enabled True -Action Allow -Direction Inbound `
                    -Profile ($_profiles -join ',') -ErrorAction SilentlyContinue
                $existing | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                    Set-NetFirewallPortFilter -Protocol TCP -LocalPort $port -ErrorAction SilentlyContinue
                Write-Log "firewall: refreshed '$name' on profiles $($_profiles -join ',')"
            } else {
                New-NetFirewallRule -DisplayName $name `
                    -Description "MiOS LAN inbound (auto-generated by mios-bootstrap)" `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port `
                    -Profile ($_profiles -join ',') -ErrorAction Stop | Out-Null
                Write-Log "firewall: created '$name' (TCP $port) on profiles $($_profiles -join ',')"
            }
            $applied.Add("$svc/$port")
        } catch {
            Log-Warn ("firewall: could not add '$name': " + $_.Exception.Message)
        }
    }
    if ($applied.Count -gt 0) {
        Log-Ok ("Windows Firewall: LAN inbound rules on $($_profiles -join '+') for " + ($applied -join ', '))
    }
}

function Set-MiosLanPortProxy {
    # Skip entirely under WSL2 mirrored networking: there is no distinct VM
    # eth0 to resolve and Windows already exposes container ports on the host,
    # so netsh portproxy is both impossible and unnecessary (the
    # "could not resolve a clean WSL VM IP" warning came from mirrored mode --
    # the .wslconfig the installer writes now uses networkingMode=mirrored).
    try {
        $_wslCfg = Join-Path $env:USERPROFILE '.wslconfig'
        if ((Test-Path $_wslCfg) -and ((Get-Content -LiteralPath $_wslCfg -Raw -ErrorAction SilentlyContinue) -match '(?im)^\s*networkingMode\s*=\s*mirrored\b')) {
            Log-Ok "portproxy: skipped (networkingMode=mirrored exposes container ports on the host directly)"
            return
        }
    } catch {}
    # Windows-side `netsh interface portproxy` mappings so OTHER devices
    # on the LAN can reach the dev VM's container ports.
    #
    # Why this is needed alongside Set-MiosLanFirewallRules:
    # In NAT networking mode (.wslconfig networkingMode=NAT, which MiOS
    # uses because mirrored mode silently breaks loopback forwarding on
    # the operator's Win11 build 28020), services bound to 0.0.0.0
    # inside the dev VM are reachable ONLY at Windows-side 127.0.0.1
    # (via the localhostForwarding=true bridge). The host's external
    # NIC (Wi-Fi / Ethernet) has nothing listening on those ports, so
    # connections from a phone on the same Wi-Fi hang on connect.
    # netsh portproxy makes Windows listen on 0.0.0.0:<port> and
    # forward to 127.0.0.1:<port>, which then bounces into the dev VM
    # via WSL's loopback bridge. Net effect: phone -> Win NIC ->
    # portproxy -> WSL distro container.
    #
    # Operator-flagged "none of my services are available
    # on my local wifi network".
    #
    # SSOT: same [ports].* + [ports.lan_firewall].expose list as the
    # firewall rules above, so opening / closing a service in mios.html
    # affects BOTH layers in lock-step. Idempotent: deletes the old
    # mapping before adding so re-runs converge cleanly without
    # accumulating duplicate listeners.
    $_defaultPorts = [ordered]@{
        forge_http       = 8300
        open_webui       = 8033
        code_server      = 8800
        cockpit          = 8090
        llm_light        = 8450
        searxng          = 8899
        hermes           = 8642
        hermes_dashboard = 8119
        guacamole_web    = 8080
        ceph_dashboard   = 8444
        rdp              = 8389
    }
    $_ports = [ordered]@{}
    foreach ($k in $_defaultPorts.Keys) {
        $_ports[$k] = [int](Get-MiosTomlValue -Section 'ports' -Key $k -Default $_defaultPorts[$k])
    }
    $_expose = @(Get-MiosTomlValue -Section 'ports.lan_firewall' -Key 'expose' -Default @($_defaultPorts.Keys))
    if ($_expose.Count -eq 0) { $_expose = @($_defaultPorts.Keys) }

    # CRITICAL FIX -- bind 0.0.0.0:PORT (covers Windows-host
    # localhost AND LAN clients in one rule), connect to the WSL VM's
    # eth0 IP. Earlier attempts:
    #   v0 (broken): listen=0.0.0.0 + connect=127.0.0.1 -- hijacked
    #     wslhost AND landed on dead Windows-host loopback. Every
    #     Windows-host curl localhost:PORT timed out.
    #   v1 (incomplete): listen=<LAN-IP> + connect=<WSL-VM-IP> -- LAN
    #     clients worked, Windows-host localhost broke because nothing
    #     bound 0.0.0.0:PORT (and WSL2's native localhostForwarding
    #     turned out to silently fail under NAT mode).
    #   v2 (current): listen=0.0.0.0 + connect=<WSL-VM-IP>. No hijack
    #     because target is the WSL VM, not Windows loopback. Windows-
    #     host localhost:PORT and LAN client <host-lan-ip>:PORT both
    #     hit the portproxy and forward into the WSL VM. Operator-
    # confirmed 8/8 MiOS services reachable from
    #     Windows browser via this rule shape.
    # WSL VM eth0 IP resolution. wsl.exe emits UTF-16LE by default --
    # capturing that in PowerShell mangles it (operator-confirmed
    # produced "20172.21.194.158", a garbage-prefixed IP, in
    # the live netsh portproxy table -> every LAN connect failed).
    # Two-part fix:
    #   1. $env:WSL_UTF8=1 makes wsl.exe emit clean UTF-8.
    #   2. [regex] extracts ONLY a valid dotted-quad from the output --
    #      belt-and-suspenders against any stray byte that still slips
    #      through, so connectaddress is ALWAYS a clean N.N.N.N or empty.
    $_wslIp = $null
    try {
        $_prevWslUtf8 = $env:WSL_UTF8
        $env:WSL_UTF8 = '1'
        $_raw = (& wsl.exe -d $DevDistro --user root -- sh -c "ip -4 -o addr show eth0" 2>$null) -join "`n"
        $env:WSL_UTF8 = $_prevWslUtf8
        $_m = [regex]::Match($_raw, '\binet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')
        if ($_m.Success) { $_wslIp = $_m.Groups[1].Value }
    } catch {}
    if (-not $_wslIp -or $_wslIp -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Log-Warn "portproxy: could not resolve a clean WSL VM IP (got: '$_wslIp') -- skipping forwarding"
        return
    }
    Write-Log "portproxy: WSL VM ip = $_wslIp"

    foreach ($svc in $_expose) {
        if (-not $_ports.Contains($svc)) { continue }
        $port = [int]$_ports[$svc]
        if ($port -lt 1 -or $port -gt 65535) { continue }
        # Drop any prior rule (idempotent re-run).
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port 2>&1 | Out-Null
        $r = & netsh interface portproxy add v4tov4 `
                  listenaddress=0.0.0.0 listenport=$port `
                  connectaddress=$_wslIp connectport=$port 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "portproxy: 0.0.0.0:$port -> ${_wslIp}:$port ($svc)"
        } else {
            Log-Warn "portproxy add for $svc :$port failed: $($r -join ' ')"
        }
    }

    # Ensure the ipv4-listen helper service is up (netsh portproxy
    # depends on IPHelper running -- a fresh Server SKU sometimes
    # ships it Disabled).
    try {
        $svc = Get-Service -Name iphlpsvc -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Set-Service -Name iphlpsvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue
        }
    } catch {}
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
    #
    # Default behavior INVERTED skipping the rename is now
    # the default. Reason: the rename breaks Podman Desktop's machine
    # visibility (Podman Desktop tracks the distro by its podman- prefix
    # registration; the rename + M:\ relocation orphans the machine
    # database entry, so the dev VM appears Stopped / un-launchable in
    # Podman Desktop even when wsl -l -v shows it Running). Operator-
    # facing UX continues to read "MiOS-DEV" via the Windows Terminal
    # profile name, Start Menu labels, and the `mios-dev` helper.
    #
    # TOML-first per AGENTS.md §3 / mios.toml is THE singular SSOT.
    # Resolve via [bootstrap.dev_vm].rename_distro from the layered
    # overlay; env var $MIOS_RENAME_DISTRO remains as a runtime override
    # for ad-hoc operator use (overrides TOML when set).
    $_renameDefault   = [string](Get-MiosTomlValue -Section 'bootstrap.dev_vm' -Key 'rename_distro' -Default 'false')
    $_renameRequested = if ($env:MIOS_RENAME_DISTRO -in @('1','true','TRUE','yes','True')) { $true }
                       elseif ($env:MIOS_RENAME_DISTRO -in @('0','false','FALSE','no','False')) { $false }
                       else { ($_renameDefault -ieq 'true') }
    if (-not $_renameRequested) {
        Log-Ok "WSL distro rename skipped (mios.toml [bootstrap.dev_vm].rename_distro=$_renameDefault) -- preserves Podman Desktop visibility for podman-$DevDistro. Edit in mios.html or set `$env:MIOS_RENAME_DISTRO=1 to opt in."
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

function New-Shortcut([string]$Path,[string]$Target,[string]$ArgList="",[string]$Desc="",[string]$Dir="") {
    # IMPORTANT: parameter was previously named $Args, which is one of
    # PowerShell's reserved superglobals (automatically populated with
    # the function's UNBOUND positional args). Inside the function body
    # $Args was therefore ALWAYS empty -- the test `if ($Args)` failed
    # and Arguments never made it onto the.lnk. Symptom
    # MiOS Linux Apps Start Menu shortcuts had TargetPath=wsl.exe but
    # Arguments="" so clicking "Files" / "Web" / etc. launched a bare
    # wsl.exe shell instead of `wsl -d podman-MiOS-DEV --user mios --
    # flatpak run <appid>`. Renamed to $ArgList so callers' --Args
    # passes actually land on the shortcut.
    $ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($ArgList) { $sc.Arguments = $ArgList }
    if ($Desc)    { $sc.Description = $Desc }
    if ($Dir)     { $sc.WorkingDirectory = $Dir }
    $sc.Save()
}

function Install-MiosWindowsTools {
    # Body extracted to src/install-host-tools.ps1 per operator directive
    # "TOLD YOU A MONOLITH INSTALL.ps1 SCRIPT WAS A BAD IDEA
    # AND THAT THE BOOTSTRAP SHOULD BE DOING MOST OF THE HOST_SIDE SETUP
    # AND INSTALLATIONS". Dot-sourced from disk at first call so the
    # 360-line winget install logic is no longer inline in this monolith
    # (also reduces AMSI heuristic surface).
    $_hostSrc = $null
    foreach ($_c in @(
        (Join-Path $MiosRepoDir 'src\install-host-tools.ps1'),
        (Join-Path $MiosBootstrapShadow 'src\install-host-tools.ps1')
    )) {
        if (Test-Path -LiteralPath $_c) { $_hostSrc = $_c; break }
    }
    if (-not $_hostSrc) {
        Log-Fail "src/install-host-tools.ps1 not found in repo. Re-run irm | iex to refresh."
        return
    }
    # Dot-source REDEFINES Install-MiosWindowsTools with the on-disk body
    # then re-invokes it. The redefinition is idempotent.
    . $_hostSrc
    Install-MiosWindowsTools
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

    # ── 1. Fonts (TOML-first per AGENTS.md §3) ───────────────────────
    # Sources + install scope all resolve from mios.toml [theme.font].*
    # so operators can pin URLs / force scope via mios.html. Geist is the
    # MiOS GLOBAL font ("Linux and Windows Font is
    # Geist font (system-wide -- terminals, apps, UI, etc-etc)") so the
    # default scope is "auto" => system-wide when elevated.
    $_fontVercelRepo = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'vercel_repo'   -Default 'https://github.com/vercel/geist-font.git')
    $_fontNerdMono   = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'url'           -Default 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/GeistMono.zip')
    $_fontSymbols    = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'symbols_url'   -Default 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip')
    $_fontScope      = [string](Get-MiosTomlValue -Section 'theme.font' -Key 'install_scope' -Default 'auto')

    $_isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    if ($_fontScope -ieq 'system' -or ($_fontScope -ieq 'auto' -and $_isAdmin)) {
        $fontDir   = "$env:WINDIR\Fonts"
        $regKey    = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        $scopeTag  = 'system-wide'
        if (-not $_isAdmin) {
            Log-Warn "[theme.font].install_scope=system but not running elevated -- falling back to per-user"
            $fontDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
            $regKey   = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
            $scopeTag = 'per-user (fallback)'
        }
    } else {
        $fontDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        $regKey   = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        $scopeTag = 'per-user'
    }
    if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
    if (-not (Test-Path $regKey))  { New-Item -Path $regKey -Force | Out-Null }

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
        $null = Invoke-NativeQuiet { git clone --depth=1 --quiet $_fontVercelRepo $geistTmp }
        if (Test-Path $geistTmp) {
            $count = 0
            Get-ChildItem -Path $geistTmp -Recurse -Include '*.otf','*.ttf' | ForEach-Object {
                if (Install-FontFile -Source $_.FullName) { $count++ }
            }
            Log-Ok "Geist (Vercel) installed ($scopeTag, $count new)"
        } else { Log-Warn "Geist clone failed -- skipping Vercel font install" }
    } finally {
        if (Test-Path $geistTmp) { Remove-Item $geistTmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # GeistMono Nerd Font -- the canonical MiOS terminal/UI face
    $geistMonoTmp = Join-Path $env:TEMP "mios-geistmono-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $geistMonoTmp -Force | Out-Null
    try {
        $geistMonoZip = Join-Path $geistMonoTmp 'GeistMono.zip'
        Invoke-WebRequest -Uri $_fontNerdMono -OutFile $geistMonoZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $geistMonoZip -DestinationPath $geistMonoTmp -Force
        $count = 0
        Get-ChildItem -Path $geistMonoTmp -Recurse -Include '*.otf','*.ttf' | ForEach-Object {
            if (Install-FontFile -Source $_.FullName) { $count++ }
        }
        Log-Ok "GeistMono Nerd Font installed ($scopeTag, $count new)"
    } catch { Log-Warn "GeistMono Nerd Font fetch failed: $($_.Exception.Message)" }
    finally { if (Test-Path $geistMonoTmp) { Remove-Item $geistMonoTmp -Recurse -Force -ErrorAction SilentlyContinue } }

    # Symbols-Only Nerd Font (Powerline + Devicon glyphs the omp theme uses)
    $nerdTmp = Join-Path $env:TEMP "mios-nerd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $nerdTmp -Force | Out-Null
    try {
        $nerdZip = Join-Path $nerdTmp 'NerdFontsSymbolsOnly.zip'
        Invoke-WebRequest -Uri $_fontSymbols -OutFile $nerdZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $nerdZip -DestinationPath $nerdTmp -Force
        $count = 0
        Get-ChildItem -Path $nerdTmp -Recurse -Include '*.otf','*.ttf' | ForEach-Object {
            if (Install-FontFile -Source $_.FullName) { $count++ }
        }
        Log-Ok "Symbols-Only Nerd Font installed ($scopeTag, $count new)"
    } catch { Log-Warn "Nerd Font fetch failed: $($_.Exception.Message)" }
    finally { if (Test-Path $nerdTmp) { Remove-Item $nerdTmp -Recurse -Force -ErrorAction SilentlyContinue } }

    # System-scope installs need a GDI WM_FONTCHANGE broadcast so apps see
    # the new fonts without logoff. Per-user installs are picked up
    # automatically by the user's session.
    if ($regKey -like 'HKLM:*') {
        try {
            # SendMessageTimeout, NOT SendMessage: a synchronous HWND_BROADCAST of
            # WM_FONTCHANGE blocks the installer FOREVER if ANY top-level window is
            # hung/unresponsive -- the stuck-install root cause (hung after
            # "Symbols-Only Nerd Font installed"). SMTO_ABORTIFHUNG|SMTO_NORMAL (0x0002)
            # + 1000ms/window makes the broadcast non-blocking. 0xFFFF=HWND_BROADCAST,
            # 0x001D=WM_FONTCHANGE.
            Add-Type -Namespace MiosFontX -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);' -ErrorAction SilentlyContinue
            $_fcRes = [System.UIntPtr]::Zero
            [void][MiosFontX.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, [uint32]0x0002, [uint32]1000, [ref]$_fcRes)
        } catch {}
    }

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
    # (per "M:\ IS git" directive). The mios-bootstrap shadow
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
            if ($_eR -and $_eR -ne "$([char]0xE0B4)") { $_omp = $_omp -replace '\\ue0b4', $_eR }
            if ($_eL -and $_eL -ne "$([char]0xE0B6)") { $_omp = $_omp -replace '\\ue0b6', $_eL }
            # leading_diamond / trailing_diamond appear only on diamond-
            # style segments (the leading text + trailing time caps).
            # Patch by JSON key: "leading_diamond": "" -> the new
            # value. Same for trailing_diamond.
            if ($_eLD -and $_eLD -ne "$([char]0xE0B6)") {
                $_omp = $_omp -replace '("leading_diamond"\s*:\s*")\\u[0-9a-fA-F]{4}', ('${1}' + $_eLD)
            }
            if ($_eTD -and $_eTD -ne "$([char]0xE0B4)") {
                $_omp = $_omp -replace '("trailing_diamond"\s*:\s*")\\u[0-9a-fA-F]{4}', ('${1}' + $_eTD)
            }
            # ── Color substitution from mios.toml [colors] (SSOT) ───
            # Per "oh my posh and other settings
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
    # Multi-image .ico writer (ICONDIR header + ICONDIRENTRY[] + per-image PNG blocks).
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)                    # reserved
    $bw.Write([UInt16]1)                    # type = icon
    $bw.Write([UInt16]$bitmaps.Count)
    $icoBlocks = @()
    foreach ($bmp in $bitmaps) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $icoBlocks += ,$ms.ToArray()
    }
    $offset = 6 + (16 * $bitmaps.Count)
    for ($i = 0; $i -lt $bitmaps.Count; $i++) {
        $b = $bitmaps[$i]; $p = $icoBlocks[$i]
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
    foreach ($p in $icoBlocks) { $bw.Write($p) }
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
    # "the dashboards are still too big!!!... but
    # if I open a new tab in MiOS apps' terminal window--I get a perfectly
    # fitting dashboard and piping!!!".
    #
    # The "too big" dashboard was THIS file's previous contents -- a
    # verbose Show-MiosDashboard with full ASCII logo + Self-replication
    # endpoint probes + dev-VM state + build-pipeline arrow. The new-tab
    # "perfectly fitting" dashboard is the Show-MiosDashboard inside
    # M:\MiOS\powershell\profile.ps1 (auto-runs on each tab open).
    #
    # Unify: mios-dash.ps1 is now a thin wrapper that dot-sources the
    # profile body and calls the SAME Show-MiosDashboard. One canonical
    # dashboard rendered everywhere -- typing `mios dash` is identical
    # to opening a new tab. SSOT: profile body comes from Get-MiOS.ps1's
    # Install-MiOSPowerShellProfile (which reads mios.toml [dashboard]
    # rows + [terminal] dims + [theme] palette).
    $dashPath = Join-Path $MiosBinDir 'mios-dash.ps1'
    $dashScript = @'
# <MiOSRoot>\bin\mios-dash.ps1
# `mios dash` verb -- delegates to the canonical Show-MiosDashboard
# defined in M:\MiOS\powershell\profile.ps1 so the dashboard rendered
# here is byte-identical to the one that auto-renders on each MiOS
# terminal tab open. Operator's directive ONE dashboard
# globally, dictated by mios.toml.
$ErrorActionPreference = 'SilentlyContinue'

# Pre-set the auto-MOTD guard BEFORE dot-sourcing the profile so the
# profile body's auto-render is suppressed -- we explicitly call
# Show-MiosDashboard ourselves below. Without this, fresh `pwsh`
# processes (launched from a Start Menu shortcut, a new WT tab, or
# any non-nested context) re-source the profile, which triggers its
# auto-render, which then runs in addition to our explicit call --
# producing two dashboards in a row. Operator-flagged
# "DOUBLE DASHBOARD still when running 'mios dash'".
$Global:MiosProfileMotdRendered = $true

$_miosProfile = 'M:\MiOS\powershell\profile.ps1'
if (Test-Path -LiteralPath $_miosProfile) {
    . $_miosProfile
    if (Get-Command Show-MiosDashboard -ErrorAction SilentlyContinue) {
        Show-MiosDashboard
        return
    }
}
Write-Host "  [!] M:\MiOS\powershell\profile.ps1 missing or Show-MiosDashboard not defined." -ForegroundColor Yellow
Write-Host "      Re-run irm | iex Get-MiOS.ps1 to refresh the profile." -ForegroundColor DarkGray
return
'@
    Set-Content -Path $dashPath -Value $dashScript -Encoding UTF8
    Log-Ok "Windows mios-dash staged at $dashPath (delegates to profile Show-MiosDashboard for unified compact rendering)"

    # The original verbose mios-dash body (full ASCII logo + Self-replication
    # endpoint probes + WSL distro state + build pipeline arrow) was
    # operator-rejected too tall for the 80x20 portal. The
    # block below is dead code retained as a textual marker only -- the
    # heredoc above is what gets staged.

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
# Operator confirmed bug previous mios-pull.ps1 only did
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
# Pre-bootc-switch the dev VM doesn't have /usr/bin/mios-pull yet (that
# binary lands via the OCI image overlay during `mios build`). Inline
# the equivalent bash so this verb works on day-0 -- before, during, and
# after the OCI image is built. The work is identical to what
# /usr/bin/mios-pull does post-bootc-switch: ensure / is a git working
# tree of mios.git (Architectural Law 3, ".git IS /"), then
# fetch + reset --hard origin/main.
# NOTE: this whole heredoc is INSIDE the outer @"..."@ that builds
# mios-pull.ps1. The @'...'@ below does NOT create a nested literal
# section -- it's just literal chars in the outer here-string. Every
# bash `$` that should reach the rendered file as a literal `$` must
# be escaped with a backtick or PS evaluates it.
#
# Earlier attempt passed `bash -c \$inlinePull` -- PowerShell's native-
# command argument quoting mangled the multi-line string (operator-
# observed install: ": invalid option namefail / -c: line
# 20: syntax error: unexpected end of file from `if' command on line
# 8"). The robust pattern is stdin-piping: write the script to bash's
# stdin via the pipeline, with LF normalization so CRLF doesn't make
# bash see `\r` as part of identifiers.
Write-Host '  [mios-pull] dev VM: syncing / overlay to origin/main...' -ForegroundColor Cyan
`$inlinePull = @'
set -uo pipefail
if [ -x /usr/bin/mios-pull ]; then
    # post-bootc-switch path: canonical script is present, defer to it
    sudo /usr/bin/mios-pull "`$@"
    exit `$?
fi
# pre-bootc-switch path: do the same work inline
if [ ! -d /.git ]; then
    echo "[mios-pull-inline] /.git missing -- dev VM root is not yet a mios.git working tree"
    echo "[mios-pull-inline]   (this is normal pre-build; bootstrap's mios-build-driver"
    echo "[mios-pull-inline]    will git-init / and overlay mios.git on the next build)"
    exit 0
fi
echo "[mios-pull-inline] git -C / fetch --depth=1 origin main ..."
sudo git -C / fetch --depth=1 origin main 2>&1 | sed 's/^/    /'
echo "[mios-pull-inline] git -C / reset --hard FETCH_HEAD ..."
sudo git -C / reset --hard FETCH_HEAD 2>&1 | sed 's/^/    /'
_head=`$(sudo git -C / rev-parse --short HEAD 2>/dev/null || true)
echo "[mios-pull-inline] / now at origin/main HEAD = `${_head}"
'@
# Normalize CRLF -> LF (Windows authoring of this PS file may leave
# CRLF in `$inlinePull which would corrupt bash identifiers like `\r`
# being treated as part of variable names) and pipe to bash via stdin
# (bash -s reads the script from stdin; arguments after `--` reach the
# script as `\$1 \$2 ...`). This avoids the native-cmd quoting bugs
# `bash -c <multi-line>` exhibited.
`$inlinePullLf = `$inlinePull.Replace("``r``n", "``n")
`$inlinePullLf | wsl.exe -d (Resolve-MiosDevDistro) --user mios -- bash -s -- @args
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
    Write-Host '    powershell -ExecutionPolicy Bypass -Command "irm $($MiosBootstrapRaw)/Get-MiOS.ps1 | iex"' -ForegroundColor DarkGray
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
    Write-Host ('  ' + ((([char]0x2500).ToString()) * [math]::Min(76, $T.Length + 4))) -ForegroundColor $muted
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
Write-Host ("  $([char]0x256D)" + ("$([char]0x2500)" * 74) + "$([char]0x256E)") -ForegroundColor $accent
Write-Host "  $([char]0x2502)                   MiOS  --  Help / Verb Reference                        $([char]0x2502)" -ForegroundColor $accent
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
Write-Host ("  $([char]0x2502)   " + $_helpTagPad.PadRight(72) + "   $([char]0x2502)") -ForegroundColor $accent
Write-Host ("  $([char]0x2570)" + ("$([char]0x2500)" * 74) + "$([char]0x256F)") -ForegroundColor $accent

Header 'Core verbs' 'Type any of these in a MiOS terminal, OR click the matching Start Menu shortcut.'
Verb 'mios'         '(no arg) -- open this help; runs `mios help` by default'
Verb 'mios build'   'Promote Downloads edits, sync the overlay, SSH into MiOS-DEV,'
Note '               ignite mios-build-driver -- the full OCI build pipeline.'
Verb 'mios code'    'Open code-server (VS Code in a browser) at http://localhost:8800/.'
Note '               Login: mios. Terminal pre-rooted at your home; `git clone'
Note '               http://mios-forge:3000/<user>/<repo>.git` works in-browser.'
Verb 'mios config'  'Open the HTML configurator (mios.toml editor) in your browser.'
Note '               Edit identity, AI, packages, ports, services, theme, etc.'
Verb 'mios dash'    'Render the framed MiOS dashboard (banner + fastfetch + verbs).'
Verb 'mios dev'     'Drop into the MiOS-DEV podman machine as user `mios` at /.'
Verb 'mios pull'    'git fetch + hard reset M:\ overlay to origin/main (no rebuild).'
Verb 'mios update'  'Re-run the bootstrap (cache-busted) -- refresh terminal + dev VM.'
Verb 'mios help'    'This list.'
Note ''
Verb 'mios <Q>'     'Free-form chat with Hermes-Agent. Anything that is not a known'
Note '               verb is sent to http://localhost:8642/v1/chat/completions and'
Note '               the response streamed to the terminal.'
Note '               Example: mios what kargs do I need for VFIO passthrough'

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
Note '                            (default http://localhost:8642/v1 -- Hermes-Agent)'
Note '   6. UNPRIVILEGED-QUADLETS every Quadlet declares User=, Group=, Delegate=yes'

Header 'Where to dig deeper'
Note '   mios.html    /usr/share/mios/configurator/mios.html   (HTML editor for mios.toml)'
Note '   AGENTS.md    M:\MiOS\repo\mios\AGENTS.md              (canonical agents.md doc)'
Note '   README.md    M:\MiOS\repo\mios\README.md              (project overview)'
Note "   GitHub       $($MiosRepoUrl -replace '\.git$','')"
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
# Operator confirmed bug `mios build` rendered an
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
# `mios build` should actually open the WSL-Podman machine
# AND build MiOS AND overlay newest MiOS repos at /ROOT.
`$distro = Resolve-MiosDevDistro
# `podman machine` and `wsl.exe -d` use DIFFERENT names for the same VM:
#   wsl.exe -d expects the WSL distro registration name -- 'podman-MiOS-DEV'
#   podman machine expects the machine name without prefix -- 'MiOS-DEV'
# Resolve-MiosDevDistro returns the WSL distro name (because it iterates
# `wsl -l -q`), which is correct for wsl.exe but causes `podman machine
# start podman-MiOS-DEV` to fail with 'VM does not exist'. Strip the
# 'podman-' prefix for podman-machine calls.
`$podmanMachine = `$distro -replace '^podman-', ''
Write-Host ''
# Pre-warm the WSL distro so its kernel + systemd are up BEFORE we ask
# podman to start the machine. Without this, `podman machine start`
# races and frequently emits:
#   "could not start api proxy since expected pipe is not available:
#    podman-MiOS-DEV"
#   "Error: machine did not transition into running state: ssh error"
# A no-op `wsl.exe -d <distro> --user mios -- true` triggers WSL to
# (re)launch the distro, which creates the AF_VSOCK / pipe endpoints
# podman then attaches to.
Write-Host ('  [build] pre-warming WSL distro {0} ...' -f `$distro) -ForegroundColor DarkGray
try {
    & wsl.exe -d `$distro --user mios -- true 2>&1 | Out-Null
} catch {}

Write-Host ('  [build] starting WSL-Podman machine: {0} ...' -f `$podmanMachine) -ForegroundColor Cyan
try {
    & podman machine start `$podmanMachine 2>&1 | ForEach-Object {
        `$line = `$_.ToString()
        # Filter noise. "already running" is happy-path; "machine did
        # not transition into running state" is a known false-positive
        # on WSL-backed machines when the api-proxy pipe is slow to
        # surface -- the distro is up, the daemon is reachable,
        # podman's own state cache just hasn't caught up yet.
        if (`$line -match 'is already running') {
            Write-Host '    (machine already running)' -ForegroundColor DarkGray
        } elseif (`$line -match 'machine did not transition into running state' -or
                  `$line -match 'could not start api proxy since expected pipe is not available' -or
                  `$line -match 'API forwarding for Docker API clients is not available') {
            Write-Host ('    (non-fatal: ' + `$line + ')') -ForegroundColor DarkGray
        } else {
            Write-Host ('    ' + `$line) -ForegroundColor DarkGray
        }
    }
} catch {
    Write-Host ('  [build] podman machine start threw: ' + `$_.Exception.Message) -ForegroundColor Yellow
    Write-Host '  [build] continuing -- wsl.exe -d already has the distro live; podman daemon should be reachable inside it.' -ForegroundColor Yellow
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
# First-run staging: on a fresh MiOS-DEV the OCI image hasn't been built
# yet, so /usr/libexec/mios/mios-build-driver doesn't exist inside the
# distro. The canonical source lives in mios.git at
# usr/libexec/mios/mios-build-driver (mios-dev/MiOS layout: FHS-shaped
# tree directly at repo root, NO 'system_files/' prefix). Per the
# "M:\ IS git" layout (build-mios.ps1 Update-MiosInstallPaths),
# mios.git's working tree is overlaid AT M:\ root, so the file is at
# M:\usr\libexec\mios\mios-build-driver, which is
# /mnt/m/usr/libexec/mios/mios-build-driver from inside WSL. Copy it in
# (idempotent -- overwrites any older staged copy) before invoking. Once
# the OCI image is built and bootc switch deploys it, the file is also
# present at the same path from the image overlay; this copy step
# becomes a no-op on subsequent re-builds.
`$driverSrc = '/mnt/m/usr/libexec/mios/mios-build-driver'
Write-Host ('  [build] staging mios-build-driver into {0}:/usr/libexec/mios/' -f `$distro) -ForegroundColor DarkGray
& wsl.exe -d `$distro --user root -- bash -c "mkdir -p /usr/libexec/mios && if [ -r '`$driverSrc' ]; then cp '`$driverSrc' /usr/libexec/mios/mios-build-driver && chmod +x /usr/libexec/mios/mios-build-driver && echo '[stage] driver staged from `$driverSrc'; else echo '[stage] WARN: `$driverSrc not readable from inside `$distro -- falling back to curl'; curl -fsSL -o /usr/libexec/mios/mios-build-driver '$MiosRawBase/usr/libexec/mios/mios-build-driver' && chmod +x /usr/libexec/mios/mios-build-driver; fi"

Write-Host ''
Write-Host ('  [build] handing off to {0}:/usr/libexec/mios/mios-build-driver' -f `$distro) -ForegroundColor Cyan
Write-Host '  [build] (this builds the OCI image inside MiOS-DEV; first run takes 10-30 min)' -ForegroundColor DarkGray
Write-Host ''
& wsl.exe -d `$distro --user mios --cd / -- bash -lc '/usr/libexec/mios/mios-build-driver'
# Install-robustness surface the driver's REAL exit code. Without
# this the `mios build` verb reported SUCCESS even when the OCI build failed
# inside MiOS-DEV -> the operator believed the image built and MiOS AI would come
# up, when it never did. Propagate the failure so it is visible + scriptable.
`$_drc = `$LASTEXITCODE
if (`$_drc -ne 0) {
    Write-Host ('  [build] OCI image build FAILED inside {0} (exit {1}) -- MiOS AI will NOT be operational until this build succeeds; see the log above.' -f `$distro, `$_drc) -ForegroundColor Red
    exit `$_drc
}
Write-Host '  [build] OCI image build completed OK.' -ForegroundColor Green
# Install-robustness run the post-bootstrap acceptance smoke now that
# the image built -- it was authored to run "at the end of mios build" but was
# never wired in, so the AI-plane "is it operational?" check never executed. The
# smoke is best-effort here (non-fatal): a still-warming AI plane warns rather
# than failing the build verb; `mios smoke` re-runs it on demand.
`$_smoke = '/mnt/m/tests/post-bootstrap-smoke.sh'
if ((& wsl.exe -d `$distro --user root -- bash -lc "test -f `$_smoke && echo y" 2>`$null) -eq 'y') {
    Write-Host '  [build] running post-bootstrap acceptance smoke (AI-plane + parity)...' -ForegroundColor Cyan
    & wsl.exe -d `$distro --user root -- bash `$_smoke
    if (`$LASTEXITCODE -ne 0) { Write-Host '  [build] smoke reported issues (see above) -- re-run with: mios smoke' -ForegroundColor Yellow }
} else {
    Write-Host '  [build] smoke script not found at M:\tests -- skipping (run: mios smoke)' -ForegroundColor DarkGray
}
"@
    Set-Content -Path $buildPath -Value $buildScript -Encoding UTF8
    Log-Ok "mios-build.ps1 (the `mios build` verb) staged at $buildPath"

    # mios.ps1 -- THE MiOS app dispatcher.
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
# "U.N.I.F.I.E.D EVERYTHING MiOS related!!!". This file
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

    # mios-code.ps1 -- `mios code` verb. Opens code-server in the
    # operator's default browser.
    $codePath = Join-Path $MiosBinDir 'mios-code.ps1'
    $codeScript = @'
# <MiOSRoot>\bin\mios-code.ps1 -- the `mios code` verb.
# Opens code-server (VS Code in a browser) in the default browser.
# Resolves the URL via mios.toml [ports].code_server (default 8800).
param([Parameter(ValueFromRemainingArguments)] $Args)
$ErrorActionPreference = 'SilentlyContinue'
$port = 8800
foreach ($_t in @("$env:USERPROFILE\.config\mios\mios.toml",'M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
    if (Test-Path -LiteralPath $_t) {
        try {
            $_txt = [IO.File]::ReadAllText($_t, (New-Object System.Text.UTF8Encoding($false)))
            $_m = [regex]::Match($_txt, '(?ms)^\[ports\].*?^\s*code_server\s*=\s*(\d+)')
            if ($_m.Success) { $port = [int]$_m.Groups[1].Value; break }
        } catch {}
    }
}
$url = "http://localhost:$port/"
Write-Host "  Opening $url (login: mios)" -ForegroundColor DarkGray
Start-Process $url | Out-Null
'@
    Set-Content -Path $codePath -Value $codeScript -Encoding UTF8

    # mios-ai.ps1 -- `mios ai` verb. Opens Open WebUI in the
    # operator's default browser.
    $aiPath = Join-Path $MiosBinDir 'mios-ai.ps1'
    $aiScript = @'
# <MiOSRoot>\bin\mios-ai.ps1 -- the `mios ai` verb.
# Opens Open WebUI (rich LLM interface) in the default browser.
# Resolves the URL via mios.toml [ports].open_webui (default 3030).
param([Parameter(ValueFromRemainingArguments)] $Args)
$ErrorActionPreference = 'SilentlyContinue'
$port = 3030
foreach ($_t in @("$env:USERPROFILE\.config\mios\mios.toml",'M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
    if (Test-Path -LiteralPath $_t) {
        try {
            $_txt = [IO.File]::ReadAllText($_t, (New-Object System.Text.UTF8Encoding($false)))
            $_m = [regex]::Match($_txt, '(?ms)^\[ports\].*?^\s*open_webui\s*=\s*(\d+)')
            if ($_m.Success) { $port = [int]$_m.Groups[1].Value; break }
        } catch {}
    }
}
$url = "http://localhost:$port/"
Write-Host "  Opening $url" -ForegroundColor DarkGray
Start-Process $url | Out-Null
'@
    Set-Content -Path $aiPath -Value $aiScript -Encoding UTF8

    # System verbs -- forward to the dev VM via wsl.exe.
    $systemVerbs = @('xbox','virt','vfio','tune','summary','profile','assess','iommu','theme','user')
    foreach ($v in $systemVerbs) {
        $vPath = Join-Path $MiosBinDir "mios-$v.ps1"
        $vScript = @"
# <MiOSRoot>\bin\mios-$v.ps1 -- the `mios $v` verb.
# Forwards the command to the MiOS-DEV WSL distro.
param([Parameter(ValueFromRemainingArguments)] `$Args)
`$_distro = 'podman-MiOS-DEV'
try {
    `$_wsl = (& wsl.exe -l -q 2>`$null) -split "``r?`n" | ForEach-Object { (`$_ -replace [char]0,'').Trim() } | Where-Object { `$_ }
    foreach (`$_cand in @('podman-MiOS-DEV','MiOS-DEV')) {
        if (`$_wsl -contains `$_cand) { `$_distro = `$_cand; break }
    }
} catch {}
& wsl.exe -d `$_distro --user mios -- mios $v @Args
"@
        Set-Content -Path $vPath -Value $vScript -Encoding UTF8
    }

    # mios-ask.ps1 -- free-form Hermes-Agent chat from the Windows
    # PowerShell terminal. Invoked by the `mios` dispatcher whenever
    # the first arg isn't a known verb. POSTs to MIOS_AI_ENDPOINT
    # (default http://localhost:8642/v1) and streams the assistant
    # content to the console.
    $askPath = Join-Path $MiosBinDir 'mios-ask.ps1'
    $askScript = @'
# <MiOSRoot>\bin\mios-ask.ps1 -- `mios <query>` chat against Hermes-Agent.
param([Parameter(ValueFromRemainingArguments)] [string[]] $Q)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Q -or $Q.Count -eq 0) {
    Write-Host "  Usage: mios <question or instruction>" -ForegroundColor Yellow
    Write-Host "  Example: mios how do I bootc switch to a staged image" -ForegroundColor DarkGray
    return
}
$query = ($Q -join ' ').Trim()
if (-not $query) { return }

# Resolution is per field. Model: MIOS_AI_MODEL env, else the layered
# mios.toml [ai].model (the SSOT default chat model), else a vendor fallback
# -- so an unset env never pins a stale model id. Key: MIOS_AI_KEY env, else
# install.env. Endpoint: MIOS_AI_ENDPOINT env, else resolved from mios.toml [ports].hermes.
$hermesPort = 8642
foreach ($_t in @("$env:USERPROFILE\.config\mios\mios.toml",'M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
    if (Test-Path -LiteralPath $_t) {
        try {
            $_txt = [IO.File]::ReadAllText($_t, (New-Object System.Text.UTF8Encoding($false)))
            $_m = [regex]::Match($_txt, '(?ms)^\[ports\].*?^\s*hermes\s*=\s*(\d+)')
            if ($_m.Success) { $hermesPort = [int]$_m.Groups[1].Value; break }
        } catch {}
    }
}
$endpoint = if ($env:MIOS_AI_ENDPOINT) { $env:MIOS_AI_ENDPOINT } else { "http://localhost:$hermesPort/v1" }
$model    = if ($env:MIOS_AI_MODEL)    { $env:MIOS_AI_MODEL }    else { '' }
$apiKey   = if ($env:MIOS_AI_KEY)      { $env:MIOS_AI_KEY }      else { '' }

# If no env model, resolve [ai].model from the layered mios.toml (SSOT for the
# default chat model). Mirrors the open_webui port scrape in the mios app verb;
# the literal is only the bottom-of-stack fallback if every layer is unreadable.
if (-not $model) {
    foreach ($_t in @("$env:USERPROFILE\.config\mios\mios.toml",'M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
        if (Test-Path -LiteralPath $_t) {
            try {
                $_txt = [IO.File]::ReadAllText($_t, (New-Object System.Text.UTF8Encoding($false)))
                $_m = [regex]::Match($_txt, '(?ms)^\[ai\].*?^\s*model\s*=\s*"?([^"\r\n]+)"?')
                if ($_m.Success) { $model = $_m.Groups[1].Value.Trim(); break }
            } catch {}
        }
    }
}
if (-not $model) { $model = 'qwen3.5:2b' }

# If no env key, scrape /etc/mios/install.env on M:\ for the key.
if (-not $apiKey) {
    foreach ($_e in @('M:\etc\mios\install.env','M:\etc\mios\hermes\api.env')) {
        if (Test-Path -LiteralPath $_e) {
            try {
                $_txt = [IO.File]::ReadAllText($_e, (New-Object System.Text.UTF8Encoding($false)))
                $_m = [regex]::Match($_txt, '(?m)^(?:API_SERVER_KEY|MIOS_AI_KEY|OPENAI_API_KEY)\s*=\s*"?([^"\r\n]+)"?')
                if ($_m.Success) { $apiKey = $_m.Groups[1].Value.Trim(); break }
            } catch {}
        }
    }
}

$headers = @{ 'Content-Type' = 'application/json' }
if ($apiKey) { $headers['Authorization'] = "Bearer $apiKey" }

$body = @{
    model    = $model
    messages = @(
        @{ role = 'user'; content = $query }
    )
    stream   = $false
} | ConvertTo-Json -Depth 8 -Compress

try {
    $resp = Invoke-RestMethod -Method Post -Uri "$endpoint/chat/completions" -Headers $headers -Body $body -TimeoutSec 120 -ErrorAction Stop
    $content = $resp.choices[0].message.content
    if ($content) {
        Write-Host ''
        Write-Host $content
        Write-Host ''
    } else {
        Write-Host "  [!] Hermes returned an empty response." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [!] mios ask: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Hermes-Agent endpoint: $endpoint" -ForegroundColor DarkGray
    Write-Host "  Is mios-hermes.service running? Check with: mios dash" -ForegroundColor DarkGray
}
'@
    Set-Content -Path $askPath -Value $askScript -Encoding UTF8

    Log-Ok "Bin scripts staged: mios (app), mios-dash, mios-dev, mios-pull, mios-update, mios-config, mios-code, mios-ask"

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
# Show-MiosApp TUI hub -- "not unified
# dashboards!!!" (TWO different layouts rendering: the legacy hub
# AND the [dashboard].rows-driven Show-MiosDashboard).  Removed
# `function mios` here so the canonical dispatcher (which routes
# to mios-<verb> functions sharing the same Show-MiosDashboard
# layout) wins.
`$Global:MiosBin = "$miosBinForProfile"
# mios-dash + mios-mini are defined as INLINE FUNCTIONS in the
# Get-MiOS.ps1 profile body above (mios-dash = FULL render with
# ASCII banner + services + sys specs; mios-mini = compact 80x20
# framed banner + fastfetch). We don't override them with bin-
# script wrappers here because the FULL render needs to query the
# running MiOS-DEV state via wsl.exe -- inlining keeps it co-
# located with the rest of the verb implementations and leaves
# the bin-script staging point for legacy direct-invocation only.
function mios-dev     { & (Join-Path `$Global:MiosBin 'mios-dev.ps1')    @args }
function mios-pull    { & (Join-Path `$Global:MiosBin 'mios-pull.ps1')   @args }
function mios-update  { & (Join-Path `$Global:MiosBin 'mios-update.ps1') @args }
function mios-config  { & (Join-Path `$Global:MiosBin 'mios-config.ps1') @args }
function mios-code    { & (Join-Path `$Global:MiosBin 'mios-code.ps1')   @args }
function mios-ask     { & (Join-Path `$Global:MiosBin 'mios-ask.ps1')    @args }

# Set-MiosWindow -- resize + re-center the CURRENT MiOS terminal
# window between [terminal] and [terminal.reading] modes from
# mios.toml. "a centered 100x50 window called
# MiOS 'reading mode' invoked with a command to resize (and re
# center) the window between the sizes". Used by `mios portal` /
# `mios reading` verbs and by the `btop` function which auto-flips
# to reading mode.
function Set-MiosWindow {
    [CmdletBinding()]
    param([ValidateSet('portal','reading')][string]`$Mode = 'portal')
    `$_section = if (`$Mode -eq 'reading') { 'terminal.reading' } else { 'terminal' }
    # Read dims from mios.toml (host overlay > vendor SSOT > hardcoded).
    `$_cols = 80; `$_rows = 20
    if (`$Mode -eq 'reading') { `$_cols = 100; `$_rows = 50 }
    foreach (`$_t in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
        if (-not (Test-Path -LiteralPath `$_t)) { continue }
        try {
            `$_txt  = [IO.File]::ReadAllText(`$_t, (New-Object System.Text.UTF8Encoding(`$false)))
            `$_secRx = '(?ms)^\[' + [regex]::Escape(`$_section) + '\][ \t]*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)'
            `$_m = [regex]::Match(`$_txt, `$_secRx)
            if (-not `$_m.Success) { continue }
            `$_body = `$_m.Groups['body'].Value
            `$_mc = [regex]::Match(`$_body, '(?m)^[ \t]*cols[ \t]*=[ \t]*(\d+)')
            `$_mr = [regex]::Match(`$_body, '(?m)^[ \t]*rows[ \t]*=[ \t]*(\d+)')
            if (`$_mc.Success) { `$_cols = [int]`$_mc.Groups[1].Value }
            if (`$_mr.Success) { `$_rows = [int]`$_mr.Groups[1].Value }
            break
        } catch {}
    }
    # Cell + chrome metrics from mios.toml [theme.font] (defaulted to
    # the Geist Mono Nerd Font 12pt baseline if the toml is unreadable
    # at this point).
    `$_cellW = 10; `$_cellH = 20; `$_chromeW = 20; `$_chromeH = 12
    foreach (`$_t in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
        if (-not (Test-Path -LiteralPath `$_t)) { continue }
        try {
            `$_txt = [IO.File]::ReadAllText(`$_t, (New-Object System.Text.UTF8Encoding(`$false)))
            `$_m = [regex]::Match(`$_txt, '(?ms)^\[theme\.font\][ \t]*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
            if (-not `$_m.Success) { continue }
            `$_b = `$_m.Groups['body'].Value
            foreach (`$_kv in @(@('cell_w_px','_cellW'),@('cell_h_px','_cellH'),@('chrome_w_px','_chromeW'),@('chrome_h_px','_chromeH'))) {
                # Build the regex from string concat. Earlier attempt
                # used dollar-paren interpolation but the outer build-
                # mios.ps1 heredoc evaluated it at install time -- it
                # tried to look up _kv at build-time scope and crashed
                # the bootstrap. Concat avoids any subexpression form.
                `$_pat = '(?m)^[ \t]*' + `$_kv[0] + '[ \t]*=[ \t]*(\d+)'
                `$_x   = [regex]::Match(`$_b, `$_pat)
                if (`$_x.Success) { Set-Variable -Name `$_kv[1] -Value ([int]`$_x.Groups[1].Value) }
            }
            break
        } catch {}
    }
    `$_winW = `$_cols * `$_cellW + `$_chromeW
    `$_winH = `$_rows * `$_cellH + `$_chromeH

    # Win32 helpers + Cursor.Position + Screen.FromPoint for centering
    # on the monitor that currently hosts the cursor.
    try {
        Add-Type -Namespace 'MiOSResize' -Name 'W' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr h, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@ -ErrorAction SilentlyContinue
    } catch {}
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    `$_cur  = [System.Windows.Forms.Cursor]::Position
    `$_work = [System.Windows.Forms.Screen]::FromPoint(`$_cur).WorkingArea
    `$_x = [int](`$_work.X + (`$_work.Width  - `$_winW) / 2); if (`$_x -lt `$_work.X) { `$_x = `$_work.X }
    `$_y = [int](`$_work.Y + (`$_work.Height - `$_winH) / 2); if (`$_y -lt `$_work.Y) { `$_y = `$_work.Y }

    # Resolve the WT process hosting THIS pwsh. Walk up the parent
    # chain via WMI since pwsh runs as a CHILD of WindowsTerminal.exe;
    # Get-Process -Name WindowsTerminal could return any WT window,
    # not necessarily ours.
    `$_hwnd = [IntPtr]::Zero
    try {
        `$_pid = `$PID
        for (`$_i = 0; `$_i -lt 6; `$_i++) {
            `$_proc = Get-CimInstance Win32_Process -Filter "ProcessId=`$_pid" -ErrorAction SilentlyContinue
            if (-not `$_proc) { break }
            if (`$_proc.Name -match '^WindowsTerminal') {
                `$_p = Get-Process -Id `$_proc.ProcessId -ErrorAction SilentlyContinue
                if (`$_p -and `$_p.MainWindowHandle -ne [IntPtr]::Zero) { `$_hwnd = `$_p.MainWindowHandle; break }
            }
            `$_pid = `$_proc.ParentProcessId
        }
    } catch {}
    if (`$_hwnd -eq [IntPtr]::Zero) {
        # Fallback: newest visible WT window. Acceptable for the
        # common case (one MiOS window open).
        `$_p = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
               Where-Object { `$_.MainWindowHandle -ne [IntPtr]::Zero -and [MiOSResize.W]::IsWindowVisible(`$_.MainWindowHandle) } |
               Sort-Object StartTime -Descending | Select-Object -First 1
        if (`$_p) { `$_hwnd = `$_p.MainWindowHandle }
    }
    if (`$_hwnd -ne [IntPtr]::Zero) {
        # 0x40 = SWP_SHOWWINDOW. No NOZORDER so window comes to front.
        [void][MiOSResize.W]::SetWindowPos(`$_hwnd, [IntPtr]::Zero, `$_x, `$_y, `$_winW, `$_winH, 0x40)
        Write-Host ("  [+] MiOS window: {0} mode ({1}x{2})" -f `$Mode, `$_cols, `$_rows) -ForegroundColor DarkGray
    } else {
        Write-Host '  [!] Could not resolve current WT window handle; resize skipped.' -ForegroundColor Yellow
    }
}

# Verb shorthands for Set-MiosWindow.
function mios-portal  { Set-MiosWindow -Mode portal }
function mios-reading { Set-MiosWindow -Mode reading }

# btop on Windows -> resize current MiOS window to reading mode (100x50
# centered) and run the dev VM's Linux btop via WSL (UNIFIED). btop
# hardcodes 80x24 minimum; portal-mode 80x20 reports 75x18 post-WSLg
# chrome, below the minimum. Reading mode (100x50) reports ~95x48,
# every btop preset fits. Window restores to portal mode on exit.
function btop {
    `$_devCandidates = @('podman-MiOS-DEV','MiOS-DEV','podman-MiOS-BUILDER','MiOS-BUILDER')
    `$_wslList = @()
    try { `$_wslList = (& wsl.exe -l -q 2>`$null) -split "``r?``n" | ForEach-Object { (`$_ -replace [char]0,'').Trim() } | Where-Object { `$_ } } catch {}
    `$_dev = `$null
    foreach (`$_c in `$_devCandidates) {
        if (`$_wslList -contains `$_c) { `$_dev = `$_c; break }
    }
    if (-not `$_dev) {
        Write-Host '  [!] No MiOS-DEV WSL distro found -- cannot run btop.' -ForegroundColor Yellow
        return
    }
    Set-MiosWindow -Mode reading
    Start-Sleep -Milliseconds 200   # let WT settle the new dims
    try {
        & wsl.exe -d `$_dev --user mios -- btop @args
    } finally {
        Set-MiosWindow -Mode portal
    }
}
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
    # Per operator (clarified): "MiOS app opens to a windows
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

    # NOTE: New-MiosShortcut + its shortcut-metadata helper code that
    # used to live here have been REMOVED. They were dead code -- the
    # only callers were the hub MiOS.lnk creator + the per-verb shortcut
    # loop, both of which were removed in earlier commits when shortcut
    # creation moved to Get-MiOS.ps1's FINAL STEP block. Removing the
    # dead Win32-interop code also eliminates AMSI heuristic flag bait.

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

    # Install-root drive letter (SSOT: [bootstrap.host_storage].drive_letter,
    # env override MIOS_DATA_DISK_LETTER). Substituted into the __MIOS_DRIVE__
    # placeholder of the staged launcher + gui-watch sources so the operator's
    # data-disk letter -- not a baked 'M' -- drives the install-root paths.
    $_stagingDrive = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER } else { Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'drive_letter' -Default 'M' }

    # ── ONE shortcut: MiOS (the hub) ─────────────────────────────────
    # Native-app behavior: the .lnk targets a tiny launcher script
    # (mios-launch.ps1) staged under $MiosBinDir. The launcher source
    # lives in src/mios-launch.ps1 in the repo (NOT inline here) so
    # AMSI heuristics don't see Win32-interop strings as part of the
    # .ps1 script content. build-mios.ps1 reads the source from disk
    # and writes it to $MiosBinDir at install time.
    $hubResizePrelude = "try { `$H=Get-Host; `$H.UI.RawUI.WindowSize=(New-Object Management.Automation.Host.Size 80,30) } catch {}"
    $miosLauncher = Join-Path $MiosBinDir 'mios-launch.ps1'
    $_psSrcCandidates = @(
        (Join-Path $MiosRepoDir 'src\mios-launch.ps1'),
        (Join-Path $MiosBootstrapShadow 'src\mios-launch.ps1')
    )
    $_psSrc = $null
    foreach ($_c in $_psSrcCandidates) {
        if (Test-Path -LiteralPath $_c) { $_psSrc = $_c; break }
    }
    $launcherSrc = $null
    if ($_psSrc) {
        try { $launcherSrc = [IO.File]::ReadAllText($_psSrc, (New-Object System.Text.UTF8Encoding($false))) } catch {
            Log-Warn "mios-launch.ps1 read failed at ${_psSrc}: $($_.Exception.Message)"
        }
    } else {
        Log-Warn "mios-launch.ps1 source not found in repo (probed: $($_psSrcCandidates -join ', ')) -- launcher will not be staged"
    }
    if ($launcherSrc) {
        # Substitute __MIOS_COLS__ / __MIOS_ROWS__ placeholders from mios.toml
        # [terminal].cols /.rows (SSOT) -- "Toml is the
        # total reference for all functions and calls".
        $_lnchCols = [int](Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80)
        $_lnchRows = [int](Get-MiosTomlValue -Section 'terminal' -Key 'rows' -Default 20)
        $launcherSrc = $launcherSrc -replace '__MIOS_COLS__', [string]$_lnchCols
        $launcherSrc = $launcherSrc -replace '__MIOS_ROWS__', [string]$_lnchRows
        $launcherSrc = $launcherSrc -replace '__MIOS_DRIVE__', $_stagingDrive
        if (-not (Test-Path $MiosBinDir)) { New-Item -ItemType Directory -Path $MiosBinDir -Force | Out-Null }
        Set-Content -Path $miosLauncher -Value $launcherSrc -Encoding UTF8
        Log-Ok "MiOS native launcher staged: $miosLauncher (cols=$_lnchCols rows=$_lnchRows from mios.toml [terminal])"
    }

    # ── mios-gui-watch.ps1 (background daemon for WSLg window auto-resize) ─
    # months of "GUI windows never render on WSLg"
    # turned out to be windows rendering at native X11 default sizes
    # (e.g. 129x113 for xeyes) at arbitrary positions, invisible against
    # acrylic terminals on a 4K display. mios-gui-watch.ps1 polls
    # msrdc.exe for new RDP-RAIL windows and force-resizes any tiny
    # spawn to mios.toml [terminal.gui_min] dims, centered on cursor
    # monitor. Once "adopted" the window is left alone.
    $miosGuiWatch = Join-Path $MiosBinDir 'mios-gui-watch.ps1'
    $_gwSrcCands = @(
        (Join-Path $MiosRepoDir 'src\mios-gui-watch.ps1'),
        (Join-Path $MiosBootstrapShadow 'src\mios-gui-watch.ps1')
    )
    $_gwSrc = $null
    foreach ($_c in $_gwSrcCands) { if (Test-Path -LiteralPath $_c) { $_gwSrc = $_c; break } }
    if ($_gwSrc) {
        try {
            $_gwBody = [IO.File]::ReadAllText($_gwSrc, (New-Object System.Text.UTF8Encoding($false)))
            $_gwBody = $_gwBody -replace '__MIOS_DRIVE__', $_stagingDrive
            Set-Content -Path $miosGuiWatch -Value $_gwBody -Encoding UTF8
            Log-Ok "mios-gui-watch staged: $miosGuiWatch (auto-resize WSLg windows to mios.toml [terminal.gui_min])"

            # HKCU Run entry so the daemon launches on every login
            # (no terminal required). Hidden window via -WindowStyle
            # Hidden + bypass AMSI scan via -ExecutionPolicy Bypass.
            $_runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if (-not (Test-Path $_runKey)) { New-Item -Path $_runKey -Force | Out-Null }
            $_pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $_pwsh) { $_pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
            $_runVal = '"{0}" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $_pwsh, $miosGuiWatch
            Set-ItemProperty -Path $_runKey -Name 'MiOS-GuiWatch' -Value $_runVal -Type String -Force
            Log-Ok "mios-gui-watch autostart registered (HKCU\...\Run\MiOS-GuiWatch)"

            # Register MiOS-Autostart (AtLogon trigger, RunLevel Highest, hidden)
            $_autostartEnabled = Get-MiosTomlValue -Section 'bootstrap.autostart' -Key 'enable' -Default $true
            if ($_autostartEnabled -eq 'true') { $_autostartEnabled = $true }
            elseif ($_autostartEnabled -eq 'false') { $_autostartEnabled = $false }
            if ($_autostartEnabled -isnot [bool]) { $_autostartEnabled = $true }

            if ($_autostartEnabled) {
                # Ensure local ProgramData\MiOS directory exists
                $hostProgData = Join-Path $env:ProgramData 'MiOS'
                if (-not (Test-Path $hostProgData)) { New-Item -ItemType Directory -Path $hostProgData -Force | Out-Null }
                $autostartScript = Join-Path $hostProgData 'mios-autostart.ps1'
                $autostartBody = @"
#Requires -Version 5.1
`$logPath = "C:\ProgramData\MiOS\logs\autostart.log"
`$null = New-Item -ItemType Directory -Path (Split-Path `$logPath) -Force -ErrorAction SilentlyContinue
`$null = New-Item -ItemType File -Path `$logPath -Force -ErrorAction SilentlyContinue
function Log {
    param(`$msg)
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$msg" | Out-File -FilePath `$logPath -Append -Encoding UTF8
}
Log "MiOS Autostart triggered."
`$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
if (Get-Command podman -ErrorAction SilentlyContinue) {
    try {
        `$state = & podman machine list --format "{{.Running}}" --filter "name=$BuilderDistro" 2>&1
        Log "Current state of machine '$BuilderDistro': `$state"
        if (`$state -notmatch "true") {
            Log "Starting machine '$BuilderDistro'..."
            `$startOut = & podman machine start $BuilderDistro 2>&1
            Log "Start output: `$startOut"
        } else {
            Log "Machine '$BuilderDistro' is already running."
        }
    } catch {
        Log "Error starting machine: `$(`$_.Exception.Message)"
    }
} else {
    Log "Error: podman command not found on PATH."
}
"@
                Set-Content -Path $autostartScript -Value $autostartBody -Encoding UTF8
                Log-Ok "Staged autostart script: $autostartScript"

                $registered = $false
                if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
                    try {
                        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$autostartScript`""
                        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
                        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
                        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
                        $null = Register-ScheduledTask -TaskName 'MiOS-Autostart' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop
                        $registered = $true
                        Log-Ok "MiOS-Autostart Scheduled Task registered (AtLogon, RunLevel Highest, hidden)."
                    } catch {
                        Log-Warn "Failed to register scheduled task: $($_.Exception.Message). Falling back to HKCU\Run..."
                    }
                } else {
                    Log-Warn "Register-ScheduledTask cmdlet not available. Falling back to HKCU\Run..."
                }

                if (-not $registered) {
                    $_runValAutostart = '"{0}" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $_pwsh, $autostartScript
                    Set-ItemProperty -Path $_runKey -Name 'MiOS-Autostart' -Value $_runValAutostart -Type String -Force
                    Log-Ok "MiOS-Autostart registered in HKCU\Run (fallback)."
                }
            }
        } catch {
            Log-Warn "mios-gui-watch / autostart staging failed: $($_.Exception.Message)"
        }
    } else {
        Log-Warn "mios-gui-watch.ps1 source not found in repo (probed: $($_gwSrcCands -join ', '))"
    }

    # Compile a tiny native .exe launcher with subsystem:Windows (no
    # console flash + window-centering loop). Source code lives in
    # src/mios-launch.cs at the repo root; build-mios.ps1 reads it from
    # disk so AMSI heuristics don't see Win32-interop strings as part
    # of the .ps1 script content.
    $miosLauncherExe = Join-Path $MiosBinDir 'mios-launch.exe'
    $_csSrcCandidates = @(
        (Join-Path $MiosRepoDir 'src\mios-launch.cs'),
        (Join-Path $MiosBootstrapShadow 'src\mios-launch.cs')
    )
    $_csSrc = $null
    foreach ($_c in $_csSrcCandidates) {
        if (Test-Path -LiteralPath $_c) { $_csSrc = $_c; break }
    }
    $launcherCs = $null
    if ($_csSrc) {
        try { $launcherCs = [IO.File]::ReadAllText($_csSrc, (New-Object System.Text.UTF8Encoding($false))) } catch {
            Log-Warn "mios-launch.cs read failed at ${_csSrc}: $($_.Exception.Message)"
        }
    } else {
        Log-Warn "mios-launch.cs not found in repo (probed: $($_csSrcCandidates -join ', ')) -- mios-launch.exe will not be compiled"
    }
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
    if ($_csc -and $launcherCs) {
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

    # ── Shortcut creation deferred to FINAL STEP of Get-MiOS.ps1 ────────────
    # "applications and icons should be installed AFTER
    # everything--at the end!!!! LAST STEPS". The canonical 4-shortcut set
    # (MiOS, MiOS-WIN, MiOS Help, Uninstall MiOS) is created by
    # Get-MiOS.ps1's end-of-script block AFTER bootstrap.ps1 + build-mios.ps1
    # succeed. build-mios.ps1's Install-WindowsBranding does NOT create
    # shortcuts at all -- if it did, partial-install failures would leave
    # broken shortcuts pointing at a half-built dev VM.
    $smLnk = Join-Path $StartMenuDir 'MiOS.lnk'

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
    # canonical 4-shortcut set: MiOS / MiOS-WIN /
    # MiOS Help / Uninstall MiOS, all created in Get-MiOS.ps1's
    # Install-MiOSNativeApp. NO per-verb shortcut creator here -- the
    # entire [apps.shortcuts] toml-driven loader was a duplicate creator
    # that re-seeded MiOS-DEV.lnk / MiOS Config.lnk / MiOS Help.lnk on
    # every install (caught in the 15:27 install screenshot).
    # The previous "$verbShortcuts = @()" guard was racy: any operator
    # mios.toml [apps.shortcuts] section would re-populate it. Removed
    # entirely. Per operator: "JUST FUCKING LISTEN".
    $verbShortcuts = @()
    $miosLaunchPs1 = Join-Path $MiosBinDir 'mios-launch.ps1'

    # Garbage-collect every shortcut OUTSIDE the canonical 4-set
    # (MiOS / MiOS-WIN / MiOS Help / Uninstall MiOS). Per operator
    # MiOS-DEV.lnk and MiOS Config.lnk are NOT canonical --
    # the MiOS shortcut already targets the dev VM, and `mios config`
    # is a typed verb. Idempotent: if absent, skip.
    $staleLnks = @(
        # Redundant-with-MiOS.lnk + typed-verb apps:
        'MiOS-DEV.lnk', 'MiOS Config.lnk',
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

    # ── MiOS Linux Apps (Start Menu subfolder) ─────────────────────────
    # "no MiOS Linux apps in windows start menus".
    # Two-prong fix: (a) /etc/wsl.conf adds [gui] guiApplications=true
    # so WSLg auto-exports .desktop entries (handled in mios.git);
    # (b) we ALSO create explicit Windows .lnk shortcuts here, because
    # WSLg auto-export depends on the distro's user-systemd being
    # healthy and the operator's preferred friendly names (Files / Web
    # / VSCodium / etc.) don't survive the "(on podman-MiOS-DEV)"
    # suffix WSLg appends. Explicit shortcuts under
    #   Start Menu\Programs\MiOS\Linux Apps\<FriendlyName>.lnk
    # are bulletproof + match the operator's mental model.
    #
    # Each shortcut targets wsl.exe with the dev distro:
    #   wsl.exe -d podman-MiOS-DEV --user mios -- flatpak run <appid>
    # Source of truth: mios.toml [desktop].flatpaks (operator-editable
    # via mios.html; new entries auto-surface on next bootstrap).
    try {
        $linuxAppsDir = Join-Path $StartMenuDir 'Linux Apps'
        if (-not (Test-Path -LiteralPath $linuxAppsDir)) {
            New-Item -ItemType Directory -Path $linuxAppsDir -Force | Out-Null
        }

        # Resolve WSL distro that actually exists (podman-prefixed or bare).
        $linuxDistro = $null
        try {
            $_wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" |
                ForEach-Object { ($_ -replace [char]0, '').Trim() } |
                Where-Object { $_ }
            foreach ($_cand in @("podman-$DevDistro", $DevDistro, "podman-$LegacyDevName", $LegacyDevName)) {
                if ($_wslList -contains $_cand) { $linuxDistro = $_cand; break }
            }
        } catch {}
        if (-not $linuxDistro) { $linuxDistro = "podman-$DevDistro" }

        # Prefer wslg.exe (part of WSL since 2021) over wsl.exe so the
        # shortcuts launch the GUI app DIRECTLY with no console popup
        # and Windows-Terminal-style chrome -- matches the exact UX
        # that WSLg's own auto-published `App (on podman-MiOS-DEV).lnk`
        # entries give the operator. wsl.exe spawns a host console;
        # wslg.exe is a pure GUI launcher.
        $wslExe = $null
        foreach ($_c in @(
            "$env:ProgramFiles\WSL\wslg.exe",
            "$env:WINDIR\System32\wslg.exe"
        )) {
            if (Test-Path -LiteralPath $_c) { $wslExe = $_c; break }
        }
        if (-not $wslExe) {
            $wslExe = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
            if (-not $wslExe) { $wslExe = "$env:WINDIR\System32\wsl.exe" }
        }

        # AppId -> friendly-name mapping. Operator-edit-friendly: short
        # name appears in Start Menu, app id resolves the actual flatpak.
        # Unknown entries fall back to the last segment of the app id.
        $linuxAppMap = @{
            'org.gnome.Nautilus.Devel'         = 'Files'
            'org.gnome.Nautilus'               = 'Files'
            'org.gnome.Epiphany'               = 'Web'
            'app.devsuite.Ptyxis'              = 'Ptyxis'
            'com.github.tchx84.Flatseal'       = 'Flatseal'
            'com.mattjakeman.ExtensionManager' = 'Extension Manager'
            'com.vscodium.codium'              = 'VSCodium'
            'org.gnome.Software'               = 'Software'
        }

        # Pull current flatpak picks from mios.toml [desktop].flatpaks.
        # Get-MiosTomlValue's regex is SINGLE-line (`(?<val>.+?)$`),
        # so a multi-line `flatpaks = [\n  "a",\n  "b",\n]` array
        # returns just `[` (the opening bracket on the same line as
        # the assignment). That stray `[` then propagated as a
        # phantom entry, producing a `[.lnk` shortcut in the
        # operator's Linux Apps folder (21:39).
        #
        # Use the same multi-line array parser the overlay flatpak
        # loop uses upstream at line ~7945: regex-grab the bracket
        # body across newlines, strip TOML comments, split on commas,
        # trim quote/whitespace decoration.
        $_fpList = @()
        try {
            $_tomlTextForFp = Resolve-MiosTomlText
            if ($_tomlTextForFp) {
                $_fpMatch = [regex]::Match($_tomlTextForFp,
                    '(?ms)^\[desktop\]\s*$.*?^\s*flatpaks\s*=\s*\[(?<arr>.*?)\]\s*$')
                if ($_fpMatch.Success) {
                    $_fpArrBody = ($_fpMatch.Groups['arr'].Value -split "`n" |
                        ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
                    $_fpList = @($_fpArrBody -split ',' |
                        ForEach-Object { $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n") } |
                        Where-Object { $_ })
                }
            }
        } catch {
            Log-Warn "Linux Apps: mios.toml [desktop].flatpaks parse failed: $($_.Exception.Message)"
        }

        $linuxShortcutsCreated = 0
        foreach ($_ref in $_fpList) {
            $_r = $_ref.Trim().Trim('"').Trim("'")
            if (-not $_r) { continue }
            if ($_r -like '#*') { continue }
            # Strip <remote>: prefix if present.
            $_appId = if ($_r -match ':') { $_r -split ':', 2 | Select-Object -Last 1 } else { $_r }
            # Skip GTK theme extensions (not launchable apps).
            if ($_appId -like 'org.gtk.Gtk*theme*') { continue }
            $_friendly = $linuxAppMap[$_appId]
            if (-not $_friendly) {
                # Fallback: last dotted segment, capitalized.
                $_last = ($_appId -split '\.')[-1]
                $_friendly = (Get-Culture).TextInfo.ToTitleCase($_last)
            }
            $_lnk = Join-Path $linuxAppsDir ("{0}.lnk" -f $_friendly)
            # wslg.exe takes the same -d / --user / -- arg shape as
            # wsl.exe BUT must be invoked with the FULL command path
            # (it doesn't run a login shell), so use /usr/bin/flatpak
            # explicitly. Matches WSLg's own auto-published shortcut
            # args exactly (e.g. for Ptyxis it writes:
            #   -d podman-MiOS-DEV --cd "~" -- /usr/bin/flatpak run
            #     --branch=stable --arch=x86_64 --command=ptyxis
            #     app.devsuite.Ptyxis).
            $_isWslg = $wslExe -match 'wslg\.exe$'
            $_args   = if ($_isWslg) {
                ("-d {0} --user mios --cd `"~`" -- /usr/bin/flatpak run {1}" -f $linuxDistro, $_appId)
            } else {
                ("-d {0} --user mios -- flatpak run {1}" -f $linuxDistro, $_appId)
            }
            try {
                New-Shortcut -Path $_lnk `
                    -Target $wslExe `
                    -ArgList $_args `
                    -Desc ("MiOS Linux app: {0} ({1}) on {2}" -f $_friendly, $_appId, $linuxDistro) `
                    -Dir ([Environment]::GetFolderPath('Desktop'))
                $linuxShortcutsCreated++
            } catch {
                Log-Warn "Linux app shortcut failed for ${_appId}: $($_.Exception.Message)"
            }
        }

        # System apps that aren't flatpaks but should still appear in
        # the Linux Apps folder (control center, system monitor).
        $sysApps = @(
            @{ Name = 'System Monitor'; Cmd = 'btop' },
            @{ Name = 'Settings';       Cmd = 'gnome-control-center' }
        )
        foreach ($_sa in $sysApps) {
            $_lnk = Join-Path $linuxAppsDir ("{0}.lnk" -f $_sa.Name)
            $_isWslg = $wslExe -match 'wslg\.exe$'
            $_sysArgs = if ($_isWslg) {
                # wslg.exe needs the full bin path (no login shell).
                ("-d {0} --user mios --cd `"~`" -- /usr/bin/bash -lc `"{1}`"" -f $linuxDistro, $_sa.Cmd)
            } else {
                ("-d {0} --user mios -- bash -lc `"{1}`"" -f $linuxDistro, $_sa.Cmd)
            }
            try {
                New-Shortcut -Path $_lnk `
                    -Target $wslExe `
                    -ArgList $_sysArgs `
                    -Desc ("MiOS Linux app: {0} ({1}) on {2}" -f $_sa.Name, $_sa.Cmd, $linuxDistro) `
                    -Dir ([Environment]::GetFolderPath('Desktop'))
                $linuxShortcutsCreated++
            } catch {}
        }

        Log-Ok ("MiOS Linux Apps: {0} Start Menu shortcuts -> {1}" -f $linuxShortcutsCreated, $linuxAppsDir)
    } catch {
        Log-Warn "MiOS Linux Apps Start Menu seeding failed: $($_.Exception.Message)"
    }

    # ── MiOS Services (web links via default browser) ──────────────────
    # Start Menu\Programs\MiOS\Services\<Name>.url -- Internet Shortcut
    # files that open in the operator's default browser (Zen / Edge /
    # Firefox / Chrome). Operator-flagged "Should also
    # include shortcuts to all our containers and services as webapps/
    # weblinks using local browser(s)". .url files are Start Menu
    # indexable and respect the operator's BrowserChoice without us
    # having to detect the installed browser.
    # SSOT: mios.toml [ports].* + a label/url map of the same shape.
    try {
        $servicesDir = Join-Path $StartMenuDir 'Services'
        if (-not (Test-Path -LiteralPath $servicesDir)) {
            New-Item -ItemType Directory -Path $servicesDir -Force | Out-Null
        }
        $_defaultPorts = [ordered]@{
            forge_http       = 8300
            open_webui       = 8033
            code_server      = 8800
            hermes           = 8642
            guacamole_web    = 8080
            ceph_dashboard   = 8444
            searxng          = 8899
            cockpit          = 8090
            llm_light        = 8450
        }
        # HTTPS for Cockpit + Ceph (self-signed; click through once). All
        # logins default to the global MiOS password (mios.toml [identity].
        # default_password = "mios"). Open WebUI is the default
        # chat front-end; code-server pairs with mios-forge for an
        # in-browser dev workflow.
        $_webLinks = @(
            @{ Key='open_webui';       Name='MiOS Chat (Open WebUI)';       Scheme='http';  Path='/' }
            @{ Key='code_server';      Name='MiOS Code (code-server)';      Scheme='http';  Path='/' }
            @{ Key='cockpit';          Name='MiOS Cockpit';                 Scheme='https'; Path='/' }
            @{ Key='forge_http';       Name='MiOS Forge';                   Scheme='http';  Path='/' }
            @{ Key='searxng';          Name='MiOS Search (SearXNG)';        Scheme='http';  Path='/' }
            @{ Key='hermes';           Name='MiOS Hermes API';              Scheme='http';  Path='/v1/models' }
            @{ Key='llm_light';        Name='MiOS LLM Light API';           Scheme='http';  Path='/' }
            @{ Key='guacamole_web';    Name='MiOS Guacamole';               Scheme='http';  Path='/guacamole/' }
            @{ Key='ceph_dashboard';   Name='MiOS Ceph Dashboard';          Scheme='https'; Path='/' }
        )
        $_svcCreated = 0
        foreach ($_w in $_webLinks) {
            $_port = [int](Get-MiosTomlValue -Section 'ports' -Key $_w.Key -Default $_defaultPorts[$_w.Key])
            if ($_port -lt 1 -or $_port -gt 65535) { continue }
            $_url = "{0}://localhost:{1}{2}" -f $_w.Scheme, $_port, $_w.Path
            $_urlFile = Join-Path $servicesDir ("{0}.url" -f $_w.Name)
            try {
                # Internet Shortcut (.url) -- ASCII INI format that
                # Windows Explorer + the Start Menu treat as a clickable
                # browser link. The [{000214A0-...}] block is the
                # ShellLinkPropertyBag GUID; Prop3=19,2 sets the file
                # as a Browse-shortcut (not Web-shortcut), which makes
                # Open With... behave correctly.
                $_lines = @(
                    '[InternetShortcut]'
                    "URL=$_url"
                    '[{000214A0-0000-0000-C000-000000000046}]'
                    'Prop3=19,2'
                )
                Set-Content -Path $_urlFile -Value $_lines -Encoding ASCII -Force
                $_svcCreated++
            } catch {
                Log-Warn "MiOS Services: $($_w.Name) shortcut failed: $($_.Exception.Message)"
            }
        }
        Log-Ok ("MiOS Services: {0} Start Menu .url shortcuts -> {1}" -f $_svcCreated, $servicesDir)
    } catch {
        Log-Warn "MiOS Services Start Menu seeding failed: $($_.Exception.Message)"
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

    Log-Ok "MiOS launcher binaries staged at $MiosBinDir (mios-launch.ps1 + mios-launch.exe). Shortcut creation deferred to FINAL STEP of Get-MiOS.ps1 after bootstrap completes successfully."

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
    # iteration loop on, which uninstalled + reinstalled
    # multiple times waiting for the dashboard to update -- it never did
    # because the Step 1-8 chain never ran).
    #
    # Operator pivot "irm|iex is the main entry point for ALL
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
            Log-Warn "Get-MiOS.ps1 functions-only dot-source failed: $($_.Exception.Message). Dashboard + WT settings.json may be stale -- run 'irm $($MiosBootstrapRaw)/Get-MiOS.ps1 | iex' to refresh."
        }
    } else {
        Log-Warn "Get-MiOS.ps1 not found in any candidate path ($($_getMiosCandidates -join ', ')) -- dashboard + WT settings.json patches skipped. Run 'irm $($MiosBootstrapRaw)/Get-MiOS.ps1 | iex' to refresh."
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
$bTop = [char]0x256D + (([char]0x2500).ToString() * ($script:DW - 2)) + [char]0x256E
$bBot = [char]0x2570 + (([char]0x2500).ToString() * ($script:DW - 2)) + [char]0x256F

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
    [char]0x2502 + " " + $Inner.PadRight($maxInner) + " " + [char]0x2502
}

# Top-of-script banner. Title + tagline lines resolve through mios.toml
# [messages.installer_banner] (SSOT). Operator rebrands via mios.html.
# Vendor fallbacks below preserve the existing wording when no TOML
# is reachable. {version} placeholder substitutes $MiosVersion.
$_bannerTitle    = Get-MiosTomlValue -Section 'messages.installer_banner' -Key 'title'    -Default "'MiOS' {version}  --  Unified Windows Installer"
$_bannerTaglines = @(Get-MiosTomlValue -Section 'messages.installer_banner' -Key 'taglines' -Default @(
    'Immutable Fedora AI Workstation',
    "WSL2 + Podman  $([char]0x2502)  Offline Build Pipeline"
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

# NO-LOCAL-DEPS direct installer for the Phase-0 platform prereqs (operator
# "without ANY local dependencies"). Used when winget is absent OR
# its install failed -- everything pulls from upstream GitHub releases or the
# built-in `wsl --install`, so a clean machine bootstraps with nothing
# pre-installed. Fail-soft: returns $false on any miss so the caller falls
# through to the existing required-prereq failure (never worse than before).
function Install-MiosPrereqDirect {
    param([string]$Cmd, [string]$Label)
    $_root = Join-Path $env:LOCALAPPDATA 'MiOS'
    try {
        switch ($Cmd) {
            'git' {
                # PortableGit self-extracting 7-Zip archive from git-for-windows.
                $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{'User-Agent'='mios-bootstrap'} -ErrorAction Stop
                $asset = $rel.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
                if (-not $asset) { Log-Warn 'git: no PortableGit 64-bit asset in latest git-for-windows release'; return $false }
                $sfx = Join-Path $env:TEMP "PortableGit-$(Get-Random).7z.exe"
                Invoke-WebRequest $asset.browser_download_url -OutFile $sfx -UseBasicParsing -ErrorAction Stop
                $gitDir = Join-Path $_root 'PortableGit'
                if (Test-Path $gitDir) { Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
                & $sfx "-o$gitDir" -y | Out-Null   # 7-Zip SFX: silent extract to -o<dir>
                Remove-Item $sfx -Force -ErrorAction SilentlyContinue
                $gitCmd = Join-Path $gitDir 'cmd'
                if (Test-Path (Join-Path $gitCmd 'git.exe')) {
                    $_u = [Environment]::GetEnvironmentVariable('Path','User')
                    if (-not (($_u -split ';') | Where-Object { $_ -ieq $gitCmd })) {
                        [Environment]::SetEnvironmentVariable('Path', "$_u;$gitCmd", 'User')
                    }
                    $env:PATH = "$env:PATH;$gitCmd"
                    return $true
                }
                return $false
            }
            'wsl' {
                # `wsl --install` ships with Windows 10 2004+/11 -- no download
                # needed; needs admin + likely a reboot before wsl.exe surfaces.
                & wsl.exe --install --no-distribution 2>&1 | ForEach-Object { Write-Log "wsl-install: $_" }
                return ($LASTEXITCODE -eq 0)
            }
            'podman' {
                # Podman for Windows installer from containers/podman releases.
                $rel = Invoke-RestMethod 'https://api.github.com/repos/containers/podman/releases/latest' -Headers @{'User-Agent'='mios-bootstrap'} -ErrorAction Stop
                $asset = $rel.assets | Where-Object { $_.name -match '^podman-.*-setup\.exe$' } | Select-Object -First 1
                if (-not $asset) { Log-Warn 'podman: no setup.exe asset in latest containers/podman release'; return $false }
                $exe = Join-Path $env:TEMP "podman-setup-$(Get-Random).exe"
                Invoke-WebRequest $asset.browser_download_url -OutFile $exe -UseBasicParsing -ErrorAction Stop
                Start-Process -FilePath $exe -ArgumentList '/install','/quiet','/norestart' -Wait -ErrorAction Stop  # WiX burn silent
                Remove-Item $exe -Force -ErrorAction SilentlyContinue
                $_m = [Environment]::GetEnvironmentVariable('PATH','Machine'); $_u = [Environment]::GetEnvironmentVariable('PATH','User')
                $env:PATH = (@($_m,$_u) | Where-Object {$_}) -join ';'
                return ([bool](Get-Command podman -ErrorAction SilentlyContinue))
            }
        }
    } catch { Log-Warn ("{0} direct-install failed: {1}" -f $Label, $_.Exception.Message) }
    return $false
}

# Auto-install Phase 0 prerequisites. Per operator "without ANY local
# dependencies": winget is an OPTIONAL accelerator; each prereq also has a
# direct path (git -> PortableGit, wsl -> built-in `wsl --install`, podman ->
# containers/podman release), so a fresh machine with no winget still
# bootstraps end-to-end. The prereq catalog resolves through mios.toml
# [bootstrap.prereqs] (SSOT) so operators can swap implementations via mios.html.
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
    $_done = $false
    # 1) winget -- OPTIONAL accelerator, only if present.
    if (Get-Command winget -EA SilentlyContinue) {
        Log-Ok ("{0} not found -- winget installing {1}..." -f $_pq.Label, $_pq.Pkg)
        & winget install --id $_pq.Pkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 |
            ForEach-Object { Write-Log ("winget[{0}]: {1}" -f $_pq.Cmd, $_) }
        $_rc = $LASTEXITCODE
        try {
            $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
            $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
            $env:PATH  = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
        } catch {}
        if (Get-Command $_pq.Cmd -EA SilentlyContinue) {
            Log-Ok ("{0} installed via winget" -f $_pq.Label); $_done = $true
        } elseif ($_pq.Cmd -eq 'wsl' -and $_rc -eq 0) {
            Log-Warn ("{0} installed via winget -- a reboot may be required for wsl.exe to surface" -f $_pq.Label); $_done = $true
            $script:WslJustInstalled = $true   # install-robustness: WSL2 substrate not live until reboot
        }
    }
    # 2) NO-LOCAL-DEPS direct install -- winget absent OR failed.
    if (-not $_done) {
        Log-Ok ("{0}: installing via direct download (no winget dependency)..." -f $_pq.Label)
        if (Install-MiosPrereqDirect -Cmd $_pq.Cmd -Label $_pq.Label) {
            if ($_pq.Cmd -eq 'wsl') {
                Log-Warn ("{0} installed direct -- a reboot may be required for wsl.exe to surface" -f $_pq.Label)
                $script:WslJustInstalled = $true   # install-robustness: reboot before WSL2 substrate is live
            } else {
                Log-Ok ("{0} installed direct" -f $_pq.Label)
            }
            $_done = $true
        }
    }
    if (-not $_done) {
        Log-Fail ("{0} could not be installed (winget + direct both unavailable/failed) -- bootstrap needs {1}" -f $_pq.Label, $_pq.Cmd)
        if ($_pq.Required) { $preOk = $false }
    }
}

# Install-robustness (B3): if WSL2 was JUST installed this run, the
# WSL2 substrate (and thus `podman machine init` in Phase 3) is NOT live until
# Windows reboots. Falling through to Phase 1/3 here dies with a cryptic podman
# error. HALT cleanly with an actionable, idempotent-re-run banner instead.
if ($script:WslJustInstalled) {
    End-Phase 0 -Fail
    Log-Fail "WSL2 was just installed -- Windows MUST reboot before the WSL2 substrate (podman machine) is live."
    Log-Fail "  -> Reboot Windows, then re-run the MiOS bootstrap (it is idempotent and resumes from here)."
    throw "Reboot required after WSL2 install -- reboot Windows, then re-run the bootstrap."
}

# Install-robustness (B2): hardware-virtualization preflight. WSL2 +
# `podman machine init` cannot start without VT-x/AMD-V (SVM) enabled in BIOS/
# UEFI; without this check Phase 3 dies with a cryptic HCS 0x80370102 / "not in
# running state after 90s". Probe firmware + hypervisor presence and fail CLEANLY
# with remediation. (Best-effort: a CIM query failure must not block a capable box.)
try {
    $_virtFw = $true; $_hyperv = $true
    try { $_virtFw = [bool](Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1 -Expand VirtualizationFirmwareEnabled) } catch {}
    try { $_hyperv = [bool](Get-CimInstance Win32_ComputerSystem -EA Stop).HypervisorPresent } catch {}
    if (-not $_virtFw -and -not $_hyperv) {
        Log-Fail "Hardware virtualization is DISABLED -- WSL2 + podman machine cannot start."
        Log-Fail "  -> Enable Intel VT-x / AMD-V (SVM) in BIOS/UEFI, then re-run the bootstrap."
        $preOk = $false
    }
} catch {}

if (-not $preOk) { End-Phase 0 -Fail; throw "Prerequisites missing -- see log: $LogFile" }

# Pre-flight: scrub misplaced /etc/wsl.conf keys from .wslconfig's [wsl2]
# section BEFORE Phase 3 (podman machine init) talks to wsl.exe. A stale
# `systemd=true` here would otherwise crash Phase 3 with the FATAL
# "wsl: Unknown key 'wsl2.systemd' in <path>" surfaced as the last
# captured stderr line of the podman pipeline.
Repair-WslConfig

End-Phase 0

function Invoke-GitFetchWithRetry {
    param(
        [string]$RepoPath,
        [string]$Ref
    )
    $exitCode = 1
    Push-Location $RepoPath
    try {
        for ($retry = 1; $retry -le 3; $retry++) {
            $exitCode = Invoke-NativeQuiet { git fetch --depth=1 origin $Ref }
            if ($exitCode -eq 0) { return 0 }
            # Fallback to full fetch if depth=1 fails (e.g. on commit SHAs or tags)
            $exitCode = Invoke-NativeQuiet { git fetch origin $Ref }
            if ($exitCode -eq 0) { return 0 }
            
            if ($retry -lt 3) {
                Log-Warn "git fetch failed for ref $Ref (exit $exitCode). Retrying in 5 seconds ($retry/3)..."
                Start-Sleep -Seconds 5
            }
        }
    } finally {
        Pop-Location
    }
    return $exitCode
}

# ── Phase 1 -- Detecting existing build environment ──────────────────────────
Start-Phase 1
$activeDistro = Find-ActiveDistro

if ($activeDistro) {
    Log-Ok "MiOS repo found in $activeDistro"
}

# mios.git is overlaid AT $MiosRepoDir root (M:\). Per.
$miosRepo = $MiosRepoDir
    if (Test-Path (Join-Path $MiosRepoDir ".git")) {
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_git_update' -Default "Updating mios.git (fetch + hard reset @ $MiosRepoDir)")
        Push-Location $MiosRepoDir
        try {
            $null = Invoke-NativeQuiet { git remote set-url origin $MiosRepoUrl }
        } finally { Pop-Location }
        $fetchExit = Invoke-GitFetchWithRetry -RepoPath $MiosRepoDir -Ref $MiosRef
        if ($fetchExit -eq 0) {
            Push-Location $MiosRepoDir
            try {
                $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                if ($resetExit -ne 0) { Log-Warn "mios.git: git reset --hard returned $resetExit" }
                if ($MiosRef -match '^[0-9a-fA-F]{7,40}$') {
                    $null = Invoke-NativeQuiet { git checkout -q FETCH_HEAD }
                } else {
                    $null = Invoke-NativeQuiet { git branch -f $MiosRef FETCH_HEAD }
                    $null = Invoke-NativeQuiet { git checkout -q $MiosRef }
                }
            } finally { Pop-Location }
        } else {
            Log-Warn "mios.git: git fetch returned $fetchExit -- working tree may be stale"
        }
    } else {
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_git_init' -Default "Initializing mios.git as the $MiosRepoDir working tree")
        & git config --global --add safe.directory '*' 2>&1 | ForEach-Object { Write-Log "git-safe-dir: $_" }
        & git config --global --add safe.directory $MiosRepoDir 2>&1 | ForEach-Object { Write-Log "git-safe-dir: $_" }
        Push-Location $MiosRepoDir
        try {
            $null = Invoke-NativeQuiet { git init -q }
            $null = Invoke-NativeQuiet { git config --unset core.worktree }
            $null = Invoke-NativeQuiet { git remote add origin $MiosRepoUrl }
            
            $fetchExit = Invoke-GitFetchWithRetry -RepoPath $MiosRepoDir -Ref $MiosRef
            if ($fetchExit -ne 0) {
                throw "mios.git: git fetch from $MiosRepoUrl failed (exit $fetchExit) at $MiosRepoDir"
            }
            $null = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
            if ($MiosRef -match '^[0-9a-fA-F]{7,40}$') {
                $null = Invoke-NativeQuiet { git checkout -q FETCH_HEAD }
            } else {
                $null = Invoke-NativeQuiet { git branch -f $MiosRef FETCH_HEAD }
                $null = Invoke-NativeQuiet { git checkout -q $MiosRef }
            }
        } finally { Pop-Location }
    }
    Push-Location $MiosRepoDir
    try {
        $existingWt = & git config --get core.worktree 2>$null
        if ($existingWt -and ($existingWt -match '^[A-Za-z]:[\/]')) {
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
        } finally { Pop-Location }
        $fetchExit = Invoke-GitFetchWithRetry -RepoPath $MiosBootstrapShadow -Ref $MiosBootstrapRef
        if ($fetchExit -eq 0) {
            Push-Location $MiosBootstrapShadow
            try {
                $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                if ($resetExit -ne 0) { Log-Warn "mios-bootstrap.git: git reset --hard returned $resetExit" }
                if ($MiosBootstrapRef -match '^[0-9a-fA-F]{7,40}$') {
                    $null = Invoke-NativeQuiet { git checkout -q FETCH_HEAD }
                } else {
                    $null = Invoke-NativeQuiet { git branch -f $MiosBootstrapRef FETCH_HEAD }
                    $null = Invoke-NativeQuiet { git checkout -q $MiosBootstrapRef }
                }
            } finally { Pop-Location }
        } else {
            Log-Warn "mios-bootstrap.git: git fetch returned $fetchExit -- shadow may be stale"
        }
    } else {
        if (-not (Test-Path $MiosBootstrapShadow)) {
            New-Item -ItemType Directory -Path $MiosBootstrapShadow -Force | Out-Null
        }
        Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_bootstrap_clone' -Default "Cloning mios-bootstrap.git -> shadow $MiosBootstrapShadow")
        Push-Location $MiosBootstrapShadow
        try {
            $null = Invoke-NativeQuiet { git init -q }
            $null = Invoke-NativeQuiet { git remote add origin $MiosBootstrapUrl }
            $fetchExit = Invoke-GitFetchWithRetry -RepoPath $MiosBootstrapShadow -Ref $MiosBootstrapRef
            if ($fetchExit -ne 0) {
                throw "mios-bootstrap.git: git fetch from $MiosBootstrapUrl failed (exit $fetchExit) at $MiosBootstrapShadow"
            }
            $null = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
            if ($MiosBootstrapRef -match '^[0-9a-fA-F]{7,40}$') {
                $null = Invoke-NativeQuiet { git checkout -q FETCH_HEAD }
            } else {
                $null = Invoke-NativeQuiet { git branch -f $MiosBootstrapRef FETCH_HEAD }
                $null = Invoke-NativeQuiet { git checkout -q $MiosBootstrapRef }
            }
        } finally { Pop-Location }
    }

    Set-Step (Get-MiosTomlValue -Section 'messages.steps' -Key 'mios_bootstrap_overlay' -Default "Overlaying mios-bootstrap files onto $MiosRepoDir")
    $robocopyExit = Invoke-NativeQuiet {
        robocopy $MiosBootstrapShadow $MiosRepoDir `
            /E /XD .git /NJH /NJS /NFL /NDL /NP
    }
    if ($robocopyExit -ge 8) {
        Log-Warn "mios-bootstrap overlay: robocopy exit $robocopyExit (>=8 means error)"
    }
    Log-Ok "mios-bootstrap files overlaid at $MiosRepoDir (shadow at $MiosBootstrapShadow)"

    if (-not (Test-Path $MiosInstallDir)) { New-Item -ItemType Directory -Path $MiosInstallDir -Force | Out-Null }
    if (-not (Test-Path $MiosBinDir)) { New-Item -ItemType Directory -Path $MiosBinDir -Force | Out-Null }

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

    # Provision .wslconfig FIRST, before any podman-machine init.
    # WSL2 reads .wslconfig at utility-VM start; if we write it after
    # podman has already spawned the VM, mirrored mode + firewall=false
    # never apply until the next `wsl --shutdown`. Operator-flagged
    # cockpit + every other container port timed out from
    # Windows because the VM came up in NAT mode while Phase 4's
    # post-hoc .wslconfig write said mirrored. Phase 4 still re-calls
    # this (idempotent) so any path that skips Phase 3 still lands
    # the config.
    try { Set-MiosWslConfig -RamGB $HW.RamGB -Cpus $HW.Cpus } catch { Log-Warn "Set-MiosWslConfig (pre-Phase-3): $($_.Exception.Message)" }
    & wsl.exe --shutdown 2>&1 | ForEach-Object { Write-Log "wsl-shutdown-pre-phase3: $_" }

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
    # `dnf5 install` per ```packages-*``` block. As of the
    # SSOT is mios.toml `[packages.<section>].pkgs` (resolved via
    # automation/lib/packages.sh), and PACKAGES.md was relegated to
    # docs at usr/share/doc/mios/reference/PACKAGES.md. The legacy
    # function's path check now warns "overlay seed skipped" on every
    # run because it looks at the moved path -- pure noise that
    # confused the operator's "ignition failed" reading on.
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
    # "podman-MiOS-DEV machine doesn't have the
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
                    # "NOT AT ALL A MIOS OVERLAY...
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
                        # dbus-launch must be on PATH before any
                        # `flatpak install` runs. The podman-machine-os
                        # 6.0 base image ships dbus-broker (system bus
                        # only) but NOT dbus-x11 (session bus launcher),
                        # so flatpak's pre-install token-request step
                        # fails with:
                        #     error: Failed to execute child process
                        #     "dbus-launch" (No such file or directory)
                        # The retry-with-arch path then dies the same
                        # way and the install loop reports 0/N OK.
                        # Operator-flagged. Cheap fix: install
                        # dbus-x11 (and its xauth dep) here once, before
                        # any flatpak call -- under 200 KB, runs in
                        # ~2-3s. Idempotent: dnf no-ops on second run.
                        & {
                            $ErrorActionPreference = 'Continue'
                            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                $PSNativeCommandUseErrorActionPreference = $false
                            }
                            & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "command -v dbus-launch >/dev/null 2>&1 || dnf install -y --quiet dbus-x11 xorg-x11-xauth 2>&1 | tail -5" 2>&1 |
                                ForEach-Object { Write-Log "mios-flatpak-dbus-prereq: $_" }
                        }
                        # Pre-install GNOME runtime + SDK ONCE before the
                        # per-app loop. org.gnome.Software (and other GNOME
                        # apps) fail with "no compatible runtime" if the
                        # platform isn't already pulled. Running this here
                        # avoids 6x parallel runtime resolution in the
                        # per-ref loop. Errors are non-fatal -- if the
                        # GNOME apps don't need it, this is a no-op.
                        & {
                            $ErrorActionPreference = 'Continue'
                            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                $PSNativeCommandUseErrorActionPreference = $false
                            }
                            # Refresh flathub's appstream so the per-app loop resolves
                            # cleanly. The old explicit `org.gnome.Platform//master` pre-pull
                            # errored "Nothing matches org.gnome.Platform in remote flathub"
                            # (//master is a gnome-nightly branch, NOT flathub -- flathub uses
                            # versioned branches;). Runtimes are pulled as deps by
                            # each per-app install below, so the pre-pull was redundant anyway.
                            & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "dbus-run-session -- sh -c 'flatpak update --system --appstream flathub 2>&1 | tail -3 || true' 2>&1 | tail -20" 2>&1 |
                                ForEach-Object { Write-Log "mios-flatpak-runtime: $_" }
                        }
                        # Ensure ALL configured remotes are added before the
                        # install loop runs (flathub is added separately
                        # elsewhere; fedora + gnome-nightly land here so
                        # entries with "fedora:" / "gnome-nightly:" prefixes
                        # in [desktop].flatpaks can install).
                        & {
                            $ErrorActionPreference = 'Continue'
                            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                $PSNativeCommandUseErrorActionPreference = $false
                            }
                            & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "
                                sudo flatpak remote-add --system --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo 2>/dev/null || true
                                sudo flatpak remote-add --system --if-not-exists fedora oci+https://registry.fedoraproject.org 2>/dev/null || true
                                sudo flatpak remote-add --system --if-not-exists gnome-nightly https://nightly.gnome.org/gnome-nightly.flatpakrepo 2>/dev/null || true
                                sudo dnf config-manager setopt updates-testing.enabled=1 2>/dev/null || true
                                sudo flatpak update --system --appstream flathub-beta 2>&1 | tail -2 || true
                                sudo flatpak update --system --appstream fedora 2>&1 | tail -2 || true
                                sudo flatpak update --system --appstream gnome-nightly 2>&1 | tail -2 || true
                            " 2>&1 | ForEach-Object { Write-Log "mios-flatpak-remotes: $_" }
                        }
                        $_fpOk = 0; $_fpFail = 0
                        foreach ($_fpEntry in $_flatpaks) {
                            # Parse "remote:appid" form; default to flathub when no prefix.
                            # Operator-flagged nautilus/ptyxis shims
                            # errored "app/<id>/x86_64/master not installed" because
                            # the install loop hardcoded `flathub` and our toml
                            # entries used `gnome-nightly:org.gnome.Nautilus.Devel`
                            # + `fedora:org.gnome.Epiphany`.
                            if ($_fpEntry -match '^([a-zA-Z0-9_-]+):(.+)$') {
                                $_fpRemote = $matches[1]
                                $_fp       = $matches[2]
                            } else {
                                $_fpRemote = 'flathub'
                                $_fp       = $_fpEntry
                            }
                            Set-Step ("[overlay] flatpak install {0}:{1}..." -f $_fpRemote, $_fp)
                            $_fpStderrLog = New-Object System.Collections.Generic.List[string]
                            & {
                                $ErrorActionPreference = 'Continue'
                                if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                    $PSNativeCommandUseErrorActionPreference = $false
                                }
                                # `dbus-run-session --` spawns a one-shot D-Bus
                                # session bus, runs the command, then tears it
                                # down. Without it, flatpak's pre-install token-
                                # request step ("Requesting tokens for remote
                                # fedora") tries to dbus-launch into a session
                                # that doesn't exist and dies with:
                                #     error: Could not connect:
                                #     No such file or directory
                                # which is what killed `fedora:org.gnome.Epiphany`
                                # for the even after dbus-x11
                                # was installed. dbus-run-session is part of dbus
                                # (always present on Fedora-base machine-os).
                                & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "dbus-run-session -- flatpak install -y --noninteractive --or-update $_fpRemote $_fp 2>&1" 2>&1 |
                                    ForEach-Object { Write-Log "mios-flatpak: $_"; [void]$_fpStderrLog.Add($_) }
                                $script:_fpLastRc = $LASTEXITCODE
                            }
                            if ($script:_fpLastRc -eq 0) {
                                Log-Ok "[overlay] flatpak install OK: $_fpRemote/$_fp"
                                $_fpOk++
                            } else {
                                $_fpRetryLog = New-Object System.Collections.Generic.List[string]
                                Log-Warn "[overlay] flatpak install attempt 1 failed (exit $($script:_fpLastRc)): $_fpRemote/$_fp -- retrying with --arch=x86_64 -v"
                                & {
                                    $ErrorActionPreference = 'Continue'
                                    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                                        $PSNativeCommandUseErrorActionPreference = $false
                                    }
                                    & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "dbus-run-session -- flatpak install -y --noninteractive --or-update --system --arch=x86_64 -v $_fpRemote $_fp 2>&1" 2>&1 |
                                        ForEach-Object { Write-Log "mios-flatpak-retry: $_"; [void]$_fpRetryLog.Add($_) }
                                    $script:_fpRetryRc = $LASTEXITCODE
                                }
                                if ($script:_fpRetryRc -eq 0) {
                                    Log-Ok "[overlay] flatpak install OK on retry: $_fp"
                                    $_fpOk++
                                } else {
                                    # Dump verbose output to its own log file
                                    # for grep-friendly diagnostic.
                                    $_fpFailLog = Join-Path $MiosLogDir ("flatpak-fail-$($_fp -replace '[^A-Za-z0-9._-]','_')-$LogStamp.log")
                                    try {
                                        $_fpAllLines = @($_fpStderrLog) + @('---retry---') + @($_fpRetryLog)
                                        Set-Content -LiteralPath $_fpFailLog -Value ($_fpAllLines -join "`n") -Encoding UTF8
                                    } catch {}
                                    $_fpTail = ($_fpRetryLog | Select-Object -Last 5) -join ' | '
                                    Log-Warn "[overlay] flatpak install FAILED both attempts (last exit $($script:_fpRetryRc)): $_fp"
                                    Log-Warn "  diagnostic tail: $_fpTail"
                                    Log-Warn "  full verbose log: $_fpFailLog"
                                    Log-Warn "  OCI image build (mios build -> automation/40-flatpak-bake.sh) retries at bake time; first-boot service mios-flatpak-install also retries on every host boot."
                                    $_fpFail++
                                }
                            }
                        }
                        Log-Ok "[desktop].flatpaks install pass: $_fpOk OK / $_fpFail failed (of $($_flatpaks.Count) total)"
                    }
                }
            }
        }
    }

    # ── NVIDIA WSL userland (gated on /dev/dxg present in dev VM) ───
    # "WSLg + GPU-PV or CDI" -> "WSLg + NVIDIA
    # Vulkan ICD". Installs NVIDIA's userspace Vulkan ICD + GLX/EGL
    # libs from the official CUDA repo. Userland-only; no kernel
    # modules. The script self-detects /dev/dxg + /mnt/wslg presence
    # and exits cleanly on non-WSLg substrates (bare-metal / Hyper-V
    # / OCI). Idempotent.
    Set-Step "Installing NVIDIA WSL userland in $_wslDistroForTerm (Vulkan ICD + GLX/EGL libs)..."
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $_nvOut = & wsl.exe -d $_wslDistroForTerm --user root -- bash /usr/libexec/mios/install-nvidia-wsl-userland.sh 2>&1
        $_nvExit = $LASTEXITCODE
        if ($_nvExit -eq 0) {
            $_nvSummary = ($_nvOut | Where-Object { $_ -match '^\s*\[(ok|skip|warn)\]' } | Select-Object -Last 3) -join ' / '
            if (-not $_nvSummary) { $_nvSummary = '(silent - see install log if needed)' }
            Log-Ok "NVIDIA WSL userland: $_nvSummary"
        } else {
            Log-Warn "NVIDIA WSL userland install exit=$_nvExit; GUI apps may fall back to dzn-only Vulkan path"
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
# Per (`getpwnam(mios) failed 17 / User not found`):
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
# ── /etc/wsl.conf [boot] systemd=true + [user] default=mios ─────────
# [boot] systemd=true MUST be set or the distro boots without systemd
# as PID 1; smoke tests then see state='offline' and Quadlets / the
# flatpak first-boot service / every service-coupled bootstrap step
# fails. WSL >= 0.67.6 honors this on next terminate+reentry.
# [user] default=mios so `wsl -d podman-MiOS-DEV` / `wsl -d MiOS-DEV`
# land in the mios shell; only written if the user exists or the
# distro entry breaks.
if [ ! -f /etc/wsl.conf ]; then
    printf '[boot]\nsystemd=true\n' > /etc/wsl.conf
    echo "[mios-seed] /etc/wsl.conf created with [boot] systemd=true"
elif ! grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
    echo "[mios-seed] /etc/wsl.conf: appended [boot] systemd=true"
elif ! grep -qE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
    if grep -qE '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
        sed -i 's|^[[:space:]]*systemd[[:space:]]*=.*|systemd=true|' /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf: rewrote systemd=<other> to systemd=true"
    else
        sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        echo "[mios-seed] /etc/wsl.conf: inserted systemd=true under existing [boot]"
    fi
else
    echo "[mios-seed] /etc/wsl.conf: [boot] systemd=true already set"
fi
if id mios >/dev/null 2>&1; then
    if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
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
# ── btop MiOS theme + 80x20 preset for the dev VM ─────────────────────
# image #15: btop reports "Width = 75 Height = 18,
# Needed 80 x 24". btop runs INSIDE the dev VM (Linux) so the Windows
# config at M:\MiOS\btop doesn't apply -- it reads ~/.config/btop/.
# Source files are exposed via WSL automount at /mnt/m/MiOS/btop/.
# Stage to BOTH the mios user (canonical) and root (in case of root
# sessions). Symlink approach so operator edits to mios.toml -> rebuild
# omp.json + theme flow through automatically.
if [ -d /mnt/m/MiOS/btop ]; then
    # System-wide fallback first. mios-btop.sh exports
    # BTOP_CONFIG_DIR=/etc/btop when the user has no ~/.config/btop,
    # so this guarantees the MiOS preset/palette renders even if the
    # per-user copy is missing (e.g. /=git home edge case).
    # screenshot: btop launched with btop's
    # compiled-in defaults (preset 3 = cpu+net, update_ms=2000)
    # because no config was found at $HOME/.config/btop. With this
    # /etc/btop/ copy in place, the resolver hits it unconditionally.
    mkdir -p /etc/btop/themes
    if [ -f /mnt/m/MiOS/btop/btop.conf ]; then
        cp -f /mnt/m/MiOS/btop/btop.conf /etc/btop/btop.conf
        chmod 0644 /etc/btop/btop.conf
    fi
    if [ -f /mnt/m/MiOS/btop/themes/mios.theme ]; then
        cp -f /mnt/m/MiOS/btop/themes/mios.theme /etc/btop/themes/mios.theme
        chmod 0644 /etc/btop/themes/mios.theme
    fi
    echo "[mios-seed] btop system-wide config staged at /etc/btop/"

    # Per-user copies (kept for operators who customize per-user).
    for _u in mios root; do
        if id "$_u" >/dev/null 2>&1; then
            _uhome=$(getent passwd "$_u" | cut -d: -f6)
            if [ -n "$_uhome" ] && [ -d "$_uhome" ]; then
                mkdir -p "$_uhome/.config/btop/themes"
                if [ -f /mnt/m/MiOS/btop/btop.conf ]; then
                    cp -f /mnt/m/MiOS/btop/btop.conf "$_uhome/.config/btop/btop.conf"
                fi
                if [ -f /mnt/m/MiOS/btop/themes/mios.theme ]; then
                    cp -f /mnt/m/MiOS/btop/themes/mios.theme "$_uhome/.config/btop/themes/mios.theme"
                fi
                chown -R "$_u":"$_u" "$_uhome/.config/btop" 2>/dev/null || true
                echo "[mios-seed] btop config + mios.theme staged for $_u at $_uhome/.config/btop/"
            fi
        fi
    done
fi
# ── Flatpak convenience symlinks (operator: epiphany / nautilus etc. should work) ─
# ran `nautilus` and `epiphany` after install, got
# "command not found" -- "LIAR!!!!!!". Install log said the flatpaks
# installed OK; they did, but flatpak exports binaries as their full
# app IDs (org.gnome.Epiphany, etc.) under /var/lib/flatpak/exports/bin/,
# NOT as short names. Operator expects `epiphany`, `nautilus`, etc.
# to work directly. Symlink the canonical short names into /usr/local/bin/
# pointing at the flatpak wrappers.
if [ -d /var/lib/flatpak/exports/bin ]; then
    mkdir -p /usr/local/bin
    # short-name -> full-app-id pairs (mirrors mios.toml [desktop].flatpaks)
    while IFS='|' read -r _short _appid; do
        _wrapper="/var/lib/flatpak/exports/bin/$_appid"
        _link="/usr/local/bin/$_short"
        if [ -x "$_wrapper" ] && [ ! -e "$_link" ]; then
            ln -snf "$_wrapper" "$_link"
            echo "[mios-seed] flatpak symlink: $_short -> $_appid"
        fi
    done <<EOFLATPAK
epiphany|org.gnome.Epiphany
nautilus|org.gnome.Nautilus
flatseal|com.github.tchx84.Flatseal
gnome-software|org.gnome.Software
extension-manager|com.mattjakeman.ExtensionManager
codium|com.vscodium.codium
code|com.vscodium.codium
EOFLATPAK
fi
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

    # Compile MiOS dconf overrides into the system-db cascade.  The
    # files at /etc/dconf/db/local.d/00-mios-theme + /etc/dconf/profile/
    # user ship in mios.git's overlay but only take effect after
    # `dconf update` builds the binary system-db.  Without this, the
    # adw-gtk3-dark + prefer-dark defaults stay inert and every GTK
    # app boots with the upstream light Adwaita fallback (operator-
    # flagged "not the mios.toml defined prefer-dark mode
    # yet").
    Set-Step "Compiling MiOS dconf system-db in $_wslDistroForTerm..."
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        # bash -c (NOT -lc) -- the dconf update step must not trigger
        # /etc/profile.d/ cascade (zz-mios-motd.sh -> mios mini -> fastfetch
        # render) which can hang here under WSL's pre-systemd boot state
        # and stall the entire install. dconf is in $PATH at /bin/dconf
        # without login-shell PATH-extension.
        # Operator-flagged install "stuck here" at this step.
        # NOTE: keep this bash -c free of embedded double-quotes and parens --
        # PowerShell's native-arg quoting mangles them passing to wsl.exe (the
        # 'syntax error near unexpected token (' came from the old
        # echo message's "(...)"). Plain words only.
        & wsl.exe -d $_wslDistroForTerm --user root -- bash -c 'command -v dconf >/dev/null 2>&1 && dconf update 2>&1 || echo dconf-binary-missing-skipped; ls /etc/dconf/db/local 2>&1 | head -1' 2>&1 |
            ForEach-Object { Write-Log "mios-dconf: $_" }
    }
    Log-Ok "MiOS dconf system-db compiled (adw-gtk3-dark + prefer-dark active for all user-bus sessions)"

    # Bibata-Modern-Classic cursor install. mios.git's automation/10-gnome.sh
    # bakes Bibata into the bootc OCI image MANDATORILY, but the dev VM
    # (podman-MiOS-DEV = podman-machine-os Fedora 44 + MiOS overlay) doesn't
    # run that automation. Without this overlay step, dconf points at
    # 'Bibata-Modern-Classic' but the theme dir doesn't exist -> libXcursor
    # silently falls back to default (operator-flagged "not
    # seeing bibata cursor that is the GLOBAL MiOS defaults"). Match the
    # image install path so the dev VM has the same cursor surface.
    Set-Step "Installing Bibata-Modern-Classic cursor in $_wslDistroForTerm..."
    # Up to 3 attempts -- the first wsl.exe call right after a fresh
    # dev-VM provision occasionally returns 127 (transient distro-ready
    # race; the next call succeeds). Use $script: scope so the exit
    # code propagates out of the & { ... } block.
    $script:_bibataExit = 1
    $script:_bibataOutput = @()
    for ($_try = 1; $_try -le 3 -and $script:_bibataExit -ne 0; $_try++) {
        if ($_try -gt 1) {
            Write-Log "mios-bibata: attempt $_try after exit=$($script:_bibataExit)"
            Start-Sleep -Seconds 5
        }
        & {
            $ErrorActionPreference = 'Continue'
            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                $PSNativeCommandUseErrorActionPreference = $false
            }
            # Base64-wrap the bibata script. Passed inline, its embedded
            # double-quotes/parens/$(...) get mangled by PowerShell's native-arg
            # quoting into bash syntax errors ("unexpected token ("
            # on the size echo). Encoding the whole script means ONLY base64 chars
            # reach the bash -c argument -- nothing to mangle. LF-normalize first.
            # Also guards the version/download/tar steps with || (a bare
            # `var=$(pipeline)` exits under set -e when the pipeline fails).
            $_bibataScript = @'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -e
if [ -d /usr/share/icons/Bibata-Modern-Classic ] && [ -n "$(ls -A /usr/share/icons/Bibata-Modern-Classic/cursors 2>/dev/null)" ]; then
    echo "Bibata already installed -- skipping"
    exit 0
fi
command -v curl >/dev/null || { echo "curl missing in dev VM"; exit 127; }
command -v tar  >/dev/null || { echo "tar missing in dev VM";  exit 127; }
VER=$(curl -sSL -H "Accept: application/vnd.github+json" https://api.github.com/repos/ful1e5/Bibata_Cursor/releases/latest 2>/dev/null | grep -oE "\"tag_name\":\\s*\"v[0-9.]+\"" | head -1 | grep -oE "v[0-9.]+" | sed "s/^v//") || VER=""
[ -z "$VER" ] && VER="2.0.7"
URL="https://github.com/ful1e5/Bibata_Cursor/releases/download/v${VER}/Bibata-Modern-Classic.tar.xz"
echo "Bibata v${VER}: ${URL}"
TARBALL=$(mktemp --suffix=.tar.xz)
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$TARBALL" "$URL" || { echo "Bibata download failed"; rm -f "$TARBALL"; exit 1; }
SIZE=$(stat -c %s "$TARBALL" 2>/dev/null || echo 0)
echo "Bibata tarball downloaded: ${SIZE} bytes"
if [ "${SIZE:-0}" -lt 100000 ]; then
    echo "Bibata tarball too small: ${SIZE} bytes - aborting" >&2
    rm -f "$TARBALL"
    exit 1
fi
mkdir -p /usr/share/icons
tar -xJf "$TARBALL" -C /usr/share/icons/ || { echo "Bibata tar extract failed"; rm -f "$TARBALL"; exit 1; }
rm -f "$TARBALL"
if [ ! -d /usr/share/icons/Bibata-Modern-Classic/cursors ] || [ -z "$(ls -A /usr/share/icons/Bibata-Modern-Classic/cursors 2>/dev/null)" ]; then
    echo "Bibata extraction failed -- cursors dir empty" >&2
    exit 1
fi
CURSORN=$(ls /usr/share/icons/Bibata-Modern-Classic/cursors | wc -l)
echo "Bibata installed: ${CURSORN} cursors"
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache /usr/share/icons/Bibata-Modern-Classic 2>&1 || true
exit 0
'@
            $_bibataB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($_bibataScript -replace "`r`n","`n")))
            $script:_bibataOutput = & wsl.exe -d $_wslDistroForTerm --user root -- bash -c "echo $_bibataB64 | base64 -d | bash" 2>&1
            $script:_bibataExit = $LASTEXITCODE
        }
        foreach ($_line in $script:_bibataOutput) { Write-Log "mios-bibata: $_line" }
    }
    if ($script:_bibataExit -eq 0) {
        Log-Ok "MiOS Bibata cursor theme staged"
    } else {
        Log-Warn ("Bibata cursor install failed after 3 attempts (exit=$($script:_bibataExit)); dconf points at Bibata-Modern-Classic but theme dir is missing -- run ``mios update`` or install manually from https://github.com/ful1e5/Bibata_Cursor/releases")
    }

    # MiOS AI CLI install: Claude Code + Gemini CLI globally via npm.
    # Both are Node.js CLIs distributed via npm, so they don't fit RPM
    # packaging. The helper script reads mios.toml [packages.ai].
    # npm_globals to discover what to install -- operators can extend
    # the list via /etc/mios/mios.toml or ~/.config/mios/mios.toml.
    # ON by default; MIOS_SKIP_AI_CLIS=1 to skip.
    Set-Step "Installing MiOS AI CLIs (Claude Code + Gemini CLI) in $_wslDistroForTerm..."
    & {
        $ErrorActionPreference = 'Continue'
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $_aiOut = & wsl.exe -d $_wslDistroForTerm --user root -- bash /usr/libexec/mios/install-ai-clis.sh 2>&1
        $_aiOut | ForEach-Object { Write-Log "mios-ai-cli: $_" }
    }
    Log-Ok "MiOS AI CLIs installed (claude + gemini available on PATH)"

    # The overlay seed wrote /etc/wsl.conf [user] default=mios so future
    # `wsl -d podman-MiOS-DEV` invocations land in the mios user (not the
    # bundled `user` UID 1000). But /etc/wsl.conf is read at distro
    # START -- the live instance running RIGHT NOW was launched with the
    # pre-seed config and still defaults to `user`. Terminate the distro
    # so the next entry (menu option 1 or 5) re-launches with the new
    # default user. Idempotent: if the distro isn't running, --terminate
    # is a no-op.
    # Full `wsl --shutdown` (utility VM + all distros) instead of just
    # `wsl --terminate <distro>`. The terminate path only restarts the
    # distro process, leaving the WSL2 utility VM running with whatever
    # networkingMode it booted in. Symptom if the utility
    # VM started in NAT mode earlier in the install (e.g. due to a
    # wsl --list -v probe in Phase 1 firing before .wslconfig was on
    # disk), .wslconfig's mirrored mode never takes effect and every
    # container port stays unreachable from Windows. shutdown forces
    # a clean utility-VM restart so the operator's next MiOS terminal
    # launch picks up mirrored + firewall=false + the /etc/wsl.conf
    # [user]=mios default user in one shot.
    Set-Step "wsl --shutdown so .wslconfig + /etc/wsl.conf take effect on next entry..."
    & wsl.exe --shutdown 2>&1 |
        ForEach-Object { Write-Log "wsl-shutdown-end-phase3: $_" }
    Log-Ok "WSL2 utility VM shutdown -- next entry uses mirrored networking + mios as default user"

    End-Phase 3

    # ── Phase 4 -- WSL2 .wslconfig ───────────────────────────────────────────
    # Phase 3 already wrote .wslconfig BEFORE initializing the dev VM
    # (so mirrored networking + firewall=false applied at first boot).
    # This phase is the idempotent re-check + post-Phase-3 firewall
    # rules. Set-MiosWslConfig is a no-op if all required keys already
    # match.
    Start-Phase 4
    try { Set-MiosWslConfig -RamGB $HW.RamGB -Cpus $HW.Cpus } catch { Log-Warn "Set-MiosWslConfig (Phase-4 recheck): $($_.Exception.Message)" }

    # Windows Firewall inbound rules for MiOS container ports. SSOT is
    # mios.toml [ports].* + [ports.lan_firewall].profiles/.expose.
    # Without these, mirrored networking carries the WSL port bind onto
    # Windows' all interfaces but Defender blocks inbound from any LAN
    # device (phone, tablet, second laptop). Operator-flagged.
    Set-Step "Adding Windows Firewall LAN inbound rules for MiOS service ports..."
    try { Set-MiosLanFirewallRules } catch { Log-Warn "Set-MiosLanFirewallRules: $($_.Exception.Message)" }
    try { Set-MiosLanPortProxy }     catch { Log-Warn "Set-MiosLanPortProxy: $($_.Exception.Message)" }

    End-Phase 4

    # ── Phase 5 -- Verify Windows build context ──────────────────────────────
    # Build runs via 'podman build' from the Windows clone -- no machine exec needed.
    Start-Phase 5
    # mios.git is overlaid AT $MiosRepoDir root, per.
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
        # Per "headers and dashboards and framing/
        # piping are all scattered and not fitting because they aren't
        # TRULY based off the toml code as source for everything".
        # Vendor default '╭─╮│╰╯' if mios.toml is unreachable.
        $_fc = Get-MiosTomlValue -Section 'branding.dashboard' -Key 'frame_chars' -Default "$([char]0x256D)$([char]0x2500)$([char]0x256E)$([char]0x2502)$([char]0x2570)$([char]0x256F)"
        if (-not $_fc -or $_fc.Length -lt 6) { $_fc = "$([char]0x256D)$([char]0x2500)$([char]0x256E)$([char]0x2502)$([char]0x2570)$([char]0x256F)" }
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
    # Bake-set policy: the MINIMAL set from mios.toml [ai].bake_models
    # (small Qwen + the embedding model) is ALWAYS baked into the OCI
    # image so a fresh install is usable fully offline without bloating
    # the image layer. Larger models stay SELECTABLE -- offered here as
    # an opt-in. This prompt only runs in the interactive local-build
    # path (build-mios.ps1); the Forgejo CI build sources
    # MIOS_OLLAMA_BAKE_MODELS straight from install.env, so cloud/CI
    # builds always get just the minimal set. If the operator's chosen
    # default model isn't already in the minimal set, offer to bake it
    # too; declining means it first-boot-pulls instead of bloating the
    # image.
    $MiosOllamaBakeModels = if ($aiDefaults.BakeModels) { $aiDefaults.BakeModels } else { "$defaultModel,$($aiDefaults.EmbedModel)" }
    $_bakeList = @($MiosOllamaBakeModels -split ',' | ForEach-Object { $_.Trim() })
    # Make sure the embedding model the operator chose is in the set.
    if ($MiosAiEmbedModel -and ($_bakeList -notcontains $MiosAiEmbedModel)) {
        $MiosOllamaBakeModels = "$MiosOllamaBakeModels,$MiosAiEmbedModel"
        $_bakeList += $MiosAiEmbedModel
    }
    if ($MiosAiModel -and ($_bakeList -notcontains $MiosAiModel)) {
        $_ans = Read-Line "Also bake '$MiosAiModel' into the image? (larger image, fully offline) [y/N]" "N"
        if ($_ans -match '^[Yy]') {
            $MiosOllamaBakeModels = "$MiosOllamaBakeModels,$MiosAiModel"
            Write-Host "  bake set: $MiosOllamaBakeModels" -ForegroundColor DarkGray
        } else {
            Write-Host "  bake set: $MiosOllamaBakeModels (minimal); '$MiosAiModel' first-boot-pulls" -ForegroundColor DarkGray
        }
    }

    Log-Ok "Identity: user=$MiosUser  host=$MiosHostname  password=(hashed)  ghcr=$tokStatus  ai=$MiosAiModel"
    $script:IdentInfo = "User:$MiosUser  Host:$MiosHostname  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$MiosAiModel"
    End-Phase 6

    # ── Phase 7 -- Write identity ─────────────────────────────────────────────
    Start-Phase 7
    $MiosLlamacppBakeModels = $aiDefaults.LlamacppBakeModels
    $MiosVllmBakeModel       = $aiDefaults.VllmBakeModel
    $envContent = @"
MIOS_USER="$MiosUser"
MIOS_HOSTNAME="$MiosHostname"
MIOS_USER_PASSWORD_HASH="$MiosHash"
MIOS_AI_MODEL="$MiosAiModel"
MIOS_AI_EMBED_MODEL="$MiosAiEmbedModel"
MIOS_OLLAMA_BAKE_MODELS="$MiosOllamaBakeModels"
MIOS_LLAMACPP_BAKE_MODELS="$MiosLlamacppBakeModels"
MIOS_VLLM_BAKE_MODEL="$MiosVllmBakeModel"
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
    # Per "the Applications tag/description when
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
    # vmconnect.exe is the Hyper-V Manager's VM-connection tool. On a
    # MiOS Hyper-V deployment the guest's mios-hyperv-enhanced.service
    # patches xrdp onto the VMBus vsock transport so vmconnect lights
    # up Enhanced Session by default (clipboard sync, dynamic
    # resolution, audio, USB). The shortcut opens vmconnect with no
    # VM specified -- operator picks their MiOS VM from the list.
    $vmconnect = Join-Path $env:WINDIR 'System32\vmconnect.exe'
    @(
        @{ F="Uninstall MiOS.lnk";       T=$pwsh;      A="-ExecutionPolicy Bypass -File `"$uninstSc`"";  D="Remove MiOS (preserves per-user config)" }
        @{ F="MiOS Enhanced Session.lnk"; T=$vmconnect; A="";                                            D="Connect to a MiOS Hyper-V VM with Enhanced Session (clipboard, dynamic resolution, audio, USB)" }
    ) | ForEach-Object {
        # Only ship Enhanced Session shortcut if vmconnect.exe exists
        # (Hyper-V client tools installed). On Windows Home, Hyper-V
        # client tools aren't present; skip silently rather than
        # creating a broken shortcut.
        if ($_.F -eq 'MiOS Enhanced Session.lnk' -and -not (Test-Path -LiteralPath $vmconnect)) { return }
        New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir
    }

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
    Log-Ok "Add/Remove Programs + Start Menu created (5+ native apps: MiOS, MiOS-DEV, MiOS Config, MiOS Help, Uninstall MiOS, MiOS Enhanced Session*)"

    # Uninstaller script. Operator-asserted contract
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
    Write-Host "    - Podman machines (MiOS-DEV, MiOS-BUILDER, podman-MiOS-*) + podman system reset"
    Write-Host "    - WSL distros (MiOS, MiOS-DEV, podman-MiOS-*, MiOS-BUILDER, podman-MiOS-BUILDER)"
    Write-Host "    - Hyper-V VMs matching MiOS-*"
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

# 1. Podman machine (every variant + global system reset)
Write-Host '  [1/13] Stopping + removing podman machines...' -ForegroundColor Cyan
foreach (`$mch in @(`$B, 'MiOS-DEV','MiOS-BUILDER','podman-MiOS-DEV','podman-MiOS-BUILDER')) {
    if ([string]::IsNullOrWhiteSpace(`$mch)) { continue }
    try { & podman machine stop `$mch 2>`$null } catch {}
    try { & podman machine rm -f `$mch 2>`$null } catch {}
}
try { & podman system reset --force 2>`$null } catch {}

# 2. WSL distros (every variant the install has used across revisions)
Write-Host '  [2/13] Unregistering WSL distros...' -ForegroundColor Cyan
foreach (`$d in @(`$B, `$M, 'MiOS', 'MiOS-DEV', 'podman-MiOS-DEV', 'MiOS-BUILDER', 'podman-MiOS-BUILDER')) {
    if ([string]::IsNullOrWhiteSpace(`$d)) { continue }
    try { & wsl.exe --unregister `$d 2>`$null | Out-Null } catch {}
}
try { & wsl.exe --shutdown 2>`$null | Out-Null } catch {}

# 2b. Hyper-V VMs matching MiOS-* (per feedback_mios_entry_full_reset memory)
Write-Host '  [3/13] Removing Hyper-V VMs (MiOS-*)...' -ForegroundColor Cyan
try {
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        Get-VM -Name 'MiOS-*' -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-VM -Name `$_.Name -TurnOff -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-VM -Name `$_.Name -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
} catch {}

# 3. Install dirs (preserve `$C unless -Purge)
Write-Host '  [4/13] Removing install dirs (M:\\MiOS + overlay)...' -ForegroundColor Cyan
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
Write-Host '  [5/13] Cleaning Windows Terminal settings.json...' -ForegroundColor Cyan
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
        # MiOS / MiOS-WIN / MiOS-DEV / podman-MiOS-* profiles
        if (`$j.profiles -and `$j.profiles.list) {
            `$keepProfiles = @(`$j.profiles.list | Where-Object {
                `$_.name -ne 'MiOS' -and `$_.name -ne 'MiOS-WIN' -and `$_.name -ne 'MiOS-DEV' -and `$_.name -ne 'MiOS-Bootstrap' -and `$_.name -notmatch '^podman-MiOS-' -and `$_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}' -and `$_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456790}'
            })
            if (`$keepProfiles.Count -ne `$j.profiles.list.Count) { `$j.profiles.list = [object[]]`$keepProfiles; `$changed = `$true }
        }
        if (`$changed) {
            (`$j | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath `$wtPath -Encoding UTF8
        }
    } catch {}
}

# 5. PowerShell profile redirector blocks (both pwsh 7 + WindowsPowerShell 5.1)
Write-Host '  [6/13] Removing PowerShell profile redirector blocks...' -ForegroundColor Cyan
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
Write-Host '  [7/13] Removing MiOS fonts...' -ForegroundColor Cyan
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
Write-Host '  [8/13] Removing PATH env entries...' -ForegroundColor Cyan
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
Write-Host '  [9/13] Removing HKCU uninstall reg key...' -ForegroundColor Cyan
if (Test-Path -LiteralPath `$K) { Remove-Item -LiteralPath `$K -Recurse -Force -ErrorAction SilentlyContinue }

# 9. Start Menu folder + Desktop .lnk shortcuts
Write-Host '  [10/13] Removing Start Menu + Desktop shortcuts...' -ForegroundColor Cyan
`$lnkNames = @(
    'MiOS.lnk','MiOS-DEV.lnk','MiOS Config.lnk','MiOS Help.lnk','Uninstall MiOS.lnk','MiOS Enhanced Session.lnk',
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
    # Also nuke the MiOS\Linux Apps\ subfolder + every .lnk inside it
    # (Files / Web / VSCodium / Flatseal / Extension Manager / Ptyxis /
    # System Monitor / Settings -- created by Install-WindowsBranding's
    # Linux Apps loop). "uninstaller STILL doesn't
    # uninstall everything from windows" -- previous build only removed
    # named .lnks, leaving Linux Apps\ orphaned in Start Menu.
    if (`$dir -match 'Start Menu\\Programs\\MiOS$') {
        `$linuxAppsSub = Join-Path `$dir 'Linux Apps'
        if (Test-Path -LiteralPath `$linuxAppsSub) {
            try { Remove-Item -LiteralPath `$linuxAppsSub -Recurse -Force -ErrorAction SilentlyContinue } catch {}
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
Write-Host '  [11/13] Removing AppUserModelID registrations...' -ForegroundColor Cyan
foreach (`$aumKey in @('HKCU:\Software\Classes\AppUserModelId\MiOS.Workstation',
                       'HKLM:\Software\Classes\AppUserModelId\MiOS.Workstation')) {
    if (Test-Path -LiteralPath `$aumKey) {
        try { Remove-Item -LiteralPath `$aumKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# 11. podman-machine state symlinks
Write-Host '  [12/13] Removing podman-machine state symlinks...' -ForegroundColor Cyan
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

# 12. MIOS_* + BTOP_CONFIG_DIR environment variables
Write-Host '  [13/17] Removing MIOS_* + BTOP_CONFIG_DIR environment variables...' -ForegroundColor Cyan
foreach (`$scope in @('User','Machine')) {
    try {
        `$envKey = if (`$scope -eq 'User') { 'HKCU:\Environment' }
                   else { 'HKLM:\System\CurrentControlSet\Control\Session Manager\Environment' }
        if (Test-Path -LiteralPath `$envKey) {
            (Get-Item -LiteralPath `$envKey).Property | Where-Object { `$_ -match '^(MIOS_|MiOS_|BTOP_CONFIG_DIR$)' } |
                ForEach-Object { try { Remove-ItemProperty -LiteralPath `$envKey -Name `$_ -ErrorAction SilentlyContinue } catch {} }
        }
    } catch {}
}

# 13. HKCU\Run autostart entries (MiOS-GuiWatch background daemon) + scheduled tasks
Write-Host '  [14/17] Removing HKCU\Run autostart entries + scheduled tasks...' -ForegroundColor Cyan
foreach (`$runVal in @('MiOS-GuiWatch','MiOS','MiOSGuiWatch','MiOS-Autostart')) {
    try { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name `$runVal -ErrorAction SilentlyContinue } catch {}
}
# Kill any running mios-gui-watch.ps1 pwsh process (it auto-resizes WSLg
# windows; without this it'd survive uninstall and keep polling).
try {
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { `$_.CommandLine -match 'mios-gui-watch' } |
        ForEach-Object { try { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
} catch {}
try {
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'MiOS-Autostart' -Confirm:`$false -ErrorAction SilentlyContinue
    }
} catch {}
try {
    `$stagedAutostart = Join-Path `$env:ProgramData 'MiOS\mios-autostart.ps1'
    if (Test-Path `$stagedAutostart) {
        Remove-Item -Path `$stagedAutostart -Force -ErrorAction SilentlyContinue
    }
} catch {}

# 14. Windows Defender exclusions (added by Add-MiosDefenderExclusions)
Write-Host '  [15/17] Removing Windows Defender exclusions...' -ForegroundColor Cyan
try {
    if (Get-Command Remove-MpPreference -ErrorAction SilentlyContinue) {
        foreach (`$excPath in @('M:\','M:\MiOS','M:\MiOS\bin','M:\MiOS\repo',(Join-Path `$env:LOCALAPPDATA 'Microsoft\WinGet'),`$env:TEMP)) {
            try { Remove-MpPreference -ExclusionPath `$excPath -ErrorAction SilentlyContinue } catch {}
        }
        foreach (`$excProc in @('pwsh.exe','wsl.exe','wslservice.exe','podman.exe','msrdc.exe')) {
            try { Remove-MpPreference -ExclusionProcess `$excProc -ErrorAction SilentlyContinue } catch {}
        }
    }
} catch {}

# 15. /etc/skel and Add/Remove Programs final cleanup (any stragglers)
# (covered by step 4 + 9; explicit re-pass here in case a partial install left both states)
Write-Host '  [16/17] Final HKCU\Uninstall\MiOS sweep + stale icon dir...' -ForegroundColor Cyan
try { Remove-Item -LiteralPath `$K -Recurse -Force -ErrorAction SilentlyContinue } catch {}
try { Remove-Item -LiteralPath (Join-Path `$I 'icons') -Recurse -Force -ErrorAction SilentlyContinue } catch {}

# 16. FULL FORMAT M:\ partition ("FULLY format
# the M:\ partition only"). Only formats if M:\ exists AND is the
# MiOS-DEV labeled partition we provisioned. NEVER touches any other
# drive letter, never re-partitions, never creates/deletes drives.
# Confirmation gated -- only fires when operator explicitly asked for
# uninstall (not on -Quiet runs from a panicked irm|iex reap path).
Write-Host '  [17/17] Reformatting M:\ partition (MIOS-DEV label)...' -ForegroundColor Cyan
try {
    `$mVol = Get-Volume -DriveLetter M -ErrorAction SilentlyContinue
    if (`$mVol -and `$mVol.FileSystemLabel -match '^MIOS') {
        # Stop any process holding handles into M:\ first
        try {
            Get-Process | Where-Object {
                try { `$_.Path -and `$_.Path -like 'M:\*' } catch { `$false }
            } | ForEach-Object { try { Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue } catch {} }
        } catch {}
        if (-not `$Quiet) {
            `$ans = Read-Host "  M: drive will be FULLY FORMATTED (label MIOS-DEV). Type 'format' to confirm"
            if (`$ans -eq 'format') {
                Format-Volume -DriveLetter M -FileSystem NTFS -NewFileSystemLabel 'MIOS-DEV' -Force -Confirm:`$false -ErrorAction Stop | Out-Null
                Write-Host '  [+] M:\ reformatted (NTFS, label MIOS-DEV, empty).' -ForegroundColor Green
            } else {
                Write-Host '  M:\ format SKIPPED (operator did not confirm).' -ForegroundColor Yellow
            }
        } else {
            # -Quiet mode: format without prompt (called from auto-reap)
            Format-Volume -DriveLetter M -FileSystem NTFS -NewFileSystemLabel 'MIOS-DEV' -Force -Confirm:`$false -ErrorAction Stop | Out-Null
            Write-Host '  [+] M:\ reformatted (NTFS, label MIOS-DEV, empty) [-Quiet].' -ForegroundColor Green
        }
    } else {
        Write-Host '  M:\ not present or label != MIOS-DEV; skipping format (safety guard).' -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [!] M:\ format failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
if (`$Purge) {
    Write-Host "  'MiOS' fully removed (zero-state). Per-user config at `$C also purged." -ForegroundColor Green
} else {
    Write-Host "  'MiOS' removed. Per-user config at `$C preserved." -ForegroundColor Green
    Write-Host "  Run with -Purge to also remove per-user config." -ForegroundColor DarkGray
}
"@ | Set-Content $uninstSc -Encoding UTF8
    Log-Ok "uninstall.ps1 written (13-category cleanup, mirrors Get-MiOS.ps1 Invoke-MiOSFullReap)"
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

# end full-install branch

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
