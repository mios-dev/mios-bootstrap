# MiOS-Cat.ps1 -- DEFUNCT backward-compat shim.
# MiOS-Cat is defunct. Delegates losslessly to the canonical MiOS-Field.ps1.
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$AllArgs)

$target = Join-Path $PSScriptRoot 'MiOS-Field.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Error "[FATAL] Canonical MiOS-Field.ps1 not found at: $target"
    exit 1
}
$psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
& $psBin -NoProfile -ExecutionPolicy Bypass -File $target @AllArgs
exit $LASTEXITCODE
