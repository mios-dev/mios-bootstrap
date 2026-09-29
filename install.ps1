# AI-hint: Legacy entry point for MiOS full install. Redirects to MiOS-Field install.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$ErrorActionPreference = "Stop"

# Canonical launcher first; the defunct MiOS-Cat shim keeps older checkouts working.
$fieldPath = Join-Path $PSScriptRoot "field\MiOS-Field.ps1"
$catPath   = Join-Path $PSScriptRoot "field\MiOS-Cat.ps1"
if (-not (Test-Path $fieldPath) -and -not (Test-Path $catPath)) {
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/field/MiOS-Field.ps1"
    Invoke-RestMethod $url | Invoke-Expression
}

$target = if (Test-Path $fieldPath) { $fieldPath } elseif (Test-Path $catPath) { $catPath } else { $null }
if ($target) {
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    if ($ArgsList -and $ArgsList.Count -gt 0) {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $target "install" @ArgsList
    } else {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $target "install"
    }
}
exit $LASTEXITCODE
