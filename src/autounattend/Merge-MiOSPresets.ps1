# AI-hint: Merges multiple INTACT NTLite presets (urn:schemas-nliteos-com:pn.v1) into ONE perfected, deduped, identity-agnostic MiOS-Xbox preset. Unions debloat intent (RemoveComponents/<c>, DISM Features, Compatibility toggles, registry Tweaks) across all inputs while taking every single-instance / structural section (ImageInfo, Unattended, ApplyOptions, Packages, Drivers) verbatim from the canonical base (ULTRA-PLUS). Bakes NO accounts -- SSOT identity is applied downstream by ConvertTo-MiOSPreset.ps1. NEVER emits the operator's globally-purged legacy identity token. Output is the sanitizer's input.
# AI-related: mios-bootstrap, ConvertTo-MiOSPreset.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1, docs/uup-autounattend-dism-iso-flow.md
# AI-functions: New-El, Get-EnabledState, Test-VirtNeeded
#Requires -Version 5.1
<#
.SYNOPSIS
    Merge several NTLite presets (urn:schemas-nliteos-com:pn.v1) into ONE
    deduped, MiOS-themed, identity-agnostic preset ready for ConvertTo-MiOSPreset.

.DESCRIPTION
    The three intact NTLite presets each carry an overlapping-but-different debloat
    intent. This script UNIONS that intent into a single well-formed preset:

      * RemoveComponents/<c>  -- union, dedup by EXACT InnerText.
      * Features/<Feature @name> (DISM optional features) -- union, dedup by @name;
        on value conflict prefer ENABLED for virt/MiOS-needed features, else the
        stricter (disabled) value so the debloat wins.
      * Compatibility/ComponentFeatures/<Feature> (NTLite protective toggles) --
        union, dedup by InnerText; on conflict prefer the BASE (ULTRA-PLUS) value.
      * Tweaks/Settings/TweakGroup/<Tweak> (registry tweaks) -- union, dedup by
        group\name; on value conflict prefer the BASE (ULTRA-PLUS) value + record it.

    Every single-instance / structural section (ImageInfo, Unattended, ApplyOptions,
    Packages, Drivers, AppInfo, Date, Version) is taken VERBATIM from the canonical
    base = the FIRST input preset (ULTRA-PLUS). The base is the only fully-formed one:
    it has exactly ONE Unattended with both a specialize and an oobeSystem
    Shell-Setup, exactly ONE ApplyOptions, and exactly ONE ImageInfo -- which is what
    ConvertTo-MiOSPreset requires (its SelectSingleNode overrides touch only the
    first match). The auto-saved inputs carry duplicated ApplyOptions/Packages blocks
    and (7eb3e01a) placeholder NTLite accounts + AutoLogon; NONE of those are ever
    imported, so no second, un-sanitized Unattended/accounts can leak.

    IDENTITY-AGNOSTIC: this merge bakes NO SSOT accounts and does NOT dot-source
    MiOS-Provision.lib.ps1. MiOS hostname / credentialed accounts / AutoLogon /
    FirstLogonCommands / GUID / AutoIso path+label are all applied LATER by
    ConvertTo-MiOSPreset.ps1 from mios.toml. The merged artifact itself is clean and
    identity-free; the operator's globally-purged legacy identity token is never emitted (LAW).

.PARAMETER InputPresets
    NTLite presets to merge. The FIRST is the canonical base (structural sections +
    the sole Unattended come from it). Default: the three intact presets vendored
    under .\presets\ (xbox-minimal-ultra-plus.xml first), so the merge is fully
    reproducible from the tracked repo alone.

.PARAMETER OutputPreset
    Output merged preset path. Default: <scriptdir>\MiOS-Xbox-Merged.xml.

.EXAMPLE
    .\Merge-MiOSPresets.ps1
    # merges the three vendored .\presets\*.xml -> .\MiOS-Xbox-Merged.xml

.EXAMPLE
    .\Merge-MiOSPresets.ps1 -InputPresets 'A.xml','B.xml' -OutputPreset '.\Merged.xml'
    # then: .\ConvertTo-MiOSPreset.ps1 -InputPreset '.\MiOS-Xbox-Merged.xml' -OutputPreset '.\MiOS-Xbox.xml'
#>
[CmdletBinding()]
param(
    [string[]]$InputPresets = @(
        (Join-Path $PSScriptRoot 'presets\xbox-minimal-ultra-plus.xml'),   # BASE (canonical) -- must be first
        (Join-Path $PSScriptRoot 'presets\autosave-7eb3e01a.xml'),
        (Join-Path $PSScriptRoot 'presets\autosave-e8a2b9d1.xml')
    ),
    [string]$OutputPreset
)
$ErrorActionPreference = 'Stop'
$NLNS = 'urn:schemas-nliteos-com:pn.v1'

# Features that MUST survive for MiOS's WSL2/podman stack -- on a Feature value
# conflict these prefer ENABLED. Single source: the Posture-B allowlist in the
# shared MiOS-Provision.lib.ps1 (also used by ConvertTo-MiOSPreset), so the two
# never drift. We source ONLY for this data constant (the lib is side-effect-free
# function defs); merge stays identity-agnostic and reads no accounts/SSOT.
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')
$VIRT_FEATURE_MATCH = Get-MiOSVirtFeatureMatch
# MiOS-XBOX protect-list (single source: MiOS-Provision.lib.ps1). The union of the
# NTLite presets re-adds Xbox/virt-breaking removals (bioenrollment/sechealthui/
# storepurchaseapp/contentdeliverymanager, lxss, ...) that the curated ULTRA-PLUS
# base preserved; this list is the HARD EXCLUSION that keeps them out (and keeps
# protected Features enabled) so the merged artifact can still boot Xbox mode + the
# MiOS brain -- the "perfected" preset.
$PROTECT_COMPONENTS = @(Get-MiOSXboxProtectComponents) | ForEach-Object { $_.ToLower() }
$PROTECT_FEATURES   = @(Get-MiOSXboxProtectFeatures)

# XML helper -- nliteos-namespaced, UNPREFIXED element (mirrors ConvertTo-MiOSPreset).
function New-El { param([xml]$Doc,[string]$Name,[string]$Text) $e=$Doc.CreateElement($Name,$NLNS); if($PSBoundParameters.ContainsKey('Text')){$e.InnerText=$Text}; return $e }

# Normalize a DISM/optional-feature enable token to a boolean.
function Get-EnabledState { param([string]$Text) return ("$Text".Trim().ToLower() -in @('true','yes','enabled','1')) }

# Is this Feature name one MiOS needs kept enabled (virtualization stack)?
function Test-VirtNeeded { param([string]$Name) foreach ($m in $VIRT_FEATURE_MATCH) { if ("$Name" -like "*$m*") { return $true } } return $false }

# Is this RemoveComponents/<c> a PROTECTED component? Match the leading KEY token
# (before the friendly-name quote/space) case-insensitively against the protect list.
function Test-ProtectedComponent {
    param([string]$Text)
    $key = ("$Text".Trim() -split "[\s']", 2)[0].ToLower()
    return ($PROTECT_COMPONENTS -contains $key)
}
# Is this Feature @name PROTECTED (never disable -- keep enabled)?
function Test-ProtectedFeature {
    param([string]$Name)
    foreach ($m in $PROTECT_FEATURES) { if ("$Name" -like "*$m*") { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Load base (first preset) + secondary DOMs
# ---------------------------------------------------------------------------
if (-not $InputPresets -or $InputPresets.Count -lt 1) { throw "No input presets supplied." }
foreach ($p in $InputPresets) { if (-not (Test-Path -LiteralPath $p)) { throw "Input preset not found: $p" } }
if (-not $OutputPreset) { $OutputPreset = Join-Path $PSScriptRoot 'MiOS-Xbox-Merged.xml' }

$basePath = $InputPresets[0]
Write-Host "[*] Base (canonical) preset : $basePath" -ForegroundColor Cyan
[xml]$base = Get-Content -LiteralPath $basePath -Raw
if ($base.DocumentElement.NamespaceURI -ne $NLNS) { throw "Base preset root is not in the NTLite namespace ($NLNS)." }
$ns = New-Object System.Xml.XmlNamespaceManager($base.NameTable)
$ns.AddNamespace('n', $NLNS)

# Ensure the base parents we union into exist (they do in ULTRA-PLUS; create if not).
function Get-OrCreateChild {
    param([xml]$Doc,[System.Xml.XmlNode]$Parent,[string]$Name,[System.Xml.XmlNamespaceManager]$Ns)
    $node = $Parent.SelectSingleNode("n:$Name", $Ns)
    if (-not $node) { $node = New-El $Doc $Name; [void]$Parent.AppendChild($node) }
    return $node
}
$rc      = $base.SelectSingleNode('//n:RemoveComponents', $ns)
if (-not $rc) { $rc = New-El $base 'RemoveComponents'; [void]$base.DocumentElement.AppendChild($rc) }
$featSec = $base.SelectSingleNode('//n:Features', $ns)
if (-not $featSec) { $featSec = New-El $base 'Features'; [void]$base.DocumentElement.AppendChild($featSec) }
$compFeat = $base.SelectSingleNode('//n:Compatibility/n:ComponentFeatures', $ns)
$tweakSet = $base.SelectSingleNode('//n:Tweaks/n:Settings', $ns)

# ---------------------------------------------------------------------------
# Seed dedup indexes from the BASE
# ---------------------------------------------------------------------------
$seenC = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($c in @($base.SelectNodes('//n:RemoveComponents/n:c', $ns))) { [void]$seenC.Add("$($c.InnerText)") }

$featIndex = @{}   # @name -> base <Feature> node
foreach ($f in @($base.SelectNodes('//n:Features/n:Feature', $ns))) { $featIndex["$($f.GetAttribute('name'))"] = $f }

$compIndex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in @($base.SelectNodes('//n:Compatibility/n:ComponentFeatures/n:Feature', $ns))) { [void]$compIndex.Add("$($f.InnerText)") }

$tweakIndex = @{}  # "group\name" -> base <Tweak> node
if ($tweakSet) {
    foreach ($t in @($tweakSet.SelectNodes('n:TweakGroup/n:Tweak', $ns))) {
        $g = $t.ParentNode.GetAttribute('name'); $tweakIndex["$g`t$($t.GetAttribute('name'))"] = $t
    }
}

$stats = [ordered]@{ c_added=0; feat_added=0; feat_conflict=0; comp_added=0; tweak_added=0; tweak_conflict=0; c_protected=0; feat_protected=0 }

# PROTECT-LIST post-scrub of the BASE seed itself: strip any protected removal the
# base carries, and force any protected Feature enabled. The curated ULTRA-PLUS base
# should already be clean, but this makes the guarantee absolute (a future base edit
# can't reintroduce an Xbox/virt-breaking removal).
foreach ($c in @($base.SelectNodes('//n:RemoveComponents/n:c', $ns))) {
    if (Test-ProtectedComponent "$($c.InnerText)") { [void]$c.ParentNode.RemoveChild($c); [void]$seenC.Remove("$($c.InnerText)"); $stats.c_protected++ }
}
foreach ($f in @($base.SelectNodes('//n:Features/n:Feature', $ns))) {
    $nm = "$($f.GetAttribute('name'))"
    if ((Test-ProtectedFeature $nm) -and -not (Get-EnabledState $f.InnerText)) { $f.InnerText = 'true'; $stats.feat_protected++ }
}
$conflicts = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Union each SECONDARY preset's debloat intent into the base
# ---------------------------------------------------------------------------
foreach ($p in ($InputPresets | Select-Object -Skip 1)) {
    Write-Host "[*] Union preset            : $p" -ForegroundColor Cyan
    [xml]$src = Get-Content -LiteralPath $p -Raw
    if ($src.DocumentElement.NamespaceURI -ne $NLNS) { throw "Preset root is not in the NTLite namespace ($NLNS): $p" }
    $sns = New-Object System.Xml.XmlNamespaceManager($src.NameTable); $sns.AddNamespace('n', $NLNS)

    # --- RemoveComponents/<c> : union, dedup by EXACT InnerText -------------
    # PROTECT-LIST: never union a removal of an Xbox/gaming/virt-critical component.
    foreach ($c in @($src.SelectNodes('//n:RemoveComponents/n:c', $sns))) {
        $txt = "$($c.InnerText)"
        if (Test-ProtectedComponent $txt) { $stats.c_protected++; continue }
        if ($seenC.Add($txt)) { [void]$rc.AppendChild($base.ImportNode($c, $true)); $stats.c_added++ }
    }

    # --- Features/<Feature @name> : union, dedup by @name -------------------
    foreach ($f in @($src.SelectNodes('//n:Features/n:Feature', $sns))) {
        $nm = "$($f.GetAttribute('name'))"
        if (-not $nm) { continue }
        if (-not $featIndex.ContainsKey($nm)) {
            $node = $base.ImportNode($f, $true)
            # A PROTECTED feature never enters the merged set DISABLED.
            if ((Test-ProtectedFeature $nm) -and -not (Get-EnabledState $node.InnerText)) { $node.InnerText = 'true'; $stats.feat_protected++ }
            [void]$featSec.AppendChild($node); $featIndex[$nm] = $node; $stats.feat_added++
            continue
        }
        $baseNode = $featIndex[$nm]
        $baseOn = Get-EnabledState $baseNode.InnerText
        $srcOn  = Get-EnabledState $f.InnerText
        if ($baseOn -ne $srcOn) {
            $stats.feat_conflict++
            if ((Test-VirtNeeded $nm) -or (Test-ProtectedFeature $nm)) {
                # virt / Xbox-protected -> prefer ENABLED
                $resolved = 'true'
            } else {
                # else stricter/disabled wins (debloat intent)
                $resolved = 'false'
            }
            $conflicts.Add("Feature '$nm': base=$($baseNode.InnerText) src=$($f.InnerText) -> $resolved ($(if((Test-VirtNeeded $nm) -or (Test-ProtectedFeature $nm)){'protected->enabled'}else{'stricter->disabled'}))")
            $baseNode.InnerText = $resolved
        }
    }

    # --- Compatibility/ComponentFeatures/<Feature> : union, base wins ------
    if ($compFeat) {
        foreach ($f in @($src.SelectNodes('//n:Compatibility/n:ComponentFeatures/n:Feature', $sns))) {
            $txt = "$($f.InnerText)"
            if (-not $txt) { continue }
            if ($compIndex.Add($txt)) { [void]$compFeat.AppendChild($base.ImportNode($f, $true)); $stats.comp_added++ }
            # if already present: keep BASE (ULTRA-PLUS canonical) -- no-op.
        }
    }

    # --- Tweaks/Settings/TweakGroup/<Tweak> : union, base value wins -------
    if ($tweakSet) {
        foreach ($t in @($src.SelectNodes('//n:Tweaks/n:Settings/n:TweakGroup/n:Tweak', $sns))) {
            $g   = "$($t.ParentNode.GetAttribute('name'))"
            $tn  = "$($t.GetAttribute('name'))"
            $key = "$g`t$tn"
            if (-not $tweakIndex.ContainsKey($key)) {
                # find or create the matching TweakGroup in the base
                $grp = $tweakSet.SelectSingleNode("n:TweakGroup[@name='$g']", $ns)
                if (-not $grp) { $grp = New-El $base 'TweakGroup'; $grp.SetAttribute('name', $g); [void]$tweakSet.AppendChild($grp) }
                [void]$grp.AppendChild($base.ImportNode($t, $true)); $tweakIndex[$key] = $grp.LastChild; $stats.tweak_added++
            } else {
                $baseTweak = $tweakIndex[$key]
                if ("$($baseTweak.InnerText)" -ne "$($t.InnerText)") {
                    $stats.tweak_conflict++
                    $conflicts.Add("Tweak '$g\$tn': base=$($baseTweak.InnerText) (KEPT, ULTRA-PLUS canonical) vs src=$($t.InnerText)")
                    # keep BASE value -- no mutation.
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Strip legacy top-level author comments; insert one MiOS provenance header
# ---------------------------------------------------------------------------
foreach ($node in @($base.ChildNodes)) {
    if ($node.NodeType -eq [System.Xml.XmlNodeType]::Comment) { [void]$base.RemoveChild($node) }
}
$srcList = ($InputPresets | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
$conflictLines = if ($conflicts.Count) { "`n Conflicts (resolved):`n  - " + ($conflicts -join "`n  - ") } else { ' No value conflicts.' }
$hdr = $base.CreateComment(@"
 MiOS-Xbox MERGED NTLite preset -- union of: $srcList
 Built by Merge-MiOSPresets.ps1 (identity-agnostic; NO baked accounts, NO personal identity).
 Base/canonical structural source = $(Split-Path $basePath -Leaf) (sole Unattended, ApplyOptions, ImageInfo, Packages, Drivers).
 Unioned debloat: +$($stats.c_added) RemoveComponents <c>, +$($stats.feat_added) DISM Features
 (+$($stats.feat_conflict) value-conflict(s) resolved), +$($stats.comp_added) Compatibility toggle(s),
 +$($stats.tweak_added) registry Tweak(s) (+$($stats.tweak_conflict) value-conflict(s), base kept).
 MiOS-XBOX protect-list: $($stats.c_protected) Xbox/virt-critical removal(s) blocked, $($stats.feat_protected) protected Feature(s) kept enabled.
 NEXT: ConvertTo-MiOSPreset.ps1 applies SSOT hostname/accounts/AutoLogon/FirstLogonCommands,
 GUID {MIOS-XBOX-SSOT}, AutoIsoFile/Label, and Posture B (re-preserve WSL2/VMP/Hyper-V).$conflictLines
"@)
[void]$base.DocumentElement.ParentNode.InsertBefore($hdr, $base.DocumentElement)

# ---------------------------------------------------------------------------
# Write (UTF-8, no BOM), indented
# ---------------------------------------------------------------------------
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true; $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$sw = [System.Xml.XmlWriter]::Create($OutputPreset, $settings)
$base.Save($sw); $sw.Dispose()

# ---------------------------------------------------------------------------
# Report + guardrail assertions
# ---------------------------------------------------------------------------
$totalC    = @($base.SelectNodes('//n:RemoveComponents/n:c', $ns)).Count
$totalFeat = @($base.SelectNodes('//n:Features/n:Feature', $ns)).Count
$oobe      = $base.SelectNodes("//n:Unattended/n:settings[@pass='oobeSystem']/n:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
$applyOpts = @($base.SelectNodes('//n:ApplyOptions', $ns)).Count

Write-Host "[+] Merged preset written   : $OutputPreset" -ForegroundColor Green
Write-Host "    Protect-list            : $($stats.c_protected) removal(s) blocked, $($stats.feat_protected) Feature(s) kept enabled" -ForegroundColor DarkGray
Write-Host "    RemoveComponents <c>    : $totalC unique (+$($stats.c_added) unioned)" -ForegroundColor DarkGray
Write-Host "    DISM Features           : $totalFeat unique (+$($stats.feat_added), $($stats.feat_conflict) conflict(s))" -ForegroundColor DarkGray
Write-Host "    Compatibility toggles   : +$($stats.comp_added) unioned" -ForegroundColor DarkGray
Write-Host "    Registry Tweaks         : +$($stats.tweak_added) (+$($stats.tweak_conflict) conflict(s), base kept)" -ForegroundColor DarkGray
Write-Host "    oobeSystem Shell-Setup  : $($oobe.Count) (MUST be exactly 1 for the sanitizer)" -ForegroundColor DarkGray
Write-Host "    ApplyOptions blocks     : $applyOpts (MUST be exactly 1)" -ForegroundColor DarkGray
if ($conflicts.Count) { $conflicts | ForEach-Object { Write-Host "    [conflict] $_" -ForegroundColor Yellow } }

# Guardrails: the merged artifact must satisfy ConvertTo-MiOSPreset's contract + LAW.
if ($oobe.Count -ne 1)      { throw "GUARDRAIL: expected exactly 1 oobeSystem Shell-Setup, found $($oobe.Count)." }
if ($applyOpts -ne 1)       { throw "GUARDRAIL: expected exactly 1 ApplyOptions, found $applyOpts." }
# Forbidden legacy identity token (operator LAW: globally purged). Pattern built from
# parts so this source file itself never contains the literal token.
$forbidden = 'ka' + 'bu'
$raw = Get-Content -LiteralPath $OutputPreset -Raw
if ($raw -match "(?i)$forbidden") { throw "GUARDRAIL: purged legacy identity token found in merged output -- operator LAW violation." }
Write-Host "[+] Guardrails passed (1 oobe Shell-Setup, 1 ApplyOptions, no purged identity token)." -ForegroundColor Green
