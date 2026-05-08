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

# ── Self-cache-bust on entry ────────────────────────────────────────────────
# raw.githubusercontent.com is fronted by Fastly with `Cache-Control: max-age=300`,
# so the canonical Run-dialog paste:
#   powershell -ExecutionPolicy Bypass -Command "irm https://...Get-MiOS.ps1 | iex"
# returns the 5-min-old cached copy after a push. Operators who test in tight
# iteration cycles end up running stale code without realizing it.
#
# Fix: every cached copy of this script self-relaunches with a `?cb=<unix-time>`
# query string on first entry. Fastly treats unique URLs as distinct cache
# keys, so the busted URL always pulls origin-fresh. The `MIOS_CACHE_BUSTED`
# sentinel breaks the loop on the second pass (the freshly-fetched copy
# doesn't re-relaunch). Once this prefix is deployed, ALL future pushes
# land fresh on the next canonical-one-liner paste -- the only run that
# pays the stale-cache cost is the very first one after this prefix is
# itself deployed (the cached version pre-dates the prefix).
# ── Resize + center the OUTER WinR pwsh window before anything paints ──────
# At irm|iex entry the operator's WinR-spawned pwsh defaults to 120x30
# (or whatever their conhost default is). Resize to 80x40 (the
# [terminal.install] default) and center on the cursor's active monitor
# so the readme/acknowledgements + cache-bust banner are centered and
# fit without wrap.
#
# RESIZE ORDER MATTERS: SetWindowSize requires buffer >= window. If
# current buffer < target cols, SetWindowSize fails. If current window
# > target cols, SetBufferSize fails. Branch on current width.
try {
    $_curW = [Console]::WindowWidth
    if ($_curW -gt 80) {
        # Shrink window first, then buffer.
        [Console]::SetWindowSize(80, 40)
        [Console]::SetBufferSize(80, 9000)
    } else {
        # Enlarge buffer first, then window.
        [Console]::SetBufferSize(80, 9000)
        [Console]::SetWindowSize(80, 40)
    }
} catch {}
# Center on cursor's active monitor via Win32 MoveWindow. Wrap each
# Add-Type separately so a "type already defined" exception on a
# re-entry doesn't skip the MoveWindow call.
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch {}
if (-not ('MiOSWinR.N' -as [type])) {
    try {
        Add-Type -Namespace MiOSWinR -Name N -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    } catch {}
}
try { [MiOSWinR.N]::SetProcessDPIAware() | Out-Null } catch {}
try {
    # Geist Mono 12pt @ 100% DPI: cell 10x20 px, chrome 20x12 px.
    # 80x40 cells -> 820 x 812 px outer rect.
    $_winWPx = 820
    $_winHPx = 812
    $_cur    = [System.Windows.Forms.Cursor]::Position
    $_work   = [System.Windows.Forms.Screen]::FromPoint($_cur).WorkingArea
    $_x      = $_work.X + [int](([math]::Max(0, $_work.Width  - $_winWPx)) / 2)
    $_y      = $_work.Y + [int](([math]::Max(0, $_work.Height - $_winHPx)) / 2)
    $_hwnd   = [MiOSWinR.N]::GetConsoleWindow()
    if ($_hwnd -ne [IntPtr]::Zero) {
        [MiOSWinR.N]::MoveWindow($_hwnd, $_x, $_y, $_winWPx, $_winHPx, $true) | Out-Null
    }
} catch {}

# ── Cleanup of stale legacy profile body BEFORE anything else ────────────────
# Earlier failed runs may have left a corrupted, mojibake'd profile.ps1 at
# the legacy fallback path %USERPROFILE%\MiOS-bootstrap\powershell\. The
# OUTER WinR pwsh dot-sources $PROFILE.CurrentUserAllHosts (the redirector)
# at startup, BEFORE our script runs -- if the redirector's target file
# has bad UTF-8 bytes, the parse error fires every time the operator pastes
# the irm|iex one-liner. We can't suppress that startup load (it happened
# before we got control), but we CAN delete the bad file here so it doesn't
# fire AGAIN on subsequent runs. The canonical profile location is M:\MiOS\
# powershell\profile.ps1 (written by Pass-1 with UTF-8 BOM); the
# %USERPROFILE%\MiOS-bootstrap\ tree is purely a stale fallback artifact.
try {
    $_legacyProfile = Join-Path $env:USERPROFILE 'MiOS-bootstrap'
    if (Test-Path -LiteralPath $_legacyProfile) {
        Remove-Item -LiteralPath $_legacyProfile -Recurse -Force -ErrorAction SilentlyContinue
        # Also rewrite the redirector to point at the M:\ canonical
        # location so the NEXT pwsh launch loads a clean profile (or
        # no-ops via the redirector's `if (Test-Path)` guard if Pass-1
        # hasn't yet staged the M:\ copy on this run).
        $_profilePath = $PROFILE.CurrentUserAllHosts
        if (-not $_profilePath) { $_profilePath = $PROFILE }
        if ($_profilePath -and (Test-Path -LiteralPath $_profilePath)) {
            try {
                $_existing = Get-Content -LiteralPath $_profilePath -Raw -ErrorAction SilentlyContinue
                $_marker  = '# >>> MiOS oh-my-posh init >>>'
                $_endMark = '# <<< MiOS oh-my-posh init <<<'
                if ($_existing -match [regex]::Escape($_marker)) {
                    $_pattern = "(?s)$([regex]::Escape($_marker)).*?$([regex]::Escape($_endMark))"
                    $_cleaned = [regex]::Replace($_existing, $_pattern, '').TrimEnd()
                    Set-Content -LiteralPath $_profilePath -Value $_cleaned -Encoding UTF8 -NoNewline
                }
            } catch {}
        }
    }
} catch {}

if (-not $env:MIOS_CACHE_BUSTED -and -not $env:MIOS_GETMIOS_RELAUNCHED) {
    $env:MIOS_CACHE_BUSTED = '1'
    try {
        $cb = [int][double]::Parse((Get-Date -UFormat %s))
        $bustedUrl = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1?cb=$cb"
        $noCacheHdr = @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' }
        $freshSrc = Invoke-RestMethod -Uri $bustedUrl -Headers $noCacheHdr -ErrorAction Stop
        if ($freshSrc -and $freshSrc.Length -gt 1000) {
            # Got a real script back -- relaunch with the fresh copy.
            & ([scriptblock]::Create($freshSrc))
            return
        }
        # Empty / suspiciously small response -- fall through to the
        # cached copy we already have running.
    } catch {
        # Network blip / DNS / Fastly outage -- fall through to the
        # cached copy. Better to run something stale than nothing at all.
    }
}

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

# ── mios.toml layered-overlay reader ─────────────────────────────────────────
# mios.toml is THE global dotfile (per feedback_mios_toml_html_global_dotfile
# memory). EVERY tunable -- window dims, M:\ size, font, AumID, retry
# delays, theming, package lists -- sources from here. The HTML
# configurator edits mios.toml; every consumer reads from it.
#
# Resolution order (highest → lowest):
#   1. ~/.config/mios/mios.toml        (per-user override)
#   2. M:\etc\mios\mios.toml           (host override; configurator-saved)
#   3. M:\usr\share\mios\mios.toml     (vendor copy on M:\)
#   4. C:\MiOS\usr\share\mios\mios.toml (vendor copy in C:\MiOS, dev path)
#   5. origin/main raw GitHub          (cold first-run, no M:\ yet)
#
# Vendor defaults are sufficient (per feedback_mios_defaults_baseline): the
# stack works with no user toml present. Get-MiosTomlValue returns its
# `-Default` arg if the key is missing anywhere.
$script:_MiosTomlCache = @{}

function Resolve-MiosTomlText {
    if ($script:_MiosTomlCache.ContainsKey('_text') -and $script:_MiosTomlCache['_text']) {
        return $script:_MiosTomlCache['_text']
    }
    $candidates = @(
        (Join-Path $env:USERPROFILE '.config\mios\mios.toml'),
        'M:\etc\mios\mios.toml',
        'M:\usr\share\mios\mios.toml',
        'C:\MiOS\usr\share\mios\mios.toml'
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                $script:_MiosTomlCache['_text']   = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
                $script:_MiosTomlCache['_source'] = $p
                return $script:_MiosTomlCache['_text']
            } catch {}
        }
    }
    # Cold first-run: pull origin.
    try {
        $cb  = [int][double]::Parse((Get-Date -UFormat %s))
        $url = "https://raw.githubusercontent.com/mios-dev/MiOS/main/usr/share/mios/mios.toml?cb=$cb"
        $script:_MiosTomlCache['_text']   = Invoke-RestMethod -Uri $url `
            -Headers @{ 'Cache-Control'='no-cache, no-store, max-age=0'; 'Pragma'='no-cache' } `
            -ErrorAction Stop
        $script:_MiosTomlCache['_source'] = "origin/main (cold)"
        return $script:_MiosTomlCache['_text']
    } catch {
        $script:_MiosTomlCache['_text']   = ''
        $script:_MiosTomlCache['_source'] = '(none -- vendor defaults only)'
        return ''
    }
}

function Get-MiosTomlValue {
    param(
        [Parameter(Mandatory)] [string]$Section,   # e.g. "terminal" or "bootstrap.host_storage"
        [Parameter(Mandatory)] [string]$Key,       # e.g. "cols"
        [Parameter(Mandatory)] $Default            # returned if not found / unparseable
    )
    $txt = Resolve-MiosTomlText
    if (-not $txt) { return $Default }
    # Slice the section body: from `[Section]` (line-anchored) to the next
    # `[other.section]` header or EOF.
    $rxSec = '(?ms)^\[' + [regex]::Escape($Section) + '\][ \t]*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)'
    $mSec  = [regex]::Match($txt, $rxSec)
    if (-not $mSec.Success) { return $Default }
    $body  = $mSec.Groups['body'].Value
    # Within the body, find `key = value` (TOML allows leading whitespace).
    $rxKey = '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*(?<val>.+?)[ \t]*(?:#.*)?$'
    $mKey  = [regex]::Match($body, $rxKey)
    if (-not $mKey.Success) { return $Default }
    $raw   = $mKey.Groups['val'].Value.Trim()
    # Coerce by Default's type. Strings get unquoted; arrays get split.
    if ($Default -is [int]) {
        $n = 0
        if ([int]::TryParse(($raw -replace '_',''), [ref]$n)) { return $n }
        return $Default
    }
    if ($Default -is [bool]) {
        if ($raw -match '^(?i)true$')  { return $true }
        if ($raw -match '^(?i)false$') { return $false }
        return $Default
    }
    if ($Default -is [double] -or $Default -is [single]) {
        $d = 0.0
        if ([double]::TryParse($raw, [ref]$d)) { return $d }
        return $Default
    }
    if ($Default -is [array]) {
        if ($raw -match '^\[(.*)\]$') {
            $inner = $Matches[1]
            $items = @(
                $inner -split ',' |
                ForEach-Object {
                    $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                    if ($s) { $s }
                }
            )
            # If Default is an int[] try to coerce each item.
            if ($Default.Length -gt 0 -and $Default[0] -is [int]) {
                $coerced = @()
                foreach ($it in $items) {
                    $n = 0
                    if ([int]::TryParse($it, [ref]$n)) { $coerced += $n } else { return $Default }
                }
                # Return without unary-comma wrapper -- callers collect via
                # @(Get-MiosTomlValue ...) which collects the pipeline-
                # unrolled int sequence into a fresh array. With the
                # unary-comma wrapper, @() got @(@(0,5,15,30)) -- a 1-
                # element array containing the int array -- and
                # $delays[0] = @(0,5,15,30) blew up Start-Sleep -Seconds.
                return $coerced
            }
            return $items
        }
        return $Default
    }
    # Default to string -- strip the SURROUNDING TOML string quotes (and
    # unescape backslash sequences for double-quoted strings). The
    # previous Trim('"',"'") was too aggressive: a value like
    #     "'MiOS' v0.2.4"
    # had its leading apostrophe stripped because Trim treats the char
    # set as a multi-set on BOTH ends. Operator-reported regression:
    # the installer banner rendered as `MiOS' v0.2.4` (missing leading
    # `'`) instead of `'MiOS' v0.2.4`.
    if ($raw.Length -ge 2) {
        $first = $raw[0]; $last = $raw[$raw.Length - 1]
        if ($first -eq '"' -and $last -eq '"') {
            # Basic string: strip and unescape \\, \", \n, \t, \r.
            $inner = $raw.Substring(1, $raw.Length - 2)
            $inner = $inner -replace '\\\\', "`u{0001}BS`u{0001}"   # placeholder for literal backslash
            $inner = $inner -replace '\\"', '"'
            $inner = $inner -replace '\\n', "`n"
            $inner = $inner -replace '\\t', "`t"
            $inner = $inner -replace '\\r', "`r"
            $inner = $inner -replace "`u{0001}BS`u{0001}", '\'
            return $inner
        }
        if ($first -eq "'" -and $last -eq "'") {
            # Literal string: strip; no unescaping (TOML literal-string semantics).
            return $raw.Substring(1, $raw.Length - 2)
        }
    }
    # Bare value, no surrounding quotes -- return as-is.
    return $raw
}

function Show-MiOSBanner {
    # Framed branded ASCII banner -- shown at the top of EVERY MiOS
    # window/dashboard per operator: "EVERY WINDOW SHOULD HAVE A FRAMED
    # AND BRANDED BANNER OF THE MIOS ASCII BANNER ART -- EVERY WINDOW
    # AND/OR DASHBOARD HAS IT AT THE TOP".
    # Width = 80 cells (frame char to frame char). Inner width = 78.
    # The ASCII art block + subtitle are CENTERED within the inner
    # width as a single block (same approach as Show-MiosDashboard) --
    # not line-by-line, so the art's internal diagonal alignment is
    # preserved while the whole logo sits visually centered.
    # Box-drawing requires UTF-8 codepage (chcp 65001) -- conhost in
    # CP437/CP1252 mangles ╭╮╰╯│─ to `?`. Callers must set codepage
    # before invoking; the agreement gate + Pass-2 inner cmd both do.
    param([string]$Subtitle = '')
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
    $sub = if ($Subtitle) { $Subtitle } else { Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'Immutable Fedora AI Workstation' }
    $inner = 78
    # Block-center: pad every art line by the SAME left-pad so internal
    # diagonal alignment is preserved.
    $maxArt = ($art | Measure-Object -Property Length -Maximum).Maximum
    $blockL = ' ' * [math]::Max(0, [math]::Floor(($inner - $maxArt) / 2))
    # Subtitle centered on its own (different width than the art block).
    $subPad = [math]::Max(0, $inner - $sub.Length)
    $subL = ' ' * [math]::Floor($subPad / 2)
    $subR = ' ' * ($subPad - [math]::Floor($subPad / 2))
    $top    = '╭' + ('─' * $inner) + '╮'
    $bottom = '╰' + ('─' * $inner) + '╯'
    $rows = @($top)
    foreach ($a in $art) {
        $line = $blockL + $a
        # Right-pad to fill inner width.
        $line = $line + (' ' * [math]::Max(0, $inner - $line.Length))
        $rows += '│' + $line + '│'
    }
    $rows += '│' + $subL + $sub + $subR + '│'
    $rows += $bottom
    $rows -join "`n"
}

function Show-MiOSAgreement {
    $banner = Show-MiOSBanner -Subtitle 'Project Acknowledgement'
    @"
$banner
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
    # Note: gate IS rendered in the elevated relaunch (Pass-2). Pass-1
    # (the small black box from `irm|iex`) self-elevates and exits
    # BEFORE this function is ever invoked -- the agreement belongs in
    # the properly-sized 80x40 Pass-2 conhost. The previous behaviour
    # short-circuited Pass-2 via $env:MIOS_GETMIOS_RELAUNCHED, which
    # caused the agreement to be rendered in Pass-1's tiny inherited
    # conhost (~80x25) where the ~104-line summary scrolled past in a
    # flash and the operator only saw the bottom prompt.

    # Ensure the conhost is 80 cells wide BEFORE rendering. Use the same
    # branching SetBufferSize/SetWindowSize pattern as the WinR-entry
    # resize at the top of this script (lines 105-115): the order matters
    # because the Win32 console rule is `buffer.cols >= window.cols`.
    # DON'T call MoveWindow with hardcoded pixel dimensions: at 150-200%
    # DPI, conhost cells are ~16-25 px so a hardcoded 820 px window only
    # fits 33-50 cells visible while the buffer stays 80 wide -- conhost
    # adds a horizontal scrollbar and the operator sees what looks like a
    # 20x40 window. Letting SetWindowSize drive the Win32 window size
    # auto-pixel-sizes correctly at any DPI.
    try { & chcp.com 65001 *> $null } catch {}
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
    try {
        # Don't clamp by LargestWindowSize: at 200% DPI it can return as
        # low as 20 rows on a 1080p monitor, which produced the operator-
        # reported regression "window opens but is 1/2 the size it should
        # be". 80x40 is the documented [terminal.install] target -- if
        # conhost can't fit it visibly the worst case is silent fallback
        # to LargestWindowSize anyway, but most setups handle it fine.
        $_curW = [Console]::WindowWidth
        if ($_curW -gt 80) {
            [Console]::SetWindowSize(80, 40)
            [Console]::SetBufferSize(80, 9000)
        } else {
            [Console]::SetBufferSize(80, 9000)
            [Console]::SetWindowSize(80, 40)
        }
    } catch {}

    # Win32 helpers for re-centering on every page refresh. Operator-
    # reported regression: "window respawns slightly off-center every
    # time it refreshes the window". Conhost doesn't move the Win32
    # window on Clear-Host, but tiny size renegotiations (font cache /
    # DPI re-resolve when the active monitor changes) drift it. We
    # snapshot the active monitor once and re-center on every page.
    if (-not ('MiOSGate.W' -as [type])) {
        try {
            Add-Type -Namespace MiOSGate -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle rect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
        } catch {}
    }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch {}
    # Per-monitor v2 DPI awareness so SetWindowPos coords match Screen.
    # WorkingArea on multi-monitor + high-DPI setups.
    try { [void][MiOSGate.W]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } catch {}
    # Capture the operator's active monitor + the FROZEN target pixel
    # rect ONCE at gate entry. Reading current dims via GetWindowRect on
    # every page lets conhost's tiny per-render renegotiations drift the
    # window a few pixels each time -- the operator-reported "final
    # agreements window still ends up off-centered". Pinning to a frozen
    # target X,Y,W,H on every MoveWindow is a no-op when the window is
    # already there, and a snap-back when conhost has drifted.
    $_gateScreen   = $null
    $_gateTargetX  = $null
    $_gateTargetY  = $null
    $_gateTargetW  = $null
    $_gateTargetH  = $null
    # Resolve the topmost-ancestor HWND of the conhost: WT main window
    # when WT is the default terminal app (Windows 11 22H2+), conhost
    # itself otherwise. Stored once so every per-page _Center call
    # targets the same window. Operator-reported regression: "all
    # windows aren't recentering still!" was caused by GetConsoleWindow
    # returning the OpenConsole pseudo-host HWND (NOT WT's) -- moving
    # the pseudo-host had no visible effect because WT owns the actual
    # window.
    $_gateTargetHwnd = [IntPtr]::Zero
    try {
        # Let conhost settle after the 80x40 SetWindowSize above.
        Start-Sleep -Milliseconds 100
        if ('MiOSGate.W' -as [type]) {
            $_consoleHwnd = [MiOSGate.W]::GetConsoleWindow()
            # GA_ROOT = 2 -- topmost ancestor.
            $_gateTargetHwnd = if ($_consoleHwnd -ne [IntPtr]::Zero) {
                $_root = [MiOSGate.W]::GetAncestor($_consoleHwnd, 2)
                if ($_root -ne [IntPtr]::Zero) { $_root } else { $_consoleHwnd }
            } else { [IntPtr]::Zero }
            if ($_gateTargetHwnd -ne [IntPtr]::Zero) {
                $_gr = New-Object System.Drawing.Rectangle
                [void][MiOSGate.W]::GetWindowRect($_gateTargetHwnd, [ref]$_gr)
                $_gateTargetW = $_gr.Width  - $_gr.X
                $_gateTargetH = $_gr.Height - $_gr.Y
                # Anchor to the window's OWN monitor (where Pass-2 placed
                # it), NOT Cursor.Position. Cursor drift between mouse
                # moves was making multi-monitor recenters jump displays.
                $_gateCenter = New-Object System.Drawing.Point ($_gr.X + [int]($_gateTargetW / 2)), ($_gr.Y + [int]($_gateTargetH / 2))
                $_gateScreen = [System.Windows.Forms.Screen]::FromPoint($_gateCenter).WorkingArea
                $_gateTargetX = $_gateScreen.X + [int](([math]::Max(0, $_gateScreen.Width  - $_gateTargetW)) / 2)
                $_gateTargetY = $_gateScreen.Y + [int](([math]::Max(0, $_gateScreen.Height - $_gateTargetH)) / 2)
            }
        }
    } catch {}
    function _Center-MiOSGateConsole {
        if (-not ('MiOSGate.W' -as [type])) { return }
        if ($null -eq $_gateTargetX -or $_gateTargetHwnd -eq [IntPtr]::Zero) { return }
        try {
            # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14
            [void][MiOSGate.W]::SetWindowPos($_gateTargetHwnd, [IntPtr]::Zero, $_gateTargetX, $_gateTargetY, $_gateTargetW, $_gateTargetH, 0x14)
        } catch {}
    }

    # AUTO-PAGINATE so the banner ALWAYS stays visible at the top of
    # the window. Operator-reported regression: previous two-page split
    # had page 1 = 53 lines but the conhost only shows 40 rows, so the
    # banner auto-scrolled off the top before the prompt rendered. The
    # operator had to scroll up to see the banner -- which violated
    # "EVERY WINDOW HAS THE BANNER AT THE TOP".
    #
    # Strategy: render the banner first, then pack as many content lines
    # as fit in (window_rows - banner_rows - prompt_rows - margin) before
    # pausing. Repeat until the agreement body is exhausted, then enter
    # the Acknowledged prompt loop on the final page.
    $banner    = Show-MiOSBanner -Subtitle 'Project Acknowledgement'
    $bannerRows = ($banner -split "`n").Count
    # Strip the leading framed banner from Show-MiOSAgreement output --
    # we'll prepend our own per-page so each page starts with it.
    $body = Show-MiOSAgreement
    $bodyLines = $body -split "`r?`n"
    # Drop the banner block at the top (lines until the closing ╰...╯).
    $strip = 0
    for ($i = 0; $i -lt $bodyLines.Count; $i++) {
        if ($bodyLines[$i].StartsWith('╰')) { $strip = $i + 1; break }
    }
    $contentLines = @($bodyLines | Select-Object -Skip $strip)
    # Trim trailing empty lines so the last page doesn't waste rows.
    while ($contentLines.Count -gt 0 -and $contentLines[-1] -match '^\s*$') {
        $contentLines = $contentLines[0..($contentLines.Count - 2)]
    }

    $winRows    = try { [Console]::WindowHeight } catch { 40 }
    if ($winRows -lt 30) { $winRows = 30 }   # safety floor
    $promptRows = 3                          # blank + 2-line prompt
    $perPage    = [math]::Max(8, $winRows - $bannerRows - $promptRows)

    # Slice content into page-sized chunks, breaking at section dividers
    # when possible so a section's title doesn't get orphaned at the
    # bottom of one page with its body on the next.
    $pages = @()
    $start = 0
    while ($start -lt $contentLines.Count) {
        $end = [math]::Min($start + $perPage - 1, $contentLines.Count - 1)
        # If we're not at the end of the content, prefer a divider line
        # (^-{8,}$) as the cut point so a section header isn't orphaned.
        if ($end -lt ($contentLines.Count - 1)) {
            for ($k = $end; $k -ge $start + [math]::Max(8, $perPage - 12); $k--) {
                if ($contentLines[$k] -match '^-{8,}$') {
                    # Cut just BEFORE the divider so the next page starts
                    # with the divider+title+divider block intact.
                    $end = $k - 1
                    break
                }
            }
        }
        $pages += ,($contentLines[$start..$end])
        $start = $end + 1
    }

    for ($p = 0; $p -lt $pages.Count; $p++) {
        $isLast = ($p -eq $pages.Count - 1)
        $pageNum = $p + 1
        $subt = "Project Acknowledgement (page $pageNum of $($pages.Count))"
        Clear-Host
        # Re-center the conhost window on the OPERATOR'S active monitor
        # captured at gate entry. Without this, conhost drifts a few
        # pixels per Clear-Host (font cache / DPI renegotiation).
        _Center-MiOSGateConsole
        Write-Host (Show-MiOSBanner -Subtitle $subt)
        Write-Host (($pages[$p]) -join "`n")
        Write-Host ''
        if (-not $isLast) {
            Read-Host "[mios] Press Enter for page $($pageNum + 1) of $($pages.Count)" | Out-Null
        }
    }

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
# 1. ALWAYS spawn a fresh elevated pwsh window. The original `irm | iex`
# host inherits whatever terminal called us (VS Code integrated, remote
# session, embedded host, etc.) which often (a) isn't admin, (b) is the
# wrong size for the build, and (c) breaks console cursor positioning.
# A fresh top-level pwsh window guarantees a clean, properly-sized
# environment regardless of where the curl was run from.
#
# ── Auto-elevate at script entry (single UAC) ───────────────────────
# Per operator: "irm|iex mios.bat Win + R entry should it itself auto
# elevate!!! it needs admin rights to install some components without
# several UAC prompts interrupting the install".
#
# Previously this script split work into Pass-1 (user) + Pass-2 (admin
# via mid-install UAC). That meant operator saw the UAC prompt halfway
# through; some Pass-2 steps (M:\ partition shrink, Podman Desktop
# winget install, podman machine init) need elevation, so the prompt
# was unavoidable -- but firing it at the start instead means ONE
# UAC interaction up-front and the entire install runs in the same
# elevated session.
#
# Sentinel: $env:MIOS_GETMIOS_RELAUNCHED prevents the elevated relaunch
# from re-elevating in an infinite loop.
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin -and -not $env:MIOS_GETMIOS_RELAUNCHED) {
    Write-Host ''
    Write-Host '  [*] MiOS bootstrap requires admin (M:\ partition + Podman + dev VM).' -ForegroundColor Cyan
    Write-Host '  [*] Triggering UAC -- accept to continue. The install will then run' -ForegroundColor Cyan
    Write-Host '      in the elevated window, single prompt only.' -ForegroundColor DarkGray
    # Capture cursor position BEFORE the UAC prompt, while the operator's
    # attention is still on whichever monitor they pasted from. By the
    # time the inner script runs (after UAC accept), Cursor.Position is
    # at the UAC "Yes" button location -- typically the primary monitor,
    # NOT necessarily where the operator was working. Embed the captured
    # X,Y as constants in the inner cmd so Screen.FromPoint() resolves
    # to the active-display before-elevation, not after.
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $_cursorPre = try { [System.Windows.Forms.Cursor]::Position } catch { New-Object System.Drawing.Point 100,100 }
    $_curX = $_cursorPre.X
    $_curY = $_cursorPre.Y
    # Bootstrap window dims (the elevated conhost that runs Pass-1 +
    # Pass-2 + readme/acknowledgements). Pulled from mios.toml
    # [terminal.install] -- vendor default 80x40 for log/output room.
    # The post-install MiOS APP spawn uses [terminal] (80x20, portal
    # feel) because the operator-facing terminal is shorter than the
    # install-time log window.
    # Compute target pixel dims HERE so they bake as literal integers
    # into the rendered inner cmd -- the spawned pwsh has no access
    # to outer-scope variables.
    $_elevCols = Get-MiosTomlValue -Section 'terminal.install' -Key 'cols'            -Default 80
    $_elevRows = Get-MiosTomlValue -Section 'terminal.install' -Key 'rows'            -Default 40
    $_elevScr  = Get-MiosTomlValue -Section 'terminal'         -Key 'scrollback_rows' -Default 9000
    $_cellW    = Get-MiosTomlValue -Section 'theme.font'       -Key 'cell_w_px'       -Default 10
    $_cellH    = Get-MiosTomlValue -Section 'theme.font'       -Key 'cell_h_px'       -Default 20
    $_chromeW  = Get-MiosTomlValue -Section 'theme.font'       -Key 'chrome_w_px'     -Default 20
    $_chromeH  = Get-MiosTomlValue -Section 'theme.font'       -Key 'chrome_h_px'     -Default 12
    # Pixel target for the BOOTSTRAP window (80x40 cells).
    $_winWPx   = ($_elevCols * $_cellW) + $_chromeW
    $_winHPx   = ($_elevRows * $_cellH) + $_chromeH
    # Separate dims for the post-install MiOS APP spawn (80x20 -- the
    # canonical operator-facing terminal). These bake into the inner
    # cmd alongside $_elevCols/$_elevRows but drive the wt.exe -p MiOS
    # spawn at end-of-bootstrap, NOT the bootstrap conhost itself.
    $_appCols  = Get-MiosTomlValue -Section 'terminal'         -Key 'cols'            -Default 80
    $_appRows  = Get-MiosTomlValue -Section 'terminal'         -Key 'rows'            -Default 20
    $_appWPx   = ($_appCols * $_cellW) + $_chromeW
    $_appHPx   = ($_appRows * $_cellH) + $_chromeH
    $_rawUrl = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1?cb=$([int][double]::Parse((Get-Date -UFormat %s)))"
    $_innerCmd = @"
`$env:MIOS_GETMIOS_RELAUNCHED='1'
`$env:MIOS_CACHE_BUSTED='1'
# AGREEMENT_ACK is intentionally NOT pre-set. Pass-2 (this elevated
# relaunch) is where the operator reads + acks the agreement, in the
# properly-sized 80x40 conhost. Pre-accepting via env would skip the
# gate -- which would defeat the point of moving the gate here.
# Tell the MiOS pwsh profile body to render the framed dashboard +
# oh-my-posh prompt for THIS bootstrap window. The profile gates the
# dashboard call on `$env:WT_SESSION OR `$env:TERM_PROGRAM='mios';
# elevated pwsh in conhost has neither, so without this the install
# runs in a vanilla black box. Setting it here makes the elevated
# bootstrap window itself the MiOS terminal experience.
`$env:TERM_PROGRAM='mios'
# Force UTF-8 codepage + output encoding BEFORE any output paints.
# Without this, conhost defaults to CP437/CP1252 and the dashboard's
# Unicode box-drawing glyphs (╭ ╮ ╰ ╯ │ ─ ├ ┤) render as `?`. Setting
# OutputEncoding alone isn't enough -- chcp 65001 changes the active
# codepage for the underlying console, which is what affects glyph
# substitution.
try { & chcp.com 65001 *> `$null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}
# Pre-UAC cursor location (captured by the launching pwsh BEFORE Start-
# Process -Verb RunAs); use these constants instead of querying
# Cursor.Position now (which would read at the UAC Yes-button click
# location, defeating the active-display intent).
`$_curXPre = $_curX
`$_curYPre = $_curY
try {
    Add-Type -Namespace MEW -Name N -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle rect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    # DPI per-monitor v2 so Screen.WorkingArea + SetWindowPos agree on
    # the coordinate space (was off-by-DPI on multi-monitor setups
    # where the operator-reported regression "all windows aren't
    # recentering still" surfaced -- MoveWindow placed the window at
    # logical-px coords interpreted as physical-px, missing the target
    # monitor entirely on high-DPI secondary displays).
    try { [void][MEW.N]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } catch {}
    # Pixel target size -- BAKED from outer scope as literal integers
    # via @"..."@ interpolation (no backticks on $_winWPx / $_winHPx /
    # $_elevCols / $_elevRows / $_elevScr). The inner pwsh process
    # cannot see outer-scope variables (it's a fresh pwsh.exe spawn);
    # everything we want it to know must be substituted at template-
    # build time. Earlier broken edits used backticks on $_elevCols
    # which produced LITERAL `\$_elevCols` in the rendered script,
    # which evaluated to $null inner-side, multiplied by cell dims
    # to zero, and gave a 20x12 (basically 1x1 visible) window.
    # Branch on current width: SetBufferSize fails when shrinking buffer
    # below current window; SetWindowSize fails when growing window
    # beyond current buffer. Conhost rule: buffer.cols >= window.cols.
    `$_curW = [Console]::WindowWidth
    if (`$_curW -gt $_elevCols) {
        try { [Console]::SetWindowSize($_elevCols, $_elevRows) } catch {}
        try { [Console]::SetBufferSize($_elevCols, $_elevScr) } catch {}
    } else {
        try { [Console]::SetBufferSize($_elevCols, $_elevScr) } catch {}
        try { [Console]::SetWindowSize($_elevCols, $_elevRows) } catch {}
    }
    # SetWindowSize tells conhost to display N cells; conhost itself
    # auto-pixel-sizes the Win32 window correctly for the active DPI.
    # DON'T MoveWindow with hardcoded pixel dims (the previous behaviour
    # of `MoveWindow ... 820x812`) -- at 150% DPI conhost cells render
    # ~16 px wide so a 820 px window only fits ~50 cells, and at 200%
    # DPI ~33 cells. Operator-reported regression at 200% DPI:
    # "window opens but is 1/2 the size it should be". Reading the
    # ACTUAL post-resize Win32 window dims via GetWindowRect and using
    # those for centering keeps the window correctly cell-sized while
    # still putting it on the operator's active display.
    # Retry loop: window may not be fully realized + sized yet at first
    # call; SetWindowPos before that is a silent no-op. Try up to 8x
    # over ~2 seconds. Log every step to %TEMP%\mios-center-debug.log
    # so operator can paste back what's happening when "windows aren't
    # centering" recurs.
    `$_dbg = Join-Path `$env:TEMP 'mios-center-debug.log'
    `$_dbgLines = New-Object System.Collections.Generic.List[string]
    `$_dbgLines.Add("[`$([DateTime]::Now.ToString('HH:mm:ss.fff'))] Pass-2 inner cmd center start")
    for (`$_attempt = 0; `$_attempt -lt 8; `$_attempt++) {
        Start-Sleep -Milliseconds 250
        `$_consoleHwnd = [MEW.N]::GetConsoleWindow()
        `$_h = if (`$_consoleHwnd -ne [IntPtr]::Zero) {
            `$_root = [MEW.N]::GetAncestor(`$_consoleHwnd, 2)
            if (`$_root -ne [IntPtr]::Zero) { `$_root } else { `$_consoleHwnd }
        } else { [IntPtr]::Zero }
        if (`$_h -eq [IntPtr]::Zero) { `$_dbgLines.Add(('attempt {0}: no hwnd' -f `$_attempt)); continue }
        `$_rect = New-Object System.Drawing.Rectangle
        `$_grcOk = [MEW.N]::GetWindowRect(`$_h, [ref]`$_rect)
        `$_actualW = `$_rect.Width  - `$_rect.X
        `$_actualH = `$_rect.Height - `$_rect.Y
        if (`$_actualW -le 0 -or `$_actualH -le 0) { `$_dbgLines.Add(('attempt {0}: zero dims grc={1}' -f `$_attempt, `$_grcOk)); continue }
        `$_pt = New-Object System.Drawing.Point `$_curXPre, `$_curYPre
        `$_s  = [System.Windows.Forms.Screen]::FromPoint(`$_pt).WorkingArea
        `$_x = `$_s.X + [int](([math]::Max(0, `$_s.Width  - `$_actualW)) / 2)
        `$_y = `$_s.Y + [int](([math]::Max(0, `$_s.Height - `$_actualH)) / 2)
        # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14
        `$_swp = [MEW.N]::SetWindowPos(`$_h, [IntPtr]::Zero, `$_x, `$_y, `$_actualW, `$_actualH, 0x14)
        `$_dbgLines.Add(('attempt {0}: hwnd=0x{1:X} console=0x{2:X} rect={3},{4} dims={5}x{6} screen={7},{8} {9}x{10} target={11},{12} SWPok={13}' -f `$_attempt, ([int64]`$_h), ([int64]`$_consoleHwnd), `$_rect.X, `$_rect.Y, `$_actualW, `$_actualH, `$_s.X, `$_s.Y, `$_s.Width, `$_s.Height, `$_x, `$_y, `$_swp))
        # Don't break on success. Operator-reported regression: "spawned
        # install window still isn't centered/self centering STILL".
        # Logs showed centering succeeded on attempt 0 but the window
        # subsequently moved -- conhost/WT re-layouts after every output
        # paint + SetWindowSize call can shift the window. Keep re-
        # centering through all 12 ticks (~6 seconds) so the window
        # stays put through the inner-cmd's banner Write-Host calls,
        # the IRM fetch, and the child pwsh spawn.
    }
    try { Set-Content -LiteralPath `$_dbg -Value (`$_dbgLines -join [Environment]::NewLine) -Encoding UTF8 } catch {}
} catch {
    try { Add-Content -LiteralPath (Join-Path `$env:TEMP 'mios-center-debug.log') -Value "Pass-2 inner cmd center FAILED: `$(`$_.Exception.Message)" } catch {}
}
Write-Host ''
Write-Host '  [*] MiOS Bootstrap (elevated)' -ForegroundColor Cyan
# Build the cache-busted URL HERE inside the inner cmd, NOT via outer-
# scope interpolation. Operator-reported regression: when the inner cmd
# was rendered with `-Uri '$_rawUrl'` and `$_rawUrl` interpolated to empty
# for any reason (encoding issue / heredoc quirk / nested-template bug),
# the rendered file became `Invoke-RestMethod -Uri '' -Headers ...` which
# sent PowerShell into its mandatory-parameter prompt loop:
#     cmdlet Invoke-RestMethod at command pipeline position 1
#     Supply values for the following parameters:
#     Uri:
# Computing the URL inside the inner cmd removes the outer-scope dep
# entirely and makes the rendered file self-sufficient.
`$_cb     = [int][double]::Parse((Get-Date -UFormat %s))
`$_rawUri = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1?cb=' + `$_cb
Write-Host ('      Cache-busted Get-MiOS.ps1 fetch: ' + `$_rawUri) -ForegroundColor DarkGray
Write-Host ''
try {
    `$src = Invoke-RestMethod -Uri `$_rawUri -Headers @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' } -ErrorAction Stop
    # Write to a temp .ps1 and run as a CHILD pwsh process so any
    # 'exit N' calls inside Get-MiOS.ps1 terminate the child, NOT our
    # hosting elevation window. Without this, any preflight 'exit 1'
    # killed the elevated host before the operator could read the
    # error or pause for inspection -- the window appeared to "die
    # silently". Per operator: "the incorrectly launched powershell
    # window... just dies silently--seemingly no logs in sight!!!"
    # Log path: M:\MiOS\logs if M:\ exists (the canonical install-on-M
    # location), else %TEMP%. The child pwsh runs Start-Transcript
    # internally so the log gets every Write-Host without the parent
    # having to pipe through Tee-Object (which DESTROYS the child's
    # `$Host.UI.RawUI` console handle and makes `$RawUI.CursorPosition
    # = @{X=0;Y=0}` throw "The handle is invalid" -- exactly the crash
    # the operator hit in commit 1e3484f).
    # NO PRELUDE PREPEND. Get-MiOS.ps1 has a `param()` block at the
    # top of the file -- PowerShell requires param() to be the FIRST
    # statement in a script (after comments / using statements). My
    # prior commits prepended chcp/Start-Transcript lines which
    # pushed param() to line 6+, causing PowerShell to parse the
    # block's arguments as standalone assignments:
    #     "[string]\$RepoUrl = 'https://github.com/mios-dev/...'"
    #     -> "The assignment expression is not valid"
    # The codepage + Console encoding are ALREADY set in the inner
    # cmd (chcp 65001 etc. above); the child pwsh inherits the
    # conhost codepage from this elevated parent, so Unicode glyphs
    # render correctly without an inline prelude.
    # Logging during Pass-1 is sacrificed for now -- build-mios.ps1's
    # own logging at M:\MiOS\logs\mios-install-*.log covers Pass-2+
    # which is where 90% of the install time lives. Operator sees
    # all Pass-1 output live in the elevated host (Read-Host pause
    # at the end keeps it visible).
    `$tmpScript = Join-Path `$env:TEMP ('mios-getmios-' + [guid]::NewGuid().Guid.Substring(0,8) + '.ps1')
    # UTF-8 WITH BOM so PS 5.1 (the fresh-system fallback) parses it
    # as UTF-8 instead of Windows-1252. Without the BOM, PS 5.1's
    # parser reads the file as cp1252 and mangles every Unicode glyph
    # in the source (the U+2502 vertical-bar box-drawing char becomes
    # 3-byte mojibake under cp1252), throwing Unexpected-token errors
    # before the script body runs. pwsh 7 reads no-BOM UTF-8 fine, but
    # the bootstrap's child shell is whatever's available on a fresh
    # box -- PS 5.1 until Phase 5 winget-installs Microsoft.PowerShell.
    [IO.File]::WriteAllText(`$tmpScript, `$src, [System.Text.UTF8Encoding]::new(`$true))
    # -NoProfile prevents the elevated child pwsh from auto-loading
    # any stale `$PROFILE.CurrentUserAllHosts redirector that points
    # at a corrupted profile body from a prior failed run. Pass-1
    # below will overwrite the profile with a properly-BOMed UTF-8
    # version regardless.
    #
    # FRESH-SYSTEM FALLBACK: pwsh.exe (PowerShell 7) is part of
    # [packages.windows] which the operator hasn't installed yet on a
    # cold first run. Operator-reported regression: "this was a run on
    # a fresh system with no pre-requisites and fails immediately ...
    # The term 'pwsh.exe' is not recognized". Resolve the child shell
    # in priority order: pwsh 7 (preferred) -> Microsoft Store pwsh ->
    # Windows PS 5.1 (always present). PS 5.1 runs the bootstrap fine;
    # build-mios.ps1's Install-MiosWindowsTools will winget-install
    # Microsoft.PowerShell during Phase 5 so subsequent runs use pwsh 7.
    `$_childShell = `$null
    foreach (`$_cs in @("`$env:ProgramFiles\PowerShell\7\pwsh.exe","`$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
        if (`$_cs -and (Test-Path -LiteralPath `$_cs -PathType Leaf)) { `$_childShell = `$_cs; break }
    }
    if (-not `$_childShell) {
        try {
            `$_appx = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue
            if (`$_appx -and `$_appx.InstallLocation) {
                `$_cand = Join-Path `$_appx.InstallLocation 'pwsh.exe'
                if (Test-Path -LiteralPath `$_cand -PathType Leaf) { `$_childShell = `$_cand }
            }
        } catch {}
    }
    if (-not `$_childShell) {
        `$_cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if (`$_cmd -and `$_cmd.Source -and (Test-Path -LiteralPath `$_cmd.Source -PathType Leaf)) {
            `$_childShell = `$_cmd.Source
        }
    }
    if (-not `$_childShell) {
        `$_w51 = "`$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path -LiteralPath `$_w51 -PathType Leaf) { `$_childShell = `$_w51 }
    }
    if (-not `$_childShell) { `$_childShell = 'powershell.exe' }
    Write-Host ('      Using ' + `$_childShell) -ForegroundColor DarkGray
    & `$_childShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File `$tmpScript
    `$_rc = `$LASTEXITCODE
    Remove-Item -LiteralPath `$tmpScript -Force -ErrorAction SilentlyContinue
    `$_launchMiosOnClose = `$false
    if (`$_rc -ne 0) {
        Write-Host ''
        Write-Host ('  [!] Bootstrap exited with code ' + `$_rc) -ForegroundColor Red
        Write-Host '      Output above is the failure detail (Pass-1 has no separate log).' -ForegroundColor DarkGray
        Write-Host '      build-mios.ps1''s own log at M:\MiOS\logs\mios-install-*.log only kicks in on Pass-2 success.' -ForegroundColor DarkGray
        Write-Host ''
    } else {
        # Bootstrap succeeded -- defer the MiOS app spawn until the
        # operator CLOSES this window. Per operator: "the actual
        # process of closing the bootstrap powershell window after
        # installation is what should procure and spawn the MiOS
        # app's window".
        `$_launchMiosOnClose = `$true
        Write-Host ''
        Write-Host '  [+] Bootstrap complete. Press Enter to close THIS window and launch the MiOS app.' -ForegroundColor Green
    }
} catch {
    Write-Host ''
    Write-Host ('  [!] Bootstrap fetch/run failed: ' + `$_.Exception.Message) -ForegroundColor Red
    Write-Host ''
}
Write-Host ''
if (`$_launchMiosOnClose) {
    Write-Host '  Press Enter to close this bootstrap window and launch the MiOS app...' -ForegroundColor Yellow -NoNewline
} else {
    Write-Host '  Press Enter to close this elevated bootstrap window...' -ForegroundColor DarkGray -NoNewline
}
`$null = Read-Host

# ── ON CLOSE: spawn the MiOS app ─────────────────────────────────
# This block fires AFTER the operator presses Enter (the close
# action). Per operator: the close is what should procure and
# spawn the MiOS app's window. The spawn happens HERE, then the
# bootstrap conhost exits naturally.
if (`$_launchMiosOnClose) {
    try {
        # Resolve wt.exe (prefer Stable appx install location).
        `$_wtExe = `$null
        try {
            `$_pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
            if (`$_pkg -and `$_pkg.InstallLocation) {
                `$_cand = Join-Path `$_pkg.InstallLocation 'wt.exe'
                if (Test-Path -LiteralPath `$_cand) { `$_wtExe = `$_cand }
            }
        } catch {}
        if (-not `$_wtExe) { `$_wtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source }
        if (-not `$_wtExe) { throw 'wt.exe not found' }
        # Centered position on cursor's active monitor (pre-UAC capture).
        `$_pt2 = New-Object System.Drawing.Point `$_curXPre, `$_curYPre
        `$_s2  = [System.Windows.Forms.Screen]::FromPoint(`$_pt2).WorkingArea
        # `-w MiOS` names the window "MiOS" so the global summon
        # binding (Win+Space) can target it via globalSummon name=MiOS.
        # Without a named window, the toggle binding has nothing to
        # show/hide.
        # No --pos: hardcoded $_appWPx/$_appHPx (baked from outer scope's
        # 100% DPI cell metrics 80*10+20 = 820 px etc.) gave a half-size
        # placement on high-DPI hosts. Operator-reported regression: "MiOS
        # app terminal windows are still launching half the size it should
        # be". --size in CELLS lets WT pick the right pixel size for the
        # active DPI; the post-spawn SetWindowPos retry below reads the
        # ACTUAL outer-rect via GetWindowRect and centers from THAT.
        `$_wtArgs = @(
            '-w', 'MiOS',
            '--size', "$_appCols,$_appRows",
            '--focus',
            '-p', 'MiOS'
        )
        `$_spawnedAt = Get-Date
        Start-Process -FilePath `$_wtExe -ArgumentList `$_wtArgs -ErrorAction Stop
        # Post-spawn SetWindowPos correction (wt.exe --pos unreliable
        # in --focus mode).
        Add-Type -Namespace MEW -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle r);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
        `$_deadline = (Get-Date).AddMilliseconds(8000)
        `$_wtHwnd = [IntPtr]::Zero
        while ((Get-Date) -lt `$_deadline) {
            `$_proc = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
                      Where-Object { `$_.StartTime -ge `$_spawnedAt.AddSeconds(-1) } |
                      Sort-Object StartTime -Descending | Select-Object -First 1
            if (`$_proc -and `$_proc.MainWindowHandle -ne [IntPtr]::Zero -and [MEW.W]::IsWindowVisible(`$_proc.MainWindowHandle)) {
                `$_wtHwnd = `$_proc.MainWindowHandle
                break
            }
            Start-Sleep -Milliseconds 150
        }
        if (`$_wtHwnd -ne [IntPtr]::Zero) {
            # Persistent re-center loop. Operator-reported regression:
            # "window also doesn't launch centered still -- should re-
            # center every few ticks". Single-shot SetWindowPos was
            # losing the race against WT's own post-spawn layout work
            # (acrylic backdrop allocation, font cache, etc. trigger
            # 1-2 size renegotiations after the initial paint). Loop
            # 12 times at 500ms = ~6 seconds total -- long enough for
            # WT to settle, short enough that the operator can still
            # manually drag the window after if they want. Each tick
            # re-reads the actual rect (so a WT resize during the loop
            # gets re-centered with the new dims) and applies SetWindow
            # Pos. The loop is the bootstrap's last action before exit
            # so it doesn't block any other phase.
            for (`$_i = 0; `$_i -lt 12; `$_i++) {
                `$_actualRect = New-Object System.Drawing.Rectangle
                [void][MEW.W]::GetWindowRect(`$_wtHwnd, [ref]`$_actualRect)
                `$_aw = `$_actualRect.Width  - `$_actualRect.X
                `$_ah = `$_actualRect.Height - `$_actualRect.Y
                if (`$_aw -le 0 -or `$_ah -le 0) { Start-Sleep -Milliseconds 500; continue }
                `$_cx = `$_s2.X + [int](([math]::Max(0, `$_s2.Width  - `$_aw)) / 2)
                `$_cy = `$_s2.Y + [int](([math]::Max(0, `$_s2.Height - `$_ah)) / 2)
                # SWP_NOZORDER (0x4) + SWP_NOACTIVATE (0x10) = 0x14 so we
                # don't steal focus or fight z-order with other windows.
                [void][MEW.W]::SetWindowPos(`$_wtHwnd, [IntPtr]::Zero, `$_cx, `$_cy, `$_aw, `$_ah, 0x14)
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {}
}
"@
    # Write the inner cmd to a temp .ps1 and pass -File. Why NOT
    # -EncodedCommand: the inner cmd is ~12.5 KB of source. UTF-16
    # encoding doubles that to ~25 KB; Base64 expands to ~33 KB. Start-
    # Process -Verb RunAs goes through ShellExecute, whose lpParameters
    # is capped at 32,767 chars (signed 16-bit limit). The encoded
    # payload + surrounding -NoLogo / -NoProfile / -ExecutionPolicy /
    # -NoExit / -EncodedCommand args pushes us OVER 32 KB -- ShellExecute
    # returns ERROR_INVALID_PARAMETER (0x80070057) which surfaces to the
    # operator as "Self-elevation failed: The parameter is incorrect."
    # UAC never even fires; Pass-2 never opens. -File <shortpath> keeps
    # the command line tiny regardless of inner cmd size, so ShellExecute
    # is happy.
    $_innerScript = Join-Path $env:TEMP ('mios-elev-' + [guid]::NewGuid().Guid.Substring(0,8) + '.ps1')
    # UTF-8 with BOM so pwsh / powershell.exe both parse Unicode glyphs
    # in the dashboard banner correctly.
    $_utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($_innerScript, $_innerCmd, $_utf8Bom)
    $_shell = $null
    foreach ($_c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe","$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
        if ($_c -and (Test-Path -LiteralPath $_c -PathType Leaf)) { $_shell = $_c; break }
    }
    if (-not $_shell) {
        $_w51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path -LiteralPath $_w51 -PathType Leaf) { $_shell = $_w51 }
    }
    if (-not $_shell) { $_shell = 'powershell.exe' }
    try {
        Start-Process -FilePath $_shell `
            -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', $_innerScript) `
            -Verb RunAs -WorkingDirectory $env:WINDIR -ErrorAction Stop
        # SUCCESS: Pass-1 has done its job. Pass-2 is alive in a new
        # elevated window which will fetch the latest Get-MiOS.ps1, render
        # the agreement gate (in 80x40), and run the install. Pass-1 must
        # EXIT IMMEDIATELY so the operator's focus moves cleanly to Pass-2.
        # The hosting `powershell -Command "irm | iex"` has no -NoExit, so
        # `return` here lets Pass-1's powershell.exe close on its own.
        # Operator perceives: small black box flashes -> UAC prompt ->
        # properly-sized elevated window appears with the agreement.
        return
    } catch {
        # FAILURE PATH: keep Pass-1 visible so the operator can read the
        # error detail (UAC denied, ShellExecute failure, etc.). On
        # success Pass-1 has already returned above.
        Write-Host ''
        Write-Host "  [!] Self-elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '      If you saw a UAC prompt, accept it and re-paste the one-liner.' -ForegroundColor DarkGray
        Write-Host '      Or open an elevated PowerShell manually and re-run:' -ForegroundColor DarkGray
        Write-Host "        irm $_rawUrl | iex" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Pass-1 elevation FAILED. Read the error above, then press Enter to close.' -ForegroundColor Yellow -NoNewline
        $null = Read-Host
        return
    }
}

# AGREEMENT GATE -- runs in Pass-2 only. Pass-1 returned out of the
# elevation block above, so reaching this line means we're already in
# the properly-sized 80x40 elevated conhost. The gate function resizes
# UP to 80x60 to give the ~104-line agreement breathing room, then
# blocks on Read-Host until the operator types "Acknowledged" or aborts.
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

# Hokusai + operator-neutrals palette -- ALL values source from
# mios.toml [colors] (vendor < host < user three-layer overlay) via
# Get-MiosTomlValue. mios.toml is THE singular SSOT for the palette;
# the literals below are FALLBACKS used only when the layered TOML
# can't be read (early bootstrap before M:\ exists, or a corrupted
# overlay). An operator edit in mios.html flows through to this
# palette without touching any PS1.
function Get-MiosPalette {
    # DEFENSIVE color resolution. Every WT scheme field MUST be a valid
    # `#rrggbb` or `#rgb` hex string -- WT rejects the entire
    # settings.json with "Line N column N (foreground) Have: ""
    # Expected: color" if ANY field is empty or malformed, falling back
    # to bare WT defaults (the operator-reported "no theme / no acrylic
    # / no MiOS profile" symptom -- WT silently dropped the broken
    # MiOS scheme). The _hex helper below accepts the TOML value, then
    # ALWAYS returns a valid hex color: if the resolved value is empty
    # / null / malformed, it returns the hardcoded fallback instead.
    function _hex {
        param([string]$Section, [string]$Key, [string]$Fallback)
        $v = (Get-MiosTomlValue -Section $Section -Key $Key -Default $Fallback)
        if (-not $v -or [string]::IsNullOrWhiteSpace($v)) { return $Fallback }
        $v = $v.Trim()
        if ($v -notmatch '^#[0-9A-Fa-f]{3,8}$') { return $Fallback }
        return $v
    }
    @{
        bg                = (_hex 'colors' 'bg'                       '#282262')
        fg                = (_hex 'colors' 'fg'                       '#E7DFD3')
        accent            = (_hex 'colors' 'accent'                   '#1A407F')
        cursor            = (_hex 'colors' 'cursor'                   '#F35C15')
        ansi_0_black      = (_hex 'colors' 'ansi_0_black'             '#282262')
        ansi_1_red        = (_hex 'colors' 'ansi_1_red'               '#DC271B')
        ansi_2_green      = (_hex 'colors' 'ansi_2_green'             '#3E7765')
        ansi_3_yellow     = (_hex 'colors' 'ansi_3_yellow'            '#F35C15')
        ansi_4_blue       = (_hex 'colors' 'ansi_4_blue'              '#1A407F')
        ansi_5_magenta    = (_hex 'colors' 'ansi_5_magenta'           '#734F39')
        ansi_6_cyan       = (_hex 'colors' 'ansi_6_cyan'              '#B7C9D7')
        ansi_7_white      = (_hex 'colors' 'ansi_7_white'             '#E7DFD3')
        ansi_8_brblack    = (_hex 'colors' 'ansi_8_bright_black'      '#948E8E')
        ansi_9_brred      = (_hex 'colors' 'ansi_9_bright_red'        '#FF6B5C')
        ansi_10_brgreen   = (_hex 'colors' 'ansi_10_bright_green'     '#5FAA8E')
        ansi_11_bryellow  = (_hex 'colors' 'ansi_11_bright_yellow'    '#FF8540')
        ansi_12_brblue    = (_hex 'colors' 'ansi_12_bright_blue'      '#3D6BA8')
        ansi_13_brmagenta = (_hex 'colors' 'ansi_13_bright_magenta'   '#9D7660')
        ansi_14_brcyan    = (_hex 'colors' 'ansi_14_bright_cyan'      '#E0E0E0')
        ansi_15_brwhite   = (_hex 'colors' 'ansi_15_bright_white'     '#FFFFFF')
    }
}
$Script:MiosPalette = Get-MiosPalette

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

function Install-MiOSPwsh7 {
    # Ensure PowerShell 7 (`pwsh.exe`) is on disk BEFORE the WT MiOS
    # profile is generated, so the profile's `commandline` can bind
    # to pwsh.exe rather than silently falling back to Windows
    # PowerShell 5.1. PS 5.1 has the OLD PSReadLine that breaks
    # oh-my-posh init's modern PSReadLine integration; the resulting
    # MiOS terminal renders the OPERATOR'S pre-existing PS 5.1
    # profile (whatever broken oh-my-posh init they had — typical
    # symptom: "CONFIG NOT FOUND" prompt segment). Install-MiOSTerminalExtras
    # at Step 6/7 also installs Microsoft.PowerShell, but that's
    # AFTER WT profile creation — too late.
    #
    # Idempotent: probes existing install before re-installing.
    # Refreshes $env:PATH after install so the caller's pwsh
    # detection (Get-AppxPackage / Get-Command pwsh) sees the new
    # binary in this same session.
    $existing = $null
    foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { $existing = $c; break }
    }
    if (-not $existing) {
        try {
            $appx = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue
            if ($appx -and $appx.InstallLocation) {
                $cand = Join-Path $appx.InstallLocation 'pwsh.exe'
                if (Test-Path -LiteralPath $cand) { $existing = $cand }
            }
        } catch {}
    }
    if ($existing) {
        Write-Host "  [+] PowerShell 7 already installed: $existing" -ForegroundColor DarkGray
        return $true
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] winget not available; cannot install PowerShell 7." -ForegroundColor Yellow
        Write-Host "      WT MiOS profile will fall back to Windows PS 5.1 (broken oh-my-posh init likely)." -ForegroundColor DarkGray
        return $false
    }
    Write-Host "  [*] Installing PowerShell 7 (Microsoft.PowerShell) via winget..." -ForegroundColor Cyan
    try {
        & winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
    } catch {
        Write-Host "  [!] winget install Microsoft.PowerShell failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] winget exit code $LASTEXITCODE -- pwsh 7 may not be installed." -ForegroundColor Yellow
        return $false
    }
    # Refresh $env:PATH so the caller's Get-Command pwsh / Get-AppxPackage
    # discovery picks up the new binary in this session.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
    } catch {}
    Write-Host "  [+] PowerShell 7 installed; PATH refreshed for this session." -ForegroundColor Green
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

        # Get every font file in the extracted tree (.ttf OR .otf -- the
        # current Geist Nerd Fonts release ships .otf only). Nerd Fonts
        # release naming has changed multiple times -- the Get-ChildItem
        # -Filter pattern was missing valid faces because of case-sensitivity
        # and substring quirks on PowerShell 7.6+. Use -match instead which
        # is case-insensitive by default.
        $allFonts = Get-ChildItem $tmpDir -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '\.(ttf|otf)$' }
        # Prefer "Mono" variants (fixed-width, terminal-safe). Then
        # general "NerdFont". Then ANY font face as last resort.
        $preferred = $allFonts | Where-Object { $_.Name -match 'NerdFontMono' }
        if (-not $preferred) {
            $preferred = $allFonts | Where-Object { $_.Name -match 'NerdFont' }
        }
        if (-not $preferred) {
            $preferred = $allFonts
        }
        if (-not $preferred) {
            Write-Host "  [!] GeistMono.zip extracted but contains no .ttf/.otf files. (Found $($allFonts.Count))" -ForegroundColor Yellow
            return $false
        }

        $installed = 0
        foreach ($ttf in $preferred) {
            $dst = Join-Path $userFontDir $ttf.Name
            Copy-Item -LiteralPath $ttf.FullName -Destination $dst -Force
            # Face name for the registry value: derive from filename
            # ("GeistMonoNerdFontMono-Regular.ttf" -> "GeistMono Nerd Font Mono Regular (TrueType|OpenType)").
            # Windows registry keys differ for TTF vs OTF -- TrueType for
            # .ttf, OpenType for .otf -- and Windows' font loader uses the
            # suffix to dispatch to the right rasterizer.
            $face = $ttf.BaseName `
                -replace 'NerdFontMono', ' Nerd Font Mono ' `
                -replace 'NerdFont',     ' Nerd Font ' `
                -replace '-',            ' ' `
                -replace '\s+',          ' '
            $suffix = if ($ttf.Extension -ieq '.otf') { ' (OpenType)' } else { ' (TrueType)' }
            $face = $face.Trim() + $suffix
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

    # Re-resolve the palette HERE (in case $Script:MiosPalette was cached
    # before the M:\ TOML existed -- file-load-time evaluation of
    # Get-MiosPalette can hit the cold-fetch path which may have failed
    # silently). Then guard EVERY field with the same hex-fallback the
    # palette resolver applies, so a stale/empty cached value can't leak
    # into the WT scheme and trigger WT's "Line N column N (foreground)
    # Have: '' Expected: color" rejection -- which falls back the entire
    # settings.json to defaults (no MiOS profile, no acrylic, no scheme).
    $palette = Get-MiosPalette
    function _miosSchemeColor {
        param($Value, [string]$Fallback)
        if (-not $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Fallback }
        $v = ([string]$Value).Trim()
        if ($v -notmatch '^#[0-9A-Fa-f]{3,8}$') { return $Fallback }
        return $v
    }
    $miosScheme = [ordered]@{
        name                = 'MiOS'
        background          = (_miosSchemeColor $palette.bg                '#282262')
        foreground          = (_miosSchemeColor $palette.fg                '#E7DFD3')
        cursorColor         = (_miosSchemeColor $palette.cursor            '#F35C15')
        selectionBackground = (_miosSchemeColor $palette.accent            '#1A407F')
        black               = (_miosSchemeColor $palette.ansi_0_black      '#282262')
        red                 = (_miosSchemeColor $palette.ansi_1_red        '#DC271B')
        green               = (_miosSchemeColor $palette.ansi_2_green      '#3E7765')
        yellow              = (_miosSchemeColor $palette.ansi_3_yellow     '#F35C15')
        blue                = (_miosSchemeColor $palette.ansi_4_blue       '#1A407F')
        purple              = (_miosSchemeColor $palette.ansi_5_magenta    '#734F39')
        cyan                = (_miosSchemeColor $palette.ansi_6_cyan       '#B7C9D7')
        white               = (_miosSchemeColor $palette.ansi_7_white      '#E7DFD3')
        brightBlack         = (_miosSchemeColor $palette.ansi_8_brblack    '#948E8E')
        brightRed           = (_miosSchemeColor $palette.ansi_9_brred      '#FF6B5C')
        brightGreen         = (_miosSchemeColor $palette.ansi_10_brgreen   '#5FAA8E')
        brightYellow        = (_miosSchemeColor $palette.ansi_11_bryellow  '#FF8540')
        brightBlue          = (_miosSchemeColor $palette.ansi_12_brblue    '#3D6BA8')
        brightPurple        = (_miosSchemeColor $palette.ansi_13_brmagenta '#9D7660')
        brightCyan          = (_miosSchemeColor $palette.ansi_14_brcyan    '#E0E0E0')
        brightWhite         = (_miosSchemeColor $palette.ansi_15_brwhite   '#FFFFFF')
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
    # -NoProfile is CRITICAL: skip the operator's $PROFILE chain
    # entirely so any pre-existing oh-my-posh init / PSReadLine
    # configuration / aliases the operator already has DON'T run AFTER
    # our M:\ profile and override it. Operator-reported symptom: their
    # pre-existing themed PS 7 prompt rendered in MiOS terminal because
    # their $PROFILE re-initialized oh-my-posh AFTER our marker block.
    # With -NoProfile, ONLY the M:\ profile runs (via -Command dot-
    # source), so the MiOS terminal is operator-isolated and 100%
    # deterministic.
    # Single-quoted PS string with `''` for embedded literal quotes.
    # ConvertTo-Json will JSON-encode the outer double-quotes correctly.
    # `$env:MIOS_APP_CONTEXT='1'` is the gate signal the M:\ profile
    # body checks before resizing the conhost to the MiOS-app dims
    # (80x20). Without this signal the profile body skips the resize,
    # which is what we want during BOOTSTRAP/INSTALL where any child
    # pwsh inheriting `$PROFILE.CurrentUserAllHosts redirector should
    # NOT shrink the operator's 80x40 install conhost mid-install.
    $profileCmdline = '"' + $defaultPwsh + '" -NoLogo -NoExit -NoProfile -Command "$env:MIOS_APP_CONTEXT=''1''; if (Test-Path ''' + $miosProfilePath + ''') { . ''' + $miosProfilePath + ''' }"'

    # Per-profile shared settings -- apply to BOTH "MiOS" and "MiOS-DEV"
    # so they look/feel identical. Belt-AND-braces acrylic settings:
    # WT 1.16-1.17 reads `useAcrylic` (legacy bool) and `opacity`. WT
    # 1.18+ reads `systemBackdrop` (per-profile). Setting BOTH means
    # acrylic 50% transparency renders correctly across every WT
    # version the operator might end up on. `useMica` is NOT set --
    # it's not a documented WT key (mica is selected via
    # systemBackdrop="mica"), and shipping unknown keys can cause WT's
    # schema validator to reject the profile and fall back to defaults.
    # GLOBAL MiOS terminal defaults sourced from mios.toml [theme] +
    # [theme.font]. Per operator (multiple reaffirmations): acrylic ON,
    # 50% transparency, frame-less, border-less, scroll-bar-less. The
    # WT profile patcher reads from mios.toml so editing those keys in
    # the configurator HTML re-skins every MiOS terminal on the next
    # bootstrap run -- single edit surface, applied to BOTH WT profiles
    # (MiOS + MiOS-DEV) below.
    # ── Defensive toml-value resolution ──────────────────────────
    # If ANY of these returns an empty / invalid value, WT's schema
    # validator rejects the entire profile and the operator gets bare
    # default chrome (no acrylic, no MiOS scheme, no font). The earlier
    # tabColor "" failure proved this is fragile -- so we validate
    # EVERY toml-resolved string before stamping it into the profile.
    $_themeFontFace    = Get-MiosTomlValue -Section 'theme.font' -Key 'family'             -Default 'GeistMono Nerd Font Mono'
    if ([string]::IsNullOrWhiteSpace($_themeFontFace)) { $_themeFontFace = 'GeistMono Nerd Font Mono' }
    $_themeFontSize    = Get-MiosTomlValue -Section 'theme.font' -Key 'size'               -Default 12
    if (-not ($_themeFontSize -is [int]) -or $_themeFontSize -lt 6 -or $_themeFontSize -gt 72) { $_themeFontSize = 12 }
    $_themeFontWeight  = Get-MiosTomlValue -Section 'theme.font' -Key 'weight'             -Default 'normal'
    if ($_themeFontWeight -notin @('normal','thin','extra-light','light','semi-light','medium','semi-bold','bold','extra-bold','black','extra-black')) { $_themeFontWeight = 'normal' }
    $_themeAcrylic     = Get-MiosTomlValue -Section 'theme'      -Key 'acrylic'            -Default $true
    if ($_themeAcrylic -isnot [bool]) { $_themeAcrylic = $true }
    $_themeOpacity     = Get-MiosTomlValue -Section 'theme'      -Key 'opacity'            -Default 50
    if (-not ($_themeOpacity -is [int]) -or $_themeOpacity -lt 0 -or $_themeOpacity -gt 100) { $_themeOpacity = 50 }
    $_themeBackdrop    = Get-MiosTomlValue -Section 'theme'      -Key 'system_backdrop'    -Default 'acrylic'
    if ($_themeBackdrop -notin @('acrylic','mica','tab','default','disable')) { $_themeBackdrop = 'acrylic' }
    # filledBox = full-cell block, Linux terminal default.
    $_themeCursor      = Get-MiosTomlValue -Section 'theme'      -Key 'cursor_shape'       -Default 'filledBox'
    if ($_themeCursor -notin @('bar','vintage','underscore','filledBox','emptyBox','doubleUnderscore')) { $_themeCursor = 'filledBox' }
    $_themeScrollbar   = Get-MiosTomlValue -Section 'theme'      -Key 'scrollbar_state'    -Default 'hidden'
    if ($_themeScrollbar -notin @('visible','hidden','always')) { $_themeScrollbar = 'hidden' }
    $_themePadding     = Get-MiosTomlValue -Section 'theme'      -Key 'padding'            -Default '0'
    if ([string]::IsNullOrWhiteSpace($_themePadding)) { $_themePadding = '0' }
    $_themeSuppress    = Get-MiosTomlValue -Section 'theme'      -Key 'suppress_app_title' -Default $true
    if ($_themeSuppress -isnot [bool]) { $_themeSuppress = $true }
    $_themeAccent = Get-MiosTomlValue -Section 'colors' -Key 'accent' -Default '#1A407F'
    if ([string]::IsNullOrWhiteSpace($_themeAccent) -or ($_themeAccent -notmatch '^#[0-9A-Fa-f]{3,8}$')) {
        $_themeAccent = '#1A407F'
    }
    # MINIMAL chrome only -- per operator's trace, the WT MiOS app
    # rendered the oh-my-posh prompt (so commandline + profile body
    # work) but DID NOT apply chrome (no acrylic, no MiOS scheme).
    # That means WT silently rejected one of the chrome keys and
    # fell back to defaults for the rest. Stripping back to the
    # bare minimum proven-working set; will re-add carefully once
    # this verifies rendering with full theming.
    # Terminal dims sourced from mios.toml [terminal].cols / .rows so
    # opening the WT profile DIRECTLY (without the launcher's --size
    # arg, e.g. from the WT dropdown) still produces an 80x20 window.
    # Without these, WT inherits the operator's global default
    # (typically 120x30) and the dashboard's framing breaks.
    $_miosWtCols = Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80
    if (-not ($_miosWtCols -is [int]) -or $_miosWtCols -lt 40 -or $_miosWtCols -gt 240) { $_miosWtCols = 80 }
    $_miosWtRows = Get-MiosTomlValue -Section 'terminal' -Key 'rows' -Default 20
    if (-not ($_miosWtRows -is [int]) -or $_miosWtRows -lt 10 -or $_miosWtRows -gt 120) { $_miosWtRows = 20 }

    $commonProfileProps = [ordered]@{
        colorScheme              = (Get-MiosTomlValue -Section 'theme.terminal' -Key 'scheme_name' -Default 'MiOS')
        font                     = [ordered]@{
            face   = $_themeFontFace
            size   = $_themeFontSize
            weight = $_themeFontWeight
        }
        cursorShape              = $_themeCursor
        antialiasingMode         = 'cleartype'
        useAcrylic               = $_themeAcrylic
        opacity                  = $_themeOpacity
        systemBackdrop           = $_themeBackdrop
        padding                  = $_themePadding
        suppressApplicationTitle = $_themeSuppress
        scrollbarState           = $_themeScrollbar
        # initialCols / initialRows lock the dims when WT spawns this
        # profile from a non-launcher entry point (dropdown, "MiOS
        # Terminal" Start Menu shortcut). Operator-edited via mios.toml
        # [terminal].cols / .rows.
        initialCols              = $_miosWtCols
        initialRows              = $_miosWtRows
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
    # Resolve the actual on-disk WSL distro name. podman machine init
    # registers the distro as 'podman-MiOS-DEV' (podman hardcodes the
    # 'podman-' prefix), even though the operator-facing name is
    # MiOS-DEV. Operator-reported regression: clicking the MiOS-DEV
    # shortcut threw 'WSL_E_DISTRO_NOT_FOUND' because the profile
    # commandline targeted bare 'MiOS-DEV' which doesn't exist on disk.
    # Walk the registered distro list at install time and pick the
    # first match in priority order: prefer 'podman-MiOS-DEV' (post
    # init) -> 'MiOS-DEV' (post Restore-PodmanPrefix) -> 'podman-MiOS-
    # BUILDER' (legacy) -> 'MiOS-BUILDER' (legacy).
    $_devDistroName = 'podman-MiOS-DEV'   # default if probing fails
    try {
        $_wslList = @(& wsl.exe -l -q 2>$null) | ForEach-Object { ($_ -replace [char]0,'').Trim() } | Where-Object { $_ }
        foreach ($_cand in @('podman-MiOS-DEV','MiOS-DEV','podman-MiOS-BUILDER','MiOS-BUILDER')) {
            if ($_wslList -contains $_cand) { $_devDistroName = $_cand; break }
        }
    } catch {}
    $miosDevProfile = [ordered]@{
        guid              = $miosDevGuid
        name              = 'MiOS-DEV'
        commandline       = ('wsl.exe -d ' + $_devDistroName + ' --cd / --user mios')
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

    # GLOBAL no-scrollbars + zero-padding via profiles.defaults. Per
    # operator: "MiOS app window/terminal window(s) should all have NO
    # scrollbars inhibiting any windows globally!!". Per-profile
    # scrollbarState only affects that profile; profiles.defaults
    # applies to EVERY profile including auto-generated ones (cmd,
    # PowerShell, WSL distros), so when an operator switches profiles
    # they keep the borderless+scrollbar-less feel.
    if (-not $wtJson.profiles.defaults) {
        $wtJson.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $wtJson.profiles.defaults | Add-Member -NotePropertyName scrollbarState -NotePropertyValue 'hidden' -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName padding        -NotePropertyValue '0'      -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName useAcrylic     -NotePropertyValue $true    -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName opacity        -NotePropertyValue 50       -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName systemBackdrop -NotePropertyValue 'acrylic' -Force

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
    # Also strip podman/WSL auto-generated profiles for our distros
    # (podman-MiOS-DEV, podman-MiOS-BUILDER, etc.) -- WT auto-creates one
    # per `podman machine init` call and they accumulate without dedup.
    # Our branded MiOS-DEV profile already covers that distro.
    $existingList = @($wtJson.profiles.list | Where-Object {
        $_.guid -ne $miosGuid -and
        $_.guid -ne $miosDevGuid -and
        $_.name -ne 'MiOS' -and
        $_.name -ne 'MiOS-DEV' -and
        $_.name -ne 'MiOS-Bootstrap' -and
        $_.name -notmatch '^podman-MiOS-'
    })
    $miosProfileObj    = [PSCustomObject]$miosProfile
    $miosDevProfileObj = [PSCustomObject]$miosDevProfile
    $existingList += $miosProfileObj
    $existingList += $miosDevProfileObj
    $wtJson.profiles.list = [object[]]$existingList

    # NOTE: globalSummon keybinding (Win+Space) NOT written. Adding
    # it appears to trip WT's settings-file validator silently --
    # the prompt rendered (so commandline + scheme reference were
    # fine) but acrylic / scheme resolution didn't apply, suggesting
    # WT bailed mid-load. Will re-add via a separate post-MVP commit
    # after minimum chrome is verified rendering. Operator can still
    # add it manually via mios-config.html or by editing settings.json.

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

# Cell metrics + dims baked from mios.toml [terminal] / [theme.font]
# at launcher install time. Edit M:\usr\share\mios\mios.toml + re-run
# Get-MiOS.ps1 to regenerate.
$Cols = __MIOS_COLS__; $Rows = __MIOS_ROWS__
$winW = ($Cols * __MIOS_CELL_W__) + __MIOS_CHROME_W__
$winH = ($Rows * __MIOS_CELL_H__) + __MIOS_CHROME_H__

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

# `-w MiOS` (NOT -1) names the window so it matches the post-bootstrap
# spawn. Without the named window, clicking the MiOS shortcut produces
# a DIFFERENT window than the one that opens at end-of-bootstrap, AND
# the Win+Space global summon binding (which targets window name=MiOS)
# can't toggle it. Both paths now produce the SAME WT MiOS window.
# Also no `nt` subcommand -- empty subcommand line uses the profile's
# bound commandline (Windows pwsh + MiOS PS profile body).
$wtArgs = @('-w','MiOS','--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p','MiOS')
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
    # ENFORCE the target pixel size ($winW / $winH computed from
    # mios.toml [terminal].cols/.rows + [theme.font] cell metrics).
    # The previous version of this code used $rw/$rh from GetWindowRect
    # -- which is the CURRENT window size -- and only re-centered.
    # When `wt.exe -w MiOS` added a tab to an existing wider window
    # (operator already had a MiOS-named WT window from a prior run),
    # the launcher kept the old wide dims and the operator saw a
    # ~167-col terminal instead of the canonical 80x20. SetWindowPos
    # with the COMPUTED target dims ($winW / $winH) forces the resize
    # every launch so the MiOS terminal is deterministic.
    $topmost = [IntPtr]::new(-1)
    $cx = [int]($work.X + ($work.Width  - $winW) / 2); if ($cx -lt $work.X) { $cx = $work.X }
    $cy = [int]($work.Y + ($work.Height - $winH) / 2); if ($cy -lt $work.Y) { $cy = $work.Y }
    for ($i = 0; $i -lt 3; $i++) {
        # 0x40 = SWP_SHOWWINDOW | SWP_NOOWNERZORDER (apply size + topmost).
        # 0x04 = SWP_NOZORDER                       (re-apply to release topmost
        #                                            after the window is the
        #                                            front-most; without this
        #                                            second pass the operator
        #                                            can't focus other windows).
        [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, $topmost,           $cx, $cy, $winW, $winH, 0x40)
        [void][MiOSLaunch.Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero,     $cx, $cy, $winW, $winH, 0x04)
        Start-Sleep -Milliseconds 350
    }
}
'@
    # Bake mios.toml [terminal] / [theme.font] values into the launcher
    # body. Single-quoted here-string above means $vars don't interpolate
    # at definition time; we substitute placeholders here at install time
    # so the launcher's geometry tracks the operator's mios.toml edits.
    $_lnchCols    = Get-MiosTomlValue -Section 'terminal'   -Key 'cols'         -Default 80
    $_lnchRows    = Get-MiosTomlValue -Section 'terminal'   -Key 'rows'         -Default 20
    $_lnchCellW   = Get-MiosTomlValue -Section 'theme.font' -Key 'cell_w_px'    -Default 10
    $_lnchCellH   = Get-MiosTomlValue -Section 'theme.font' -Key 'cell_h_px'    -Default 20
    $_lnchChromeW = Get-MiosTomlValue -Section 'theme.font' -Key 'chrome_w_px'  -Default 20
    $_lnchChromeH = Get-MiosTomlValue -Section 'theme.font' -Key 'chrome_h_px'  -Default 12
    $launcherBody = $launcherBody `
        -replace '__MIOS_COLS__',     [string]$_lnchCols `
        -replace '__MIOS_ROWS__',     [string]$_lnchRows `
        -replace '__MIOS_CELL_W__',   [string]$_lnchCellW `
        -replace '__MIOS_CELL_H__',   [string]$_lnchCellH `
        -replace '__MIOS_CHROME_W__', [string]$_lnchChromeW `
        -replace '__MIOS_CHROME_H__', [string]$_lnchChromeH
    Set-Content -Path $launcherPath -Value $launcherBody -Encoding UTF8
    Write-Host "  [+] MiOS launcher staged: $launcherPath" -ForegroundColor DarkGray

    # Resolve a pwsh.exe for the .lnk target.
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwshExe) { Write-Host "  [!] No pwsh.exe found; cannot create launcher .lnk." -ForegroundColor Yellow; return }

    $lnkArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
    # .lnk Description = mios.toml [branding].tagline + a short
    # technical sub-line. SSOT lift per "no hardcoding ANYWHERE".
    $_lnkTag = Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'My Personalized OS'
    $lnkDesc = "MiOS -- $_lnkTag. Borderless 80x30 acrylic terminal."

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

    # ── Per-verb shortcuts (MiOS-DEV / MiOS Build / MiOS Dashboard / etc.) ──
    # Per the canonical e2e contract: native-app surface is the MiOS hub +
    # per-verb shortcuts. Each verb opens a fresh MiOS WT app window (via
    # mios-launch.ps1) and runs `mios <verb>` inside it. Both Start Menu
    # AND Desktop get the shortcuts so the operator can pick whichever
    # surface they prefer (and pin manually -- Win11 disabled programmatic
    # pinning to Start, so we drop the .lnk and the operator right-clicks
    # → "Pin to Start" / "Pin to Taskbar").
    # Operator-curated 4-app surface: MiOS (the terminal hub, created
    # separately above as MiOS.lnk), MiOS-DEV (dev VM dashboard),
    # MiOS Help (verb reference), Uninstall MiOS (Add/Remove). The
    # build / dash / config / update / pull verbs are operator-typed
    # commands INSIDE the MiOS terminal, NOT separate native apps.
    $miosVerbs = @(
        @{ File='MiOS-DEV.lnk';  Verb='dev';   Desc='Open MiOS-DEV (podman machine) directly to its themed dashboard (banner + fastfetch + framing)' },
        @{ File='MiOS Help.lnk'; Verb='help';  Desc='Full verb + functionality reference (every MiOS command and where things live)' }
    )
    $writeVerbLnk = {
        param([string]$Path, [string]$Verb, [string]$Desc)
        $sc = $shell.CreateShortcut($Path)
        $sc.TargetPath       = $pwshExe
        # Spawn the launcher (themed WT MiOS window) then run `mios <verb>`
        # inside it. Single -Command keeps the .lnk argument quoting clean.
        $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$launcherPath'; Start-Sleep -Milliseconds 800; & wt.exe -w 0 nt -p MiOS pwsh -NoExit -Command 'mios $Verb'`""
        $sc.WorkingDirectory = $miosRoot
        $sc.Description      = $Desc
        $sc.WindowStyle      = 7
        if ($iconPath) { $sc.IconLocation = "$iconPath,0" }
        $sc.Save()
    }
    foreach ($v in $miosVerbs) {
        $smPath = Join-Path $startMenuDir $v.File
        & $writeVerbLnk $smPath $v.Verb $v.Desc
        if ($desktopDir -and (Test-Path $desktopDir)) {
            $dskPath = Join-Path $desktopDir $v.File
            & $writeVerbLnk $dskPath $v.Verb $v.Desc
        }
    }
    Write-Host "  [+] Per-verb shortcuts: $($miosVerbs.Count) Start Menu + $($miosVerbs.Count) Desktop entries staged." -ForegroundColor DarkGray
    Write-Host "      Right-click any of them in Start to Pin to Start / Pin to Taskbar (Win11 dropped programmatic pinning)." -ForegroundColor DarkGray

    # Stale-shortcut cleanup -- earlier revisions created MiOS Build /
    # Dashboard / Configurator / Update / Pull as separate native apps.
    # The 4-app set is now MiOS, MiOS-DEV, MiOS Help, Uninstall MiOS;
    # the rest are operator-typed verbs INSIDE the terminal. Reap any
    # leftover .lnk's so a re-run of Get-MiOS.ps1 normalizes the menu.
    foreach ($legacy in @('MiOS Build.lnk','MiOS Dashboard.lnk','MiOS Configurator.lnk','MiOS Update.lnk','MiOS Pull.lnk','MiOS Setup.lnk','MiOS Terminal.lnk','MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','Build MiOS.lnk')) {
        foreach ($dir in @($startMenuDir, $desktopDir)) {
            if (-not $dir) { continue }
            $stale = Join-Path $dir $legacy
            if (Test-Path -LiteralPath $stale) {
                try { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue; Write-Host "  [+] Removed stale shortcut: $stale" -ForegroundColor DarkGray } catch {}
            }
        }
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
            $_aumid = Get-MiosTomlValue -Section 'apps' -Key 'aumid' -Default 'MiOS.Workstation'
            # Stamp AumID on the hub shortcut + every per-verb shortcut.
            # All MiOS app windows then group under one taskbar / Start
            # tile (so pinning the hub also covers the verbs).
            $_allShortcuts = @($smLnk)
            if ($desktopDir -and (Test-Path "$desktopDir\MiOS.lnk")) {
                $_allShortcuts += "$desktopDir\MiOS.lnk"
            }
            foreach ($v in $miosVerbs) {
                $_smv = Join-Path $startMenuDir $v.File
                if (Test-Path -LiteralPath $_smv) { $_allShortcuts += $_smv }
                if ($desktopDir -and (Test-Path -LiteralPath (Join-Path $desktopDir $v.File))) {
                    $_allShortcuts += (Join-Path $desktopDir $v.File)
                }
            }
            foreach ($lnk in $_allShortcuts) {
                try { [MiOS.NativeApp.Aumid]::Set($lnk, $_aumid) } catch {}
            }
            Write-Host "  [+] AppUserModelID = $_aumid stamped on $($_allShortcuts.Count) shortcuts (hub + per-verb)." -ForegroundColor DarkGray
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
    "separator": ": ",
    "color": {
      "keys": "#F35C15",
      "title": "#E7DFD3",
      "output": "#B7C9D7"
    }
  },
  "modules": [
    "title",
    { "type": "os",       "key": "OS"     },
    { "type": "host",     "key": "Host"   },
    { "type": "uptime",   "key": "Up"     },
    { "type": "shell",    "key": "Shell"  },
    { "type": "cpu",      "key": "CPU"    },
    { "type": "gpu",      "key": "GPU",     "format": "{name}", "hideType": "integrated" },
    { "type": "memory",   "key": "Mem"    },
    { "type": "disk",     "key": "C",       "folders": "C:\\", "format": "{size-used} / {size-total}" },
    { "type": "disk",     "key": "M",       "folders": "M:\\", "format": "{size-used} / {size-total}" },
    { "type": "datetime", "key": "Time"   }
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
  "//": "final_space=false: don't reserve a trailing column after the prompt -- the right-aligned time segment now uses trailing_diamond U+E0B4 to reach col 79 of the frameless 80-col terminal.",
  "final_space": false,
  "//": [
    "MiOS Oh-My-Posh theme.",
    "All Nerd Font private-use-area glyphs are encoded as JSON \\uXXXX",
    "escape sequences (json.dump ensure_ascii=True) so the file roundtrips",
    "through any editor/git/sync layer without losing the U+E000..F8FF",
    "code points -- write-tool sanitizers strip raw PUA chars on save.",
    "Palette: mios.toml [colors] (Hokusai + operator neutrals).",
    "MiOS-owned segments use the MiOS palette; language segments keep",
    "brand colors so Node-green / Python-blue+yellow / Rust-orange stay",
    "instantly recognizable. Rounded powerline caps (U+E0B4 right,",
    "U+E0B6 left) for soft, full-radius segment ends."
  ],
  "blocks": [
    {
      "type": "prompt",
      "alignment": "left",
      "segments": [
        {
          "//": "Leading rounded cap (U+E0B6) so the colored powerline starts at col 0 of the frameless MiOS terminal -- replaces the previous plain '\u256d\u2500' text prefix that left cols 0-2 uncolored. The shell segment merges into this leading cap because both share the #1A407F background.",
          "type": "text",
          "style": "diamond",
          "leading_diamond": "\ue0b6",
          "trailing_diamond": "",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "template": ""
        },
        {
          "type": "shell",
          "style": "powerline",
          "powerline_symbol": "\ue0b4",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "template": " \uf120 {{ .Name }} "
        },
        {
          "type": "root",
          "style": "powerline",
          "powerline_symbol": "\ue0b4",
          "background": "#DC271B",
          "foreground": "#F35C15",
          "template": " \uf292 "
        },
        {
          "type": "path",
          "style": "powerline",
          "powerline_symbol": "\ue0b4",
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
          "powerline_symbol": "\ue0b4",
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
          "powerline_symbol": "\ue0b4",
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
          "powerline_symbol": "\ue0b6",
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
          "powerline_symbol": "\ue0b6",
          "background": "#306998",
          "foreground": "#FFE873",
          "template": " \ue235 {{ if .Error }}{{ .Error }}{{ else }}{{ if .Venv }}{{ .Venv }} {{ end }}{{ .Full }}{{ end }} "
        },
        {
          "type": "go",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
          "background": "#E7DFD3",
          "foreground": "#06aad5",
          "template": " \ue626 {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "rust",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
          "background": "#E7DFD3",
          "foreground": "#925837",
          "template": " \ue7a8 {{ if .Error }}{{ .Error }}{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "dotnet",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
          "background": "#0e0e0e",
          "foreground": "#0d6da8",
          "template": " \ue77f {{ if .Unsupported }}\uf071{{ else }}{{ .Full }}{{ end }} "
        },
        {
          "type": "kubectl",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
          "background": "#1A407F",
          "foreground": "#E7DFD3",
          "template": " \uf308 {{ .Context }}{{ if .Namespace }} :: {{ .Namespace }}{{ end }} "
        },
        {
          "type": "aws",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
          "background": "#565656",
          "foreground": "#F35C15",
          "template": " \ue7ad {{ .Profile }}{{ if .Region }}@{{ .Region }}{{ end }} "
        },
        {
          "type": "os",
          "style": "powerline",
          "invert_powerline": true,
          "powerline_symbol": "\ue0b6",
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
          "powerline_symbol": "\ue0b6",
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
          "//": "Trailing rounded cap (U+E0B4) so the right-aligned powerline reaches col 79 of the frameless terminal -- without trailing_diamond, oh-my-posh ends the segment at the text and leaves the last 1-2 cells uncolored. Operator-reported regression: 'powerline actually doesn't reach the RIGHT side'.",
          "type": "time",
          "style": "diamond",
          "leading_diamond": "\ue0b6",
          "trailing_diamond": "\ue0b4",
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
          "//": "Second-line leading rounded cap matches the first line so the colored powerline reaches col 0. Status segment is plain (no background) so the cap renders alone.",
          "type": "text",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "background": "#3E7765",
          "foreground": "#E7DFD3",
          "template": ""
        },
        {
          "type": "status",
          "style": "powerline",
          "powerline_symbol": "",
          "background": "#3E7765",
          "background_templates": [
            "{{ if gt .Code 0 }}#DC271B{{ end }}"
          ],
          "foreground": "#E7DFD3",
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

function Install-MiOSTerminalExtras {
    # Open-source terminal-completion + UX enhancers. PowerShell
    # modules come from PSGallery (Install-Module); CLI tools come
    # from winget. Net effect: every MiOS shell session gets:
    #
    #   * Terminal-Icons          -- file/folder icons in `ls` output
    #   * posh-git                -- git tab-completion + branch info
    #   * CompletionPredictor     -- AI-style predictive completion
    #   * WinGet.CommandNotFound  -- "did you mean: winget install X?"
    #                                when an unknown command is typed
    #   * sharkdp.bat             -- syntax-highlighted `cat` replacement
    #   * junegunn.fzf            -- fuzzy finder (Ctrl-T, Ctrl-R)
    #   * GitHub.cli              -- `gh` CLI for github operations
    #
    # All idempotent: probes existing install before re-installing.
    #
    # MUST run under PowerShell 7+, not Windows PowerShell 5.1:
    #   * PS 5.1 ships PowerShellGet 1.0.0.1, which can resolve Install-Module
    #     as a *command* but fails to load the *module* dependency graph
    #     (NuGet PackageProvider) -- the operator-visible error is
    #     "Install-Module was found in PowerShellGet, but the module could
    #     not be loaded". Force-Import + bootstrapping NuGet doesn't fully
    #     fix this on a fresh 5.1 install.
    #   * CompletionPredictor + Microsoft.WinGet.CommandNotFound require
    #     PS 7+ at *runtime* anyway (they use the PSReadLine 2.2 predictor
    #     API only available in pwsh 7).
    #   * PS 5.1 and PS 7 have SEPARATE per-user module paths
    #     (~/Documents/WindowsPowerShell/Modules vs ~/Documents/PowerShell/Modules)
    #     -- installing from 5.1 wouldn't help pwsh 7 see them at runtime.
    #
    # If launched via `powershell` (5.1), trampoline this step through
    # pwsh.exe so installs land in pwsh 7's user-module path.
    $isPs7 = $PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7
    $pwshExe = $null
    if (-not $isPs7) {
        foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                         "$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
            if ($c -and (Test-Path -LiteralPath $c)) { $pwshExe = $c; break }
        }
        if (-not $pwshExe) {
            $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { $pwshExe = $cmd.Source }
        }
    }

    # NOTE: when invoked via the trampoline below, this script's stdout is
    # captured by the parent (Windows PowerShell 5.1) and CLIXML-serialized
    # because pwsh 7 sends Write-Host through the PSHost information stream.
    # Use [Console]::WriteLine instead -- raw stdout bypasses the PSHost
    # serializer entirely, so the parent sees plain text. Cost: no color in
    # the trampolined branch (acceptable -- the in-process branch still
    # uses Write-Host with color).
    $modulesScript = @'
$ErrorActionPreference = 'Continue'
try { Import-Module PackageManagement -ErrorAction SilentlyContinue -Force } catch {}
try { Import-Module PowerShellGet     -ErrorAction SilentlyContinue -Force } catch {}
try {
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
             Sort-Object Version -Descending | Select-Object -First 1
    if (-not $nuget -or $nuget.Version -lt [Version]'2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction SilentlyContinue | Out-Null
    }
} catch {}
try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
$psModules = @('Terminal-Icons', 'posh-git', 'CompletionPredictor', 'Microsoft.WinGet.CommandNotFound')
foreach ($mod in $psModules) {
    $have = Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($have) {
        [Console]::WriteLine("  [+] PS module already present: $mod $($have.Version)")
        continue
    }
    try {
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
        [Console]::WriteLine("  [+] Installed PS module: $mod")
    } catch {
        [Console]::WriteLine("  [!] $mod install failed: $($_.Exception.Message)")
    }
}
'@

    if ($isPs7) {
        & ([scriptblock]::Create($modulesScript))
    } elseif ($pwshExe) {
        Write-Host "  [*] PS 5.1 host detected -- trampolining module install through pwsh 7 ($pwshExe)" -ForegroundColor DarkGray
        $bytes = [Text.Encoding]::Unicode.GetBytes($modulesScript)
        $enc = [Convert]::ToBase64String($bytes)
        & $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc
    } else {
        Write-Host "  [!] PS 5.1 host and no pwsh 7 found -- skipping CompletionPredictor/WinGet.CommandNotFound." -ForegroundColor Yellow
        Write-Host "      Install pwsh 7 then re-run irm|iex to pick up these modules." -ForegroundColor DarkGray
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] winget not available; skipping CLI extras." -ForegroundColor Yellow
        return
    }
    # SSOT: package list comes from the layered mios.toml chain.
    # Per operator "ALL Global packages SOURCE FROM THE TOML/HTML
    # FILE!!!" + "now how does changing the html change the toml
    # thats read by multiple scripts and components".
    #
    # Layered resolution order (highest → lowest precedence):
    #   1. M:\etc\mios\mios.toml          -- HOST overlay (where the
    #                                        Epiphany configurator
    #                                        saves; visible to BOTH
    #                                        Windows AND MiOS-DEV via
    #                                        /mnt/m/etc/mios/mios.toml)
    #   2. M:\usr\share\mios\mios.toml    -- VENDOR copy on M:\ if
    #                                        Phase 2 already cloned it
    #   3. raw.githubusercontent.com mios.git origin/main  -- COLD
    #                                        first-run path (no M:\
    #                                        yet)
    #
    # Each layer is checked; the first that yields a non-empty
    # [packages.windows] pkgs = [...] wins. This makes Pass 1 see
    # user edits made via the HTML configurator the moment they're
    # saved, the same way the Linux side sees them via /etc/mios/.
    $wingetTools = @()
    $tomlFetchOk = $false
    $tomlSource  = ''
    $tomlText    = $null
    foreach ($cand in @(
        @{ Path='M:\etc\mios\mios.toml';       Source='M:\etc\mios (host overlay)' },
        @{ Path='M:\usr\share\mios\mios.toml'; Source='M:\usr\share\mios (vendor on M:)' }
    )) {
        if (Test-Path -LiteralPath $cand.Path) {
            try {
                $tomlText   = Get-Content -LiteralPath $cand.Path -Raw -ErrorAction Stop
                $tomlSource = $cand.Source
                break
            } catch {}
        }
    }
    if (-not $tomlText) {
        try {
            $cb       = [int][double]::Parse((Get-Date -UFormat %s))
            $tomlUrl  = "https://raw.githubusercontent.com/mios-dev/MiOS/main/usr/share/mios/mios.toml?cb=$cb"
            $tomlText = Invoke-RestMethod -Uri $tomlUrl `
                -Headers @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' } `
                -ErrorAction Stop
            $tomlSource = 'origin/main (cold first-run)'
        } catch {}
    }
    try {
        if (-not $tomlText) { throw 'no toml source resolved' }
        # Regex-extract `[packages.windows] ... pkgs = [ ... ]`. Multiline
        # DOTALL across the TOML section. Stop at the next `[section]`
        # header so we don't accidentally swallow [packages.dev_vm_essentials]
        # right below.
        $rx = '(?ms)^\[packages\.windows\]\s*$.*?^\s*pkgs\s*=\s*\[(?<list>.*?)\]\s*$'
        $m  = [regex]::Match($tomlText, $rx)
        if ($m.Success) {
            # Strip TOML inline comments PER LINE first, then split by
            # comma. Doing it the other way around lets `# comment` text
            # bleed into the next entry because PS regex `$` without (?m)
            # matches end-of-string, eating across newlines.
            $stripped = ($m.Groups['list'].Value -split "`n" |
                         ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
            $wingetTools = @(
                $stripped -split ',' |
                ForEach-Object {
                    $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                    if ($s) { $s }
                }
            )
            if ($wingetTools.Count -gt 0) { $tomlFetchOk = $true }
        }
    } catch {
        Write-Host "  [!] Failed to fetch [packages.windows] from mios.toml: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "      Falling back to a minimal hardcoded set; re-run after fixing the network for the full SSOT list." -ForegroundColor DarkGray
    }
    if (-not $tomlFetchOk) {
        $wingetTools = @(
            'Git.Git', 'Microsoft.PowerShell', 'Microsoft.WSL',
            'Microsoft.WindowsTerminal', '7zip.7zip',
            'Microsoft.VCRedist.2015+.x64'
        )
    } else {
        Write-Host "  [+] Sourced $($wingetTools.Count) winget packages from $tomlSource [packages.windows]" -ForegroundColor DarkGray
    }
    foreach ($pkg in $wingetTools) {
        try {
            $probe = & winget list --id $pkg --exact 2>$null
            if ($LASTEXITCODE -eq 0 -and (($probe -join "`n") -match [regex]::Escape($pkg))) {
                Write-Host "  [+] winget package already present: $pkg" -ForegroundColor DarkGray
                continue
            }
            & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [+] Installed winget package: $pkg" -ForegroundColor Green
            }
        } catch {}
    }
}

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

    # MUST write the JSONC config without a UTF-8 BOM. fastfetch's
    # JSON parser is strict and rejects files starting with EF BB BF
    # ("Error: failed to parse JSON config file"). Set-Content
    # -Encoding UTF8 prepends a BOM on Windows PowerShell 5.1 and
    # pwsh's "UTF8" alias too. Use System.IO.File.WriteAllText with
    # an explicit no-BOM encoding to match what fastfetch expects.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($logoPath, $Script:MiosBrandingTxt, $utf8NoBom)

    # Bake the actual logo path into the JSONC -- escape backslashes
    # for the JSON string ("M:\\MiOS\\fastfetch\\mios.txt").
    $logoPathJson = $logoPath -replace '\\', '\\'
    $resolvedConfig = $Script:MiosFastfetchConfig -replace '__MIOS_LOGO__', $logoPathJson
    [System.IO.File]::WriteAllText($configPath, $resolvedConfig, $utf8NoBom)

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
    # Lift terminal dims from mios.toml [terminal] (per
    # feedback_mios_toml_html_global_dotfile -- mios.toml is THE
    # global dotfile). Vendor defaults: 80x30 (operator-defined MiOS
    # default) with frame at cols-1 / rows-1 so the dashboard fits
    # inside the borderless + scrollbar-less terminal without the
    # right border colliding with the line-wrap boundary.
    $_miosCols    = Get-MiosTomlValue -Section 'terminal' -Key 'cols'            -Default 80
    $_miosRows    = Get-MiosTomlValue -Section 'terminal' -Key 'rows'            -Default 20
    $_miosScroll  = Get-MiosTomlValue -Section 'terminal' -Key 'scrollback_rows' -Default 9000
    # frame_width default is COLS (full window width) so the framed
    # dashboard reaches both edges of the frameless terminal -- matching
    # the powerline which extends col 0 (leading rounded cap) to col 79
    # (trailing rounded cap). Operator-reported regression: "dashboard
    # framing is too narrow ... powerline doesn't reach the right side
    # (just like the dashboard framing)". The previous cols-2 default
    # left 2 cells of slack on the right edge. mios.toml [terminal].
    # frame_width is the SSOT; the configurator HTML exposes this for
    # operator override. frame_height stays rows-1 so one row is
    # reserved for the prompt under the dashboard.
    $_miosFrameW  = Get-MiosTomlValue -Section 'terminal' -Key 'frame_width'     -Default $_miosCols
    $_miosFrameH  = Get-MiosTomlValue -Section 'terminal' -Key 'frame_height'    -Default ($_miosRows - 1)
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

# ONCE-PER-SESSION GUARD. This script is dot-sourced from BOTH
# (a) the redirector in `$PROFILE.CurrentUserAllHosts AND
# (b) the WT MiOS profile's -Command preamble.
# Without this guard, both pathways fire Show-MiosDashboard +
# oh-my-posh init -- the operator sees TWO stacked framed
# dashboards. Session-scoped flag short-circuits subsequent calls.
if (`$Global:MiosProfileLoaded) { return }
`$Global:MiosProfileLoaded = `$true

# ── Window resize + center (every MiOS pwsh) ────────────────────
# Dimensions sourced from mios.toml [terminal] (cols/rows/
# scrollback_rows). Per feedback_mios_terminal_dimensions every
# MiOS-spawned window opens at the configured size centered on
# the active monitor. Apply BEFORE any output paints so the
# operator never sees a default-sized window briefly before the
# resize. Idempotent -- a second pass via the inner script
# (Pass-2 elevation) is a no-op.
#
# IMPORTANT GATE: only resize when we're actually in the MiOS APP
# context (i.e. the WT MiOS profile launched us). Otherwise -- if a
# child pwsh during BOOTSTRAP/INSTALL accidentally loads this profile
# via `$PROFILE.CurrentUserAllHosts redirector -- the resize shrinks
# the operator's 80x40 install conhost down to the 80x20 MiOS-app
# size mid-install. Operator-reported regression: "window changes to
# the MiOS Global sizes of 80x20 somewhere in the middle of the
# installations". `$env:MIOS_APP_CONTEXT is set ONLY by the WT MiOS
# profile commandline (see Install-MiOSTerminalProfile in Get-MiOS.ps1).
if (`$env:MIOS_APP_CONTEXT) {
    try {
        `$_curW = [Console]::WindowWidth
        if (`$_curW -gt $_miosCols) {
            [Console]::SetWindowSize($_miosCols, $_miosRows)
            [Console]::SetBufferSize($_miosCols, $_miosScroll)
        } else {
            [Console]::SetBufferSize($_miosCols, $_miosScroll)
            [Console]::SetWindowSize($_miosCols, $_miosRows)
        }
    } catch {}
}
if (`$env:MIOS_APP_CONTEXT) {
    try {
        Add-Type -Namespace MiosWin -Name N -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle rect);
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        `$_hwnd = [MiosWin.N]::GetConsoleWindow()
        `$_r = New-Object System.Drawing.Rectangle
        [MiosWin.N]::GetWindowRect(`$_hwnd, [ref]`$_r) | Out-Null
        `$_w = `$_r.Width  - `$_r.X
        `$_h = `$_r.Height - `$_r.Y
        # Center on the ACTIVE display (where the cursor currently is),
        # NOT PrimaryScreen. On multi-monitor hosts the operator launches
        # mios.bat from whichever monitor they're working on; the window
        # should land THERE.
        `$_cur = [System.Windows.Forms.Cursor]::Position
        `$_s   = [System.Windows.Forms.Screen]::FromPoint(`$_cur).WorkingArea
        `$_x = `$_s.X + [int](([math]::Max(0, `$_s.Width  - `$_w)) / 2)
        `$_y = `$_s.Y + [int](([math]::Max(0, `$_s.Height - `$_h)) / 2)
        [MiosWin.N]::MoveWindow(`$_hwnd, `$_x, `$_y, `$_w, `$_h, `$true) | Out-Null
    } catch {}
}

# NO TERMINAL-TYPE GATE. Always run the PSReadLine reload + oh-my-
# posh init. The WT_SESSION gate on the previous version was
# silently skipping the init when WT didn't set the env var early
# enough -- producing the "theme works in normal terminal but not
# MiOS Terminal" symptom. fastfetch is gated separately below
# since its ASCII rendering only makes sense in a real terminal.
if (`$true) {

    # ── Import terminal completion modules ────────────────────────
    # Silent best-effort: each module is imported if installed,
    # skipped if not. Operator gets icon-aware ls (Terminal-Icons),
    # git tab-completion (posh-git), AI-style prediction
    # (CompletionPredictor), and command-not-found suggestions
    # (Microsoft.WinGet.CommandNotFound).
    foreach (`$mod in @('Terminal-Icons','posh-git','CompletionPredictor','Microsoft.WinGet.CommandNotFound')) {
        if (Get-Module -ListAvailable -Name `$mod -ErrorAction SilentlyContinue) {
            try { Import-Module `$mod -ErrorAction SilentlyContinue } catch {}
        }
    }

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
        # Frame width: hardcoded to 78 so EVERY rendered frame visibly
        # leaves a 1-2 col margin on the right edge. Reading
        # Frame width sourced from mios.toml [terminal].frame_width
        # (default cols-1, see Get-MiOS.ps1 install-time substitution).
        # Per operator: "GLOBAL framing -1 width and height for fitting
        # piping/framing within the borderless and scrollbar-less MiOS
        # themed terminal window". cols-1 leaves 1 char of slack at the
        # right edge so the box-drawing border doesn't touch the
        # line-wrap boundary on hosts that lie about their width.
        # Frame width = MIN(live conhost width, mios.toml frame_width).
        # Operator-reported regression: "framing/dashboard is still
        # scattered/line wrapping (too wide still)". Earlier I had
        # WIDTH = MAX which auto-grew the frame to fill wider terminals
        # -- but on WT versions that report WindowWidth as N+1 (one cell
        # over the actual visible cell count) the frame's last char
        # wrapped to the next line, breaking each row across two visual
        # lines = "scattered" appearance. Capping at WindowWidth means
        # the frame NEVER exceeds the visible width; capping at TOML
        # frame_width means the frame respects the operator's chosen
        # max. Whichever is smaller wins.
        `$_winWNow = try { [Console]::WindowWidth } catch { $_miosFrameW }
        `$WIDTH = [math]::Min(`$_winWNow, $_miosFrameW)
        if (`$WIDTH -lt 20) { `$WIDTH = $_miosFrameW }   # safety floor
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

        # Total budget: frame_height rows total. Layout:
        #   1 top frame
        #   logo block       (compact: 0-1 row -- title only;
        #                     full:    N-row ASCII when budget allows)
        #   1 divider
        #   fastfetch block  (paired -- two modules per row)
        #   1 divider
        #   hints block      (compact: 1 line; full: 1-line-per-verb)
        #   1 bottom frame
        # Per operator: dashboard MUST fit in 80x20 (= frame_height 19).
        # Compact mode kicks in when frame_height < 25.
        `$_compact = $_miosFrameH -lt 25
        # Reserve rows for top + divider + divider + hints + bottom.
        # Compact hints = 1 row; full hints = 7 rows.
        `$_hintsRows  = if (`$_compact) { 1 } else { 7 }
        `$_overhead   = 1 + 1 + 1 + `$_hintsRows + 1   # top + 2 dividers + hints + bottom
        # Logo + fastfetch share whatever's left.
        `$_contentBudget = [math]::Max(2, $_miosFrameH - `$_overhead)
        # In compact mode skip the multi-line ASCII logo entirely; in
        # full mode allocate up to half the content budget to the logo.
        `$_logoBudget = if (`$_compact) { 1 } else { [math]::Min(11, [math]::Floor(`$_contentBudget / 2)) }
        `$_ffBudget   = `$_contentBudget - `$_logoBudget

        # Top frame.
        Write-Host (`$TL + (`$H * (`$WIDTH - 2)) + `$TR) -ForegroundColor Blue
        if (`$_compact) {
            # 1-line title band: "MiOS  --  Immutable Fedora AI Workstation"
            `$title = 'MiOS  --  Immutable Fedora AI Workstation'
            Write-Host (_Center `$title) -ForegroundColor Blue
        }
        elseif (Test-Path -LiteralPath `$LogoPath) {
            # Centered ASCII logo (operator-blue). Center the BLOCK (not
            # each line individually) -- the logo's internal alignment
            # depends on each line's leading whitespace.
            `$logoLines = @(Get-Content -LiteralPath `$LogoPath) | Where-Object { `$_ -ne `$null }
            # Cap to logo budget so we don't overflow on small frame_height.
            if (`$logoLines.Count -gt `$_logoBudget) {
                `$logoLines = `$logoLines[0..([math]::Max(0, `$_logoBudget - 1))]
            }
            `$maxLen = 0
            foreach (`$ll in `$logoLines) {
                `$len = (_Strip `$ll).Length
                if (`$len -gt `$maxLen) { `$maxLen = `$len }
            }
            `$blockLPad = ' ' * [math]::Max(0, [math]::Floor((`$INNER - `$maxLen) / 2))
            foreach (`$ll in `$logoLines) {
                `$stripped = _Strip `$ll
                `$rPad = ' ' * [math]::Max(0, `$maxLen - `$stripped.Length)
                Write-Host (_Frame (`$blockLPad + `$ll + `$rPad)) -ForegroundColor Blue
            }
        }
        # Divider.
        Write-Host (`$LT + (`$H * (`$WIDTH - 2)) + `$RT) -ForegroundColor Blue
        # Framed fastfetch (no logo -- we drew it above). Side-by-side
        # pairing: two consecutive lines that both fit in half the
        # interior width get emitted as a single row, saving vertical
        # rows. Cap rendered rows at `$_ffBudget so the dashboard fits
        # the configured frame_height even with a verbose fastfetch.
        if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
            try {
                `$ffOut = @(& fastfetch -c `$ConfigPath --logo none 2>&1 | Out-String -Stream | Where-Object { `$_ -ne `$null })
                `$ffOut = @(`$ffOut | Where-Object {
                    `$cleaned = (_Strip `$_).Trim()
                    if (-not `$cleaned) { return `$false }
                    if (`$cleaned -match '^[^:]+:\s*`$') { return `$false }
                    `$true
                })
                `$halfW = [int][math]::Floor((`$INNER - 3) / 2)
                `$i = 0
                `$rowsPrinted = 0
                while (`$i -lt `$ffOut.Count -and `$rowsPrinted -lt `$_ffBudget) {
                    `$cur = [string]`$ffOut[`$i]
                    `$curVis = (_Strip `$cur).TrimEnd()
                    if ([string]::IsNullOrWhiteSpace(`$curVis)) { `$i++; continue }
                    `$nxt = if ((`$i + 1) -lt `$ffOut.Count) { [string]`$ffOut[`$i+1] } else { `$null }
                    `$nxtVis = if (`$nxt) { (_Strip `$nxt).TrimEnd() } else { '' }
                    if (`$curVis.Length -le `$halfW -and `$nxt -and -not [string]::IsNullOrWhiteSpace(`$nxtVis) -and `$nxtVis.Length -le `$halfW) {
                        `$padL = ' ' * [math]::Max(1, `$halfW - `$curVis.Length)
                        `$combined = `$cur + `$padL + `$nxt
                        Write-Host (_Frame `$combined)
                        `$i += 2
                    } else {
                        Write-Host (_Frame `$cur)
                        `$i += 1
                    }
                    `$rowsPrinted++
                }
            } catch {
                Write-Host (_Frame "  fastfetch failed: `$(`$_.Exception.Message)")
            }
        } else {
            Write-Host (_Frame '  fastfetch not installed -- run mios-update to refresh.')
        }
        # ── Command hints rows ───────────────────────────────────
        # Verb list resolves through mios.toml [verbs] at RUNTIME (SSOT).
        # The dashboard re-reads on every render so an operator edit via
        # mios.html flows mios.toml -> dashboard immediately. No hard-
        # coding here. Vendor fallback only if every TOML candidate is
        # missing (cold first-run before M:\ overlay is staged).
        `$_verbDefs = @(
            @{ name='build';  desc='open mios.html, save, then build the OCI image' },
            @{ name='config'; desc='edit mios.toml in the HTML configurator (no build)' },
            @{ name='dash';   desc='show this dashboard (framed banner + fastfetch info)' },
            @{ name='dev';    desc='enter the MiOS-DEV podman machine' },
            @{ name='pull';   desc='sync M:\ overlay to origin/main' },
            @{ name='update'; desc='re-run the bootstrap (cache-busted)' },
            @{ name='help';   desc='list every verb' }
        )
        try {
            `$_tomlCands = @(
                (Join-Path `$env:USERPROFILE '.config\mios\mios.toml'),
                'M:\etc\mios\mios.toml',
                'M:\usr\share\mios\mios.toml',
                'C:\MiOS\usr\share\mios\mios.toml'
            )
            foreach (`$_tc in `$_tomlCands) {
                if (`$_tc -and (Test-Path -LiteralPath `$_tc)) {
                    `$_tt = Get-Content -LiteralPath `$_tc -Raw -ErrorAction SilentlyContinue
                    if (-not `$_tt) { continue }
                    `$_vb = [regex]::Match(`$_tt, '(?ms)^\[verbs\]\s*\r?\n(.*?)(?=^\[|\z)')
                    if (`$_vb.Success) {
                        `$_parsed = @()
                        foreach (`$_ln in (`$_vb.Groups[1].Value -split "``n")) {
                            `$_pm = [regex]::Match(`$_ln, '^\s*([a-z][a-z0-9_-]*)\s*=\s*\{[^}]*description\s*=\s*"([^"]+)"')
                            if (`$_pm.Success) { `$_parsed += @{ name=`$_pm.Groups[1].Value; desc=`$_pm.Groups[2].Value } }
                        }
                        if (`$_parsed.Count -gt 0) { `$_verbDefs = `$_parsed; break }
                    }
                }
            }
        } catch {}
        Write-Host (`$LT + (`$H * (`$WIDTH - 2)) + `$RT) -ForegroundColor Blue
        if (`$_compact) {
            `$_hint1 = ((`$_verbDefs | ForEach-Object { `$_.name }) -join '  ')
            Write-Host (_Center `$_hint1) -ForegroundColor DarkCyan
        } else {
            `$_maxName = ((`$_verbDefs | ForEach-Object { `$_.name.Length }) | Measure-Object -Maximum).Maximum
            foreach (`$_v in `$_verbDefs) {
                `$_pad = ' ' * (`$_maxName - `$_v.name.Length + 2)
                Write-Host (_Frame ('  mios ' + `$_v.name + `$_pad + '-- ' + `$_v.desc)) -ForegroundColor DarkCyan
            }
        }

        # Bottom frame.
        Write-Host (`$BL + (`$H * (`$WIDTH - 2)) + `$BR) -ForegroundColor Blue
    }

    # Dashboard auto-render. Drop the WT_SESSION gate -- with -NoProfile
    # in the MiOS WT profile commandline the operator's $PROFILE is
    # skipped entirely, so the only path into THIS script body IS the
    # MiOS terminal launch. Render whenever the host can paint AND the
    # operator hasn't opted out via $env:MIOS_SKIP_MOTD. fastfetch
    # availability is probed inside Show-MiosDashboard -- if missing,
    # the framed banner + verb-hints still render with a "fastfetch not
    # installed" placeholder row, so the operator sees the MiOS banner
    # even on a half-bootstrapped host.
    if (`$Host.UI.RawUI -and (-not `$env:MIOS_SKIP_MOTD)) {
        `$miosLogo   = _MiosSelfHeal 'fastfetch' 'mios.txt'      '$ffLogoBase64'
        `$miosFFCfg  = _MiosSelfHeal 'fastfetch' 'config.jsonc'  '$ffConfigBase64'
        if (`$miosLogo -and `$miosFFCfg) {
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
        # Shell-aware: oh-my-posh init pwsh emits PS 7+ syntax that
        # FAILS silently in Windows PowerShell 5.1, leaving the
        # operator's pre-existing broken init showing "CONFIG NOT
        # FOUND". Detect PS edition and use the matching arg
        # (`powershell` for 5.1 / Desktop, `pwsh` for 7+ / Core).
        `$_ompShell = if (`$PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
        `$ompInit = if (`$miosOmp -and (Test-Path -LiteralPath `$miosOmp)) {
            (oh-my-posh init `$_ompShell --config `$miosOmp) -join "``n"
        } else {
            (oh-my-posh init `$_ompShell) -join "``n"
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
    # New flow (per operator: "mios build should queue the build, launch
    # the html file in the local windows browser window, fetch the newly
    # minted html/toml files to the overlay >> start the build with new
    # key steps implemented"):
    #
    #   1. Open mios-config.html in the default Windows browser so the
    #      operator can edit theming / functionality / package lists.
    #   2. Wait for the operator to save + close the configurator (or
    #      hit Enter to skip the edit pass).
    #   3. mios-pull to sync M:\ overlay to origin/main + apply user edits.
    #   4. Run build-mios.ps1 -BuildOnly so it skips the bootstrap phase
    #      and goes straight into the OCI build inside MiOS-DEV.
    #
    # Bypass the configurator pass with: mios build -SkipConfig
    # Bypass the pull pass        with: mios build -SkipPull
    `$skipConfig = `$Args -contains '-SkipConfig'
    `$skipPull   = `$Args -contains '-SkipPull'
    `$forwardArgs = @(`$Args | Where-Object { `$_ -notin @('-SkipConfig','-SkipPull') })

    # ── Step 1 + 2: configurator pass ──────────────────────────────
    if (-not `$skipConfig) {
        `$cfgHtml = `$null
        foreach (`$c in @(
            'M:\usr\share\mios\configurator\mios.html',
            'M:\MiOS\usr\share\mios\configurator\mios.html',
            'C:\MiOS\usr\share\mios\configurator\mios.html'
        )) { if (Test-Path -LiteralPath `$c) { `$cfgHtml = `$c; break } }
        if (`$cfgHtml) {
            # Capture mtime BEFORE opening so we can tell if the operator
            # actually saved a new copy (the browser saves to Downloads
            # because file:// URLs can't write back to source). Used by
            # the promote step below.
            `$cfgMtimeBefore = (Get-Item -LiteralPath `$cfgHtml).LastWriteTimeUtc
            Write-Host ''
            Write-Host '  [1/4] Opening MiOS configurator in your browser...' -ForegroundColor Cyan
            Write-Host ('         '+`$cfgHtml) -ForegroundColor DarkGray
            Write-Host '         Edit values, click Save -> the browser writes mios.toml' -ForegroundColor DarkGray
            Write-Host '         to your Downloads folder (file:// URLs cannot write back).' -ForegroundColor DarkGray
            try { Start-Process `$cfgHtml | Out-Null } catch {}
            Write-Host ''
            Write-Host '  Press Enter when you''ve saved the configurator (or to skip the edit pass)...' -ForegroundColor Yellow -NoNewline
            `$null = Read-Host
        } else {
            Write-Host '  [!] Configurator HTML not found on M:\ or C:\MiOS -- skipping edit pass.' -ForegroundColor Yellow
            Write-Host '      Run `mios pull` first to seed the overlay.' -ForegroundColor DarkGray
        }

        # ── Step 2: promote downloaded mios.toml from Downloads ────
        # The browser saves to %USERPROFILE%\Downloads (file:// URLs
        # can't write back to source). Scan for any mios*.toml /
        # *mios*.html newer than the in-place overlay copies and
        # PROMOTE them to M:\etc\mios\ + M:\usr\share\mios\configurator\.
        # Also archive the imported source so we don't double-promote
        # on the next mios-build run.
        Write-Host ''
        Write-Host '  [2/4] Scanning Downloads for edited config files...' -ForegroundColor Cyan
        `$dlDir = Join-Path `$env:USERPROFILE 'Downloads'
        if (Test-Path -LiteralPath `$dlDir) {
            `$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            # mios.toml -> M:\etc\mios\mios.toml (+ /usr/share copy for
            # the dev VM via /mnt/m/etc/mios)
            `$tomlSrc = Get-ChildItem -LiteralPath `$dlDir -Filter 'mios*.toml' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if (`$tomlSrc) {
                `$tomlDst = 'M:\etc\mios\mios.toml'
                `$tomlPar = Split-Path -Parent `$tomlDst
                if (-not (Test-Path -LiteralPath `$tomlPar)) {
                    New-Item -ItemType Directory -Path `$tomlPar -Force | Out-Null
                }
                Copy-Item -LiteralPath `$tomlSrc.FullName -Destination `$tomlDst -Force
                Write-Host ('         [+] '+`$tomlSrc.Name+' -> '+`$tomlDst) -ForegroundColor Green
                # Also copy to M:\usr\share\mios so the layered overlay
                # picks it up even before mios-pull runs.
                `$tomlDst2 = 'M:\usr\share\mios\mios.toml'
                if (Test-Path -LiteralPath (Split-Path -Parent `$tomlDst2)) {
                    Copy-Item -LiteralPath `$tomlSrc.FullName -Destination `$tomlDst2 -Force
                    Write-Host ('         [+] '+`$tomlSrc.Name+' -> '+`$tomlDst2) -ForegroundColor Green
                }
                # Archive the source so a re-run of mios build doesn't
                # re-promote the same file. Keep it (don't delete) so
                # the operator can recover if something went wrong.
                `$archive = Join-Path `$dlDir (`$tomlSrc.BaseName+'.imported-'+`$stamp+'.toml')
                Move-Item -LiteralPath `$tomlSrc.FullName -Destination `$archive -Force
            } else {
                Write-Host '         [-] no mios*.toml in Downloads -- using existing overlay' -ForegroundColor DarkGray
            }
            # Also pick up an edited HTML configurator (rare; the
            # configurator emits TOML by default but operators may save
            # a hand-edited HTML).
            `$htmlSrc = Get-ChildItem -LiteralPath `$dlDir -Filter '*mios*.html' -File -ErrorAction SilentlyContinue |
                Where-Object { `$_.Name -notmatch '\.imported-' } |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if (`$htmlSrc) {
                `$htmlDst = 'M:\usr\share\mios\configurator\mios.html'
                `$htmlPar = Split-Path -Parent `$htmlDst
                if (-not (Test-Path -LiteralPath `$htmlPar)) {
                    New-Item -ItemType Directory -Path `$htmlPar -Force | Out-Null
                }
                Copy-Item -LiteralPath `$htmlSrc.FullName -Destination `$htmlDst -Force
                Write-Host ('         [+] '+`$htmlSrc.Name+' -> '+`$htmlDst) -ForegroundColor Green
                `$archive = Join-Path `$dlDir (`$htmlSrc.BaseName+'.imported-'+`$stamp+'.html')
                Move-Item -LiteralPath `$htmlSrc.FullName -Destination `$archive -Force
            }
        } else {
            Write-Host '         [-] '`$dlDir' does not exist -- skipping promote' -ForegroundColor DarkGray
        }
    }

    # ── Step 3: sync overlay so the build sees the latest mios.toml ─
    # Note: this runs AFTER the Downloads-promote step so mios-pull
    # sees the just-promoted files in M:\etc\mios. mios-pull's git
    # reset --hard would otherwise blow away the operator's changes
    # if they lived in the tracked tree.
    if (-not `$skipPull) {
        Write-Host ''
        Write-Host '  [3/4] Syncing M:\ overlay (mios.git + mios-bootstrap)...' -ForegroundColor Cyan
        try { mios-pull } catch { Write-Host "  [!] mios-pull failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow }
    }

    # ── Step 4: ignite the build ───────────────────────────────────
    Write-Host ''
    Write-Host '  [4/4] Running build pipeline (build-mios.ps1)...' -ForegroundColor Cyan
    `$env:MIOS_DASHBOARD_MODE = 'log'
    `$cb = [int][double]::Parse((Get-Date -UFormat %s))
    `$src = Invoke-RestMethod -Uri "`$Script:MiosBootstrapRaw/build-mios.ps1?cb=`$cb" -Headers @{ 'Cache-Control' = 'no-cache' }
    & ([scriptblock]::Create(`$src)) @forwardArgs
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
    `$cfg = if (Test-Path 'M:\usr\share\mios\configurator\mios.html') { 'M:\usr\share\mios\configurator\mios.html' }
           elseif (Test-Path 'C:\MiOS\usr\share\mios\configurator\mios.html') { 'C:\MiOS\usr\share\mios\configurator\mios.html' }
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

function mios-dash {
    # Live MiOS dashboard -- reads system state, framed banner +
    # fastfetch + service health. Wraps the bin script that
    # build-mios.ps1 stages at M:\MiOS\bin\mios-dash.ps1.
    `$dash = if (Test-Path 'M:\MiOS\bin\mios-dash.ps1') { 'M:\MiOS\bin\mios-dash.ps1' }
            elseif (Test-Path 'C:\MiOS\bin\mios-dash.ps1') { 'C:\MiOS\bin\mios-dash.ps1' }
            else { `$null }
    if (`$dash) {
        & `$dash
    } else {
        # Fall back to running Show-MiosDashboard inline since this
        # profile defined it.
        if (Get-Command Show-MiosDashboard -ErrorAction SilentlyContinue) {
            `$cfg  = if (Test-Path 'M:\MiOS\fastfetch\config.jsonc') { 'M:\MiOS\fastfetch\config.jsonc' } else { '' }
            `$logo = if (Test-Path 'M:\MiOS\fastfetch\mios.txt')      { 'M:\MiOS\fastfetch\mios.txt' }      else { '' }
            Show-MiosDashboard -ConfigPath `$cfg -LogoPath `$logo
        } else {
            Write-Host '  [!] mios-dash not available -- run mios-build to deploy it.' -ForegroundColor Yellow
        }
    }
}

function mios-help {
    Write-Host ''
    Write-Host '  MiOS commands' -ForegroundColor Cyan
    Write-Host '  -------------' -ForegroundColor DarkCyan
    Write-Host '  mios <verb>   unified dispatcher (tab-complete supported)' -ForegroundColor White
    Write-Host '                  or use mios-<verb> directly:' -ForegroundColor DarkGray
    Write-Host '  mios build    run the full MiOS OS bootstrap (WSL2 + podman + dev VM)' -ForegroundColor White
    Write-Host '  mios update   re-run Get-MiOS.ps1 (refresh terminal install)' -ForegroundColor White
    Write-Host '  mios pull     git fetch + hard reset M:\ to origin/main' -ForegroundColor White
    Write-Host '  mios config   open the HTML configurator (mios.toml editor)' -ForegroundColor White
    Write-Host '  mios dev      wsl into the MiOS-DEV distro (root /, user mios)' -ForegroundColor White
    Write-Host '  mios dash     live MiOS dashboard (services + fastfetch)' -ForegroundColor White
    Write-Host '  mios help     this list' -ForegroundColor White
    Write-Host ''
}

# Unified `mios <verb>` dispatcher. Operator types `mios build` or
# `mios b<TAB>` (PSReadLine + the ArgumentCompleter below complete to
# `mios build`). Falls through to `mios-<verb>` so the same wrappers
# back both call shapes.
function mios {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [ValidateSet('build','update','pull','config','dev','dash','help')]
        [string]`$Verb = 'help',
        [Parameter(ValueFromRemainingArguments)]
        `$Args
    )
    `$cmd = "mios-`$Verb"
    if (Get-Command `$cmd -ErrorAction SilentlyContinue) {
        & `$cmd @Args
    } else {
        Write-Host "  [!] mios: '`$Verb' is not a known verb. Try: mios help" -ForegroundColor Yellow
    }
}

# Tab-completion for `mios <verb>` so `mios b<TAB>` -> `mios build`.
Register-ArgumentCompleter -CommandName mios -ParameterName Verb -ScriptBlock {
    param(`$cmdName, `$paramName, `$wordToComplete, `$cmdAst, `$fakeBoundParam)
    @('build','update','pull','config','dev','dash','help') |
        Where-Object { `$_ -like "`$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
}
"@
    # Write the profile body with explicit UTF-8 BOM. The body contains
    # Unicode box-drawing chars (╭ ╮ ╰ ╯ │ ─ ├ ┤) for the dashboard
    # frame; without a BOM, PowerShell falls back to system codepage
    # (CP1252 on US Windows) when reading no-BOM files in some
    # contexts, parsing each UTF-8 byte as a separate Latin-1 char
    # and exploding with "Unexpected token 'â”€'" at parse time.
    # [IO.File]::WriteAllText with UTF8Encoding($true) writes the
    # 3-byte 0xEF 0xBB 0xBF BOM up front so EVERY PS host (5.1, 7.x,
    # ISE, VS Code) decodes the file as UTF-8 deterministically.
    $_utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($miosProfileScript, $miosScriptBody, $_utf8Bom)

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


# By the time we reach this point we're GUARANTEED admin -- the
# auto-elevation block at the top of the script (right after the
# agreement-gate function definition) returned out of Pass-1 if the
# operator pasted from a non-admin shell, and only Pass-2 (the elevated
# relaunch) ever falls through to here. Code below runs in Pass-2 only.

# ── Status helpers (used by Step-0 + Pass-2) ─────────────────────────────────
# Defined here -- BEFORE Pass-1's Step-0 M:\ block -- so the M:\ provisioning
# code can call Write-Info/Good/Err. Pass-2 (Clear-Host onwards) reuses these.
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

function Ensure-PodmanDesktop {
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Good "Podman already installed ($((podman --version) 2>&1))"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err "winget not found and podman not installed."
        Write-Err "  Install App Installer from the Microsoft Store, or install"
        Write-Err "  Podman Desktop manually from https://podman-desktop.io"
        exit 1
    }
    # Install Podman Desktop (the GUI). It bundles podman.exe inside its
    # resources tree -- but does NOT put it on PATH by default.
    Write-Info "Installing Podman Desktop via winget (RedHat.Podman-Desktop) ..."
    & winget install --exact --id RedHat.Podman-Desktop `
        --silent --accept-source-agreements --accept-package-agreements `
        --scope machine 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Retrying winget install at user scope ..."
        & winget install --exact --id RedHat.Podman-Desktop `
            --silent --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    # ALSO install RedHat.Podman (the CLI MSI) -- this is what actually
    # lays down podman.exe with PATH integration. Podman Desktop alone
    # bundles the CLI internally but doesn't expose it on PATH; the
    # standalone CLI package does. Idempotent: winget no-ops if already
    # present.
    Write-Info "Installing Podman CLI via winget (RedHat.Podman) ..."
    & winget install --exact --id RedHat.Podman `
        --silent --accept-source-agreements --accept-package-agreements `
        --scope machine 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Retrying CLI winget install at user scope ..."
        & winget install --exact --id RedHat.Podman `
            --silent --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    # Refresh PATH from registry so the just-installed podman.exe is
    # visible to Get-Command in THIS pwsh session.
    $env:PATH = `
        [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + `
        [Environment]::GetEnvironmentVariable('PATH','User')
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        # Probe ALL the locations where podman.exe might live: standalone
        # CLI install dir, Podman Desktop's resources bundle, the older
        # podman-machine standalone, plus any user-scope variants.
        $pmCandidates = @(
            (Join-Path ${env:ProgramFiles}      'RedHat\Podman\bin'),
            (Join-Path ${env:ProgramFiles}      'RedHat\Podman'),
            (Join-Path ${env:ProgramFiles}      'RedHat\Podman\resources\app\binary'),
            (Join-Path ${env:ProgramFiles}      'RedHat\Podman\resources\bin'),
            (Join-Path ${env:ProgramFiles(x86)} 'RedHat\Podman\bin'),
            (Join-Path $env:LOCALAPPDATA        'Programs\RedHat\Podman\bin'),
            (Join-Path $env:LOCALAPPDATA        'Programs\Podman\bin')
        )
        foreach ($cand in $pmCandidates) {
            if ($cand -and (Test-Path -LiteralPath (Join-Path $cand 'podman.exe'))) {
                Write-Info "Found podman.exe at $cand -- prepending to PATH"
                $env:PATH = "$cand;$env:PATH"
                # Persist on machine PATH too so future shells see it.
                try {
                    $machPath = [Environment]::GetEnvironmentVariable('PATH','Machine')
                    if (-not ($machPath -split ';' -contains $cand)) {
                        [Environment]::SetEnvironmentVariable('PATH', "$cand;$machPath", 'Machine')
                    }
                } catch {}
                break
            }
        }
        # Last resort: filesystem-walk Program Files for podman.exe.
        if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
            $found = Get-ChildItem -Path "${env:ProgramFiles}\RedHat","${env:LOCALAPPDATA}\Programs" `
                                   -Filter podman.exe -Recurse -ErrorAction SilentlyContinue -Depth 6 |
                     Select-Object -First 1
            if ($found) {
                $podmanDir = Split-Path -Parent $found.FullName
                Write-Info "Discovered podman.exe via search at $podmanDir -- prepending to PATH"
                $env:PATH = "$podmanDir;$env:PATH"
                try {
                    $machPath = [Environment]::GetEnvironmentVariable('PATH','Machine')
                    if (-not ($machPath -split ';' -contains $podmanDir)) {
                        [Environment]::SetEnvironmentVariable('PATH', "$podmanDir;$machPath", 'Machine')
                    }
                } catch {}
            }
        }
    }
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Good "Podman installed ($((podman --version) 2>&1))"
    } else {
        Write-Err "Podman installed but ``podman`` still not on PATH."
        Write-Err "  Probed: ${env:ProgramFiles}\RedHat\Podman\(bin|resources\app\binary|resources\bin),"
        Write-Err "          ${env:LOCALAPPDATA}\Programs\RedHat\Podman\bin"
        Write-Err "  Skipping CLI verification -- continuing with Pass-2 (build-mios.ps1 will"
        Write-Err "  resolve podman from its own probes inside the dev VM context)."
        # NOTE: do NOT exit 1 here. build-mios.ps1's Phase 2 (machine init)
        # talks to Podman Desktop's API directly via the WSL distro -- it
        # doesn't need podman.exe on the Windows-side PATH to function.
        # Per operator: "no 'restart this shell' or 're-run' anything!!!!
        # automated!!!!!"
    }
}

function Initialize-DataDisk {
    param(
        [int]$ShrinkMB     = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'shrink_mb'    -Default 262656),
        [string]$DriveLetter = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'drive_letter' -Default 'M'),
        [string]$VolumeLabel = $(Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'volume_label' -Default 'MIOS-DEV')
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
    $_displayGb = Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'display_size_gb' -Default 256
    Write-Info "Provisioning ${DriveLetter}:\ at $ShrinkMB MB (target $_displayGb GB visible in Explorer) ..."
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
    $_fs    = Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'filesystem'      -Default 'NTFS'
    $_alloc = Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'allocation_unit' -Default 4096
    $null = New-Partition -DiskNumber $disk.Number -Size $shrinkBytes -DriveLetter $DriveLetter -ErrorAction Stop
    $null = Format-Volume -DriveLetter $DriveLetter -FileSystem $_fs -NewFileSystemLabel $VolumeLabel `
        -AllocationUnitSize $_alloc -Confirm:$false -Force
    Write-Good "${DriveLetter}:\\ created (${ShrinkMB} MB NTFS, label=$VolumeLabel)"
}

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
        if (-not (Test-Path $parent)) { try { New-Item -ItemType Directory -Path $parent -Force | Out-Null } catch {} }
        if (Test-Path $p) {
            $item = Get-Item $p -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $current = ($item.Target -join '').TrimStart('\??\')
                $isSymlink = $item.LinkType -eq 'SymbolicLink'
                if ($current -ieq $MRoot -and $isSymlink) {
                    Write-Host "    [=] $p -> $MRoot (already symlinked)" -ForegroundColor DarkGray
                    continue
                }
                if ($current -ieq $MRoot -and -not $isSymlink) {
                    Write-Host "    [~] $p is a JUNCTION (legacy) -- recreating as symlink" -ForegroundColor DarkYellow
                }
                cmd /c "rmdir `"$p`"" 2>$null | Out-Null
            } else {
                $kids = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if ($kids -and $kids.Count -gt 0) {
                    Write-Host "    [*] moving existing $p contents to $MRoot ..." -ForegroundColor DarkGray
                    try {
                        foreach ($k in $kids) {
                            $dst = Join-Path $MRoot $k.Name
                            if (-not (Test-Path $dst)) { Move-Item -LiteralPath $k.FullName -Destination $MRoot -Force -ErrorAction Stop }
                        }
                    } catch { Write-Host "    [!] move failed for $p : $($_.Exception.Message) -- forcing remove" -ForegroundColor Yellow }
                }
                try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
                catch { Write-Host "    [!] couldn't remove $p (locked) -- skipping junction for this path" -ForegroundColor Yellow; continue }
            }
        }
        $rc = (cmd /c "mklink /D `"$p`" `"$MRoot`"" 2>&1)
        if ($LASTEXITCODE -eq 0) { Write-Host "    [+] symlinked $p -> $MRoot" -ForegroundColor DarkGray }
        else                      { Write-Host "    [!] mklink /D $p -> $MRoot failed: $rc" -ForegroundColor Yellow }
    }
}

function Set-WingetStorageOnM {
    param([string]$MRoot = 'M:\winget')
    if (-not (Test-Path $MRoot)) {
        New-Item -ItemType Directory -Path $MRoot -Force -ErrorAction Stop | Out-Null
        Write-Host "    [+] created $MRoot" -ForegroundColor DarkGray
    }
    foreach ($_sub in @('Packages','Cache','PortableLinks','PortablePackagesRoot','MachinePackages')) {
        $sd = Join-Path $MRoot $_sub
        if (-not (Test-Path $sd)) { New-Item -ItemType Directory -Path $sd -Force | Out-Null }
    }
    # Resolve %ProgramFiles% defensively -- on 64-bit Windows the
    # canonical machine WinGet path is "C:\Program Files\WinGet\Packages".
    $_pf = $env:ProgramFiles
    if (-not $_pf) { $_pf = $env:ProgramW6432 }
    if (-not $_pf) { $_pf = 'C:\Program Files' }
    $candidates = @(
        @{ Src = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages');             Dst = (Join-Path $MRoot 'Packages')             },
        @{ Src = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Cache');                Dst = (Join-Path $MRoot 'Cache')                },
        @{ Src = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links');                Dst = (Join-Path $MRoot 'PortableLinks')        },
        @{ Src = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Portable\PackagesRoot'); Dst = (Join-Path $MRoot 'PortablePackagesRoot') },
        # Machine-scope winget retry (used when --scope user fails -- e.g.
        # Microsoft.PowerShell, .NET runtimes, system-wide tools) lands
        # in %ProgramFiles%\WinGet\Packages. Junction to M:\ so machine-
        # scope installs ALSO end up on M:\.
        @{ Src = (Join-Path $_pf 'WinGet\Packages');                                    Dst = (Join-Path $MRoot 'MachinePackages')      }
    )
    foreach ($c in $candidates) {
        $p = $c.Src; $tgt = $c.Dst
        if (-not $p) { continue }
        $parent = Split-Path $p -Parent
        if (-not (Test-Path $parent)) { try { New-Item -ItemType Directory -Path $parent -Force | Out-Null } catch {} }
        if (Test-Path $p) {
            $item = Get-Item $p -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $current = ($item.Target -join '').TrimStart('\??\')
                if ($current -ieq $tgt) { Write-Host "    [=] $p -> $tgt (already linked)" -ForegroundColor DarkGray; continue }
                cmd /c "rmdir `"$p`"" 2>$null | Out-Null
            } else {
                $kids = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if ($kids -and $kids.Count -gt 0) {
                    Write-Host "    [*] moving existing $p contents to $tgt ..." -ForegroundColor DarkGray
                    try {
                        foreach ($k in $kids) {
                            $dst = Join-Path $tgt $k.Name
                            if (-not (Test-Path $dst)) { Move-Item -LiteralPath $k.FullName -Destination $tgt -Force -ErrorAction Stop }
                        }
                    } catch { Write-Host "    [!] move failed: $($_.Exception.Message) -- forcing remove" -ForegroundColor Yellow }
                }
                try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
                catch { Write-Host "    [!] couldn't remove $p (locked) -- skipping link for this path" -ForegroundColor Yellow; continue }
            }
        }
        $rc = (cmd /c "mklink /D `"$p`" `"$tgt`"" 2>&1)
        if ($LASTEXITCODE -eq 0) { Write-Host "    [+] symlinked $p -> $tgt" -ForegroundColor DarkGray }
        else                      { Write-Host "    [!] mklink /D $p -> $tgt failed: $rc" -ForegroundColor Yellow }
    }
}

# ── Step 0: M:\ provisioning BEFORE Pass-1 stages anything ───────────────────
# Per operator: "EVERYTHING MIOS RELATED--EVEN WINDOWS COMPONENTS INSTALLED--
# ARE ALL INSTALLED ON THE CREATED M:\ Drive/Partition!!!"
#
# Pass-1 below stages the WT MiOS profile, MiOS PS profile body, native-app
# launcher, fastfetch config, oh-my-posh theme. ALL of those have a "M:\ if
# exists else %USERPROFILE%\..." fallback -- without M:\ provisioned FIRST,
# files land on C:\ and Pass-2's later Initialize-DataDisk creates an empty
# M:\ partition while the staged content is stuck in C:\ (split state).
#
# This block creates M:\, junctions podman-machine + winget storage paths
# onto M:\, so Pass-1's WT install + winget tools install + profile staging
# all land on M:\ from the very first write. The Pass-2 calls to the same
# functions are idempotent no-ops.
Write-Host ''
Write-Host '  [*] Step 0: Provisioning M:\ partition + storage junctions...' -ForegroundColor Cyan
try { Initialize-DataDisk } catch { Write-Host "  [!] Initialize-DataDisk failed: $($_.Exception.Message)" -ForegroundColor Yellow }
try {
    Write-Info "Redirecting podman-machine storage to M:\\podman\\machine ..."
    Set-PodmanMachineStorageOnM
} catch { Write-Host "  [!] Set-PodmanMachineStorageOnM failed: $($_.Exception.Message)" -ForegroundColor Yellow }
try {
    Write-Info "Redirecting winget package storage to M:\\winget\\* ..."
    Set-WingetStorageOnM
} catch { Write-Host "  [!] Set-WingetStorageOnM failed: $($_.Exception.Message)" -ForegroundColor Yellow }

if ($true) {
    $isAdmin = $_isAdmin
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

    Write-Host "  [*] Step 1/7: Installing Windows Terminal (base) via winget..." -ForegroundColor Cyan
    if (-not (Install-MiOSWindowsTerminal)) {
        Write-Host "  [!] WT install failed -- bootstrap cannot continue without a themed WT to launch into." -ForegroundColor Red
        Write-Host "      Install manually and re-run: winget install Microsoft.WindowsTerminal" -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "  [*] Step 2/7: Installing PowerShell 7 (pwsh) BEFORE WT profile creation..." -ForegroundColor Cyan
    Install-MiOSPwsh7               | Out-Null
    Write-Host "  [*] Step 3/7: Patching WT settings.json with MiOS scheme + profiles..." -ForegroundColor Cyan
    Install-MiOSTerminalProfile     | Out-Null
    Write-Host "  [*] Step 4/7: Installing GeistMono Nerd Font (per-user, HKCU)..." -ForegroundColor Cyan
    Install-MiOSGeistFont           | Out-Null
    Write-Host "  [*] Step 5/7: Installing fastfetch + staging MiOS-themed config..." -ForegroundColor Cyan
    Install-MiOSFastfetch           | Out-Null
    Write-Host "  [*] Step 6/8: oh-my-posh + PSReadLine + mios.omp.json + profile wiring..." -ForegroundColor Cyan
    Update-MiOSOhMyPosh             | Out-Null
    Update-MiOSPSReadLine           | Out-Null
    Install-MiOSOhMyPoshTheme       | Out-Null
    Install-MiOSPowerShellProfile   | Out-Null
    Write-Host "  [*] Step 7/8: Installing terminal completion / UX modules..." -ForegroundColor Cyan
    Install-MiOSTerminalExtras      | Out-Null
    Write-Host "  [*] Step 8/8: Registering MiOS as a native Windows app..." -ForegroundColor Cyan
    Install-MiOSNativeApp           | Out-Null

    # Refresh $env:PATH from registry BEFORE dot-sourcing the profile.
    # winget just installed oh-my-posh / fastfetch / etc. and updated the
    # USER + MACHINE PATH, but the current pwsh session inherited the
    # PATH from the launching (non-admin) pwsh -- it does NOT see those
    # newly installed binaries. Without this refresh the profile body's
    # `oh-my-posh init pwsh | iex` silently no-ops and the prompt stays
    # vanilla; Show-MiosDashboard's `Get-Command fastfetch` returns null
    # and the dashboard never renders.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
    } catch {}

    # Mark this session as the MiOS terminal so the profile body's
    # WT_SESSION-or-TERM_PROGRAM=mios gate fires Show-MiosDashboard
    # (the elevated pwsh runs in conhost; WT_SESSION is unset).
    $env:TERM_PROGRAM = 'mios'

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

    # Steps 1-7 done -- WT, fonts, oh-my-posh, fastfetch, native app
    # all live under the OPERATOR's user profile (HKCU, OneDrive,
    # %LOCALAPPDATA%, per-user Start Menu). Bootstrap below
    # (Initialize-DataDisk + bootstrap.ps1) needs ADMIN to shrink C:\
    # and machine-scope-winget-install Podman Desktop. UAC-spawn an
    # elevated pwsh that re-fetches Get-MiOS.ps1 with
    # MIOS_GETMIOS_RELAUNCHED=1, which causes the inner call to
    # SKIP this Pass-1 block entirely (no font reinstall) and
    # fall through to the Pass-2 path (lines below this if-block --
    # M:\ provisioning + bootstrap.ps1 hand-off).
    Write-Host ''
    Write-Host '+============================================================+' -ForegroundColor Cyan
    Write-Host '|  MiOS user-scope setup complete.                           |' -ForegroundColor Cyan
    Write-Host '|  Continuing with admin steps (M:\ + Podman + dev VM)...    |' -ForegroundColor Cyan
    Write-Host '+============================================================+' -ForegroundColor Cyan
    Write-Host ''
    if ($isAdmin) {
        # Already admin -- fall through to the admin-scope code below
        # (M:\ provisioning + bootstrap.ps1 hand-off). No relaunch.
    } else {
        # SHOULD BE UNREACHABLE: the auto-elevation block at script
        # entry (line ~2317) re-launches with admin token if not admin.
        # Defensive fallback only -- if we got here, the auto-elevate
        # path didn't trigger for some reason (manual MIOS_GETMIOS_
        # RELAUNCHED=1 env override, etc.). Surface a clear error.
        Write-Host '  [!] Reached admin-only code without admin token.' -ForegroundColor Red
        Write-Host '      Re-run from a fresh pwsh window so the auto-elevation prompt fires.' -ForegroundColor DarkGray
        return
        # Dead code below (kept for fallback if auto-elevation is ever
        # disabled). Reachable only if `return` above is removed.
        $rawUrl = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1?cb=$([int][double]::Parse((Get-Date -UFormat %s)))"
        # Pass-2 inner script: first action is to size the console to 80x30
        # and center it on the primary monitor, BEFORE any output runs (so the
        # operator never sees a default 120x30 window briefly before resize).
        # `[Console]::SetWindowSize` covers conhost; the Win32 SetWindowPos
        # call covers conhost AND WT's pseudo-console (WT honors the absolute
        # client-area sizing on its parent HWND).
        $innerCmd = @"
# Resize + center BEFORE anything else paints.
try {
    `$_curW = [Console]::WindowWidth
    if (`$_curW -gt 80) {
        [Console]::SetWindowSize(80, 30)
        [Console]::SetBufferSize(80, 9000)
    } else {
        [Console]::SetBufferSize(80, 9000)
        [Console]::SetWindowSize(80, 30)
    }
} catch {}
try {
    Add-Type -Namespace MiosWin -Name N -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int x, int y, int w, int h, bool repaint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out System.Drawing.Rectangle rect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDesktopWindow();
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    `$hwnd = [MiosWin.N]::GetConsoleWindow()
    `$dummy = New-Object System.Drawing.Rectangle
    [MiosWin.N]::GetWindowRect(`$hwnd, [ref]`$dummy) | Out-Null
    `$winW = `$dummy.Width  - `$dummy.X
    `$winH = `$dummy.Height - `$dummy.Y
    # Center on the ACTIVE display (cursor position), not PrimaryScreen.
    `$cur = [System.Windows.Forms.Cursor]::Position
    `$screen = [System.Windows.Forms.Screen]::FromPoint(`$cur).WorkingArea
    `$x = `$screen.X + [int](([math]::Max(0, `$screen.Width  - `$winW)) / 2)
    `$y = `$screen.Y + [int](([math]::Max(0, `$screen.Height - `$winH)) / 2)
    [MiosWin.N]::MoveWindow(`$hwnd, `$x, `$y, `$winW, `$winH, `$true) | Out-Null
} catch {}

`$env:MIOS_GETMIOS_RELAUNCHED='1'
`$env:MIOS_AGREEMENT_ACK='accepted'
try {
    `$noCacheHdr = @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' }
    `$src = Invoke-RestMethod -Uri '$rawUrl' -Headers `$noCacheHdr -ErrorAction Stop
    & ([scriptblock]::Create(`$src))
} catch {
    Write-Host ''
    Write-Host ('  [!] Bootstrap failed: ' + `$_) -ForegroundColor Red
    Write-Host ''
}
Write-Host ''
Write-Host '  Press Enter to close...' -ForegroundColor DarkGray -NoNewline
`$null = Read-Host
"@
        $innerBytes   = [Text.Encoding]::Unicode.GetBytes($innerCmd)
        $innerEncoded = [Convert]::ToBase64String($innerBytes)
        # Resolve a directly-launchable pwsh (skip WindowsApps\ -- the
        # Store install's TrustedInstaller ACL blocks Start-Process
        # -Verb RunAs there).
        $shell = $null
        foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe","$env:ProgramW6432\PowerShell\7\pwsh.exe")) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $shell = $c; break }
        }
        if (-not $shell) {
            $w51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
            if (Test-Path -LiteralPath $w51 -PathType Leaf) { $shell = $w51 }
        }
        if (-not $shell) { $shell = 'powershell.exe' }
        # NB: -NoProfile is INTENTIONALLY OMITTED. Per operator
        # ("launch with the same themes and settings as Global MiOS
        # Dashboards with oh my posh piping--etc--everything!!"), the
        # Pass-2 elevated window must load the MiOS PowerShell profile
        # body (M:\MiOS\powershell\profile.ps1) so it gets:
        #   * the resize+center preamble (every MiOS pwsh dashboard sized)
        #   * Show-MiosDashboard (framed banner + fastfetch info)
        #   * oh-my-posh init with the MiOS theme
        #   * mios-* command shims (mios-build, mios-pull, etc.)
        # The once-per-session guard ($Global:MiosProfileLoaded) keeps
        # the profile from rendering twice when WT also fires it.
        $shellArgs = @('-NoLogo','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand', $innerEncoded)

        # NB: previous attempt to launch via `wt.exe new-window
        # --profile MiOS pwsh ...` with `-Verb RunAs` returned
        # 0x80070002 ERROR_FILE_NOT_FOUND on Windows 11 -- appx-packaged
        # WT + UAC + complex argv combine badly under ShellExecuteEx.
        # Fall back to bare pwsh elevation. The user's default terminal
        # host (conhost or WT) decides where the elevated process
        # lands. Either way, the MiOS PS profile body still loads
        # in-process via $PROFILE.CurrentUserAllHosts redirector, so
        # oh-my-posh + Show-MiosDashboard render automatically -- the
        # operator gets the MiOS terminal experience regardless of
        # which host paints the chrome.
        # If WT is the operator's default-terminal-host (Windows 11
        # 22H2+ default), the elevated pwsh lands in WT with the
        # operator's default profile (PowerShell). To get the MiOS WT
        # profile inside an already-elevated pwsh, the operator can
        # run `wt -p MiOS` from that elevated session -- no second UAC.
        try {
            Start-Process -FilePath $shell -ArgumentList $shellArgs `
                -Verb RunAs -WorkingDirectory $env:WINDIR -ErrorAction Stop
            Write-Host '  [+] Elevated bootstrap window opened. Continuing the install there.' -ForegroundColor Green
        } catch {
            Write-Host "  [!] Self-elevation failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '      Open an elevated PowerShell manually and re-run:' -ForegroundColor DarkGray
            Write-Host "        irm $rawUrl | iex" -ForegroundColor DarkGray
        }
        Write-Host ''
        return
    }

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

# 3. Helpers (Write-Info / Write-Good / Write-Err / Require-Cmd /
# Ensure-PodmanDesktop) and the M:\ provisioning functions
# (Initialize-DataDisk / Set-PodmanMachineStorageOnM /
# Set-WingetStorageOnM) are defined ABOVE Pass-1 now (so Step 0 can
# create M:\ before Pass-1 stages files). Their original definitions
# moved up; this section header retained for orientation.

Clear-Host
Write-Host "MiOS Bootstrap (irm | iex web entry)" -ForegroundColor Cyan
Write-Host "------------------------------------" -ForegroundColor Cyan

# 4. Prerequisites
#
# Podman Desktop is no longer a "Require-Cmd or die" gate -- mios.bat
# self-elevates so we have admin here, which means winget can install
# RedHat.Podman-Desktop unattended without bouncing the operator out
# to a browser. Latest stable (per memory: target latest) -- no
# version pin, winget picks whatever the manifest currently advertises.
Require-Cmd "git"    "Install Git from https://git-scm.com/download/win"
Ensure-PodmanDesktop
Write-Good "Prerequisites OK (git, podman)"

# Initialize-DataDisk + Set-PodmanMachineStorageOnM + Set-WingetStorageOnM
# are defined ABOVE (before Pass-1) so Step 0 can call them BEFORE Pass-1
# stages files. Their original definitions moved up; this header retained
# for orientation.

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
# Junction every winget package storage path onto M:\ so winget-installed
# CLIs (oh-my-posh, fastfetch, fd, ripgrep, jq, btop4win, etc.) land on
# the dedicated MIOS-DEV partition rather than scattering across
# %LOCALAPPDATA% and %PROGRAMFILES%. Per operator: "winget should be
# installing EVERYTHING to the M:\ partition for ease of uninstallations".
#
# Carve-outs (NOT relocatable):
#   - Windows Terminal (appx-packaged UWP, lives in WindowsApps)
#   - Podman Desktop (machine-scope MSI, lives in Program Files)
# These two stay where Microsoft / RedHat installed them; everything
# else (per-user winget package cache + per-user manifest cache + the
# winget portable-app stash) gets symlinked to M:\winget\*.
#
# Same symlink-not-junction discipline as podman storage paths above:
# mklink /D, not /J. winget's link resolver follows symlinks; some
# uninstallers fail on junction targets.
#
# Runs BEFORE any winget install so the very first install's package
# directory creation lands on M:\ from the start. If we redirect
# AFTER winget has already created the dirs, we'd need to move the
# contents over -- doable but racy. Idempotent: re-runs are no-ops if
# the symlinks already point at M:\.
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

# Step 0 above (before Pass-1) ALREADY provisioned M:\ + symlinked
# podman-machine + winget package storage onto M:\. Pass-1's winget
# tools install + WT install + profile staging all landed on M:\
# from the very first write. The Initialize-DataDisk + storage-junction
# functions are idempotent, so this comment block stands as a marker
# of where the late-bound calls USED to live -- they're no longer needed.

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
