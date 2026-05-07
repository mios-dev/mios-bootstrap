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
        'M:\usr\share\mios\mios.toml',
        'C:\MiOS\usr\share\mios\mios.toml'
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                $script:_MiosTomlCache['_text']   = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
                $script:_MiosTomlCache['_source'] = $p
                return $script:_MiosTomlCache['_text']
            } catch {}
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
                return ,$coerced
            }
            return ,$items
        }
        return $Default
    }
    return $raw.Trim('"', "'")
}

# Resolve canonical terminal dims ONCE at script-load so every later
# resize / wt --size / stty call uses the same values from mios.toml.
$script:MiosCols   = Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80
$script:MiosRows   = Get-MiosTomlValue -Section 'terminal' -Key 'rows' -Default 20
$script:MiosScroll = Get-MiosTomlValue -Section 'terminal' -Key 'scrollback_rows' -Default 9000

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

# ── Paths & constants ─────────────────────────────────────────────────────────
$MiosVersion      = "v0.2.4"
$MiosRepoUrl      = "https://github.com/mios-dev/MiOS.git"   # repo renamed mios.git -> MiOS.git; old URL still redirects but git's smart-HTTP fetch refuses 301s without followRedirects
$MiosBootstrapUrl = "https://github.com/mios-dev/mios-bootstrap.git"
# Podman machine name -- canonical "MiOS-DEV" (was MiOS-BUILDER pre-v0.2.3).
# Backed by WSL distro `podman-MiOS-DEV` once `podman machine init` runs.
# Both names are recognized at install-time so existing MiOS-BUILDER
# distros are accepted (and not destroyed) until the next podman machine rm.
$DevDistro        = "MiOS-DEV"
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

# ── Dashboard state ───────────────────────────────────────────────────────────
$script:DW         = [math]::Max(60, [math]::Min(([Console]::WindowWidth - 6), 72))
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
if ($BootstrapOnly) {
    $script:PhaseNames = @(
        "Hardware + Prerequisites",
        "Detecting environment",
        "Directories and repos",
        "MiOS-DEV distro",
        "WSL2 configuration",
        "App registration"
    )
    $script:AppRegPhaseId = 5
} else {
    $script:PhaseNames = @(
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
    $script:AppRegPhaseId = 8
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
                    $cfgHtml = Join-Path $MiosRepoDir 'usr/share/mios/configurator/index.html'
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
    # Open /usr/share/mios/configurator/index.html for the operator to
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
        (Join-Path $RepoDir "mios\usr\share\mios\configurator\index.html"),
        (Join-Path $MiosShareDir "system\usr\share\mios\configurator\index.html"),
        (Join-Path $MiosShareDir "bootstrap\usr\share\mios\configurator\index.html")
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

    # Convert C:\path\index.html -> /mnt/c/path/index.html
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
    $ramGB = try { [math]::Round((Get-CimInstance Win32_PhysicalMemory|Measure-Object Capacity -Sum).Sum/1GB) } catch { 16 }
    # OS-reported RAM (bytes) -- this is what podman validates against; may be less than nominal GB count
    $osTotalRamMB = try { [math]::Floor((Get-CimInstance Win32_ComputerSystem -EA Stop).TotalPhysicalMemory / 1MB) } catch { $ramGB * 1024 }
    $cpus  = [Environment]::ProcessorCount
    $gpu   = try { Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" } | Select-Object -First 1 } catch { $null }
    $gpuName   = if ($gpu) { $gpu.Name } else { "Unknown" }
    $hasNvidia = $gpuName -match "NVIDIA|GeForce|Quadro|RTX|GTX|Tesla"
    $baseImage = if ($hasNvidia) { "ghcr.io/ublue-os/ucore-hci:stable-nvidia" } else { "ghcr.io/ublue-os/ucore-hci:stable" }
    $aiModel   = if ($ramGB -ge 32) { "qwen2.5-coder:14b" } elseif ($ramGB -ge 12) { "qwen2.5-coder:7b" } else { "phi4-mini:3.8b-q4_K_M" }
    $diskFreeGB    = try { [math]::Floor((Get-PSDrive C -EA Stop).Free/1GB) } catch { 200 }
    $builderDiskGB = [math]::Max(80, $diskFreeGB - 20)
    return @{ RamGB=$ramGB; OsTotalRamMB=$osTotalRamMB; Cpus=$cpus; GpuName=$gpuName; HasNvidia=$hasNvidia
              BaseImage=$baseImage; AiModel=$aiModel; DiskGB=$builderDiskGB }
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

    Set-Step "Sizing MiOS data disk ($ShrinkMB MB on ${DriveLetter}:)..."

    # 0. Already-initialized? Skip.
    $existing = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existing -and $existing.FileSystemLabel -eq $VolumeLabel) {
        Log-Ok "MiOS data disk already on ${DriveLetter}: ($([math]::Round($existing.Size/1GB,1)) GB, $($existing.FileSystem))"
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
        [string]$Repo = 'quay.io/podman/machine-os',
        [string]$Tag  = '6.0',
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
    # Cap at the OS-reported physical RAM (what podman validates) minus 512 MB safety margin.
    # Nominal $HW.RamGB rounds up from actual hardware, causing podman to reject the request.
    $ramMB = [math]::Max(4096, [math]::Min($HW.OsTotalRamMB - 512, $HW.RamGB * 1024 - 512))

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
                & podman machine rm --force $BuilderDistro 2>&1 |
                    ForEach-Object { Write-Log "podman-recover-rm: $_" }

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
sudo ln -sf usr/share/mios/configurator/index.html /configurator.html  2>/dev/null || true
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
        Log-Ok "MiOS oh-my-posh theme staged at $themeDst"

        # Inject (or refresh) the init line in the user's PowerShell profile.
        # Marker comments delimit the MiOS-managed block so re-runs are
        # idempotent (we replace the block, not append).
        $profilePath = $PROFILE.CurrentUserAllHosts
        if (-not $profilePath) { $profilePath = $PROFILE }
        $profileDir  = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
        $marker   = '# >>> MiOS oh-my-posh init >>>'
        $endMark  = '# <<< MiOS oh-my-posh init <<<'
        $themeForProfile = $themeDst -replace '\\', '\\'
        $block = @"
$marker
# Auto-generated by mios-bootstrap/build-mios.ps1. Edit at your own
# risk -- block is replaced on every re-run between the markers.
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    `$miosTheme = "$themeForProfile"
    if (Test-Path `$miosTheme) {
        oh-my-posh init pwsh --config `$miosTheme | Invoke-Expression
    }
}
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
        [ValidateSet('plain','dev','pull','dash','build','update','config')] [string] $Badge = 'plain'
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

$WIDTH = 80
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
# Bare invocation -> root login shell at ~root. Args pass through verbatim
# so callers can still do `mios-dev --user user -- some-cmd` etc.
`$distro = Resolve-MiosDevDistro
if (`$args.Count -eq 0) {
    wsl.exe -d `$distro --user root --cd '~' -- bash -l
} else {
    wsl.exe -d `$distro @args
}
"@ -Encoding UTF8

    $pullPath = Join-Path $MiosBinDir 'mios-pull.ps1'
    Set-Content -Path $pullPath -Value @"
$devResolveBlock
wsl.exe -d (Resolve-MiosDevDistro) --user root sudo /usr/bin/mios-pull @args
"@ -Encoding UTF8

    # mios-update.ps1 -- re-runs build-mios.ps1 from the cloned repo to
    # refresh the Windows side (oh-my-posh, fonts, theme, launcher).
    $bootstrapBuild = Join-Path $MiosRepoDir 'mios-bootstrap\build-mios.ps1'
    $updatePath = Join-Path $MiosBinDir 'mios-update.ps1'
    $updateScript = @"
# Refreshes the Windows-side MiOS install by re-running build-mios.ps1.
# Skips the heavy build / VM provisioning phases via -ResetOnly when
# possible; passes any extra arguments through.
`$bs = "$bootstrapBuild"
if (Test-Path `$bs) {
    & pwsh.exe -NoProfile -File `$bs @args
} else {
    Write-Host "build-mios.ps1 not found at `$bs" -ForegroundColor Yellow
    Write-Host "Re-clone with: git clone $MiosBootstrapUrl `"$MiosRepoDir\mios-bootstrap`""
}
"@
    Set-Content -Path $updatePath -Value $updateScript -Encoding UTF8

    # mios-config.ps1 -- opens the HTML configurator in default browser.
    $cfgPath = Join-Path $MiosBinDir 'mios-config.ps1'
    $cfgHtml = Join-Path $MiosShareDir 'mios\usr\share\mios\configurator\index.html'
    $cfgScript = @"
`$cfg = "$cfgHtml"
if (Test-Path `$cfg) { Start-Process `$cfg }
else { Write-Host "configurator not found at `$cfg" -ForegroundColor Yellow }
"@
    Set-Content -Path $cfgPath -Value $cfgScript -Encoding UTF8

    # mios.ps1 -- THE MiOS app. Single launcher that replaces the
    # previous per-verb Start Menu shortcuts. Each verb (Build, Dev VM,
    # Update, Dashboard, Configurator, ...) is a numbered menu item;
    # the bin scripts beside this one stay as the actual workers and
    # the app just dispatches. Self-locates bin/ via $PSScriptRoot so
    # a re-run picks up the latest verbs without regeneration.
    $hubPath   = Join-Path $MiosBinDir 'mios.ps1'
    $hubScript = @'
# <MiOSRoot>\bin\mios.ps1 -- the MiOS app.
# Auto-installed by mios-bootstrap (Install-MiosLauncher).
$ErrorActionPreference = 'SilentlyContinue'
$Script:MiOSBin  = $PSScriptRoot
$Script:MiOSRoot = Split-Path -Parent $Script:MiOSBin

try {
    $sz  = New-Object Management.Automation.Host.Size 80, 30
    $buf = New-Object Management.Automation.Host.Size 80, 9000
    $Host.UI.RawUI.BufferSize = $buf
    $Host.UI.RawUI.WindowSize = $sz
} catch {}

function Read-MiosVersion {
    $f = Join-Path $Script:MiOSRoot 'VERSION'
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return '0.2.2'
}

function Resolve-MiosDevDistro {
    $wslList = @()
    try { $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ } } catch {}
    foreach ($c in @('MiOS-DEV', 'podman-MiOS-DEV', 'MiOS-BUILDER', 'podman-MiOS-BUILDER')) {
        if ($wslList -contains $c) { return $c }
    }
    return $null
}

function Show-MiosApp {
    Clear-Host
    $ver  = Read-MiosVersion
    # 78-char frame to match the MiOS profile dashboard + leave 1-2 col
    # right margin in an 80-col window. Unicode box-drawing chars match
    # the global Show-MiosDashboard styling.
    $top  = [char]0x256D + ([string][char]0x2500) * 76 + [char]0x256E   # ╭──...──╮
    $bot  = [char]0x2570 + ([string][char]0x2500) * 76 + [char]0x256F   # ╰──...──╯
    $thin = [char]0x251C + ([string][char]0x2500) * 76 + [char]0x2524   # ├──...──┤
    $V    = [char]0x2502                                                # │
    Write-Host $top -ForegroundColor DarkCyan
    $title = "$V  MiOS v" + $ver
    Write-Host ($title + (' ' * (77 - $title.Length)) + $V) -ForegroundColor Cyan
    $sub = "$V  one launcher; mios.toml is the SSOT for every target"
    Write-Host ($sub + (' ' * (77 - $sub.Length)) + $V) -ForegroundColor DarkGray
    Write-Host $thin -ForegroundColor DarkCyan
    $items = @(
        @{ Key = '1'; Name = 'Build MiOS';        Desc = 'build deployable OCI (podman build + deploy)' },
        @{ Key = '2'; Name = 'Enter Dev VM';      Desc = 'wsl into MiOS-DEV (root shell)'              },
        @{ Key = '3'; Name = 'Update Overlay';    Desc = 'mios-pull onto / inside MiOS-DEV'            },
        @{ Key = '4'; Name = 'Dashboard';         Desc = 'live system view (services, fastfetch)'      },
        @{ Key = '5'; Name = 'Configurator';      Desc = 'edit mios.toml (Epiphany via WSLg)'          },
        @{ Key = '6'; Name = 'Re-run Bootstrap';  Desc = 'rerun localhost setup + dev VM provision'    },
        @{ Key = '7'; Name = 'Open Install Root'; Desc = 'open ' + $Script:MiOSRoot + ' in Explorer'    },
        @{ Key = 'q'; Name = 'Quit';              Desc = 'exit'                                         }
    )
    foreach ($it in $items) {
        $body = '  [' + $it.Key + ']  ' + $it.Name.PadRight(20) + $it.Desc
        if ($body.Length -gt 74) { $body = $body.Substring(0, 73) + [char]0x2026 }
        $line = "$V $body".PadRight(77) + $V
        $color = if ($it.Key -eq 'q') { 'DarkGray' } else { 'White' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host $thin -ForegroundColor DarkCyan
    $dev = Resolve-MiosDevDistro
    $devTxt = if ($dev) { $dev } else { 'not registered' }
    $devLine = "$V  Dev distro : $devTxt"
    Write-Host ($devLine.PadRight(77) + $V) -ForegroundColor DarkGray
    $instLine = "$V  Install    : $($Script:MiOSRoot)"
    Write-Host ($instLine.PadRight(77) + $V) -ForegroundColor DarkGray
    $ssotLine = "$V  SSOT       : ~/.config > /etc > /usr/share  (mios/mios.toml)"
    Write-Host ($ssotLine.PadRight(77) + $V) -ForegroundColor DarkGray
    Write-Host $bot -ForegroundColor DarkCyan
    Write-Host ''
}

function Invoke-Verb {
    param([string]$Key)
    switch ($Key) {
        '1' { & (Join-Path $Script:MiOSBin 'mios-update.ps1') -BuildOnly }
        '2' { & (Join-Path $Script:MiOSBin 'mios-dev.ps1')                }
        '3' { & (Join-Path $Script:MiOSBin 'mios-pull.ps1')               }
        '4' { & (Join-Path $Script:MiOSBin 'mios-dash.ps1')               }
        '5' { & (Join-Path $Script:MiOSBin 'mios-config.ps1')             }
        '6' { & (Join-Path $Script:MiOSBin 'mios-update.ps1')             }
        '7' { Start-Process explorer.exe $Script:MiOSRoot                 }
        default { Write-Host "  Unknown option '$Key'." -ForegroundColor Yellow; Start-Sleep 1 }
    }
}

while ($true) {
    Show-MiosApp
    Write-Host -NoNewline '  Choose [1-7,q]: ' -ForegroundColor Cyan
    $choice = Read-Host
    if ($choice -in @('q','Q','quit','exit')) { break }
    Invoke-Verb $choice
    if ($choice -ne 'q') {
        Write-Host ''
        Write-Host -NoNewline '  Press Enter to return to the menu...' -ForegroundColor DarkGray
        $null = Read-Host
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
# on every re-run between the markers. Functions resolve the bin
# scripts under $MiosBinDir. The `mios` function (no suffix) is the
# canonical entry point -- launches the menu app from any pwsh shell.
`$Global:MiosBin = "$miosBinForProfile"
function mios         { & (Join-Path `$Global:MiosBin 'mios.ps1')        @args }
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
    $miosCmd = ('pwsh.exe -NoExit -ExecutionPolicy Bypass -Command "& { try { $H=Get-Host; $H.UI.RawUI.BufferSize=(New-Object Management.Automation.Host.Size 80,9000); $H.UI.RawUI.WindowSize=(New-Object Management.Automation.Host.Size 80,30) } catch {}; & ''' + $hubPathForJson + ''' }"')
    if (Test-Path $wtSettings) {
        try {
            # JSONC tolerance: strip comments + trailing commas before parsing
            # so this works on PS5.1 (ConvertFrom-Json refuses JSONC there).
            $wtRaw = Get-Content $wtSettings -Raw
            $wtRaw = [regex]::Replace($wtRaw, '(?ms)/\*.*?\*/', '')
            $wtRaw = [regex]::Replace($wtRaw, '(?m)^\s*//.*$', '')
            $wtRaw = [regex]::Replace($wtRaw, ',(\s*[}\]])', '$1')
            $wtJson = $wtRaw | ConvertFrom-Json

            $miosGuid = '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}'
            $existingProfile = $null
            if ($wtJson.profiles -and $wtJson.profiles.list) {
                $existingProfile = $wtJson.profiles.list | Where-Object { $_.guid -eq $miosGuid } | Select-Object -First 1
            }
            if ($existingProfile) {
                # Rebind commandline + icon to the post-install hub. Leave
                # font/scheme/padding/launchMode untouched -- those are
                # owned by Get-MiOS.ps1's installer and we don't want to
                # rewrite them on every build run.
                $existingProfile.commandline = $miosCmd
                $existingProfile.startingDirectory = $Script:MiOSRoot
                if ($icoPath -and (-not $existingProfile.PSObject.Properties['icon'])) {
                    $existingProfile | Add-Member -NotePropertyName icon -NotePropertyValue $icoPath -Force
                } elseif ($icoPath) {
                    $existingProfile.icon = $icoPath
                }
                $wtJson | ConvertTo-Json -Depth 32 | Set-Content -Path $wtSettings -Encoding UTF8
                Log-Ok "Windows Terminal MiOS profile rebound to $hubPath"
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
# no titlebar, no tab row), 80 cols x 30 rows, screen-centered on
# whichever monitor the cursor is currently on. Re-centers post-launch
# via Win32 SetWindowPos to defeat WT's --pos-ignored-in-focus
# regression. Runs invisibly (parent shortcut uses -WindowStyle Hidden).
param(
    [string]$Profile = 'MiOS'
)
$ErrorActionPreference = 'SilentlyContinue'

try {
    Add-Type -Namespace 'MiOSLaunch.Native' -Name 'Dpi' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
"@
    [MiOSLaunch.Native.Dpi]::SetProcessDPIAware() | Out-Null
} catch {}

Add-Type -AssemblyName System.Windows.Forms

# Cell metrics (Geist Mono 12pt, lineHeight=1.0): ~10 x 20 px.
# Outer-rect slack for DWM frame + scrollbar + acrylic edge: +20 W, +12 H.
$Cols   = 80
$Rows   = 30
$winW   = ($Cols * 10) + 20
$winH   = ($Rows * 20) + 12

$cur    = [System.Windows.Forms.Cursor]::Position
$work   = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
$x      = [int]($work.X + ($work.Width  - $winW) / 2)
$y      = [int]($work.Y + ($work.Height - $winH) / 2)
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

$wtArgs = @('-w','-1','--pos',"$x,$y",'--size','80,30','--focus','nt','-p',$Profile)
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

    # Retry-loop center: WT in focus mode often re-positions itself
    # to its remembered location AFTER our first SetWindowPos. Three
    # spaced-out moves stick where one doesn't.
    $topmost = [IntPtr]::new(-1)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $rect = New-Object MiOSLaunch.Native.Win+RECT
        if ([MiOSLaunch.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) {
            $rw = $rect.Right - $rect.Left
            $rh = $rect.Bottom - $rect.Top
            if ($rw -gt 0 -and $rh -gt 0) {
                $cx = [int]($work.X + ($work.Width  - $rw) / 2)
                $cy = [int]($work.Y + ($work.Height - $rh) / 2)
                # HWND_TOPMOST + SWP_SHOWWINDOW = 0x40.
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, $topmost, $cx, $cy, $rw, $rh, 0x40)
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $cx, $cy, $rw, $rh, 0x04)
            }
        }
        Start-Sleep -Milliseconds 350
    }
}
'@
    if (-not (Test-Path $MiosBinDir)) { New-Item -ItemType Directory -Path $MiosBinDir -Force | Out-Null }
    Set-Content -Path $miosLauncher -Value $launcherSrc -Encoding UTF8
    Log-Ok "MiOS native launcher staged: $miosLauncher"

    # Shortcut targets the centering launcher with -WindowStyle Hidden so
    # there's no console-flash before WT appears. -NoProfile keeps the
    # launcher cold-start fast (typically < 300 ms before wt.exe spawns).
    if ($wtExe) {
        $hubTarget = $pwshExe
        $hubArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$miosLauncher`""
    } else {
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
    $verbShortcuts = @(
        @{ Name = 'MiOS-DEV';          Bin = 'mios-dev.ps1';    Icon = 'mios-dev.ico';    Desc = 'Enter the MiOS-DEV WSL2 distro (root shell)' },
        @{ Name = 'MiOS Build';        Bin = 'mios-update.ps1'; Icon = 'mios-build.ico';  Desc = 'Build the deployable MiOS OCI image (podman build + deploy)' },
        @{ Name = 'MiOS Dashboard';    Bin = 'mios-dash.ps1';   Icon = 'mios-dash.ico';   Desc = 'Live MiOS system view (services, fastfetch, git tree)' },
        @{ Name = 'MiOS Configurator'; Bin = 'mios-config.ps1'; Icon = 'mios-config.ico'; Desc = 'Edit mios.toml in the GUI (Epiphany via WSLg)' },
        @{ Name = 'MiOS Update';       Bin = 'mios-update.ps1'; Icon = 'mios-update.ico'; Desc = 'Re-run the MiOS bootstrap (refresh terminal + dev VM)' },
        @{ Name = 'MiOS Pull';         Bin = 'mios-pull.ps1';   Icon = 'mios-pull.ico';   Desc = 'Sync M:\\ overlay to origin/main (mios-pull)' }
    )
    foreach ($v in $verbShortcuts) {
        $vBin   = Join-Path $MiosBinDir $v.Bin
        $vIcon  = Join-Path $MiosIconsDir $v.Icon
        $vLnk   = Join-Path $StartMenuDir ("{0}.lnk" -f $v.Name)
        $vArgs  = "-NoProfile -ExecutionPolicy Bypass -File `"$vBin`""
        # Build verb runs with -BuildOnly so it triggers the OCI build,
        # not the full bootstrap re-run.
        if ($v.Name -eq 'MiOS Build') {
            $vArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$vBin`" -BuildOnly"
        }
        # Verbs that don't drop into a shell (Configurator launches
        # Epiphany, Pull is one-shot) close after running -- use pwsh
        # without -NoExit. MiOS-DEV intentionally lands in the WSL
        # shell and stays there. Dashboard / Update / Build keep their
        # output visible via -NoExit.
        if ($v.Name -in @('MiOS-DEV')) {
            # mios-dev.ps1 wraps wsl.exe; the WSL session itself keeps
            # the window alive, no -NoExit needed.
            $vArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$vBin`""
        } elseif ($v.Name -in @('MiOS Build','MiOS Dashboard','MiOS Update')) {
            $vArgs = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$vBin`"" + $(if ($v.Name -eq 'MiOS Build') { ' -BuildOnly' } else { '' })
        }
        New-MiosShortcut -LnkPath $vLnk -TargetExe $pwshExe -ArgsString $vArgs -IconFile $vIcon -Description $v.Desc | Out-Null
        Log-Ok ("Per-verb Start Menu shortcut: {0} -> {1}" -f $v.Name, $v.Bin)
    }

    # Garbage-collect any stale shortcuts from earlier revisions whose
    # names don't match the current verb set. Idempotent: if absent, skip.
    foreach ($legacy in @('Build MiOS.lnk','MiOS Dev VM.lnk','MiOS Rebuild.lnk','MiOS Setup.lnk','MiOS Terminal.lnk','MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','Uninstall MiOS.lnk')) {
        $stale = Join-Path $StartMenuDir $legacy
        if (Test-Path $stale) {
            try { Remove-Item $stale -Force -ErrorAction SilentlyContinue; Log-Ok "Removed legacy shortcut: $legacy" } catch {}
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

Write-Host $bTop -ForegroundColor Cyan
Write-Host (_BoxRow "'MiOS' $MiosVersion  --  Unified Windows Installer") -ForegroundColor Cyan
Write-Host (_BoxRow "Immutable Fedora AI Workstation")                   -ForegroundColor Cyan
Write-Host (_BoxRow "WSL2 + Podman  │  Offline Build Pipeline")          -ForegroundColor Cyan
Write-Host $bBot -ForegroundColor Cyan
Write-Host ""

if ($script:DashboardMode -eq 'log') {
    Write-Host "Note: console doesn't support in-place repaint -- running in linear log mode." -ForegroundColor Yellow
    Write-Host "      Phase transitions + throttled step updates print sequentially below." -ForegroundColor DarkYellow
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

# Force-recompute $DW now that the window is definitely 80 wide. If the
# load-time resize failed but THIS one succeeded, the original $DW (set
# from a wider parent terminal) would still drive the dashboard at the
# wrong width. Re-reading WindowWidth here closes that gap.
$script:DW = [math]::Max(60, [math]::Min(([Console]::WindowWidth - 6), 72))

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
if (Get-Command git    -EA SilentlyContinue) { Log-Ok "Git $((& git --version 2>&1) -replace 'git version ','')" }
else { Log-Fail "Git not found -- winget install Git.Git"; $preOk = $false }
if (Get-Command wsl    -EA SilentlyContinue) { Log-Ok "WSL2 available" }
else { Log-Warn "WSL2 not found -- run: wsl --install" }
if (Get-Command podman -EA SilentlyContinue) { Log-Ok "Podman $((& podman --version 2>&1) -replace 'podman version ','')" }
else { Log-Warn "Podman not found -- winget install RedHat.Podman-Desktop" }

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
    Install-WindowsBranding
    Install-MiosLauncher
    if ($BootstrapOnly) {
        Log-Ok "-BootstrapOnly mode: existing $DevDistro is healthy, Windows install refreshed."
        End-Phase 1   # we never entered Phase 9 here
        return
    }

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
        Set-Step "Updating mios.git (fetch + hard reset @ $MiosRepoDir)"
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
        Set-Step "Initializing mios.git as the $MiosRepoDir working tree"
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
            $fetchExit = Invoke-NativeQuiet { git fetch --depth=1 origin main }
            if ($fetchExit -ne 0) {
                throw "mios.git: git fetch from $MiosRepoUrl failed (exit $fetchExit) at $MiosRepoDir"
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
    Log-Ok "mios.git overlaid at $MiosRepoDir"

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
        Set-Step "Cloning mios-bootstrap.git to shadow $MiosBootstrapShadow"
        $cloneExit = Invoke-NativeQuiet { git clone --depth 1 $MiosBootstrapUrl $MiosBootstrapShadow }
        if ($cloneExit -ne 0) {
            throw "mios-bootstrap.git: clone from $MiosBootstrapUrl failed (exit $cloneExit)"
        }
    }

    # Overlay mios-bootstrap files onto $MiosRepoDir (M:\) -- excluding .git
    # so we don't clobber mios.git's .git dir at M:\.
    Set-Step "Overlaying mios-bootstrap files onto $MiosRepoDir"
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
    Log-Ok "Entry scripts staged at $MiosBinDir"
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
            $tomlText = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
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
        # ── Operator-facing end-of-Pass-2 summary ────────────────────
        # The bootstrap STOPS here. The operator decides when to fire
        # the build pipeline by typing `mios build` (or clicking the
        # MiOS Build shortcut). Per
        # feedback_mios_bootstrap_stops_at_mios_dev_ready memory: the
        # Windows entry installs everything UP TO MiOS-DEV being a
        # native app, then prints hint lines and returns. No auto-chain.
        $_dispGb = 256
        try { $v = Get-Volume -DriveLetter M -ErrorAction SilentlyContinue; if ($v) { $_dispGb = [math]::Round($v.Size/1GB,0) } } catch {}
        Write-Host ''
        Write-Host '  +' ('-' * 76) '+' -ForegroundColor DarkCyan
        Write-Host '  |  MiOS Windows-side install complete                                        |' -ForegroundColor Cyan
        Write-Host '  +' ('-' * 76) '+' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '    Installed ...............................................................' -ForegroundColor DarkGray
        Write-Host ('      [+] M:\ partition ({0} GB NTFS, label MIOS-DEV)' -f $_dispGb) -ForegroundColor Green
        Write-Host '      [+] Podman Desktop + podman-MiOS-DEV machine' -ForegroundColor Green
        Write-Host '      [+] mios.git + mios-bootstrap overlaid at M:\' -ForegroundColor Green
        Write-Host '      [+] MiOS terminal essentials layered into MiOS-DEV' -ForegroundColor Green
        Write-Host '      [+] Native Windows app: Start Menu + Desktop + per-verb shortcuts' -ForegroundColor Green
        Write-Host '      [+] MiOS PowerShell profile (oh-my-posh, dashboard, mios <verb>)' -ForegroundColor Green
        Write-Host ''
        Write-Host '    What''s next? Type any of these in the MiOS terminal:' -ForegroundColor White
        Write-Host '      mios build   -- open mios-config.html, save, then build the OCI image' -ForegroundColor Cyan
        Write-Host '      mios config  -- edit mios.toml in the HTML configurator (no build)' -ForegroundColor Cyan
        Write-Host '      mios dash    -- show the MiOS dashboard (framed banner + fastfetch)' -ForegroundColor Cyan
        Write-Host '      mios dev     -- enter the MiOS-DEV podman machine' -ForegroundColor Cyan
        Write-Host '      mios pull    -- sync M:\ overlay to origin/main' -ForegroundColor Cyan
        Write-Host '      mios update  -- re-run the bootstrap (cache-busted)' -ForegroundColor Cyan
        Write-Host '      mios help    -- list every verb' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    The MiOS hub shortcut is in your Start Menu / Desktop / Win+Search.' -ForegroundColor DarkGray
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
    @{
        DisplayName="MiOS - Immutable Fedora AI Workstation"; DisplayVersion=$MiosVersion
        Publisher="MiOS-DEV"; InstallLocation=$MiosInstallDir
        UninstallString=$uninstCmd; QuietUninstallString="$uninstCmd -Quiet"
        URLInfoAbout="https://github.com/mios-dev/mios"
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
    $launcherArgs    = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$miosLauncher`""
    $launcherArgsDev = "$launcherArgs -Profile MiOS-DEV"
    @(
        @{ F="MiOS Setup.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`"";              D="Re-run full 'MiOS' setup" },
        @{ F="Build MiOS.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`" -BuildOnly";    D="Build 'MiOS' OCI image (Phase 6+: identity, podman build, deploy)" },
        @{ F="MiOS Configurator.lnk";  T=$pwsh;     A="-NoProfile -ExecutionPolicy Bypass -File `"$cfgScript`""; D="Edit mios.toml in Epiphany via WSLg" },
        @{ F="MiOS Terminal.lnk";      T=$pwsh;     A=$launcherArgs;                                             D="Open MiOS WT profile (borderless, 80x30, screen-centered)" },
        @{ F="MiOS Dev Shell.lnk";     T=$pwsh;     A=$launcherArgsDev;                                          D="Open MiOS-DEV WT profile (borderless, 80x30, screen-centered)" },
        @{ F="Uninstall MiOS.lnk";     T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$uninstSc`"";             D="Remove MiOS" }
    ) | ForEach-Object { New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir }

    # Mirror the Configurator shortcut to the operator's Desktop so the
    # icon is one click away without opening Start Menu first.
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    if ($desktopDir -and (Test-Path $desktopDir)) {
        New-Shortcut (Join-Path $desktopDir "MiOS Configurator.lnk") $pwsh `
            "-NoProfile -ExecutionPolicy Bypass -File `"$cfgScript`"" `
            "Edit mios.toml in Epiphany via WSLg" $MiosInstallDir
        Log-Ok "Desktop shortcut written to $desktopDir\MiOS Configurator.lnk"
    }
    Log-Ok "Add/Remove Programs + Start Menu created"

    # Uninstaller script. Removes the install dir + machine-wide
    # ProgramData state + Start Menu + registry entry + Podman/WSL2
    # distros. Preserves per-user config ($MiosConfigDir) so re-installs
    # pick up the operator's last identity.
    $B = $BuilderDistro
    @"
#Requires -Version 5.1
param([switch]`$Quiet)
`$I='$($MiosInstallDir-replace"'","''")'
`$P='$($MiosProgramData-replace"'","''")'
`$D='$($MiosDataDir-replace"'","''")'
`$C='$($MiosConfigDir-replace"'","''")'
`$S='$($StartMenuDir-replace"'","''")'
`$K='$($UninstallRegKey-replace"'","''")'
`$B='$B'
`$M='$MiosWslDistro'
if (-not `$Quiet) {
    Write-Host ''; Write-Host '  ''MiOS'' Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes: `$I, `$P, `$D, ``$B`` + ``$M`` (Podman + WSL2 distros), Start Menu"
    Write-Host "  Preserves: `$C (per-user config)"; Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}
try { podman machine stop `$B 2>`$null } catch {}
try { podman machine rm -f `$B 2>`$null } catch {}
try { wsl --unregister `$B 2>`$null } catch {}
try { wsl --unregister `$M 2>`$null } catch {}
foreach (`$p in @(`$I,`$P,`$D,`$S)) { if (Test-Path `$p) { Remove-Item `$p -Recurse -Force -ErrorAction SilentlyContinue } }
if (Test-Path `$K) { Remove-Item `$K -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host "  'MiOS' removed. Per-user config at `$C preserved." -ForegroundColor Green
"@ | Set-Content $uninstSc -Encoding UTF8
    Log-Ok "uninstall.ps1 written"
    End-Phase $script:AppRegPhaseId

    # ── Phase 9 -- Build ──────────────────────────────────────────────────────
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
