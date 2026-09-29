# field/lib/MiOS-Cat.psm1 -- backward-compat shim for MiOS-Cat.
# MiOS-Cat is DEFUNCT. This module exists only so old callers do not break.
# All implementations live in MiOS-Field.psm1.

$fieldLib = Join-Path $PSScriptRoot "MiOS-Field.psm1"
if (-not (Test-Path -LiteralPath $fieldLib)) {
    throw "[FATAL] Canonical MiOS-Field.psm1 not found at: $fieldLib"
}
Import-Module $fieldLib -Force -Global

# Alias old MiOS-Cat function names to their MiOS-Field counterparts.
Set-Alias -Name Show-MiOSCatMenu       -Value Show-MiOSFieldMenu       -Scope Global
Set-Alias -Name Invoke-MiOSCatStage    -Value Invoke-MiOSFieldStage    -Scope Global
Set-Alias -Name Invoke-MiOSCatVerify   -Value Invoke-MiOSFieldVerify   -Scope Global
Set-Alias -Name Invoke-MiOSCatInstall  -Value Invoke-MiOSFieldInstall  -Scope Global
Set-Alias -Name Invoke-MiOSCatBuild    -Value Invoke-MiOSFieldBuild    -Scope Global
Set-Alias -Name Invoke-MiOSCatUpdate   -Value Invoke-MiOSFieldUpdate   -Scope Global
Set-Alias -Name Invoke-MiOSCatProvision -Value Invoke-MiOSFieldProvision -Scope Global
Set-Alias -Name Invoke-MiOSCatManual   -Value Invoke-MiOSFieldManual   -Scope Global

Export-ModuleMember -Function Show-MiOSFieldMenu, `
    Invoke-MiOSFieldStage, `
    Invoke-MiOSFieldInstall, `
    Invoke-MiOSFieldBuild, `
    Invoke-MiOSFieldUpdate, `
    Invoke-MiOSFieldProvision, `
    Invoke-MiOSFieldVerify, `
    Invoke-MiOSFieldManual, `
    Expand-MiOSOCIImage, `
    Test-MiOSMediaLayout, `
    New-MiOSOCIArchive `
    -Alias Show-MiOSCatMenu, Invoke-MiOSCatStage, Invoke-MiOSCatVerify, `
           Invoke-MiOSCatInstall, Invoke-MiOSCatBuild, Invoke-MiOSCatUpdate, `
           Invoke-MiOSCatProvision, Invoke-MiOSCatManual
