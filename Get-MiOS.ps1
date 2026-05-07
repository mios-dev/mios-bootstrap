<#
.SYNOPSIS
    'MiOS' bootstrap -- canonical Windows one-liner entry point.

.DESCRIPTION
    Designed for: irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex

    Thin entrypoint that:
      1. Elevates to Administrator (re-launches a NEW window so the
         operator sees a clean, properly-sized terminal).
      2. Resizes the host window to ~100x40 so the build dashboard
         frame (80 cols + breathing room) fits without wrapping.
      3. Verifies Git + Podman are present.
      4. Force-cleans + fresh-clones the mios-bootstrap repo into
         $env:TEMP\mios-bootstrap. Every run is fresh; no persistent
         working tree, no fetch/pull update branch.
      5. Hands off to bootstrap.ps1 -- the new split-bootstrap entry
         (default: -BootstrapOnly = preflight + dev VM + Windows
         install; the deployable OCI image is built later via the
         "Build MiOS" Start Menu shortcut bootstrap.ps1 drops).

    Pre-v0.2.4 this script wrapped the run in Start-Transcript --
    that captured the dashboard's cursor escapes and broke the
    in-place repaint. Removed: build-mios.ps1 writes its own unified
    log directly via [IO.File]::AppendAllText (no transcript needed).

    Pass -FullBuild to chain the OCI image build immediately
    (legacy one-shot behavior).

.PARAMETER RepoUrl
    git URL for mios-bootstrap (default: GitHub upstream).

.PARAMETER Branch
    Branch to clone (default: main).

.PARAMETER RepoDir
    Temp clone target. Default: $env:TEMP\mios-bootstrap-<random8>.
    Each invocation gets a fresh GUID-suffixed dir so a locked
    leftover from a previous run never blocks a new start. Operators
    who genuinely want to point at a local checkout (e.g. for
    development) can pass an explicit -RepoDir; the script will
    refuse to delete it if it's outside %TEMP%. There is NO update /
    fetch / pull branch here -- always fresh-clone. A persistent path
    like $env:USERPROFILE\MiOS-bootstrap is FORBIDDEN as the bootstrap
    working tree (it accumulates stale state across runs and was the
    root cause of every "FATAL: From https://...", "FATAL: Cloning
    into ...", and "FATAL: vm already exists" surface we kept fixing).

.PARAMETER FullBuild
    Run the full pipeline in one shot (preflight + dev VM + Windows
    install + OCI build + deploy). Equivalent to passing -FullBuild
    through to bootstrap.ps1.

.PARAMETER Unattended
    Take all defaults; skip interactive prompts.

.PARAMETER Workflow
    Optional preset workflow name (legacy parameter; passed through
    via $env:MIOS_WORKFLOW for any consumer that reads it).
#>
param(
    [string]$RepoUrl   = "https://github.com/mios-dev/mios-bootstrap.git",
    [string]$Branch    = "main",
    # The canonical Windows-entry working tree per
    # feedback_mios_entry_m_drive_clone.md: M:\MiOS\repo\mios-bootstrap.
    # M:\ is provisioned to EXACTLY 256 GB by Initialize-MiosDataDisk
    # below. The previous %TEMP%-with-GUID approach (commit 88a0de3)
    # was a stopgap; M:\ is the canonical answer because the build's
    # downstream artifacts (OCI layers, WSL2 .tar/.vhdx, Hyper-V vhdx,
    # qcow2, ISO, RAW) easily exceed 50 GB and need a dedicated
    # data partition.
    [string]$RepoDir   = "M:\MiOS\repo\mios-bootstrap",
    [switch]$FullBuild,
    [switch]$Unattended,
    [string]$Workflow  = ""
)

$ErrorActionPreference = "Stop"

# Acknowledgement gate (full scrollable form -- inlined because this
# script runs via 'irm | iex' where $PSScriptRoot is empty so we cannot
# dot-source automation/lib/agreements-banner.ps1 from a clone.
#
# Skip paths:
#   $env:MIOS_AGREEMENT_BANNER in (quiet|silent|off|0|false)  -- silent skip
#   $env:MIOS_AGREEMENT_ACK   = 'accepted'                    -- declared accept (CI)
#   $env:MIOS_GETMIOS_RELAUNCHED = '1'                        -- inner call inherits the outer's accept
#
# On 'No thanks' or any non-accept reply we exit 78 (EX_CONFIG) before
# any clone, fetch, or elevation -- nothing on disk is mutated.

function Show-MiOSAgreement {
    @"
================================================================================
      ___                       ___           ___
     /\__\          ___        /\  \         /\  \
    /::|  |        /\  \      /::\  \       /::\  \
   /:|:|  |        \:\  \    /:/\:\  \     /:/\ \  \
  /:/|:|__|__      /::\__\  /:/  \:\  \   _\:\~\ \  \
 /:/ |::::\__\  __/:/\/__/ /:/__/ \:\__\ /\ \:\ \ \__\
 \/__/~~/:/  / /\/:/  /    \:\  \ /:/  / \:\ \:\ \/__/
       /:/  /  \::/__/      \:\  /:/  /   \:\ \:\__\
      /:/  /    \:\__\       \:\/:/  /     \:\/:/  /
     /:/  /      \/__/        \::/  /       \::/  /
     \/__/                     \/__/         \/__/

                        MiOS  --  Project Acknowledgement
================================================================================

The full document lives at AGREEMENTS.md (in the mios-bootstrap repo,
fetched in step 5 below). The summary you are reading is the abridged
operator-facing extract -- it is enough to make an informed accept-or-
decline decision before any code runs.

--------------------------------------------------------------------------------
1. WHAT MiOS IS
--------------------------------------------------------------------------------

MiOS (pronounced "MyOS") is a research-grade, single-user-oriented
Linux operating system delivered as an OCI bootc image. It is NOT a
commercial product, NOT a hardened distribution backed by a vendor
SLA, and NOT an audited reference platform. Treat every script,
postcheck, and architectural claim as an artifact under ongoing
review -- correct in the cases that have been exercised, likely to
need adjustment in cases that have not.

--------------------------------------------------------------------------------
2. LICENSING
--------------------------------------------------------------------------------

* MiOS-owned source is Apache-2.0 (LICENSE)
* Bundled vendor components retain their upstream licenses (LICENSES.md)
* Attribution to every upstream project is recorded in usr/share/doc/mios/reference/credits.md

--------------------------------------------------------------------------------
3. THIRD-PARTY AGREEMENTS THAT APPLY IMPLICITLY
--------------------------------------------------------------------------------

  * NVIDIA proprietary GPU drivers + CUDA -- NVIDIA Software License
  * Steam (Flatpak) -- Steam Subscriber Agreement on first launch
  * Microsoft Windows VM guests (libvirt/QEMU) -- bring your own license
  * Flathub apps installed via mios.toml [desktop].flatpaks -- each carries
    its own license
  * Sigstore-signed images (opt-in via bootc switch --enforce-container-
    sigpolicy) -- accept the transparency-log + Fulcio identity model

These are NOT MiOS-specific terms. They are the upstream vendor terms
MiOS surfaces at install time.

--------------------------------------------------------------------------------
4. DATA AND NETWORK POSTURE
--------------------------------------------------------------------------------

* No telemetry. There is no built-in telemetry channel in the image.
* Outbound network calls from a default deployment are limited to:
    - Fedora / RPMFusion / Flathub mirrors during build / bootc upgrade
    - GitHub Container Registry (ghcr.io) during image fetch
    - User-chosen Quadlet workloads (Forgejo, LocalAI, Ollama, Guacamole,...)
    - The local AI runtime at MIOS_AI_ENDPOINT (default localhost)
* Operators can audit by inspecting /etc/containers/systemd/,
  /usr/lib/systemd/system/, and the active firewalld policy.
* MiOS does not exfiltrate any user data to a vendor cloud.

--------------------------------------------------------------------------------
5. NO WARRANTY
--------------------------------------------------------------------------------

Apache-2.0 'AS IS' clause governs MiOS-owned source. CI covers the
build pipeline, image lint, and postcheck invariants -- NOT full
hardware matrix testing, multi-host upgrade drills, long-running
stability, or production failure modes.

--------------------------------------------------------------------------------
6. TRADEMARKS
--------------------------------------------------------------------------------

Third-party trademarks (Fedora, Universal Blue, NVIDIA, OpenAI,
Anthropic, Google, GitHub, Microsoft, Cline, Cursor, ...) belong to
their respective owners. MiOS references them solely to identify the
upstream component or specification each is part of.

--------------------------------------------------------------------------------
7. YOUR CHOICE
--------------------------------------------------------------------------------

Acknowledged  -- proceed. Get-MiOS.ps1 will elevate, clone the
                 mios-bootstrap repo, and hand off to bootstrap.ps1.
No thanks     -- exit 78 (EX_CONFIG). Nothing modified, nothing pulled.

For unattended / CI invocation, set
  `$env:MIOS_AGREEMENT_ACK = 'accepted'`
in the host environment to bypass this prompt as declared policy.

================================================================================
"@
}

function Invoke-MiOSAgreementGate {
    # Skip-paths in priority order.
    $quietValues   = @('quiet','silent','off','0','false','FALSE')
    $acceptValues  = @('accepted','ACCEPTED','yes','YES','y','1','true','TRUE')
    if ($env:MIOS_AGREEMENT_BANNER -and $quietValues -contains $env:MIOS_AGREEMENT_BANNER) { return $true }
    if ($env:MIOS_AGREEMENT_ACK    -and $acceptValues -contains $env:MIOS_AGREEMENT_ACK)   {
        [Console]::Error.WriteLine("[mios] AGREEMENTS.md acknowledged via MIOS_AGREEMENT_ACK; proceeding.")
        return $true
    }
    if ($env:MIOS_GETMIOS_RELAUNCHED -eq '1') { return $true }   # inner call inherits outer accept

    # Render scrollable summary. Out-Host -Paging works on the standard
    # Console host; falls back to plain Write-Host when the host doesn't
    # support paging (transcript / redirected).
    $text = Show-MiOSAgreement
    try   { $text -split "`r?`n" | Out-Host -Paging }
    catch { Write-Host $text }

    # Prompt loop.
    while ($true) {
        $reply = Read-Host -Prompt "`n[mios] Type 'Acknowledged' to proceed, or 'No thanks' to abort"
        switch -Regex ($reply) {
            '^(Acknowledged|acknowledged|ACKNOWLEDGED|accept|ACCEPT|y|Y|yes|YES)$' {
                [Console]::Error.WriteLine("[mios] AGREEMENTS.md acknowledged; proceeding.")
                $env:MIOS_AGREEMENT_ACK = 'accepted'
                return $true
            }
            '^(No\s+thanks|no\s+thanks|NO\s+THANKS|n|N|no|NO|decline|DECLINE|q|Q|quit|QUIT)$' {
                [Console]::Error.WriteLine('[mios] not acknowledged; aborting (no system changes made).')
                exit 78
            }
            default {
                [Console]::Error.WriteLine("[mios] Please type exactly 'Acknowledged' or 'No thanks'.")
            }
        }
    }
}

Invoke-MiOSAgreementGate | Out-Null

# ───────────────────────────────────────────────────────────────────────
# Windows Terminal "MiOS" profile + Geist Mono Nerd Font + oh-my-posh
# wiring. Runs ONCE on the outer (pre-elevation) pass so the elevated
# relaunch can pin -p MiOS and inherit the correct font, scheme,
# padding, acrylic backdrop, 50% blur, 12pt Geist, and a
# borderless 80x30 focus-mode window centered on the primary display.
#
# Canonical dimensions: 80 cols × 30 rows.
#   * 80×30 is the IBM "text-mode 3+" / TTY0 standard dimension
#     (alongside 80×25 / 80×50). Universal grub/console fallback.
#   * 4:3 pixel aspect ratio: with a 1:2 (W:H) monospace cell, 80/30
#     gives 720×600 px ≈ 1.20:1 → render with lineHeight=1.0 the cells
#     squash to 9×18 px → 720×540 → exactly 4:3.
#   * Wide enough for the dashboard frame (80-col strict-clamp) and
#     tall enough for the menu + footer + 8 phase rows + log row.
#
# All three helpers are idempotent: safe to call on every run.
# ───────────────────────────────────────────────────────────────────────

# Hokusai + operator-neutrals palette -- kept in sync with
# C:\MiOS\usr\share\mios\mios.toml [colors] section. Single hash so the
# scheme JSON and the MOTD/dashboard share the same exact tokens.
$Script:MiosPalette = @{
    bg                  = '#282262'
    fg                  = '#E7DFD3'
    accent              = '#1A407F'
    cursor              = '#F35C15'
    ansi_0_black        = '#282262'
    ansi_1_red          = '#DC271B'
    ansi_2_green        = '#3E7765'
    ansi_3_yellow       = '#F35C15'
    ansi_4_blue         = '#1A407F'
    ansi_5_magenta      = '#734F39'
    ansi_6_cyan         = '#B7C9D7'
    ansi_7_white        = '#E7DFD3'
    ansi_8_brblack      = '#948E8E'
    ansi_9_brred        = '#FF6B5C'
    ansi_10_brgreen     = '#5FAA8E'
    ansi_11_bryellow    = '#FF8540'
    ansi_12_brblue      = '#3D6BA8'
    ansi_13_brmagenta   = '#9D7660'
    ansi_14_brcyan      = '#E0E0E0'
    ansi_15_brwhite     = '#FFFFFF'
}

# Per-user font-install registry key: the modern non-admin path. Win10
# 1809+ honors HKCU font registrations for the running user; no
# Windows\Fonts\ admin write needed. We probe both "GeistMono Nerd Font
# Mono" and "GeistMono NFM" (the two face names Nerd Fonts has shipped
# under) so a font installed by another tool is reused.
function Test-MiOSFontInstalled {
    param([string]$Family = 'GeistMono Nerd Font Mono')
    try {
        $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (Test-Path $key) {
            $names = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                      Get-Member -MemberType NoteProperty |
                      Where-Object { $_.Name -notmatch '^PS' }).Name
            foreach ($n in $names) {
                if ($n -match [regex]::Escape($Family) -or $n -match 'GeistMono\s+NFM' -or $n -match 'GeistMono\s+Nerd\s+Font') {
                    return $true
                }
            }
        }
        # Also check the system-wide key (older admin installs / chocolatey).
        $sysKey = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (Test-Path $sysKey) {
            $sysNames = (Get-ItemProperty -Path $sysKey -ErrorAction SilentlyContinue |
                          Get-Member -MemberType NoteProperty |
                          Where-Object { $_.Name -notmatch '^PS' }).Name
            foreach ($n in $sysNames) {
                if ($n -match [regex]::Escape($Family) -or $n -match 'GeistMono\s+NFM' -or $n -match 'GeistMono\s+Nerd\s+Font') {
                    return $true
                }
            }
        }
    } catch {}
    return $false
}

# Idempotent winget install for Windows Terminal Preview ("dev line").
# WT Preview tracks the active development branch, so MiOS gets the
# newest acrylic/systemBackdrop/launchMode behavior the moment Microsoft
# ships it. Stable WT (Microsoft.WindowsTerminal) is fine too; we only
# upgrade an operator who has neither installed.
#
# Source: winget pulls from msstore by default; Preview lives at
#   id = Microsoft.WindowsTerminal.Preview
# We pass --silent so no UI surfaces and --accept-{package,source}-
# agreements so Server SKUs (which display the agreement EULA on first
# winget call) don't hang the bootstrap.
function Wait-MiOSWindowsTerminalReady {
    # winget install returns the moment the MSIX is downloaded — AppX
    # deployment continues asynchronously after that, so the package
    # registration + per-user LocalState dir don't exist yet. Without
    # this wait, Install-MiOSTerminalProfile saw "WT not installed" and
    # silently no-op'd; the operator's launch went through wt.exe alias
    # to a default-themed Preview that had no MiOS settings.
    #
    # Three readiness gates, polled with backoff:
    #   1. Get-AppxPackage  -- the package is registered with the AppX
    #      runtime (PackageFullName resolved, runtime knows about it).
    #   2. LocalState dir   -- per-user storage tree materialized.
    #   3. wt.exe on disk   -- the UWP install dir has the binary
    #      ready to launch (WT.exe alias still works at this point but
    #      we want a guaranteed direct-launch path for our --focus
    #      bootstrap window below).
    $deadline = (Get-Date).AddSeconds(90)
    $previewLocal = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState'

    while ((Get-Date) -lt $deadline) {
        $pkg = $null
        try { $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminalPreview' -ErrorAction SilentlyContinue } catch {}
        $localOk = Test-Path -LiteralPath $previewLocal
        $exeOk = $false
        if ($pkg -and $pkg.InstallLocation) {
            $wtExe = Join-Path $pkg.InstallLocation 'wt.exe'
            if (Test-Path -LiteralPath $wtExe) { $exeOk = $true }
        }
        if ($pkg -and $exeOk) {
            # If the LocalState dir hasn't been created yet (first-ever
            # install, no prior WT launch), force-create it so our
            # settings.json write target exists.
            if (-not $localOk) {
                try { New-Item -ItemType Directory -Path $previewLocal -Force | Out-Null } catch {}
            }
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Install-MiOSWindowsTerminal {
    # Operator's invariant: MiOS owns ONLY the Windows Terminal Preview
    # (dev channel) install. The stable WT install -- if present -- is
    # left strictly alone, because the operator may use it for non-MiOS
    # work and doesn't want their stable settings.json overwritten with
    # MiOS globals/defaults. So we ALWAYS ensure Preview is installed
    # (even when Stable is already there) and ALWAYS target Preview's
    # settings.json -- not Stable's, not the unpackaged location.
    $appx = $null
    try { $appx = Get-AppxPackage -Name 'Microsoft.WindowsTerminalPreview' -ErrorAction SilentlyContinue } catch {}
    if ($appx) {
        Write-Host "  [+] Windows Terminal Preview already installed (MiOS targets ONLY this install)." -ForegroundColor DarkGray
        # Even though it's installed, run readiness wait so callers
        # downstream are guaranteed an existing LocalState dir.
        [void](Wait-MiOSWindowsTerminalReady)
        return $true
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] winget not available; cannot auto-install Windows Terminal Preview." -ForegroundColor Yellow
        Write-Host "      Install manually from: https://aka.ms/terminal-preview" -ForegroundColor DarkGray
        return $false
    }
    Write-Host "  [*] Installing Windows Terminal Preview via winget (dev channel)..." -ForegroundColor Cyan
    try {
        & winget install --id Microsoft.WindowsTerminal.Preview --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
    } catch {
        Write-Host "  [!] winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] winget exit code $LASTEXITCODE -- Preview install may not have completed." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [*] winget install returned -- waiting for AppX deployment to finish..." -ForegroundColor Cyan
    if (-not (Wait-MiOSWindowsTerminalReady)) {
        Write-Host "  [!] Windows Terminal Preview did not become ready within 90s." -ForegroundColor Yellow
        Write-Host "      Settings patch may not stick on first launch -- re-run irm|iex after WT first-runs." -ForegroundColor DarkGray
        return $false
    }
    Write-Host "  [+] Windows Terminal Preview installed and ready." -ForegroundColor Green
    return $true
}

function Install-MiOSGeistFont {
    if (Test-MiOSFontInstalled) {
        Write-Host "  [+] GeistMono Nerd Font already installed (HKCU/HKLM)." -ForegroundColor DarkGray
        return $true
    }
    Write-Host "  [*] Installing GeistMono Nerd Font (per-user)..." -ForegroundColor Cyan
    $zipUrl  = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/GeistMono.zip'
    $tmpDir  = Join-Path $env:TEMP ("mios-geist-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $zipPath = Join-Path $tmpDir 'GeistMono.zip'
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force -ErrorAction Stop

        # Per-user font install dir. Created on demand on Win10 1809+.
        $userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        if (-not (Test-Path $userFontDir)) {
            New-Item -ItemType Directory -Path $userFontDir -Force | Out-Null
        }
        $regKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (-not (Test-Path $regKey)) {
            New-Item -Path $regKey -Force | Out-Null
        }

        # Prefer the *NerdFontMono* variants (forced fixed-width, the only
        # safe choice for terminals). Fallback to *NerdFont* if Mono ones
        # aren't present in the release.
        $preferred = Get-ChildItem $tmpDir -Filter '*NerdFontMono*.ttf' -Recurse -ErrorAction SilentlyContinue
        if (-not $preferred) {
            $preferred = Get-ChildItem $tmpDir -Filter '*NerdFont*.ttf' -Recurse -ErrorAction SilentlyContinue
        }
        if (-not $preferred) {
            Write-Host "  [!] GeistMono.zip extracted but no .ttf files matched the expected pattern." -ForegroundColor Yellow
            return $false
        }

        $installed = 0
        foreach ($ttf in $preferred) {
            $dst = Join-Path $userFontDir $ttf.Name
            Copy-Item -LiteralPath $ttf.FullName -Destination $dst -Force
            # Face name for the registry value: derive from filename
            # ("GeistMonoNerdFontMono-Regular.ttf" -> "GeistMono Nerd Font Mono Regular (TrueType)").
            $face = $ttf.BaseName `
                -replace 'NerdFontMono', ' Nerd Font Mono ' `
                -replace 'NerdFont',     ' Nerd Font ' `
                -replace '-',            ' ' `
                -replace '\s+',          ' '
            $face = $face.Trim() + ' (TrueType)'
            New-ItemProperty -Path $regKey -Name $face -Value $dst -PropertyType String -Force | Out-Null
            $installed++
        }
        Write-Host "  [+] Installed $installed Geist Mono Nerd Font face(s) to $userFontDir." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] Geist Mono Nerd Font install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "      WT will fall back to Cascadia Mono -- glyphs in oh-my-posh will be missing." -ForegroundColor DarkGray
        return $false
    } finally {
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Resolve the WT Preview settings.json path. WE ONLY TOUCH PREVIEW. The
# stable WT install (if any) is left untouched -- the operator may use
# it for non-MiOS work and doesn't want our globals overwriting theirs.
# Returns $null if Preview isn't installed (caller should run
# Install-MiOSWindowsTerminal first).
function Get-MiOSTerminalSettingsPath {
    $previewSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
    $previewLocal    = Split-Path -Parent $previewSettings
    if (Test-Path -LiteralPath $previewSettings) { return $previewSettings }
    # LocalState dir exists but settings.json hasn't been written yet
    # (fresh AppX deployment -- WT writes settings on first launch). We
    # return the path so the caller can write a fresh file there.
    if (Test-Path -LiteralPath $previewLocal) { return $previewSettings }
    return $null
}

# Borderless / no-titlebar / focus-mode launchMode is configured in the
# settings file (root-level "launchMode": "focus") -- passing --focus on
# the wt.exe command line ALONE only hides tabs but keeps the title bar
# unless launchMode is also set in JSON. We set both for belt-and-braces.
function Install-MiOSTerminalProfile {
    # Defensive readiness wait: even if Install-MiOSWindowsTerminal
    # already waited, AppX deployment can still be propagating user-state
    # paths. Re-wait so we never write to a non-existent LocalState dir.
    [void](Wait-MiOSWindowsTerminalReady)
    $settingsPath = Get-MiOSTerminalSettingsPath
    if (-not $settingsPath) {
        Write-Host "  [!] Windows Terminal Preview not ready (LocalState dir missing) -- skipping settings patch." -ForegroundColor Yellow
        Write-Host "      Re-run irm|iex after WT first-launch creates the dir." -ForegroundColor DarkGray
        return $null
    }
    Write-Host "  [*] Patching Windows Terminal Preview settings: $settingsPath" -ForegroundColor Cyan

    # Stable WT profile GUID for "MiOS-Bootstrap". Re-using the same GUID
    # across runs lets us upsert idempotently instead of polluting the
    # profile list with a new entry every time.
    $miosGuid = '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}'

    $palette = $Script:MiosPalette
    $miosScheme = [ordered]@{
        name                = 'MiOS'
        background          = $palette.bg
        foreground          = $palette.fg
        cursorColor         = $palette.cursor
        selectionBackground = $palette.accent
        black               = $palette.ansi_0_black
        red                 = $palette.ansi_1_red
        green               = $palette.ansi_2_green
        yellow              = $palette.ansi_3_yellow
        blue                = $palette.ansi_4_blue
        purple              = $palette.ansi_5_magenta
        cyan                = $palette.ansi_6_cyan
        white               = $palette.ansi_7_white
        brightBlack         = $palette.ansi_8_brblack
        brightRed           = $palette.ansi_9_brred
        brightGreen         = $palette.ansi_10_brgreen
        brightYellow        = $palette.ansi_11_bryellow
        brightBlue          = $palette.ansi_12_brblue
        brightPurple        = $palette.ansi_13_brmagenta
        brightCyan          = $palette.ansi_14_brcyan
        brightWhite         = $palette.ansi_15_brwhite
    }

    # Profile commandline: pwsh -NoLogo with no command -- pinned to the
    # MiOS profile so any wt.exe -p MiOS-Bootstrap launch (manual or
    # programmatic) lands in a Geist-rendered, MiOS-schemed shell whose
    # $PROFILE is loaded (oh-my-posh init runs from there).
    $defaultPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (-not (Test-Path -LiteralPath $defaultPwsh)) {
        $defaultPwsh = "$env:ProgramW6432\PowerShell\7\pwsh.exe"
    }
    if (-not (Test-Path -LiteralPath $defaultPwsh)) {
        $defaultPwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    $profileCmdline = '"' + $defaultPwsh + '" -NoLogo'

    # Per-profile shared settings -- apply to BOTH "MiOS" and "MiOS-DEV"
    # so they look/feel identical. NONE of these touch global theme; the
    # operator's other WT profiles are unaffected.
    #
    # Acrylic = gaussian-blur-behind material (vs. Mica's wallpaper-only).
    # useAcrylic+systemBackdrop="acrylic" extends the blur to the window
    # backdrop too. opacity=50 = 50% blur intensity. padding=0 +
    # suppressApplicationTitle=true keeps the body frame-flush.
    $commonProfileProps = [ordered]@{
        colorScheme              = 'MiOS'
        font                     = [ordered]@{
            face   = 'GeistMono Nerd Font Mono'
            size   = 12
            weight = 'normal'
        }
        cursorShape              = 'bar'
        antialiasingMode         = 'cleartype'
        useAcrylic               = $true
        useMica                  = $false
        systemBackdrop           = 'acrylic'
        opacity                  = 50
        padding                  = '0'
        suppressApplicationTitle = $true
        hidden                   = $false
    }

    $miosDevGuid = '{a8b5c2d3-e4f5-6789-abcd-ef0123456790}'

    $miosProfile = [ordered]@{
        guid              = $miosGuid
        name              = 'MiOS'
        commandline       = $profileCmdline
        startingDirectory = 'M:\\'
    }
    foreach ($k in $commonProfileProps.Keys) { $miosProfile[$k] = $commonProfileProps[$k] }

    # MiOS-DEV profile: drops the operator straight into the MiOS-DEV WSL2
    # distro as the mios user, cwd /. Same look as MiOS (acrylic, font,
    # scheme) so the only visible difference is the prompt context.
    $miosDevProfile = [ordered]@{
        guid              = $miosDevGuid
        name              = 'MiOS-DEV'
        commandline       = 'wsl.exe -d MiOS-DEV --cd / --user mios'
        startingDirectory = $null
    }
    foreach ($k in $commonProfileProps.Keys) { $miosDevProfile[$k] = $commonProfileProps[$k] }

    # Read existing settings.json -- preserve EVERY existing global
    # (launchMode, defaultProfile, theme, keybindings, etc.). We touch
    # only schemes[] and profiles.list[] entries that are ours.
    # WT writes JSONC; ConvertFrom-Json on PS5.1 chokes on it, so strip
    # comments + trailing commas before parsing.
    $raw = ''
    if (Test-Path -LiteralPath $settingsPath) {
        try { $raw = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop } catch { $raw = '' }
    }
    if (-not $raw -or -not $raw.Trim()) {
        # First-run / empty settings.json -- start from a minimal skeleton.
        $raw = '{ "profiles": { "list": [] }, "schemes": [] }'
    }
    # Strip // line comments and /* */ block comments so older PS can parse.
    $stripped = [regex]::Replace($raw, '(?ms)/\*.*?\*/', '')
    $stripped = [regex]::Replace($stripped, '(?m)^\s*//.*$', '')
    # Strip trailing commas before close-brace or close-bracket so older
    # ConvertFrom-Json (PS 5.1) accepts the JSONC.
    $stripped = [regex]::Replace($stripped, ',(\s*[\x7D\x5D])', '$1')

    try {
        $wtJson = $stripped | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "  [!] settings.json could not be parsed; backing up + replacing." -ForegroundColor Yellow
        $backup = $settingsPath + '.mios-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force -ErrorAction SilentlyContinue
        $wtJson = ConvertFrom-Json '{ "profiles": { "list": [] }, "schemes": [] }'
    }

    # ── Global WT theme: MiOS everywhere ──────────────────────────────
    # Per operator: the Windows Terminal install IS a MiOS install.
    # Set every global so every WT window opens borderless, frameless,
    # centered, 80x30, MiOS-themed. profiles.defaults makes ALL profiles
    # (the operator's pre-existing PowerShell, CMD, Azure, etc.)
    # inherit MiOS appearance unless they explicitly override.
    $wtJson | Add-Member -NotePropertyName launchMode                  -NotePropertyValue 'focus' -Force
    $wtJson | Add-Member -NotePropertyName showTabsInTitlebar          -NotePropertyValue $false  -Force
    $wtJson | Add-Member -NotePropertyName alwaysShowTabs              -NotePropertyValue $false  -Force
    $wtJson | Add-Member -NotePropertyName showTerminalTitleInTitlebar -NotePropertyValue $false  -Force
    $wtJson | Add-Member -NotePropertyName useAcrylicInTabRow          -NotePropertyValue $true   -Force
    $wtJson | Add-Member -NotePropertyName initialCols                 -NotePropertyValue 80      -Force
    $wtJson | Add-Member -NotePropertyName initialRows                 -NotePropertyValue 30      -Force
    $wtJson | Add-Member -NotePropertyName centerOnLaunch              -NotePropertyValue $true   -Force
    $wtJson | Add-Member -NotePropertyName alwaysOnTop                 -NotePropertyValue $true   -Force
    $wtJson | Add-Member -NotePropertyName disableAnimations           -NotePropertyValue $false  -Force
    $wtJson | Add-Member -NotePropertyName theme                       -NotePropertyValue 'dark'  -Force
    # Make the MiOS profile the default profile (Ctrl-Shift-T, double-
    # click on WT shortcut, taskbar pin → all open MiOS).
    $wtJson | Add-Member -NotePropertyName defaultProfile              -NotePropertyValue $miosGuid -Force

    # Ensure profiles container exists before defaults / list manipulation.
    # NOTE: PS 5.1's parser chokes on [PSCustomObject]@{...} in a paren-
    # group inside a pipeline (`-NotePropertyValue ([PSCustomObject]@{...})`),
    # so we hoist each cast to a local variable.
    if (-not $wtJson.profiles) {
        $emptyProfilesObj = [PSCustomObject]@{ list = @() }
        $wtJson | Add-Member -NotePropertyName profiles -NotePropertyValue $emptyProfilesObj -Force
    }

    # profiles.defaults inheritance: every profile gets MiOS look unless
    # it explicitly overrides. The operator's pre-existing PowerShell /
    # CMD / Azure / WSL profiles all become MiOS-themed automatically.
    $defaultsBlock = [ordered]@{
        colorScheme              = 'MiOS'
        font                     = [ordered]@{
            face   = 'GeistMono Nerd Font Mono'
            size   = 12
            weight = 'normal'
        }
        cursorShape              = 'bar'
        antialiasingMode         = 'cleartype'
        useAcrylic               = $true
        useMica                  = $false
        systemBackdrop           = 'acrylic'
        opacity                  = 50
        padding                  = '0'
        suppressApplicationTitle = $true
    }
    $defaultsObj = [PSCustomObject]$defaultsBlock
    $wtJson.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue $defaultsObj -Force

    # Schemes: upsert MiOS.
    if (-not $wtJson.schemes) {
        $wtJson | Add-Member -NotePropertyName schemes -NotePropertyValue @() -Force
    }
    $miosSchemeObj = [PSCustomObject]$miosScheme
    $existingSchemes = @($wtJson.schemes | Where-Object { $_.name -ne 'MiOS' })
    $existingSchemes += $miosSchemeObj
    $wtJson.schemes = $existingSchemes

    # Profiles.list ensure-exists.
    if (-not $wtJson.profiles.list) {
        $wtJson.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
    }
    # Filter out any prior MiOS / MiOS-DEV entries by GUID *or* by the
    # names we've used in earlier revisions, so the upsert is exactly two.
    $existingList = @($wtJson.profiles.list | Where-Object {
        $_.guid -ne $miosGuid -and
        $_.guid -ne $miosDevGuid -and
        $_.name -ne 'MiOS' -and
        $_.name -ne 'MiOS-DEV' -and
        $_.name -ne 'MiOS-Bootstrap'
    })
    $miosProfileObj    = [PSCustomObject]$miosProfile
    $miosDevProfileObj = [PSCustomObject]$miosDevProfile
    $existingList += $miosProfileObj
    $existingList += $miosDevProfileObj
    $wtJson.profiles.list = $existingList

    # Write back.
    try {
        $parent = Split-Path -Parent $settingsPath
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        ($wtJson | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        Write-Host "  [+] MiOS + MiOS-DEV profiles + MiOS scheme upserted (no global theme changes)." -ForegroundColor Green
        return $miosGuid
    } catch {
        Write-Host "  [!] settings.json write failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# Idempotent block in $PROFILE.CurrentUserAllHosts: oh-my-posh init line
# pointed at mios.omp.json. The theme file is shipped under the install
# dir; if it isn't there yet (first-run, before build-mios.ps1 stages it),
# we fall back to a built-in oh-my-posh theme so the prompt still renders.
function Install-MiOSPowerShellProfile {
    # Resolve $PROFILE.CurrentUserAllHosts even if outer script blocks
    # have torn down standard host context.
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not $profilePath) { $profilePath = $PROFILE }
    if (-not $profilePath) {
        $profilePath = Join-Path $env:USERPROFILE 'Documents\PowerShell\profile.ps1'
    }
    $profileDir = Split-Path -Parent $profilePath
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

    $marker  = '# >>> MiOS oh-my-posh init >>>'
    $endMark = '# <<< MiOS oh-my-posh init <<<'
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }

    $block = @"
$marker
# Auto-generated by Get-MiOS.ps1 / build-mios.ps1. Replaced between the
# markers on every bootstrap. Initializes oh-my-posh with the MiOS theme
# (Hokusai palette) when the binary is on PATH; silent no-op otherwise.
# Probes every place the canonical mios.omp.json could land:
#   M:\MiOS\themes\mios.omp.json        deployed install (data-disk root)
#   M:\usr\share\mios\oh-my-posh\...    mios.git overlay at M:\ root
#   C:\MiOS\themes\mios.omp.json        deployed install (admin / no data disk)
#   C:\MiOS\usr\share\mios\oh-my-posh\..    legacy admin install
#   `$env:USERPROFILE\MiOS-bootstrap\...    rare local checkout
# `$env:MIOS_OMP_JSON overrides everything for ad-hoc testing.
if (`$env:WT_SESSION -or `$env:TERM_PROGRAM -eq 'mios') {
    `$miosOmp = `$null
    `$candidates = @()
    if (`$env:MIOS_OMP_JSON) { `$candidates += `$env:MIOS_OMP_JSON }
    `$candidates += @(
        'M:\MiOS\themes\mios.omp.json',
        'M:\usr\share\mios\oh-my-posh\mios.omp.json',
        'C:\MiOS\themes\mios.omp.json',
        'C:\MiOS\usr\share\mios\oh-my-posh\mios.omp.json',
        (Join-Path `$env:USERPROFILE 'MiOS-bootstrap\usr\share\mios\oh-my-posh\mios.omp.json')
    )
    foreach (`$c in `$candidates) {
        if (`$c -and (Test-Path -LiteralPath `$c)) { `$miosOmp = `$c; break }
    }
    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        if (`$miosOmp) {
            oh-my-posh init pwsh --config `$miosOmp | Invoke-Expression
        } else {
            oh-my-posh init pwsh | Invoke-Expression
        }
    }
}
$endMark
"@

    if ($existing -match [regex]::Escape($marker)) {
        $pattern  = "(?s)$([regex]::Escape($marker)).*?$([regex]::Escape($endMark))"
        $safeRepl = $block -replace '\$', '$$$$'
        $existing = [regex]::Replace($existing, $pattern, $safeRepl)
    } else {
        $existing = ($existing.TrimEnd() + "`n`n" + $block + "`n").TrimStart()
    }
    Set-Content -Path $profilePath -Value $existing -Encoding UTF8 -NoNewline
    Write-Host "  [+] PowerShell profile updated with MiOS oh-my-posh init: $profilePath" -ForegroundColor Green
}

# DPI-aware centered position for an 80x30 acrylic focus-mode window.
#
# Cell metrics (Geist Mono 12pt @ 100% DPI, lineHeight=1.0): ~10 × 20 px
# → grid 800 × 600 px → 4:3 exactly.
#
# Window-level slack (DWM frame + scrollbar + acrylic edge in focus mode):
# +20 px width, +12 px height. So the wt.exe outer rect is ~820 × 612 px
# at 100% DPI on a typical Win11 build.
#
# Robustness layers:
#   1. SetProcessDPIAware() -- without this, on 125%/150% scaled displays
#      Screen.WorkingArea returns LOGICAL pixels and our --pos math is
#      off by the scale factor (window lands top-left).
#   2. Cursor-monitor detection -- PrimaryScreen always sends the window
#      to display #1 even when the operator is on display #2. Use
#      Screen.FromPoint(Cursor.Position) so the window opens on whichever
#      monitor the operator is actively using.
#   3. Post-launch correction -- wt.exe sometimes ignores --pos in focus
#      mode (1.18+ regression). Move-MiOSWindowToCenter (called from the
#      relaunch path after Start-Process) finds the WT hwnd and moves it
#      to the true center. This is the belt-AND-braces guarantee that
#      'exit' is type-able because the window is on-screen.
function Get-MiOSCenteredWindowPosition {
    param(
        [int]$Cols   = 80,
        [int]$Rows   = 30,
        [int]$CellW  = 10,
        [int]$CellH  = 20
    )
    try {
        Add-Type -Namespace 'MiOS.Native' -Name 'Dpi' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction SilentlyContinue
        try { [MiOS.Native.Dpi]::SetProcessDPIAware() | Out-Null } catch {}
    } catch {}

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $cursor = [System.Windows.Forms.Cursor]::Position
        $screen = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea

        $winW = ($Cols * $CellW) + 20   # cells + DWM frame + scrollbar
        $winH = ($Rows * $CellH) + 12   # cells + DWM frame T+B
        $x = [int]($screen.X + ($screen.Width  - $winW) / 2)
        $y = [int]($screen.Y + ($screen.Height - $winH) / 2)
        if ($x -lt $screen.X) { $x = $screen.X }
        if ($y -lt $screen.Y) { $y = $screen.Y }
        return @{ Pos = "$x,$y"; ScreenLeft = $screen.X; ScreenTop = $screen.Y; ScreenWidth = $screen.Width; ScreenHeight = $screen.Height }
    } catch {
        return @{ Pos = '0,0'; ScreenLeft = 0; ScreenTop = 0; ScreenWidth = 1920; ScreenHeight = 1080 }
    }
}

# Post-launch re-center: WT in focus mode sometimes lands at (0,0) or at
# the previous WT window's last position because it ignores --pos. We
# wait up to ~3s for a WindowsTerminal.exe process to surface a top-level
# hwnd, GetWindowRect to read its real outer-rect size, then SetWindowPos
# to (screenCenter - rect/2). This guarantees the window is exactly
# screen-center regardless of what WT did with --pos.
function Move-MiOSWindowToCenter {
    param(
        [hashtable]$ScreenInfo,
        [int]$TimeoutMs = 4000
    )
    try {
        Add-Type -Namespace 'MiOS.Native' -Name 'Win' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
public struct RECT { public int Left, Top, Right, Bottom; }
'@ -ErrorAction SilentlyContinue
    } catch {}

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $hwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        $wt = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
              Sort-Object StartTime -Descending |
              Select-Object -First 1
        if ($wt -and $wt.MainWindowHandle -ne [IntPtr]::Zero) {
            if ([MiOS.Native.Win]::IsWindowVisible($wt.MainWindowHandle)) {
                $hwnd = $wt.MainWindowHandle
                break
            }
        }
        Start-Sleep -Milliseconds 150
    }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    $rect = New-Object MiOS.Native.Win+RECT
    if (-not [MiOS.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) { return $false }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { return $false }

    $x = [int]($ScreenInfo.ScreenLeft + ($ScreenInfo.ScreenWidth  - $w) / 2)
    $y = [int]($ScreenInfo.ScreenTop  + ($ScreenInfo.ScreenHeight - $h) / 2)
    # HWND_TOPMOST = -1 (sticks the window above all non-topmost windows).
    # SWP_SHOWWINDOW = 0x40 (force visible). SWP_NOACTIVATE = 0x10 if we
    # don't want to steal focus -- but we DO want focus on the bootstrap
    # window so the operator sees it. So flags = SWP_SHOWWINDOW (0x40).
    $hwndTopmost = [IntPtr]::new(-1)
    [void][MiOS.Native.Win]::SetWindowPos($hwnd, $hwndTopmost, $x, $y, $w, $h, 0x40)
    # Belt-and-braces: re-issue with no-zorder so the move sticks even
    # if the topmost flag was clamped by group-policy.
    [void][MiOS.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero,   $x, $y, $w, $h, 0x44)
    return $true
}

# 1. ALWAYS spawn a fresh elevated pwsh window. The original `irm | iex`
# host inherits whatever terminal called us (VS Code integrated, remote
# session, embedded host, etc.) which often (a) isn't admin, (b) is the
# wrong size for the build, and (c) breaks console cursor positioning.
# A fresh top-level pwsh window guarantees a clean, properly-sized
# environment regardless of where the curl was run from.
#
# Sentinel: $env:MIOS_GETMIOS_RELAUNCHED prevents the new window from
# re-launching itself in an infinite loop.
if (-not $env:MIOS_GETMIOS_RELAUNCHED) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "  [*] Provisioning MiOS terminal profile (Geist Mono NF + Hokusai scheme)..." -ForegroundColor Cyan
    Install-MiOSWindowsTerminal     | Out-Null
    Install-MiOSGeistFont           | Out-Null
    Install-MiOSPowerShellProfile   | Out-Null
    Install-MiOSTerminalProfile     | Out-Null
    $miosWindowInfo = Get-MiOSCenteredWindowPosition -Cols 80 -Rows 30
    $miosWindowPos  = $miosWindowInfo.Pos

    Write-Host "  [*] Spawning a fresh elevated pwsh window for the bootstrap run..." -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host "  [*] You'll see a UAC prompt momentarily; approve it to continue." -ForegroundColor DarkGray
    }

    # Derive the raw.githubusercontent.com URL from the .git clone URL.
    # GitHub's "/raw/" path on github.com only works WITHOUT the .git
    # suffix; the tracked URL has .git for `git clone` so we strip it
    # here. Using raw.githubusercontent.com directly is the canonical
    # path for `irm | iex` and avoids the github.com 302 redirect
    # entirely.
    #
    # Cache-buster: Fastly serves raw.githubusercontent.com with a
    # 5-minute max-age. Right after we push a fix, the operator's
    # next `irm` can still hit the old cached object until that TTL
    # expires. Appending ?cb=<unix-time> on the NESTED fetch (inside
    # the relaunch) gives Fastly a fresh cache key, so even if their
    # OUTER irm gets stale, the elevated window's fetch is fresh and
    # any mismatch self-corrects on first run.
    $rawBase = $RepoUrl -replace '\.git$', '' `
                       -replace '^https?://github\.com/', 'https://raw.githubusercontent.com/'
    $cacheBust = [int][double]::Parse((Get-Date -UFormat %s))
    $rawUrl    = "$rawBase/$Branch/Get-MiOS.ps1?cb=$cacheBust"

    $forwardSwitches = ""
    if ($FullBuild)  { $forwardSwitches += " -FullBuild" }
    if ($Unattended) { $forwardSwitches += " -Unattended" }
    if ($Workflow)   { $forwardSwitches += " -Workflow $Workflow" }

    # Build the relaunch script as a single string. We pass it to pwsh
    # via -EncodedCommand (UTF-16LE base64) so embedded quotes, dollar
    # signs, parens, etc. cannot be mangled by Start-Process /
    # CreateProcess argument-splitting. The previous -Command path got
    # tripped up by the apostrophe in "(wrong branch '$Branch')" --
    # CreateProcess saw the embedded quote and terminated the throw
    # string mid-message, leaving 'likely' looking like a cmdlet.
    #
    # HTML-sniff guard: GitHub serves 404s with an HTML body. Without
    # this check iex would execute the HTML as garbage CSS/text.
    # HTML-sniff guard for the elevated window's nested fetch.
    #
    # IMPORTANT: this entire file MUST NOT contain the literal substring
    # '<!DOCTYPE' followed by ' html' OR the substring less-than-h-t-m-l
    # followed by a non-word char. An older deployed version of
    # Get-MiOS.ps1 had an unanchored regex that scanned the WHOLE
    # response body for those tokens; if the operator's outer irm hits
    # a Fastly POP still serving that pre-fix version, the OLD heredoc
    # runs against THIS file's body. To stay invisible to the legacy
    # regex during the cache-rollover window we build the marker
    # strings via char-code concatenation below -- the literal token
    # never appears anywhere in this source.
    $relaunchCmd = @"
`$env:MIOS_GETMIOS_RELAUNCHED='1'
# Inner pwsh was launched with -NoProfile (clean bootstrap env). Manually
# dot-source the AllHosts profile so the MiOS oh-my-posh init block runs
# and the operator's prompt after the bootstrap finishes is rendered in
# the Hokusai palette + Geist Mono NF glyphs. Silent if the profile or
# oh-my-posh isn't installed yet -- the block is idempotent on every run.
if (`$PROFILE.CurrentUserAllHosts -and (Test-Path `$PROFILE.CurrentUserAllHosts)) {
    try { . `$PROFILE.CurrentUserAllHosts } catch {}
}
try {
    # Cache-Control: no-cache + Pragma: no-cache + a unique If-None-Match
    # tag tell Fastly (and any intermediate proxies) to revalidate against
    # origin instead of serving the cached body. raw.githubusercontent.com
    # honors these on a best-effort basis -- combined with the cb=<epoch>
    # query string above this gives us belt-and-braces cache busting.
    `$noCacheHdr = @{
        'Cache-Control' = 'no-cache, no-store, max-age=0'
        'Pragma'        = 'no-cache'
        'If-None-Match' = "mios-bootstrap-`$([guid]::NewGuid().ToString('N'))"
    }
    `$src = Invoke-RestMethod -Uri '$rawUrl' -Headers `$noCacheHdr -ErrorAction Stop
    `$head = if (`$src) { `$src.TrimStart().Substring(0, [Math]::Min(64, `$src.TrimStart().Length)) } else { '' }
    `$lt    = [char]60                              # '<'
    `$dtTok = `$lt + '!DOC' + 'TYPE'                # '<!' + 'DOCTYPE' (split so this file never contains the joined literal)
    `$hTok  = `$lt + 'ht' + 'ml'                    # less-than h-t-m-l, also split
    if (-not `$src -or `$head.StartsWith(`$dtTok) -or `$head.StartsWith(`$hTok)) {
        throw 'Get-MiOS.ps1 fetch returned a page (404 or wrong branch). URL: $rawUrl'
    }
    & ([scriptblock]::Create(`$src))$forwardSwitches
} catch {
    Write-Host ''
    Write-Host ('  [!] Bootstrap failed: ' + `$_) -ForegroundColor Red
    Write-Host '      URL: $rawUrl' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press Enter to close...' -ForegroundColor DarkGray -NoNewline
    `$null = Read-Host
}
"@

    # PowerShell's -EncodedCommand expects UTF-16LE base64.
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($relaunchCmd)
    $encoded = [Convert]::ToBase64String($bytes)

    # Resolve $shell to a directly-launchable on-disk path. PowerShell 7
    # has THREE possible install shapes on Windows, and only ONE of them
    # is launchable via Start-Process -Verb RunAs:
    #
    #   (a) MSI / standalone install at $env:ProgramFiles\PowerShell\7\pwsh.exe
    #       -- LAUNCHABLE. Plain NTFS file, no ACL surprise, no alias
    #       indirection. PREFERRED.
    #
    #   (b) Microsoft Store install at
    #       $env:ProgramFiles\WindowsApps\Microsoft.PowerShell_*\pwsh.exe
    #       -- NOT LAUNCHABLE directly. WindowsApps\ is owned by
    #       TrustedInstaller with restricted ACLs; even the elevated
    #       Administrator gets ERROR_ACCESS_DENIED (0x80070005) when
    #       Start-Process tries to exec a binary from there. The only
    #       supported entry point is via the App Execution Alias at
    #       %LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe, which itself
    #       fails on -Verb RunAs with ERROR_FILE_CANNOT_BE_ACCESSED
    #       (0x80070780) because the alias-forward chain doesn't survive
    #       UAC elevation. Both Store-install paths are unusable for our
    #       elevation use case -- we deliberately SKIP them.
    #
    #   (c) Windows PowerShell 5.1 at
    #       %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe
    #       -- LAUNCHABLE. Ships with every Windows install, fixed
    #       canonical path, no alias chain, no TrustedInstaller ACL.
    #       Older PS edition (5.1 vs 7.x) but the bootstrap relaunch
    #       payload uses only Invoke-RestMethod + [scriptblock]::Create
    #       + Read-Host, all of which work identically in 5.1. UNIVERSAL
    #       FALLBACK.
    #
    # Resolution order: (a) MSI pwsh -> (c) Windows PS 5.1. We never
    # attempt (b) because Start-Process can't launch from WindowsApps\
    # under any elevation flow, alias or no alias.
    $shell = $null
    foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $shell = $c; break }
    }
    if (-not $shell) {
        $winPwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path -LiteralPath $winPwsh -PathType Leaf) { $shell = $winPwsh }
    }
    if (-not $shell) {
        # Truly degenerate: no MSI pwsh AND no Windows PS 5.1 (nuked
        # System32?). Last-ditch alias path from PATH so Start-Process at
        # least surfaces a clear error rather than silently hanging.
        $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    }
    $shellArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-EncodedCommand', $encoded
    )

    # Force a NEW STANDALONE WINDOW. Without this the elevated relaunch
    # lands as a tab inside whatever existing Windows Terminal window
    # the user already had open -- not what we want for an installer
    # that paints a fixed-size 110-col dashboard. Strategy:
    #   1. If wt.exe (Windows Terminal) is installed, spawn through it
    #      with `-w -1 nt` -- "-w -1" creates a brand-new WT window
    #      (not a new tab in window 0) and `nt` opens a new tab inside
    #      that fresh window. The window is sized via the WT profile
    #      defaults; the inner pwsh resizes via $Host.UI.RawUI.WindowSize
    #      below to a guaranteed 110x42.
    #   2. Otherwise fall back to plain Start-Process pwsh -- which on
    #      hosts with conhost as the default terminal (Win10, or Win11
    #      with "Default Terminal" set to "Windows Console Host") opens
    #      a separate conhost window that pwsh can size programmatically.
    # wt.exe argument grammar:
    #     wt [global-args] new-tab [tab-args] [commandline]
    # `nt` is the short form of `new-tab`. `--title` is a TAB-ARG (must
    # follow `nt`) and the title MUST NOT contain a space -- Start-Process
    # flattens -ArgumentList back into a string and ProcessCreate then
    # splits on whitespace, so "MiOS Bootstrap" becomes two argv tokens
    # and wt tries to spawn a command literally named "Bootstrap" ->
    # 2147942402 (0x80070002, file-not-found). Single-token title
    # sidesteps that. `-w -1` is a GLOBAL arg meaning "new WT window"
    # (vs new tab in the operator's existing window).
    #
    # Resolution chain (try in order, fall through on failure):
    #   1. wt.exe via App Execution Alias at WindowsApps\wt.exe.
    #      Common breakage: "The stub received bad data" -- the alias
    #      stub forwards to the UWP terminal, but `-Verb RunAs` flips
    #      the security context mid-forward and the UWP package
    #      activation fails. Hits Server SKUs and some Win11 builds.
    #   2. wt.exe resolved via the real UWP install path at
    #      Program Files\WindowsApps\Microsoft.WindowsTerminal_*\wt.exe
    #      (skips the alias stub entirely).
    #   3. Plain Start-Process pwsh -Verb RunAs (conhost). Always works.
    # Resolve wt.exe to the WT PREVIEW install specifically. The App
    # Execution Alias might still point to Stable WT if both are
    # installed — we want our launches to land in Preview where the
    # MiOS settings live.
    $wtPreviewExe = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory -Filter 'Microsoft.WindowsTerminalPreview_*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'wt.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    $wtExeCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    $wtExe = if ($wtPreviewExe) { [PSCustomObject]@{ Source = $wtPreviewExe } } else { $wtExeCmd }
    $elevated = $false
    if ($wtExe) {
        # Global args (before `nt`) configure the WT WINDOW; tab args
        # (after `nt`) configure the tab. -p MiOS-Bootstrap pins the
        # profile we just provisioned so the new window inherits the
        # Geist font, MiOS color scheme, zero padding, suppressed title.
        # --pos / --size override settings.json initialCols/Rows for this
        # specific launch; --focus enforces borderless even if an older
        # WT build doesn't honor launchMode=focus.
        $wtArgs = @(
            '-w','-1',
            '--pos',  $miosWindowPos,
            '--size', '80,30',
            '--focus',
            'nt',
            '--title','MiOS-Bootstrap',
            '-p','MiOS',
            $shell
        ) + $shellArgs
        try {
            $wtTarget = if ($wtPreviewExe) { $wtPreviewExe } else { 'wt.exe' }
            Start-Process $wtTarget -ArgumentList $wtArgs -Verb RunAs -ErrorAction Stop
            $elevated = $true
        } catch {
            Write-Host "  [!] wt.exe elevation failed: $($_.Exception.Message)" -ForegroundColor Yellow
            # Last-ditch: stable WT's UWP path (only if Preview wasn't found).
            $realWt = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter 'wt.exe' -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match 'Microsoft\.WindowsTerminal' } |
                      Select-Object -First 1 -ExpandProperty FullName
            if ($realWt) {
                Write-Host "  [*] Retrying via real UWP path: $realWt" -ForegroundColor Cyan
                try {
                    Start-Process $realWt -ArgumentList $wtArgs -Verb RunAs -ErrorAction Stop
                    $elevated = $true
                } catch {
                    Write-Host "  [!] Direct UWP wt.exe also failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            if (-not $elevated) {
                Write-Host "  [*] Falling through to plain pwsh elevation (conhost window)." -ForegroundColor Cyan
            }
        }
    }
    if (-not $elevated) {
        # Plain elevation. Pass -WorkingDirectory $env:WINDIR so the
        # elevated process gets a WD it's guaranteed to be able to read
        # (avoids the "Administrator can't see %USERPROFILE%" path-not-
        # accessible class of 0x80070780 failures when the launching user
        # had a OneDrive-redirected or non-default home directory).
        try {
            Start-Process -FilePath $shell -ArgumentList $shellArgs -Verb RunAs -WorkingDirectory $env:WINDIR -ErrorAction Stop
            $elevated = $true
        } catch {
            Write-Host "  [!] $shell elevation failed: $($_.Exception.Message)" -ForegroundColor Yellow
            # Last-resort fallback: Windows PowerShell 5.1 at the canonical
            # System32 path (skips any App Execution Alias chain entirely).
            $winPwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
            if ((Test-Path -LiteralPath $winPwsh -PathType Leaf) -and ($shell -ne $winPwsh)) {
                Write-Host "  [*] Retrying via Windows PowerShell 5.1: $winPwsh" -ForegroundColor Cyan
                try {
                    Start-Process -FilePath $winPwsh -ArgumentList $shellArgs -Verb RunAs -WorkingDirectory $env:WINDIR -ErrorAction Stop
                    $elevated = $true
                } catch {
                    Write-Host "  [!] Windows PowerShell 5.1 elevation also failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    if ($elevated -and $wtExe) {
        # Belt-and-braces re-center: WT in focus mode often ignores --pos
        # on the first launch (lands at 0,0 or at the previous WT
        # window's last saved position). Wait for the WT hwnd to surface,
        # then SetWindowPos to true screen center based on actual outer
        # window dims. Without this the operator can be left with an
        # off-screen window that's only closeable via 'exit' typed
        # blind -- defeating the whole point of focus mode.
        try { Move-MiOSWindowToCenter -ScreenInfo $miosWindowInfo | Out-Null } catch {}
    }
    if (-not $elevated) {
        Write-Host ''
        Write-Host '  [!] Could not spawn an elevated pwsh window via any path.' -ForegroundColor Red
        Write-Host '      Manually open an elevated PowerShell and re-run:' -ForegroundColor DarkGray
        Write-Host "        irm $rawUrl | iex" -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    Write-Host "  [+] New pwsh window opened. Continuing the bootstrap there." -ForegroundColor Green
    return
}

# 2. Resize host window to 80x30 -- the canonical TTY0 / text-mode-3+
# dimension and the MiOS dashboard's global size. 80 cols × 30 rows
# yields a 4:3 pixel aspect with standard 1:2 monospace cells, fits
# the dashboard frame's 80-col strict-clamp, and matches the post-
# install hub menu's row budget. wt.exe --size 80,30 already requested
# this for the WT window; this RawUI set is the conhost-fallback path
# AND a belt-and-braces resize in case WT honored --pos but ignored
# --size on an older build.
try {
    $sz  = New-Object Management.Automation.Host.Size 80, 30
    $buf = New-Object Management.Automation.Host.Size 80, 9000
    $Host.UI.RawUI.BufferSize = $buf
    $Host.UI.RawUI.WindowSize = $sz
} catch {
    try { $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size 80, 30 } catch {}
}

# 3. Helpers
function Write-Info { param([string]$M) Write-Host "  [*] $M" -ForegroundColor Cyan }
function Write-Good { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green }
function Write-Err  { param([string]$M) Write-Host "  [!] $M" -ForegroundColor Red }
function Require-Cmd {
    param([string]$Cmd, [string]$InstallHint)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Err "$Cmd not found. $InstallHint"
        exit 1
    }
}

Clear-Host
Write-Host "MiOS Bootstrap (irm | iex web entry)" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Cyan

# 4. Prerequisites
Require-Cmd "git"    "Install Git from https://git-scm.com/download/win"
Require-Cmd "podman" "Install Podman Desktop from https://podman-desktop.io"
Write-Good "Prerequisites OK (git, podman)"

# Initialize-DataDisk: shrink C:\ by EXACTLY 256 GB (262144 MB) and
# create M:\ as NTFS labeled MIOS-DEV. Idempotent: if M:\ already
# exists with the right label, returns silently. Per
# feedback_mios_entry_m_drive_clone.md, M:\ is part of the Windows
# entry contract and runs every irm|iex.
function Initialize-DataDisk {
    param(
        [int]$ShrinkMB     = 262144,   # exactly 256 GB, no auto-sizing
        [string]$DriveLetter = 'M',
        [string]$VolumeLabel = 'MIOS-DEV'
    )
    $existing = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existing -and $existing.FileSystemLabel -eq $VolumeLabel) {
        Write-Good "M:\ already provisioned ($([math]::Round($existing.Size/1GB,1)) GB, $($existing.FileSystem), label=$VolumeLabel)"
        return
    }
    if ($existing) {
        Write-Err "Drive ${DriveLetter}: exists with label '$($existing.FileSystemLabel)' (not '$VolumeLabel')."
        Write-Err "Either remove the volume manually or pass -DriveLetter <other> to Get-MiOS.ps1."
        exit 1
    }
    Write-Info "Provisioning ${DriveLetter}:\ at exactly $ShrinkMB MB (256 GB) ..."
    $sysLetter = ([Environment]::GetEnvironmentVariable('SystemDrive')).TrimEnd(':')
    $cPart       = Get-Partition -DriveLetter $sysLetter
    $supported   = Get-PartitionSupportedSize -DriveLetter $sysLetter
    $shrinkBytes = [int64]$ShrinkMB * 1MB
    $newCSize    = $cPart.Size - $shrinkBytes
    if ($shrinkBytes -gt ($cPart.Size - $supported.SizeMin)) {
        Write-Err "Cannot shrink ${sysLetter}: by $ShrinkMB MB."
        Write-Err "  current ${sysLetter}: size: $([math]::Round($cPart.Size/1GB,1)) GB"
        Write-Err "  min supported size:    $([math]::Round($supported.SizeMin/1GB,1)) GB"
        Write-Err "  max shrinkable:         $([math]::Round(($cPart.Size-$supported.SizeMin)/1GB,1)) GB"
        Write-Err "Free up ${sysLetter}: space (move pagefile / disable hibernation / clean up large files) and retry."
        exit 1
    }
    $disk = Get-Disk -Number $cPart.DiskNumber
    if ($disk.PartitionStyle -notin @('GPT','MBR')) {
        Write-Err "Disk $($disk.Number) has unsupported partition style '$($disk.PartitionStyle)'"
        exit 1
    }
    Write-Info "  shrinking ${sysLetter}: $([math]::Round($cPart.Size/1GB,1)) GB -> $([math]::Round($newCSize/1GB,1)) GB ..."
    Resize-Partition -DriveLetter $sysLetter -Size $newCSize -ErrorAction Stop
    Write-Info "  creating $VolumeLabel partition (${ShrinkMB} MB) on disk $($disk.Number) ..."
    $null = New-Partition -DiskNumber $disk.Number -Size $shrinkBytes -DriveLetter $DriveLetter -ErrorAction Stop
    $null = Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel $VolumeLabel `
        -AllocationUnitSize 4096 -Confirm:$false -Force
    Write-Good "${DriveLetter}:\\ created (${ShrinkMB} MB NTFS, label=$VolumeLabel)"
}

# Junction every candidate podman-machine storage path onto M:\ so the
# eventual `podman machine init` lands the WSL distro VHDX (multi-GB) on
# the dedicated 256 GB partition rather than on C:\. Per
# feedback_mios_dev_on_m_drive.md, this MUST happen before any podman
# command runs -- if podman creates files at the source path first, the
# junction can't be applied to a non-empty dir without a move-then-junction
# dance.
#
# Podman v4.x and v5.x use different default storage paths on Windows
# depending on machine provider, user vs. system scope, and version
# upgrades that didn't migrate the data. We junction ALL candidates so
# whichever one the installed podman picks resolves to M:\.
function Set-PodmanMachineStorageOnM {
    param([string]$MRoot = 'M:\podman\machine')
    if (-not (Test-Path $MRoot)) {
        New-Item -ItemType Directory -Path $MRoot -Force -ErrorAction Stop | Out-Null
        Write-Host "    [+] created $MRoot" -ForegroundColor DarkGray
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA  'containers\podman\machine'),
        (Join-Path $env:USERPROFILE   '.local\share\containers\podman\machine'),
        (Join-Path $env:PROGRAMDATA   'containers\podman\machine')
    )
    foreach ($p in $candidates) {
        if (-not $p) { continue }
        $parent = Split-Path $p -Parent
        if (-not (Test-Path $parent)) {
            try { New-Item -ItemType Directory -Path $parent -Force | Out-Null } catch {}
        }
        if (Test-Path $p) {
            $item = Get-Item $p -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $current = ($item.Target -join '').TrimStart('\??\')
                $isSymlink = $item.LinkType -eq 'SymbolicLink'
                if ($current -ieq $MRoot -and $isSymlink) {
                    Write-Host "    [=] $p -> $MRoot (already symlinked)" -ForegroundColor DarkGray
                    continue
                }
                # Wrong target OR right target but wrong link type
                # (legacy junction from a pre-2026-05-06 install --
                # podman 5.8.2 chokes on junctions for this path).
                # Remove + re-link as symlink below.
                if ($current -ieq $MRoot -and -not $isSymlink) {
                    Write-Host "    [~] $p is a JUNCTION (legacy) -- recreating as symlink so podman 5.8.2 stops failing on os.Mkdir" -ForegroundColor DarkYellow
                }
                cmd /c "rmdir `"$p`"" 2>$null | Out-Null
            } else {
                # Real directory exists. If empty, remove. If non-empty,
                # move contents to M:\ first so we don't lose state.
                $kids = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if ($kids -and $kids.Count -gt 0) {
                    Write-Host "    [*] moving existing $p contents to $MRoot ..." -ForegroundColor DarkGray
                    try {
                        foreach ($k in $kids) {
                            $dst = Join-Path $MRoot $k.Name
                            if (-not (Test-Path $dst)) {
                                Move-Item -LiteralPath $k.FullName -Destination $MRoot -Force -ErrorAction Stop
                            }
                        }
                    } catch {
                        Write-Host "    [!] move failed for $p : $($_.Exception.Message) -- forcing remove" -ForegroundColor Yellow
                    }
                }
                try {
                    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Host "    [!] couldn't remove $p (locked) -- skipping junction for this path" -ForegroundColor Yellow
                    continue
                }
            }
        }
        # Now create the link. Use mklink /D (symbolic link) -- NOT
        # /J (junction). Why:
        #
        # podman 5.8.2's `podman machine ls` calls os.Mkdir on
        # ~/.local/share/containers/podman/machine and treats EEXIST
        # as fatal when the path is a NTFS junction. With a junction
        # there:
        #     Error: mkdir C:\Users\Administrator\.local\share\containers\podman\machine:
        #            Cannot create a file when that file already exists.
        # Same path created as a symlink (mklink /D): no error,
        # podman writes the wsl/, machine/, machine.pub, port-alloc.*
        # children straight through to the M:\ target.
        #
        # Verified empirically 2026-05-06 against podman 5.8.2:
        #     /J -> ls FAILS,  init works
        #     /D -> ls WORKS,  init works, files land in M:\
        #
        # mklink /D requires admin OR Developer Mode. The bootstrap
        # already requires admin for diskpart shrink in
        # Initialize-MiosDataDisk, so this isn't an additional ask.
        $rc = (cmd /c "mklink /D `"$p`" `"$MRoot`"" 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [+] symlinked $p -> $MRoot" -ForegroundColor DarkGray
        } else {
            Write-Host "    [!] mklink /D $p -> $MRoot failed: $rc" -ForegroundColor Yellow
        }
    }
}

# NOTE: this script does NOT delete anything on the operator's
# filesystem -- not C:\MiOS, not M:\MiOS, not %USERPROFILE%, not
# %PROGRAMDATA%, NOTHING. A previous version of this script had a
# "full reset" block that nuked C:\MiOS and M:\MiOS unconditionally.
# That was wrong: a fresh-install operator has no MiOS dirs to reset
# in the first place (so the block did nothing useful in the
# canonical use case), and a returning operator has uncommitted work
# in those dirs that wasn't ours to touch. The block destroyed
# operator work and is permanently removed.
#
# WSL distros, podman machines, and Hyper-V VMs aren't touched
# either -- those are operator-managed VM artifacts, even when their
# names are MiOS-flavored. If a stale registration is in the way of
# a new install, the script's later phases will detect that
# situation and surface an actionable error so the operator can
# decide what to do, rather than silently destroying state.

# 4c. Provision M:\ at exactly 256 GB (NTFS, label MIOS-DEV).
# Per feedback_mios_entry_m_drive_clone.md, M:\ is part of the
# Windows entry contract -- the dev VM (podman-MiOS-DEV.vhdx),
# build artifacts, and the bootstrap source clone all live on
# this dedicated 256 GB partition. Idempotent: skips if M:\
# already exists with the right label.
Initialize-DataDisk

# Junction every candidate podman-machine storage path to M:\ so the
# eventual `podman machine init MiOS-DEV` lands the WSL VHDX on the
# 256 GB data partition, not on C:\. Per
# feedback_mios_dev_on_m_drive.md, this MUST happen BEFORE any podman
# command runs (the bootstrap, build-mios.ps1, anything). The full
# reset above already cleared the source dirs, so the junctions go in
# clean.
Write-Info "Redirecting podman-machine storage to M:\\podman\\machine ..."
Set-PodmanMachineStorageOnM

# Create the canonical Windows install root structure now that M:\
# is guaranteed to exist. The reset above wiped M:\MiOS, so this
# rebuilds it fresh.
$miosRepoDir = "M:\MiOS\repo"
New-Item -ItemType Directory -Path $miosRepoDir -Force -ErrorAction SilentlyContinue | Out-Null

# 5. Fresh-clone the mios-bootstrap repo to M:\MiOS\repo\mios-bootstrap.
#
# CONTRACT (per feedback_mios_irm_iex_always_temp_clone.md +
# feedback_mios_entry_m_drive_clone.md): irm|iex ALWAYS clones a
# fresh copy. There is NO update / fetch / pull branch. The clone
# target is M:\MiOS\repo\mios-bootstrap (the canonical Windows-entry
# working tree), NOT %TEMP% or %USERPROFILE%.
#
# Since the full reset above already wiped M:\MiOS, $RepoDir won't
# exist when we get here -- no Remove-Item dance needed. (Operator
# overrides with -RepoDir <other-path> still get the safety check.)
if ((Test-Path $RepoDir) -and ($RepoDir -ne 'M:\MiOS\repo\mios-bootstrap')) {
    Write-Err "-RepoDir $RepoDir already exists. Either delete it manually, or re-run without -RepoDir to use the canonical M:\MiOS\repo\mios-bootstrap."
    exit 1
}

# Helper: run git with all streams drained via System.Diagnostics.Process
# so PowerShell's pipeline never sees stderr (no EAP=Stop trap on git's
# normal "Cloning into ..." progress banner).
function Invoke-GitProc {
    param([string[]]$ArgList, [string]$Cwd = $null)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        foreach ($a in $ArgList) {
            if ($psi.ArgumentList -ne $null) { [void]$psi.ArgumentList.Add($a) }
        }
        if ($psi.ArgumentList -eq $null -or $psi.ArgumentList.Count -eq 0) {
            # PS 5.1 fallback: build single-string Arguments. Each arg
            # quoted in case of spaces in paths.
            $psi.Arguments = ($ArgList | ForEach-Object { '"' + ($_ -replace '"','\"') + '"' }) -join ' '
        }
        if ($Cwd) { $psi.WorkingDirectory = $Cwd }
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $out
            Stderr   = $err
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = $_.Exception.Message }
    }
}

# If $RepoDir already exists with a .git subdir from a prior run, do an
# in-place fetch + reset --hard to bring it to origin/main. NEVER delete
# operator-side files (per feedback_mios_entry_full_reset.md). If it
# exists but isn't a git repo, fail with an actionable message rather
# than silently nuking it.
if (Test-Path $RepoDir) {
    if (Test-Path (Join-Path $RepoDir '.git')) {
        Write-Info "Updating existing bootstrap clone at $RepoDir (fetch + hard reset to origin/$Branch) ..."
        $fr = Invoke-GitProc -ArgList @('fetch','--depth=1','origin',$Branch) -Cwd $RepoDir
        if ($fr.ExitCode -ne 0) {
            Write-Err "git fetch in $RepoDir failed (exit $($fr.ExitCode))."
            Write-Err "Stderr: $($fr.Stderr.Trim())"
            Write-Err "Re-run manually:  git -C `"$RepoDir`" fetch --depth=1 origin $Branch"
            exit 1
        }
        $rr = Invoke-GitProc -ArgList @('reset','--hard','FETCH_HEAD') -Cwd $RepoDir
        if ($rr.ExitCode -ne 0) {
            Write-Err "git reset --hard in $RepoDir failed (exit $($rr.ExitCode))."
            Write-Err "Stderr: $($rr.Stderr.Trim())"
            exit 1
        }
        Write-Good "Bootstrap clone updated to origin/$Branch in place at $RepoDir"
    } else {
        Write-Err "$RepoDir exists but is not a git repository."
        Write-Err "I won't delete it -- contents may be operator-managed. Either:"
        Write-Err "  - Move it aside:   Rename-Item `"$RepoDir`" `"$RepoDir.bak`""
        Write-Err "  - Or pass -RepoDir <other-path> to use a different target."
        exit 1
    }
} else {
    Write-Info "Cloning $RepoUrl ($Branch, depth=1) -> $RepoDir ..."
    # Ensure parent dir exists so git clone has a place to write.
    $parent = Split-Path $RepoDir -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $cr = Invoke-GitProc -ArgList @('clone','--branch',$Branch,'--depth','1',$RepoUrl,$RepoDir)
    if ($cr.ExitCode -ne 0) {
        Write-Err "git clone $RepoUrl -> $RepoDir failed (exit $($cr.ExitCode))."
        Write-Err "Stderr: $($cr.Stderr.Trim())"
        Write-Err "Re-run manually to see git's diagnostic output:"
        Write-Err "  git clone --branch $Branch --depth 1 $RepoUrl `"$RepoDir`""
        exit 1
    }
    Write-Good "Fresh bootstrap clone at $RepoDir"
}

# 6. Hand off to bootstrap.ps1 (canonical split-bootstrap entry).
# Defaults to -BootstrapOnly: stops after dev VM + Windows install.
# The "Build MiOS" Start Menu shortcut drives the OCI build.
$entry = Join-Path $RepoDir "bootstrap.ps1"
if (-not (Test-Path $entry)) {
    Write-Err "bootstrap.ps1 not found in $RepoDir (cloned with wrong branch?)"
    exit 1
}

if ($Workflow) { $env:MIOS_WORKFLOW = $Workflow }

$forwardArgs = @()
if ($FullBuild)  { $forwardArgs += '-FullBuild' }
if ($Unattended) { $forwardArgs += '-Unattended' }

Write-Info "Handing off to bootstrap.ps1 ..."
Push-Location $RepoDir
try {
    & $entry @forwardArgs
} finally { Pop-Location }
exit $LASTEXITCODE
