# AI-hint: Legacy entry point for MiOS full install. Redirects to MiOS-Cat install.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$ErrorActionPreference = "Stop"

$catPath = Join-Path $PSScriptRoot "field\MiOS-Cat.ps1"
if (-not (Test-Path $catPath)) {
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/field/MiOS-Cat.ps1"
    Invoke-RestMethod $url | Invoke-Expression
}

if (Test-Path $catPath) {
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    if ($ArgsList -and $ArgsList.Count -gt 0) {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $catPath "install" @ArgsList
    } else {
        & $psBin -NoProfile -ExecutionPolicy Bypass -File $catPath "install"
    }
}
exit $LASTEXITCODE
