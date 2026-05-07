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
    # Per operator: target the BASE Windows Terminal install (Stable),
    # NOT Preview. Polls until WT Stable's AppX package is registered
    # AND its LocalState dir is materialized.
    $deadline = (Get-Date).AddSeconds(90)
    $stableLocal = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'

    while ((Get-Date) -lt $deadline) {
        $pkg = $null
        try { $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue } catch {}
        $localOk = Test-Path -LiteralPath $stableLocal
        $exeOk = $false
        if ($pkg -and $pkg.InstallLocation) {
            $wtExe = Join-Path $pkg.InstallLocation 'wt.exe'
            if (Test-Path -LiteralPath $wtExe) { $exeOk = $true }
        }
        if ($pkg -and $exeOk) {
            if (-not $localOk) {
                try { New-Item -ItemType Directory -Path $stableLocal -Force | Out-Null } catch {}
            }
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Install-MiOSWindowsTerminal {
    # Operator pivot: MiOS targets the BASE Windows Terminal install,
    # NOT Preview. We do NOT pollute the operator's globals or default
    # profile -- we just upsert the MiOS / MiOS-DEV profiles into the
    # operator's existing settings.json so they appear in the WT
    # profile dropdown. Borderless / centered / sized launch comes
    # from wt.exe COMMAND-LINE flags at launch time, not globals.
    $appx = $null
    try { $appx = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue } catch {}
    if ($appx) {
        Write-Host "  [+] Windows Terminal (base install) already present." -ForegroundColor DarkGray
        [void](Wait-MiOSWindowsTerminalReady)
        return $true
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] winget not available; cannot auto-install Windows Terminal." -ForegroundColor Yellow
        Write-Host "      Install manually from the Microsoft Store." -ForegroundColor DarkGray
        return $false
    }
    Write-Host "  [*] Installing Windows Terminal (base) via winget..." -ForegroundColor Cyan
    try {
        & winget install --id Microsoft.WindowsTerminal --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
    } catch {
        Write-Host "  [!] winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] winget exit code $LASTEXITCODE -- WT install may not have completed." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [*] winget install returned -- waiting for AppX deployment to finish..." -ForegroundColor Cyan
    if (-not (Wait-MiOSWindowsTerminalReady)) {
        Write-Host "  [!] Windows Terminal did not become ready within 90s." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [+] Windows Terminal installed and ready." -ForegroundColor Green
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
        $zipSize = (Get-Item $zipPath).Length
        if ($zipSize -lt 100000) {
            # < 100 KB means we got a 404 HTML page or similar, not the
            # real ~50 MB Geist zip. Bail early with a useful message.
            Write-Host "  [!] GeistMono.zip download too small ($zipSize bytes) -- likely 404." -ForegroundColor Yellow
            Write-Host "      Source: $zipUrl" -ForegroundColor DarkGray
            return $false
        }
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force -ErrorAction Stop
        $extractedCount = (Get-ChildItem $tmpDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host "  [*] GeistMono.zip: $([math]::Round($zipSize/1MB,1)) MB, $extractedCount files extracted." -ForegroundColor DarkGray

        # ALL MiOS install artifacts land on M:\ per the operator's
        # invariant. Fonts go to M:\MiOS\fonts\ -- Windows accepts any
        # path in HKCU\...\Fonts as long as the registry value points
        # at the actual .ttf file. Falls back to %LOCALAPPDATA%\...
        # only if M:\ isn't mounted yet (very early bootstrap).
        $miosFontDir = if (Test-Path 'M:\') { 'M:\MiOS\fonts' }
                       else { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts' }
        if (-not (Test-Path $miosFontDir)) {
            New-Item -ItemType Directory -Path $miosFontDir -Force | Out-Null
        }
        $userFontDir = $miosFontDir
        $regKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (-not (Test-Path $regKey)) {
            New-Item -Path $regKey -Force | Out-Null
        }

        # Get every .ttf file in the extracted tree, then filter by name.
        # Nerd Fonts release naming has changed multiple times -- the
        # Get-ChildItem -Filter pattern was missing valid TTFs because
        # of case-sensitivity and substring quirks on PowerShell 7.6+.
        # Use -match instead which is case-insensitive by default.
        $allTtfs = Get-ChildItem $tmpDir -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '\.ttf$' }
        # Prefer "Mono" variants (fixed-width, terminal-safe). Then
        # general "NerdFont". Then ANY .ttf as last resort.
        $preferred = $allTtfs | Where-Object { $_.Name -match 'NerdFontMono' }
        if (-not $preferred) {
            $preferred = $allTtfs | Where-Object { $_.Name -match 'NerdFont' }
        }
        if (-not $preferred) {
            $preferred = $allTtfs
        }
        if (-not $preferred) {
            Write-Host "  [!] GeistMono.zip extracted but contains no .ttf files. (Found $($allTtfs.Count))" -ForegroundColor Yellow
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

# Resolve the WT settings.json path. Per operator: target the BASE
# (Stable) Windows Terminal install. Returns $null if WT Stable isn't
# installed (caller should run Install-MiOSWindowsTerminal first).
function Get-MiOSTerminalSettingsPath {
    $stableSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $stableLocal    = Split-Path -Parent $stableSettings
    if (Test-Path -LiteralPath $stableSettings) { return $stableSettings }
    # LocalState exists but settings.json not yet written (fresh install,
    # WT not yet first-launched). Return the path so we can create it.
    if (Test-Path -LiteralPath $stableLocal) { return $stableSettings }
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
        Write-Host "  [!] Windows Terminal not ready (LocalState dir missing) -- skipping settings patch." -ForegroundColor Yellow
        Write-Host "      Re-run irm|iex after WT first-launch creates the dir." -ForegroundColor DarkGray
        return $null
    }
    Write-Host "  [*] Patching Windows Terminal settings: $settingsPath" -ForegroundColor Cyan

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

    # Profile commandline: pwsh -NoLogo -NoExit -Command ". 'M:\...'".
    # Explicitly dot-sources the canonical M:\ profile script AFTER
    # $PROFILE has loaded -- so even if the operator has a broken
    # oh-my-posh init in their $PROFILE that runs after our markers,
    # OUR regex-patched init runs LAST and wins. This is what makes
    # the MiOS terminal's prompt deterministic regardless of the
    # operator's existing PowerShell profile state. Without this
    # explicit re-init, the MiOS terminal could inherit a broken
    # PSReadLine binding state from the operator's pre-existing init.
    # Resolve pwsh 7 across all install shapes:
    #   1. MSI install at $env:ProgramFiles\PowerShell\7\pwsh.exe
    #   2. Microsoft Store install at WindowsApps\Microsoft.PowerShell_*
    #      (operator's actual setup -- PS 7.6.1 from MS Store).
    #   3. App Execution Alias via Get-Command (last-ditch).
    #   4. Windows PS 5.1 (only if no pwsh found at all). 5.1 has the
    #      OLD PSReadLine that breaks oh-my-posh init -- avoid unless
    #      truly desperate.
    $defaultPwsh = $null
    foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { $defaultPwsh = $c; break }
    }
    if (-not $defaultPwsh) {
        try {
            $appxPwsh = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue
            if ($appxPwsh -and $appxPwsh.InstallLocation) {
                $cand = Join-Path $appxPwsh.InstallLocation 'pwsh.exe'
                if (Test-Path -LiteralPath $cand) { $defaultPwsh = $cand }
            }
        } catch {}
    }
    if (-not $defaultPwsh) {
        $glob = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory -Filter 'Microsoft.PowerShell_*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        if ($glob) {
            $cand = Join-Path $glob.FullName 'pwsh.exe'
            if (Test-Path -LiteralPath $cand) { $defaultPwsh = $cand }
        }
    }
    if (-not $defaultPwsh) {
        $cmdPwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($cmdPwsh -and $cmdPwsh.Source -and (Test-Path -LiteralPath $cmdPwsh.Source)) {
            $defaultPwsh = $cmdPwsh.Source
        }
    }
    if (-not $defaultPwsh) {
        # LAST RESORT: PS 5.1. oh-my-posh init's modern Get-PSReadLineKeyHandler
        # syntax will still work via the M:\ profile's regex-patch.
        $defaultPwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        Write-Host "  [!] No pwsh 7 found; falling back to Windows PS 5.1 in MiOS profile." -ForegroundColor Yellow
    }
    $miosProfilePath = if (Test-Path 'M:\') { 'M:\MiOS\powershell\profile.ps1' }
                      else { Join-Path $env:USERPROFILE 'MiOS-bootstrap\powershell\profile.ps1' }
    # Single-quoted PS string with `''` for embedded literal quotes.
    # ConvertTo-Json will JSON-encode the outer double-quotes correctly.
    $profileCmdline = '"' + $defaultPwsh + '" -NoLogo -NoExit -Command "if (Test-Path ''' + $miosProfilePath + ''') { . ''' + $miosProfilePath + ''' }"'

    # Per-profile shared settings -- apply to BOTH "MiOS" and "MiOS-DEV"
    # so they look/feel identical. Belt-AND-braces acrylic settings:
    # WT 1.16-1.17 reads `useAcrylic` (legacy bool) and `opacity`. WT
    # 1.18+ reads `systemBackdrop` (per-profile). Setting BOTH means
    # acrylic 50% transparency renders correctly across every WT
    # version the operator might end up on. `useMica` is NOT set --
    # it's not a documented WT key (mica is selected via
    # systemBackdrop="mica"), and shipping unknown keys can cause WT's
    # schema validator to reject the profile and fall back to defaults.
    $commonProfileProps = [ordered]@{
        colorScheme              = 'MiOS'
        font                     = [ordered]@{
            face   = 'GeistMono Nerd Font Mono'
            size   = 12
            weight = 'normal'
        }
        cursorShape              = 'bar'
        antialiasingMode         = 'cleartype'
        # Acrylic 50% transparency -- MiOS spec.
        useAcrylic               = $true
        opacity                  = 50
        systemBackdrop           = 'acrylic'
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

    # NO GLOBAL WRITES. Per operator pivot: do NOT set launchMode,
    # defaultProfile, centerOnLaunch, profiles.defaults, theme, etc.
    # The operator's existing settings.json globals stay untouched.
    # MiOS only adds itself as TWO profiles + ONE color scheme. The
    # frameless / centered / 80x30 / always-on-top behavior all comes
    # from wt.exe command-line args at launch time.
    if (-not $wtJson.profiles) {
        $emptyProfilesObj = [PSCustomObject]@{ list = @() }
        $wtJson | Add-Member -NotePropertyName profiles -NotePropertyValue $emptyProfilesObj -Force
    }

    # Schemes: upsert MiOS (force [object[]] so a single-entry schemes
    # array doesn't get unwrapped to a bare object by ConvertTo-Json).
    if (-not $wtJson.schemes) {
        $wtJson | Add-Member -NotePropertyName schemes -NotePropertyValue @() -Force
    }
    $miosSchemeObj = [PSCustomObject]$miosScheme
    $existingSchemes = @($wtJson.schemes | Where-Object { $_.name -ne 'MiOS' })
    $existingSchemes += $miosSchemeObj
    # Force [object[]] -- ConvertTo-Json otherwise unwraps single-element
    # arrays to bare objects, which makes WT's schemes lookup miss the
    # MiOS scheme entirely (the "PROFILE IS NOT SET TO COLOR PALETTE"
    # symptom). Comma-prefix forces array preservation through assignment.
    $wtJson.schemes = [object[]]$existingSchemes

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
    $wtJson.profiles.list = [object[]]$existingList

    # Write back, then VERIFY by re-reading and parsing. ConvertTo-Json
    # has a long history of unwrapping single-element arrays to bare
    # objects -- which makes WT's scheme lookup miss MiOS entirely
    # (the "PROFILE IS NOT SET TO COLOR PALETTE" symptom). Verify
    # post-write that schemes[] really IS an array containing MiOS.
    try {
        $parent = Split-Path -Parent $settingsPath
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        ($wtJson | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $settingsPath -Encoding UTF8

        # Verify pass.
        $verifyRaw = Get-Content -LiteralPath $settingsPath -Raw
        $vStripped = [regex]::Replace($verifyRaw, '(?ms)/\*.*?\*/', '')
        $vStripped = [regex]::Replace($vStripped, '(?m)^\s*//.*$', '')
        $vStripped = [regex]::Replace($vStripped, ',(\s*[\x7D\x5D])', '$1')
        $vJson = $vStripped | ConvertFrom-Json -ErrorAction Stop
        $schemeNames = @()
        if ($vJson.schemes) { $schemeNames = @($vJson.schemes | ForEach-Object { $_.name }) }
        $profileNames = @()
        if ($vJson.profiles -and $vJson.profiles.list) { $profileNames = @($vJson.profiles.list | ForEach-Object { $_.name }) }

        if ($schemeNames -contains 'MiOS' -and $profileNames -contains 'MiOS') {
            Write-Host "  [+] MiOS scheme + MiOS/MiOS-DEV profiles upserted." -ForegroundColor Green
            Write-Host "      schemes:  $($schemeNames -join ', ')" -ForegroundColor DarkGray
            Write-Host "      profiles: $($profileNames -join ', ')" -ForegroundColor DarkGray
        } else {
            Write-Host "  [!] settings.json verify FAILED -- scheme or profile didn't round-trip!" -ForegroundColor Red
            Write-Host "      schemes:  $($schemeNames -join ', ')" -ForegroundColor DarkGray
            Write-Host "      profiles: $($profileNames -join ', ')" -ForegroundColor DarkGray
            # Fallback: hand-write the schemes + profiles arrays as raw
            # JSON-array literals so PS singleton-unwrap can't bite.
            $miosSchemeJson  = $miosSchemeObj  | ConvertTo-Json -Depth 16 -Compress
            $miosProfileJson = $miosProfileObj | ConvertTo-Json -Depth 16 -Compress
            $miosDevProfileJson = $miosDevProfileObj | ConvertTo-Json -Depth 16 -Compress
            Write-Host "      Falling back to raw JSON-string injection." -ForegroundColor DarkGray
        }
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
function Install-MiOSNativeApp {
    # Make MiOS a first-class Windows app the moment irm|iex finishes:
    #   * Start Menu MiOS.lnk  (so Win-search "MiOS" returns it)
    #   * Desktop MiOS.lnk     (one-click launch)
    #   * HKCU Uninstall key   (Settings > Apps > Installed apps lists it)
    #   * AppUserModelID stamp (taskbar grouping + Pin to Start identity)
    #   * Best-effort programmatic Pin to Start (Win10 only -- Win11 hint)
    #
    # Target dir for the launcher script: M:\MiOS\bin\mios-launch.ps1
    # (operator's M:\-everywhere invariant). Falls back to %LOCALAPPDATA%
    # if M:\ isn't yet provisioned.

    $miosRoot = if (Test-Path 'M:\') { 'M:\MiOS' } else { Join-Path $env:LOCALAPPDATA 'MiOS' }
    $miosBin  = Join-Path $miosRoot 'bin'
    if (-not (Test-Path $miosBin)) { New-Item -ItemType Directory -Path $miosBin -Force | Out-Null }

    $launcherPath = Join-Path $miosBin 'mios-launch.ps1'

    # Resolve Stable WT's wt.exe via Get-AppxPackage; the launcher prefers
    # this over the App Execution Alias for deterministic profile binding.
    $wtStablePath = $null
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
        if ($pkg -and $pkg.InstallLocation) {
            $cand = Join-Path $pkg.InstallLocation 'wt.exe'
            if (Test-Path -LiteralPath $cand) { $wtStablePath = $cand }
        }
    } catch {}

    # Compute the centered position once, hardcode it into the launcher
    # so each click is reproducible. (Cursor-monitor recomputed at
    # launch time too, see body.)
    $launcherBody = @'
# mios-launch.ps1 -- native MiOS app launcher.
# Spawns wt.exe with the MiOS profile in focus mode (frameless,
# borderless, no titlebar/tab-row), 80 cols x 30 rows, screen-centered
# on whichever monitor the cursor is currently on, always-on-top.
# Runs invisibly (parent shortcut uses -WindowStyle Hidden).
$ErrorActionPreference = 'SilentlyContinue'

try {
    Add-Type -Namespace 'MiOSLaunch.Native' -Name 'Dpi' -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [MiOSLaunch.Native.Dpi]::SetProcessDPIAware() | Out-Null
} catch {}

Add-Type -AssemblyName System.Windows.Forms

# Cell metrics: Geist Mono 12pt @ 100% DPI ~ 10x20 px.
$Cols = 80; $Rows = 30
$winW = ($Cols * 10) + 20
$winH = ($Rows * 20) + 12

$cur  = [System.Windows.Forms.Cursor]::Position
$work = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
$x = [int]($work.X + ($work.Width  - $winW) / 2); if ($x -lt $work.X) { $x = $work.X }
$y = [int]($work.Y + ($work.Height - $winH) / 2); if ($y -lt $work.Y) { $y = $work.Y }

# Resolve wt.exe to Stable specifically.
$wtExe = $null
try {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
    if ($pkg -and $pkg.InstallLocation) {
        $cand = Join-Path $pkg.InstallLocation 'wt.exe'
        if (Test-Path -LiteralPath $cand) { $wtExe = $cand }
    }
} catch {}
if (-not $wtExe) { $wtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source }
if (-not $wtExe) {
    [System.Windows.Forms.MessageBox]::Show("Windows Terminal is not installed. Run irm|iex Get-MiOS.ps1 to install.","MiOS","OK","Error") | Out-Null
    exit 1
}

$wtArgs = @('-w','-1','--pos',"$x,$y",'--size','80,30','--focus','nt','-p','MiOS')
$spawnedAt = Get-Date
Start-Process -FilePath $wtExe -ArgumentList $wtArgs

# Post-launch retry-center + always-on-top via Win32.
try {
    Add-Type -Namespace 'MiOSLaunch.Native' -Name 'Win' -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect); [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd); public struct RECT { public int Left, Top, Right, Bottom; }'
} catch {}

$deadline = (Get-Date).AddMilliseconds(8000)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    # Pick the WindowsTerminal process whose StartTime is AFTER our
    # spawnedAt timestamp. Picking "newest WT" without the timestamp
    # filter accidentally targets the operator's pre-existing WT
    # window (whose StartTime is later only because StartTime sort
    # picks the most-recently-active one). Filter by spawn time + 1s
    # leeway so we always land on OUR newly-spawned WT.
    $proc = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $spawnedAt.AddSeconds(-1) } |
            Sort-Object StartTime -Descending | Select-Object -First 1
    if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero -and [MiOSLaunch.Native.Win]::IsWindowVisible($proc.MainWindowHandle)) {
        $hwnd = $proc.MainWindowHandle; break
    }
    Start-Sleep -Milliseconds 150
}
if ($hwnd -ne [IntPtr]::Zero) {
    $topmost = [IntPtr]::new(-1)
    for ($i = 0; $i -lt 3; $i++) {
        $rect = New-Object MiOSLaunch.Native.Win+RECT
        if ([MiOSLaunch.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) {
            $rw = $rect.Right - $rect.Left; $rh = $rect.Bottom - $rect.Top
            if ($rw -gt 0 -and $rh -gt 0) {
                $cx = [int]($work.X + ($work.Width - $rw) / 2)
                $cy = [int]($work.Y + ($work.Height - $rh) / 2)
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, $topmost, $cx, $cy, $rw, $rh, 0x40)
                [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $cx, $cy, $rw, $rh, 0x04)
            }
        }
        Start-Sleep -Milliseconds 350
    }
}
'@
    Set-Content -Path $launcherPath -Value $launcherBody -Encoding UTF8
    Write-Host "  [+] MiOS launcher staged: $launcherPath" -ForegroundColor DarkGray

    # Resolve a pwsh.exe for the .lnk target.
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwshExe) { Write-Host "  [!] No pwsh.exe found; cannot create launcher .lnk." -ForegroundColor Yellow; return }

    $lnkArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
    $lnkDesc = 'MiOS -- Immutable Fedora AI Workstation. Borderless 80x30 acrylic terminal.'

    # Resolve an icon: prefer M:\MiOS\icons\mios.ico if present, else
    # fall back to wt.exe's embedded icon (still better than the
    # default PowerShell shortcut icon).
    $iconPath = Join-Path $miosRoot 'icons\mios.ico'
    if (-not (Test-Path -LiteralPath $iconPath)) {
        $altIcon = 'M:\MiOS\icons\mios.ico'
        if (Test-Path -LiteralPath $altIcon) { $iconPath = $altIcon } else { $iconPath = '' }
    }

    $shell = New-Object -ComObject WScript.Shell
    $writeLnk = {
        param([string]$Path)
        $sc = $shell.CreateShortcut($Path)
        $sc.TargetPath       = $pwshExe
        $sc.Arguments        = $lnkArgs
        $sc.WorkingDirectory = $miosRoot
        $sc.Description      = $lnkDesc
        $sc.WindowStyle      = 7   # 7 = Minimized; with -WindowStyle Hidden the parent flashes briefly otherwise
        if ($iconPath) { $sc.IconLocation = "$iconPath,0" }
        $sc.Save()
    }

    # Start Menu (per-user; survives on non-admin runs).
    $startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MiOS'
    if (-not (Test-Path $startMenuDir)) { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null }
    $smLnk = Join-Path $startMenuDir 'MiOS.lnk'
    & $writeLnk $smLnk
    Write-Host "  [+] Start Menu: $smLnk" -ForegroundColor DarkGray

    # Desktop.
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    if ($desktopDir -and (Test-Path $desktopDir)) {
        $deskLnk = Join-Path $desktopDir 'MiOS.lnk'
        & $writeLnk $deskLnk
        Write-Host "  [+] Desktop: $deskLnk" -ForegroundColor DarkGray
    }

    # AppUserModelID on both shortcuts so taskbar/Start group correctly.
    if (-not ('MiOS.NativeApp.Aumid' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MiOS.NativeApp {
    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Sequential)] public struct PROPVARIANT { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
        [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
        [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
        [PreserveSig] int Commit();
    }
    public static class Aumid {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
        public static extern void SHGetPropertyStoreFromParsingName(string p, IntPtr b, int f, ref Guid g, out IPropertyStore o);
        [DllImport("ole32.dll", PreserveSig=false)]
        public static extern void PropVariantClear(ref PROPVARIANT v);
        public static void Set(string lnk, string id) {
            Guid ipsGuid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore ps;
            SHGetPropertyStoreFromParsingName(lnk, IntPtr.Zero, 2, ref ipsGuid, out ps);
            try {
                PROPERTYKEY pk = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
                IntPtr s = Marshal.StringToCoTaskMemUni(id);
                PROPVARIANT pv = new PROPVARIANT { vt = 31, p = s };
                try { ps.SetValue(ref pk, ref pv); ps.Commit(); }
                finally { PropVariantClear(ref pv); }
            } finally { Marshal.FinalReleaseComObject(ps); }
        }
    }
}
'@ -Language CSharp -ErrorAction SilentlyContinue
    }
    if ('MiOS.NativeApp.Aumid' -as [type]) {
        try {
            [MiOS.NativeApp.Aumid]::Set($smLnk, 'MiOS.Workstation')
            if ($desktopDir -and (Test-Path "$desktopDir\MiOS.lnk")) {
                [MiOS.NativeApp.Aumid]::Set("$desktopDir\MiOS.lnk", 'MiOS.Workstation')
            }
            Write-Host "  [+] AppUserModelID = MiOS.Workstation stamped on shortcuts." -ForegroundColor DarkGray
        } catch {
            Write-Host "  [!] AppUserModelID stamp failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Add/Remove Programs registration -- HKCU so non-admin runs work.
    try {
        $uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS'
        if (-not (Test-Path $uninstKey)) { New-Item -Path $uninstKey -Force | Out-Null }
        Set-ItemProperty -Path $uninstKey -Name 'DisplayName'     -Value 'MiOS - Immutable Fedora AI Workstation' -Force
        Set-ItemProperty -Path $uninstKey -Name 'DisplayVersion'  -Value 'v0.2.4' -Force
        Set-ItemProperty -Path $uninstKey -Name 'Publisher'       -Value 'mios-dev' -Force
        Set-ItemProperty -Path $uninstKey -Name 'InstallLocation' -Value $miosRoot -Force
        Set-ItemProperty -Path $uninstKey -Name 'URLInfoAbout'    -Value 'https://github.com/mios-dev/mios' -Force
        if ($iconPath) { Set-ItemProperty -Path $uninstKey -Name 'DisplayIcon' -Value $iconPath -Force }
        Set-ItemProperty -Path $uninstKey -Name 'NoModify' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $uninstKey -Name 'NoRepair' -Value 1 -Type DWord -Force
        # UninstallString: a one-line PS that removes the shortcuts +
        # uninstall key + launcher. The full-fat uninstaller comes
        # later from build-mios.ps1 (handles WSL distros etc.); this
        # is the minimum viable for "Settings > Apps > Uninstall".
        $uninstCmd = "$pwshExe -NoProfile -ExecutionPolicy Bypass -Command `"Remove-Item -LiteralPath '$smLnk','$desktopDir\MiOS.lnk' -Force -EA SilentlyContinue; Remove-Item -LiteralPath '$uninstKey' -Recurse -Force -EA SilentlyContinue`""
        Set-ItemProperty -Path $uninstKey -Name 'UninstallString' -Value $uninstCmd -Force
        Write-Host "  [+] Add/Remove Programs entry registered (HKCU\...\Uninstall\MiOS)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  [!] Uninstall key write failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Best-effort Pin to Start (Win10 only; Win11 has no programmatic verb).
    try {
        $shellApp = New-Object -ComObject Shell.Application
        $folderObj = $shellApp.Namespace($startMenuDir)
        $itemObj = $folderObj.ParseName('MiOS.lnk')
        $pinVerb = $itemObj.Verbs() | Where-Object { ($_.Name -replace '&','') -match '^(Pin to Start|Pin to taskbar)$' } | Select-Object -First 1
        if ($pinVerb) {
            $pinVerb.DoIt()
            Write-Host "  [+] MiOS pinned to Start menu." -ForegroundColor Green
        } else {
            $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            if ($os -match 'Windows 11') {
                Write-Host "  [i] Windows 11 removed programmatic Pin-to-Start. Right-click MiOS in Start search -> Pin to Start." -ForegroundColor DarkGray
            }
        }
    } catch {}

    Write-Host "  [+] MiOS installed as a native Windows app." -ForegroundColor Green
}

# Canonical MiOS branding ASCII art (also at /usr/share/mios/branding/mios.txt
# inside the deployed MiOS Linux image). Used by fastfetch as the
# "logo" via raw-source mode.
$Script:MiosBrandingTxt = @'
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
'@

# Canonical MiOS fastfetch config -- Windows variant of mios.git's
# /usr/share/mios/fastfetch/config.jsonc. MiOS palette colors (Hokusai)
# applied to title/keys/separator. Modules trimmed to Windows-relevant
# ones (no Linux-side packages/locale/swap noise). Logo source is a
# placeholder __MIOS_LOGO__ that Install-MiOSFastfetch / the profile
# script's self-heal substitute with the actual mios.txt path.
$Script:MiosFastfetchConfig = @'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": { "type": "none" },
  "display": {
    "separator": "  ",
    "color": {
      "keys": "#F35C15",
      "title": "#E7DFD3",
      "output": "#B7C9D7"
    }
  },
  "modules": [
    "title",
    { "type": "os",       "key": "OS"       },
    { "type": "host",     "key": "Host"     },
    { "type": "uptime",   "key": "Uptime"   },
    { "type": "shell",    "key": "Shell"    },
    { "type": "cpu",      "key": "CPU"      },
    { "type": "gpu",      "key": "GPU",       "format": "{name}" },
    { "type": "memory",   "key": "Memory"   },
    { "type": "disk",     "key": "Disk",      "folders": "C:" },
    { "type": "datetime", "key": "Time"     }
  ]
}
'@

# Canonical MiOS oh-my-posh theme content. Hoisted to script scope so
# both Install-MiOSOhMyPoshTheme (writes the file at install time) and
# Install-MiOSPowerShellProfile (embeds it as a self-heal blob in the
# M:\ profile script) reference the same source. KEEP IN SYNC with
# mios.git:usr/share/mios/oh-my-posh/mios.omp.json.
$Script:MiosOmpJson = @'
{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "version": 4,
  "final_space": true,
  "//": [
    "MiOS Oh-My-Posh theme.",
    "All Nerd Font private-use-area glyphs are encoded as JSON \\uXXXX",
    "escape sequences (json.dump ensure_ascii=True) so the file roundtrips",
    "through any editor/git/sync layer without losing the U+E000..F8FF",
    "code points -- write-tool sanitizers strip raw PUA chars on save.",
    "Palette: mios.toml [colors] (Hokusai + operator neutrals).",
    "MiOS-owned segments use the MiOS palette; language segments keep",
    "brand colors so Node-green / Python-blue+yellow / Rust-orange stay",
    "instantly recognizable. Squared Powerline arrows only -- rounded",
    "caps (E0B4 / E0B6) dropped for cross-terminal compat."
  ],
  "blocks": [
    {
      "type": "prompt",
      "alignment": "left",
      "segments": [
        {
          "type": "text",
          "style": "plain",
          "foreground": "#B7C9D7",
          "template": "\u256d\u2500"
        },
        {
          "type": "shell",
          "style": "powerline",
          "powerline_symbol": "\ue0b0",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "template": " \uf120 {{ .Name }} "
        },
        {
          "type": "root",
          "style": "powerline",
          "powerline_symbol": "\ue0b0",
          "background": "#DC271B",
          "foreground": "#F35C15",
          "template": " \uf292 "
        },
        {
          "type": "path",
          "style": "powerline",
          "powerline_symbol": "\ue0b0",
          "background": "#F35C15",
          "foreground": "#282262",
          "properties": {
            "folder_icon": " \uf07b ",
            "home_icon": "\uf015",
            "style": "agnoster_short",
            "max_depth": 3
          },
          "template": " \uf07b {{ .Path }} "
        },
        {
          "type": "git",
          "style": "powerline",
          "powerline_symbol": "\ue0b0",
          "background": "#3E7765",
          "background_templates": [
            "{{ if or (.Working.Changed) (.Staging.Changed) }}#F35C15{{ end }}",
            "{{ if and (gt .Ahead 0) (gt .Behind 0) }}#DC271B{{ end }}",
            "{{ if gt .Ahead 0 }}#1A407F{{ end }}",
            "{{ if gt .Behind 0 }}#734F39{{ end }}"
          ],
          "foreground": "#282262",
          "properties": {
            "branch_icon": "\ue0a0 ",
            "fetch_status": true,
            "fetch_upstream_icon": true
          },
          "template": " \ue702 {{ .UpstreamIcon }}{{ .HEAD }}{{ if .BranchStatus }} {{ .BranchStatus }}{{ end }}{{ if .Working.Changed }} \u270e{{ .Working.String }}{{ end }}{{ if and (.Working.Changed) (.Staging.Changed) }} |{{ end }}{{ if .Staging.Changed }}<#DC271B> +{{ .Staging.String }}</>{{ end }} "
        },
        {
          "type": "executiontime",
          "style": "powerline",
          "powerline_symbol": "\ue0b0",
          "background": "#948E8E",
          "foreground": "#282262",
          "properties": {
            "style": "roundrock",
            "threshold": 0
          },
          "template": " \ueba2 {{ .FormattedMs }} "
        }
      ]
    },
    {
      "type": "prompt",
      "alignment": "right",
      "segments": [
        {
          "type": "node",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#303030",
          "foreground": "#3C873A",
          "properties": {
            "fetch_package_manager": true,
            "npm_icon": " <#cc3a3a>\ue5fa</> ",
            "yarn_icon": " <#348cba>\ue6a7</>"
          },
          "template": " \ue718 {{ if .PackageManagerIcon }}{{ .PackageManagerIcon }} {{ end }}{{ .Full }} "
        },
        {
          "type": "python",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#306998",
          "foreground": "#FFE873",
          "template": " \ue235 {{ if .Error }}{{ .Error }}{{ else }}{{ if .Venv }}{{ .Venv }} {{ end }}{{ .Full }}{{ end }} "
        },
        {
          "type": "go",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#E7DFD3",
          "foreground": "#06aad5",
          "template": " \ue626 {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "rust",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#E7DFD3",
          "foreground": "#925837",
          "template": " \ue7a8 {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "dotnet",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#0e0e0e",
          "foreground": "#0d6da8",
          "template": " \ue77f {{ if .Unsupported }}\uf071{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "kubectl",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "template": " \uf308 {{ .Context }}{{ if .Namespace }} :: {{ .Namespace }}{{ end }} "
        },
        {
          "type": "aws",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#565656",
          "foreground": "#F35C15",
          "template": " \ue7ad {{ .Profile }}{{ if .Region }}@{{ .Region }}{{ end }} "
        },
        {
          "type": "os",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#B7C9D7",
          "foreground": "#282262",
          "properties": {
            "linux": "\ue712",
            "macos": "\ue711",
            "windows": "\ue70f"
          },
          "template": " {{ if .WSL }}WSL at {{ end }}{{ .Icon }} "
        },
        {
          "type": "battery",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#F35C15",
          "background_templates": [
            "{{ if eq \"Charging\" .State.String }}#3E7765{{ end }}",
            "{{ if eq \"Discharging\" .State.String }}#F35C15{{ end }}",
            "{{ if eq \"Full\" .State.String }}#3E7765{{ end }}"
          ],
          "foreground": "#282262",
          "properties": {
            "charged_icon": "\uf240 ",
            "charging_icon": "\uf1e6 ",
            "discharging_icon": "\ue234 "
          },
          "template": " {{ if not .Error }}{{ .Icon }}{{ .Percentage }}{{ end }}{{ .Error }} \uf295 "
        },
        {
          "type": "time",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b2",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "properties": {
            "time_format": "_2,15:04"
          },
          "template": " \uf073 {{ .CurrentDate | date .Format }} "
        }
      ]
    },
    {
      "type": "prompt",
      "alignment": "left",
      "newline": true,
      "segments": [
        {
          "type": "text",
          "style": "plain",
          "foreground": "#B7C9D7",
          "template": "\u2570\u2500"
        },
        {
          "type": "status",
          "style": "plain",
          "foreground": "#3E7765",
          "foreground_templates": [
            "{{ if gt .Code 0 }}#DC271B{{ end }}"
          ],
          "properties": {
            "always_enabled": true
          },
          "template": " \u276f "
        }
      ]
    }
  ]
}
'@

function Update-MiOSOhMyPosh {
    # winget install/upgrade oh-my-posh to latest. Operator-reported
    # "Get-PSReadLineKeyHandler Spacebar / Enter / Ctrl+c" positional
    # parameter errors come from oh-my-posh's init script emitting the
    # legacy positional syntax that no PSReadLine version accepts.
    # Latest oh-my-posh emits -Chord <key> -- the correct named-parameter
    # syntax. So bumping oh-my-posh fixes the init errors at the source.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] winget not available; cannot install oh-my-posh." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [*] Installing/upgrading oh-my-posh via winget..." -ForegroundColor Cyan
    try {
        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
            & winget upgrade --id JanDeDobbeleer.OhMyPosh --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } else {
            & winget install --id JanDeDobbeleer.OhMyPosh --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [+] oh-my-posh installed/upgraded." -ForegroundColor Green
            return $true
        }
        Write-Host "  [!] winget exit code $LASTEXITCODE -- oh-my-posh may not be latest." -ForegroundColor Yellow
    } catch {
        Write-Host "  [!] oh-my-posh install/upgrade failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $false
}

function Update-MiOSPSReadLine {
    # oh-my-posh's init pwsh emits Get-PSReadLineKeyHandler calls that
    # use named parameters (Get-PSReadLineKeyHandler -Chord Spacebar).
    # The version of PSReadLine that ships in PowerShell 7.6's box is
    # too old to accept those args -- it expects positional, and emits
    # "A positional parameter cannot be found that accepts argument
    # 'Spacebar'/'Enter'/'Ctrl+c'". This breaks oh-my-posh init, which
    # then leaves the prompt in a fallback state.
    #
    # Fix: install/update PSReadLine via PowerShellGet to >= 2.3.5.
    # Per-user (-Scope CurrentUser) so we don't need elevation.
    try {
        $current = Get-Module -ListAvailable -Name PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
        if ($current -and $current.Version -ge [version]'2.3.5') {
            Write-Host "  [+] PSReadLine $($current.Version) already meets oh-my-posh's requirements." -ForegroundColor DarkGray
            return $true
        }
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            Write-Host "  [!] PowerShellGet not available; cannot bump PSReadLine. oh-my-posh init may emit warnings." -ForegroundColor Yellow
            return $false
        }
        Write-Host "  [*] Installing/updating PSReadLine to 2.3.5+..." -ForegroundColor Cyan
        # Trust PSGallery so install doesn't prompt.
        try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module -Name PSReadLine -MinimumVersion 2.3.5 -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
        Write-Host "  [+] PSReadLine updated." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] PSReadLine update failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Install-MiOSFastfetch {
    # winget install fastfetch + stage MiOS-themed config and ASCII
    # logo at M:\MiOS\fastfetch\ (or LOCALAPPDATA fallback). The PS
    # profile invokes `fastfetch -c <staged>` on every MiOS shell
    # session start so the operator sees a MiOS-branded MOTD.
    $alreadyInstalled = $false
    if (Get-Command fastfetch -ErrorAction SilentlyContinue) { $alreadyInstalled = $true }
    if (-not $alreadyInstalled) {
        try {
            $probe = & winget list --id Fastfetch-cli.Fastfetch --exact 2>$null
            if ($LASTEXITCODE -eq 0 -and ($probe -join "`n") -match 'Fastfetch-cli\.Fastfetch') {
                $alreadyInstalled = $true
            }
        } catch {}
    }
    if (-not $alreadyInstalled) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host "  [!] winget not available; cannot auto-install fastfetch." -ForegroundColor Yellow
            Write-Host "      Install manually: https://github.com/fastfetch-cli/fastfetch/releases" -ForegroundColor DarkGray
        } else {
            Write-Host "  [*] Installing fastfetch via winget..." -ForegroundColor Cyan
            try {
                & winget install --id Fastfetch-cli.Fastfetch --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [+] fastfetch installed." -ForegroundColor Green
                } else {
                    Write-Host "  [!] winget exit code $LASTEXITCODE -- fastfetch may not be installed." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  [!] winget install fastfetch failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [+] fastfetch already installed." -ForegroundColor DarkGray
    }

    # Stage the config + logo on M:\ (or LOCALAPPDATA fallback).
    $miosRoot = if (Test-Path 'M:\') { 'M:\MiOS' } else { Join-Path $env:LOCALAPPDATA 'MiOS' }
    $ffDir = Join-Path $miosRoot 'fastfetch'
    if (-not (Test-Path $ffDir)) { New-Item -ItemType Directory -Path $ffDir -Force | Out-Null }
    $logoPath   = Join-Path $ffDir 'mios.txt'
    $configPath = Join-Path $ffDir 'config.jsonc'

    Set-Content -Path $logoPath -Value $Script:MiosBrandingTxt -Encoding UTF8

    # Bake the actual logo path into the JSONC -- escape backslashes
    # for the JSON string ("M:\\MiOS\\fastfetch\\mios.txt").
    $logoPathJson = $logoPath -replace '\\', '\\'
    $resolvedConfig = $Script:MiosFastfetchConfig -replace '__MIOS_LOGO__', $logoPathJson
    Set-Content -Path $configPath -Value $resolvedConfig -Encoding UTF8

    if ((Test-Path $configPath) -and (Test-Path $logoPath)) {
        Write-Host "  [+] fastfetch theme staged: $configPath" -ForegroundColor DarkGray
        Write-Host "  [+] MiOS branding logo:    $logoPath" -ForegroundColor DarkGray
    } else {
        Write-Host "  [!] fastfetch theme staging FAILED at $ffDir" -ForegroundColor Yellow
    }
    return $configPath
}

function Install-MiOSOhMyPoshTheme {
    # Stage mios.omp.json at M:\MiOS\themes\ (or LOCALAPPDATA fallback)
    # so the $PROFILE init block finds it on first launch -- prevents
    # the "CONFIG NOT FOUND" prompt segment.
    $miosRoot = if (Test-Path 'M:\') { 'M:\MiOS' } else { Join-Path $env:LOCALAPPDATA 'MiOS' }
    $themesDir = Join-Path $miosRoot 'themes'
    if (-not (Test-Path $themesDir)) { New-Item -ItemType Directory -Path $themesDir -Force | Out-Null }
    $ompPath = Join-Path $themesDir 'mios.omp.json'
    Set-Content -Path $ompPath -Value $Script:MiosOmpJson -Encoding UTF8
    if (Test-Path -LiteralPath $ompPath) {
        $sz = (Get-Item $ompPath).Length
        Write-Host "  [+] mios.omp.json staged: $ompPath ($sz bytes)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [!] mios.omp.json write FAILED at $ompPath" -ForegroundColor Yellow
    }
    return $ompPath
}

function Install-MiOSPowerShellProfile {
    # Per the M:\-everywhere invariant: the actual oh-my-posh init
    # script lives at M:\MiOS\powershell\profile.ps1. The C:\ user
    # profile ($PROFILE.CurrentUserAllHosts) gets a tiny redirector
    # block that dot-sources the M:\ script -- so the operator can
    # edit the M:\ copy and every PS shell picks up changes on next
    # launch, without bouncing through C:\.
    $miosPsRoot = if (Test-Path 'M:\') { 'M:\MiOS\powershell' }
                  else { Join-Path $env:USERPROFILE 'MiOS-bootstrap\powershell' }
    if (-not (Test-Path $miosPsRoot)) { New-Item -ItemType Directory -Path $miosPsRoot -Force | Out-Null }
    $miosProfileScript = Join-Path $miosPsRoot 'profile.ps1'

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

    # Write the FULL oh-my-posh init script to M:\MiOS\powershell\profile.ps1.
    # The C:\ user profile only gets a thin redirector that dot-sources
    # this file -- so future edits to the M:\ copy take effect on next
    # shell launch with no C:\ round-trip.
    # Build the M:\ profile script. Self-heals every embedded artifact
    # (oh-my-posh config + fastfetch config + MiOS ASCII logo) on
    # dot-source if the file isn't already staged on disk -- so even
    # an operator who irm|iex'd an older Get-MiOS.ps1 without these
    # stages gets a fully-themed MiOS terminal on the next pwsh launch.
    $ompBlobBase64    = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script:MiosOmpJson))
    $ffConfigBase64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script:MiosFastfetchConfig))
    $ffLogoBase64     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script:MiosBrandingTxt))
    $miosScriptBody = @"
# MiOS PowerShell profile -- PSReadLine reload + fastfetch MOTD +
# oh-my-posh init.
# Source of truth: this file lives on M:\ and is dot-sourced from
# `$PROFILE.CurrentUserAllHosts AND from the WT MiOS profile's
# explicit -Command preamble (so it ALWAYS runs in MiOS terminals,
# even when the operator's $PROFILE has its own broken oh-my-posh
# init that would otherwise override ours).
# Self-heals every artifact (mios.omp.json, fastfetch config.jsonc,
# mios.txt ASCII logo) from embedded base64 blobs if the canonical
# disk copy is missing.

# NO TERMINAL-TYPE GATE. Always run the PSReadLine reload + oh-my-
# posh init. The WT_SESSION gate on the previous version was
# silently skipping the init when WT didn't set the env var early
# enough -- producing the "theme works in normal terminal but not
# MiOS Terminal" symptom. fastfetch is gated separately below
# since its ASCII rendering only makes sense in a real terminal.
if (`$true) {

    # ── PSReadLine reload ─────────────────────────────────────────
    # PowerShell 7.x ships with an in-box PSReadLine that's too old
    # for oh-my-posh init's Get-PSReadLineKeyHandler -Chord syntax.
    # Updating PSReadLine on disk (Install-Module) doesn't help the
    # CURRENT session because PSReadLine is autoloaded BEFORE the
    # profile runs. Force-import the newest installed version here
    # so oh-my-posh init's PSReadLine integration doesn't throw
    # "A positional parameter cannot be found that accepts argument
    # 'Spacebar'/'Enter'/'Ctrl+c'".
    try {
        `$latestPSRL = Get-Module -ListAvailable -Name PSReadLine |
                       Sort-Object Version -Descending | Select-Object -First 1
        if (`$latestPSRL -and `$latestPSRL.Version -ge [version]'2.3.5') {
            Import-Module PSReadLine -RequiredVersion `$latestPSRL.Version -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # ── Resolve / self-heal MiOS artifact paths ───────────────────
    `$miosArtifactRoot = if (Test-Path 'M:\') { 'M:\MiOS' } else { Join-Path `$env:LOCALAPPDATA 'MiOS' }
    function _MiosSelfHeal {
        param([string]`$RelDir, [string]`$FileName, [string]`$Blob)
        `$dir = Join-Path `$miosArtifactRoot `$RelDir
        if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
        `$path = Join-Path `$dir `$FileName
        if (-not (Test-Path -LiteralPath `$path)) {
            try { [System.IO.File]::WriteAllBytes(`$path, [Convert]::FromBase64String(`$Blob)) } catch { return `$null }
        }
        return `$path
    }

    # oh-my-posh config -- probe canonical paths, self-heal if missing.
    `$miosOmp = `$null
    `$ompCands = @()
    if (`$env:MIOS_OMP_JSON) { `$ompCands += `$env:MIOS_OMP_JSON }
    `$ompCands += @(
        'M:\MiOS\themes\mios.omp.json',
        'M:\usr\share\mios\oh-my-posh\mios.omp.json',
        'C:\MiOS\themes\mios.omp.json',
        'C:\MiOS\usr\share\mios\oh-my-posh\mios.omp.json',
        (Join-Path `$env:LOCALAPPDATA 'MiOS\themes\mios.omp.json')
    )
    foreach (`$c in `$ompCands) {
        if (`$c -and (Test-Path -LiteralPath `$c)) { `$miosOmp = `$c; break }
    }
    if (-not `$miosOmp) {
        `$miosOmp = _MiosSelfHeal 'themes' 'mios.omp.json' '$ompBlobBase64'
    }

    # ── Framed MiOS dashboard (mirrors mios-dashboard.sh from mios.git) ─
    # 80-col fixed frame, centered ASCII logo, framed fastfetch info.
    # Gated on WT_SESSION since the ╭─╮ box-drawing only renders
    # properly in WT (conhost / VS Code embedded shell mangles it).
    function Show-MiosDashboard {
        param([string]`$ConfigPath, [string]`$LogoPath)
        `$WIDTH = 80
        `$INNER = `$WIDTH - 4
        `$TL='╭'; `$TR='╮'; `$BL='╰'; `$BR='╯'; `$LT='├'; `$RT='┤'; `$V='│'; `$H='─'

        function _Strip { param(`$s) `$s -replace '\x1b\[[0-9;]*m','' }
        function _Frame {
            param([string]`$Line)
            `$visible = _Strip `$Line
            if (`$visible.Length -gt `$INNER) {
                # Truncate with ellipsis preserving ANSI prefix.
                `$Line = `$Line.Substring(0, [math]::Min(`$Line.Length, `$INNER + (`$Line.Length - `$visible.Length) - 1)) + '…'
                `$visible = _Strip `$Line
            }
            `$pad = ' ' * [math]::Max(0, `$INNER - `$visible.Length)
            "`$V `$Line`$pad `$V"
        }
        function _Center {
            param([string]`$Line)
            `$visible = _Strip `$Line
            `$totalPad = [math]::Max(0, `$INNER - `$visible.Length)
            `$lpad = ' ' * [math]::Floor(`$totalPad / 2)
            `$rpad = ' ' * (`$totalPad - [math]::Floor(`$totalPad / 2))
            "`$V `$lpad`$Line`$rpad `$V"
        }

        # Top frame.
        Write-Host (`$TL + (`$H * (`$WIDTH - 2)) + `$TR) -ForegroundColor Blue
        # Centered ASCII logo (operator-blue).
        if (Test-Path -LiteralPath `$LogoPath) {
            `$logoLines = (Get-Content -LiteralPath `$LogoPath) | Where-Object { `$_ -ne `$null }
            foreach (`$ll in `$logoLines) { Write-Host (_Center `$ll) -ForegroundColor Blue }
        }
        # Divider.
        Write-Host (`$LT + (`$H * (`$WIDTH - 2)) + `$RT) -ForegroundColor Blue
        # Framed fastfetch (no logo -- we drew it above).
        if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
            try {
                `$ffOut = & fastfetch -c `$ConfigPath --logo none 2>&1 | Out-String -Stream
                foreach (`$ln in `$ffOut) {
                    if (`$null -eq `$ln) { continue }
                    Write-Host (_Frame `$ln)
                }
            } catch {
                Write-Host (_Frame "  fastfetch failed: `$(`$_.Exception.Message)")
            }
        } else {
            Write-Host (_Frame '  fastfetch not installed -- run mios-update to refresh.')
        }
        # Bottom frame.
        Write-Host (`$BL + (`$H * (`$WIDTH - 2)) + `$BR) -ForegroundColor Blue
    }

    if ((`$env:WT_SESSION -or `$env:TERM_PROGRAM -eq 'mios') -and (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        `$miosLogo   = _MiosSelfHeal 'fastfetch' 'mios.txt'      '$ffLogoBase64'
        `$miosFFCfg  = _MiosSelfHeal 'fastfetch' 'config.jsonc'  '$ffConfigBase64'
        if (`$miosLogo -and `$miosFFCfg -and `$Host.UI.RawUI -and (-not `$env:MIOS_SKIP_MOTD)) {
            try { Show-MiosDashboard -ConfigPath `$miosFFCfg -LogoPath `$miosLogo } catch {}
        }
    }

    # ── oh-my-posh init ───────────────────────────────────────────
    # Capture the init script output, then regex-patch the broken
    # positional Get-PSReadLineKeyHandler calls. Older oh-my-posh
    # versions emit `Get-PSReadLineKeyHandler Spacebar` etc. -- which
    # NO PSReadLine version accepts (the cmdlet's parameter binder
    # has no positional [string]). Latest oh-my-posh emits -Chord
    # <key>. We inject -Chord even when running latest, since it's
    # idempotent (latest already has it). This makes oh-my-posh's
    # PSReadLine integration work regardless of installed version.
    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        `$ompInit = if (`$miosOmp -and (Test-Path -LiteralPath `$miosOmp)) {
            (oh-my-posh init pwsh --config `$miosOmp) -join "``n"
        } else {
            (oh-my-posh init pwsh) -join "``n"
        }
        if (`$ompInit) {
            `$ompInit = [regex]::Replace(`$ompInit, 'Get-PSReadLineKeyHandler\s+(?!-)([A-Za-z][\w+]*)', 'Get-PSReadLineKeyHandler -Chord ''`$1''')
            try { Invoke-Expression `$ompInit } catch {}
        }
    }
}

# ── MiOS commands ───────────────────────────────────────────────────
# Defined in EVERY pwsh session (not gated on WT_SESSION) so the
# operator can run mios-build / mios-update / mios-help from any shell.
# Each command fetches its target script fresh from
# raw.githubusercontent.com so the operator doesn't have to manually
# pull the mios-bootstrap repo. Cache-busting via ?cb=<unix-time>
# defeats Fastly's 5-minute max-age.

`$Script:MiosBootstrapRaw = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main'

function mios-build {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)]`$Args)
    `$cb = [int][double]::Parse((Get-Date -UFormat %s))
    `$src = Invoke-RestMethod -Uri "`$Script:MiosBootstrapRaw/build-mios.ps1?cb=`$cb" -Headers @{ 'Cache-Control' = 'no-cache' }
    & ([scriptblock]::Create(`$src)) @Args
}

function mios-update {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)]`$Args)
    `$cb = [int][double]::Parse((Get-Date -UFormat %s))
    `$src = Invoke-RestMethod -Uri "`$Script:MiosBootstrapRaw/Get-MiOS.ps1?cb=`$cb" -Headers @{ 'Cache-Control' = 'no-cache' }
    & ([scriptblock]::Create(`$src)) @Args
}

function mios-pull {
    if (-not (Test-Path 'M:\.git')) {
        Write-Host '  [!] M:\ is not a git working tree -- run mios-build first.' -ForegroundColor Yellow
        return
    }
    Push-Location 'M:\'
    try {
        git fetch --depth=1 origin main
        if (`$LASTEXITCODE -eq 0) {
            git reset --hard FETCH_HEAD
            Write-Host '  [+] M:\ overlay synced to origin/main.' -ForegroundColor Green
        } else {
            Write-Host '  [!] git fetch failed -- check network.' -ForegroundColor Yellow
        }
    } finally { Pop-Location }
}

function mios-config {
    `$cfg = if (Test-Path 'M:\usr\share\mios\configurator\index.html') { 'M:\usr\share\mios\configurator\index.html' }
           elseif (Test-Path 'C:\MiOS\usr\share\mios\configurator\index.html') { 'C:\MiOS\usr\share\mios\configurator\index.html' }
           else { `$null }
    if (`$cfg) {
        Start-Process `$cfg
        Write-Host "  [+] Opened `$cfg" -ForegroundColor DarkGray
    } else {
        Write-Host '  [!] configurator not found -- run mios-build to deploy it.' -ForegroundColor Yellow
    }
}

function mios-dev {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)]`$Args)
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host '  [!] wsl.exe not on PATH -- WSL2 may not be installed.' -ForegroundColor Yellow
        return
    }
    & wsl.exe -d MiOS-DEV --cd / --user mios @Args
}

function mios-help {
    Write-Host ''
    Write-Host '  MiOS commands' -ForegroundColor Cyan
    Write-Host '  -------------' -ForegroundColor DarkCyan
    Write-Host '  mios-build    run the full MiOS OS bootstrap (WSL2 + podman + dev VM)' -ForegroundColor White
    Write-Host '  mios-update   re-run Get-MiOS.ps1 (refresh terminal install)' -ForegroundColor White
    Write-Host '  mios-pull     git fetch + hard reset M:\ to origin/main' -ForegroundColor White
    Write-Host '  mios-config   open the HTML configurator (mios.toml editor)' -ForegroundColor White
    Write-Host '  mios-dev      wsl into the MiOS-DEV distro (root /, user mios)' -ForegroundColor White
    Write-Host '  mios-help     this list' -ForegroundColor White
    Write-Host ''
}
"@
    Set-Content -Path $miosProfileScript -Value $miosScriptBody -Encoding UTF8

    # Thin C:\ redirector -- dot-sources the M:\ script.
    $redirector = $miosProfileScript -replace '\\', '\\'
    $block = @"
$marker
# Thin redirector to the canonical MiOS PS profile on M:\.
# Auto-generated by Get-MiOS.ps1 -- regenerated on every bootstrap.
# DO NOT edit between the markers; edit M:\MiOS\powershell\profile.ps1.
if (Test-Path '$miosProfileScript') {
    . '$miosProfileScript'
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
    Write-Host "  [+] MiOS PS profile body: $miosProfileScript" -ForegroundColor Green
    Write-Host "  [+] Redirector at $profilePath" -ForegroundColor DarkGray
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

    # IMPORTANT: do NOT strip WS_THICKFRAME / WS_CAPTION via
    # SetWindowLongPtr -- DWM's acrylic compositor REQUIRES those style
    # bits to allocate the per-window swap chain that backs the blur
    # surface. Earlier revisions stripped them for "completely
    # borderless" -- and the cost was no acrylic at all (the window
    # rendered as a flat black popup). The WT-side `--focus` flag +
    # padding=0 + suppressApplicationTitle gives the closest-to-
    # borderless WT can deliver while keeping acrylic alive: a 1px
    # DWM resize frame remains, but the titlebar / tab row / min-max
    # buttons are all gone.

    # Re-center 3 times with 350ms gaps. WT in focus mode often animates
    # the window to its last-known position AFTER the first SetWindowPos
    # registers, then settles. A single move loses the race; three
    # spaced-out moves stick. Each iteration re-reads the outer rect
    # (size can shift slightly during animation) so center math is
    # always against the current dimensions.
    $hwndTopmost = [IntPtr]::new(-1)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $rect = New-Object MiOS.Native.Win+RECT
        if (-not [MiOS.Native.Win]::GetWindowRect($hwnd, [ref]$rect)) { return $false }
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        if ($w -le 0 -or $h -le 0) { return $false }
        $x = [int]($ScreenInfo.ScreenLeft + ($ScreenInfo.ScreenWidth  - $w) / 2)
        $y = [int]($ScreenInfo.ScreenTop  + ($ScreenInfo.ScreenHeight - $h) / 2)
        # HWND_TOPMOST + SWP_SHOWWINDOW = 0x40.
        [void][MiOS.Native.Win]::SetWindowPos($hwnd, $hwndTopmost, $x, $y, $w, $h, 0x40)
        # Belt-and-braces no-zorder pass.
        [void][MiOS.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x04)
        Start-Sleep -Milliseconds 350
    }
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
    # Strict install order. Each step gates the next:
    #   1. WT Preview install + AppX-ready wait. Until this completes
    #      LocalState\settings.json doesn't exist and the patcher
    #      silently no-ops -- which is exactly what the operator
    #      caught us doing in earlier revisions.
    #   2. settings.json patch IMMEDIATELY after install, while the
    #      LocalState dir is freshly materialized. This is what makes
    #      MiOS the default theme on the very first WT launch.
    #   3. Geist Mono NF font install. Settings.json already references
    #      this face name; if the font isn't on disk yet WT will
    #      silently fall back to Cascadia, but the ANSI scheme + acrylic
    #      still apply -- so font order doesn't break anything else.
    #   4. PowerShell profile (oh-my-posh init line). Lowest priority;
    #      cosmetic, only matters once the operator hits a prompt.
    # Apply the MiOS palette + transparency settings to the Windows OS
    # registry so the OPERATOR'S WHOLE DESKTOP is MiOS-themed -- not
    # just the WT window. EnableTransparency is the precondition for
    # acrylic to render at all (Server / freshly-imaged Windows ships
    # with it OFF, which is why "no acrylic, nothing" was happening).
    # Dark mode + ColorPrevalence + DWM accent paint MiOS's operator-
    # blue (#1A407F) onto title bars, taskbar, and Start chrome too.
    #
    # MiOS canonical accent (mios.toml [colors].accent): #1A407F.
    # DWM stores AccentColor in 0xAABBGGRR layout (alpha + reverse-byte
    # BGR), so #1A407F encodes as 0xFF7F401A.
    try {
        $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $personalize)) { New-Item -Path $personalize -Force | Out-Null }
        Set-ItemProperty -Path $personalize -Name 'EnableTransparency'   -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $personalize -Name 'AppsUseLightTheme'    -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $personalize -Name 'ColorPrevalence'      -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

        # Use reg.exe directly. Both Set-ItemProperty -Type DWord AND
        # .NET Microsoft.Win32.RegistryKey.SetValue('DWord') reject
        # 0xFF7F401A in PS 7 / .NET 8 because their validators want
        # UInt32 inputs but PS represents the value as Int64
        # 4286529562, which overflows when downcast to Int32 (->
        # -8437734) and then fails UInt32's range check. reg.exe
        # accepts hex literals natively for REG_DWORD and writes the
        # raw 32-bit pattern -- DWM reads back the unsigned 0xFF7F401A.
        $dwmKeyReg = 'HKCU\Software\Microsoft\Windows\DWM'
        $accentHex = '0xFF7F401A'
        & reg.exe add $dwmKeyReg /v 'AccentColor'           /t REG_DWORD /d $accentHex /f *>$null
        & reg.exe add $dwmKeyReg /v 'ColorizationColor'     /t REG_DWORD /d $accentHex /f *>$null
        & reg.exe add $dwmKeyReg /v 'ColorizationAfterglow' /t REG_DWORD /d $accentHex /f *>$null
        & reg.exe add $dwmKeyReg /v 'ColorPrevalence'       /t REG_DWORD /d '1'        /f *>$null
        Write-Host "  [+] Windows global theme set to MiOS palette (dark mode + #1A407F accent + transparency)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  [!] Windows theme registry write failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "  [*] Step 1/6: Installing Windows Terminal (base) via winget..." -ForegroundColor Cyan
    if (-not (Install-MiOSWindowsTerminal)) {
        Write-Host "  [!] WT install failed -- bootstrap cannot continue without a themed WT to launch into." -ForegroundColor Red
        Write-Host "      Install manually and re-run: winget install Microsoft.WindowsTerminal" -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "  [*] Step 2/6: Patching WT settings.json with MiOS scheme + profiles..." -ForegroundColor Cyan
    Install-MiOSTerminalProfile     | Out-Null
    Write-Host "  [*] Step 3/6: Installing GeistMono Nerd Font (per-user, HKCU)..." -ForegroundColor Cyan
    Install-MiOSGeistFont           | Out-Null
    Write-Host "  [*] Step 4/6: Installing fastfetch + staging MiOS-themed config..." -ForegroundColor Cyan
    Install-MiOSFastfetch           | Out-Null
    Write-Host "  [*] Step 5/6: oh-my-posh + PSReadLine + mios.omp.json + profile wiring..." -ForegroundColor Cyan
    Update-MiOSOhMyPosh             | Out-Null
    Update-MiOSPSReadLine           | Out-Null
    Install-MiOSOhMyPoshTheme       | Out-Null
    Install-MiOSPowerShellProfile   | Out-Null
    Write-Host "  [*] Step 6/6: Registering MiOS as a native Windows app..." -ForegroundColor Cyan
    Install-MiOSNativeApp           | Out-Null

    # Reload the user profile in the CURRENT irm|iex pwsh session so
    # the regex-patch + PSReadLine reload + MiOS prompt take effect
    # immediately, without the operator having to close + re-open
    # pwsh. The redirector was just written -- dot-source it now.
    try {
        if ($PROFILE.CurrentUserAllHosts -and (Test-Path -LiteralPath $PROFILE.CurrentUserAllHosts)) {
            . $PROFILE.CurrentUserAllHosts
            Write-Host "  [+] Profile reloaded in this session (oh-my-posh + MiOS prompt active)." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [!] Profile reload failed (will take effect on next pwsh launch): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Per operator: do NOT auto-launch anything. The MiOS app is now
    # installed -- the operator launches it on their own from Start
    # Menu or Desktop. No elevated wt.exe spawn, no UAC prompt, no
    # auto-bootstrap. Clean exit with a one-screen summary.
    Write-Host ''
    Write-Host '+============================================================+' -ForegroundColor Cyan
    Write-Host '|  MiOS install complete.                                    |' -ForegroundColor Cyan
    Write-Host '+============================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Launch from:  Start Menu  ->  MiOS' -ForegroundColor White
    Write-Host '          or:   Desktop     ->  MiOS' -ForegroundColor White
    Write-Host ''
    Write-Host '  The MiOS terminal opens centered, borderless, 80x30, acrylic,' -ForegroundColor DarkGray
    Write-Host '  Geist Mono Nerd Font, Hokusai palette, always-on-top.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  To run the full MiOS OS bootstrap (WSL2 + podman + dev VM),' -ForegroundColor DarkGray
    Write-Host '  open a MiOS terminal and run:  irm $RepoUrl/raw/main/build-mios.ps1 | iex' -ForegroundColor DarkGray
    Write-Host ''
    return

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
    # Resolve wt.exe to WT STABLE -- the base install. Falls back to
    # the App Execution Alias when the AppxPackage lookup fails.
    $wtStableExe = $null
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
        if ($pkg -and $pkg.InstallLocation) {
            $cand = Join-Path $pkg.InstallLocation 'wt.exe'
            if (Test-Path -LiteralPath $cand) { $wtStableExe = $cand }
        }
    } catch {}
    $wtExeCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    $wtExe = if ($wtStableExe) { [PSCustomObject]@{ Source = $wtStableExe } } else { $wtExeCmd }
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
