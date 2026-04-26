# MiOS Public Bootstrap — Windows (PowerShell 5.1+)
# Repository: Kabuki94/MiOS-bootstrap
# Usage: irm https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.ps1 | iex

$ErrorActionPreference = "Stop"
$PrivateInstaller = "https://raw.githubusercontent.com/Kabuki94/mios/main/install.ps1"

function Read-Secret {
    param([string]$Prompt)
    Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return Read-Host -MaskInput
    }
    $sec  = Read-Host -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-WithDefault {
    param([string]$Prompt, [string]$Default = "")
    Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    if ($Default) { Write-Host "[$Default] " -NoNewline -ForegroundColor DarkGray }
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

Write-Host ""
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host "  |  MiOS -- Local Build Configuration                          |" -ForegroundColor Cyan
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host ""

# ── GitHub PAT (required for private repo access) ───────────────────────────
if (-not $env:GHCR_TOKEN) {
    $env:GHCR_TOKEN = Read-Secret "GitHub PAT (requires 'repo' scope):"
}
if (-not $env:GHCR_TOKEN) {
    Write-Host "  [!] Token required." -ForegroundColor Red; exit 1
}

Write-Host ""
Write-Host "  -- Build Configuration -----------------------------------------" -ForegroundColor Yellow
Write-Host ""

# ── Admin username ────────────────────────────────────────────────────────────
if (-not $env:MIOS_USER) {
    $env:MIOS_USER = Read-WithDefault "Admin username:" "mios"
} else {
    Write-Host "  Admin username: $($env:MIOS_USER)  (env)" -ForegroundColor DarkGray
}

# ── Admin password ────────────────────────────────────────────────────────────
if (-not $env:MIOS_PASSWORD) {
    while ($true) {
        $pw1 = Read-Secret "Admin password:"
        if (-not $pw1) { Write-Host "  [!] Password cannot be empty." -ForegroundColor Red; continue }
        $pw2 = Read-Secret "Confirm password:"
        if ($pw1 -eq $pw2) { $env:MIOS_PASSWORD = $pw1; break }
        Write-Host "  [!] Mismatch -- try again." -ForegroundColor Red
    }
} else {
    Write-Host "  Admin password: (env -- masked)" -ForegroundColor DarkGray
}

# ── Hostname ──────────────────────────────────────────────────────────────────
# Produces <base>-<5-digit> e.g. "kabu-ws-83427" -- unique per build
if (-not $env:MIOS_HOSTNAME) {
    $hbase = Read-WithDefault "Hostname base (5-digit suffix appended):" "mios"
    $suffix = '{0:D5}' -f (Get-Random -Minimum 10000 -Maximum 99999)
    $env:MIOS_HOSTNAME = "$hbase-$suffix"
} else {
    Write-Host "  Hostname: $($env:MIOS_HOSTNAME)  (env)" -ForegroundColor DarkGray
}

# ── Optional: GHCR push credentials ──────────────────────────────────────────
if (-not $env:MIOS_GHCR_USER) {
    Write-Host ""
    $env:MIOS_GHCR_USER = Read-WithDefault "GHCR push username [skip]:" ""
}
if ($env:MIOS_GHCR_USER -and -not $env:MIOS_GHCR_PUSH_TOKEN) {
    $pt = Read-Secret "GHCR push token [reuse GitHub PAT]:"
    $env:MIOS_GHCR_PUSH_TOKEN = if ($pt) { $pt } else { $env:GHCR_TOKEN }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  -- Summary -----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host ("    {0,-20} {1}" -f "Admin user:",    $env:MIOS_USER)
Write-Host ("    {0,-20} {1}" -f "Admin password:", "(masked)")
Write-Host ("    {0,-20} {1}" -f "Hostname:",       $env:MIOS_HOSTNAME)
$pushStr = if ($env:MIOS_GHCR_USER) { $env:MIOS_GHCR_USER } else { "none (local build only)" }
Write-Host ("    {0,-20} {1}" -f "Registry push:",  $pushStr)
Write-Host ""
$ok = Read-Host "  Proceed? [Y/n]"
if ($ok -and $ok.ToLower() -eq "n") { Write-Host "  Aborted."; exit 0 }

# ── Fetch and execute private installer ───────────────────────────────────────
$env:MIOS_AUTOINSTALL = "1"
$target = "$env:TEMP\mios-install-$(Get-Random).ps1"
$headers = @{ Authorization = "token $($env:GHCR_TOKEN)" }

Write-Host ""
Write-Host "  [+] Fetching private installer..." -ForegroundColor Gray
try {
    Invoke-WebRequest -Uri $PrivateInstaller -Headers $headers -OutFile $target -UseBasicParsing
    Write-Host "  [OK] Launching installer." -ForegroundColor Green
    Write-Host ""
    & $target
} catch {
    Write-Host "  [!] Failed to fetch installer. Check token and repo permissions." -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Gray
    exit 1
} finally {
    Remove-Item $target -ErrorAction SilentlyContinue
}
