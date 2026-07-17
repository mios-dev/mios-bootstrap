# AI-hint: MiOS-XBOX first-login runtime HYDRATION -- the one-time install of the Store-delivered gaming pieces that CANNOT be baked offline into the image (Gaming Services + the Edge WebView2 runtime + Store framework deps), because the MiOS-XBOX image strips Windows Update. Runs at first interactive logon (while the user signs into Xbox) as an ONLOGON task registered by the specialize-pass provisioner; polls the web via winget (msstore) + the WebView2 evergreen bootstrapper, installs/updates, is marker-gated + retries across logins, then self-removes. NOT baked because these are per-user/Store-serviced and version-churning.
# AI-related: mios-bootstrap, New-MiOSHostServiceCommands (MiOS-Provision.lib.ps1), New-MiOSAutounattend.ps1, New-MiOSISO.ps1, docs/pre-logon-system-services.md
#Requires -Version 5.1
<#
.SYNOPSIS
    First-login one-time hydration of the Store-delivered Xbox/gaming runtime that
    an offline, WU-stripped MiOS-XBOX image cannot bake: Gaming Services, the Edge
    WebView2 evergreen runtime, and the Store framework deps the Xbox app needs.

.DESCRIPTION
    Registered as an ONLOGON scheduled task (MiOS-XBOX-Hydrate) by the specialize
    provisioner, so it fires at the first interactive logon -- exactly while the user
    is signing into Xbox. It:
      * is marker-gated (C:\ProgramData\MiOS\hydrated.marker) so it is truly one-time;
      * RETRIES across logins if the network/Store isn't ready yet (Dev-channel builds
        + a fresh box often have no connectivity at first boot);
      * self-UNREGISTERS its task once complete;
      * degrades open (logs, never blocks the shell).

    Install channel = winget (Microsoft.DesktopAppInstaller, which the protect-list
    keeps) against the `msstore` source for the appx (Gaming Services / Xbox app), and
    the documented WebView2 evergreen bootstrapper for the runtime. Product IDs +
    the WebView2 URL come from SSOT with researched defaults.

.PARAMETER Products   msstore product IDs to ensure (default: Gaming Services + Xbox app).
.PARAMETER WebView2Url Evergreen bootstrapper URL.
.PARAMETER StateDir   Marker + log location.
.PARAMETER TaskName   The ONLOGON task to self-remove on success.
#>
[CmdletBinding()]
param(
    [string[]]$Products = @('9MWPM2CQNLHN', '9MV0B5HZVK9Z'),   # Gaming Services, Xbox app
    [string]$WebView2Url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
    [string]$StateDir = 'C:\ProgramData\MiOS',
    [string]$TaskName = 'MiOS-XBOX-Hydrate'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Join-Path $StateDir 'logs') | Out-Null
$log    = Join-Path $StateDir 'logs\hydrate.log'
$marker = Join-Path $StateDir 'hydrated.marker'
function Log { param([string]$m) "$([Environment]::TickCount) $m" | Out-File -Append -Encoding utf8 $log }

if (Test-Path $marker) { Log 'already hydrated -- removing task'; schtasks /delete /tn $TaskName /f *>$null; return }

# Need connectivity for the Store/web fetch; if offline, exit and let the next
# logon retry (the ONLOGON task stays registered until the marker is set).
# Probe TCP 443, NOT ICMP: Microsoft's edge (and many routers/firewalls) drop ICMP
# echo even when HTTPS works -- an ICMP gate would false-"offline" a fully online box
# and, since the marker is only set on success, no-op hydration forever.
if (-not (Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Log 'no network yet (TCP 443 to microsoft.com) -- will retry next logon'; return
}

$ok = $true

# 1) Edge WebView2 evergreen runtime (Xbox app account/store panels render in it).
try {
    if (-not (Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -eq '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' })) {
        $bs = Join-Path $env:TEMP 'MicrosoftEdgeWebview2Setup.exe'
        Invoke-WebRequest -Uri $WebView2Url -OutFile $bs -UseBasicParsing -TimeoutSec 120
        Start-Process -FilePath $bs -ArgumentList '/silent','/install' -Wait
        Log 'WebView2 runtime installed'
    } else { Log 'WebView2 already present' }
} catch { $ok = $false; Log "WebView2 FAILED: $($_.Exception.Message)" }

# 2) Store appx (Gaming Services, Xbox app) via winget msstore -- installs deps too.
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if ($winget) {
    foreach ($id in $Products) {
        try {
            & $winget install --id $id --source msstore --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
            Log "winget msstore $id -> exit $LASTEXITCODE"
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        } catch { $ok = $false; Log "winget $id FAILED: $($_.Exception.Message)" }
    }
} else {
    # Fallback: open the Store PDP so the user can finish (still one-time).
    $ok = $false
    foreach ($id in $Products) { Start-Process "ms-windows-store://pdp/?productid=$id" -ErrorAction SilentlyContinue }
    Log 'winget absent -- opened Store PDP(s) for manual completion; will retry'
}

# 3) Make sure Gaming Services + its service are live.
try {
    if (Get-AppxPackage -Name 'Microsoft.GamingServices' -ErrorAction SilentlyContinue) {
        foreach ($svc in 'GamingServices','GamingServicesNet') {
            if (Get-Service $svc -ErrorAction SilentlyContinue) { Set-Service $svc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service $svc -ErrorAction SilentlyContinue }
        }
        Log 'GamingServices present + service started'
    } else { $ok = $false; Log 'GamingServices still not installed' }
} catch { Log "GamingServices svc step: $($_.Exception.Message)" }

if ($ok) {
    New-Item -ItemType File -Force -Path $marker | Out-Null
    Log 'hydration COMPLETE -- marker set, removing task'
    schtasks /delete /tn $TaskName /f *>$null
} else {
    Log 'hydration incomplete -- will retry next logon (task kept)'
}
