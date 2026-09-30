# Legacy path retained for existing media. The canonical launcher is field/MiOS-Cat.ps1.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Verb = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$VerbArgs
)

$targetScript = Join-Path $PSScriptRoot "..\field\MiOS-Cat.ps1"
if (-not (Test-Path -LiteralPath $targetScript)) {
    Write-Error "[FATAL] Canonical field script not found at: $targetScript"
    exit 1
}

$psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$execArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $targetScript)
if ($Verb) { $execArgs += $Verb }
if ($VerbArgs) { $execArgs += $VerbArgs }

& $psBin @execArgs
exit $LASTEXITCODE
