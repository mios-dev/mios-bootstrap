# AI-hint: Sanitizes an NTLite Windows-image preset (e.g. the MiOS-Xbox gaming build) to MiOS conventions -- SSOT-driven hostname generation, credentialed local accounts, GLOBAL user preferences (Default hive), the nested MiOS irm|iex bootstrap, and (Posture B) preservation of the WSL2/VirtualMachinePlatform/Hyper-V substrate the MiOS agent stack requires.
# AI-related: mios-bootstrap, Get-MiOS.ps1, src/autounattend/New-MiOSAutounattend.ps1, src/autounattend/autounattend.xml
# AI-functions: Read-MiosToml, Get-MiOSHostname, Get-MiOSAccounts, New-MiOSGlobalPrefCommands
#Requires -Version 5.1
<#
.SYNOPSIS
    Convert an NTLite preset (urn:schemas-nliteos-com:pn.v1) into a MiOS-conformant
    preset: MiOS naming, SSOT hostname + accounts + global prefs, nested MiOS
    bootstrap, and virtualization preserved so MiOS's WSL2 podman stack can run.

.DESCRIPTION
    The MiOS-Xbox presets debloat Windows hard but also STRIP WSL / VirtualMachine
    Platform / Hyper-V / Containers -- the exact substrate the MiOS Linux agent
    stack (WSL2 podman machine) needs. This sanitizer applies "Posture B":
    keep the gaming debloat, but re-preserve virtualization, then layer MiOS
    conventions from mios.toml SSOT:

      * Hostname   : SSOT [autounattend].computer_name, with generation
                     ("random" / "MiOS-#" -> MIOS-XXXXXXXX, "*" -> Windows random,
                     or a literal name). NetBIOS-safe (<=15 chars).
      * Accounts   : SSOT [[autounattend.accounts]] local ("offline") accounts,
                     each with credentials + group; never a blank admin.
                     First admin gets AutoLogon (LogonCount 1) so FirstLogon runs.
      * Nested boot: FirstLogonCommands runs  irm .../Get-MiOS.ps1 | iex .
      * GLOBAL prefs: MiOS user preferences (dark mode, accent, show file
                     extensions, taskbar) written to the Default User hive AND
                     the first user's HKCU so EVERY account (present + future)
                     inherits them.
      * Naming     : header, ImageInfo GUID, ISO output path + label -> MiOS-*.

.PARAMETER InputPreset   NTLite preset to sanitize (e.g. Xbox-Minimal-ULTRA-PLUS.xml).
.PARAMETER OutputPreset  Output MiOS preset path. Default: MiOS-<InputBaseName>.xml.
.PARAMETER TomlPath      mios.toml SSOT (default: M:\etc\mios, M:\usr\share\mios, or <repo>\mios.toml).
.PARAMETER BootstrapUrl  Override nested-bootstrap URL.
.PARAMETER ObfuscatePasswords  Base64-obscure account passwords in the output.
.PARAMETER KeepVirtualizationDisabled  Skip Posture-B (leave WSL/Hyper-V stripped -- pure-gaming, no MiOS brain).

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

# Components/features that MUST survive for MiOS's WSL2 podman stack (Posture B).
$VIRT_COMPONENT_MATCH = @('lxss', 'windowssubsystemforlinux')
$VIRT_FEATURE_MATCH   = @(
    'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V',
    'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM',
    'Windows.HyperV.OptionalFeature'
)

# ---------------------------------------------------------------------------
function Read-MiosToml {
    param([string]$Path)
    $r = @{ scalars = @{}; accounts = @(); prefs = @{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    $section = ''; $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -eq '[[autounattend.accounts]]') {
            if ($cur) { $r.accounts += ,$cur }
            $cur = @{}; $section = 'account'; continue
        }
        if ($line -match '^\[(?<s>[^\]]+)\]$') {
            if ($cur) { $r.accounts += ,$cur; $cur = $null }
            $section = $Matches['s']; continue
        }
        if ($line -match '^(?<k>[A-Za-z0-9_\-\.]+)\s*=\s*(?<v>.+)$') {
            $k = $Matches['k'].Trim(); $v = $Matches['v'].Trim().Trim('"', "'")
            if ($section -eq 'account' -and $cur -ne $null) { $cur[$k] = $v }
            elseif ($section -eq 'autounattend.preferences') { $r.prefs[$k] = $v }
            else { $r.scalars["$section.$k"] = $v }
        }
    }
    if ($cur) { $r.accounts += ,$cur }
    return $r
}
function Get-Toml { param($T,[string]$Key,[string]$Def='') if ($T.scalars.ContainsKey($Key) -and $T.scalars[$Key]) { $T.scalars[$Key] } else { $Def } }

function Get-MiOSHostname {
    # SSOT-driven hostname generation. NetBIOS-safe, <=15 chars.
    param($Toml)
    $raw = Get-Toml $Toml 'autounattend.computer_name' (Get-Toml $Toml 'identity.hostname' 'MIOS')
    if ($raw -eq '*') { return '*' }                                  # Windows random
    if ($raw -match 'random' -or $raw -match '#') {
        $suffix = -join ((48..57) + (65..70) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
        return ("MIOS-$suffix").Substring(0, [Math]::Min(15, "MIOS-$suffix".Length))
    }
    return $raw.Substring(0, [Math]::Min(15, $raw.Length))
}

function Get-MiOSAccounts {
    param($Toml)
    $accts = @($Toml.accounts)
    if ($accts.Count -eq 0) {
        $u = Get-Toml $Toml 'identity.username' 'mios'
        $accts = @(@{ name=$u; display_name=(Get-Toml $Toml 'identity.fullname' 'MiOS User'); group='Administrators'; password=$u })
    }
    foreach ($a in $accts) {
        if (-not $a.name)         { $a.name = 'mios' }
        if (-not $a.password)     { $a.password = $a.name }   # never a blank admin
        if (-not $a.group)        { $a.group = 'Users' }
        if (-not $a.display_name) { $a.display_name = $a.name }
    }
    return ,$accts
}
function ConvertTo-PwPair { param([string]$Pw)
    if ($ObfuscatePasswords) { @{ v=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Pw+'Password')); p='false' } }
    else { @{ v=$Pw; p='true' } }
}

function New-MiOSGlobalPrefCommands {
    # MiOS FUNCTIONAL preferences applied GLOBALLY: to the Default User hive
    # (every future account) AND the first user's HKCU. Visual identity (theme,
    # accent, wallpaper, lockscreen, OEM) lives in New-MiOSBrandingCommands.
    # Values resolve from SSOT [autounattend.preferences] with MiOS defaults.
    param($Toml)
    $d = [ordered]@{
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt|REG_DWORD'           = (Get-Toml $Toml 'autounattend.preferences.hide_file_ext' '0')
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Hidden|REG_DWORD'                = (Get-Toml $Toml 'autounattend.preferences.show_hidden' '1')
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAl|REG_DWORD'             = (Get-Toml $Toml 'autounattend.preferences.taskbar_align' '0')  # 0=left
        'Software\Microsoft\Windows\CurrentVersion\Search|SearchboxTaskbarMode|REG_DWORD'             = (Get-Toml $Toml 'autounattend.preferences.taskbar_search' '0') # 0=hidden
    }
    $cmds = New-Object System.Collections.Generic.List[string]
    # Apply to the current (first auto-logon) user's HKCU.
    foreach ($k in $d.Keys) {
        $parts = $k -split '\|'; $cmds.Add(('reg add "HKCU\{0}" /v {1} /t {2} /d {3} /f' -f $parts[0], $parts[1], $parts[2], $d[$k]))
    }
    # Apply to the Default User hive so EVERY future account inherits them.
    $cmds.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"')
    foreach ($k in $d.Keys) {
        $parts = $k -split '\|'; $cmds.Add(('reg add "HKU\MiOSDefault\{0}" /v {1} /t {2} /d {3} /f' -f $parts[0], $parts[1], $parts[2], $d[$k]))
    }
    $cmds.Add('reg unload "HKU\MiOSDefault"')
    return $cmds
}

function ConvertTo-AccentDword {
    # #RRGGBB -> 0xFFBBGGRR (DWM/Explorer accent DWORD, AABBGGRR little-endian).
    param([string]$Hex)
    $h = "$Hex".TrimStart('#')
    if ($h.Length -ne 6 -or $h -notmatch '^[0-9A-Fa-f]{6}$') { return '0xFF7F401A' }  # MiOS #1A407F
    return ('0xFF{0}{1}{2}' -f $h.Substring(4,2), $h.Substring(2,2), $h.Substring(0,2)).ToUpper()
}

function New-MiOSBrandingCommands {
    # FULL MiOS visual identity applied GLOBALLY to the Windows edition, ALL from
    # SSOT ([branding], [colors].accent, [theme]) with MiOS defaults, editable in
    # the mios.html configurator. Writes machine-wide (HKLM: OEM info, lockscreen,
    # brand icon) + the Default User hive AND first HKCU (theme, accent, wallpaper)
    # so EVERY account -- present and future -- carries the MiOS look.
    param($Toml)
    if ((Get-Toml $Toml 'branding.windows.enable' 'true') -notmatch '^(true|1|yes)$') { return @() }
    $c = New-Object System.Collections.Generic.List[string]

    # --- OEM information (machine-wide, System > About) --------------------
    $oem = [ordered]@{
        Manufacturer = Get-Toml $Toml 'branding.oem_manufacturer' 'MiOS'
        Model        = Get-Toml $Toml 'branding.oem_model'        (Get-Toml $Toml 'branding.tagline' 'My Personal Operating System')
        SupportURL   = Get-Toml $Toml 'branding.oem_support_url'  'https://github.com/mios-dev'
        SupportHours = Get-Toml $Toml 'branding.oem_support_hours' 'Always on'
        SupportPhone = Get-Toml $Toml 'branding.oem_support_phone' ''
        Logo         = Get-Toml $Toml 'branding.oem_logo'         'C:\Windows\Web\MiOS\mios-logo.bmp'
    }
    foreach ($k in $oem.Keys) {
        if ("$($oem[$k])" -ne '') { $c.Add(('reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v {0} /t REG_SZ /d "{1}" /f' -f $k, $oem[$k])) }
    }

    # --- System UI font: substitute Segoe UI -> Geist (machine-wide) -------
    # The actual Geist / GeistMono Nerd Font files are installed by the MiOS
    # bootstrap (Install-MiOSGeistFont); this makes Geist the global UI face.
    if ((Get-Toml $Toml 'branding.font_substitute' 'true') -match '^(true|1|yes)$') {
        $uiFont = Get-Toml $Toml 'branding.ui_font' 'Geist'
        foreach ($face in @('Segoe UI','Segoe UI Semibold','Segoe UI Light','Segoe UI Semilight')) {
            $c.Add(('reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes" /v "{0}" /t REG_SZ /d "{1}" /f' -f $face, $uiFont))
        }
    }

    # --- Lockscreen (machine-wide, PersonalizationCSP) --------------------
    $wallpaper  = Get-Toml $Toml 'branding.wallpaper'  'C:\Windows\Web\MiOS\mios-wallpaper.jpg'
    $lockscreen = Get-Toml $Toml 'branding.lockscreen' $wallpaper
    if ("$lockscreen" -ne '') {
        $csp = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
        $c.Add(('reg add "{0}" /v LockScreenImageStatus /t REG_DWORD /d 1 /f' -f $csp))
        $c.Add(('reg add "{0}" /v LockScreenImagePath /t REG_SZ /d "{1}" /f' -f $csp, $lockscreen))
        $c.Add(('reg add "{0}" /v LockScreenImageUrl /t REG_SZ /d "{1}" /f' -f $csp, $lockscreen))
    }

    # --- Theme + accent + wallpaper (Default hive + first HKCU) -----------
    $accentDword = ConvertTo-AccentDword (Get-Toml $Toml 'colors.accent' '#1A407F')
    $darkApps    = if ((Get-Toml $Toml 'theme.mode' 'dark') -match '^(?i)light$') { '1' } else { '0' }
    $wallStyle   = Get-Toml $Toml 'branding.wallpaper_style' '10'   # 10 = Fill
    $perHive = {
        param($hivePrefix)
        $per = [ordered]@{
            'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|AppsUseLightTheme|REG_DWORD'    = $darkApps
            'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|SystemUsesLightTheme|REG_DWORD' = $darkApps
            'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|ColorPrevalence|REG_DWORD'      = '1'
            'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|EnableTransparency|REG_DWORD'   = '1'
            'Software\Microsoft\Windows\DWM|AccentColor|REG_DWORD'                                        = $accentDword
            'Software\Microsoft\Windows\DWM|ColorizationColor|REG_DWORD'                                  = $accentDword
            'Software\Microsoft\Windows\DWM|ColorPrevalence|REG_DWORD'                                    = '1'
            'Software\Microsoft\Windows\CurrentVersion\Explorer\Accent|AccentColorMenu|REG_DWORD'         = $accentDword
            'Software\Microsoft\Windows\CurrentVersion\Explorer\Accent|StartColorMenu|REG_DWORD'          = $accentDword
            'Control Panel\Desktop|WallPaper|REG_SZ'                                                       = $wallpaper
            'Control Panel\Desktop|WallpaperStyle|REG_SZ'                                                  = $wallStyle
            # Dynamic Lighting -- drive RGB peripherals from the MiOS accent.
            'Software\Microsoft\Lighting|UseSystemAccentColor|REG_DWORD'                                   = '1'
            'Software\Microsoft\Lighting|AmbientLightingEnabled|REG_DWORD'                                 = '1'
        }
        $lines = @()
        foreach ($k in $per.Keys) {
            $p = $k -split '\|'
            $lines += ('reg add "{0}\{1}" /v {2} /t {3} /d {4} /f' -f $hivePrefix, $p[0], $p[1], $p[2], $(if ($p[2] -eq 'REG_SZ') { '"' + $per[$k] + '"' } else { $per[$k] }))
        }
        return $lines
    }
    # --- Bibata cursor scheme (per hive). The .cur/.ani files are staged to
    # cursor_dir by the MiOS bootstrap (Install-MiOSBibataCursor) / the ISO;
    # the registry makes Bibata the global default for every account. ------
    $curEnable = (Get-Toml $Toml 'branding.cursor' 'true') -match '^(true|1|yes)$'
    $curDir    = Get-Toml $Toml 'branding.cursor_dir'    '%SystemRoot%\Cursors\Bibata-Modern-Classic'
    $curName   = Get-Toml $Toml 'branding.cursor_scheme' 'Bibata-Modern-Classic'
    $curMap = [ordered]@{ AppStarting='Working.ani'; Arrow='Default.cur'; Crosshair='Cross.cur'; Hand='Link.cur'; Help='Help.cur'; IBeam='IBeam.cur'; No='Unavailiable.cur'; NWPen='Handwriting.cur'; Person='Person.cur'; Pin='Pin.cur'; SizeAll='Move.cur'; SizeNESW='Diagonal_2.cur'; SizeNS='Vertical.cur'; SizeNWSE='Diagonal_1.cur'; SizeWE='Horizontal.cur'; UpArrow='Alternate.cur'; Wait='Busy.ani' }
    $cursorCmds = {
        param($hp)
        $ll = @()
        if (-not $curEnable) { return $ll }
        $ll += ('reg add "{0}\Control Panel\Cursors" /ve /t REG_SZ /d "{1}" /f' -f $hp, $curName)
        $ll += ('reg add "{0}\Control Panel\Cursors" /v "Scheme Source" /t REG_DWORD /d 2 /f' -f $hp)
        foreach ($cn in $curMap.Keys) { $ll += ('reg add "{0}\Control Panel\Cursors" /v {1} /t REG_EXPAND_SZ /d "{2}\{3}" /f' -f $hp, $cn, $curDir, $curMap[$cn]) }
        return $ll
    }
    foreach ($l in (& $perHive 'HKCU')) { $c.Add($l) }
    foreach ($l in (& $cursorCmds 'HKCU')) { $c.Add($l) }
    $c.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"')
    foreach ($l in (& $perHive 'HKU\MiOSDefault')) { $c.Add($l) }
    foreach ($l in (& $cursorCmds 'HKU\MiOSDefault')) { $c.Add($l) }
    $c.Add('reg unload "HKU\MiOSDefault"')
    return $c
}

function New-MiOSLinuxLayoutCommands {
    # Strip Windows' default per-user directory sprawl and impose a UNIFIED,
    # Linux-like, human-readable layout that MIRRORS the WSL tree so a path
    # means the same thing on both sides (Windows C:\etc <-> WSL /mnt/c/etc;
    # MiOS data M:\etc\mios <-> /mnt/m/etc/mios). Applied GLOBALLY (Default hive
    # + first HKCU) so every account gets the same organization.
    param($Toml)
    if ((Get-Toml $Toml 'autounattend.layout.enable' 'true') -notmatch '^(true|1|yes)$') { return @() }
    $sys = '%SystemDrive%'
    # 1) Linux-like top-level tree on the system drive (mirrors the WSL rootfs
    #    names; SSOT-tunable). MiOS's M:\ data drive already uses etc/usr/var.
    $tree = (Get-Toml $Toml 'autounattend.layout.linux_tree' 'etc usr var home opt srv tmp bin lib root').Trim()
    $c = New-Object System.Collections.Generic.List[string]
    foreach ($d in ($tree -split '\s+' | Where-Object { $_ })) { $c.Add("mkdir $sys\$d") }
    # 2) Lowercase, unified user folders (downloads/documents/desktop/pictures/
    #    music/videos) + repoint the shell-folder registry to them, GLOBALLY.
    if ((Get-Toml $Toml 'autounattend.layout.lowercase_userfolders' 'true') -match '^(true|1|yes)$') {
        $map = [ordered]@{
            '{374DE290-123F-4565-9164-39C4925E467B}' = 'downloads'   # Downloads
            'Personal'                               = 'documents'   # Documents
            'Desktop'                                = 'desktop'
            'My Pictures'                            = 'pictures'
            'My Music'                               = 'music'
            'My Video'                               = 'videos'
        }
        foreach ($lc in ($map.Values | Select-Object -Unique)) { $c.Add("mkdir %USERPROFILE%\$lc") }
        foreach ($hive in @('HKCU','HKU\MiOSDefault')) {
            $usf = "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
            $needLoad = ($hive -eq 'HKU\MiOSDefault')
            if ($needLoad) { $c.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"') }
            foreach ($k in $map.Keys) {
                $c.Add(('reg add "{0}" /v "{1}" /t REG_EXPAND_SZ /d "%USERPROFILE%\{2}" /f' -f $usf, $k, $map[$k]))
            }
            if ($needLoad) { $c.Add('reg unload "HKU\MiOSDefault"') }
        }
    }
    # 3) Strip the "This PC" known-folder clutter (machine-wide). Default: just
    #    3D Objects; SSOT can add Music/Pictures/Videos/Desktop/Documents/Downloads.
    $stripGuids = (Get-Toml $Toml 'autounattend.layout.strip_thispc' '{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}').Trim()
    foreach ($g in ($stripGuids -split '\s+' | Where-Object { $_ })) {
        $c.Add("reg delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$g`" /f")
        $c.Add("reg delete `"HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$g`" /f")
    }
    return $c
}

# --- helpers to build nliteos-namespaced nodes ------------------------------
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
    $pw = ConvertTo-PwPair ([string]$a.password)
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
$first = $accounts[0]; $fp = ConvertTo-PwPair ([string]$first.password)
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

# FirstLogonCommands: GLOBAL prefs first, then the nested MiOS bootstrap.
$existingFlc = $oobe.SelectSingleNode('n:FirstLogonCommands', $ns); if ($existingFlc) { [void]$oobe.RemoveChild($existingFlc) }
$flc = New-El $xml 'FirstLogonCommands'
$order = 1
$layoutCmds = @(New-MiOSLinuxLayoutCommands -Toml $toml)
$brandCmds  = @(New-MiOSBrandingCommands -Toml $toml)
$prefCmds   = @(New-MiOSGlobalPrefCommands -Toml $toml)
foreach ($grp in @(
        @{ d='MiOS unified Linux-like directory layout'; c=$layoutCmds },
        @{ d='MiOS global branding + theme (OEM/accent/wallpaper/lockscreen)'; c=$brandCmds },
        @{ d='MiOS global user preferences'; c=$prefCmds })) {
    foreach ($pc in $grp.c) {
        $sc = New-El $xml 'SynchronousCommand'
        [void]$sc.AppendChild((New-El $xml 'Order' ([string]$order)))
        [void]$sc.AppendChild((New-El $xml 'CommandLine' ("cmd /c $pc")))
        [void]$sc.AppendChild((New-El $xml 'Description' $grp.d))
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

# 5) MiOS header comment -----------------------------------------------------
# Strip any legacy top-level comment(s) (original author/naming, e.g. "Kabu",
# "XBOX-MINIMAL-ULTRA-PLUS") before stamping the MiOS header.
foreach ($node in @($xml.ChildNodes)) {
    if ($node.NodeType -eq [System.Xml.XmlNodeType]::Comment) { [void]$xml.RemoveChild($node) }
}
$hdr = $xml.CreateComment(@"
 MiOS preset (sanitized from $(Split-Path $InputPreset -Leaf) by ConvertTo-MiOSPreset.ps1).
 Conventions: SSOT hostname=$hostName; $($accounts.Count) SSOT local account(s) with credentials;
 GLOBAL MiOS user preferences + unified Linux-like directory layout (Default hive + first HKCU,
 mirrors the WSL tree); nested MiOS irm|iex bootstrap.
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
