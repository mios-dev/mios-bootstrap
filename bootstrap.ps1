# MiOS Public Bootstrap — Windows (PowerShell 5.1+)
# Repository: Kabuki94/MiOS-bootstrap
# Usage: irm https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.ps1 | iex

$ErrorActionPreference = "Stop"

$MiosAppDir = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosDocsDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "MiOS"

$MiosConfigDir = Join-Path $MiosAppDir "configs"
$MiosEnvDir = Join-Path $MiosAppDir ".env"
$MiosRepoDir = Join-Path $MiosAppDir "repo"
$MiosBuildsDir = Join-Path $MiosAppDir "builds"

$MiosDeployDir = Join-Path $MiosDocsDir "deployments"
$MiosManifestsDir = Join-Path $MiosDocsDir "manifests"
$MiosImagesDir = Join-Path $MiosDocsDir "images"

$PrivateInstaller = "https://raw.githubusercontent.com/Kabuki94/mios/main/install.ps1"
$EnvFile = Join-Path $MiosEnvDir "mios-build.env"
$SecretsFile = Join-Path $env:TEMP "mios-secrets.env"

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

function Import-EnvFile {
    param([string]$Path)
    Get-Content $Path | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $idx = $_.IndexOf('=')
        if ($idx -gt 0) {
            $k = $_.Substring(0, $idx).Trim()
            $v = $_.Substring($idx + 1).Trim()
            [System.Environment]::SetEnvironmentVariable($k, $v, "Process")
        }
    }
}

function Export-EnvFile {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = @(
        "# MiOS Build Configuration"
        "# Generated: $([System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "MIOS_USER=$env:MIOS_USER"
        "MIOS_HOSTNAME=$env:MIOS_HOSTNAME"
    )
    if ($env:MIOS_GHCR_USER)       { $lines += "MIOS_GHCR_USER=$env:MIOS_GHCR_USER" }
    $lines | Set-Content $Path -Encoding UTF8

    $secretLines = @(
        "GHCR_TOKEN=$env:GHCR_TOKEN"
        "MIOS_PASSWORD=$env:MIOS_PASSWORD"
    )
    if ($env:MIOS_GHCR_PUSH_TOKEN) { $secretLines += "MIOS_GHCR_PUSH_TOKEN=$env:MIOS_GHCR_PUSH_TOKEN" }
    $secretLines | Set-Content $SecretsFile -Encoding UTF8

    # Restrict secrets file to current user only
    try {
        $acl = Get-Acl $SecretsFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "FullControl", "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl $SecretsFile $acl
    } catch {
        Write-Host "  [!] Could not restrict secrets file permissions: $_" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host "  |  MiOS -- Local Build Configuration                          |" -ForegroundColor Cyan
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host ""

# ── Stage Directories ──────────────────────────────────────────────────────
Write-Host "  Staging MiOS environment..." -ForegroundColor Gray
foreach ($d in @($MiosConfigDir, $MiosEnvDir, $MiosRepoDir, $MiosBuildsDir, $MiosDeployDir, $MiosManifestsDir, $MiosImagesDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Configure Windows Subsystem for Linux (.wslconfig) ───────────────────
Write-Host "  Configuring WSL2 for MiOS..." -ForegroundColor Gray
try {
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $totalRAM = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    $wslRAM = [Math]::Max(16, [Math]::Floor($totalRAM / 1GB * 0.80))
    $wslCPUs = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $wslLines = @(
        "# MiOS v2.1.0 — WSL2 Configuration",
        "[wsl2]",
        "memory=${wslRAM}GB",
        "processors=${wslCPUs}",
        "swap=8GB",
        "localhostForwarding=true",
        "nestedVirtualization=true",
        "vmIdleTimeout=-1",
        "systemd=true",
        "",
        "[experimental]",
        "networkingMode=mirrored",
        "dnsTunneling=true",
        "autoProxy=true"
    )
    $wslConfig = $wslLines -join "`r`n"
    if (Test-Path $wslConfigPath) {
        $backup = "${wslConfigPath}.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $wslConfigPath $backup -Force
        Write-Host "  Backed up existing .wslconfig to $backup" -ForegroundColor DarkGray
    }
    $wslConfig | Set-Content $wslConfigPath -Encoding UTF8
    Write-Host "  [OK] .wslconfig generated: ${wslRAM}GB RAM, $wslCPUs CPUs" -ForegroundColor Green
} catch {
    Write-Host "  [!] Failed to configure .wslconfig: $_" -ForegroundColor DarkGray
}

# ── Load saved build config ───────────────────────────────────────────────
if (Test-Path $EnvFile) {
    Write-Host "  Found saved config: $EnvFile" -ForegroundColor DarkGray
    $loadOk = Read-Host "  Load previous build variables? [Y/n]"
    if (-not $loadOk -or $loadOk.ToLower() -ne "n") {
        Import-EnvFile $EnvFile
        if (Test-Path $SecretsFile) { Import-EnvFile $SecretsFile }
        Write-Host "  [OK] Loaded." -ForegroundColor Green
        Write-Host ""
    }
}

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
# Suffix is generated first so the user sees the full hostname in the prompt.
if (-not $env:MIOS_HOSTNAME) {
    $suffix = '{0:D5}' -f (Get-Random -Minimum 10000 -Maximum 99999)
    Write-Host "  Hostname base " -NoNewline -ForegroundColor White
    Write-Host "[mios] " -NoNewline -ForegroundColor DarkGray
    Write-Host "(suffix -$suffix is pre-generated -> mios-$suffix): " -NoNewline -ForegroundColor DarkGray
    $hbase = Read-Host
    if ([string]::IsNullOrWhiteSpace($hbase)) { $hbase = "mios" }
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
Write-Host ("    {0,-20} {1}" -f "Config saved to:", $EnvFile)
Write-Host ""
$ok = Read-Host "  Proceed? [Y/n]"
if ($ok -and $ok.ToLower() -eq "n") { Write-Host "  Aborted."; exit 0 }

# ── Save build config ─────────────────────────────────────────────────────────
Export-EnvFile $EnvFile
Write-Host "  [OK] Build config saved -> $EnvFile" -ForegroundColor Green

# ── Fetch and execute private installer ───────────────────────────────────────
$env:MIOS_AUTOINSTALL = "1"
$env:MIOS_DIR = $MiosRepoDir
$env:MIOS_BUILDS_DIR = $MiosBuildsDir
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
