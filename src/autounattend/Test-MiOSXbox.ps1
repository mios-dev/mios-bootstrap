<#
.SYNOPSIS
  MiOS-XBOX functionality self-test. Run ELEVATED inside the booted MiOS-XBOX
  (VM or hardware) after first-logon completes. Verifies the gaming-minimal Xbox
  surface, the debloat, Xbox FSE, the virt stack, and that the MiOS bootstrap
  deployed -- prints a PASS/FAIL report and exits non-zero if anything critical fails.

.DESCRIPTION
  This is the "boot it and test for Full MiOS functionalities" step. The wrapper
  Build-MiOSXbox.ps1 -TestVM boots the image; once MiOS first-logon finishes, run
  this inside that VM. Checks the SSOT expectations, not hardcoded assumptions:
  keep-set apps present, bloat absent, telemetry/consumer-features off, Xbox FSE
  override live, WSL2/VMP/Hyper-V enabled, MiOS-Host payload + bootstrap staged.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Test-MiOSXbox.ps1
#>
[CmdletBinding()]
param([switch]$Json)

$R = [System.Collections.Generic.List[object]]::new()
function Test-Item {
    param([string]$Name, [scriptblock]$Test, [switch]$Critical)
    $res = 'FAIL'; $detail = ''
    try { $v = & $Test; if ($v) { $res = 'PASS' } elseif ($v -is [string]) { $res = 'FAIL'; $detail = $v } }
    catch { $res = 'ERR'; $detail = $_.Exception.Message.Split([Environment]::NewLine)[0] }
    $R.Add([pscustomobject]@{ Check = $Name; Result = $res; Critical = [bool]$Critical; Detail = $detail })
}
function Test-Appx { param([string]$Name) [bool](Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue) -or [bool](Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $Name) }
function Get-Reg { param([string]$Path, [string]$Name) try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null } }
function Test-Feature { param([string]$Name) try { (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State -eq 'Enabled' } catch { $false } }

# --- KEEP-SET present (Xbox + MiOS requirements) ---
Test-Item 'Xbox app (GamingApp) present'        { Test-Appx 'Microsoft.GamingApp' } -Critical
Test-Item 'Xbox Identity Provider present'      { Test-Appx 'Microsoft.XboxIdentityProvider' }
Test-Item 'Microsoft Store present'             { Test-Appx 'Microsoft.WindowsStore' } -Critical
Test-Item 'winget (DesktopAppInstaller) present'{ Test-Appx 'Microsoft.DesktopAppInstaller' } -Critical
Test-Item 'Defender UI (SecHealthUI) present'   { Test-Appx 'Microsoft.SecHealthUI' }

# --- BLOAT absent ---
foreach ($b in 'Microsoft.MicrosoftSolitaireCollection','MSTeams','Microsoft.OutlookForWindows','Microsoft.YourPhone','Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.MicrosoftOfficeHub') {
    Test-Item "bloat absent: $b" ([scriptblock]::Create("-not (Test-Appx '$b')"))
}
Test-Item 'Edge absent (skip_edge)' { -not (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") }

# --- Debloat / privacy applied ---
Test-Item 'Telemetry policy AllowTelemetry=0'   { (Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry') -eq 0 }
Test-Item 'DiagTrack service disabled'          { (Get-Service DiagTrack -ErrorAction SilentlyContinue).StartType -eq 'Disabled' }
Test-Item 'Consumer features off'               { (Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures') -eq 1 }
Test-Item 'Copilot off'                         { (Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot') -eq 1 }

# --- Xbox Full Screen Experience override live ---
Test-Item 'Xbox FSE feature override present' {
    $ov = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8'
    [bool]((Get-ChildItem $ov -ErrorAction SilentlyContinue) | ForEach-Object { Get-Reg $_.PSPath 'EnabledState' } | Where-Object { $_ -eq 2 })
}

# --- Virt stack (the MiOS brain needs it) ---
Test-Item 'VirtualMachinePlatform enabled'      { Test-Feature 'VirtualMachinePlatform' } -Critical
Test-Item 'WSL feature enabled'                 { Test-Feature 'Microsoft-Windows-Subsystem-Linux' } -Critical
Test-Item 'Hyper-V enabled'                     { Test-Feature 'Microsoft-Hyper-V' }

# --- MiOS bootstrap deployed ---
Test-Item 'MiOS-Host payload staged'            { Test-Path 'C:\ProgramData\MiOS\MiOS-Host.ps1' } -Critical
Test-Item 'MiOS scheduled task registered'      { [bool](& schtasks.exe /query /tn 'MiOS-Host' 2>$null) -or [bool](& schtasks.exe /query /tn 'MiOS-FirstBoot' 2>$null) }
Test-Item 'MiOS repo cloned (bootstrap ran)'    { Test-Path 'C:\mios-bootstrap' }
Test-Item 'MiOS-DEV builder present (WSL)'      { [bool]((& wsl.exe -l -q 2>$null) -match 'MiOS') }
# MiOS AI front door -- only up once the Linux plane deployed; informational, not critical.
Test-Item 'MiOS AI endpoint :8642 reachable'    { try { $null = Invoke-WebRequest 'http://localhost:8642/v1/models' -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop; $true } catch { $false } }

# --- report ---
$pass = @($R | Where-Object Result -eq 'PASS').Count
$fail = @($R | Where-Object { $_.Result -ne 'PASS' })
$critFail = @($fail | Where-Object Critical)
if ($Json) {
    [pscustomobject]@{ total = $R.Count; pass = $pass; fail = $fail.Count; critical_fail = $critFail.Count; results = $R } | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    $R | ForEach-Object {
        $c = switch ($_.Result) { 'PASS' { 'Green' } 'FAIL' { if ($_.Critical) { 'Red' } else { 'Yellow' } } default { 'Red' } }
        Write-Host ('  [{0}] {1}{2}' -f $_.Result, $_.Check, $(if ($_.Detail) { "  -- $($_.Detail)" } else { '' })) -ForegroundColor $c
    }
    Write-Host ''
    Write-Host ("  {0}/{1} passed; {2} failed ({3} critical)" -f $pass, $R.Count, $fail.Count, $critFail.Count) -ForegroundColor $(if ($critFail.Count) { 'Red' } elseif ($fail.Count) { 'Yellow' } else { 'Green' })
}
exit ([int]($critFail.Count -gt 0))
