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
      4. Clones / updates the mios-bootstrap repo into
         $env:USERPROFILE\MiOS-bootstrap.
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
    Local clone target (default: $USERPROFILE\MiOS-bootstrap).

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
    [string]$RepoDir   = (Join-Path $env:USERPROFILE "MiOS-bootstrap"),
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
* Attribution to every upstream project is recorded in CREDITS.md

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
try {
    `$src = Invoke-RestMethod -Uri '$rawUrl' -ErrorAction Stop
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

    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $startArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-EncodedCommand', $encoded
    )
    Start-Process $shell -ArgumentList $startArgs -Verb RunAs
    Write-Host "  [+] New pwsh window opened. Continuing the bootstrap there." -ForegroundColor Green
    return
}

# 2. Resize host window. Larger here (110x42) than the 100x40 default
# inside build-mios.ps1 because the new pwsh window starts at the
# system default (often 80x25), so we need an explicit set.
try {
    $sz  = New-Object Management.Automation.Host.Size 110, 42
    $buf = New-Object Management.Automation.Host.Size 110, 3000
    $Host.UI.RawUI.BufferSize = $buf
    $Host.UI.RawUI.WindowSize = $sz
} catch {
    try { $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size 110, 42 } catch {}
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

# 5. Clone or refresh the mios-bootstrap repo. We do NOT use Start-Transcript
# here -- build-mios.ps1's unified log captures everything, and a transcript
# wraps stdout in a way that breaks the dashboard's in-place repaint.
if (Test-Path (Join-Path $RepoDir ".git")) {
    Write-Info "Updating existing repo at $RepoDir ..."
    Push-Location $RepoDir
    try {
        & git fetch origin 2>&1 | Out-Null
        & git checkout $Branch 2>&1 | Out-Null
        & git pull --ff-only origin $Branch 2>&1 | Out-Null
    } finally { Pop-Location }
} else {
    Write-Info "Cloning $RepoUrl -> $RepoDir ..."
    & git clone --branch $Branch --depth 1 $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git clone failed"
        exit 1
    }
}
Write-Good "Bootstrap repo ready at $RepoDir"

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
