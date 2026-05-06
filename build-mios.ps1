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
    # -BootstrapOnly: localhost-side preflight + dev VM provision +
    # smoke test + rename + Windows install. Stops BEFORE the OCI image
    # build (Phase 6+). This is the curl-bash entry path -- after it
    # completes the operator has a fully-functional MiOS-DEV WSL2 distro
    # plus Windows-side icons (oh-my-posh, fonts, theme, Start Menu).
    # The "Build MiOS" Start Menu shortcut then drives the full image
    # build via -BuildOnly when the operator is ready.
    [switch]$BootstrapOnly,

    # -BuildOnly: skip the dev VM provisioning (assumes the bootstrap
    # phase already ran and MiOS-DEV is registered). Jump to identity
    # prompts + OCI image build + deploy. This is what the "Build MiOS"
    # Start Menu launcher invokes.
    [switch]$BuildOnly,

    # -Unattended: take all defaults; no interactive prompts.
    [switch]$Unattended
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

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
$MiosRepoUrl      = "https://github.com/mios-dev/mios.git"
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
# MiOS-DEV's base machine-OS image. We DO NOT pin a specific tag by
# default any more, because:
#
#   * `podman machine init --image <bare OCI ref>` does NOT recognize
#     the bare-ref form -- podman tries to stat() the value as a local
#     file path. On Windows that's a GetFileAttributesEx call on
#     "quay.io/podman/machine-os:<tag>" which fails with "The system
#     cannot find the path specified" because `:` is interpreted as a
#     drive-letter separator. The user-visible failure was:
#         FATAL: Error: GetFileAttributesEx quay.io/podm...
#     in Phase 3 with the previous pin "quay.io/podman/machine-os:6.0".
#   * To pass an OCI ref to `podman machine init --image`, the value
#     MUST be prefixed with `docker://`. Bare refs are silently treated
#     as file paths, no error from the parser, just an unhelpful stat
#     failure downstream.
#   * Hard-pinning a specific tag also tends to break with podman
#     client version drift -- a podman 4.x client doesn't understand
#     a 6.x machine-os, and vice versa.
#
# Behavior: if $env:MIOS_MACHINE_IMAGE is set we pass it through (and
# auto-prefix `docker://` if it looks like an OCI ref). Otherwise we
# omit --image entirely and let podman use its bundled default, which
# always matches the installed podman client version.
$MachineImage = $env:MIOS_MACHINE_IMAGE
if ($MachineImage -and $MachineImage -notmatch '^(docker|https?|file)://' -and $MachineImage -match '^[a-z0-9.-]+\.[a-z]{2,}/') {
    # Looks like a bare OCI ref (host.tld/repo:tag) -- prefix it so
    # podman parses it as a docker-transport URL, not a file path.
    $MachineImage = "docker://$MachineImage"
}

if ($script:IsAdmin) {
    # AllUsers (machine-wide native Windows app layout). Top-level
    # C:\MiOS as requested -- treats MiOS as a first-class Windows
    # application rather than a hidden Program Files entry.
    $MiosInstallDir   = Join-Path ${env:SystemDrive} "MiOS"             # C:\MiOS
    $MiosProgramData  = Join-Path ${env:ProgramData}  "MiOS"            # C:\ProgramData\MiOS
    $MiosRepoDir      = Join-Path $MiosInstallDir   "repo"              # code (git checkouts)
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
    # land at M:\MiOS\repo, not at C:\MiOS\repo.
    param([Parameter(Mandatory)] [string] $NewRoot)
    $script:MiosInstallDir  = $NewRoot
    $script:MiosBinDir      = Join-Path $NewRoot 'bin'
    $script:MiosShareDir    = Join-Path $NewRoot 'share'
    $script:MiosIconsDir    = Join-Path $NewRoot 'icons'
    $script:MiosThemesDir   = Join-Path $NewRoot 'themes'
    $script:MiosFontsDir    = Join-Path $NewRoot 'fonts'
    # State + artifacts also move onto the data disk.
    $script:MiosProgramData = Join-Path $NewRoot 'machine-state'
    $script:MiosRepoDir     = Join-Path $NewRoot 'repo'
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
    $shrinkMB    = if ($env:MIOS_DATA_DISK_MB)     { [int]$env:MIOS_DATA_DISK_MB }     else { 262144 }
    $driveLetter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER }      else { 'M' }
    try {
        $dataRoot = Initialize-MiosDataDisk -ShrinkMB $shrinkMB -DriveLetter $driveLetter -VolumeLabel 'MIOS-DEV'
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
    [System.IO.File]::AppendAllText(
        $LogFile,
        ("=" * 78 + "`n" +
         "MiOS install session  start=$LogStamp  pid=$PID  user=$env:USERNAME  host=$env:COMPUTERNAME`n" +
         "=" * 78 + "`n"),
        [Text.Encoding]::UTF8)
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
    # Console mirroring policy depends on $DashboardMode:
    #   * interactive: Write-Host every line. Show-Dashboard repaints
    #     over these rows on its next tick (the log file already has
    #     the canonical record so we can be liberal here).
    #   * log:         Show-Dashboard is a no-op so anything we Write-Host
    #     stays on screen forever. Only surface WARN/ERROR (which
    #     operators must see) and let INFO live in the log file.
    if ($script:DashboardMode -eq 'interactive') {
        Write-Host $line
    } elseif ($L -in @('WARN','ERROR')) {
        $color = if ($L -eq 'ERROR') { 'Red' } else { 'Yellow' }
        Write-Host $line -ForegroundColor $color
    }
    if ($L -eq "ERROR") { $script:ErrCount++ }
    if ($L -eq "WARN")  { $script:WarnCount++ }
}

# ── Dashboard state ───────────────────────────────────────────────────────────
$script:DW         = [math]::Max(66, [math]::Min(([Console]::WindowWidth - 2), 80))
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
$script:TotalPhases   = $script:PhaseNames.Count
$script:PhStat        = @(0,0,0,0,0,0,0,0,0,0,0,0,0,0)
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
    # Linear-log mode: SetCursorPosition is a no-op or the host doesn't
    # support repaint -- attempting to render the framed dashboard just
    # stacks frames downward forever (one per Set-Step / phase tick).
    # Bail entirely; Start-Phase / End-Phase / Set-Step emit their own
    # one-line log messages in this mode (see those functions below).
    if ($script:DashboardMode -eq 'log') { return }
    try {
    # ── Sizing -- max 80 cols (standard tty0/console) ──────────────────────────
    $winW = try { [Console]::WindowWidth  } catch { 80 }
    $bufH = try { [Console]::BufferHeight } catch { 9999 }
    # Width-floor: pad to MAX($winW, last render width) so a narrower
    # current render still overwrites every column the previous render
    # touched. Otherwise the rightmost column(s) of a wider previous
    # render show as a vertical ghost stripe.
    $winW = [math]::Max($winW, $script:DashLastWidth)
    # Always 1 char narrower than actual terminal so old content to the right
    # of the box is blanked on overwrite; capped at 80 for tty0 portability.
    $w  = [math]::Max(40, [math]::Min(80, $winW - 1))
    $in = $w - 4   # inner content width: "| " + content + " |"
    $sepD = ("+" + ("-" * ($w - 2)) + "+").PadRight($winW)
    $sepE = ("+" + ("=" * ($w - 2)) + "+").PadRight($winW)

    # ── Row helper -- script block closes over $in/$winW from caller scope ─────
    $mkRow = {
        param([string]$c)
        ("| " + $c.PadRight($in) + " |").PadRight($winW)
    }

    # ── State ─────────────────────────────────────────────────────────────────
    $phDone = [int]($script:PhStat | Where-Object { $_ -ge 2 } | Measure-Object).Count
    $phFail = [int]($script:PhStat | Where-Object { $_ -eq 3 } | Measure-Object).Count
    $elapsed   = [datetime]::Now - $script:ScriptStart
    $elStr     = fmtSpan $elapsed
    $statusStr = if ($phFail -gt 0) { "FAILED" } `
                 elseif ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) { "RUNNING" } `
                 else { "IDLE" }
    $curName   = if ($script:CurPhase -ge 0) { [string]$script:PhaseNames[$script:CurPhase] } else { "Initializing" }

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
    $title = " 'MiOS' $MiosVersion  --  Build Dashboard"
    $right = "[ $elStr ] "
    $gap   = [math]::Max(0, $in - $title.Length - $right.Length)
    $hdr   = "| $title" + (" " * $gap) + "$right |"
    $rows.Add($hdr.PadRight($winW))
    $rows.Add($sepE)

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
    $phTag = switch ([int]$script:PhStat[[math]::Max(0,$script:CurPhase)]) {
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
    $rows.Add($sepE)

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
        $script:DashLastWidth  = [math]::Max($script:DashLastWidth, $winW)
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
        Show-Dashboard
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
    } else {
        Show-Dashboard
    }
}

# Throttle Set-Step prints in log mode -- the build pipeline calls
# Set-Step on every line of native output, which would flood the log.
# Print at most once per 2 seconds OR on a substantially-changed step.
$script:LastStepLogTime = [datetime]::MinValue
$script:LastStepLogText = ""
function Set-Step([string]$T) {
    $script:CurStep = $T
    Write-Log "step: $T"
    if ($script:DashboardMode -eq 'log') {
        $now = [datetime]::Now
        $clean = ($T -replace '\s+', ' ').Trim()
        if ($clean.Length -gt 90) { $clean = $clean.Substring(0, 87) + '...' }
        $secsSince = ($now - $script:LastStepLogTime).TotalSeconds
        $isFirst   = ($script:LastStepLogTime -eq [datetime]::MinValue)
        if ($isFirst -or $secsSince -ge 2 -or $clean -ne $script:LastStepLogText) {
            $ts = $now.ToString("HH:mm:ss")
            Write-Host "  [$ts]  $clean" -ForegroundColor DarkGray
            $script:LastStepLogTime = $now
            $script:LastStepLogText = $clean
        }
    } else {
        Show-Dashboard
    }
}

function Log-Ok([string]$T)   { Write-Log "ok   $T";          Set-Step $T }
function Log-Warn([string]$T) { Write-Log "warn $T" "WARN";   Set-Step "WARN: $T" }
function Log-Fail([string]$T) { Write-Log "fail $T" "ERROR";  Set-Step "FAIL: $T" }

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
        Write-Host ""
        Write-Host "  +-- MiOS bootstrap complete --------------------------------+" -ForegroundColor Green
        if ($devDistro) {
            Write-Host ("  |  Dev distro:  {0}{1}|" -f $devDistro, (' ' * [Math]::Max(0, 44 - $devDistro.Length))) -ForegroundColor DarkGray
            Write-Host ("  |  Enter via:   wsl -d {0}{1}|" -f $devDistro, (' ' * [Math]::Max(0, 36 - $devDistro.Length))) -ForegroundColor DarkGray
            Write-Host "  +-----------------------------------------------------------+" -ForegroundColor Green
        }
        Write-Host "  |  1) Continue to build (OCI image + deployables)           |" -ForegroundColor White
        Write-Host "  |  2) Change settings (open mios.toml in configurator)      |" -ForegroundColor White
        Write-Host "  |  3) System checks (preflight + dev VM health)             |" -ForegroundColor White
        Write-Host "  |  4) Logs / reports                                        |" -ForegroundColor White
        Write-Host "  |  5) Enter dev distro now (wsl -d ...)                     |" -ForegroundColor White
        Write-Host "  |  6) Close                                                 |" -ForegroundColor White
        Write-Host "  +-----------------------------------------------------------+" -ForegroundColor Green
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
                # First-boot installs of MiOS-DEV may not yet have the bind-mount, so we
                # also ship a fallback that fetches the latest driver from raw.github so
                # an out-of-date dev-distro can self-update before invoking it.
                $driverPath = '/usr/libexec/mios/mios-build-driver'
                $fallback   = 'https://raw.githubusercontent.com/mios-dev/mios/main/usr/libexec/mios/mios-build-driver'
                $driverCmd  = @"
if [[ -x $driverPath ]]; then
    bash $driverPath
else
    echo "[handoff] $driverPath not present in $devDistro -- fetching from origin..."
    tmp=`$(mktemp)
    if curl -fsSL '$fallback' -o "`$tmp"; then
        chmod +x "`$tmp"
        bash "`$tmp"
        rm -f "`$tmp"
    else
        echo "[handoff] failed to fetch driver from $fallback" >&2
        exec bash
    fi
fi
"@
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
                    & $wt new-tab --title "MiOS Build ($devDistro)" `
                        wsl.exe -d $devDistro --user mios --cd "~" -- bash -lc $driverCmd
                } else {
                    Write-Host "  wt.exe not found -- launching wsl.exe directly in a fresh conhost window." -ForegroundColor Yellow
                    Start-Process -FilePath 'wsl.exe' `
                        -ArgumentList @('-d', $devDistro, '--user', $MiosUser, '--cd', '~', '--', 'bash', '-lc', $driverCmd)
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
                $pfl = Join-Path $MiosRepoDir 'preflight.ps1'
                if (Test-Path $pfl) {
                    Write-Host "  -> running preflight.ps1..." -ForegroundColor Cyan
                    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pfl
                } else {
                    Write-Host "  preflight.ps1 not found at $pfl" -ForegroundColor Yellow
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
                    Write-Host "  -> launching wsl -d $devDistro ..." -ForegroundColor Cyan
                    & wsl.exe -d $devDistro
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
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
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
        [int]$ShrinkMB     = 262144,
        [string]$DriveLetter = 'M',
        [string]$VolumeLabel = 'MIOS-DEV'
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
        Junction %LOCALAPPDATA%\containers\podman\machine -> $DataRoot\podman\machine
        BEFORE `podman machine init` runs, so MiOS-DEV's VHDX is created on the
        new drive in the first place (no post-hoc move + symlink dance needed).

    .NOTES
        Idempotent: existing junction with the same target is left alone. If a
        real directory already exists at the default path, its contents are
        moved over and the directory replaced with a junction.
    #>
    param([Parameter(Mandatory)][string]$DataRoot)

    $defaultDir = Join-Path $env:LOCALAPPDATA 'containers\podman\machine'
    $targetDir  = Join-Path $DataRoot 'podman\machine'
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-Path $defaultDir) {
        $item = Get-Item $defaultDir -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $current = $item.Target -join ''
            if ($current -and ($current -ieq $targetDir -or $current -ieq "\??\$targetDir")) {
                Log-Ok "podman-machine storage already junctioned -> $targetDir"
                return
            }
            # Different target -- remove and re-link
            cmd /c rmdir "`"$defaultDir`"" | Out-Null
        } else {
            # Real directory exists -- move children to target then remove
            Set-Step "Migrating existing podman-machine state to $targetDir ..."
            Get-ChildItem $defaultDir -Force | Move-Item -Destination $targetDir -Force
            Remove-Item $defaultDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    } else {
        $parent = Split-Path $defaultDir -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    # Create the junction (cmd's mklink is the standards path for NTFS reparse points)
    cmd /c mklink /J "`"$defaultDir`"" "`"$targetDir`"" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to junction $defaultDir -> $targetDir (mklink exit $LASTEXITCODE)"
    }
    Log-Ok "podman-machine storage junctioned $defaultDir -> $targetDir"
}

function New-BuilderDistro([hashtable]$HW) {
    Set-Step "Initializing $DevDistro ($($HW.Cpus) CPUs / $($HW.RamGB)GB / $($HW.DiskGB)GB disk)"
    # Cap at the OS-reported physical RAM (what podman validates) minus 512 MB safety margin.
    # Nominal $HW.RamGB rounds up from actual hardware, causing podman to reject the request.
    $ramMB = [math]::Max(4096, [math]::Min($HW.OsTotalRamMB - 512, $HW.RamGB * 1024 - 512))

    # Data disk + podman storage redirection happened earlier in
    # Invoke-DataDiskBootstrap (between Phase 1 and Phase 2). By the
    # time we reach Phase 3 the partition is provisioned and
    # CONTAINERS_STORAGE_CONF / podman.connections already point at
    # the data disk. $HW.DiskGB has also been clamped there.
    $diskGB = $HW.DiskGB

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
    $initRc      = $LASTEXITCODE
    $initJoined  = ($initOut -join " ")
    if ($initRc -ne 0) {
        # "VM already exists" -- recover by starting (or treating as already
        # running) instead of failing. Caller's outer loop already tried to
        # detect a running machine; we got here because the registration
        # exists but `podman machine ls` didn't expose it as running, which
        # also matches Windows Subsystem for Linux's transient ghost state
        # right after a previous interrupted init. Best response is just to
        # try starting it and verify the API.
        if ($initJoined -match 'already exists|VM already exists') {
            Log-Warn "podman machine init: $BuilderDistro already exists -- starting instead"
            $startOut = @(& podman machine start $BuilderDistro 2>&1)
            $startOut | ForEach-Object { Write-Log "podman-recover-start: $_" }
            if (($startOut -join " ") -match 'already running') {
                Log-Ok "$BuilderDistro is already running"
            } elseif ($LASTEXITCODE -ne 0) {
                throw "podman machine start $BuilderDistro after init-already-exists failed (exit $LASTEXITCODE)"
            }
        } else {
            throw "podman machine init failed (exit $initRc)"
        }
    }
    $null = Invoke-NativeQuiet { podman machine set --default $BuilderDistro }
    Log-Ok "$DevDistro ready as default Podman machine"

    # Rootful machine-os distros are not accessible via wsl.exe or podman machine ssh.
    # Build runs from the Windows Podman client via the machine's API -- no exec needed.
    # Just verify the API is up (it should be immediately after --now).
    Set-Step "Verifying $DevDistro Podman API..."
    $deadline = (Get-Date).AddSeconds(30)
    $apiOk = $false
    while ((Get-Date) -lt $deadline) {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { $apiOk = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $apiOk) { throw "$BuilderDistro not in running state after 30 s -- check: podman machine ls" }
    Log-Ok "$DevDistro Podman API ready"
    # Overlay seed is invoked once at end of Phase 3 (covers both the
    # newly-created path and the already-running path); see the call
    # site directly above End-Phase 3 in the main flow.
}

function Invoke-MiosOverlaySeed {
    # Seed the full MiOS package surface as a live overlay inside the
    # MiOS-DEV WSL2 distro. Reads PACKAGES.md from the cloned mios.git
    # checkout and runs `dnf5 install` per fenced ```packages-*``` block.
    #
    # Why: every CLI/utility/dev tool that ships in the deployed MiOS
    # OCI image is installed live on the Windows-side dev machine too,
    # so `wsl -d podman-MiOS-DEV` lands the operator in a shell that
    # is package-equivalent to a deployed MiOS host (minus kernel/UEFI
    # which only apply to bare-metal/Hyper-V/QEMU shapes).
    #
    # Idempotent via a sentinel: skip if /var/lib/mios/.overlay-seeded
    # is newer than the source PACKAGES.md.
    Set-Step "Seeding MiOS package overlay onto $DevDistro..."
    $packagesMd = Join-Path $MiosRepoDir "mios\usr\share\mios\PACKAGES.md"
    if (-not (Test-Path $packagesMd)) {
        Log-Warn "PACKAGES.md not found at $packagesMd -- overlay seed skipped"
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
        (Join-Path $MiosRepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $MiosRepoDir "mios\usr\share\mios\mios.toml")
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
    $miosRoot = Join-Path $MiosRepoDir "mios"
    if (-not (Test-Path (Join-Path $miosRoot "Containerfile"))) {
        Log-Warn "mios.git checkout missing at $miosRoot -- Quadlet overlay skipped"
        return
    }
    $wslDistro = "podman-$DevDistro"
    $sshOk = $false
    foreach ($candidate in @($wslDistro, $DevDistro)) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; $sshOk = $true; break }
    }
    if (-not $sshOk) { Log-Warn "Cannot wsl.exe into $DevDistro -- Quadlet overlay deferred"; return }

    # Convert C:\path\to\mios -> /mnt/c/path/to/mios for the WSL side.
    $drive = $miosRoot.Substring(0,1).ToLower()
    $miosRootWsl = "/mnt/$drive" + ($miosRoot.Substring(2) -replace '\\','/')

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

sudo install -d -m 0755 /var/lib/mios
sudo touch "$SENTINEL"

active=$($NS systemctl --no-legend list-units 'mios-*' 2>/dev/null | wc -l)
echo "[quadlet-overlay] done -- $active mios-* units active"
echo "[quadlet-overlay] Cockpit:        https://localhost:9090/  (host LAN reachable via mirrored networking)"
echo "[quadlet-overlay] Podman Desktop: containers under MiOS-DEV machine carry openInBrowser labels"
echo "[quadlet-overlay] Terminal:       Ptyxis flatpak ready -- launch via WSLg, default tab is host shell"
echo "[quadlet-overlay] Ollama:         set MIOS_DEV_ENABLE_AI=1 then re-run for the local Ollama Quadlet"
'@

    # CRLF -> LF (see Invoke-MiosOverlaySeed for the rationale).
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overlayScript))
    $stage = "set -e; export MIOS_DEV_ENABLE_AI='$enableAi' MIOS_DEV_ENABLE_RUNNER='$enableRunner'; " +
             "echo '$b64' | base64 -d > /tmp/mios-quadlet-overlay.sh && chmod +x /tmp/mios-quadlet-overlay.sh; " +
             "/tmp/mios-quadlet-overlay.sh '$miosRootWsl'"
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
    $repoPath = Join-Path $MiosRepoDir "mios"

    # ── Universal MiOS-SEED merge ────────────────────────────────────────────
    # Overlay mios-bootstrap onto mios.git BEFORE invoking podman build so the
    # build context contains both layers. Without this, only mios.git's tree
    # is in the build context and bootstrap-owned files (etc/skel/.config/mios/,
    # etc/mios/profile.toml, mios.toml at root, agent entry-point .md files)
    # never reach the OCI image -- WSL/bootc deploys would diverge from the
    # Linux Total-Root-Merge path. seed-merge.ps1 is the canonical PowerShell
    # implementation; seed-merge.sh is its bash twin invoked from build-mios.sh.
    $bootstrapPath = Join-Path $MiosRepoDir "mios-bootstrap"
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
    if ($name -eq "podman-$DevDistro") {
        $podOut = ""
        try { $podOut = (& podman --connection "${DevDistro}-root" version --format '{{.Server.Version}}' 2>&1) -join "" } catch {}
        if ([string]::IsNullOrWhiteSpace($podOut) -or $podOut -match 'error|Error|fail') {
            Log-Warn "smoke: podman API not responding (got: '$podOut')"
            # Non-fatal -- some podman versions report differently
        } else {
            Log-Ok "smoke 4/4: podman API server v$($podOut.Trim())"
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
    $miosThemeSrc = Join-Path $MiosRepoDir 'mios\usr\share\mios\oh-my-posh\mios.omp.json'
    if (-not (Test-Path $miosThemeSrc)) {
        $miosThemeSrc = Join-Path $MiosRepoDir 'mios-bootstrap\usr\share\mios\oh-my-posh\mios.omp.json'
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
    # Generate one multi-size .ico (16/32/48/64/256) with a "M" glyph
    # plus an optional accent badge (chevron / arrow / grid / gear /
    # update-arrows). Writes a multi-image PNG-payload .ico so Windows
    # Explorer + Taskbar pick the best size for each rendering context.
    #
    # Badges live in the bottom-right corner (~36% of canvas); the
    # main "M" stays centered so all icons read as part of one family.
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
        # MiOS palette (Hokusai + operator): bg=#282262 accent=#F35C15 fg=#E7DFD3
        $bg     = [System.Drawing.Color]::FromArgb(40, 34, 98)
        $fg     = [System.Drawing.Color]::FromArgb(231, 223, 211)
        $accent = [System.Drawing.Color]::FromArgb(243, 92, 21)
        $green  = [System.Drawing.Color]::FromArgb(62, 119, 101)
        $g.Clear($bg)
        $ringPen = New-Object System.Drawing.Pen($accent, [math]::Max(1, $s / 32))
        $g.DrawEllipse($ringPen, 1, 1, $s - 3, $s - 3)
        $fontSize = [int]($s * 0.55)
        $font  = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold)
        $sf    = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $brush = New-Object System.Drawing.SolidBrush($fg)
        $g.DrawString('M', $font, $brush, [System.Drawing.RectangleF]::FromLTRB(0, 0, $s, $s), $sf)

        if ($Badge -ne 'plain' -and $s -ge 32) {
            $bSize = [int]($s * 0.36)
            $bX    = $s - $bSize - 1
            $bY    = $s - $bSize - 1
            # Filled badge circle (green for non-destructive, accent
            # orange for action verbs).
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
            $g.DrawString([string]$glyphChar, $glyphFont, $brush,
                [System.Drawing.RectangleF]::FromLTRB($bX, $bY, $bX + $bSize, $bY + $bSize), $sf)
            $glyphFont.Dispose()
        }
        $g.Dispose(); $font.Dispose(); $brush.Dispose(); $ringPen.Dispose()
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
wsl.exe -d (Resolve-MiosDevDistro) @args
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
    $sz  = New-Object Management.Automation.Host.Size 90, 36
    $buf = New-Object Management.Automation.Host.Size 90, 3000
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
    $bar  = '+' + ('=' * 86) + '+'
    $thin = '+' + ('-' * 86) + '+'
    Write-Host $bar -ForegroundColor DarkCyan
    $title = '|  MiOS v' + $ver
    Write-Host ($title + (' ' * (87 - $title.Length)) + '|') -ForegroundColor Cyan
    Write-Host ('|  one launcher; mios.toml is the SSOT for every deployment target' + (' ' * 21) + '|') -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
    $items = @(
        @{ Key = '1'; Name = 'Build MiOS';        Desc = 'build the deployable OCI image (Phase 6+: podman build + deploy)' },
        @{ Key = '2'; Name = 'Enter Dev VM';      Desc = 'wsl into the MiOS-DEV WSL2 distro (root shell)'                  },
        @{ Key = '3'; Name = 'Update Overlay';    Desc = 'pull mios.git + bootstrap onto / inside MiOS-DEV (mios-pull)'    },
        @{ Key = '4'; Name = 'Dashboard';         Desc = 'show the live MiOS system view (services, git tree, fastfetch)'  },
        @{ Key = '5'; Name = 'Configurator';      Desc = 'edit mios.toml in the GUI (Epiphany via WSLg)'                    },
        @{ Key = '6'; Name = 'Re-run Bootstrap';  Desc = 'rerun the localhost setup (preflight + dev VM provision)'         },
        @{ Key = '7'; Name = 'Open Install Root'; Desc = 'open ' + $Script:MiOSRoot + ' in Explorer'                        },
        @{ Key = 'q'; Name = 'Quit';              Desc = 'exit'                                                             }
    )
    foreach ($it in $items) {
        $line = '  [' + $it.Key + ']  ' + $it.Name.PadRight(22) + $it.Desc
        if ($line.Length -gt 88) { $line = $line.Substring(0, 87) + [char]0x2026 }
        $color = if ($it.Key -eq 'q') { 'DarkGray' } else { 'White' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
    Write-Host $thin -ForegroundColor DarkCyan
    $dev = Resolve-MiosDevDistro
    Write-Host '  Dev distro : ' -NoNewline -ForegroundColor DarkGray
    if ($dev) { Write-Host $dev -ForegroundColor Green } else { Write-Host 'not registered' -ForegroundColor DarkGray }
    Write-Host '  Install    : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Script:MiOSRoot -ForegroundColor White
    Write-Host '  SSOT       : ' -NoNewline -ForegroundColor DarkGray
    Write-Host '~/.config/mios/mios.toml > /etc/mios/mios.toml > /usr/share/mios/mios.toml' -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkCyan
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
    $wtSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path $wtSettings)) {
        # Preview / store-side-loaded variant
        $wtSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
    }
    # Profile commandline -- resizes the console buffer (WT has no
    # per-profile init-size knob; initialCols/Rows is window-global
    # which would clobber other tabs) then launches the MiOS hub. The
    # hub is the one canonical entry; from there the operator chooses
    # Build / Dev VM / Update / Dashboard / Configurator. Path is baked
    # in at install time so no $PROFILE round-trip is needed.
    $hubPathForJson = $hubPath -replace '\\', '\\'
    $miosCmd = ('pwsh.exe -NoExit -ExecutionPolicy Bypass -Command "& { try { $H=Get-Host; $H.UI.RawUI.BufferSize=(New-Object Management.Automation.Host.Size 90,3000); $H.UI.RawUI.WindowSize=(New-Object Management.Automation.Host.Size 90,36) } catch {}; & ''' + $hubPathForJson + ''' }"')
    if (Test-Path $wtSettings) {
        try {
            $wtJson = Get-Content $wtSettings -Raw | ConvertFrom-Json
            # Color scheme (MiOS palette).
            if (-not $wtJson.schemes) {
                $wtJson | Add-Member -NotePropertyName schemes -NotePropertyValue @() -Force
            }
            $miosScheme = [PSCustomObject]@{
                name           = 'MiOS'
                background     = '#282262'
                foreground     = '#E7DFD3'
                cursorColor    = '#F35C15'
                selectionBackground = '#1A407F'
                black          = '#282262'
                red            = '#DC271B'
                green          = '#3E7765'
                yellow         = '#F35C15'
                blue           = '#1A407F'
                purple         = '#734F39'
                cyan           = '#B7C9D7'
                white          = '#E7DFD3'
                brightBlack    = '#948E8E'
                brightRed      = '#DC271B'
                brightGreen    = '#3E7765'
                brightYellow   = '#F35C15'
                brightBlue     = '#1A407F'
                brightPurple   = '#925837'
                brightCyan     = '#B7C9D7'
                brightWhite    = '#E0E0E0'
            }
            $schemes = @($wtJson.schemes | Where-Object { $_.name -ne 'MiOS' })
            $schemes += $miosScheme
            $wtJson.schemes = $schemes

            # Profile.
            if (-not $wtJson.profiles) {
                $wtJson | Add-Member -NotePropertyName profiles -NotePropertyValue ([PSCustomObject]@{ list = @() }) -Force
            }
            if (-not $wtJson.profiles.list) {
                $wtJson.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
            }
            $miosGuid = '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}'
            $miosProfile = [PSCustomObject]@{
                guid              = $miosGuid
                name              = 'MiOS'
                commandline       = $miosCmd
                startingDirectory = '%USERPROFILE%'
                icon              = $(if ($icoPath) { $icoPath } else { 'ms-appx:///ProfileIcons/{61c54bbd-c2c6-5271-96e7-009a87ff44bf}.png' })
                colorScheme       = 'MiOS'
                # Geist Mono is the Vercel face; Symbols-Only Nerd Font
                # is registered alongside so DirectWrite font-fallback
                # picks it up for PUA (Powerline + Devicon) glyphs.
                font              = [PSCustomObject]@{
                    face = 'Geist Mono'
                    size = 11
                }
                useAcrylic        = $false
                opacity           = 100
                cursorShape       = 'bar'
                antialiasingMode  = 'cleartype'
            }
            $list = @($wtJson.profiles.list | Where-Object { $_.guid -ne $miosGuid })
            $list += $miosProfile
            $wtJson.profiles.list = $list

            $wtJson | ConvertTo-Json -Depth 20 | Set-Content -Path $wtSettings -Encoding UTF8
            Log-Ok "Windows Terminal MiOS profile injected at $wtSettings"
        } catch {
            Log-Warn "Windows Terminal settings.json patch failed: $($_.Exception.Message)"
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
        return $LnkPath
    }

    # ── ONE shortcut: MiOS (the hub) ─────────────────────────────────
    # Replaces the previous six per-verb shortcuts. Operators launch
    # MiOS, get the hub menu, pick a verb. All verbs reachable from
    # one icon. Desktop and Start Menu both point at the same hub.
    # Per-verb shortcuts are intentionally not generated -- the Start
    # Menu noise was a recurring user complaint and the underlying
    # bin scripts (mios-hub, mios-dash, mios-dev, ...) are still
    # directly invocable from any pwsh shell as PROFILE functions.
    $hubResizePrelude = "try { `$H=Get-Host; `$H.UI.RawUI.WindowSize=(New-Object Management.Automation.Host.Size 90,36) } catch {}"
    if ($wtExe) {
        # Prefer Windows Terminal's MiOS profile (correct font + scheme).
        # WT's profile commandline already resizes the buffer + launches
        # the MiOS app; here we just ask WT to open that profile.
        $hubTarget = $wtExe
        $hubArgs   = '-p MiOS'
    } else {
        $hubTarget = $pwshExe
        $hubArgs   = "-NoExit -ExecutionPolicy Bypass -Command `"& { $hubResizePrelude; & '$hubPath' }`""
    }

    $hubDesc = 'MiOS -- Immutable Fedora AI workstation. One launcher; all verbs accessible from the menu inside.'
    $smLnk   = Join-Path $StartMenuDir 'MiOS.lnk'
    New-MiosShortcut -LnkPath $smLnk -TargetExe $hubTarget -ArgsString $hubArgs -IconFile $icoPath -Description $hubDesc | Out-Null
    Log-Ok "Start Menu: $smLnk"

    if (Test-Path $desktopDir) {
        $deskLnk = Join-Path $desktopDir 'MiOS.lnk'
        New-MiosShortcut -LnkPath $deskLnk -TargetExe $hubTarget -ArgsString $hubArgs -IconFile $icoPath -Description $hubDesc | Out-Null
        Log-Ok "Desktop: $deskLnk"
    }

    # Garbage-collect any stale per-verb shortcuts left over from
    # earlier launcher revisions. Idempotent: if absent, skip.
    foreach ($legacy in @('Build MiOS.lnk','MiOS Dev VM.lnk','MiOS Update.lnk','MiOS Dashboard.lnk','MiOS Configurator.lnk','MiOS Rebuild.lnk','MiOS Build.lnk','MiOS Setup.lnk','MiOS Terminal.lnk','MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','Uninstall MiOS.lnk')) {
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
Try-ResizeConsole -Cols 100 -Rows 40
# Interactive (in-place repaint) is now the DEFAULT. Test-DashboardCanRedraw
# probes [Console]::CursorTop, RawUI.WindowSize, etc. and falls back to log
# mode automatically if the host can't redraw (transcript host, redirected
# stdout, very narrow terminal). Set MIOS_DASHBOARD_MODE=log to force the
# linear-log fallback explicitly (useful for CI / non-tty pipelines).
$script:DashboardMode = if ($env:MIOS_DASHBOARD_MODE -eq 'log') {
    'log'
} elseif (Test-DashboardCanRedraw) {
    'interactive'
} else {
    'log'
}

# ── Banner ───────────────────────────────────────────────────────────────────
Clear-Host
$b = "+" + ("=" * ($script:DW - 2)) + "+"
$pad = [math]::Max(0, $script:DW - 4 - "MiOS $MiosVersion  --  Unified Windows Installer".Length)
Write-Host $b                                                                       -ForegroundColor Cyan
Write-Host ("| 'MiOS' $MiosVersion  --  Unified Windows Installer" + (" " * $pad) + " |") -ForegroundColor Cyan
Write-Host ("| Immutable Fedora AI Workstation" + (" " * ($script:DW - 34)) + " |") -ForegroundColor Cyan
Write-Host ("| WSL2 + Podman  |  Offline Build Pipeline" + (" " * ($script:DW - 43)) + " |") -ForegroundColor Cyan
Write-Host $b                                                                       -ForegroundColor Cyan
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

Show-Dashboard   # draw initial (all phases pending)

# ── Phase 0 -- Hardware + Prerequisites ──────────────────────────────────────
Start-Phase 0
$HW = Get-Hardware
Write-Log "hw: CPU=$($HW.Cpus)  RAM=$($HW.RamGB)GB  Disk=$($HW.DiskGB)GB  GPU=$($HW.GpuName)"
Write-Log "hw: Base=$($HW.BaseImage)  Model=$($HW.AiModel)"
$gpuShort = $HW.GpuName -replace 'NVIDIA GeForce ','RTX ' -replace 'NVIDIA Quadro ','Quadro '
$script:HWInfo    = "Host:$($env:COMPUTERNAME)  RAM:$($HW.RamGB)GB  CPU:$($HW.Cpus)c  GPU:$gpuShort  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')"
$script:IdentInfo = "Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$($HW.AiModel)"
Show-Dashboard

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
    $miosRepo = Join-Path $MiosRepoDir "mios"
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
    # Skip phases 2-8, go straight to build
    for ($s = 2; $s -le 8; $s++) {
        $script:PhStat[$s] = 2
        $script:PhStart[$s] = [datetime]::Now
        $script:PhEnd[$s]   = [datetime]::Now
    }
    Show-Dashboard

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

    foreach ($r in @(
        @{ Path=(Join-Path $MiosRepoDir "mios");           Url=$MiosRepoUrl;      Name="mios.git" },
        @{ Path=(Join-Path $MiosRepoDir "mios-bootstrap"); Url=$MiosBootstrapUrl; Name="mios-bootstrap.git" }
    )) {
        if (Test-Path (Join-Path $r.Path ".git")) {
            # Hard-reset to origin/main so the build context always
            # matches what's on the remote. `git pull --ff-only` was
            # too soft -- if the working tree had stale files (from a
            # legacy-install migration where /XO/XN/XC kept older
            # files at the destination) the pull silently no-op'd
            # and the build kept running pre-fix scripts.
            Set-Step "Updating $($r.Name) (fetch + hard reset)"
            Push-Location $r.Path
            try {
                $fetchExit = Invoke-NativeQuiet { git fetch --depth=1 origin main }
                if ($fetchExit -eq 0) {
                    $resetExit = Invoke-NativeQuiet { git reset --hard FETCH_HEAD }
                    if ($resetExit -ne 0) {
                        Log-Warn "$($r.Name): git reset --hard returned $resetExit"
                    }
                } else {
                    Log-Warn "$($r.Name): git fetch returned $fetchExit -- working tree may be stale"
                }
            } finally { Pop-Location }
        } else {
            Set-Step "Cloning $($r.Name)"
            $cloneExit = Invoke-NativeQuiet { git clone --depth 1 $r.Url $r.Path }
            if ($cloneExit -ne 0) {
                Log-Fail "$($r.Name): git clone exited $cloneExit"
                throw "git clone $($r.Url) -> $($r.Path) failed (exit $cloneExit). Check network connectivity and that the URL is reachable."
            }
        }
        Log-Ok $r.Name
    }

    # ── Materialize bootstrap files into the install dir ─────────────────────
    # Both repos are cloned into $MiosRepoDir, but a "native Windows app"
    # install also exposes the bootstrap-side templates and entry scripts
    # under predictable, non-git-shaped paths so Windows tooling, shortcuts,
    # and the uninstaller don't have to traverse a .git working tree.
    #
    #   $MiosBinDir                     entry-point .ps1 scripts (Get-MiOS, build-mios, uninstall)
    #   $MiosShareDir\bootstrap\etc     mios-bootstrap/etc tree (skel templates, mios.toml)
    #   $MiosShareDir\bootstrap\usr     mios-bootstrap/usr tree (system overlay templates)
    #   $MiosShareDir\system\usr        mios.git/usr tree (factory FHS overlay; read-only ref)
    #
    # robocopy is used over Copy-Item so we get incremental sync semantics
    # (only changed files re-copy on re-run). /MIR mirrors content + deletes
    # stale files; /NJH /NJS suppress the header/summary so output stays terse.
    Set-Step "Materializing bootstrap files into install dir"
    $bootstrapSrc = Join-Path $MiosRepoDir "mios-bootstrap"
    $miosSrc      = Join-Path $MiosRepoDir "mios"
    $copyPairs = @(
        @{ Src=(Join-Path $bootstrapSrc "etc"); Dst=(Join-Path $MiosShareDir "bootstrap\etc") },
        @{ Src=(Join-Path $bootstrapSrc "usr"); Dst=(Join-Path $MiosShareDir "bootstrap\usr") },
        @{ Src=(Join-Path $miosSrc      "usr"); Dst=(Join-Path $MiosShareDir "system\usr")    }
    )
    foreach ($p in $copyPairs) {
        if (Test-Path $p.Src) {
            $null = New-Item -ItemType Directory -Path $p.Dst -Force -ErrorAction SilentlyContinue
            # robocopy uses exit codes 0-7 to mean SUCCESS (e.g. 1 = files
            # copied; 2 = extra files at dest, ignored; 4 = mismatched).
            # Wrap via Invoke-NativeQuiet so the exit code -- whatever it
            # is -- doesn't trip $ErrorActionPreference='Stop'.
            $null = Invoke-NativeQuiet { robocopy $p.Src $p.Dst /MIR /NJH /NJS /NFL /NDL /NP }
        }
    }
    # Stage entry-point scripts under $MiosBinDir so Start Menu shortcuts
    # and PATH integration target a stable, non-git location.
    foreach ($script in @("Get-MiOS.ps1","build-mios.ps1","build-mios.sh","bootstrap.ps1","bootstrap.sh")) {
        $srcFile = Join-Path $bootstrapSrc $script
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $MiosBinDir $script) -Force
        }
    }
    # Drop a VERSION marker at the install root so external tools (and the
    # operator) can identify the installed release without a git query.
    Set-Content -Path (Join-Path $MiosInstallDir "VERSION") -Value $MiosVersion -Encoding ASCII -Force
    Log-Ok "Bootstrap files materialized under $MiosShareDir"
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
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "^$([regex]::Escape($n))\s+true" }
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
    # Also accept a stopped machine and start it
    if (-not $machineRunning) {
        try {
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))" }
            if ($ml) {
                Set-Step "Starting existing $BuilderDistro machine..."
                $startOut = @(& podman machine start $BuilderDistro 2>&1)
                $startOut | ForEach-Object { Write-Log "podman-start: $_" }
                $startJoined = ($startOut -join " ")
                if ($LASTEXITCODE -eq 0) {
                    $machineRunning = $true; Log-Ok "$BuilderDistro started"
                } elseif ($startJoined -match 'already running') {
                    # Non-zero exit + 'already running' message: machine
                    # IS running, podman is just being noisy. Treat as OK.
                    $machineRunning = $true
                    Log-Ok "$BuilderDistro already running (podman reported the state non-fatally)"
                } elseif ($startJoined -match "DISTRO_NOT_FOUND|bootstrap script failed|WSL_E_DISTRO") {
                    # Stale Podman machine metadata -- WSL distro was deleted but Podman registry entry remains.
                    # Force-remove the stale entry so New-BuilderDistro can re-init cleanly.
                    Write-Log "podman-start: stale machine registration detected -- removing $BuilderDistro" "WARN"
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
        New-BuilderDistro -HW $HW
    }

    # Run the overlay seed regardless of whether the machine was just created or
    # was already running. Idempotent via /var/lib/mios/.overlay-seeded -- a
    # second pass is a no-op when PACKAGES.md hasn't changed since last seed.
    # This is what catches the re-run case (operator runs build-mios.ps1 again
    # after editing PACKAGES.md): every section delta gets installed live.
    Invoke-MiosOverlaySeed

    # Quadlet/systemd overlay -- copies the MiOS FHS overlay into MiOS-DEV and
    # enables the lightweight container set (cockpit.socket, mios-cockpit-link,
    # mios-forge). Heavy services (mios-ai, mios-forgejo-runner) are opt-in via
    # MIOS_DEV_ENABLE_AI=1 / MIOS_DEV_ENABLE_RUNNER=1. Idempotent via
    # /var/lib/mios/.quadlet-overlay-seeded sentinel.
    Invoke-MiosQuadletOverlay

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
    $repoPath = Join-Path $MiosRepoDir "mios"
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
        Show-PostBootstrapMenu
        return
    }

    # Operator can pre-fill mios.toml fields via the HTML page; the
    # Phase-6 prompts that follow then default to whatever was saved.
    # Skipped when -Unattended or MIOS_NO_CONFIGURATOR=1.
    Open-Configurator -RepoDir $MiosRepoDir

    # ── Phase 6 -- Identity ───────────────────────────────────────────────────
    Start-Phase 6
    $script:CurStep = "Waiting for identity input..."
    Show-Dashboard
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

    # ── Phase 8 -- App registration + Start Menu ──────────────────────────────
    Start-Phase 8
    $pwsh      = if (Get-Command pwsh -EA SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
    # Entry-point scripts live under $MiosBinDir (materialized in Phase 2).
    # Prefer build-mios.ps1 (current canonical entry); fall back to the
    # legacy install.ps1 redirector if an old install is being re-run.
    $selfSc    = if (Test-Path (Join-Path $MiosBinDir "build-mios.ps1")) {
                     Join-Path $MiosBinDir "build-mios.ps1"
                 } else {
                     Join-Path $MiosRepoDir "mios-bootstrap\install.ps1"
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
    @(
        @{ F="MiOS Setup.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`"";              D="Re-run full 'MiOS' setup" },
        @{ F="Build MiOS.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`" -BuildOnly";    D="Build 'MiOS' OCI image (Phase 6+: identity, podman build, deploy)" },
        @{ F="MiOS Configurator.lnk";  T=$pwsh;     A="-NoProfile -ExecutionPolicy Bypass -File `"$cfgScript`""; D="Edit mios.toml in Epiphany via WSLg" },
        @{ F="MiOS Terminal.lnk";      T="wsl.exe"; A="-d $MiosWslDistro";                                       D="Open 'MiOS' workstation terminal" },
        @{ F="MiOS Dev Shell.lnk";     T="wsl.exe"; A="-d $DevDistro --user root";                               D="Open $DevDistro terminal (root)" },
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
    End-Phase 8

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
    if ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) {
        try { End-Phase $script:CurPhase -Fail } catch {}
    }
    Show-Dashboard
} finally {
    # Always show final summary and keep window open
    try { [Console]::SetCursorPosition(0, $script:DashRow + $script:DashHeight) } catch {}

    $totalTime = fmtSpan ([datetime]::Now - $script:ScriptStart)
    Write-Host ""
    $b = "+" + ("=" * ($script:DW - 2)) + "+"
    if ($ExitCode -eq 0) {
        $artifactDir = Join-Path $MiosDistroDir "artifacts"
        Write-Host $b -ForegroundColor Green
        $l = "| 'MiOS' $MiosVersion built and deployed!  (total: $totalTime)"
        Write-Host ($l.PadRight($script:DW - 1) + "|") -ForegroundColor Green
        Write-Host ("| OCI   : localhost/mios:latest  in $BuilderDistro".PadRight($script:DW - 1) + "|") -ForegroundColor White
        $wslLine = "| WSL2  : wsl -d $MiosWslDistro"
        $wslDistroOk = (& wsl.exe -l --quiet 2>$null) -join " " -match $MiosWslDistro
        if ($wslDistroOk) {
            Write-Host ($wslLine.PadRight($script:DW - 1) + "|") -ForegroundColor Cyan
        } else {
            Write-Host ("| WSL2  : see $artifactDir\mios-wsl2.tar".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        }
        $qcow2 = Join-Path $artifactDir "mios.qcow2"
        $raw   = Join-Path $artifactDir "mios.raw"
        if (Test-Path $qcow2) { Write-Host ("| QEMU  : $qcow2".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        if (Test-Path $raw)   { Write-Host ("| RAW   : $raw".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        $hvVm = try { Get-VM -Name $MiosWslDistro -EA SilentlyContinue } catch { $null }
        if ($hvVm) { Write-Host ("| HV    : Hyper-V VM '$MiosWslDistro' ready -- Start-VM -Name $MiosWslDistro".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        Write-Host ("| Logs  : $MiosLogDir".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Green
    } else {
        Write-Host $b -ForegroundColor Red
        Write-Host ("| BUILD FAILED (exit $ExitCode)  --  Errors: $($script:ErrCount)".PadRight($script:DW - 1) + "|") -ForegroundColor Red
        Write-Host ("| Log  : $LogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Re-run : podman build --no-cache -t localhost/mios:latest $MiosRepoDir\mios".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Log directory: $MiosLogDir" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $Unattended) {
        Write-Host "  Press Enter to close..." -ForegroundColor DarkGray -NoNewline
        $null = Read-Host
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
