# AI-hint: Sanitizes an NTLite Windows-image preset (e.g. the MiOS-Xbox gaming build) to MiOS conventions -- SSOT-driven hostname, credentialed accounts, GLOBAL branding/theme + unified Linux-like layout + prefs (from the shared MiOS-Provision.lib.ps1), the nested MiOS irm|iex bootstrap, and Posture B (preserve WSL2/VMP/Hyper-V). Shares its provisioning core with Invoke-MiOSProvision.ps1 so MiOS-XBOX.iso and irm|iex stay in feature parity.
# AI-related: mios-bootstrap, MiOS-Provision.lib.ps1, Get-MiOS.ps1, New-MiOSAutounattend.ps1, Invoke-MiOSProvision.ps1
# AI-functions: New-El
#Requires -Version 5.1
<#
.SYNOPSIS
    Convert an NTLite preset (urn:schemas-nliteos-com:pn.v1) into a MiOS-conformant
    preset: MiOS naming, SSOT hostname + accounts, GLOBAL branding/theme/layout/prefs
    (shared provisioning core), nested MiOS bootstrap, virtualization preserved.

.DESCRIPTION
    The provisioning logic (SSOT reader, hostname/account resolution, branding,
    theme, Linux-like layout, prefs) lives in MiOS-Provision.lib.ps1 and is SHARED
    with Invoke-MiOSProvision.ps1 (existing-Windows path) so both install paths
    reach identical MiOS state. This script layers the NTLite/XML-specific work:
    Posture B (re-preserve WSL2/VMP/Hyper-V), MiOS naming, SSOT accounts + AutoLogon,
    and FirstLogonCommands = the shared provisioning set + the nested irm|iex.

.PARAMETER InputPreset   NTLite preset to sanitize (e.g. Xbox-Minimal-ULTRA-PLUS.xml).
.PARAMETER OutputPreset  Output MiOS preset path. Default: MiOS-<InputBaseName>.xml.
.PARAMETER TomlPath      mios.toml SSOT (default: M:\etc\mios, M:\usr\share\mios, or <repo>\mios.toml).
.PARAMETER BootstrapUrl  Override nested-bootstrap URL.
.PARAMETER ObfuscatePasswords  Base64-obscure account passwords in the output.
.PARAMETER KeepVirtualizationDisabled  Skip Posture-B (pure-gaming, no MiOS brain).

.EXAMPLE
    .\ConvertTo-MiOSPreset.ps1 -InputPreset 'C:\MiOS\Xbox-Minimal-ULTRA-PLUS.xml' -OutputPreset '.\MiOS-Xbox.xml'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPreset,
    [string]$OutputPreset,
    [string]$TomlPath,
    [string]$BootstrapUrl,
    [switch]$ObfuscatePasswords,
    [switch]$KeepVirtualizationDisabled
)
$ErrorActionPreference = 'Stop'
$NLNS = 'urn:schemas-nliteos-com:pn.v1'
$CANONICAL_BOOTSTRAP = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1'

# Shared MiOS provisioning core (SSOT reader + branding/theme/layout/prefs/accounts
# + the Posture-B virtualization allowlist).
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

# Components/features that MUST survive for MiOS's WSL2 podman stack (Posture B).
# Single source: MiOS-Provision.lib.ps1 (shared with Merge-MiOSPresets.ps1).
$VIRT_COMPONENT_MATCH = Get-MiOSVirtComponentMatch
$VIRT_FEATURE_MATCH   = Get-MiOSVirtFeatureMatch

# XML helper -- nliteos-namespaced element (uses $NLNS; XML-specific, not shared).
function New-El { param([xml]$Doc,[string]$Name,[string]$Text) $e=$Doc.CreateElement($Name,$NLNS); if($PSBoundParameters.ContainsKey('Text')){$e.InnerText=$Text}; return $e }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InputPreset)) { throw "Input preset not found: $InputPreset" }
if (-not $OutputPreset) { $OutputPreset = Join-Path (Get-Location) ('MiOS-' + (Split-Path $InputPreset -Leaf)) }
if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml     = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }
$hostName = Get-MiOSHostname -Toml $toml
$accounts = Get-MiOSAccounts -Toml $toml
$bootUrl  = if ($BootstrapUrl) { $BootstrapUrl } else { Get-Toml $toml 'autounattend.bootstrap_url' $CANONICAL_BOOTSTRAP }
$isoOut   = Get-Toml $toml 'autounattend.iso_out'   'M:\MiOS\iso\MiOS-Xbox.iso'
$isoLabel = Get-Toml $toml 'autounattend.iso_label' 'MiOS-Xbox'

Write-Host "[*] SSOT: $(if($TomlPath){$TomlPath}else{'(defaults)'}) | hostname=$hostName | accounts=$($accounts.Count)" -ForegroundColor Cyan

[xml]$xml = Get-Content -LiteralPath $InputPreset -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace('n', $NLNS)

# 1) POSTURE B -- re-preserve virtualization ---------------------------------
$virtRemoved = 0; $virtFeat = 0
if (-not $KeepVirtualizationDisabled) {
    foreach ($c in @($xml.SelectNodes('//n:RemoveComponents/n:c', $ns))) {
        $t = "$($c.InnerText)".ToLower()
        if ($VIRT_COMPONENT_MATCH | Where-Object { $t -match $_ }) { [void]$c.ParentNode.RemoveChild($c); $virtRemoved++ }
    }
    foreach ($f in @($xml.SelectNodes('//n:Features/n:Feature', $ns))) {
        $nm = "$($f.GetAttribute('name'))"
        if ($VIRT_FEATURE_MATCH | Where-Object { $nm -like "*$_*" }) { [void]$f.ParentNode.RemoveChild($f); $virtFeat++ }  # remove disable => stays enabled
    }
    foreach ($f in @($xml.SelectNodes("//n:Compatibility/n:ComponentFeatures/n:Feature", $ns))) {
        if ("$($f.InnerText)" -eq 'Hyper-V') { $f.SetAttribute('enabled','yes') }
    }
}

# 2) Rename / MiOS conventions ----------------------------------------------
$gi = $xml.SelectSingleNode('//n:ImageInfo/n:GUID', $ns); if ($gi) { $gi.InnerText = '{MIOS-XBOX-SSOT}' }
$auto = $xml.SelectSingleNode('//n:ApplyOptions/n:AutoIsoFile', $ns);  if ($auto) { $auto.InnerText = $isoOut }
$albl = $xml.SelectSingleNode('//n:ApplyOptions/n:AutoIsoLabel', $ns); if ($albl) { $albl.InnerText = $isoLabel }

# 3) ComputerName (specialize) ----------------------------------------------
$cn = $xml.SelectSingleNode("//n:Unattended//n:component[@name='Microsoft-Windows-Shell-Setup']/n:ComputerName", $ns)
if ($cn) { $cn.InnerText = $hostName } else {
    $spec = $xml.SelectSingleNode("//n:Unattended/n:settings[@pass='specialize']/n:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
    if ($spec) { [void]$spec.AppendChild((New-El $xml 'ComputerName' $hostName)) }
}

# 4) oobeSystem Shell-Setup: SSOT accounts + AutoLogon + FirstLogonCommands ---
$oobe = $xml.SelectSingleNode("//n:Unattended/n:settings[@pass='oobeSystem']/n:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
if (-not $oobe) { throw "Preset has no oobeSystem Shell-Setup component; cannot inject MiOS accounts." }

# Rebuild LocalAccounts from SSOT.
$ua = $oobe.SelectSingleNode('n:UserAccounts', $ns)
if ($ua) { [void]$oobe.RemoveChild($ua) }
$ua = New-El $xml 'UserAccounts'
$la = New-El $xml 'LocalAccounts'
foreach ($a in $accounts) {
    $pw = ConvertTo-PwPair -Pw ([string]$a.password) -Obfuscate:$ObfuscatePasswords
    $lacc = New-El $xml 'LocalAccount'
    [void]$lacc.AppendChild((New-El $xml 'Name' ([string]$a.name)))
    [void]$lacc.AppendChild((New-El $xml 'DisplayName' ([string]$a.display_name)))
    $grp = if ($a.group -match '^(?i)admin') { 'Administrators' } else { 'Users' }
    [void]$lacc.AppendChild((New-El $xml 'Group' $grp))
    $pwn = New-El $xml 'Password'
    [void]$pwn.AppendChild((New-El $xml 'Value' $pw.v))
    [void]$pwn.AppendChild((New-El $xml 'PlainText' $pw.p))
    [void]$lacc.AppendChild($pwn)
    [void]$la.AppendChild($lacc)
}
[void]$ua.AppendChild($la)
[void]$oobe.AppendChild($ua)

# AutoLogon (first admin so FirstLogon runs unattended).
$first = $accounts[0]; $fp = ConvertTo-PwPair -Pw ([string]$first.password) -Obfuscate:$ObfuscatePasswords
$existingAl = $oobe.SelectSingleNode('n:AutoLogon', $ns); if ($existingAl) { [void]$oobe.RemoveChild($existingAl) }
$al = New-El $xml 'AutoLogon'
[void]$al.AppendChild((New-El $xml 'Enabled' 'true'))
[void]$al.AppendChild((New-El $xml 'Username' ([string]$first.name)))
[void]$al.AppendChild((New-El $xml 'LogonCount' '1'))
$alp = New-El $xml 'Password'
[void]$alp.AppendChild((New-El $xml 'Value' $fp.v))
[void]$alp.AppendChild((New-El $xml 'PlainText' $fp.p))
[void]$al.AppendChild($alp)
[void]$oobe.AppendChild($al)

# FirstLogonCommands: SHARED MiOS provisioning set, then the nested MiOS bootstrap.
$existingFlc = $oobe.SelectSingleNode('n:FirstLogonCommands', $ns); if ($existingFlc) { [void]$oobe.RemoveChild($existingFlc) }
$flc = New-El $xml 'FirstLogonCommands'
$order = 1
foreach ($grp in (New-MiOSProvisionCommands -Toml $toml)) {
    foreach ($pc in $grp.Commands) {
        $sc = New-El $xml 'SynchronousCommand'
        [void]$sc.AppendChild((New-El $xml 'Order' ([string]$order)))
        [void]$sc.AppendChild((New-El $xml 'CommandLine' ("cmd /c $pc")))
        [void]$sc.AppendChild((New-El $xml 'Description' $grp.Description))
        [void]$flc.AppendChild($sc); $order++
    }
}
$sc = New-El $xml 'SynchronousCommand'
[void]$sc.AppendChild((New-El $xml 'Order' ([string]$order)))
[void]$sc.AppendChild((New-El $xml 'CommandLine' ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm ' + $bootUrl + ' | iex"')))
[void]$sc.AppendChild((New-El $xml 'Description' 'MiOS bootstrap (nested irm|iex)'))
[void]$sc.AppendChild((New-El $xml 'RequiresUserInput' 'true'))
[void]$flc.AppendChild($sc)
[void]$oobe.AppendChild($flc)

# 5) MiOS header comment (strip legacy author/naming comments first) --------
foreach ($node in @($xml.ChildNodes)) {
    if ($node.NodeType -eq [System.Xml.XmlNodeType]::Comment) { [void]$xml.RemoveChild($node) }
}
$hdr = $xml.CreateComment(@"
 MiOS preset (sanitized from $(Split-Path $InputPreset -Leaf) by ConvertTo-MiOSPreset.ps1).
 SSOT hostname=$hostName; $($accounts.Count) SSOT local account(s) with credentials;
 GLOBAL MiOS branding/theme + unified Linux-like layout + prefs (shared MiOS-Provision.lib.ps1,
 Default hive + first HKCU); nested MiOS irm|iex bootstrap -- same core the irm|iex installer runs.
 Posture B: WSL2 / VirtualMachinePlatform / Hyper-V PRESERVED for the MiOS podman stack
 (removed $virtRemoved virt component-removal(s) + $virtFeat virt feature-disable(s)).
"@)
[void]$xml.DocumentElement.ParentNode.InsertBefore($hdr, $xml.DocumentElement)

# Write (UTF-8, no BOM), indented.
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true; $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$sw = [System.Xml.XmlWriter]::Create($OutputPreset, $settings)
$xml.Save($sw); $sw.Dispose()

Write-Host "[+] MiOS preset written: $OutputPreset" -ForegroundColor Green
Write-Host "    hostname=$hostName  accounts=$($accounts.Count)  virt-preserved=$([bool](-not $KeepVirtualizationDisabled))  iso=$isoOut ($isoLabel)" -ForegroundColor DarkGray
