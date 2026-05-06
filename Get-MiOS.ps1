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
    $wtExe = Get-Command wt.exe -ErrorAction SilentlyContinue
    $elevated = $false
    if ($wtExe) {
        $wtArgs = @('-w','-1','nt','--title','MiOS-Bootstrap',$shell) + $shellArgs
        try {
            Start-Process wt.exe -ArgumentList $wtArgs -Verb RunAs -ErrorAction Stop
            $elevated = $true
        } catch {
            Write-Host "  [!] wt.exe (App Execution Alias) elevation failed: $($_.Exception.Message)" -ForegroundColor Yellow
            # Try the real UWP-installed wt.exe directly, bypassing the alias stub.
            $realWt = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter 'wt.exe' -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match 'Microsoft\.WindowsTerminal_' } |
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
                if ($current -ieq $MRoot) {
                    Write-Host "    [=] $p -> $MRoot (already junctioned)" -ForegroundColor DarkGray
                    continue
                }
                # Different target -- remove and re-link below.
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
        # Now create the junction.
        $rc = (cmd /c "mklink /J `"$p`" `"$MRoot`"" 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [+] junctioned $p -> $MRoot" -ForegroundColor DarkGray
        } else {
            Write-Host "    [!] mklink /J $p -> $MRoot failed: $rc" -ForegroundColor Yellow
        }
    }
}

# 4b. Full-reset every artifact MiOS has ever installed on this host.
#
# CONTRACT (per feedback_mios_entry_full_reset.md): every irm|iex run is
# a FULL RESET. No partial state, no carry-over. Reaps:
#   * Temp clones      -- %TEMP%\mios-bootstrap*
#   * Persistent clone -- %USERPROFILE%\MiOS-bootstrap (legacy, forbidden)
#   * Per-user config  -- %USERPROFILE%\.config\mios
#   * WSL distros      -- MiOS, MiOS-DEV, MiOS-BUILDER, podman-MiOS-DEV,
#                          podman-MiOS-BUILDER, podman-machine-default
#   * Podman machines  -- same name set (lots of overlap with WSL above)
#   * Hyper-V VMs      -- everything matching MiOS-*
#   * Install dirs     -- M:\MiOS, C:\MiOS, %PROGRAMDATA%\MiOS,
#                          %LOCALAPPDATA%\MiOS
#   * Start Menu       -- "MiOS\" folder under per-machine + per-user
#   * Registry         -- HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion
#                          \Uninstall\MiOS
# Each step is wrapped so a missing artifact (the common case after a
# fresh OS install) doesn't fail the run. Errors degrade to a Write-Info
# log so the operator can see what didn't reap, but the bootstrap
# continues regardless -- the new run is fresh-cloned anyway, so any
# leftover that survives reset just gets re-overwritten.
Write-Info "Full-reset of prior MiOS state (per Day-0 entry contract) ..."

$resetDirs = @(
    (Join-Path $env:USERPROFILE 'MiOS-bootstrap'),
    (Join-Path $env:USERPROFILE '.config\mios'),
    'M:\MiOS',
    'C:\MiOS',
    (Join-Path $env:PROGRAMDATA 'MiOS'),
    (Join-Path $env:LOCALAPPDATA 'MiOS')
)
foreach ($d in $resetDirs) {
    if ($d -and (Test-Path $d)) {
        try {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
            Write-Host "    [-] removed $d" -ForegroundColor DarkGray
        } catch {
            Write-Host "    [!] couldn't remove $d (locked or in use): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Sweep all mios-bootstrap-* temp dirs from prior runs (but keep the
# current $RepoDir we'll clone into).
try {
    Get-ChildItem $env:TEMP -Directory -Filter 'mios-bootstrap-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $RepoDir } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "    [-] removed $($_.FullName)" -ForegroundColor DarkGray
            } catch {}
        }
} catch {}

# WSL distros (every variant the bootstrap has ever named).
$wslNames = @('MiOS','MiOS-DEV','MiOS-BUILDER','podman-MiOS-DEV','podman-MiOS-BUILDER','podman-machine-default')
try {
    $wslList = (& wsl.exe -l -q 2>$null) -split "`r?`n" |
               ForEach-Object { ($_ -replace [char]0,'').Trim() } |
               Where-Object { $_ }
    foreach ($n in $wslNames) {
        if ($wslList -contains $n) {
            try {
                & wsl.exe --unregister $n 2>&1 | Out-Null
                Write-Host "    [-] wsl --unregister $n" -ForegroundColor DarkGray
            } catch {
                Write-Host "    [!] wsl --unregister $n failed" -ForegroundColor Yellow
            }
        }
    }
} catch {}

# Podman machines.
foreach ($n in $wslNames) {
    try {
        $rmOut = & podman machine rm --force $n 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [-] podman machine rm $n" -ForegroundColor DarkGray
        }
    } catch {}
}

# Hyper-V VMs matching MiOS-*. Hyper-V cmdlets only exist when the
# Hyper-V role / RSAT is installed; we Get-Command-gate so missing
# cmdlets don't blow up.
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    try {
        Get-VM -Name 'MiOS-*' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.State -ne 'Off') { Stop-VM -Name $_.Name -TurnOff -Force -ErrorAction SilentlyContinue }
                Remove-VM -Name $_.Name -Force -ErrorAction Stop
                Write-Host "    [-] Hyper-V Remove-VM $($_.Name)" -ForegroundColor DarkGray
            } catch {
                Write-Host "    [!] Hyper-V Remove-VM $($_.Name) failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } catch {}
}

# Start Menu folders (machine-wide and per-user).
$startFolders = @(
    (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\Start Menu\Programs\MiOS'),
    (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs\MiOS')
)
foreach ($sf in $startFolders) {
    if (Test-Path $sf) {
        try {
            Remove-Item -LiteralPath $sf -Recurse -Force -ErrorAction Stop
            Write-Host "    [-] removed Start Menu folder $sf" -ForegroundColor DarkGray
        } catch {}
    }
}

# Uninstall registry key (lets the next bootstrap re-register cleanly).
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MiOS'
if (Test-Path $uninstallKey) {
    try {
        Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction Stop
        Write-Host "    [-] removed registry $uninstallKey" -ForegroundColor DarkGray
    } catch {}
}

Write-Good "Full-reset complete; starting fresh bootstrap."

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

Write-Info "Cloning $RepoUrl ($Branch, depth=1) -> $RepoDir ..."
# Bulletproof native-command invocation, take 4:
#
#   * 245d88e tried `*>$null` (PowerShell pipeline redirect): defeated
#     by stream-merged ErrorRecord synthesis happening BEFORE redirect.
#   * a6569e8 tried `& { EAP=Continue; ... } 2>&1 | Out-Null`: somehow
#     EAP=Stop in the parent scope still escapes up through the irm|
#     iex relaunch-wrapper boundary in this specific context.
#   * 1643b64 tried `Start-Process -RedirectStandardError NUL
#     -RedirectStandardOutput NUL`: PowerShell's Start-Process has a
#     hard-coded equality check that refuses identical redirect targets,
#     so this throws "RedirectStandardOutput and RedirectStandardError
#     are same".
#
# Final approach: drop down to System.Diagnostics.Process directly.
# That class has no such silly equality check, and we explicitly
# .ReadToEnd() each stream into local strings (then discard them) so
# both streams are drained without involving PowerShell's pipeline
# ErrorRecord synthesis at all. RedirectStandard* = $true requires
# UseShellExecute = $false, which lets us run from the existing console
# without spawning a new window.
$cloneExit = -1
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'git'
    foreach ($a in @('clone','--branch',$Branch,'--depth','1',$RepoUrl,$RepoDir)) {
        # ArgumentList is the safe Add-individual-argument API on
        # .NET 5+; on Windows PowerShell 5.1 (.NET Framework 4.x) we
        # fall back to the legacy single-string Arguments and quote
        # paths that may contain spaces.
        if ($psi.ArgumentList -ne $null) { [void]$psi.ArgumentList.Add($a) }
    }
    if ($psi.ArgumentList -eq $null -or $psi.ArgumentList.Count -eq 0) {
        # PS 5.1 / .NET Framework path -- no ArgumentList, build a
        # quoted single-string Arguments value.
        $psi.Arguments = ('clone --branch {0} --depth 1 {1} "{2}"' -f $Branch, $RepoUrl, $RepoDir)
    }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    [void]$proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $cloneExit = $proc.ExitCode
} catch {
    # If Process.Start itself threw (rare -- usually means git not on
    # PATH, which Require-Cmd above already gated against), fall through
    # to the exit-code check below with the sentinel -1.
    Write-Err "git clone via System.Diagnostics.Process threw: $_"
}
if ($cloneExit -ne 0) {
    Write-Err "git clone $RepoUrl -> $RepoDir failed (exit $cloneExit)."
    Write-Err "Re-run manually to see git's diagnostic output:"
    Write-Err "  git clone --branch $Branch --depth 1 $RepoUrl `"$RepoDir`""
    exit 1
}
Write-Good "Fresh bootstrap clone at $RepoDir"

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
