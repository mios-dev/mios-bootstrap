# AI-hint: Legacy entry point for MiOS full install. Redirects to MiOS-Field install.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$ErrorActionPreference = "Stop"

$fieldPath = Join-Path $PSScriptRoot "field\MiOS-Field.ps1"
if (-not (Test-Path $fieldPath)) {
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/field/MiOS-Field.ps1"
    Invoke-RestMethod $url | Invoke-Expression
}

if (Test-Path $fieldPath) {
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    if ($ArgsList -and $ArgsList.Count -gt 0) {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $fieldPath "install" @ArgsList
    } else {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $fieldPath "install"
    }
}
exit $LASTEXITCODE
