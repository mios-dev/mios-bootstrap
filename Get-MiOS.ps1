# AI-hint: Legacy entry point for MiOS installation. Redirects to MiOS-Cat install.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$ErrorActionPreference = "Stop"

# Use local cat if available (cloned tree), otherwise fetch from main
$catPath = Join-Path $PSScriptRoot "cat\MiOS-Cat.ps1"
if (-not (Test-Path $catPath)) {
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/cat/MiOS-Cat.ps1"
    Invoke-RestMethod $url | Invoke-Expression
}

if (Test-Path $catPath) {
    & $catPath "install" @ArgsList
}
exit $LASTEXITCODE
