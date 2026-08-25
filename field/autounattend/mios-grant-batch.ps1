param([string]$User)
# ============================================================================
#  MiOS grant "Log on as a batch job" (SeBatchLogonRight)
#  Baked into install.wim at \Windows\Setup\Scripts\mios-grant-batch.ps1 and run
#  by the specialize pass (New-MiOSHostServiceCommands) right after the service
#  account is created, BEFORE the MiOS-Host / MiOS-Daemon tasks are registered.
#  WHY: offline diagnosis proved every scheduled task run as the svc account
#  registered but NEVER executed (no logs) -- a stored-password batch-logon
#  failure, so the MiOS brain never deployed. schtasks /create is supposed to
#  auto-grant this right, but in the specialize (SYSTEM/MINWINPC) context it did
#  not persist. Grant it explicitly via secedit so the account can log on + run.
#  Idempotent + non-fatal.
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\MiOS\logs\grant-batch.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function L($m) { "$([DateTime]::Now.ToString('HH:mm:ss')) $m" | Add-Content $log }
if (-not $User) { L 'no -User supplied'; exit 0 }
try {
    $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $inf = Join-Path $env:TEMP 'mios-batch.inf'
    $sdb = Join-Path $env:TEMP 'mios-batch.sdb'
    & secedit.exe /export /cfg $inf /areas USER_RIGHTS | Out-Null
    $lines = Get-Content $inf
    $out = New-Object System.Collections.Generic.List[string]
    $found = $false
    foreach ($l in $lines) {
        if ($l -match '^SeBatchLogonRight\s*=') {
            if ($l -notmatch [regex]::Escape($sid)) { $l = $l.TrimEnd() + ",*$sid" }
            $found = $true
        }
        $out.Add($l)
    }
    if (-not $found) {
        $idx = -1
        for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i] -match '^\[Privilege Rights\]') { $idx = $i; break } }
        if ($idx -ge 0) { $out.Insert($idx + 1, "SeBatchLogonRight = *$sid") }
        else { $out.Add('[Privilege Rights]'); $out.Add("SeBatchLogonRight = *$sid") }
    }
    $out | Set-Content $inf -Encoding Unicode
    & secedit.exe /import /cfg $inf /db $sdb | Out-Null
    & secedit.exe /configure /db $sdb /areas USER_RIGHTS | Out-Null
    Remove-Item $inf, $sdb -Force -ErrorAction SilentlyContinue
    L "granted SeBatchLogonRight to $User ($sid)"
} catch { L "grant failed: $($_.Exception.Message)" }
exit 0
