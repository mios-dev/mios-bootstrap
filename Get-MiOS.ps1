# AI-hint: Primary entry point for MiOS installation; handles admin elevation, environment validation, and fresh-clone of the bootstrap repo to initiate the preflight, VM setup, and OCI build pipeline.
# AI-related: /usr/share/mios/mios.toml, /etc/mios/mios.toml, /etc/mios/., /usr/share/mios/branding/mios.txt, /usr/share/mios/branding/mios, mios-dev, mios-bootstrap, mios-pull, mios-launch, mios-install
# AI-functions: Disable-ConsoleQuickEdit, Resolve-MiosTomlText, Get-MiosTomlValue, Show-MiOSBanner, Show-MiOSAgreement, Invoke-MiOSAgreementGate, _Center-MiOSGateConsole, Get-MiosPalette, _hex, Test-MiOSFontInstalled, Wait-MiOSWindowsTerminalReady, Ensure-MiOSWinget
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

# Disable console QuickEdit immediately so an accidental click/select in the
# (elevated) window can't freeze the installer on its next write -- Windows
# "mark" mode blocks the process until Enter/Esc is pressed (a click
# during the long install read as a dead hang). build-mios.ps1 re-applies this;
# the type guard makes the second call a no-op. Best-effort; never fatal.
function Disable-ConsoleQuickEdit {
    try {
        if (-not ('MiosConsole.Win32' -as [type])) {
            Add-Type -Namespace MiosConsole -Name Win32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern System.IntPtr GetStdHandle(int nStdHandle); [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode); [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);' -ErrorAction Stop
        }
        $h = [MiosConsole.Win32]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        [uint32]$mode = 0
        if ([MiosConsole.Win32]::GetConsoleMode($h, [ref]$mode)) {
            $mode = ($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80   # -QUICK_EDIT +EXTENDED_FLAGS
            [void][MiosConsole.Win32]::SetConsoleMode($h, $mode)
        }
    } catch {}
}
Disable-ConsoleQuickEdit

# -- Self-cache-bust on entry ------------------------------------------------
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
# -- Resize + center the OUTER WinR pwsh window before anything paints ------
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

# -- Cleanup of stale legacy profile body BEFORE anything else ----------------
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

# -- mios.toml reader (Get-MiOS.ps1 = ALWAYS web-only) -------------------------
# mios.toml is THE global dotfile (per feedback_mios_toml_html_global_dotfile
# memory). EVERY tunable -- window dims, M:\ size, font, AumID, retry
# delays, theming, package lists -- sources from here. The HTML
# configurator edits mios.toml; every consumer reads from it.
#
# This file (Get-MiOS.ps1) is the BOOTSTRAP entry -- invoked via
# `irm | iex` for clean installs and via `mios update` for forced
# refresh. Per operator architectural rule
#
#   "ORIGIN = web entries/repos only -- no fallback to M:\ or
#    anywhere else -- unless origin has been pulled and it's a
#    simple 'mios build' -- that can pull from M:\ as it'd already
#    exist -- then 'mios update' would ALWAYS pull from web
#    regardless of clean entry, updating, etc-etc!!!"
#
# Get-MiOS.ps1 is BOTH the clean entry AND what mios update re-runs,
# so EVERY read here is web-only.  M:\ overlays / ~/.config user
# overrides are honored by build-mios.ps1's `mios build` flow (which
# is downstream of mios-pull and assumes M:\ is current), NOT by the
# bootstrap itself.  Mixing the two would let a stale M:\ silently
# override a web fetch, defeating the "clean entry forces refresh"
# guarantee.
#
# Vendor defaults are sufficient (per feedback_mios_defaults_baseline):
# the stack works with no user toml present. Get-MiosTomlValue returns
# its `-Default` arg if the key is missing anywhere.
$script:_MiosTomlCache = @{}

function Resolve-MiosTomlText {
    if ($script:_MiosTomlCache.ContainsKey('_text') -and $script:_MiosTomlCache['_text']) {
        return $script:_MiosTomlCache['_text']
    }
    # Local fallback for development/testing
    $localToml = "C:\mios-bootstrap\mios.toml"
    if (Test-Path $localToml) {
        try {
            $script:_MiosTomlCache['_text'] = [IO.File]::ReadAllText($localToml, (New-Object System.Text.UTF8Encoding($false)))
            $script:_MiosTomlCache['_source'] = "local ($localToml)"
            return $script:_MiosTomlCache['_text']
        } catch {}
    }
    # Web only -- no local fallback.  See header comment for the rule.
    try {
        $cb  = [int][double]::Parse((Get-Date -UFormat %s))
        $url = "https://raw.githubusercontent.com/mios-dev/MiOS/main/usr/share/mios/mios.toml?cb=$cb"
        # Use IWR not IRM so the response body comes back as raw text
        # regardless of Content-Type (raw.githubusercontent.com sometimes
        # serves .toml as application/octet-stream which IRM can't decode).
        $resp = Invoke-WebRequest -Uri $url `
            -Headers @{ 'Cache-Control'='no-cache, no-store, max-age=0'; 'Pragma'='no-cache' } `
            -UseBasicParsing -ErrorAction Stop
        if ($resp.Content -is [byte[]]) {
            $script:_MiosTomlCache['_text'] = [System.Text.Encoding]::UTF8.GetString($resp.Content)
        } else {
            $script:_MiosTomlCache['_text'] = [string]$resp.Content
        }
        $script:_MiosTomlCache['_source'] = "origin/main (web)"
        return $script:_MiosTomlCache['_text']
    } catch {
        $script:_MiosTomlCache['_text']   = ''
        $script:_MiosTomlCache['_source'] = '(unreachable -- vendor defaults only)'
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
            # Sentinel uses [char]0x01 (literal SOH byte) instead of the
            # PS 7-only `` `u{0001} `` syntax -- PS 5.1 treats `` `u ``
            # as just literal "u", which leaked the placeholder
            # `u{0001}BS` (visible) into rendered strings.  Operator
            # "Initializing mios.git as the M:u{0001}BSu{0001}
            # working tree".  [char]0x01 works in both PS 5.1 and PS 7+.
            $_bs = [string][char]0x01 + 'BS' + [string][char]0x01
            $inner = $raw.Substring(1, $raw.Length - 2)
            $inner = $inner -replace '\\\\', $_bs   # placeholder for literal backslash
            $inner = $inner -replace '\\"', '"'
            $inner = $inner -replace '\\n', "`n"
            $inner = $inner -replace '\\t', "`t"
            $inner = $inner -replace '\\r', "`r"
            $inner = $inner -replace [regex]::Escape($_bs), '\'
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

# -- Canonical origin URLs (SSOT: [bootstrap] mios_repo / bootstrap_repo) ------
# ONE source for every web fetch below. Resolved once from mios.toml so an
# operator override of the repo owner/name/ref flows to all download sites; the
# vendor defaults match the [bootstrap] keys. Raw-content bases are DERIVED from
# the .git clone URLs (github.com host -> raw.githubusercontent.com, drop the
# trailing .git, append the ref) so the owner/name live in exactly one place.
# Script-scoped + assigned AFTER Get-MiosTomlValue is defined; the fetch
# functions above resolve these at call time (which is always later). The two
# root chicken-egg fetches that pull mios.toml / Get-MiOS.ps1 itself keep their
# inline literal -- they run before any toml exists and ARE the documented
# vendor default these vars fall back to.
function ConvertTo-MiosRawBase {
    param([Parameter(Mandatory)][string]$GitUrl, [Parameter(Mandatory)][string]$Ref)
    if ($GitUrl -match '^[A-Za-z]:') {
        return $GitUrl
    }
    $base = $GitUrl -replace '^https://github\.com/', 'https://raw.githubusercontent.com/' -replace '\.git$', ''
    return "$base/$Ref"
}
$Script:MiosRepoUrl      = Get-MiosTomlValue -Section 'bootstrap' -Key 'mios_repo'      -Default 'https://github.com/mios-dev/MiOS.git'
$Script:MiosBootstrapUrl = Get-MiosTomlValue -Section 'bootstrap' -Key 'bootstrap_repo' -Default 'https://github.com/mios-dev/mios-bootstrap.git'
$Script:MiosRef          = Get-MiosTomlValue -Section 'bootstrap' -Key 'mios_ref'       -Default 'main'
$Script:MiosBootstrapRef = Get-MiosTomlValue -Section 'bootstrap' -Key 'bootstrap_ref'  -Default 'main'
$Script:MiosRawBase      = ConvertTo-MiosRawBase $Script:MiosRepoUrl      $Script:MiosRef          # vendor mios.git raw tree base
$Script:MiosBootstrapRaw = ConvertTo-MiosRawBase $Script:MiosBootstrapUrl $Script:MiosBootstrapRef  # bootstrap repo raw tree base

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
    # CP437/CP1252 mangles ++++|- to `?`. Callers must set codepage
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
    $sub = if ($Subtitle) { $Subtitle } else { Get-MiosTomlValue -Section 'branding' -Key 'tagline_app' -Default (Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'My Personal Operating System') }
    # Width: cols - right_margin - 2 frame chars. SSOT from mios.toml.
    # Operator reported "framing too wide STILL" at the previous hard-
    # coded inner=78 (total=80) -- that totaled the entire 80-col
    # terminal width with no slack, and WT's pseudo-console
    # over-reports by 1 cell during the first paint, so the right
    # frame char wrapped. inner = cols - right_margin - 2 always
    # leaves right_margin cells of slack on the right edge.
    $_bCols      = Get-MiosTomlValue -Section 'terminal.install' -Key 'cols'         -Default (Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80)
    # "dashboards should be edge to edge globally!!
    # 80x20 window is the Global benchmark!". right_margin=0 means the
    # frame paints col 1..N where N = WindowWidth, edge-to-edge.
    # Canonical launches use mios-launch.exe with --focus so WT runs in
    # true 80x20 cells with no chrome reservation. Non-focus launches
    # (operator opens WT profile directly) have chrome that eats cells
    # -- in those cases the operator can override right_margin via
    # mios.toml [terminal].right_margin.
    $_bRightMgn  = Get-MiosTomlValue -Section 'terminal'         -Key 'right_margin' -Default 0
    $inner = [math]::Max(20, $_bCols - $_bRightMgn - 2)
    # Block-center: pad every art line by the SAME left-pad so internal
    # diagonal alignment is preserved.
    $maxArt = ($art | Measure-Object -Property Length -Maximum).Maximum
    $blockL = ' ' * [math]::Max(0, [math]::Floor(($inner - $maxArt) / 2))
    # Subtitle centered on its own (different width than the art block).
    $subPad = [math]::Max(0, $inner - $sub.Length)
    $subL = ' ' * [math]::Floor($subPad / 2)
    $subR = ' ' * ($subPad - [math]::Floor($subPad / 2))
    # PS 5.1 (Windows PowerShell -- the ONLY shell on a fresh Windows) does
    # NOT define [char] * [int]: it throws "the operation '[System.Char] *
    # [System.Int32]' is not defined" and kills the whole elevated bootstrap
    # before the agreement gate can even render. pwsh 7 silently promotes the
    # char to a string and repeats it; 5.1 does not. Cast to a string FIRST so
    # the horizontal rule repeats identically on both shells. (char + string
    # concatenation IS fine in 5.1 -- only the multiply was undefined.)
    # install-robustness.
    $_hbar  = ([char]0x2500).ToString() * $inner
    $top    = [char]0x256d + $_hbar + [char]0x256e
    $bottom = [char]0x2570 + $_hbar + [char]0x256f
    $rows = @($top)
    foreach ($a in $art) {
        $line = $blockL + $a
        # Right-pad to fill inner width.
        $line = $line + (' ' * [math]::Max(0, $inner - $line.Length))
        $rows += [char]0x2502 + $line + [char]0x2502
    }
    $rows += [char]0x2502 + $subL + $sub + $subR + [char]0x2502
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
    # Drop the banner block at the top (lines until the closing +...+).
    $strip = 0
    for ($i = 0; $i -lt $bodyLines.Count; $i++) {
        if ($bodyLines[$i].StartsWith([char]0x2570)) { $strip = $i + 1; break }
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
# -- Auto-elevate at script entry (single UAC) -----------------------
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
    # Pass-1 -> Pass-2 UAC handoff prompt strings resolve through
    # mios.toml [messages.elevation] (SSOT).  Operator rebrands via
    # mios.html.  Vendor defaults below are the cold-fallback set
    # when no toml is reachable yet (this runs BEFORE M:\ overlay
    # exists on first install).
    $_eAdmin = Get-MiosTomlValue -Section 'messages.elevation' -Key 'admin_required'   -Default '  [*] MiOS bootstrap requires admin (M:\ partition + Podman + dev VM).'
    $_eUac1  = Get-MiosTomlValue -Section 'messages.elevation' -Key 'uac_trigger_line' -Default '  [*] Triggering UAC -- accept to continue. The install will then run'
    $_eUac2  = Get-MiosTomlValue -Section 'messages.elevation' -Key 'uac_trigger_hint' -Default '      in the elevated window, single prompt only.'
    Write-Host $_eAdmin -ForegroundColor Cyan
    Write-Host $_eUac1  -ForegroundColor Cyan
    Write-Host $_eUac2  -ForegroundColor DarkGray
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
    $_rawUrl = "$($Script:MiosBootstrapRaw)/Get-MiOS.ps1?cb=$([int][double]::Parse((Get-Date -UFormat %s)))"
    # Pass-2 exit-message strings resolved at install time from
    # mios.toml [messages.pass2_exit] (SSOT). Baked as literals into
    # the inner-cmd heredoc below.  Single-quote the values + escape
    # single-quotes so the heredoc-substituted text is a valid PS
    # literal regardless of operator-supplied content.
    $_p2ExitedPrefix     = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'exited_code_prefix'   -Default '  [!] Bootstrap exited with code ') -replace "'", "''"
    $_p2FailureDtl       = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'failure_detail'       -Default '      Output above is the failure detail (Pass-1 has no separate log).') -replace "'", "''"
    $_p2BuildLogHnt      = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'build_log_hint'       -Default "      build-mios.ps1's own log at M:\MiOS\logs\mios-install-*.log only kicks in on Pass-2 success.") -replace "'", "''"
    $_p2FetchFailed      = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'fetch_run_failed'     -Default '  [!] Bootstrap fetch/run failed: ') -replace "'", "''"
    $_p2PressEnter       = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'press_enter_close'    -Default '  Press Enter to close this elevated bootstrap window...') -replace "'", "''"
    $_p2SuccessTrans     = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'success_transition'   -Default '  [+] Bootstrap complete. Loading MiOS terminal in this window...') -replace "'", "''"
    $_p2ProfileFailed    = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'profile_load_failed'  -Default '  [!] MiOS profile load failed: ') -replace "'", "''"
    $_p2ProfileFailedHnt = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'profile_load_hint'    -Default '      Open a fresh MiOS shortcut to retry.') -replace "'", "''"
    $_p2ProfileMissing   = (Get-MiosTomlValue -Section 'messages.pass2_exit' -Key 'profile_missing'      -Default '  [!] M:\MiOS\powershell\profile.ps1 not found -- open the MiOS shortcut to launch the app window.') -replace "'", "''"
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
# Unicode box-drawing glyphs (+ + + + | - + +) render as `?`. Setting
# OutputEncoding alone isn't enough -- chcp 65001 changes the active
# codepage for the underlying console, which is what affects glyph
# substitution.
try { & chcp.com 65001 *> `$null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}
# Pass-2 transcript -- the early elevated window was historically UNLOGGED
# (operator: "the incorrectly launched powershell window just dies silently
# --seemingly no logs in sight!!!"). Start a transcript NOW so ANY early
# failure (IRM fetch, scriptblock parse/throw, agreement gate, a preflight
# 'exit', or a bare error) lands in a readable file. build-mios.ps1 opens
# its own mios-install-*.log later; this closes the gap BEFORE that on the
# Pass-2 critical path. install-robustness.
try {
    `$_p2LogDir = if (Test-Path 'M:\') { 'M:\MiOS\logs' } else { Join-Path `$env:TEMP 'mios-logs' }
    if (-not (Test-Path `$_p2LogDir)) { New-Item -ItemType Directory -Force -Path `$_p2LogDir | Out-Null }
    `$_p2Log = Join-Path `$_p2LogDir ('mios-pass2-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Start-Transcript -LiteralPath `$_p2Log -Force *> `$null
    Write-Host ('      Pass-2 log: ' + `$_p2Log) -ForegroundColor DarkGray
} catch {}
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
    # over ~2 seconds. Log every step to M:\MiOS\logs\mios-center-debug.log
    # (per feedback_mios_m_drive_everything; falls back to %TEMP% only
    # when M:\ doesn't exist yet during very-early bootstrap) so operator
    # can paste back what's happening when "windows aren't centering" recurs.
    `$_dbg = if (Test-Path 'M:\MiOS\logs') { Join-Path 'M:\MiOS\logs' 'mios-center-debug.log' } else { Join-Path `$env:TEMP 'mios-center-debug.log' }
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
    try {
        `$_dbgFail = if (Test-Path 'M:\MiOS\logs') { Join-Path 'M:\MiOS\logs' 'mios-center-debug.log' } else { Join-Path `$env:TEMP 'mios-center-debug.log' }
        Add-Content -LiteralPath `$_dbgFail -Value "Pass-2 inner cmd center FAILED: `$(`$_.Exception.Message)"
    } catch {}
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
    # install-robustness retry the fetch 3x with backoff +
    # body validation. A single transient blip here otherwise killed the
    # whole elevated install with a bare Invoke-RestMethod exception.
    `$src = `$null
    for (`$_fa = 1; `$_fa -le 3; `$_fa++) {
        try {
            `$src = Invoke-RestMethod -Uri `$_rawUri -Headers @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' } -TimeoutSec 60 -ErrorAction Stop
            if (`$src -and `$src.Length -gt 200) { break }
            `$src = `$null
        } catch {
            Write-Host ('  [!] Get-MiOS.ps1 fetch attempt ' + `$_fa + ' failed: ' + `$_.Exception.Message) -ForegroundColor Yellow
        }
        if (`$_fa -lt 3) { Start-Sleep -Seconds (@(2,5,10)[`$_fa-1]) }
    }
    if (-not `$src) { throw 'Could not fetch Get-MiOS.ps1 after 3 attempts (network/TLS?).' }
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
    # Run the freshly-fetched Get-MiOS.ps1 IN-PROCESS via scriptblock.
    # The previous `& pwsh.exe -File $tmpScript` spawned a new pwsh
    # process. On Windows 11 with WT as the default terminal, that
    # spawn opened a NEW WT TAB / WINDOW (operator-reported regression:
    # "spawns bootstrap window (correct) >> THEN opens a new window
    # (incorrect) >> THEN ALSO spawns the acknowledgement window").
    # In-process scriptblock execution eliminates the third window AND
    # avoids the cross-process console handle dance that previously
    # broke Read-Host on PS 5.1 fallback. Any `exit N` calls inside
    # Get-MiOS.ps1 will terminate THIS pwsh -- but that's exactly what
    # the operator wants for a unified "single bulk-install window"
    # experience. The existing try/catch wrapping is enough to keep
    # the elevation host visible long enough for the Read-Host pause
    # at the bottom of the inner cmd to fire.
    `$_rc = 0
    try {
        & ([scriptblock]::Create(`$src))
    } catch {
        Write-Host ''
        Write-Host ('  [!] In-process bootstrap throw: ' + `$_.Exception.Message) -ForegroundColor Red
        `$_rc = 1
    }
    if (`$_rc -ne 0) {
        Write-Host ''
        # Strings baked at Pass-1 install time from mios.toml
        # [messages.pass2_exit] (SSOT).
        Write-Host ('$_p2ExitedPrefix' + `$_rc) -ForegroundColor Red
        Write-Host '$_p2FailureDtl' -ForegroundColor DarkGray
        Write-Host '$_p2BuildLogHnt' -ForegroundColor DarkGray
        Write-Host ''
    } else {
        # "irm|iex invocation and install processes
        # spawn too many powershell windows and should be performed
        # in-line in one promoted Powershell window after bootstrap".
        # On success, transition THIS elevated conhost into the MiOS
        # terminal experience instead of asking the operator to press
        # Enter and click a shortcut.  Dot-source M:\MiOS\powershell\
        # profile.ps1 -- it self-renders the framed dashboard and
        # exposes the `mios <verb>` dispatcher (build / dash / dev /
        # config / pull / update / help).  Operator types verbs
        # directly in this same window; no new WT spawn, no shortcut
        # click, no third window.
        Write-Host ''
        Write-Host '$_p2SuccessTrans' -ForegroundColor Green
        Write-Host ''
        Start-Sleep -Milliseconds 800
        try { Clear-Host } catch {}
        # The MiOS profile body sources the dashboard, oh-my-posh,
        # the mios.toml resolvers, AND defines `mios <verb>` plus the
        # per-verb function aliases.  After this dot-source the
        # operator is at the MiOS prompt in this same elevated
        # conhost.  pwsh -NoExit (set in the spawn args) keeps the
        # interactive prompt alive; no Read-Host below for the
        # success path.
        `$_miosProfile = 'M:\MiOS\powershell\profile.ps1'
        if (Test-Path -LiteralPath `$_miosProfile) {
            try { . `$_miosProfile } catch {
                Write-Host ('$_p2ProfileFailed' + `$_.Exception.Message) -ForegroundColor Yellow
                Write-Host '$_p2ProfileFailedHnt' -ForegroundColor DarkGray
            }
        } else {
            Write-Host '$_p2ProfileMissing' -ForegroundColor Yellow
        }
        # SUCCESS path returns here -- the dot-sourced profile owns
        # the prompt from this point.  No press-Enter close; the
        # operator quits the window naturally (`exit` / Ctrl-D / `q`).
        return
    }
} catch {
    Write-Host ''
    Write-Host ('$_p2FetchFailed' + `$_.Exception.Message) -ForegroundColor Red
    Write-Host ''
}
# FAILURE path falls through to the press-Enter close so the operator
# has time to read the error before the elevated window closes.
Write-Host ''
Write-Host '$_p2PressEnter' -ForegroundColor DarkGray -NoNewline
try { Stop-Transcript *> `$null } catch {}
`$null = Read-Host
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

# -----------------------------------------------------------------------
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
# -----------------------------------------------------------------------

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

function Ensure-MiOSWinget {
    # Bootstrap winget itself on a truly bare Windows host (Win 10 21H2,
    # OOBE-fresh Win 11 N edition without Store, etc.) before any other
    # Install-MiOS* function tries to use it. Operator-flagged
    # "MiOS should automatically install EVERYTHING needed to install MiOS
    # via irm|iex". Without this, every winget invocation on a bare host
    # silently warns + skips, leaving the bootstrap half-installed.
    #
    # Resolution chain:
    #   1. winget already on PATH -> done.
    #   2. Microsoft.DesktopAppInstaller AppxPackage installed but PATH
    #      stale -> refresh PATH, re-probe.
    #   3. Download App Installer MSIXBUNDLE from mios.toml
    #      [bootstrap.prereqs].appinstaller_url (default aka.ms/getwinget)
    #      -> Add-AppxPackage.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  [+] winget already on PATH." -ForegroundColor DarkGray
        return $true
    }
    try {
        $appx = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
    } catch { $appx = $null }
    if ($appx) {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "  [+] winget surfaced after PATH refresh." -ForegroundColor Green
            return $true
        }
    }
    $_url = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'appinstaller_url' -Default 'https://aka.ms/getwinget')
    Write-Host "  [*] winget missing -- downloading App Installer MSIXBUNDLE from $_url ..." -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP "mios-winget-$([guid]::NewGuid().ToString('N').Substring(0,8)).msixbundle"
    try {
        Invoke-WebRequest -Uri $_url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path $tmp -ErrorAction Stop
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH = (@($_machPath, $_userPath) | Where-Object { $_ }) -join ';'
    } catch {
        Write-Host "  [!] Ensure-MiOSWinget download/install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  [+] winget bootstrapped via App Installer MSIXBUNDLE." -ForegroundColor Green
        return $true
    }
    Write-Host "  [!] winget still not on PATH after Add-AppxPackage." -ForegroundColor Yellow
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
    # TOML-first per AGENTS.md §3 -- winget ID resolves from
    # mios.toml [bootstrap.prereqs].terminal_pkg so operators can pin to
    # WindowsTerminalPreview or a different distribution channel via mios.html.
    $_wtPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'terminal_pkg' -Default 'Microsoft.WindowsTerminal')
    Write-Host "  [*] Installing Windows Terminal ($_wtPkg) via winget..." -ForegroundColor Cyan
    try {
        & winget install --id $_wtPkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
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
    # TOML-first per AGENTS.md §3 -- winget ID from mios.toml
    # [bootstrap.prereqs].pwsh_pkg (operator can pin to PowerShell-Preview
    # or an MSI variant via mios.html).
    $_pwshPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'pwsh_pkg' -Default 'Microsoft.PowerShell')
    Write-Host "  [*] Installing PowerShell 7 ($_pwshPkg) via winget..." -ForegroundColor Cyan
    try {
        & winget install --id $_pwshPkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
    } catch {
        Write-Host "  [!] winget install $_pwshPkg failed: $($_.Exception.Message)" -ForegroundColor Yellow
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

function Install-MiOSBibataCursor {
    # Install Bibata-Modern-Classic as the Windows-wide cursor scheme.
    # Operator-flagged "cursor is still not bibata GLOBALLY".
    # Linux dev VM Bibata install runs separately inside the WSL distro
    # (build-mios.ps1's Set-Step "Installing Bibata-Modern-Classic
    # cursor"). This Windows-side complement covers the desktop chrome
    # so the operator sees the same cursor on hover/click outside WT.
    #
    # Mechanism:
    #   1. Fetch ful1e5/Bibata_Cursor latest "Bibata-Modern-Classic-
    #      Windows.tar.gz" release asset.
    #   2. Extract to M:\MiOS\cursors\Bibata-Modern-Classic (per the
    #      everything-on-M:\ invariant).
    #   3. Set HKCU\Control Panel\Cursors values to the extracted
    #      .cur / .ani paths so Windows uses Bibata in every app.
    #   4. Register the scheme under HKCU\Control Panel\Cursors\Schemes
    #      so it appears in Settings -> Mouse -> Additional pointer
    #      options and survives operator scheme switches.
    #   5. Broadcast SystemParametersInfo(SPI_SETCURSORS) so the running
    #      desktop picks up the new pointers without a logoff.
    #
    # Idempotent: if Bibata is already installed AND the active
    # `(Default)` scheme is "Bibata Modern Classic", short-circuit.
    $schemeName = 'Bibata Modern Classic'
    $cursorsKey = 'HKCU:\Control Panel\Cursors'
    $current = (Get-ItemProperty -Path $cursorsKey -ErrorAction SilentlyContinue).'(default)'
    if (-not $current) { $current = (Get-ItemProperty -Path $cursorsKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)' }
    $installRoot = if (Test-Path 'M:\') { 'M:\MiOS\cursors\Bibata-Modern-Classic' }
                   else { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Cursors\Bibata-Modern-Classic' }
    if ($current -eq $schemeName -and (Test-Path -LiteralPath (Join-Path $installRoot 'Default.cur'))) {
        Write-Host "  [+] Bibata cursor already installed + active: $installRoot" -ForegroundColor DarkGray
        return $true
    }

    Write-Host "  [*] Installing Bibata-Modern-Classic Windows cursor..." -ForegroundColor Cyan
    $tmpDir   = Join-Path $env:TEMP ("mios-bibata-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $zipPath  = Join-Path $tmpDir 'Bibata-Modern-Classic-Windows.zip'
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

        # Resolve latest release tag from GitHub's API.
        $tag = 'v2.0.7'
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ful1e5/Bibata_Cursor/releases/latest' `
                       -Headers @{ 'User-Agent' = 'MiOS-Bootstrap' } -ErrorAction Stop
            if ($rel.tag_name) { $tag = $rel.tag_name }
        } catch {}
        $assetUrl = "https://github.com/ful1e5/Bibata_Cursor/releases/download/$tag/Bibata-Modern-Classic-Windows.zip"
        Write-Host "  [*] Bibata $tag : $assetUrl" -ForegroundColor DarkGray

        Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        $zipSize = (Get-Item $zipPath).Length
        if ($zipSize -lt 100000) {
            Write-Host "  [!] Bibata download too small ($zipSize bytes) -- likely 404." -ForegroundColor Yellow
            return $false
        }

        # Extract with Expand-Archive (handles zip natively). Strip
        # the top-level dir Bibata's zip uses ("Bibata-Modern-Classic")
        # so cursor files land directly under $installRoot.
        if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        $extractTmp = Join-Path $tmpDir 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractTmp -Force -ErrorAction Stop
        $extractedRoot = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
        if ($extractedRoot) {
            Get-ChildItem -LiteralPath $extractedRoot.FullName -File | Move-Item -Destination $installRoot -Force
        } else {
            Get-ChildItem -LiteralPath $extractTmp -File | Move-Item -Destination $installRoot -Force
        }
        $curFiles = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Include '*.cur','*.ani' -ErrorAction SilentlyContinue)
        if ($curFiles.Count -lt 10) {
            Write-Host "  [!] Bibata extraction produced only $($curFiles.Count) cursor files (expected 15+)." -ForegroundColor Yellow
            return $false
        }
        Write-Host "  [+] Extracted $($curFiles.Count) Bibata cursors to $installRoot" -ForegroundColor Green

        # Map Bibata filenames -> Windows cursor registry value names.
        # Sourced from Bibata's shipped install.inf (clickgen-generated
        # Wreg section). Notable rename from older Bibata releases:
        # - Pointer.cur (not Default.cur) for Arrow
        # - Work.ani (not Working.ani) for AppStarting
        # - Vert.cur / Horz.cur / Dgn1.cur / Dgn2.cur (compact names)
        # - Alternate.cur for UpArrow (no -Select suffix)
        $cursorMap = [ordered]@{
            'Arrow'         = 'Pointer.cur'
            'Help'          = 'Help.cur'
            'AppStarting'   = 'Work.ani'
            'Wait'          = 'Busy.ani'
            'Crosshair'     = 'Cross.cur'
            'precisionhair' = 'Cross.cur'   # alias in Bibata install.inf
            'IBeam'         = 'Text.cur'
            'NWPen'         = 'Handwriting.cur'
            'No'            = 'Unavailable.cur'
            'SizeNS'        = 'Vert.cur'
            'SizeWE'        = 'Horz.cur'
            'SizeNWSE'      = 'Dgn1.cur'
            'SizeNESW'      = 'Dgn2.cur'
            'Grab'          = 'Move.cur'
            'SizeAll'       = 'Move.cur'
            'UpArrow'       = 'Alternate.cur'
            'Hand'          = 'Link.cur'
            'Pin'           = 'Pin.cur'
            'Person'        = 'Person.cur'
            'Pan'           = 'Pan.cur'
            'Grabbing'      = 'Grabbing.cur'
            'Zoom-in'       = 'Zoom-in.cur'
            'Zoom-out'      = 'Zoom-out.cur'
        }
        # Locate each file (Bibata's zip may extract files into a
        # nested cursors/ dir depending on packaging; walk to find them).
        $byName = @{}
        foreach ($f in $curFiles) { $byName[$f.Name] = $f.FullName }

        if (-not (Test-Path $cursorsKey)) { New-Item -Path $cursorsKey -Force | Out-Null }
        # Build CSV for HKCU\Control Panel\Cursors\Schemes value --
        # 21 comma-separated paths in install.inf's canonical order
        # (pointer, help, work, busy, cross, text, handwriting,
        # unavailable, vert, horz, dgn1, dgn2, move, alternate, link,
        # pin, person, pan, grabbing, zoom-in, zoom-out).
        $schemeFiles = @('Pointer.cur','Help.cur','Work.ani','Busy.ani','Cross.cur',
                         'Text.cur','Handwriting.cur','Unavailable.cur','Vert.cur',
                         'Horz.cur','Dgn1.cur','Dgn2.cur','Move.cur','Alternate.cur',
                         'Link.cur','Pin.cur','Person.cur','Pan.cur','Grabbing.cur',
                         'Zoom-in.cur','Zoom-out.cur')
        $schemePaths = foreach ($f in $schemeFiles) {
            if ($byName.ContainsKey($f)) { $byName[$f] } else { '' }
        }
        $schemeCsv = $schemePaths -join ','

        # Set individual pointer registry values.
        foreach ($k in $cursorMap.Keys) {
            $file = $cursorMap[$k]
            if ($byName.ContainsKey($file)) {
                Set-ItemProperty -Path $cursorsKey -Name $k -Value $byName[$file] -Type ExpandString -Force
            }
        }
        # Active scheme name (Windows reads `(default)` for the display
        # label in Mouse Properties).
        Set-ItemProperty -Path $cursorsKey -Name '(default)' -Value $schemeName -Force

        # CursorBaseSize controls the rendered pixel size of the active
        # cursor (Windows picks the matching variant from the multi-image
        # .cur file). Bibata's Windows release embeds 5 sizes per .cur
        # (32, 48, 64, 96, 128); even the smallest 32px variant renders
        # visibly larger than typical Windows cursors because the
        # bibata glyph fills more of the 32x32 canvas. Operator-flagged
        # "windows bibata is too large" -- lowering the base
        # size to 24 forces Windows to downscale the 32px source to
        # match the visual weight of the default Aero cursor.
        # Operator-overridable via mios.toml [theme.cursor_windows].base_size.
        $_cursorSize = 24
        try { $_cursorSize = [int](Get-MiosTomlValue -Section 'theme.cursor_windows' -Key 'base_size' -Default 24) } catch {}
        if ($_cursorSize -lt 16 -or $_cursorSize -gt 256) { $_cursorSize = 24 }
        Set-ItemProperty -Path $cursorsKey -Name 'CursorBaseSize' -Value $_cursorSize -Type DWord -Force

        # Register the scheme in HKCU\...\Schemes so it appears in the
        # mouse properties dialog dropdown alongside Windows Default.
        $schemesKey = 'HKCU:\Control Panel\Cursors\Schemes'
        if (-not (Test-Path $schemesKey)) { New-Item -Path $schemesKey -Force | Out-Null }
        Set-ItemProperty -Path $schemesKey -Name $schemeName -Value $schemeCsv -Type ExpandString -Force

        # Broadcast SystemParametersInfo so the running desktop reloads
        # cursors immediately (no logoff). 0x57 = SPI_SETCURSORS.
        Add-Type -Namespace MiosWin -Name SPI -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);
'@ -ErrorAction SilentlyContinue
        try { [MiosWin.SPI]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x03) | Out-Null } catch {}

        Write-Host "  [+] Bibata-Modern-Classic active. Cursor scheme: '$schemeName'." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] Bibata install failed: $($_.Exception.Message)" -ForegroundColor Yellow
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
    # -- Defensive toml-value resolution --------------------------
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
    # launch_mode -- forces WT focus mode (no titlebar, no tabs) at
    # window-create time so the pseudo-console reports the actual
    # visible cell count from first paint. Without this, WT initially
    # measures the viewport WITH titlebar/tabs (cell count = cols-1)
    # and only re-measures after `scrollbarState=hidden` takes over,
    # by which time the first prompt has already been rendered to the
    # wrong width. With launch_mode=focus, the chrome is gone before
    # the first paint, so cell count = cols immediately.
    $_themeLaunchMode  = Get-MiosTomlValue -Section 'theme'      -Key 'launch_mode'        -Default 'focus'
    if ($_themeLaunchMode -notin @('default','focus','maximized','maximizedFocus','fullscreen','focusFullscreen')) { $_themeLaunchMode = 'focus' }
    # disable_animations -- defaults to FALSE (animations ON) per
    # operator: "enable animations and all preview features in the MiOS
    # Windows Terminal profile -- full aesthetics! ALSO: can it quickly
    # fade on open and close??". WT's built-in window open/close fade is
    # gated on disableAnimations=false + useAcrylic=true. The trade-off:
    # acrylic-recompute on first paint MAY re-trigger the off-by-N
    # cell-count bug; if the powerline wraps again with animations on,
    # bump mios.toml [terminal].right_margin to 1 as the targeted band-
    # aid (NOT animations off -- operator wants the aesthetics).
    $_themeNoAnimate   = Get-MiosTomlValue -Section 'theme'      -Key 'disable_animations' -Default $false
    if ($_themeNoAnimate -isnot [bool]) { $_themeNoAnimate = $false }
    # enable_preview_features -- gates the bundle of WT experimental.*
    # toggles that are aesthetics-relevant (URL detection, AtlasEngine
    # GPU renderer, forced-VT input, full-repaint rendering). Defaults
    # to TRUE per operator. Set to false only if a specific WT version
    # ships a regression in one of the preview keys.
    $_themePreviewFx   = Get-MiosTomlValue -Section 'theme'      -Key 'enable_preview_features' -Default $true
    if ($_themePreviewFx -isnot [bool]) { $_themePreviewFx = $true }
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
    # WT profile names sourced from mios.toml [theme.terminal] (SSOT).
    # "MiOS-DEV is the main application the end
    # user uses, MiOS app itself should be defined as MiOS-WIN from
    # here on out".  Linux dev VM = MiOS-DEV (canonical MiOS surface);
    # Windows-side launcher app = MiOS-WIN (renamed from "MiOS").
    $_miosProfileName    = Get-MiosTomlValue -Section 'theme.terminal' -Key 'profile_name'     -Default 'MiOS-WIN'
    $_miosDevProfileName = Get-MiosTomlValue -Section 'theme.terminal' -Key 'dev_profile_name' -Default 'MiOS-DEV'
    if ([string]::IsNullOrWhiteSpace($_miosProfileName))    { $_miosProfileName    = 'MiOS-WIN' }
    if ([string]::IsNullOrWhiteSpace($_miosDevProfileName)) { $_miosDevProfileName = 'MiOS-DEV' }

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
        # Disable WT's end-of-line auto-wrap on the MiOS profile.
        # Default WT behavior: writing to the LAST column emits a
        # soft-wrap newline, so content that fills exactly cols-wide
        # (e.g. our edge-to-edge dashboard frame at width=80 in an
        # 80-col window) wraps every full-width row to a new visual
        # row -- pushing the dashboard's TOP frame above the viewport.
        # Operator screenshot image #12: top `+-MiOS-+`
        # corner clipped, fastfetch info at row 0, right `|` border
        # missing. Setting this to true tells WT to leave col cols-1
        # written without firing the soft-wrap, so width=80 content
        # in an 80-col window stays on one row. Combined with
        # mios.toml [terminal].right_margin=0 + frame_width=80 this
        # produces the truly edge-to-edge framed dashboard the
        # operator wants on BOTH bash + pwsh sides.
        disableEndOfLineWrap     = $true
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
        name              = $_miosProfileName
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

    # GLOBAL WRITES (edge-to-edge pivot): the prior "no
    # globals" stance left WT's pseudo-console reporting +1-2 cells
    # over the actual visible cell count during first paint, before
    # `profiles.defaults.scrollbarState='hidden'` could take effect.
    # That made oh-my-posh's right-aligned powerline block wrap the
    # trailing time char to col 0 of the next line ("powerline seconds
    # rolling over to the left under the second-line ❯"). Operator:
    # "MiOS app/windows terminal windows should be completely
    # frameless/borderless with no margin (edge-to-edge printing)."
    #
    # Setting `launchMode = "focus"` at the ROOT level strips the title
    # bar AND the tab row from the very first paint, so WT measures the
    # viewport at the actual cell count cols × rows. Pairing it with
    # per-profile `suppressApplicationTitle = true` keeps WT from
    # re-measuring whenever the shell tries to set the window title
    # (every `cd`, every prompt repaint), and `disableAnimations = true`
    # skips the acrylic-recompute pass that re-measures the cell grid.
    # All three are required: drop any one and the off-by-N comes back.
    if (-not $wtJson.profiles) {
        $emptyProfilesObj = [PSCustomObject]@{ list = @() }
        $wtJson | Add-Member -NotePropertyName profiles -NotePropertyValue $emptyProfilesObj -Force
    }

    # Root-level launchMode -- forces focus mode (no titlebar, no tabs)
    # globally. This affects EVERY WT window the operator opens, not
    # just MiOS profiles. Operator-approved ("go fix
    # mios-bootstrap edge-to-edge now") because `--focus` on the wt.exe
    # CLI alone hides tabs but leaves the titlebar, so the off-by-N
    # cell-count bug persisted on launches that didn't go through the
    # MiOS launcher. Sourced from mios.toml [theme].launch_mode (SSOT)
    # so an operator who needs tabs back can flip it via mios.html
    # without editing this script. Use `wt.exe -w 0 nt` for a transient
    # tabs-and-titlebar window if needed.
    $wtJson | Add-Member -NotePropertyName launchMode -NotePropertyValue $_themeLaunchMode -Force

    # GLOBAL no-scrollbars + zero-padding + no-titlebar-rewriting via
    # profiles.defaults. Per operator: "MiOS app window/terminal
    # window(s) should all have NO scrollbars inhibiting any windows
    # globally!!". Per-profile scrollbarState only affects that profile;
    # profiles.defaults applies to EVERY profile including auto-
    # generated ones (cmd, PowerShell, WSL distros), so when an operator
    # switches profiles they keep the borderless+scrollbar-less feel.
    # suppressApplicationTitle=true and disableAnimations=true are the
    # second + third legs of the edge-to-edge tripod (see comment
    # above) -- without them, WT re-measures the viewport after the
    # first prompt has already been rendered using the wrong width.
    if (-not $wtJson.profiles.defaults) {
        $wtJson.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $wtJson.profiles.defaults | Add-Member -NotePropertyName scrollbarState           -NotePropertyValue $_themeScrollbar -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName padding                  -NotePropertyValue $_themePadding   -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName useAcrylic               -NotePropertyValue $_themeAcrylic   -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName opacity                  -NotePropertyValue $_themeOpacity   -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName systemBackdrop           -NotePropertyValue $_themeBackdrop  -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName suppressApplicationTitle -NotePropertyValue $_themeSuppress  -Force
    $wtJson.profiles.defaults | Add-Member -NotePropertyName disableAnimations        -NotePropertyValue $_themeNoAnimate -Force

    # Preview / experimental features bundle. All gated on
    # mios.toml [theme].enable_preview_features. Operator: "enable
    # animations and all preview features in the MiOS Windows Terminal
    # profile -- full aesthetics!" Each key here MUST be a documented
    # WT experimental knob (no random invented keys -- WT silently
    # rejects unknown keys, and a single rejected key can cascade into
    # the entire profile being skipped, which manifests as "MiOS scheme
    # never applied" / "powerline glyphs render as boxes").
    if ($_themePreviewFx) {
        # GPU-accelerated text renderer (AtlasEngine). Faster + cleaner
        # subpixel antialiasing for powerline glyphs.
        $wtJson.profiles.defaults | Add-Member -NotePropertyName useAtlasEngine -NotePropertyValue $true -Force
        # URL hyperlink detection (Ctrl-click to open). Aesthetic +
        # functional: URLs render with a subtle underline on hover.
        $wtJson.profiles.defaults | Add-Member -NotePropertyName 'experimental.detectURLs' -NotePropertyValue $true -Force
        # ForceVT input -- routes ALL input through the VT pathway, so
        # modifier keys (Ctrl/Alt/Shift combos) hit the shell as
        # documented escape sequences instead of being intercepted by
        # WT's native key handler.
        $wtJson.profiles.defaults | Add-Member -NotePropertyName 'experimental.input.forceVT' -NotePropertyValue $true -Force
        # Cleaner full-repaint rendering on resize / scrollback nav --
        # avoids the partial-row tearing the default differential
        # repaint sometimes shows under acrylic.
        $wtJson.profiles.defaults | Add-Member -NotePropertyName 'experimental.rendering.forceFullRepaint' -NotePropertyValue $true -Force
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
    # Also strip podman/WSL auto-generated profiles for our distros
    # (podman-MiOS-DEV, podman-MiOS-BUILDER, etc.) -- WT auto-creates one
    # per `podman machine init` call and they accumulate without dedup.
    # Our branded MiOS-DEV profile already covers that distro.
    # Strip prior MiOS-related entries.  "MiOS" name kept in the strip
    # list so re-runs after the rename ("MiOS app itself
    # should be defined as MiOS-WIN") clean up the old "MiOS" profile
    # left behind.  Also strips current "MiOS-WIN" by name in case the
    # GUID changed.
    $existingList = @($wtJson.profiles.list | Where-Object {
        $_.guid -ne $miosGuid -and
        $_.guid -ne $miosDevGuid -and
        $_.name -ne 'MiOS'                     -and
        $_.name -ne $_miosProfileName          -and
        $_.name -ne $_miosDevProfileName       -and
        $_.name -ne 'MiOS-DEV'                 -and
        $_.name -ne 'MiOS-Bootstrap'           -and
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

        # Verify against the ACTUAL renamed profile names from
        # mios.toml [theme.terminal] ("MiOS app
        # itself should be defined as MiOS-WIN").  Was hardcoded to
        # 'MiOS' which always failed post-rename and dropped through
        # to the raw-JSON-injection fallback that wrote a degraded
        # settings.json (schemes/profiles arrays partly-stripped),
        # leaving WT without the proper MiOS chrome -> Nerd Font
        # PUA glyphs (U+E0B4 / U+E0B6) rendered as `?` placeholders.
        if ($schemeNames -contains 'MiOS' -and $profileNames -contains $_miosProfileName -and $profileNames -contains $_miosDevProfileName) {
            Write-Host "  [+] MiOS scheme + $_miosProfileName + $_miosDevProfileName profiles upserted." -ForegroundColor Green
            Write-Host "      schemes:  $($schemeNames -join ', ')" -ForegroundColor DarkGray
            Write-Host "      profiles: $($profileNames -join ', ')" -ForegroundColor DarkGray
        } else {
            Write-Host "  [!] settings.json verify FAILED -- expected schemes contains 'MiOS' AND profiles contains '$_miosProfileName' + '$_miosDevProfileName'." -ForegroundColor Red
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
    # (operator's M:\-everywhere invariant -- "irm|iex sets up M:\
    # disk/partition installs EVERYTHING to M:\ EVERYTHING").  M:\
    # is a HARD REQUIREMENT -- the bootstrap creates it in
    # Initialize-DataDisk before this function runs.  No fallback
    # to LOCALAPPDATA; if M:\ isn't there, something has wiped it
    # mid-install and we should fail loudly rather than silently
    # split the install across C:\ and M:\.
    if (-not (Test-Path 'M:\')) {
        throw "Install-MiosLauncher: M:\ not provisioned -- Initialize-DataDisk should have created it before this point. MiOS contract: every MiOS-managed file lives on M:\."
    }
    $miosRoot = 'M:\MiOS'
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
#
# -Profile <name>  WT profile to launch.  Canonical names:
#                  'MiOS-DEV' (= dev VM via wsl.exe -d podman-MiOS-DEV)
#                  'MiOS-WIN' (= Windows pwsh + MiOS profile body)
# -Verb <name>     Optional. Runs `mios <verb>` inside the launched
#                  Windows-side window after the profile body loads.
#                  Ignored for MiOS-DEV (the dev VM is a bash login).
#
# "UNIFY all MiOS app windows/themed windows
# terminal windows to use the same profile and launch params GLOBALLY!!!"
param(
    [string]$Profile = 'MiOS-DEV',
    [string]$Verb    = ''
)
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

# Window name: MiOS for the bare hub launch, MiOS-<verb> for verb
# launches. Per-verb unique names prevent verb tabs piling into the
# main MiOS hub window -- each click opens its OWN centered focus
# window. The hub stays single-instance (clicking MiOS again reuses
# the existing window). Win+Space summon still targets `MiOS` (the hub)
# per mios.toml [theme.terminal].summon_window_name.
$winName = if ([string]::IsNullOrWhiteSpace($Verb)) { 'MiOS' } else { 'MiOS-' + $Verb }

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

# `-w <winName>` names the window so click-to-focus finds it and the
# post-launch SetWindowPos retry can target it. The hub uses
# `-w MiOS` (single-instance, summon-targetable). Per-verb launches
# use `-w MiOS-<verb>` (own window per verb -- no tab-pile).
#
# Empty subcommand on hub launches uses the profile's bound commandline
# (Windows pwsh + MiOS PS profile body via Install-MiOSTerminalProfile).
# On verb launches, override commandline with a pwsh that loads the
# profile body explicitly THEN runs `mios <verb>` -- otherwise wt.exe's
# subcommand replaces the profile commandline and we lose the dashboard
# render + the `mios` function definition.
if ([string]::IsNullOrWhiteSpace($Verb) -or $Profile -eq 'MiOS-DEV') {
    # Bare profile launch (or dev VM -- bash login takes no verb).
    # The WT profile's bound commandline runs as-is.
    $wtArgs = @('-w',$winName,'--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p',$Profile)
} else {
    # Verb dispatch on a Windows-side profile (MiOS-WIN, or legacy 'MiOS').
    # Override the WT profile commandline with pwsh.exe loading the MiOS
    # profile body explicitly + running `mios <verb>` after.
    $miosProfile = 'M:\MiOS\powershell\profile.ps1'
    $pwshExe = $null
    try {
        $pwshPkg = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pwshPkg) { $pwshExe = $pwshPkg.Source }
    } catch {}
    if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
    $verbSafe = $Verb -replace "'","''"
    $miosProfileSafe = $miosProfile -replace "'","''"
    $cmd = "`$env:MIOS_APP_CONTEXT='1'; if (Test-Path '$miosProfileSafe') { . '$miosProfileSafe' }; mios $verbSafe"
    $wtArgs = @('-w',$winName,'--pos',"$x,$y",'--size',"$Cols,$Rows",'--focus','-p',$Profile,$pwshExe,'-NoLogo','-NoExit','-NoProfile','-Command',$cmd)
}
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
    # IMPORTANT: probe canonical install locations FIRST. Get-Command
    # pwsh.exe on Windows 11 returns the WindowsApps reparse-point stub
    # (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe) which ShellExecute
    # rejects with 0x80070002 (operator 17:57 install: clicking MiOS
    # Help.lnk produced "[error 2147942402 (0x80070002) when launching
    # `mios help`] The system cannot find the file specified.")
    $pwshExe = $null
    foreach ($_pcand in @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramW6432\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe"
    )) {
        if ($_pcand -and (Test-Path -LiteralPath $_pcand)) { $pwshExe = $_pcand; break }
    }
    if (-not $pwshExe) { $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwshExe) { Write-Host "  [!] No pwsh.exe found; cannot create launcher .lnk." -ForegroundColor Yellow; return }

    # Hub .lnk targets the MiOS-DEV WT profile (mios.toml
    # [theme.terminal].hub_target_profile, default "MiOS-DEV") --
    # "MiOS app opens direct to... podman-MiOS-DEV".
    # The launcher receives -Profile <name>; mios-launch.ps1 spawns
    # `wt.exe ... -p <name>` which lands the operator straight in the
    # dev VM shell.  No Verb -- the dev VM commandline is a bash
    # login, not a `mios <verb>` dispatcher.
    $_hubTargetProfile = Get-MiosTomlValue -Section 'theme.terminal' -Key 'hub_target_profile' -Default 'MiOS-DEV'
    if ([string]::IsNullOrWhiteSpace($_hubTargetProfile)) { $_hubTargetProfile = 'MiOS-DEV' }
    $lnkArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -Profile `"$_hubTargetProfile`""
    # .lnk Description = mios.toml [branding].tagline_app (preferred)
    # or.tagline. Per 'the Applications
    # tag/description ... should be defined as My Personal Operating
    # System or similar'.  SSOT lift per "no hardcoding ANYWHERE".
    $_lnkTag = Get-MiosTomlValue -Section 'branding' -Key 'tagline_app' -Default (Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'My Personal Operating System')
    $lnkDesc = "MiOS -- $_lnkTag"

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

    # - Canonical 4-shortcut set ------------------
    # SSOT: each shortcut's metadata (name, profile, verb, description)
    # resolves through mios.toml [apps.shortcut.<key>]. PS-code defaults
    # below are vendor fallbacks per feedback_mios_defaults_baseline.
    # Operator can rename/relabel via mios.html -> mios.toml without
    # touching code. Per feedback_mios_toml_is_ssot_for_code: no
    # hardcoded user-facing strings.
    #
    # Operator directive: "MiOS app opens MiOS-DEV machine to the GLOBAL
    # unified dash, MiOS-WIN does the windows side ... MiOS Help and
    # Uninstall MiOS are the ONLY installed shortcuts/links system wide!!!"
    $_smFolder = Get-MiosTomlValue -Section 'apps' -Key 'start_menu_folder' -Default 'MiOS'
    if ([string]::IsNullOrWhiteSpace($_smFolder)) { $_smFolder = 'MiOS' }
    $startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$_smFolder"
    if (-not (Test-Path $startMenuDir)) { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null }
    $desktopDir = [Environment]::GetFolderPath('Desktop')

    # Resolve WT profile names from mios.toml [theme.terminal] (SSOT) so
    # a mios.toml rename (e.g. MiOS-WIN -> something else) flows through.
    $_winProfile = Get-MiosTomlValue -Section 'theme.terminal' -Key 'profile_name'     -Default 'MiOS-WIN'
    $_devProfile = Get-MiosTomlValue -Section 'theme.terminal' -Key 'dev_profile_name' -Default 'MiOS-DEV'
    if ([string]::IsNullOrWhiteSpace($_winProfile)) { $_winProfile = 'MiOS-WIN' }
    if ([string]::IsNullOrWhiteSpace($_devProfile)) { $_devProfile = 'MiOS-DEV' }

    # Prefer the compiled subsystem:Windows launcher (.exe -- zero pwsh
    # flash, proper window centering loop). Fall back to pwsh + .ps1
    # only if the .exe wasn't compiled (csc.exe missing on the host).
    $_launcherExe = Join-Path $miosRoot 'bin\mios-launch.exe'
    $_useExeLauncher = Test-Path -LiteralPath $_launcherExe

    $writeMiosLnk = {
        param([string]$LnkPath, [string]$LnkTarget, [string]$LnkArgs, [string]$LnkDesc)
        $sc = $shell.CreateShortcut($LnkPath)
        $sc.TargetPath       = $LnkTarget
        $sc.Arguments        = $LnkArgs
        $sc.WorkingDirectory = $miosRoot
        $sc.Description      = $LnkDesc
        # WindowStyle Normal (1) -- the .exe is subsystem:Windows so
        # there's no console to hide; the spawned wt.exe handles its
        # own window state. Was 7 (Minimized) which on some shells
        # propagated to wt.exe and hid the MiOS window.
        $sc.WindowStyle      = 1
        if ($iconPath) { $sc.IconLocation = "$iconPath,0" }
        $sc.Save()
    }

    # SSOT shortcut catalog -- vendor defaults baked here, mios.toml
    # [apps.shortcut.<key>] overrides any/all keys.
    $_shortcutCatalog = @(
        @{ Key='mios';      DefName='MiOS';        DefProfile=$_devProfile; DefVerb='';     DefDesc="MiOS -- $_lnkTag" },
        @{ Key='mios_win';  DefName='MiOS-WIN';    DefProfile=$_winProfile; DefVerb='';     DefDesc='MiOS-WIN -- Windows-side terminal with MiOS theme + dashboard' },
        @{ Key='mios_help'; DefName='MiOS Help';   DefProfile=$_winProfile; DefVerb='help'; DefDesc='MiOS Help -- verb + functionality reference' }
    )
    foreach ($_sc in $_shortcutCatalog) {
        $_section = 'apps.shortcut.' + $_sc.Key
        $_lnkName = Get-MiosTomlValue -Section $_section -Key 'name'        -Default $_sc.DefName
        $_lnkProf = Get-MiosTomlValue -Section $_section -Key 'profile'     -Default $_sc.DefProfile
        $_lnkVerb = Get-MiosTomlValue -Section $_section -Key 'verb'        -Default $_sc.DefVerb
        $_lnkDesc = Get-MiosTomlValue -Section $_section -Key 'description' -Default $_sc.DefDesc
        if ([string]::IsNullOrWhiteSpace($_lnkName)) { $_lnkName = $_sc.DefName }
        if ([string]::IsNullOrWhiteSpace($_lnkProf)) { $_lnkProf = $_sc.DefProfile }
        # Build (TargetExe, ArgString) pair. .exe form takes positional
        # args ("<profile> <cols> <rows>") and is preferred. .ps1 fallback
        # uses pwsh -File invocation. Cell dims sourced from mios.toml
        # [terminal] (SSOT) -- "TOML is THE TOTAL
        # REFERENCE for all functions and calls".
        $_shortcutCols = [int](Get-MiosTomlValue -Section 'terminal' -Key 'cols' -Default 80)
        $_shortcutRows = [int](Get-MiosTomlValue -Section 'terminal' -Key 'rows' -Default 20)
        if ($_useExeLauncher) {
            $_lnkTarget = $_launcherExe
            $_lnkArgStr = "$_lnkProf $_shortcutCols $_shortcutRows"
            if ($_lnkVerb -and $_lnkProf -ne $_devProfile) {
                # Verb dispatch -- the .exe doesn't currently parse -Verb,
                # so route those (just MiOS Help today) through the .ps1.
                $_lnkTarget = $pwshExe
                $_lnkArgStr = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -Profile `"$_lnkProf`" -Verb `"$_lnkVerb`""
            }
        } else {
            $_lnkTarget = $pwshExe
            $_lnkArgStr = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -Profile `"$_lnkProf`""
            if ($_lnkVerb -and $_lnkProf -ne $_devProfile) {
                $_lnkArgStr += " -Verb `"$_lnkVerb`""
            }
        }
        try {
            & $writeMiosLnk (Join-Path $startMenuDir ($_lnkName + '.lnk')) $_lnkTarget $_lnkArgStr $_lnkDesc
            if ($desktopDir -and (Test-Path $desktopDir)) {
                & $writeMiosLnk (Join-Path $desktopDir ($_lnkName + '.lnk')) $_lnkTarget $_lnkArgStr $_lnkDesc
            }
            Write-Host "  [+] Shortcut: $_lnkName -> $_lnkTarget $_lnkArgStr" -ForegroundColor DarkGray
        } catch {
            Write-Host "  [!] Shortcut creation failed for $_lnkName : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # The hub variable below is left as 'MiOS' so subsequent code that
    # references $_hubLnkName (e.g. AumID stamping, registry uninstall
    # entries) targets the canonical MiOS.lnk.
    $_hubLnkName = 'MiOS'
    $smLnk = Join-Path $startMenuDir 'MiOS.lnk'

    # -- Per-verb shortcuts (MiOS-DEV / MiOS Build / MiOS Dashboard / etc.) --
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
    # Per-verb shortcuts.  Each entry maps to:
    #   * Profile  -- WT profile name to launch ('MiOS' = hub,
    #                 'MiOS-DEV' = wsl.exe -d podman-MiOS-DEV --user mios)
    #   * Verb     -- mios verb to run inside the launched window
    #                 (empty = just open the profile, no dispatch)
    #   * Icon     -- per-verb .ico under M:\MiOS\icons (fallback: mios.ico)
    # "launching MiOS-DEV doesn't launch in to
    # the podman-MiOS-DEV machine still" -- root cause was that the
    # MiOS-DEV.lnk was passing `-Verb dev` to mios-launch.ps1 which
    # only accepted -Profile, so the dev launcher silently fell back
    # to Profile='MiOS' (the hub) and the dev verb was never used.
    # The Profile field below routes to the right WT profile so
    # MiOS-DEV.lnk now lands in the actual dev VM.
    # consolidation: "TOO MANY APPS!! I SAID
    # UNIFY MiOS APPS in a way that makes sense and is minimal --
    # MiOS app opens direct to ... podman-MiOS-DEV!!!".  The hub
    # MiOS.lnk written above is the ONE user-facing app.  Per-verb
    # shortcuts (MiOS Help / MiOS Config / MiOS-DEV / MiOS-WIN)
    # are NOT created -- those are typed verbs in the terminal
    # (`mios help`, `mios config`, `mios dev`, etc.), not separate
    # native apps.  Only the Uninstall MiOS shortcut sibling lives
    # alongside the hub.  $miosVerbs is left as an empty array so
    # downstream loops (AumID stamping, .lnk reaping) iterate
    # zero entries instead of crashing on $null.
    $miosVerbs = @()

    # -- Uninstall MiOS shortcut (Start Menu + Desktop) --------------
    # Per "MiOS should... Install as a Native
    # Windows Application with a bundled uninstaller being a
    # shortcut/link as well".  The hub already registers in
    # Add/Remove Programs (line 2294+); this gives the operator a
    # direct desktop / Start-Menu shortcut to the uninstaller without
    # opening Settings -> Apps.  The .lnk targets M:\MiOS\bin\uninstall.ps1
    # which build-mios.ps1's Install-WindowsBranding stages -- it does
    # the full reap (WSL distros, podman machines, registry keys, M:\
    # overlay, .lnk cleanup).  Falls back to the inline UninstallString
    # registered above if the full uninstall.ps1 isn't on disk yet
    # (e.g. on a half-bootstrapped host).
    $_uninstScript = Join-Path $miosRoot 'bin\uninstall.ps1'
    $writeUninstLnk = {
        param([string]$Path)
        $sc = $shell.CreateShortcut($Path)
        $sc.TargetPath       = $pwshExe
        if (Test-Path -LiteralPath $_uninstScript) {
            $sc.Arguments    = "-NoProfile -ExecutionPolicy Bypass -File `"$_uninstScript`""
        } else {
            # Inline minimum-viable uninstaller (matches the registry
            # UninstallString value -- removes hub .lnks + uninstall key).
            $sc.Arguments    = "-NoProfile -ExecutionPolicy Bypass -Command `"Remove-Item -LiteralPath '$smLnk','$desktopDir\MiOS.lnk' -Force -EA SilentlyContinue; Remove-Item -LiteralPath '$uninstKey' -Recurse -Force -EA SilentlyContinue`""
        }
        $sc.WorkingDirectory = $miosRoot
        $sc.Description      = 'Uninstall MiOS (removes WT profiles, WSL distros, M:\ overlay, registry keys, shortcuts)'
        $sc.WindowStyle      = 1   # 1 = Normal -- operator should SEE the uninstall progress
        if ($iconPath) { $sc.IconLocation = "$iconPath,0" }
        $sc.Save()
    }
    $uninstSmLnk = Join-Path $startMenuDir 'Uninstall MiOS.lnk'
    & $writeUninstLnk $uninstSmLnk
    Write-Host "  [+] Start Menu: $uninstSmLnk" -ForegroundColor DarkGray
    if ($desktopDir -and (Test-Path $desktopDir)) {
        $uninstDeskLnk = Join-Path $desktopDir 'Uninstall MiOS.lnk'
        & $writeUninstLnk $uninstDeskLnk
        Write-Host "  [+] Desktop: $uninstDeskLnk" -ForegroundColor DarkGray
    }

    # Stale-shortcut cleanup -- canonical 4-shortcut set is
    # MiOS / MiOS-WIN / MiOS Help / Uninstall MiOS (created above).
    # Every OTHER variant a prior revision shipped gets reaped so
    # re-running Get-MiOS.ps1 normalizes the menu. NOTE: MiOS-DEV.lnk
    # is reaped because the canonical "MiOS.lnk" already targets the
    # dev VM (no second shortcut for the same target). MiOS Config.lnk
    # is reaped because `mios config` is a typed verb inside the terminal.
    foreach ($legacy in @(
        # Per-verb shortcuts no longer in the canonical set (typed verbs):
        'MiOS Build.lnk','MiOS Dashboard.lnk','MiOS Configurator.lnk',
        'MiOS Update.lnk','MiOS Pull.lnk','MiOS Setup.lnk',
        'MiOS Terminal.lnk','MiOS Dev Shell.lnk','MiOS Podman Shell.lnk',
        'Build MiOS.lnk',
        # Redundant-with-MiOS.lnk + typed-verb apps:
        'MiOS-DEV.lnk','MiOS Config.lnk'
    )) {
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
            # Stamp AumID on every canonical shortcut (4-set: MiOS,
            # MiOS-WIN, MiOS Help, Uninstall MiOS) so all MiOS app
            # windows group under one taskbar / Start tile.
            $_allShortcuts = @()
            foreach ($lnkName in @('MiOS.lnk','MiOS-WIN.lnk','MiOS Help.lnk','Uninstall MiOS.lnk')) {
                $_smPath = Join-Path $startMenuDir $lnkName
                if (Test-Path -LiteralPath $_smPath) { $_allShortcuts += $_smPath }
                if ($desktopDir) {
                    $_dkPath = Join-Path $desktopDir $lnkName
                    if (Test-Path -LiteralPath $_dkPath) { $_allShortcuts += $_dkPath }
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
        # DisplayName resolves through mios.toml [branding].tagline_app
        # (per 'the Applications tag/description
        # when installed "MiOS - Immutable Fedora AI Workstation"
        # should be defined as My Personal Operating System or similar').
        # The technical descriptor "Immutable Fedora AI Workstation"
        # remains in the dashboard subtitle for in-terminal context;
        # the OS-wide app face (this DisplayName, .lnk descriptions,
        # AppX manifest) uses the operator-friendly tagline.
        $_arTag = Get-MiosTomlValue -Section 'branding' -Key 'tagline_app' -Default (Get-MiosTomlValue -Section 'branding' -Key 'tagline' -Default 'My Personal Operating System')
        Set-ItemProperty -Path $uninstKey -Name 'DisplayName'     -Value ('MiOS - ' + $_arTag) -Force
        Set-ItemProperty -Path $uninstKey -Name 'DisplayVersion'  -Value 'v0.2.4' -Force
        Set-ItemProperty -Path $uninstKey -Name 'Publisher'       -Value 'mios-dev' -Force
        Set-ItemProperty -Path $uninstKey -Name 'InstallLocation' -Value $miosRoot -Force
        Set-ItemProperty -Path $uninstKey -Name 'URLInfoAbout'    -Value (Get-MiosTomlValue -Section 'branding' -Key 'about_url' -Default 'https://github.com/mios-dev/mios') -Force
        if ($iconPath) { Set-ItemProperty -Path $uninstKey -Name 'DisplayIcon' -Value $iconPath -Force }
        Set-ItemProperty -Path $uninstKey -Name 'NoModify' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $uninstKey -Name 'NoRepair' -Value 1 -Type DWord -Force
        # UninstallString: prefer the full M:\MiOS\bin\uninstall.ps1 if
        # build-mios.ps1's Install-WindowsBranding has staged it; falls
        # back to a minimum-viable inline removal of the hub + uninstall
        # entry .lnks + registry key when the full uninstaller isn't on
        # disk yet (e.g. half-bootstrapped host).
        $_fullUninst = Join-Path $miosRoot 'bin\uninstall.ps1'
        if (Test-Path -LiteralPath $_fullUninst) {
            $uninstCmd = "$pwshExe -NoProfile -ExecutionPolicy Bypass -File `"$_fullUninst`""
        } else {
            $uninstCmd = "$pwshExe -NoProfile -ExecutionPolicy Bypass -Command `"Remove-Item -LiteralPath '$smLnk','$desktopDir\MiOS.lnk','$startMenuDir\Uninstall MiOS.lnk','$desktopDir\Uninstall MiOS.lnk' -Force -EA SilentlyContinue; Remove-Item -LiteralPath '$uninstKey' -Recurse -Force -EA SilentlyContinue`""
        }
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

function Install-MiOSServiceShortcuts {
    # Explicit Windows Start Menu shortcuts for MiOS web services. WSLg's
    # auto-publish heuristic filters out the 10 mios-svc-*.desktop files
    # MiOS ships in /usr/share/applications/ (Categories=System;Network;
    # Settings; + Exec=xdg-open URL doesn't fit WSLg's app model).
    # Operator-confirmed 0 of 10 mios-svc-* entries surfaced
    # as Windows shortcuts despite clean Type=Application + NoDisplay=false.
    #
    # TOML-first per AGENTS.md §3 -- iterates mios.toml [desktop.start_menu]
    # `publish` list and reads <key>_label, <key>_scheme, <key>_port_key
    # for each entry. Resolves the port from [ports].<port_key>. Writes
    # one .url Internet shortcut per entry into
    #   %APPDATA%\Microsoft\Windows\Start Menu\Programs\podman-MiOS-DEV\
    # so they land in the same Start Menu folder WSLg uses for the
    # 2 apps it does auto-publish (gnome-software, winemine).
    #
    # Idempotent: rewrites the .url body each pass; safe to re-run.
    # Operator removes by dropping a key from `publish` (existing .url
    # persists until Pass-0 reap or manual delete).
    $publishCSV = [string](Get-MiosTomlValue -Section 'desktop.start_menu' -Key 'publish' -Default 'forge,cockpit,code_server,hermes_workspace,searxng,hermes_dashboard,guacamole_web')
    $publish = @($publishCSV -split '[,\s\[\]"'']+' | Where-Object { $_ })
    if (-not $publish -or $publish.Count -eq 0) {
        Write-Host "  [-] [desktop.start_menu].publish empty -- no service shortcuts created." -ForegroundColor DarkGray
        return $false
    }

    $startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\podman-MiOS-DEV'
    if (-not (Test-Path $startMenuDir)) { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null }

    $created = 0
    foreach ($key in $publish) {
        $portKey = [string](Get-MiosTomlValue -Section 'desktop.start_menu' -Key "${key}_port_key" -Default $key)
        $port    = [int](Get-MiosTomlValue -Section 'ports' -Key $portKey -Default 0)
        if ($port -lt 1) {
            Write-Host "  [-] skip '$key' -- [ports].$portKey unresolved" -ForegroundColor DarkGray
            continue
        }
        $label  = [string](Get-MiosTomlValue -Section 'desktop.start_menu' -Key "${key}_label"  -Default $key)
        $scheme = [string](Get-MiosTomlValue -Section 'desktop.start_menu' -Key "${key}_scheme" -Default 'http')
        $url    = "${scheme}://localhost:${port}/"

        # .url Internet shortcut format: plain INI body, opens in default
        # browser when launched from Start Menu. shell32.dll,14 is the
        # generic globe icon Windows uses for unbranded web shortcuts.
        $urlPath = Join-Path $startMenuDir "$label (MiOS-DEV).url"
        $body = "[InternetShortcut]`r`nURL=$url`r`nIconFile=$env:SystemRoot\System32\shell32.dll`r`nIconIndex=14`r`n"
        try {
            Set-Content -Path $urlPath -Value $body -Encoding ASCII -Force
            $created++
        } catch {
            Write-Host "  [!] $label : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host "  [+] $created MiOS service shortcuts created in $startMenuDir" -ForegroundColor Green
    return $true
}

# ========================================================================
# Vendor content blobs (branding ASCII / fastfetch config / oh-my-posh
# theme) USED to be embedded as heredocs in this script.  They drifted
# from upstream mios.git on every iteration and produced stale
# powerline glyphs / ASCII art / fastfetch logos at install time --
# "you are hardcoding mios build to build a
# smaller version of itself that you've embedded in the actual codebase
# and THAT's where it's sourcing from!! MiOS is completely self
# developing, self building, self hosted... ALL values source from the
# toml".
#
# Get-MiosVendorContent resolves vendor content from mios.git origin
# (raw.githubusercontent.com).  WEB ONLY -- no local fallback.
#
# Per operator architectural rule
#
#   "ORIGIN = web entries/repos only -- no fallback to M:\ or
#    anywhere else -- unless origin has been pulled and it's a
#    simple 'mios build' -- that can pull from M:\ as it'd already
#    exist -- then 'mios update' would ALWAYS pull from web
#    regardless of clean entry, updating, etc-etc!!!"
#
# Get-MiOS.ps1 is BOTH the clean `irm | iex` entry AND what `mios
# update` re-fetches.  Both must hit the web -- never M:\, never
# C:\MiOS, never %USERPROFILE%.  M:\ overlays exist for build-mios.ps1
# / `mios build` to read AFTER mios-pull has populated them; the
# bootstrap itself ALWAYS forces a fresh fetch.  Mixing the two
# would let a stale M:\ silently override the web pull, defeating
# the "clean entry forces refresh" guarantee.
#
# Hard-fail with a clear error rather than falling back to a stale
# snapshot.  No embedded heredocs, no M:\ cache, no on-disk dev
# tree -- nothing but origin.
# ========================================================================
function Get-MiosVendorContent {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [string] $RelPath
    )
    if ($Script:MiosRawBase -match '^[A-Za-z]:') {
        try {
            $localPath = Join-Path $Script:MiosRawBase "usr/share/mios/$RelPath"
            if (Test-Path $localPath) {
                return [IO.File]::ReadAllText($localPath, (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch {
            throw "Get-MiosVendorContent (local): cannot resolve '$RelPath' from '$localPath'. Underlying: $($_.Exception.Message)"
        }
    }
    try {
        $cb  = [int][double]::Parse((Get-Date -UFormat %s))
        $url = "$($Script:MiosRawBase)/usr/share/mios/$RelPath" + "?cb=$cb"
        $headers = @{ 'Cache-Control' = 'no-cache, no-store, max-age=0'; 'Pragma' = 'no-cache' }
        # Use Invoke-WebRequest, NOT Invoke-RestMethod.  IRM
        # auto-deserializes any JSON response into a PSCustomObject; for
        # vendor content like mios.omp.json we need RAW TEXT.  IRM
        # produced an 867-byte stringified-PSCustomObject (instead of
        # the 10.9 kb omp.json source) and broke the downstream
        # GetBytes() call with "Cannot find an overload" because the
        # argument was an object, not a string.  IWR returns the raw
        # response body as a string (or byte[] for binary), which we
        # then UTF-8-decode if it came back as bytes -- so PUA glyphs
        # (U+E0B4 / U+E0B6) in mios.omp.json survive end-to-end.
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -ErrorAction Stop
        if ($resp.Content -is [byte[]]) {
            return [System.Text.Encoding]::UTF8.GetString($resp.Content)
        }
        return [string]$resp.Content
    } catch {
        throw "Get-MiosVendorContent: cannot resolve '$RelPath' from raw.githubusercontent.com mios.git origin/main. MiOS self-replication requires reachable origin -- no local fallback (per operator: 'ORIGIN = web entries/repos only'). Underlying: $($_.Exception.Message)"
    }
}

# Resolved at script-load time so downstream functions
# (Install-MiOSFastfetch, Install-MiOSPowerShellProfile, the self-heal
# base64-encoders below) see them in $Script: scope.  All three pull
# fresh from mios.git so the install ALWAYS reflects current upstream.
$Script:MiosBrandingTxt     = Get-MiosVendorContent 'branding/mios.txt'
$Script:MiosFastfetchConfig = Get-MiosVendorContent 'fastfetch/config.jsonc'
$Script:MiosOmpJson         = Get-MiosVendorContent 'oh-my-posh/mios.omp.json'

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
        @{ Path='C:\mios-bootstrap\mios.toml'; Source='C:\mios-bootstrap (local dev)' },
        @{ Path='M:\etc\mios\mios.toml';       Source='M:\etc\mios (host overlay)' },
        @{ Path='M:\usr\share\mios\mios.toml'; Source='M:\usr\share\mios (vendor on M:)' }
    )) {
        if (Test-Path -LiteralPath $cand.Path) {
            try {
                $tomlText   = [IO.File]::ReadAllText($cand.Path, (New-Object System.Text.UTF8Encoding($false)))
                $tomlSource = $cand.Source
                break
            } catch {}
        }
    }
    if (-not $tomlText) {
        try {
            $cb       = [int][double]::Parse((Get-Date -UFormat %s))
            $tomlUrl  = "$($Script:MiosRawBase)/usr/share/mios/mios.toml?cb=$cb"
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
    # TOML-first -- oh-my-posh winget ID from mios.toml [bootstrap.prereqs].ohmyposh_pkg
    $_ompPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'ohmyposh_pkg' -Default 'JanDeDobbeleer.OhMyPosh')
    Write-Host "  [*] Installing/upgrading oh-my-posh ($_ompPkg) via winget..." -ForegroundColor Cyan
    try {
        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
            & winget upgrade --id $_ompPkg --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } else {
            & winget install --id $_ompPkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
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
            # TOML-first -- fastfetch winget ID from mios.toml [bootstrap.prereqs].fastfetch_pkg
            $_ffPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'fastfetch_pkg' -Default 'Fastfetch-cli.Fastfetch')
            Write-Host "  [*] Installing fastfetch ($_ffPkg) via winget..." -ForegroundColor Cyan
            try {
                & winget install --id $_ffPkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
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

    # Stage the config + logo on M:\ (M:\-everywhere invariant -- no
    # LOCALAPPDATA fallback; Initialize-DataDisk creates M:\ before
    # any MiOS staging runs).
    if (-not (Test-Path 'M:\')) {
        throw "Install-MiOSFastfetch: M:\ not provisioned -- Initialize-DataDisk should have created it before this point."
    }
    $miosRoot = 'M:\MiOS'
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

    # Source-of-truth path point on Windows: the deployed config uses
    # /usr/share/mios/branding/mios.txt (the Linux path). Rewrite to
    # the Windows-friendly Logo path that we just staged.
    $resolvedConfig = $resolvedConfig -replace '/usr/share/mios/branding/mios\.txt', $logoPathJson

    # -- Color substitution from mios.toml [theme.fastfetch] (SSOT) --
    # Per "oh my posh and other settings should
    # source from the same toml sections for all platform for theme/
    # branding to be truly unified in code".  fastfetch's per-module
    # color overrides (logo / keys / title / output) ship with vendor-
    # default ANSI tags that match [theme.fastfetch] vendor defaults;
    # operator overrides via mios.html flow into every MiOS terminal
    # without touching this script.  Only fires when the resolved
    # value differs from vendor and is one of fastfetch's accepted
    # ANSI color names.
    $_ffPalette = @(
        @{ Token='logo_color';   VendorAnsi='blue';   JsonField='"1"' }
        @{ Token='keys_color';   VendorAnsi='yellow'; JsonField='"keys"' }
        @{ Token='title_color';  VendorAnsi='white';  JsonField='"title"' }
        @{ Token='output_color'; VendorAnsi='cyan';   JsonField='"output"' }
    )
    $_ansiNames = @('black','red','green','yellow','blue','magenta','cyan','white','default')
    foreach ($_pe in $_ffPalette) {
        $_resolved = Get-MiosTomlValue -Section 'theme.fastfetch' -Key $_pe.Token -Default $_pe.VendorAnsi
        if ($_resolved -and $_resolved -ne $_pe.VendorAnsi -and $_ansiNames -contains $_resolved.ToLower()) {
            # Replace `"1": "blue"` -> `"1": "<resolved>"` (or the
            # equivalent for keys/title/output).  Field-anchored
            # regex so we don't accidentally rewrite ANSI strings
            # elsewhere in the JSONC.
            $_rx = ($_pe.JsonField + '\s*:\s*"') + [regex]::Escape($_pe.VendorAnsi) + '"'
            $_rep = $_pe.JsonField + ': "' + $_resolved + '"'
            $resolvedConfig = [regex]::Replace($resolvedConfig, $_rx, $_rep)
        }
    }
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
    # Stage mios.omp.json at M:\MiOS\themes\ -- M:\-everywhere
    # invariant; Initialize-DataDisk creates M:\ before this runs.
    if (-not (Test-Path 'M:\')) {
        throw "Install-MiOSOhMyPoshTheme: M:\ not provisioned -- Initialize-DataDisk should have created it before this point."
    }
    $miosRoot = 'M:\MiOS'
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
    # frame_width default is COLS - 1 per operator "everything should be
    # -1 width" -- 1-cell gutter on the right edge prevents the frame
    # from line-wrapping when WT reports WindowWidth one cell over
    # visible. mios.toml [terminal].frame_width is the SSOT; the
    # configurator HTML exposes this for operator override.
    # frame_height stays rows-1 so one row is reserved for the prompt.
    $_miosFrameW  = Get-MiosTomlValue -Section 'terminal' -Key 'frame_width'     -Default $_miosCols
    $_miosFrameH  = Get-MiosTomlValue -Section 'terminal' -Key 'frame_height'    -Default ($_miosRows - 1)
    # right_margin: cells of slack between the rightmost paintable cell
    # and the rightmost cell the dashboard frame / right-aligned prompt
    # block writes to. Default 2 because the operator reported "framing
    # too wide STILL" with the previous cols-1 (1 cell) margin -- WT's
    # pseudo-console reports WindowWidth 1 cell over the visible/
    # paintable cell count during the first paint (before the
    # scrollbarState='hidden' setting and its scrollbar-reservation
    # release have taken effect). cols-2 always avoids wrap.
    $_miosRightMargin = Get-MiosTomlValue -Section 'terminal' -Key 'right_margin' -Default 0
    # Font family + size sourced from mios.toml [theme.font] -- baked
    # as the install-time default for the dashboard's "font" field
    # (Show-MiosDashboard re-reads at runtime so configurator edits
    # also flow through; this is the cold-start fallback).
    $_themeFontFace = Get-MiosTomlValue -Section 'theme.font' -Key 'family' -Default 'GeistMono Nerd Font Mono'
    if ([string]::IsNullOrWhiteSpace($_themeFontFace)) { $_themeFontFace = 'GeistMono Nerd Font Mono' }
    $_themeFontSize = Get-MiosTomlValue -Section 'theme.font' -Key 'size' -Default 12
    if (-not ($_themeFontSize -is [int]) -or $_themeFontSize -lt 6 -or $_themeFontSize -gt 72) { $_themeFontSize = 12 }

    # -- EULA pre-print lines (mios.toml [messages.eula]) -------------
    # Read the toml once at install time and bake the resolved lines
    # as a literal PS array into the heredoc.  Operator edits via
    # mios.html flow on the next `mios update` re-run.  Get-MiosTomlValue
    # can't parse multi-line array values (its key regex doesn't span
    # lines), so use an inline DOTALL match here.
    $_eulaTomlText = Resolve-MiosTomlText
    $_eulaLines = @(
        '',
        '  MiOS -- My Personal Operating System',
        '  Immutable Fedora AI Workstation (pronounced "MyOS")',
        '',
        '  By invoking any MiOS entry point you acknowledge:',
        '    * MiOS is provided AS IS, NO WARRANTY (MIT license).',
        '    * Build/install scripts can modify your system globally',
        '      (registry, env vars, fonts, WT settings, WSL distros, M:\ partition).',
        '    * Telemetry: NONE (no data leaves the host without explicit operator action).',
        '    * Full text: M:\AGREEMENTS.md  +  M:\LICENSE',
        '',
        '  Continued use of this terminal is treated as acknowledgment.',
        ''
    )
    $_eulaDisplayMs = 600
    if ($_eulaTomlText) {
        $_euSec = [regex]::Match($_eulaTomlText, '(?ms)^\[messages\.eula\]\s*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
        if ($_euSec.Success) {
            $_euBody = $_euSec.Groups['body'].Value
            $_msM = [regex]::Match($_euBody, '(?m)^\s*display_ms\s*=\s*(\d+)')
            if ($_msM.Success) { $_eulaDisplayMs = [int]$_msM.Groups[1].Value }
            $_lnsM = [regex]::Match($_euBody, '(?ms)^\s*lines\s*=\s*\[(?<arr>.*?)^\]')
            if ($_lnsM.Success) {
                # PS 5.1-safe sentinel ([char]0x01) for \\ -- the
                # `` `u{0001} `` form is PS 7-only and leaks the literal
                # placeholder when the bootstrap runs in PS 5.1.
                $_eulaBs = [string][char]0x01 + 'BS' + [string][char]0x01
                $_parsed = @()
                foreach ($_lm in [regex]::Matches($_lnsM.Groups['arr'].Value, '"((?:[^"\\]|\\.)*)"')) {
                    # Unescape JSON-style \" \\ \n \t in the toml string
                    $_v = $_lm.Groups[1].Value
                    $_v = $_v -replace '\\\\', $_eulaBs
                    $_v = $_v -replace '\\"',   '"'
                    $_v = $_v -replace '\\n',   "`n"
                    $_v = $_v -replace '\\t',   "`t"
                    $_v = $_v -replace [regex]::Escape($_eulaBs), '\'
                    $_parsed += $_v
                }
                if ($_parsed.Count -gt 0) { $_eulaLines = $_parsed }
            }
        }
    }
    # Convert to a PS array literal that's safe to embed in the
    # double-quoted heredoc.  Single-quote each line and escape
    # single-quotes by doubling them (PS '' inside a single-quoted
    # string = literal ').
    $_eulaArrayLiteral = '@(' + (
        ($_eulaLines | ForEach-Object {
            "'" + ($_ -replace "'", "''") + "'"
        }) -join ', '
    ) + ')'

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

# -- UTF-8 codepage + Console encoding ------------------------------
# Operator-reported regression: powerline glyphs (U+E0B4 etc.) rendered
# as 'î' mojibake -- WT was decoding the UTF-8 bytes as cp1252 because
# this profile body wasn't setting chcp 65001 / Console.OutputEncoding.
# Setting both ensures every glyph oh-my-posh emits to stdout renders
# as the correct PUA cap, not the cp1252-mangled multi-char sequence.
try { & chcp.com 65001 *> `$null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new(`$false) } catch {}
try { `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false) } catch {}

# -- Window resize + center (every MiOS pwsh) --------------------
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

    # -- Import terminal completion modules ------------------------
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

    # -- PSReadLine reload -----------------------------------------
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

    # -- Resolve / self-heal MiOS artifact paths -------------------
    # M:\-everywhere invariant (operator: "irm|iex sets up M:\
    # disk/partition installs EVERYTHING to M:\ EVERYTHING").
    # M:\ is created at install time and never removed at runtime;
    # if it's missing, the install never completed and the operator
    # needs to re-run irm|iex.  The profile body falls back to a
    # warn rather than silently splitting state across drives.
    `$miosArtifactRoot = 'M:\MiOS'
    if (-not (Test-Path -LiteralPath `$miosArtifactRoot)) {
        Write-Host "  [!] M:\MiOS not found -- re-run the irm|iex bootstrap to provision M:\." -ForegroundColor Yellow
    }
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
        'M:\usr\share\mios\oh-my-posh\mios.omp.json'
    )
    # C:\* deliberately excluded -- M:\-everywhere invariant
    # (operator: EVERYTHING to M:\, no LOCALAPPDATA / C:\MiOS leaks).
    foreach (`$c in `$ompCands) {
        if (`$c -and (Test-Path -LiteralPath `$c)) { `$miosOmp = `$c; break }
    }
    if (-not `$miosOmp) {
        `$miosOmp = _MiosSelfHeal 'themes' 'mios.omp.json' '$ompBlobBase64'
    }

    # -- Framed MiOS dashboard (mirrors mios-dashboard.sh from mios.git) -
    # 80-col fixed frame, centered ASCII logo, framed fastfetch info.
    # Gated on WT_SESSION since the +-+ box-drawing only renders
    # properly in WT (conhost / VS Code embedded shell mangles it).
    function Show-MiosDashboard {
        param([string]`$ConfigPath, [string]`$LogoPath)
        # Width adapts to LIVE terminal width every render so the dashboard
        # always renders edge-to-edge. "dashboards
        # should be edge to edge globally!! 80x20 window is the Global
        # benchmark!" + "opening MiOS app and using things like fastfetch
        # and btop--things that clear the screen; ends up fitting the
        # dashboards in the same original window and tab--eventually".
        #
        # First-render timing: at session start, WT hasn't settled the
        # cell count yet. Solution: poll WindowWidth up to 5x with a
        # 50ms gap until it stabilizes (two consecutive reads agree),
        # then use the stable value. After fastfetch/btop run, WT has
        # fully settled and subsequent renders read correctly.
        `$_widthA = 0; `$_widthB = 0
        for (`$_i = 0; `$_i -lt 5; `$_i++) {
            `$_widthB = `$_widthA
            `$_winC = try { [Console]::WindowWidth } catch { 0 }
            `$_winR = try { `$Host.UI.RawUI.WindowSize.Width } catch { 0 }
            `$_widthA = if (`$_winC -gt 0 -and `$_winR -gt 0) { [math]::Min(`$_winC, `$_winR) }
                        elseif (`$_winC -gt 0) { `$_winC }
                        elseif (`$_winR -gt 0) { `$_winR }
                        else { 0 }
            if (`$_widthA -gt 0 -and `$_widthA -eq `$_widthB) { break }
            if (`$_i -lt 4) { Start-Sleep -Milliseconds 50 }
        }
        `$_winWNow = if (`$_widthA -gt 0) { `$_widthA } else { $_miosFrameW }
        `$WIDTH = `$_winWNow - $_miosRightMargin
        # Cap to mios.toml [terminal].frame_width (SSOT). WT's
        # WindowWidth poll is unreliable during the first ~200ms after
        # spawn -- it can return a value 4-8 cells wider than the
        # final viewport (focus-mode + acrylic backdrop allocation
        # haven't settled). Without this cap, host_os/CPU/font lines
        # render at the inflated WIDTH, then WT re-sizes the buffer
        # narrower, and every overflowing line wraps -- pushing the
        # top frame off-viewport. Capping to the toml value (the
        # operator-declared "this is what 80x20 means") guarantees
        # the dashboard never renders wider than the declared frame.
        # Operator-flagged "ie..." / "on..." wraps in
        # MiOS-WIN dashboard with top frame clipped off-screen.
        if ($_miosFrameW -gt 0 -and `$WIDTH -gt $_miosFrameW) {
            `$WIDTH = $_miosFrameW
        }
        if (`$WIDTH -lt 20) { `$WIDTH = [math]::Max(20, `$_winWNow) }
        `$INNER = `$WIDTH - 4
        `$TL=[char]0x256d; `$TR=[char]0x256e; `$BL=[char]0x2570; `$BR=[char]0x256f; `$LT=[char]0x251c; `$RT=[char]0x2524; `$V=[char]0x2502; `$H=[char]0x2500

        # Uniform frame color -- per "make the
        # entire frame 1 uniform colour--make it a complimenting colour
        # to the windows colour that's sourced from the toml fields that
        # are relevant to MiOS's color palette colours". MiOS canonical
        # accent (mios.toml [colors].accent + [branding.dashboard].frame_color)
        # is operator-blue (#1A407F = ANSI 34 = [ConsoleColor]::Blue).
        # Embed ANSI 34 around every `$V` border so the per-content rows
        # render their borders in the SAME color as the standalone
        # top/divider/bottom Write-Host calls (which use
        # -ForegroundColor Blue). Without this, _Frame/_Center returned
        # a plain string that Write-Host emitted in the inherited
        # foreground (often cream from the MiOS scheme), making per-row
        # borders visually different from top/divider/bottom borders.
        `$_esc      = [char]27
        `$_FrameC   = "`$_esc[34m"
        `$_FrameR   = "`$_esc[0m"

        function _Strip { param(`$s) `$s -replace '\x1b\[[0-9;]*m','' }
        function _Frame {
            param([string]`$Line)
            `$visible = _Strip `$Line
            if (`$visible.Length -gt `$INNER) {
                # Truncate with ellipsis preserving ANSI prefix.
                `$Line = `$Line.Substring(0, [math]::Min(`$Line.Length, `$INNER + (`$Line.Length - `$visible.Length) - 1)) + [char]0x2026
                `$visible = _Strip `$Line
            }
            `$pad = ' ' * [math]::Max(0, `$INNER - `$visible.Length)
            "`$_FrameC`$V`$_FrameR `$Line`$pad`$_FrameC `$V`$_FrameR"
        }
        function _Center {
            param([string]`$Line)
            `$visible = _Strip `$Line
            `$totalPad = [math]::Max(0, `$INNER - `$visible.Length)
            `$lpad = ' ' * [math]::Floor(`$totalPad / 2)
            `$rpad = ' ' * (`$totalPad - [math]::Floor(`$totalPad / 2))
            "`$_FrameC`$V`$_FrameR `$lpad`$Line`$rpad`$_FrameC `$V`$_FrameR"
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

        # Read mios.toml ONCE up-front so [dashboard].title (here),
        # [dashboard].rows + [theme.font] (further down) all read from
        # the same in-memory copy.  No fallback to other paths -- the
        # canonical layout is M:\etc\mios (host overlay) > M:\usr\share
        # (vendor on M:\).
        `$_dashTomlText = `$null
        foreach (`$_tc in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml')) {
            if (Test-Path -LiteralPath `$_tc) {
                try { `$_dashTomlText = [IO.File]::ReadAllText(`$_tc, (New-Object System.Text.UTF8Encoding(`$false))); break } catch {}
            }
        }

        # Top frame.
        Write-Host (`$TL + (`$H * (`$WIDTH - 2)) + `$TR) -ForegroundColor Blue
        if (`$_compact) {
            # 1-line title band -- resolves through mios.toml [dashboard].title
            # at runtime so the configurator HTML edits flow through to the
            # next render.  Vendor default is the technical descriptor
            # ("MiOS  --  Immutable Fedora AI Workstation"); operators who
            # want the friendly "My Personal Operating System" face on the
            # dashboard subtitle override [dashboard].title via mios.html.
            `$title = 'MiOS  --  My Personal Operating System'
            if (`$_dashTomlText) {
                `$_titleM = [regex]::Match(`$_dashTomlText, '(?ms)^\[dashboard\]\s*\r?\n.*?^\s*title\s*=\s*"([^"]+)"')
                if (`$_titleM.Success) { `$title = `$_titleM.Groups[1].Value }
            }
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

        # -- Compact metric rows ---------------------------------
        # Driven by mios.toml [dashboard].rows -- side-by-side fields
        # per row keep the dashboard at ~5 metric rows so 80x20 leaves
        # ample room for the prompt and command output.  Per operator
        # "the dash is set GLOBALLY to Windows and Linux
        # dashboards!! same settings!!! ... smaller metric can be
        # side-by-side in the dash; freeing up more room for the
        # prompt field."  The Linux-side mios-dashboard.sh reads the
        # same [dashboard] section.
        #
        # Field renderers fetch values via Get-CimInstance (single-
        # cached) / Get-Volume / `$PSVersionTable.  They each return a
        # short labeled string ("CPU AMD Ryzen 9 9950X3D 5.75GHz (32c)").
        # Unknown field-keys are silently skipped so the dashboard
        # is forward-compatible with future mios.toml additions.
        `$_dashCache = @{}
        `$_DashGetField = {
            param([string]`$_k, [string]`$_fontFam, [int]`$_fontSz)
            switch (`$_k) {
                'host_os' {
                    if (-not `$_dashCache.ContainsKey('_os')) {
                        `$_dashCache['_os'] = try { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { `$null }
                    }
                    `$_o = `$_dashCache['_os']
                    # Compact OS caption: strip Microsoft prefix, the
                    # "for Workstations" SKU suffix, "Insider Preview"
                    # marketing, "(64-bit)" arch (it's redundant -- the
                    # arch line covers it), and trailing whitespace.
                    # Operator-flagged "Windows 11 Pro for
                    # Workstations Insider Preview" overflowed the 80x20
                    # frame and wrapped, pushing the top frame off-screen.
                    `$_cap = if (`$_o -and `$_o.Caption) { ((((((`$_o.Caption -replace 'Microsoft\s*','') -replace '\s+for\s+Workstations','') -replace '\s+Insider\s+Preview','') -replace '\s*\(64-?bit\)','') -replace '\s*N\s+Edition','')).Trim() } else { 'Windows' }
                    return "`$env:USERNAME@`$env:COMPUTERNAME -- `$_cap".Trim()
                }
                'cpu' {
                    if (-not `$_dashCache.ContainsKey('_cpu')) {
                        `$_dashCache['_cpu'] = try { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { `$null }
                    }
                    `$_c = `$_dashCache['_cpu']
                    if (-not `$_c) { return 'CPU --' }
                    `$_n = (`$_c.Name -replace '\s+@.*','' -replace '\s+Processor','' -replace '\(R\)','' -replace '\(TM\)','').Trim()
                    `$_clk = if (`$_c.MaxClockSpeed) { [math]::Round(`$_c.MaxClockSpeed / 1000.0, 2) } else { 0 }
                    `$_co  = `$_c.NumberOfLogicalProcessors
                    return "CPU `$_n `${_clk}GHz (`${_co}c)"
                }
                {`$_ -in 'gpu_discrete','gpu_integrated'} {
                    if (-not `$_dashCache.ContainsKey('_gpus')) {
                        `$_dashCache['_gpus'] = try { @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch { @() }
                    }
                    `$_gs = `$_dashCache['_gpus']
                    if (-not `$_gs -or `$_gs.Count -eq 0) { return 'GPU --' }
                    if (`$_k -eq 'gpu_discrete') {
                        `$_g = `$_gs | Where-Object { `$_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro' } | Select-Object -First 1
                        if (-not `$_g) { `$_g = `$_gs | Sort-Object @{e={`$_.AdapterRAM};Descending=`$true} | Select-Object -First 1 }
                    } else {
                        `$_g = `$_gs | Where-Object { `$_.Name -match 'Radeon\(TM\) Graphics|Intel.*Graphics|UHD Graphics' } | Select-Object -First 1
                        if (-not `$_g) { return '' }
                    }
                    if (-not `$_g) { return 'GPU --' }
                    `$_n = (`$_g.Name -replace 'NVIDIA GeForce ','' -replace 'NVIDIA ','' -replace '\(R\)','' -replace '\(TM\)','').Trim()
                    `$_vr = if (`$_g.AdapterRAM) { [math]::Round(([uint32]`$_g.AdapterRAM) / 1GB, 1) } else { 0 }
                    if (`$_vr -le 0) { return "GPU `$_n" }
                    return "GPU `$_n `${_vr}GiB"
                }
                'ram' {
                    if (-not `$_dashCache.ContainsKey('_os')) {
                        `$_dashCache['_os'] = try { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { `$null }
                    }
                    `$_o = `$_dashCache['_os']
                    if (-not `$_o) { return 'RAM --' }
                    `$_tot = [math]::Round(([int64]`$_o.TotalVisibleMemorySize) / 1MB, 1)
                    `$_use = [math]::Round((([int64]`$_o.TotalVisibleMemorySize - [int64]`$_o.FreePhysicalMemory)) / 1MB, 1)
                    `$_pct = if (`$_o.TotalVisibleMemorySize -gt 0) { [math]::Round(((`$_use / `$_tot) * 100), 0) } else { 0 }
                    return "RAM `${_use} / `${_tot}GiB (`${_pct}%)"
                }
                'swap' {
                    if (-not `$_dashCache.ContainsKey('_pf')) {
                        `$_dashCache['_pf'] = try { Get-CimInstance Win32_PageFileUsage -ErrorAction Stop } catch { `$null }
                    }
                    `$_p = @(`$_dashCache['_pf'])
                    if (-not `$_p -or `$_p.Count -eq 0 -or -not `$_p[0]) { return 'Swap --' }
                    `$_tot = [math]::Round((`$_p | Measure-Object AllocatedBaseSize -Sum).Sum / 1024.0, 1)
                    `$_use = [math]::Round((`$_p | Measure-Object CurrentUsage -Sum).Sum / 1024.0, 1)
                    `$_pct = if (`$_tot -gt 0) { [math]::Round(((`$_use / `$_tot) * 100), 0) } else { 0 }
                    return "Swap `${_use} / `${_tot}GiB (`${_pct}%)"
                }
                {`$_ -match '^disk_([a-zA-Z])$'} {
                    # PowerShell switch with regex condition matches but
                    # does NOT reliably populate `$Matches in the action
                    # block scope -- saw `disk_c : err`
                    # in the dashboard because `$Matches[1]` was \$null and
                    # `$_dl` came back empty.  Parse the letter from `$_
                    # directly via Substring instead.
                    `$_dl = `$_.Substring(5,1).ToUpper()
                    `$_v  = try { Get-Volume -DriveLetter `$_dl -ErrorAction Stop } catch { `$null }
                    if (-not `$_v) { return "`${_dl}: --" }
                    `$_tot = [math]::Round(`$_v.Size / 1GB, 1)
                    `$_use = [math]::Round((`$_v.Size - `$_v.SizeRemaining) / 1GB, 1)
                    `$_pct = if (`$_v.Size -gt 0) { [math]::Round((((`$_v.Size - `$_v.SizeRemaining) / `$_v.Size) * 100), 0) } else { 0 }
                    return "`${_dl}: `${_use} / `${_tot}GiB (`${_pct}%)"
                }
                'kernel' {
                    return 'Kernel ' + [System.Environment]::OSVersion.Version.ToString()
                }
                'shell' {
                    return 'Shell pwsh ' + `$PSVersionTable.PSVersion.ToString()
                }
                'font' {
                    return "Font `$_fontFam `${_fontSz}pt"
                }
                'uptime' {
                    if (-not `$_dashCache.ContainsKey('_os')) {
                        `$_dashCache['_os'] = try { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { `$null }
                    }
                    `$_o = `$_dashCache['_os']
                    if (-not `$_o -or -not `$_o.LastBootUpTime) { return 'Up --' }
                    `$_up = (Get-Date) - `$_o.LastBootUpTime
                    `$_upd = [math]::Floor(`$_up.TotalDays)
                    return "Up `${_upd}d `$(`$_up.Hours)h `$(`$_up.Minutes)m"
                }
                default { return '' }
            }
        }

        # Parse [dashboard].rows + [theme.font] from the mios.toml text
        # we already loaded above for [dashboard].title.  Vendor defaults
        # baked in below if parsing fails (cold first-run before M:\
        # overlay is staged).
        `$_dashRows  = `$null
        `$_dashFontF = '$_themeFontFace'
        `$_dashFontS = $_themeFontSize
        if (`$_dashTomlText) {
            `$_dashSec = [regex]::Match(`$_dashTomlText, '(?ms)^\[dashboard\]\s*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
            if (`$_dashSec.Success) {
                `$_rowsM = [regex]::Match(`$_dashSec.Groups['body'].Value, '(?ms)^\s*rows\s*=\s*\[(?<arr>.*?)^\]')
                if (`$_rowsM.Success) {
                    `$_rowsBody = `$_rowsM.Groups['arr'].Value
                    `$_rowMatches = [regex]::Matches(`$_rowsBody, '\[(?<r>[^\]]*)\]')
                    `$_dashRows = @()
                    foreach (`$_rm in `$_rowMatches) {
                        `$_fields = @(`$_rm.Groups['r'].Value -split ',' | ForEach-Object { `$_.Trim().Trim('"',"'",' ',"``t","``r","``n") } | Where-Object { `$_ })
                        if (`$_fields.Count -gt 0) { `$_dashRows += ,`$_fields }
                    }
                    if (`$_dashRows.Count -eq 0) { `$_dashRows = `$null }
                }
            }
            # [theme.font] -- pick up runtime font overrides for the font field.
            `$_fontSec = [regex]::Match(`$_dashTomlText, '(?ms)^\[theme\.font\]\s*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
            if (`$_fontSec.Success) {
                `$_fb = `$_fontSec.Groups['body'].Value
                `$_fm = [regex]::Match(`$_fb, '(?m)^\s*family\s*=\s*"([^"]+)"')
                if (`$_fm.Success) { `$_dashFontF = `$_fm.Groups[1].Value }
                `$_sm = [regex]::Match(`$_fb, '(?m)^\s*size\s*=\s*(\d+)')
                if (`$_sm.Success) { `$_dashFontS = [int]`$_sm.Groups[1].Value }
            }
        }
        if (-not `$_dashRows) {
            `$_dashRows = @(@('host_os'),@('cpu','gpu_discrete'),@('ram','swap'),@('disk_c','disk_m'),@('kernel','shell','font'))
        }

        foreach (`$_row in `$_dashRows) {
            `$_n = @(`$_row).Count
            if (`$_n -le 0) { continue }
            # Equal-width columns within the framed inner area.
            `$_colW = [math]::Floor((`$INNER - (`$_n - 1) * 2) / `$_n)
            if (`$_colW -lt 8) { `$_colW = 8 }
            `$_cells = @()
            foreach (`$_fk in `$_row) {
                # Try/catch per-field so a single broken renderer
                # (e.g. Get-Volume not available, lspci missing) doesn't
                # kill the whole loop -- saw the
                # dashboard render only the first 3 rows and bail because
                # the disk_c renderer's Get-Volume call raised in a
                # context where the Storage module wasn't loaded.
                `$_val = ''
                try {
                    `$_val = & `$_DashGetField `$_fk `$_dashFontF `$_dashFontS
                } catch {
                    `$_val = "`$_fk : err"
                }
                if (-not `$_val) { `$_val = '' }
                if (`$_val.Length -gt `$_colW) {
                    `$_val = `$_val.Substring(0, [math]::Max(1, `$_colW - 1)) + [char]0x2026
                }
                `$_cells += `$_val.PadRight(`$_colW)
            }
            try {
                Write-Host (_Frame ((`$_cells -join '  ').TrimEnd()))
            } catch {
                # Frame helper failed (rare -- ANSI strip or PadRight
                # overflow); print a placeholder so the render flow
                # continues and the divider/hints/bottom frame land.
                Write-Host (_Frame "  [dashboard row render failed]")
            }
        }
        # -- MiOS services block ----------------------------------
        # refresh: parity with the Linux-side
        # mios-dashboard.sh services grid. Each cell is a
        # <dot> <name> :<port> probe row. Endpoints reachable from
        # the Windows host go through localhost (WSL2's
        # localhostForwarding mirrors the dev VM's listening sockets
        # to the Windows loopback automatically). When a probe
        # fails -- service is down OR forwarding misses (a known
        # WSL2 networking flake) -- we show the dot as off and
        # carry the row anyway so the layout stays stable.
        function _ProbeEp {
            param([string]`$Url, [int]`$TimeoutMs = 1500)
            try {
                `$req = [System.Net.WebRequest]::Create(`$Url)
                `$req.Timeout = `$TimeoutMs
                `$req.Method  = "GET"
                `$req.ServicePoint.Expect100Continue = `$false
                try { `$resp = `$req.GetResponse(); `$resp.Close() } catch {
                    if (`$_.Exception -is [System.Net.WebException] -and
                        `$_.Exception.Response -ne `$null) { return `$true }
                    return `$false
                }
                return `$true
            } catch { return `$false }
        }
        function _ServiceCell {
            param([string]`$Name, [int]`$Port, [string]`$Probe = "/",
                  [bool]`$Https = `$false)
            `$scheme = if (`$Https) { "https" } else { "http" }
            `$url = "`${scheme}://localhost:`${Port}`${Probe}"
            `$up  = _ProbeEp -Url `$url
            `$dot = if (`$up) { "`$_esc[32m*`$_esc[0m" } else { "`$_esc[90m-`$_esc[0m" }
            `$nm = `$Name.PadRight(11)
            "`$dot `$nm :`$(`$Port.ToString().PadRight(5))"
        }
        function _ServiceRow {
            param([string]`$L, [string]`$R)
            Write-Host (_Frame ("  `$L  `$R")) -ForegroundColor Blue
        }
        Write-Host (`$LT + (`$H * (`$WIDTH - 2)) + `$RT) -ForegroundColor Blue
        Write-Host (_Frame "  `$_esc[1m`$_esc[36mAI surface`$_esc[0m") -ForegroundColor Blue
        `$_c_agent  = _ServiceCell -Name "Agent-Pipe"  -Port $(Get-MiosTomlValue -Section 'ports' -Key 'agent_pipe' -Default 8640) -Probe "/health"
        `$_c_herm   = _ServiceCell -Name "Hermes"      -Port $(Get-MiosTomlValue -Section 'ports' -Key 'hermes' -Default 8642) -Probe "/health"
        `$_c_pg     = _ServiceCell -Name "pgvector"    -Port $(Get-MiosTomlValue -Section 'ports' -Key 'pgvector' -Default 8432)
        `$_c_dash   = _ServiceCell -Name "Dash-AI"     -Port $(Get-MiosTomlValue -Section 'ports' -Key 'hermes_dashboard' -Default 8119)
        `$_c_llm    = _ServiceCell -Name "LLM-Light"   -Port $(Get-MiosTomlValue -Section 'ports' -Key 'llm_light' -Default 8450)
        _ServiceRow `$_c_agent `$_c_herm
        _ServiceRow `$_c_pg    `$_c_dash
        _ServiceRow `$_c_llm   (' ' * 20)
        Write-Host (_Frame "  `$_esc[1m`$_esc[36mUser surface`$_esc[0m") -ForegroundColor Blue
        `$_c_webui  = _ServiceCell -Name "WebUI"       -Port $(Get-MiosTomlValue -Section 'ports' -Key 'open_webui' -Default 8033)
        `$_c_cock   = _ServiceCell -Name "Cockpit"     -Port $(Get-MiosTomlValue -Section 'ports' -Key 'cockpit' -Default 8090) -Https `$true
        `$_c_code   = _ServiceCell -Name "Code"        -Port $(Get-MiosTomlValue -Section 'ports' -Key 'code_server' -Default 8800)
        `$_c_forge  = _ServiceCell -Name "Forge"       -Port $(Get-MiosTomlValue -Section 'ports' -Key 'forge_http' -Default 8300)
        `$_c_srch   = _ServiceCell -Name "Search"      -Port $(Get-MiosTomlValue -Section 'ports' -Key 'searxng' -Default 8899)
        `$_c_ttyb   = _ServiceCell -Name "ttyd-bash"   -Port $(Get-MiosTomlValue -Section 'ports' -Key 'ttyd_bash' -Default 8681)
        `$_c_ttyp   = _ServiceCell -Name "ttyd-PS"     -Port $(Get-MiosTomlValue -Section 'ports' -Key 'ttyd_powershell' -Default 8682)
        _ServiceRow `$_c_webui `$_c_cock
        _ServiceRow `$_c_code  `$_c_forge
        _ServiceRow `$_c_srch  `$_c_ttyb
        _ServiceRow `$_c_ttyp  (' ' * 20)

        # -- Command hints rows -----------------------------------
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
                'M:\usr\share\mios\mios.toml'
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

    # NO inline-render here. The profile body is a thin function-
    # definition layer; the "what shows up on terminal spawn" is
    # whatever verb mios.toml [terminal.startup].windows points at.
    # The dispatch fires AT THE END of this profile (after the `mios`
    # verb function is defined). See the [terminal.startup] block
    # below the function definitions.
    # "have the bash and pwsh/WT environment/
    # dotfile(s) automatically run mios dash on open/launch--NOT
    # PRINT ON LAUNCH!!! THE ACTUAL ENV/DOTFILE(S) SHOULD DICTATE THE
    # COMMANDS/VERBS AND WHATS RUN ON CONSOLE SPAWN(ALL PLATFORMS
    # GLOBALLY)--ALL SOURCED FROM THE MIOS.TOML"

    # -- oh-my-posh init -------------------------------------------
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

# -- MiOS commands ---------------------------------------------------
# Defined in EVERY pwsh session (not gated on WT_SESSION) so the
# operator can run mios-build / mios-update / mios-help from any shell.
# Each command fetches its target script fresh from
# raw.githubusercontent.com so the operator doesn't have to manually
# pull the mios-bootstrap repo. Cache-busting via ?cb=<unix-time>
# defeats Fastly's 5-minute max-age.

`$Script:MiosBootstrapRaw = '$($Script:MiosBootstrapRaw)'

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

    # -- Step 1 + 2: configurator pass ------------------------------
    if (-not `$skipConfig) {
        `$cfgHtml = `$null
        foreach (`$c in @(
            'M:\usr\share\mios\configurator\mios.html',
            'M:\MiOS\usr\share\mios\configurator\mios.html'
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
            Write-Host '  [!] Configurator HTML not found on M:\ -- skipping edit pass.' -ForegroundColor Yellow
            Write-Host '      Run `mios pull` first to seed the overlay.' -ForegroundColor DarkGray
        }

        # -- Step 2: promote downloaded mios.toml from Downloads ----
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

    # -- Step 3: sync overlay so the build sees the latest mios.toml -
    # Note: this runs AFTER the Downloads-promote step so mios-pull
    # sees the just-promoted files in M:\etc\mios. mios-pull's git
    # reset --hard would otherwise blow away the operator's changes
    # if they lived in the tracked tree.
    if (-not `$skipPull) {
        Write-Host ''
        Write-Host '  [3/4] Syncing M:\ overlay (mios.git + mios-bootstrap)...' -ForegroundColor Cyan
        try { mios-pull } catch { Write-Host "  [!] mios-pull failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow }
    }

    # -- Step 4: ignite the build -----------------------------------
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
    # Probe for the actual on-disk WSL distro name. With the default
    # rename-skipped behavior (MIOS_RENAME_DISTRO unset), the distro is
    # 'podman-MiOS-DEV' (preserved from podman machine init so Podman
    # Desktop can see it). With opt-in rename, it's 'MiOS-DEV'. Either
    # works -- we resolve at call time so the helper survives both modes.
    `$_devDistro = `$null
    try {
        `$_wsl = (& wsl.exe -l -q 2>`$null) -split "`r?`n" |
            ForEach-Object { (`$_ -replace [char]0,'').Trim() } |
            Where-Object { `$_ }
        foreach (`$_cand in @('podman-MiOS-DEV','MiOS-DEV','podman-MiOS-BUILDER','MiOS-BUILDER')) {
            if (`$_wsl -contains `$_cand) { `$_devDistro = `$_cand; break }
        }
    } catch {}
    if (-not `$_devDistro) {
        Write-Host '  [!] No MiOS-DEV / podman-MiOS-DEV WSL distro registered. Run irm|iex one-liner to provision.' -ForegroundColor Yellow
        return
    }
    & wsl.exe -d `$_devDistro --cd / --user mios @Args
}

function mios-mini {
    # MINI dashboard -- the compact 80x20 framed banner + fastfetch
    # info. This is what fires on every shell spawn (vendor default
    # of [terminal.startup].verb). "have launch
    # be the mini-dashboard ... NOT PRINT ON LAUNCH" -- the dotfile
    # dispatches THIS verb so the render comes from a verb command,
    # not inline-print in the profile body.
    if (Get-Command Show-MiosDashboard -ErrorAction SilentlyContinue) {
        `$cfg  = if (Test-Path 'M:\MiOS\fastfetch\config.jsonc') { 'M:\MiOS\fastfetch\config.jsonc' } else { '' }
        `$logo = if (Test-Path 'M:\MiOS\fastfetch\mios.txt')      { 'M:\MiOS\fastfetch\mios.txt' }      else { '' }
        Show-MiosDashboard -ConfigPath `$cfg -LogoPath `$logo
    } else {
        Write-Host '  [!] mios mini: Show-MiosDashboard not loaded.' -ForegroundColor Yellow
    }
}

function mios-dash {
    # FULL MiOS dashboard -- ASCII banner + fastfetch (full width,
    # no compact frame trim) + MiOS-DEV service status + extended
    # sys specs. "the invoked 'mios dash'
    # command(s) runs the FULL MiOS dashboard; showing all service's
    # and relevant MiOS system specs too--include the MIOS ASCII
    # banner in the full dash!"
    `$_ascii = `$null
    foreach (`$_p in @('M:\MiOS\fastfetch\mios.txt','M:\usr\share\mios\branding\mios.txt')) {
        if (Test-Path -LiteralPath `$_p) { `$_ascii = `$_p; break }
    }
    if (`$_ascii) {
        Write-Host ''
        foreach (`$_l in (Get-Content -LiteralPath `$_ascii)) {
            Write-Host `$_l -ForegroundColor Blue
        }
        Write-Host ''
    }

    Write-Host '  MiOS -- Full system view' -ForegroundColor Cyan
    Write-Host '  ------------------------' -ForegroundColor DarkCyan

    # Sys specs via fastfetch (full module list, no frame).
    `$_ffCfg = if (Test-Path 'M:\MiOS\fastfetch\config.jsonc') { 'M:\MiOS\fastfetch\config.jsonc' }
              elseif (Test-Path 'M:\usr\share\mios\fastfetch\config.jsonc') { 'M:\usr\share\mios\fastfetch\config.jsonc' }
              else { `$null }
    if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
        if (`$_ffCfg) { & fastfetch -c `$_ffCfg --logo none } else { & fastfetch --logo none }
    } else {
        Write-Host '  [fastfetch unavailable]' -ForegroundColor DarkGray
    }

    # MiOS-DEV service status (Quadlets + portal + dev-VM-essentials).
    # Reads from the running podman-MiOS-DEV WSL distro via wsl.exe.
    Write-Host ''
    Write-Host '  MiOS-DEV services' -ForegroundColor Cyan
    Write-Host '  -----------------' -ForegroundColor DarkCyan
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        `$_distro = `$null
        foreach (`$_d in @('podman-MiOS-DEV','MiOS-DEV')) {
            try {
                `$_chk = & wsl.exe -d `$_d --user mios -- echo ready 2>`$null
                if (`$LASTEXITCODE -eq 0 -and `$_chk -match 'ready') { `$_distro = `$_d; break }
            } catch {}
        }
        if (`$_distro) {
            try {
                & wsl.exe -d `$_distro --user mios -- bash -lc 'systemctl --user list-units --type=service --state=active --no-legend --no-pager 2>/dev/null | head -30; echo ""; echo "graphical-session.target: `$(systemctl --user is-active graphical-session.target 2>/dev/null)"; echo "xdg-desktop-portal.service: `$(systemctl --user is-active xdg-desktop-portal.service 2>/dev/null)"; echo "podman.socket: `$(systemctl --user is-active podman.socket 2>/dev/null)"'
            } catch {
                Write-Host "  [!] failed to query MiOS-DEV services: `$_" -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [MiOS-DEV distro not running -- start with: mios dev]' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  [wsl.exe not available]' -ForegroundColor DarkGray
    }

    # Podman machine state (Windows host side).
    Write-Host ''
    Write-Host '  Podman machine' -ForegroundColor Cyan
    Write-Host '  --------------' -ForegroundColor DarkCyan
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        try { & podman machine list 2>&1 | Out-Host } catch {}
        try { & podman info --format '  Hostname:   {{.Host.Hostname}}
  Server OS:  {{.Host.OS}}
  CPUs:       {{.Host.CPUs}}
  Memory:     {{.Host.MemTotal}} bytes' 2>$null } catch {}
    } else {
        Write-Host '  [podman not on PATH]' -ForegroundColor DarkGray
    }
    Write-Host ''
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
    Write-Host '  mios ai       open Open WebUI (rich LLM interface) in your browser' -ForegroundColor White
    Write-Host '  mios dev      wsl into the MiOS-DEV distro (root /, user mios)' -ForegroundColor White
    Write-Host '  mios dash     FULL dashboard: ASCII banner + services + extended sys specs' -ForegroundColor White
    Write-Host '  mios xbox     Xbox VM Secure Boot / XML repair' -ForegroundColor White
    Write-Host '  mios virt     apply optimized VM config + CPU pinning' -ForegroundColor White
    Write-Host '  mios vfio     configure GPU/USB passthrough (Isolation)' -ForegroundColor White
    Write-Host '  mios help     this list' -ForegroundColor White
    Write-Host ''
}

# Unified `mios <verb>` dispatcher. Operator types `mios build` or
# `mios b<TAB>` (PSReadLine + the ArgumentCompleter below complete to
# `mios build`). Falls through to `mios-<verb>` so the same wrappers
# back both call shapes.
# Known verbs dispatch to mios-<verb>.ps1 wrappers in `$Global:MiosBin.
# Anything that isn't a known verb is routed to Hermes-Agent at
# MIOS_AI_ENDPOINT as a chat completion, so `mios how do I bootc switch`
# works from any PowerShell terminal without a separate `ask` verb.
`$Script:MiosKnownVerbs = @('build','update','pull','config','ai','dev','dash','mini','help','code','xbox','virt','vfio','tune','summary','profile','assess','iommu','theme','user')

function mios {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]`$Verb,
        [Parameter(ValueFromRemainingArguments)]
        `$Args
    )
    if (-not `$Verb) { `$Verb = 'help' }
    if (`$Script:MiosKnownVerbs -contains `$Verb.ToLowerInvariant()) {
        `$cmd = "mios-`$(`$Verb.ToLowerInvariant())"
        if (Get-Command `$cmd -ErrorAction SilentlyContinue) {
            & `$cmd @Args
        } else {
            Write-Host "  [!] mios: verb '`$Verb' wrapper not found. Try: mios help" -ForegroundColor Yellow
        }
        return
    }
    # Free-form query -> Hermes-Agent /v1/chat/completions.
    `$_query = (@(`$Verb) + @(`$Args)) -join ' '
    `$_ask = Join-Path `$Global:MiosBin 'mios-ask.ps1'
    if (Test-Path -LiteralPath `$_ask) {
        & `$_ask `$_query
    } else {
        Write-Host "  [!] mios-ask.ps1 not staged. Try: mios help" -ForegroundColor Yellow
    }
}

Register-ArgumentCompleter -CommandName mios -ParameterName Verb -ScriptBlock {
    param(`$cmdName, `$paramName, `$wordToComplete, `$cmdAst, `$fakeBoundParam)
    `$Script:MiosKnownVerbs |
        Where-Object { `$_ -like "`$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
}

# -- Interactive-shell startup verb (SSOT: mios.toml [terminal.startup]) --
# The profile body above is JUST function definitions. What runs on
# terminal spawn is the verb declared in mios.toml -- read fresh
# every shell launch so HTML configurator edits flow through with
# zero re-bake. Vendor default is "dash" but the operator can flip
# to any other verb (or "" for a silent shell).
#
# Per-platform key precedence: [terminal.startup].windows wins over
# [terminal.startup].verb (the cross-platform default). The Linux
# bash side reads the same TOML keys (.linux > .verb).
#
# Guards:
#   - `$env:MIOS_SKIP_MOTD = "1"      -> no startup verb fires.
#   - non-interactive host           -> no fire (background scripts,
#                                       VS Code's PowerShell extension
#                                       integrated terminal, etc.).
#   - `$Global:MiosStartupVerbFired   -> idempotent across re-sources
#                                       (mios.ps1 dot-sources this
#                                       profile to load functions, we
#                                       don't want a recursive verb
#                                       call inside an already-running
#                                       verb).
function _MiosResolveStartupVerb {
    `$_cands = @(
        (Join-Path `$env:USERPROFILE '.config\mios\mios.toml'),
        'M:\etc\mios\mios.toml',
        'M:\usr\share\mios\mios.toml'
    )
    foreach (`$_c in `$_cands) {
        if (-not (Test-Path -LiteralPath `$_c)) { continue }
        try {
            `$_t = [IO.File]::ReadAllText(`$_c, (New-Object System.Text.UTF8Encoding(`$false)))
        } catch { continue }
        `$_sec = [regex]::Match(`$_t, '(?ms)^\[terminal\.startup\]\s*\r?\n(?<body>.*?)(?=^\[[^\]]+\]|\z)')
        if (-not `$_sec.Success) { continue }
        `$_body = `$_sec.Groups['body'].Value
        # Per-platform key wins over cross-platform 'verb' key.
        `$_keys = @('windows','verb')
        foreach (`$_k in `$_keys) {
            `$_m = [regex]::Match(`$_body, ('(?m)^\s*' + [regex]::Escape(`$_k) + '\s*=\s*"([^"]*)"'))
            if (`$_m.Success) { return `$_m.Groups[1].Value.Trim() }
        }
    }
    # Vendor fallback: mini (the compact 80x20 framed banner).
    # `dash` is the FULL render -- ASCII banner + service status +
    # extended sys specs -- explicitly invoked by the operator,
    # not auto-fired on every shell spawn.
    return 'mini'
}

if (-not `$Global:MiosStartupVerbFired -and `$Host.UI.RawUI -and (-not `$env:MIOS_SKIP_MOTD)) {
    `$Global:MiosStartupVerbFired = `$true
    `$_startupVerb = _MiosResolveStartupVerb
    if (`$_startupVerb) {
        try { mios `$_startupVerb } catch {}
    }
}
"@
    # Write the profile body with explicit UTF-8 BOM. The body contains
    # Unicode box-drawing chars (+ + + + | - + +) for the dashboard
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

    # Append a diagnostic block to M:\MiOS\powershell\profile.ps1 that
    # writes [Console]::WindowWidth + BufferWidth + LASTEXITCODE-style
    # context to M:\MiOS\diagnostics\window-width.txt at every profile
    # load. Operators (and the AI agent debugging wrap issues) can read
    # this file to know the EXACT cell count WT is reporting on the
    # operator's hardware -- no more guessing right_margin values from
    # screenshots. Re-runs append (with timestamp) so we get a history
    # across MiOS WT launches. Per operator's 5-hour iteration spiral
    # STOP guessing margin values, measure the actual width.
    $diagBlock = @"

# -- MiOS WindowWidth diagnostic (auto-appended by Install-MiOSPowerShellProfile) --
# Every MiOS pwsh launch appends one line to M:\MiOS\diagnostics\window-width.txt
# capturing [Console]::WindowWidth + BufferWidth + WT_SESSION + timestamp.
# This is the SOURCE OF TRUTH for the actual visible cell count on the
# operator's hardware -- if WindowWidth != mios.toml [terminal].cols, the
# delta is the WT chrome budget that right_margin must absorb.
try {
    `$_diagDir = 'M:\MiOS\diagnostics'
    if (-not (Test-Path -LiteralPath `$_diagDir)) { New-Item -ItemType Directory -Path `$_diagDir -Force | Out-Null }
    `$_diagFile = Join-Path `$_diagDir 'window-width.txt'
    `$_ww = try { [Console]::WindowWidth } catch { '?' }
    `$_bw = try { `$Host.UI.RawUI.BufferSize.Width } catch { '?' }
    `$_wh = try { [Console]::WindowHeight } catch { '?' }
    `$_wt = if (`$env:WT_SESSION) { 'WT' } else { 'conhost-or-other' }
    `$_ts = (Get-Date).ToString('s')
    Add-Content -LiteralPath `$_diagFile -Value ("{0} WindowWidth={1} BufferWidth={2} WindowHeight={3} host={4} pwsh={5}" -f `$_ts, `$_ww, `$_bw, `$_wh, `$_wt, `$PSVersionTable.PSVersion)
} catch {}
# -- end MiOS WindowWidth diagnostic --
"@
    try {
        Add-Content -LiteralPath $miosProfileScript -Value $diagBlock -Encoding UTF8
        Write-Host "  [+] WindowWidth diagnostic appended to $miosProfileScript" -ForegroundColor DarkGray
    } catch {}
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

# -- Status helpers (used by Step-0 + Pass-2) ---------------------------------
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

function Ensure-Winget {
    # Bootstrap winget (Microsoft.DesktopAppInstaller) on a Windows host
    # that doesn't ship it. Win11 has it preinstalled; Win10 22H2 also
    # ships it; but Windows Server, Sandbox, debloated images, and very
    # fresh OOBE machines sometimes don't. winget is the prerequisite
    # for every package install downstream (WSL, Podman, Windows Terminal,
    # PowerShell 7, oh-my-posh, fastfetch, etc.) so failing here means
    # NOTHING else installs.
    #
    # Operator directive "Make sure the irm|iex installer
    # can STILL install on a fresh Windows System with NOTHING installed".
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $v = (& winget --version 2>&1) -join ' '
        Write-Host "  [+] winget already present ($v)" -ForegroundColor DarkGray
        return $true
    }

    Write-Host "  [*] winget not found -- bootstrapping Microsoft.DesktopAppInstaller..." -ForegroundColor Cyan

    # Path A: Add-AppxPackage from the official Microsoft delivery URL.
    # The bundle includes winget + its dependencies (UI.Xaml, VCLibs).
    # URL is the documented one Microsoft Learn points operators at.
    $appxUrl = 'https://aka.ms/getwinget'
    $tmpMsix = Join-Path $env:TEMP "mios-winget-bootstrap-$(Get-Random).msixbundle"
    try {
        Write-Host "    [.] Downloading $appxUrl -> $tmpMsix" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $appxUrl -OutFile $tmpMsix -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path $tmpMsix -ErrorAction Stop
        Write-Host "  [+] winget installed via Add-AppxPackage" -ForegroundColor Green
        Remove-Item -LiteralPath $tmpMsix -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [!] Add-AppxPackage Microsoft.DesktopAppInstaller failed: $($_.Exception.Message)" -ForegroundColor Yellow

        # Path B: PowerShell module fallback. Microsoft.WinGet.Client
        # ships a Repair-WinGetPackageManager cmdlet that mirrors the
        # MSIX bootstrap and handles dependency ordering on Server SKUs.
        try {
            Write-Host "    [.] Falling back to Microsoft.WinGet.Client module..." -ForegroundColor DarkGray
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -AcceptLicense -ErrorAction Stop
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            Repair-WinGetPackageManager -AllUsers -ErrorAction Stop
            Write-Host "  [+] winget installed via Microsoft.WinGet.Client" -ForegroundColor Green
        } catch {
            Write-Host "  [!] All winget bootstrap paths failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    # Verify it's now on PATH (Add-AppxPackage doesn't refresh the
    # current process's PATH; load the AppX path explicitly).
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $appxPath = (Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue).InstallLocation
        if ($appxPath -and (Test-Path "$appxPath\winget.exe")) {
            $env:PATH = "$appxPath;$env:PATH"
            Write-Host "  [+] winget added to current-process PATH ($appxPath)" -ForegroundColor DarkGray
        }
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        return $true
    }
    Write-Host "  [!] winget still not on PATH -- next-session reboot will surface it." -ForegroundColor Yellow
    return $false
}

function Enable-MiOSWindowsFeatures {
    # Detect + enable the OS-level features MiOS needs:
    #   Microsoft-Windows-Subsystem-Linux   -- WSL substrate
    #   VirtualMachinePlatform              -- WSL2 (HCS) + Hyper-V hypervisor
    #   Microsoft-Hyper-V                   -- Hyper-V Manager + VMs (Pro/Ent)
    #
    # All require admin (DISM-level feature toggles). Caller is responsible
    # for admin context -- Get-MiOS.ps1 self-elevates via UAC before any
    # call site reaches this function, so we hard-fail with a clear message
    # rather than silently skipping if we somehow land here as a normal user.
    #
    # "pwsh7+, podman, wsl, hyper-v, etc-etc are all
    # fecthed and installed during irm|iex installations -- THE FIRST
    # STEPS AFTER DISK CREATION". This function is Step 0.6 in Pass-2,
    # immediately after Initialize-DataDisk + Set-PodmanMachineStorageOnM
    # + Set-WingetStorageOnM + mios.toml promotion to M:\.
    #
    # Reboot policy: enables with -NoRestart and aggregates which features
    # required a reboot. Surfaces a clear warning at the end if any
    # reboot is pending; doesn't reboot automatically (operator-flagged:
    # NO automatic mid-install reboots).
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "  [!] Enable-MiOSWindowsFeatures needs admin -- deferring (auto-elevation will rerun this)." -ForegroundColor Yellow
        return $false
    }

    # TOML-first per AGENTS.md §3 -- feature DISM names resolve from
    # mios.toml [bootstrap.prereqs.features].* so operators can swap
    # Hyper-V for Hyper-V-Core, add Containers/SMBDirect, etc., via
    # mios.html. Order matters (WSL substrate before VMP before Hyper-V);
    # use [ordered] to preserve insertion order. Build via .Add() (void
    # return) instead of $features[k]=v to avoid any indexer-emit leak
    # into the function's pipeline output (operator-confirmed
    # the indexer-assignment form leaked the assigned value into the
    # function's return stream, making `$_featResult -eq 'reboot-required'`
    # filter-match a multi-element array even when rebootPending stayed
    # $false -- spurious Pass-2 halt despite all 3 features already
    # Enabled).
    $features = [ordered]@{}
    $features.Add([string](Get-MiosTomlValue -Section 'bootstrap.prereqs.features' -Key 'wsl'    -Default 'Microsoft-Windows-Subsystem-Linux'), 'Windows Subsystem for Linux')
    $features.Add([string](Get-MiosTomlValue -Section 'bootstrap.prereqs.features' -Key 'vmp'    -Default 'VirtualMachinePlatform'),            'Virtual Machine Platform (WSL2 + Hyper-V hypervisor)')
    $features.Add([string](Get-MiosTomlValue -Section 'bootstrap.prereqs.features' -Key 'hyperv' -Default 'Microsoft-Hyper-V'),                 'Hyper-V (manager + VMs)')

    $rebootPending = $false
    foreach ($name in $features.Keys) {
        $label = $features[$name]
        try {
            $state = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
        } catch {
            # Feature not present on this Windows edition (e.g. Hyper-V
            # absent on Home). Continue with the rest.
            Write-Host "  [-] $label not available on this Windows edition -- skipping." -ForegroundColor DarkGray
            continue
        }
        if ($state.State -eq 'Enabled') {
            Write-Host "  [+] $label already enabled." -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [*] Enabling $label..." -ForegroundColor Cyan
        try {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop
            if ($r.RestartNeeded) { $rebootPending = $true }
            Write-Host "  [+] $label enabled." -ForegroundColor Green
        } catch {
            Write-Host "  [!] Enable-WindowsOptionalFeature $name failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # --- WSL bootstrap on fresh Windows ----------------------------------
    # Fresh Windows 11 doesn't ship wsl.exe -- it's a separate Store-distributed
    # MSIX app since 2022. On a clean machine, DISM enables the Windows feature
    # ("Microsoft-Windows-Subsystem-Linux") but the actual wsl.exe binary +
    # the WSL kernel are downloaded from the Store. `wsl --install` (DISM-era
    # path) auto-pulls them on first run; we drive it explicitly so the
    # operator sees a known transcript instead of waiting on opaque downloads.
    #
    # Operator-flagged "MiOS should be running preview builds
    # of WSL. Make sure the irm|iex installer can STILL install on a fresh
    # Windows System with NOTHING installed".
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        # TOML-first -- WSL Store MSIX winget ID from mios.toml
        # [bootstrap.prereqs].wsl_pkg (operator can pin to Microsoft.WSL
        # preview channel via mios.html).
        $_wslPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'wsl_pkg' -Default 'Microsoft.WSL')
        Write-Host "  [*] wsl.exe not on PATH -- installing WSL ($_wslPkg via Microsoft Store MSIX)..." -ForegroundColor Cyan
        # Path A: winget install (preferred on Win11; pulls the Store version + dependencies)
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            try {
                & winget install --id $_wslPkg --silent --accept-source-agreements --accept-package-agreements 2>&1 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            } catch {
                Write-Host "  [!] winget install $_wslPkg : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        # Path B: fallback to `wsl --install --no-distribution` (works on
        # any Win10 22H2+ / Win11 with the Windows-feature already enabled).
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            try {
                $sysWsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
                if (Test-Path $sysWsl) {
                    Write-Host "  [*] Falling back to '$sysWsl --install --no-distribution'..." -ForegroundColor Cyan
                    & $sysWsl --install --no-distribution --web-download 2>&1 |
                        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                }
            } catch {
                Write-Host "  [!] wsl --install fallback failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # WSL kernel update + opt into PRE-RELEASE channel (preview builds).
    # `wsl --update` pulls the latest MSIX kernel from Microsoft Store;
    # `--pre-release` flag (added in WSL 2.0.0, available on every modern
    # Windows + WSL combo) opts into the preview build channel which has
    # the newer compositor + gnome-shell --nested fixes operator needs
    # for the Enhanced Session full-desktop path.
    # `--set-default-version 2` ensures wsl --install / `wsl --import`
    # use WSL2 (HCS via VirtualMachinePlatform) by default.
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        try {
            Write-Host "  [*] Running 'wsl --update --pre-release' (preview channel)..." -ForegroundColor Cyan
            & wsl.exe --update --pre-release 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            & wsl.exe --set-default-version 2 2>&1 | Out-Null
            Write-Host "  [+] WSL: preview channel + default version 2" -ForegroundColor Green
            # Surface what we actually got
            try {
                $verOut = (& wsl.exe --version 2>&1) -join "`n"
                Write-Host "  [.] wsl --version:" -ForegroundColor DarkGray
                $verOut -split "`n" | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            } catch {}
        } catch {
            Write-Host "  [!] wsl --update --pre-release: $($_.Exception.Message)" -ForegroundColor Yellow
            # Fallback: try without --pre-release in case the flag isn't
            # supported by the very-old WSL kernel installed.
            try { & wsl.exe --update 2>&1 | Out-Null } catch {}
            try { & wsl.exe --set-default-version 2 2>&1 | Out-Null } catch {}
        }
    } else {
        Write-Host "  [-] wsl.exe still not on PATH after install attempts -- next-session reboot may surface it." -ForegroundColor DarkGray
        $rebootPending = $true
    }

    if ($rebootPending) {
        # TOML-first -- mios.toml [bootstrap.prereqs.features].require_reboot_to_continue
        # decides whether Pass-2 halts here (so downstream WSL-dependent
        # steps don't cascade-fail) or surfaces a warning and continues.
        # Operator default: halt (true), since on a truly fresh Windows
        # the dev VM, podman machine init, and OCI build all REQUIRE the
        # reboot; trying to run them just produces noise + half-broken
        # state. Operator opts to "continue anyway and watch what
        # survives" by setting it to false in mios.html.
        $_haltOnReboot = ([string](Get-MiosTomlValue -Section 'bootstrap.prereqs.features' -Key 'require_reboot_to_continue' -Default 'true')) -ieq 'true'
        Write-Host ''
        Write-Host '  +==============================================================+' -ForegroundColor Yellow
        Write-Host '  | REBOOT PENDING -- Windows features enabled this session need |' -ForegroundColor Yellow
        Write-Host '  | a reboot to take full effect. WSL2, the dev VM, podman       |' -ForegroundColor Yellow
        Write-Host '  | machine init, and the OCI build will fail until you reboot.  |' -ForegroundColor Yellow
        Write-Host '  +==============================================================+' -ForegroundColor Yellow
        if ($_haltOnReboot) {
            Write-Host ''
            Write-Host '  REBOOT NOW, then re-run the irm|iex one-liner. Pass-0 reaps' -ForegroundColor Cyan
            Write-Host '  prior state automatically; the next run starts clean and'  -ForegroundColor Cyan
            Write-Host '  proceeds straight through.' -ForegroundColor Cyan
            Write-Host ''
            return [pscustomobject]@{ Status = 'ok';  RebootRequired = $true; HaltRequested = $true }
        }
        Write-Host '  [bootstrap.prereqs.features].require_reboot_to_continue=false ' -ForegroundColor DarkGray
        Write-Host '  -- continuing despite reboot-pending; expect cascade failures.' -ForegroundColor DarkGray
        Write-Host ''
        return [pscustomobject]@{ Status = 'ok'; RebootRequired = $true; HaltRequested = $false }
    }
    return [pscustomobject]@{ Status = 'ok'; RebootRequired = $false; HaltRequested = $false }
}

function Ensure-PodmanDesktop {
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Good "Podman already installed ($((podman --version) 2>&1))"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err "winget not found and podman not installed."
        Write-Err "  Install App Installer from the Microsoft Store, or install"
        Write-Err "  Podman CLI manually via the installer from https://podman.io (or github.com/containers/podman/releases)"
        exit 1
    }
    # Check if we should install Podman Desktop
    $_installDesktop = Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'install_podman_desktop' -Default $false
    if ($_installDesktop -eq 'true') { $_installDesktop = $true }
    elseif ($_installDesktop -eq 'false') { $_installDesktop = $false }
    if ($_installDesktop -isnot [bool]) { $_installDesktop = $false }

    if ($_installDesktop) {
        # Install Podman Desktop (the GUI). It bundles podman.exe inside its
        # resources tree -- but does NOT put it on PATH by default.
        # TOML-first -- Podman Desktop winget ID from mios.toml [bootstrap.prereqs].podman_pkg
        $_podmanPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'podman_pkg' -Default 'RedHat.Podman-Desktop')
        Write-Info "Installing Podman Desktop via winget ($_podmanPkg) ..."
        & winget install --exact --id $_podmanPkg `
            --silent --accept-source-agreements --accept-package-agreements `
            --scope machine 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            Write-Info "Retrying winget install at user scope ..."
            & winget install --exact --id $_podmanPkg `
                --silent --accept-source-agreements --accept-package-agreements 2>&1 |
                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
    # ALWAYS install RedHat.Podman (the CLI MSI) -- this is what actually
    # lays down podman.exe with PATH integration. Podman Desktop alone
    # bundles the CLI internally but doesn't expose it on PATH; the
    # standalone CLI package does. Idempotent: winget no-ops if already
    # present.
    # TOML-first -- Podman CLI MSI ID from mios.toml [bootstrap.prereqs].podman_cli_pkg
    $_podmanCliPkg = [string](Get-MiosTomlValue -Section 'bootstrap.prereqs' -Key 'podman_cli_pkg' -Default 'RedHat.Podman')
    Write-Info "Installing Podman CLI via winget ($_podmanCliPkg) ..."
    & winget install --exact --id $_podmanCliPkg `
        --silent --accept-source-agreements --accept-package-agreements `
        --scope machine 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Retrying CLI winget install at user scope ..."
        & winget install --exact --id $_podmanCliPkg `
            --silent --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    # Direct MSI download and silent installation fallback if winget failed/is missing
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        Write-Info "winget install failed or unavailable. Attempting direct MSI download and install of Podman CLI..."
        $podmanVersion = "6.0.0"
        try {
            $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/containers/podman/releases/latest" -UseBasicParsing -ErrorAction Stop
            if ($latestRelease.tag_name -match '^v?([0-9\.]+)$') {
                $podmanVersion = $Matches[1]
            }
        } catch {
            Write-Info "Failed to query latest version from GitHub API (offline or rate-limited). Using default fallback version v6.0.0"
        }
        $msiUrl = "https://github.com/containers/podman/releases/download/v$podmanVersion/podman-v$podmanVersion.msi"
        $msiPath = Join-Path $env:TEMP "podman-installer.msi"
        Write-Info "Downloading Podman CLI MSI from $msiUrl ..."
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($msiUrl, $msiPath)
            Write-Info "Installing Podman CLI silently via msiexec..."
            $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                Write-Err "msiexec exited with non-zero code: $($proc.ExitCode)"
            }
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Err "Direct MSI installation failed: $_"
        }
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

# -----------------------------------------------------------------------------
# Invoke-MiOSFullReap -- Phase 0 reap of every prior MiOS artifact
# -----------------------------------------------------------------------------
# Per feedback_mios_entry_full_reset memory:
#   "every irm|iex must reap ALL prior MiOS state: temp clones, persistent
#   clones, WSL distros (MiOS / MiOS-DEV / podman-MiOS-DEV / MiOS-BUILDER),
#   podman machines, Hyper-V VMs (MiOS-*), install dirs (M:\ contents +
#   %PROGRAMDATA%\MiOS / %LOCALAPPDATA%\MiOS / %APPDATA%\MiOS), Start Menu
#   shortcuts, registry uninstall key. No partial state; no carry-over."
# C:\MiOS + C:\mios-bootstrap are PROTECTED -- operator dev working trees
# of mios.git + mios-bootstrap.git per feedback_mios_no_c_drive_fallback.
#
# AND per "If the uninstaller actually uninstalled
# things automatically every time; I wouldn't have to Manually uninstall
# anything EVERY TIME it fails!!!!"
#
# Two callers:
#   1. Phase 0 of the irm|iex main flow -- runs BEFORE Initialize-DataDisk
#      so every install starts from zero state regardless of prior runs.
#   2. The top-level failure trap -- runs on any unhandled exception so a
#      half-broken install never leaves stale state behind.
#
# Idempotent: every block is wrapped in EAP=SilentlyContinue + try/catch so
# missing artifacts are no-ops. Logs each category's outcome to stdout in
# DarkGray so the operator sees what's being reaped without noise.
#
# Scope (matches uninstall.ps1's 12-category contract + Hyper-V + persistent
# clones):
#   1. Podman machines (MiOS-DEV, MiOS-BUILDER, plus any podman-MiOS-* WSL distro)
#   2. WSL distros (MiOS, MiOS-DEV, podman-MiOS-DEV, MiOS-BUILDER, podman-MiOS-BUILDER)
#   3. Hyper-V VMs matching MiOS-*
#   4. Install dirs: M:\ contents (everything except drive root metadata),
#      %PROGRAMDATA%\MiOS, %LOCALAPPDATA%\MiOS, %APPDATA%\MiOS.
#      NEVER C:\MiOS (operator dev tree of mios.git -- protected).
#   5. WT settings.json -- launchMode, profiles.defaults MiOS keys, MiOS scheme,
#      MiOS / MiOS-WIN / MiOS-DEV / podman-MiOS-* profiles
#   6. PowerShell profile redirector blocks (10 candidate paths, marker-delimited)
#   7. Fonts: Geist + symbols-only Nerd Font + matching HKCU font reg entries
#   8. PATH env entries pointing into M:\MiOS\bin (HKCU + HKLM)
#   9. HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS
#  10. Start Menu folder + Desktop .lnk shortcuts (every legacy variant)
#  11. AppUserModelID HKCU/HKLM\Software\Classes\AppUserModelId\MiOS.Workstation
#  12. podman-machine state symlinks (3 candidate paths)
#  13. MIOS_*/MiOS_* environment variables (HKCU + HKLM)
#
# Non-destructive: NEVER touches C:\mios-bootstrap OR C:\MiOS (both are
# operator dev clones -- may have uncommitted work), the operator's
# pwsh profile body outside the >>> MiOS ... >>> markers, or any
# non-MiOS WT profiles / schemes / fonts.
function Invoke-MiOSFullReap {
    param([switch]$Quiet)
    $reapEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    # SSOT: every operator-visible reap string resolves through
    # mios.toml [messages.reap].* with the hardcoded fallback as Default.
    # Per feedback_mios_messages_section_ssot: no Write-Host literals.
    $_msgBanner   = Get-MiosTomlValue -Section 'messages.reap' -Key 'banner'   -Default '[*] Phase 0: Reaping all prior MiOS state (zero-carry-over contract)...'
    $_msgComplete = Get-MiosTomlValue -Section 'messages.reap' -Key 'complete' -Default '[+] Phase 0 reap complete -- proceeding with fresh install.'
    $_lookupReap = {
        param([string]$Key, [string]$Default)
        $v = Get-MiosTomlValue -Section 'messages.reap' -Key $Key -Default $Default
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        return $v
    }

    $_log = {
        param([string]$msg, [string]$color = 'DarkGray')
        if (-not $Quiet) { Write-Host "    $msg" -ForegroundColor $color }
    }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host "  $_msgBanner" -ForegroundColor Cyan
    }

    # 1. Podman machines
    & $_log (& $_lookupReap 'category_1' '[1/13] podman machine stop + rm (MiOS-DEV, MiOS-BUILDER) ...')
    foreach ($mch in @('MiOS-DEV','MiOS-BUILDER','podman-MiOS-DEV','podman-MiOS-BUILDER')) {
        try { & podman machine stop $mch *>$null } catch {}
        try { & podman machine rm -f $mch *>$null } catch {}
    }
    try { & podman system reset --force *>$null } catch {}

    # 2. WSL distros (every variant the install pipeline has used)
    & $_log (& $_lookupReap 'category_2' '[2/13] wsl --unregister (MiOS, MiOS-DEV, podman-MiOS-*, MiOS-BUILDER) ...')
    foreach ($d in @('MiOS','MiOS-DEV','podman-MiOS-DEV','MiOS-BUILDER','podman-MiOS-BUILDER')) {
        try { & wsl.exe --unregister $d 2>$null | Out-Null } catch {}
    }
    try { & wsl.exe --shutdown 2>$null | Out-Null } catch {}

    # 3. Hyper-V VMs matching MiOS-*
    & $_log (& $_lookupReap 'category_3' '[3/13] Hyper-V VMs (MiOS-*) ...')
    try {
        if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
            Get-VM -Name 'MiOS-*' -ErrorAction SilentlyContinue | ForEach-Object {
                try { Stop-VM -Name $_.Name -TurnOff -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-VM -Name $_.Name -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}

    # 4. Install dirs. PROTECTED FROM REAP -- operator-owned dev trees:
    #   * C:\MiOS            -- dev working tree of mios.git (memory:
    #                            feedback_mios_no_c_drive_fallback;
    #                            ".git IS /" working tree). End consumers
    #                            never have this dir, so deleting it
    #                            only ever destroys operator dev work.
    # Operator-flagged after this
    #                            trap fired on a Phase-3 reap-on-failure
    #                            and wiped their checkout (uncommitted
    #                            edits unrecoverable -- no shadow copies).
    #   * C:\mios-bootstrap  -- dev working tree of mios-bootstrap.git
    #                            (same protected category).
    #
    # MiOS owns M:\ exclusively (see block below) + a few %ProgramData% /
    # %LOCALAPPDATA% / %APPDATA% caches that ARE install-managed.
    & $_log (& $_lookupReap 'category_4' '[4/13] Install dirs (%PROGRAMDATA%\MiOS, %LOCALAPPDATA%\MiOS, %APPDATA%\MiOS) -- skipping C:\MiOS + C:\mios-bootstrap ...')
    foreach ($p in @(
        (Join-Path $env:ProgramData    'MiOS'),
        (Join-Path $env:LOCALAPPDATA   'MiOS'),
        (Join-Path $env:APPDATA        'MiOS')
    )) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    # M:\ contents -- wipe everything at the drive root (the partition itself
    # stays; Initialize-DataDisk's idempotent check sees M:\ exists with
    # label=MIOS-DEV and skips re-creation). MiOS owns this entire volume.
    if (Test-Path -LiteralPath 'M:\') {
        try {
            Get-ChildItem -LiteralPath 'M:\' -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'System Volume Information' -and $_.Name -ne '$RECYCLE.BIN' } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
        } catch {}
    }

    # 5. WT settings.json -- remove only MiOS-set keys, preserve everything else
    & $_log (& $_lookupReap 'category_5' '[5/13] Windows Terminal settings.json (MiOS scheme + profiles + defaults) ...')
    foreach ($wtPath in @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
    )) {
        if (-not (Test-Path -LiteralPath $wtPath)) { continue }
        try {
            $raw = Get-Content -LiteralPath $wtPath -Raw
            $stripped = [regex]::Replace($raw, '(?ms)/\*.*?\*/', '')
            $stripped = [regex]::Replace($stripped, '(?m)^\s*//.*$', '')
            $stripped = [regex]::Replace($stripped, ',(\s*[\}\]])', '$1')
            $j = $stripped | ConvertFrom-Json -ErrorAction Stop
            $changed = $false
            if ($j.PSObject.Properties['launchMode'] -and $j.launchMode -in @('focus','maximizedFocus','focusFullscreen')) {
                $j.PSObject.Properties.Remove('launchMode'); $changed = $true
            }
            if ($j.profiles -and $j.profiles.defaults) {
                foreach ($k in @('scrollbarState','padding','useAcrylic','opacity','systemBackdrop','suppressApplicationTitle','disableAnimations','useAtlasEngine','experimental.detectURLs','experimental.input.forceVT','experimental.rendering.forceFullRepaint')) {
                    if ($j.profiles.defaults.PSObject.Properties[$k]) {
                        $j.profiles.defaults.PSObject.Properties.Remove($k); $changed = $true
                    }
                }
            }
            if ($j.schemes) {
                $keepSchemes = @($j.schemes | Where-Object { $_.name -ne 'MiOS' })
                if ($keepSchemes.Count -ne $j.schemes.Count) { $j.schemes = [object[]]$keepSchemes; $changed = $true }
            }
            if ($j.profiles -and $j.profiles.list) {
                $keepProfiles = @($j.profiles.list | Where-Object {
                    $_.name -ne 'MiOS' -and $_.name -ne 'MiOS-WIN' -and $_.name -ne 'MiOS-DEV' -and $_.name -ne 'MiOS-Bootstrap' -and $_.name -notmatch '^podman-MiOS-' -and $_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456789}' -and $_.guid -ne '{a8b5c2d3-e4f5-6789-abcd-ef0123456790}'
                })
                if ($keepProfiles.Count -ne $j.profiles.list.Count) { $j.profiles.list = [object[]]$keepProfiles; $changed = $true }
            }
            if ($changed) {
                ($j | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $wtPath -Encoding UTF8
            }
        } catch {}
    }

    # 6. PowerShell profile redirector blocks (marker-delimited removal)
    & $_log (& $_lookupReap 'category_6' '[6/13] PowerShell profile redirector blocks (MiOS markers) ...')
    function script:Remove-MiosMarkerBlock {
        param([string]$Text, [string]$StartMarker, [string]$EndMarker)
        while ($true) {
            $si = $Text.IndexOf($StartMarker)
            if ($si -lt 0) { return $Text }
            $ei = $Text.IndexOf($EndMarker, $si)
            if ($ei -lt 0) { return $Text }
            $endPos = $ei + $EndMarker.Length
            if ($endPos -lt $Text.Length -and $Text[$endPos] -eq "`r") { $endPos++ }
            if ($endPos -lt $Text.Length -and $Text[$endPos] -eq "`n") { $endPos++ }
            $Text = $Text.Substring(0, $si) + $Text.Substring($endPos)
        }
    }
    $pwshProfileCandidates = @(
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\profile.ps1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\WindowsPowerShell\profile.ps1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    ) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($pp in $pwshProfileCandidates) {
        if (-not (Test-Path -LiteralPath $pp)) { continue }
        try {
            $body = Get-Content -LiteralPath $pp -Raw
            $body = Remove-MiosMarkerBlock -Text $body -StartMarker '# >>> MiOS oh-my-posh init >>>' -EndMarker '# <<< MiOS oh-my-posh init <<<'
            $body = Remove-MiosMarkerBlock -Text $body -StartMarker '# >>> MiOS dash function >>>'   -EndMarker '# <<< MiOS dash function <<<'
            $body = $body.Trim()
            if ([string]::IsNullOrWhiteSpace($body)) {
                Remove-Item -LiteralPath $pp -Force -ErrorAction SilentlyContinue
            } else {
                Set-Content -LiteralPath $pp -Value $body -Encoding UTF8 -NoNewline
            }
        } catch {}
    }

    # 7. Fonts (Geist + Symbols-Only Nerd Font + matching HKCU reg entries)
    & $_log (& $_lookupReap 'category_7' '[7/13] Fonts (Geist*, *NerdFont*, SymbolsOnly*) + HKCU font reg ...')
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (Test-Path -LiteralPath $fontDir) {
        Get-ChildItem -LiteralPath $fontDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Geist|.*NerdFontMono|.*NerdFontPropo|.*NerdFont|SymbolsOnly|.*Symbols.*)' } |
            ForEach-Object {
                $fname = $_.Name
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                if (Test-Path -LiteralPath $fontReg) {
                    $face = [System.IO.Path]::GetFileNameWithoutExtension($fname)
                    foreach ($suffix in @(' (TrueType)',' (OpenType)')) {
                        $regName = "$face$suffix"
                        try { Remove-ItemProperty -LiteralPath $fontReg -Name $regName -ErrorAction SilentlyContinue } catch {}
                    }
                }
            }
    }

    # 8. PATH env (HKCU + HKLM if admin) -- strip M:\MiOS\bin entries
    & $_log (& $_lookupReap 'category_8' '[8/13] PATH env entries (M:\MiOS\bin from HKCU + HKLM) ...')
    foreach ($scope in @('User','Machine')) {
        try {
            $cur = [Environment]::GetEnvironmentVariable('Path', $scope)
            if (-not $cur) { continue }
            $parts = $cur -split ';' | Where-Object {
                $_ -and ($_ -notmatch '[Mm]:\\\\?MiOS\\\\bin') -and ($_ -notmatch '[Mm]:\\MiOS\\bin')
            }
            $new = ($parts -join ';')
            if ($new -ne $cur) {
                [Environment]::SetEnvironmentVariable('Path', $new, $scope)
            }
        } catch {}
    }

    # 9. HKCU uninstall reg key
    & $_log (& $_lookupReap 'category_9' '[9/13] HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\MiOS ...')
    $uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS'
    if (Test-Path -LiteralPath $uninstKey) {
        try { Remove-Item -LiteralPath $uninstKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    # 10. Start Menu folder + Desktop .lnk shortcuts (every legacy name)
    & $_log (& $_lookupReap 'category_10' '[10/13] Start Menu folder + Desktop .lnk shortcuts ...')
    $lnkNames = @(
        'MiOS.lnk','MiOS-WIN.lnk','MiOS-DEV.lnk','MiOS Config.lnk','MiOS Help.lnk','Uninstall MiOS.lnk',
        'MiOS Setup.lnk','Build MiOS.lnk','MiOS Configurator.lnk','MiOS Terminal.lnk',
        'MiOS Dev Shell.lnk','MiOS Podman Shell.lnk','MiOS Build.lnk','MiOS Dashboard.lnk',
        'MiOS Update.lnk','MiOS Pull.lnk'
    )
    $shortcutDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop'),
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\MiOS',
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MiOS')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
    # Desktop folders also collect Windows scratch artifacts like
    # `.tmp.driveu...` from disk-shrink/format operations. These aren't
    # MiOS-managed but they appear during the Initialize-DataDisk shrink
    # and confuse the operator (they look like leftover MiOS junk).
    # Reap any .tmp.* item from desktop dirs only (NOT Start Menu --
    # those are the actual install targets for MiOS shortcuts).
    foreach ($dir in $shortcutDirs) {
        if ($dir -match 'Desktop$') {
            try {
                Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '.tmp.*' -or $_.Name -like '*.tmp.driveu*' } |
                    ForEach-Object {
                        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                    }
            } catch {}
        }
        foreach ($ln in $lnkNames) {
            $lp = Join-Path $dir $ln
            if (Test-Path -LiteralPath $lp) {
                try { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        # Recursively remove MiOS\Linux Apps\ subfolder (Files / Web / VSCodium /
        # Flatseal / Extension Manager / Ptyxis / System Monitor / Settings)
        # created by Install-WindowsBranding's Linux Apps loop. Operator
        # "uninstaller STILL doesn't uninstall everything from
        # windows" -- the named-.lnk loop above left Linux Apps\ orphaned.
        if ($dir -match 'Start Menu\\Programs\\MiOS$') {
            $linuxAppsSub = Join-Path $dir 'Linux Apps'
            if (Test-Path -LiteralPath $linuxAppsSub) {
                try { Remove-Item -LiteralPath $linuxAppsSub -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        if ($dir -match 'Start Menu\\Programs\\MiOS$') {
            if ((Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                try { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    # 11. AppUserModelID HKCU/HKLM registrations
    & $_log (& $_lookupReap 'category_11' '[11/13] AppUserModelID (MiOS.Workstation) HKCU + HKLM ...')
    foreach ($aumKey in @(
        'HKCU:\Software\Classes\AppUserModelId\MiOS.Workstation',
        'HKLM:\Software\Classes\AppUserModelId\MiOS.Workstation'
    )) {
        if (Test-Path -LiteralPath $aumKey) {
            try { Remove-Item -LiteralPath $aumKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    # 12. podman-machine state symlinks (3 candidate paths)
    & $_log (& $_lookupReap 'category_12' '[12/13] podman-machine state symlinks (LOCALAPPDATA / .local\\share / ProgramData) ...')
    foreach ($pmLink in @(
        (Join-Path $env:LOCALAPPDATA 'containers\podman\machine'),
        (Join-Path $env:USERPROFILE  '.local\share\containers\podman\machine'),
        'C:\ProgramData\containers\podman\machine'
    )) {
        if (Test-Path -LiteralPath $pmLink) {
            try {
                $item = Get-Item -LiteralPath $pmLink -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.LinkType -eq 'SymbolicLink' -or $item.LinkType -eq 'Junction' -or $item.Target)) {
                    Remove-Item -LiteralPath $pmLink -Force -ErrorAction SilentlyContinue
                } elseif ($item) {
                    Remove-Item -LiteralPath $pmLink -Recurse -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

    # 13. MIOS_*/MiOS_*/BTOP_CONFIG_DIR environment variables (HKCU + HKLM)
    & $_log (& $_lookupReap 'category_13' '[13/17] MIOS_* + BTOP_CONFIG_DIR environment variables ...')
    foreach ($scope in @('User','Machine')) {
        try {
            $envKey = if ($scope -eq 'User') { 'HKCU:\Environment' }
                       else { 'HKLM:\System\CurrentControlSet\Control\Session Manager\Environment' }
            if (Test-Path -LiteralPath $envKey) {
                (Get-Item -LiteralPath $envKey).Property | Where-Object { $_ -match '^(MIOS_|MiOS_|BTOP_CONFIG_DIR$)' } |
                    ForEach-Object { try { Remove-ItemProperty -LiteralPath $envKey -Name $_ -ErrorAction SilentlyContinue } catch {} }
            }
        } catch {}
    }

    # 14. HKCU\Run autostart + kill mios-gui-watch.ps1 daemon
    & $_log '[14/17] HKCU\Run autostart entries + mios-gui-watch daemon + scheduled tasks ...'
    foreach ($runVal in @('MiOS-GuiWatch','MiOS','MiOSGuiWatch','MiOS-Autostart')) {
        try { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $runVal -ErrorAction SilentlyContinue } catch {}
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'mios-gui-watch' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}
    try {
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName 'MiOS-Autostart' -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        $stagedAutostart = Join-Path $env:ProgramData 'MiOS\mios-autostart.ps1'
        if (Test-Path $stagedAutostart) {
            Remove-Item -Path $stagedAutostart -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # 15. Windows Defender exclusions (paired with Add-MiosDefenderExclusions)
    & $_log '[15/17] Windows Defender exclusions (paths + processes) ...'
    try {
        if (Get-Command Remove-MpPreference -ErrorAction SilentlyContinue) {
            foreach ($excPath in @('M:\','M:\MiOS','M:\MiOS\bin','M:\MiOS\repo',(Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'),$env:TEMP)) {
                try { Remove-MpPreference -ExclusionPath $excPath -ErrorAction SilentlyContinue } catch {}
            }
            foreach ($excProc in @('pwsh.exe','wsl.exe','wslservice.exe','podman.exe','msrdc.exe')) {
                try { Remove-MpPreference -ExclusionProcess $excProc -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}

    # 16a. Windows Firewall inbound rules with the "MiOS -" prefix.
    # Paired with build-mios.ps1 :: Set-MiosLanFirewallRules. Sweep by
    # DisplayName prefix so we never touch operator-authored rules.
    & $_log '[16a/17] Windows Firewall rules (DisplayName "MiOS - *") ...'
    try {
        if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
            Get-NetFirewallRule -DisplayName 'MiOS - *' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { Remove-NetFirewallRule -InputObject $_ -ErrorAction SilentlyContinue } catch {}
                }
        }
    } catch {}

    # 16. WSL service host caches + any in-flight wslhost/msrdc procs
    & $_log '[16/17] Killing in-flight wslhost / msrdc / mios-gui-watch host processes ...'
    foreach ($pn in @('wslhost','msrdc','wsl','vmmemWSL')) {
        try { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { & wsl.exe --shutdown 2>$null | Out-Null } catch {}

    # 17. FULL FORMAT M:\ partition ("FULLY format
    # the M:\ partition only"). Only formats if M:\ exists AND its label
    # starts with MIOS (the partition we provisioned). NEVER repartitions,
    # never touches any other drive letter.
    & $_log '[17/17] Reformatting M:\ partition (NTFS, label MIOS-DEV) ...'
    try {
        $mVol = Get-Volume -DriveLetter M -ErrorAction SilentlyContinue
        if ($mVol -and $mVol.FileSystemLabel -match '^MIOS') {
            Format-Volume -DriveLetter M -FileSystem NTFS -NewFileSystemLabel 'MIOS-DEV' -Force -Confirm:$false -ErrorAction Stop | Out-Null
            & $_log '  [+] M:\ reformatted (NTFS, label MIOS-DEV, empty)'
        } else {
            & $_log '  M:\ not present or label != MIOS-DEV; skipping format (safety guard)'
        }
    } catch {
        & $_log ("  [!] M:\ format failed: " + $_.Exception.Message)
    }

    if (-not $Quiet) {
        Write-Host "  $_msgComplete" -ForegroundColor Green
        Write-Host ''
    }
    $ErrorActionPreference = $reapEAP
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
        # Install-robustness do NOT hard-exit on a box that cannot
        # free the full 256 GB (256/512 GB laptop SSDs, or a heavily-used C:).
        # CLAMP the data partition to the largest fittable size, down to a floor
        # ([bootstrap.host_storage].min_shrink_mb, default 64 GB); only abort if
        # even the floor won't fit -- and then `throw` (TRAPPABLE by the caller's
        # try/catch) instead of a bare `exit 1` (which terminated the whole
        # runspace, so the caller's catch + remediation never ran).
        $minShrinkMB = [int](Get-MiosTomlValue -Section 'bootstrap.host_storage' -Key 'min_shrink_mb' -Default 65536)
        $availBytes  = $cPart.Size - $supported.SizeMin
        if ($availBytes -ge ([int64]$minShrinkMB * 1MB)) {
            $clampMB     = [int]([math]::Floor($availBytes / 1MB)) - 1024   # ~1 GB headroom
            Write-Info "Requested $ShrinkMB MB exceeds the $([math]::Round($availBytes/1GB,1)) GB shrinkable on ${sysLetter}:; clamping ${DriveLetter}:\ to ~$([math]::Round($clampMB/1024,1)) GB (floor $([math]::Round($minShrinkMB/1024,1)) GB)."
            $ShrinkMB    = $clampMB
            $shrinkBytes = [int64]$ShrinkMB * 1MB
            $newCSize    = $cPart.Size - $shrinkBytes
        } else {
            Write-Err "Cannot shrink ${sysLetter}: by even the $([math]::Round($minShrinkMB/1024,1)) GB minimum."
            Write-Err "  current ${sysLetter}: size: $([math]::Round($cPart.Size/1GB,1)) GB"
            Write-Err "  max shrinkable:         $([math]::Round($availBytes/1GB,1)) GB"
            Write-Err "Free up ${sysLetter}: space (move pagefile / disable hibernation / clean up large files) and retry."
            throw "Initialize-DataDisk: insufficient shrinkable space on ${sysLetter}: (need >= $minShrinkMB MB, have $([math]::Round($availBytes/1MB)) MB)"
        }
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

# -- Functions-only dot-source gate -------------------------------------------
# Per "irm|iex is the main entry point for ALL things
# MiOS... FIX all in code!". The canonical entry is:
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex
# which falls through to the Pass-1 main flow below (M:\ provisioning + Step
# 1-8 chain + bootstrap.ps1 handoff). EVERY install path -- whether triggered
# by the irm|iex one-liner, the MiOS launcher, mios-update, or build-mios.ps1
# -- routes through these same Install-MiOS* functions so the deployed state
# is deterministic regardless of entry path.
#
# build-mios.ps1's Install-MiosLauncher dot-sources THIS script with
# $env:MIOS_GETMIOS_FUNCTIONS_ONLY=1 set so it can reuse the function
# definitions (Install-MiOSPowerShellProfile, Install-MiOSTerminalProfile,
# etc.) without re-entering the main flow. Without this gate, dot-sourcing
# would re-trigger Initialize-DataDisk + Step 1-8 + the bootstrap.ps1
# handoff, which would recurse infinitely (build-mios.ps1 was called BY
# bootstrap.ps1 in the first place).
if ($env:MIOS_GETMIOS_FUNCTIONS_ONLY) {
    # All function defs + $Script:Mios* vars (MiosBrandingTxt,
    # MiosFastfetchConfig, MiosOmpJson) above this point are now in
    # the caller's scope. Caller invokes Install-MiOSPowerShellProfile
    # / Install-MiOSTerminalProfile / etc. directly.
    return
}

# -- Step 0: M:\ provisioning BEFORE Pass-1 stages anything -------------------
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
# -- Defender exclusions BEFORE anything else --------------------------------
# 16:48 install: Microsoft Defender AMSI blocked
# build-mios.ps1 with "This script contains malicious content and has
# been blocked by your antivirus software". The C# Add-Type blocks for
# IPropertyStore + PROPVARIANT + StringToCoTaskMemUni (AppUserModelID
# stamping) match heuristic patterns that malware uses for shortcut-
# persistence -- false positive that kills the install.
#
# Pre-add Defender exclusions for the MiOS-owned paths so AMSI skips
# scanning them. Requires admin (Pass-2 elevated context). Wrapped in
# try/catch -- if the operator's Group Policy forbids Set-MpPreference,
# we continue silently and let AMSI do its thing (the bait-reduction
# refactor in build-mios.ps1 should keep most installs unblocked).
function Add-MiosDefenderExclusions {
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) { return }
    # SSOT: exclusion paths + processes resolve through mios.toml
    # [security.defender_exclusions].* with vendor defaults baked here.
    # Operator can add their own paths via mios.html -> mios.toml.
    $_defaultPaths = @(
        'M:\',
        'M:\MiOS',
        'M:\MiOS\bin',
        'M:\MiOS\repo',
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'),
        $env:TEMP
    )
    $_defaultProcs = @(
        'M:\MiOS\bin\mios-launch.exe',
        'M:\MiOS\bin\fastfetch.exe',
        'M:\MiOS\bin\btop.exe'
    )
    $excPaths = @(Get-MiosTomlValue -Section 'security.defender_exclusions' -Key 'paths'     -Default $_defaultPaths)
    $excProcs = @(Get-MiosTomlValue -Section 'security.defender_exclusions' -Key 'processes' -Default $_defaultProcs)
    foreach ($p in $excPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($p in $excProcs) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue } catch {}
    }
}
try { Add-MiosDefenderExclusions } catch { Write-Host "  [!] Defender exclusion add failed (non-fatal, AMSI may still block): $($_.Exception.Message)" -ForegroundColor Yellow }

# -- Pre-Phase-0: write .wslconfig BEFORE the very first wsl.exe call ---------
# Mirrored networking + firewall=false are read by WSL2 when the
# UTILITY VM starts. The utility VM starts on the FIRST wsl.exe
# invocation anywhere in this run -- and Invoke-MiOSFullReap below
# calls `wsl --unregister` + `wsl --shutdown` before anything else.
# If .wslconfig isn't on disk by then, the utility VM that those reap
# calls implicitly boot lands in legacy NAT mode and STAYS there until
# the next time someone explicitly stops it. Symptom the operator hit
# every container port (cockpit 8090, forge_http 8300,
# open_webui 8033, hermes 8642, searxng 8899, llm-light 8450) timed out from
# Windows even though `ss -tlnp` inside MiOS-DEV showed the binds, and
# the host showed `vEthernet (WSL (Hyper-V firewall))` (NAT-only
# adapter) instead of the IP-mirrored topology.
# build-mios.ps1 Phase 3 still writes .wslconfig before podman-machine
# init (belt-and-suspenders); this earlier write is what makes that
# work even after the reap's wsl.exe calls.
# Pre-Phase-0 .wslconfig writer -- TOML-first per AGENTS.md §3 / mios.toml
# is THE singular SSOT for every operator-visible value. Resolve from the
# layered overlay (~/.config > /etc > /usr/share); falls back to the
# safe default (NAT + localhostForwarding) on a fresh host where mios.toml
# isn't deployed yet. Mirrored mode opt-in: edit [wsl2].networking_mode
# in mios.html, save, re-run irm|iex (read the [wsl2] comment block in
# the vendor mios.toml for the prerequisites).
$_netMode  = [string](Get-MiosTomlValue -Section 'wsl2' -Key 'networking_mode'      -Default 'NAT')
$_lhfwd    = [string](Get-MiosTomlValue -Section 'wsl2' -Key 'localhost_forwarding' -Default 'true')
$_fwall    = [string](Get-MiosTomlValue -Section 'wsl2' -Key 'firewall'             -Default 'false')
$_gui      = [string](Get-MiosTomlValue -Section 'wsl2' -Key 'gui_applications'     -Default 'true')
$_isMirror = ($_netMode -ieq 'mirrored')

$_wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
$_wslCfgRaw = if (Test-Path $_wslCfg) { Get-Content $_wslCfg -Raw } else { "" }

# Build the section body from TOML-resolved values.
$_keyLines = New-Object System.Collections.Generic.List[string]
$_keyLines.Add("networkingMode=$_netMode")
if ($_isMirror) {
    if ($_fwall -ieq 'true') { $_keyLines.Add('firewall=true') }
} else {
    if ($_lhfwd -ieq 'true') { $_keyLines.Add('localhostForwarding=true') }
}
if ($_gui -ieq 'true') { $_keyLines.Add('guiApplications=true') }

# Detect divergence: any required key missing or value mismatched.
$_needWrite = $false
foreach ($_kv in $_keyLines) {
    $_pat = '^' + [regex]::Escape($_kv) + '\s*$'
    if ($_wslCfgRaw -notmatch $_pat) { $_needWrite = $true; break }
}
if ($_needWrite) {
    if ($_wslCfgRaw -notmatch "\[wsl2\]") {
        $_baseline = @"

[wsl2]
# MiOS pre-Phase-0 minimum, generated from mios.toml [wsl2].* by
# Get-MiOS.ps1 on every irm|iex. Edit values in mios.html, not here --
# this block is regenerated.
$($_keyLines -join "`r`n")
"@
        [System.IO.File]::WriteAllText($_wslCfg, $_baseline, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        # [wsl2] section exists -- replace its keys with the TOML-resolved
        # set. Strip ALL legacy networking keys (networkingMode,
        # localhostForwarding, firewall) so a prior mode doesn't survive.
        $_lines = Get-Content $_wslCfg
        $_in    = $false
        $_out   = [System.Collections.Generic.List[string]]::new()
        $_added = $false
        foreach ($_l in $_lines) {
            if ($_l -match '^\[wsl2\]') {
                $_in = $true; $_out.Add($_l)
                if (-not $_added) { foreach ($_kv in $_keyLines) { $_out.Add($_kv) }; $_added = $true }
                continue
            } elseif ($_l -match '^\[') { $_in = $false }
            if ($_in -and $_l -match '^(networkingMode|localhostForwarding|firewall|guiApplications)\s*=') { continue }
            $_out.Add($_l)
        }
        [System.IO.File]::WriteAllLines($_wslCfg, $_out, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "  [+] .wslconfig: $_netMode mode written from mios.toml [wsl2].* (pre-Phase-0)" -ForegroundColor Green
    & wsl.exe --shutdown 2>$null | Out-Null
}

# -- Phase 0: Reap ALL prior MiOS state BEFORE anything else -----------------
# Per feedback_mios_entry_full_reset memory: "every irm|iex must reap ALL
# prior MiOS state... No partial state; no carry-over." AND operator
# "If the uninstaller actually uninstalled things automatically
# every time; I wouldn't have to Manually uninstall anything EVERY TIME it
# fails!!!!". Runs UNCONDITIONALLY on every irm|iex invocation -- even if
# nothing prior is installed (idempotent no-op).
try { Invoke-MiOSFullReap } catch { Write-Host "  [!] Invoke-MiOSFullReap failed: $($_.Exception.Message)" -ForegroundColor Yellow }

# -- Failure-trap auto-reap --------------------------------------------------
# Operator contract "If the uninstaller actually uninstalled
# things automatically every time; I wouldn't have to Manually uninstall
# anything EVERY TIME it fails!!!!". Phase 0 reap above already handled the
# "next irm|iex starts clean" case. This trap handles the "current install
# fails mid-way" case -- terminating errors here trigger a final reap so
# Windows is left in zero-state immediately on failure (operator never sees
# half-broken state). Runs in addition to (not replacing) Phase 0.
#
# SSOT: every operator-visible string resolves through mios.toml
# [messages.failure_trap].* with the hardcoded fallback as Default.
$_trapFmtFailed = Get-MiosTomlValue -Section 'messages.failure_trap' -Key 'install_failed_template' -Default '[!!] Install failed: {0}'
$_trapAutoReap  = Get-MiosTomlValue -Section 'messages.failure_trap' -Key 'auto_reaping' -Default '[*]  Auto-reaping all MiOS state to leave Windows zero-state...'
$_trapReapDone  = Get-MiosTomlValue -Section 'messages.failure_trap' -Key 'reap_complete' -Default '[+]  Reap complete -- re-run irm|iex one-liner to retry from clean state.'
$_trapReapFail  = Get-MiosTomlValue -Section 'messages.failure_trap' -Key 'reap_on_failure_failed_template' -Default '[!] Reap-on-failure also failed: {0}'
trap {
    Write-Host ''
    Write-Host ('  ' + ($_trapFmtFailed -f $_.Exception.Message)) -ForegroundColor Red
    Write-Host "  $_trapAutoReap" -ForegroundColor Yellow
    try { Invoke-MiOSFullReap } catch {
        Write-Host ('  ' + ($_trapReapFail -f $_.Exception.Message)) -ForegroundColor Yellow
    }
    Write-Host "  $_trapReapDone" -ForegroundColor Green
    Write-Host ''
    exit 1
}

# SSOT: every Step N banner resolves through mios.toml [messages.steps].
# Per feedback_mios_messages_section_ssot: no Write-Host literals in code;
# vendor defaults via -Default arg of Get-MiosTomlValue.
$_msgStep0          = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_0_provision'      -Default '[*] Step 0: Provisioning M:\ partition + storage junctions...'
$_msgStep0Failed    = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_0_failed_template' -Default '[!] Initialize-DataDisk failed: {0}'
$_msgPodmanRedirect = Get-MiosTomlValue -Section 'messages.steps' -Key 'podman_storage_redirect' -Default 'Redirecting podman-machine storage to M:\\podman\\machine ...'
$_msgPodmanFailed   = Get-MiosTomlValue -Section 'messages.steps' -Key 'podman_storage_failed_template' -Default '[!] Set-PodmanMachineStorageOnM failed: {0}'
$_msgWingetRedirect = Get-MiosTomlValue -Section 'messages.steps' -Key 'winget_storage_redirect' -Default 'Redirecting winget package storage to M:\\winget\\* ...'
$_msgWingetFailed   = Get-MiosTomlValue -Section 'messages.steps' -Key 'winget_storage_failed_template' -Default '[!] Set-WingetStorageOnM failed: {0}'

Write-Host ''
Write-Host "  $_msgStep0" -ForegroundColor Cyan
try { Initialize-DataDisk } catch { Write-Host ('  ' + ($_msgStep0Failed -f $_.Exception.Message)) -ForegroundColor Yellow }
try {
    Write-Info $_msgPodmanRedirect
    Set-PodmanMachineStorageOnM
} catch { Write-Host ('  ' + ($_msgPodmanFailed -f $_.Exception.Message)) -ForegroundColor Yellow }

# Bootstrap winget on hosts that don't have it before any winget-consuming
# step runs (Set-WingetStorageOnM, Enable-MiOSWindowsFeatures' WSL Store
# install, Ensure-PodmanDesktop, Windows Terminal install, etc.).
# Fresh Win11 has it preinstalled; Server / Win10 / debloated images may not.
try { Ensure-Winget | Out-Null } catch { Write-Host "  [!] Ensure-Winget failed: $($_.Exception.Message)" -ForegroundColor Yellow }

try {
    Write-Info $_msgWingetRedirect
    Set-WingetStorageOnM
} catch { Write-Host ('  ' + ($_msgWingetFailed -f $_.Exception.Message)) -ForegroundColor Yellow }

# Step 0.5: Promote the fetched vendor mios.toml to BOTH M:\usr\share\mios
# and M:\etc\mios so the Windows-side dashboard / wrappers / Show-MiosDashboard
# read the same [dashboard].rows / [colors] / [ports] / [packages.windows]
# as the Linux side. Without this step Show-MiosDashboard falls back to its
# vendor row-layout when M:\etc\mios\mios.toml is missing or stale, and
# operator sees a different dashboard layout in pwsh vs in MiOS-DEV bash
# (operator-flagged "MIOS.TOML ISN'T USED GLOBALLY"). Idempotent:
# overwrites the M:\ overlay on every install with the live origin/main
# fetch so a re-run always picks up the latest configurator edits.
try {
    $_miosTomlText = Resolve-MiosTomlText
    if ($_miosTomlText) {
        foreach ($_tomlDst in @('M:\usr\share\mios\mios.toml', 'M:\etc\mios\mios.toml')) {
            $_tomlDstDir = Split-Path -Parent $_tomlDst
            if (-not (Test-Path -LiteralPath $_tomlDstDir)) {
                New-Item -ItemType Directory -Path $_tomlDstDir -Force | Out-Null
            }
            [IO.File]::WriteAllText($_tomlDst, $_miosTomlText, (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Host "  [+] mios.toml promoted to M:\usr\share\mios + M:\etc\mios (Windows = Linux dash parity)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [!] mios.toml fetch returned empty -- M:\ overlay not promoted (Show-MiosDashboard will use vendor defaults)" -ForegroundColor Yellow
    }
} catch {
    Write-Host ("  [!] mios.toml promotion to M:\ failed: $($_.Exception.Message)") -ForegroundColor Yellow
}

# Step 0.6: Enable Windows OS-level features MiOS depends on (WSL +
# VirtualMachinePlatform + Hyper-V). "pwsh7+,
# podman, wsl, hyper-v, etc-etc are all fecthed and installed during
# irm|iex installations -- THE FIRST STEPS AFTER DISK CREATION". This
# runs as Step 0.6 -- after Initialize-DataDisk + the storage redirects
# + mios.toml M:\ promotion, before Pass-1 Windows-user-scope setup.
# Requires admin; function self-checks and defers cleanly otherwise.
$_msgStep06 = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_0_6_features' -Default '[*] Step 0.6: Enabling Windows features (WSL + VirtualMachinePlatform + Hyper-V)...'
Write-Host ''
Write-Host "  $_msgStep06" -ForegroundColor Cyan
try { Ensure-MiOSWinget | Out-Null } catch { Write-Host "  [!] Ensure-MiOSWinget failed: $($_.Exception.Message)" -ForegroundColor Yellow }

# Hyper-V Firewall must allow inbound to the WSL VM. By default the WSL
# VM Creator GUID {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} is
# NotConfigured, which inherits a deny-all-inbound policy and silently
# drops every Windows-host -> WSL service request -- even when WSL2
# native localhostForwarding, the in-distro firewalld, AND the netsh
# portproxy are all open. Operator-confirmed with this
# setting NotConfigured, every browser hit on http://localhost:PORT/
# returned 000 across the entire MiOS stack. Setting it to Allow +
# Enabled is what unblocks the inbound path.
try {
    $_hvWslGuid = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
    if (Get-Command Set-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue) {
        Set-NetFirewallHyperVVMSetting -Name $_hvWslGuid `
            -Enabled True `
            -DefaultInboundAction Allow `
            -DefaultOutboundAction Allow `
            -LoopbackEnabled True `
            -AllowHostPolicyMerge True `
            -ErrorAction Stop
        Write-Host '  [+] Hyper-V Firewall: WSL VM creator set to Allow + LoopbackEnabled.' -ForegroundColor Green
    } else {
        Write-Host '  [!] Set-NetFirewallHyperVVMSetting cmdlet missing -- Windows < 11 22H2? Hyper-V firewall step skipped.' -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [!] Hyper-V Firewall config failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
try {
    # Capture into [pscustomobject] -- if the function leaks ANY pipeline
    # output (shouldn't, post-.Add refactor), grab the LAST
    # value (the explicit return) so the structured-result check can't be
    # confused by stray strings/objects upstream of the return statement.
    $_featOut = @(Enable-MiOSWindowsFeatures)
    $_featResult = $_featOut | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['HaltRequested'] } | Select-Object -Last 1
    if ($_featResult -and $_featResult.HaltRequested) {
        # Halt Pass-2 cleanly so downstream WSL/podman/build steps don't
        # cascade-fail. Operator-friendly exit per mios.toml
        # [bootstrap.prereqs.features].require_reboot_to_continue=true.
        Write-Host '  [*] Halting Pass-2 to await reboot (TOML-driven). Re-run the' -ForegroundColor Cyan
        Write-Host '      irm|iex one-liner after reboot to resume from clean state.' -ForegroundColor Cyan
        exit 0
    }
} catch { Write-Host "  [!] Enable-MiOSWindowsFeatures failed: $($_.Exception.Message)" -ForegroundColor Yellow }

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
        # SSOT: theme-apply success/failure messages from [messages.theme_apply].
        $_msgThemeOk     = Get-MiosTomlValue -Section 'messages.theme_apply' -Key 'applied'          -Default '[+] Windows global theme set to MiOS palette (dark mode + #1A407F accent + transparency).'
        Write-Host "  $_msgThemeOk" -ForegroundColor DarkGray
    } catch {
        $_msgThemeFail = Get-MiosTomlValue -Section 'messages.theme_apply' -Key 'failed_template' -Default '[!] Windows theme registry write failed: {0}'
        Write-Host ('  ' + ($_msgThemeFail -f $_.Exception.Message)) -ForegroundColor Yellow
    }

    # SSOT: Step 1/7..7/7 banners resolve through mios.toml [messages.steps].
    # "applications and icons should be installed AFTER
    # everything--at the end!!!! LAST STEPS". Step 8 (Install-MiOSNativeApp)
    # was relocated to the very end of Get-MiOS.ps1, AFTER bootstrap.ps1 +
    # build-mios.ps1's full phase loop succeeds. If the dev VM build fails
    # part-way, the failure-trap reap fires and NO shortcuts are ever
    # created -- operator never sees broken icons pointing at a half-built
    # dev VM. Steps 1-7 below stage the Windows-side basics ONLY.
    $_msgStep1     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_1_wt'           -Default '[*] Step 1/7: Installing Windows Terminal (base) via winget...'
    $_msgStep2     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_2_pwsh7'        -Default '[*] Step 2/7: Installing PowerShell 7 (pwsh) BEFORE WT profile creation...'
    $_msgStep3     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_3_wt_settings'  -Default '[*] Step 3/7: Patching WT settings.json with MiOS scheme + profiles...'
    $_msgStep4     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_4_geist_font'   -Default '[*] Step 4/7: Installing GeistMono Nerd Font (per-user, HKCU)...'
    $_msgStep5     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_5_fastfetch'    -Default '[*] Step 5/7: Installing fastfetch + staging MiOS-themed config...'
    $_msgStep6     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_6_omp'          -Default '[*] Step 6/7: oh-my-posh + PSReadLine + mios.omp.json + profile wiring...'
    $_msgStep7     = Get-MiosTomlValue -Section 'messages.steps' -Key 'step_7_extras'       -Default '[*] Step 7/7: Installing terminal completion / UX modules...'
    $_msgWtFailed  = Get-MiosTomlValue -Section 'messages.steps' -Key 'wt_failed_error'     -Default '[!] WT install failed -- bootstrap cannot continue without a themed WT to launch into.'
    $_msgWtHint    = Get-MiosTomlValue -Section 'messages.steps' -Key 'wt_failed_hint'      -Default '    Install manually and re-run: winget install Microsoft.WindowsTerminal'

    Write-Host "  $_msgStep1" -ForegroundColor Cyan
    if (-not (Install-MiOSWindowsTerminal)) {
        Write-Host "  $_msgWtFailed" -ForegroundColor Red
        Write-Host "  $_msgWtHint" -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "  $_msgStep2" -ForegroundColor Cyan
    Install-MiOSPwsh7               | Out-Null
    Write-Host "  $_msgStep3" -ForegroundColor Cyan
    Install-MiOSTerminalProfile     | Out-Null
    Write-Host "  $_msgStep4" -ForegroundColor Cyan
    Install-MiOSGeistFont           | Out-Null
    # Bibata cursor rides alongside the font install -- both are
    # operator-visible "global desktop chrome" touches that don't fit
    # neatly into a separate numbered step.
    # "cursor is still not bibata GLOBALLY".
    Install-MiOSBibataCursor        | Out-Null
    # Start Menu shortcuts for every Linux .desktop entry in the dev
    # VM (flatpak apps + native rpm apps + MiOS service launchers).
    # Uses Microsoft WSL's native shortcut pattern (wslg.exe target,
    # no console flash, .ico icons in %LOCALAPPDATA%\Temp\WSLDVCPlugin\
    # <distro>\) so apps appear in Windows search / Start with their
    # proper icons. Operator-flagged "opening WSL apps in
    # windows is NOT native WSL behaviour ... icons should be visible
    # for each application NATIVELY".
    try {
        $_shortcutScript = 'C:\MiOS\usr\libexec\mios\Update-MiOSStartMenuShortcuts.ps1'
        if (Test-Path $_shortcutScript) {
            & $_shortcutScript | Out-Null
        }
    } catch { Write-Host "  [!] Update-MiOSStartMenuShortcuts failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host "  $_msgStep5" -ForegroundColor Cyan
    Install-MiOSFastfetch           | Out-Null
    Write-Host "  $_msgStep6" -ForegroundColor Cyan
    Update-MiOSOhMyPosh             | Out-Null
    Update-MiOSPSReadLine           | Out-Null
    Install-MiOSOhMyPoshTheme       | Out-Null
    Install-MiOSPowerShellProfile   | Out-Null
    Write-Host "  $_msgStep7" -ForegroundColor Cyan
    Install-MiOSTerminalExtras      | Out-Null
    # NOTE: Install-MiOSNativeApp (canonical 4-shortcut creation) used to
    # run here as Step 8/8. Moved to the end-of-script "FINAL STEP"
    # block (post-bootstrap.ps1 success) per operator directive.

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
        $rawUrl = "$($Script:MiosBootstrapRaw)/Get-MiOS.ps1?cb=$([int][double]::Parse((Get-Date -UFormat %s)))"
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
# NOTE: Phase 0 above (Invoke-MiOSFullReap, called BEFORE Initialize-
# DataDisk on every irm|iex run) has already nuked every prior MiOS
# artifact on this machine: WSL distros, podman machines, Hyper-V VMs,
# install dirs (%PROGRAMDATA%\MiOS / %LOCALAPPDATA%\MiOS / %APPDATA%\MiOS),
# M:\ contents, WT MiOS scheme + profiles, Start Menu folder + Desktop
# .lnks, HKCU uninstall reg key, AppUserModelID regs, podman-machine
# state symlinks, MIOS_* env vars, fonts, PATH entries, MiOS Firewall
# rules.
#
# C:\MiOS + C:\mios-bootstrap are NEVER touched: both are operator-
# owned dev working trees of mios.git / mios-bootstrap.git (per the
# feedback_mios_no_c_drive_fallback memory). End consumers never have
# these dirs; reaping them only ever destroys operator dev work.
# Operator-flagged after C:\MiOS got nuked.
#
# Per feedback_mios_entry_full_reset memory +
# "every irm|iex must reap ALL prior MiOS state... No partial state;
# no carry-over." M:\ is the MiOS-owned 256 GB partition; the reap
# clears that + the AppData caches but never the dev-tree C:\ paths.

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
    # Install-robustness retry the clone 3x with backoff. A single
    # transient network blip (raw.githubusercontent / GitHub TLS reset) otherwise
    # aborted the ENTIRE irm|iex install at the entry. Each retry wipes the partial
    # clone so it starts clean.
    $cr = $null
    for ($_cattempt = 1; $_cattempt -le 3; $_cattempt++) {
        if (Test-Path $RepoDir) { Remove-Item -Recurse -Force $RepoDir -ErrorAction SilentlyContinue }
        $cr = Invoke-GitProc -ArgList @('clone','--branch',$Branch,'--depth','1',$RepoUrl,$RepoDir)
        if ($cr.ExitCode -eq 0) { break }
        if ($_cattempt -lt 3) {
            $_cbk = @(2,5,10)[$_cattempt-1]
            Write-Info "git clone attempt $_cattempt failed (exit $($cr.ExitCode)); retrying in ${_cbk}s (transient network?)..."
            Start-Sleep -Seconds $_cbk
        }
    }
    if ($cr.ExitCode -ne 0) {
        Write-Err "git clone $RepoUrl -> $RepoDir failed after 3 attempts (exit $($cr.ExitCode))."
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
$_bootstrapExit = $LASTEXITCODE

# -- FINAL STEP: applications + icons (operator directive) ------------------
# "applications and icons should be installed AFTER
# everything--at the end!!!! LAST STEPS". Only fires on bootstrap.ps1 +
# build-mios.ps1 success ($_bootstrapExit==0). On failure the trap-on-
# failure auto-reap above already wiped Windows clean -- no shortcuts
# pointing at a half-broken dev VM.
if ($_bootstrapExit -eq 0) {
    $_msgFinalStep = Get-MiosTomlValue -Section 'messages.steps' -Key 'final_step_native_app' -Default '[*] Final step: Registering MiOS as a native Windows app + canonical 4 shortcuts...'
    Write-Host ''
    Write-Host "  $_msgFinalStep" -ForegroundColor Cyan
    try { Install-MiOSNativeApp | Out-Null } catch {
        Write-Host "  [!] Install-MiOSNativeApp failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # MiOS service URLs as Windows Start Menu shortcuts (Cockpit, Code,
    # Workspace, Search, Forge, Dashboard, Guacamole). Drives the
    # mios.toml [desktop.start_menu] catalog -- WSLg's auto-publish
    # filter ignores xdg-open URL handlers, so we publish explicitly.
    try { Install-MiOSServiceShortcuts | Out-Null } catch {
        Write-Host "  [!] Install-MiOSServiceShortcuts failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# -- Bootstrap stops at DEV-ready --------------------------------------------
# (feedback_mios_dev_vm_is_builder_only.md):
#   "we aren't bootc switching podman-MiOS-DEV!!! WE NEED TO FIRST BOOT IN
#    TO podman-MiOS-DEV and have it working!!!! 'mios build' command is
#    for building OCI images from any MiOS app window"
#
# The dev VM is the BUILDER substrate -- podman-machine-os Fedora 44 with
# the MiOS overlay (Quadlets / RPM layer / flatpaks / branding) applied
# during Phase 3. It is NOT bootc-switched to localhost/mios:latest; that
# would conflate the builder with the deployment target. `mios build` is
# the operator-triggered verb that produces OCI + bootc-image-builder
# artifacts (vhdx / qcow2 / iso / raw / wsl tarball) for deploying to
# OTHER substrates. Output flows outward from the dev VM, never inward.
#
# Earlier commits (a307e4b ... 90aa799) auto-chained `mios build` here on
# the assumption that post-bootstrap = bootc-switched dev VM. Operator
# corrected: that's wrong. Bootstrap returns at DEV-ready; the staged
# MiOS hub shortcut + verb-hint banner above tell the operator what
# verbs to type next.

# -- WSLg host-side bridge reset (clears [WARN: COPY MODE]) ------------------
# "STILL no visible windows" -- weston / msrdc
# accumulate state during the multi-minute install (mid-install
# wsl.exe -- probes, daemon-reloads, container starts) that often
# leaves the host-side RDP-RAIL bridge stuck in COPY MODE even after
# our /mnt/wslg/runtime-dir chmod fix lands. A fresh `wsl --shutdown`
# + `Restart-Service LxssManager` on the Windows host gives WSLg a
# clean slate to negotiate VAIL (shared-memory) mode on first re-entry.
#
# Safe to run unconditionally at the END of irm|iex: bootstrap has
# already completed all its work, no in-flight operations to lose.
# The next time the operator launches MiOS, WSLg starts fresh.
if ($_bootstrapExit -eq 0) {
    try {
        Write-Host ''
        Write-Host '  [*] Resetting WSL/WSLg host-side state so the next launch starts clean...' -ForegroundColor Cyan
        & wsl.exe --shutdown 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        # Restart-Service requires admin; the irm|iex caller already
        # elevated, so this works. Failure is non-fatal -- shutdown
        # alone is usually enough.
        # WSL service name differs by Windows build: 'WslService' on Win11
        # Store/inbox WSL, 'LxssManager' on legacy Win10. Try both; skip
        # gracefully if neither exists ('Cannot find any service
        # with service name LxssManager' on Win11).
        $_wslSvcRestarted = $false
        foreach ($_svc in @('WslService','LxssManager')) {
            try { Restart-Service -Name $_svc -Force -ErrorAction Stop; $_wslSvcRestarted = $true; break } catch {}
        }
        if (-not $_wslSvcRestarted) {
            Write-Host "  [!] WSL service restart skipped: neither WslService nor LxssManager present (non-fatal)." -ForegroundColor DarkGray
        }
        Write-Host '  [+] WSLg reset complete -- next MiOS terminal launch starts with fresh RDP-RAIL state.' -ForegroundColor Green
    } catch {
        Write-Host "  [!] WSLg reset step failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

exit $_bootstrapExit
