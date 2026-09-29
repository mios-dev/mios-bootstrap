# MiOS-Cat.ps1 -- DEFUNCT shim in cat/. Delegates to canonical field/MiOS-Field.ps1.
# Folded losslessly to canonical installation conventions (ADR-0013, Task T-1118).
# Delegates directly to installation/mios-install.ps1.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Verb = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$VerbArgs
)

$targetScript = Join-Path $PSScriptRoot "..\installation\mios-install.ps1"
if (-not (Test-Path -LiteralPath $targetScript)) {
    $targetScript = Join-Path $PSScriptRoot "..\field\MiOS-Field.ps1"
}
if (-not (Test-Path -LiteralPath $targetScript)) {
    Write-Error "[FATAL] Canonical installation script not found at: $targetScript"
    exit 1
}

$psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$execArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $targetScript)
if ($Verb) { $execArgs += $Verb }
if ($Verb -in @('verify', 'stage') -and $VerbArgs -notcontains '-Unattended') {
    $execArgs += "-Unattended"
}
if ($VerbArgs) { $execArgs += $VerbArgs }

& $psBin @execArgs
exit $LASTEXITCODE
