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

# 5. Clone or refresh the mios-bootstrap repo. We do NOT use Start-Transcript
# here -- build-mios.ps1's unified log captures everything, and a transcript
# wraps stdout in a way that breaks the dashboard's in-place repaint.
if (Test-Path (Join-Path $RepoDir ".git")) {
    Write-Info "Updating existing repo at $RepoDir ..."
    Push-Location $RepoDir
    try {
        # PowerShell's $ErrorActionPreference='Stop' (set at script top)
        # combined with `2>&1` stream merging is the actual trap here:
        # git writes its NORMAL pull progress to stderr ("From https://...",
        # "Receiving objects: ..."), and `2>&1` materializes those lines
        # as ErrorRecords on the pipeline. With EAP=Stop, the FIRST
        # ErrorRecord throws immediately, before any `if ($LASTEXITCODE
        # -ne 0)` check can run. Net result: the per-boot failure surfaces
        # as a single mystery line ("From https://github.com/...") instead
        # of the actual cause (uncommitted changes, divergent history).
        #
        # PowerShell 7.4+'s $PSNativeCommandUseErrorActionPreference adds
        # a SECOND auto-promotion path (non-zero exit -> throw); we
        # neutralize that too as belt-and-braces.
        #
        # We invoke each git command inside `& {}` with EAP=Continue and
        # PSNCUEAP=$false locally, so stream-merged stderr is collected
        # quietly into a string without throwing, then we check
        # $LASTEXITCODE ourselves and raise our own actionable error.
        $invoke_git = {
            param([string[]]$ArgList)
            $ErrorActionPreference = 'Continue'
            if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                $PSNativeCommandUseErrorActionPreference = $false
            }
            $combined = & git @ArgList 2>&1 | ForEach-Object { $_.ToString() }
            [pscustomobject]@{
                Output   = ($combined -join "`n")
                ExitCode = $LASTEXITCODE
            }
        }

        $r = & $invoke_git @('fetch', 'origin')
        if ($r.ExitCode -ne 0) {
            throw ("git fetch origin failed (exit $($r.ExitCode)) in '$RepoDir':`n" +
                   $r.Output +
                   "`nHint: check network connectivity, then run 'git -C $RepoDir fetch origin' manually.")
        }
        $r = & $invoke_git @('checkout', $Branch)
        if ($r.ExitCode -ne 0) {
            throw ("git checkout $Branch failed (exit $($r.ExitCode)) in '$RepoDir':`n" +
                   $r.Output +
                   "`nHint: there are likely uncommitted changes in '$RepoDir'. Either:" +
                   "`n  - commit / 'git stash' your edits and retry, OR" +
                   "`n  - delete the directory entirely (it's a thin redirector; safe to re-clone)")
        }
        $r = & $invoke_git @('pull', '--ff-only', 'origin', $Branch)
        if ($r.ExitCode -ne 0) {
            throw ("git pull --ff-only origin $Branch failed (exit $($r.ExitCode)) in '$RepoDir':`n" +
                   $r.Output +
                   "`nHint: '$RepoDir' has diverged from origin/$Branch (local commits ahead, or non-ff upstream rebase). Either:" +
                   "`n  - 'git -C $RepoDir reset --hard origin/$Branch' to discard local commits, OR" +
                   "`n  - re-run with -RepoDir <fresh-path> to clone into a clean directory")
        }
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
