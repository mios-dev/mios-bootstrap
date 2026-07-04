# AI-hint: Shared MiOS install-time provisioning library (SSOT reader + hostname/account/branding/theme/layout/preferences emitters) dot-sourced by BOTH the MiOS-XBOX.iso path (ConvertTo-MiOSPreset.ps1 -> autounattend reg) AND the irm|iex / existing-Windows path (Invoke-MiOSProvision.ps1 -> live apply). One source => the two install paths stay in feature parity.
# AI-related: mios-bootstrap, Get-MiOS.ps1, ConvertTo-MiOSPreset.ps1, Invoke-MiOSProvision.ps1, New-MiOSAutounattend.ps1
# AI-functions: Read-MiosToml, Get-Toml, Get-MiOSHostname, Get-MiOSAccounts, ConvertTo-PwPair, ConvertTo-AccentDword, New-MiOSGlobalPrefCommands, New-MiOSBrandingCommands, New-MiOSLinuxLayoutCommands, New-MiOSProvisionCommands, Invoke-MiOSHostCommands
#Requires -Version 5.1
# =============================================================================
# MiOS-Provision.lib.ps1 -- UNIFIED provisioning core.
#
# Every MiOS-specific, install-time provisioning fact (accounts, hostname,
# branding/theme/accent/RGB/cursor/font, unified Linux-like layout, user
# prefs) is defined ONCE here, sourced from mios.toml SSOT with MiOS defaults.
# It emits plain `reg add` / `mkdir` command strings so the SAME set can be:
#   * embedded as <FirstLogonCommands> in a MiOS-XBOX.iso autounattend/NTLite
#     preset (ConvertTo-MiOSPreset.ps1), and
#   * run live on an already-installed box (Invoke-MiOSProvision.ps1),
# guaranteeing MiOS-XBOX.iso and the irm|iex installer reach identical state.
# The heavy MiOS components/services/servers (M:\, WSL2 podman dev VM, AI
# lanes, gateways, pgvector) are enabled by Get-MiOS.ps1, which BOTH paths run
# (the ISO via the nested irm|iex FirstLogon, existing Windows directly).
# =============================================================================

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
function ConvertTo-PwPair {
    param([string]$Pw, [switch]$Obfuscate)
    if ($Obfuscate) { @{ v=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Pw+'Password')); p='false' } }
    else { @{ v=$Pw; p='true' } }
}

function ConvertTo-AccentDword {
    # #RRGGBB -> 0xFFBBGGRR (DWM/Explorer accent DWORD, AABBGGRR little-endian).
    param([string]$Hex)
    $h = "$Hex".TrimStart('#')
    if ($h.Length -ne 6 -or $h -notmatch '^[0-9A-Fa-f]{6}$') { return '0xFF7F401A' }  # MiOS #1A407F
    return ('0xFF{0}{1}{2}' -f $h.Substring(4,2), $h.Substring(2,2), $h.Substring(0,2)).ToUpper()
}

function New-MiOSGlobalPrefCommands {
    # MiOS FUNCTIONAL preferences applied GLOBALLY: Default hive + first HKCU.
    param($Toml)
    $d = [ordered]@{
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt|REG_DWORD'  = (Get-Toml $Toml 'autounattend.preferences.hide_file_ext' '0')
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Hidden|REG_DWORD'       = (Get-Toml $Toml 'autounattend.preferences.show_hidden' '1')
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAl|REG_DWORD'    = (Get-Toml $Toml 'autounattend.preferences.taskbar_align' '0')
        'Software\Microsoft\Windows\CurrentVersion\Search|SearchboxTaskbarMode|REG_DWORD'    = (Get-Toml $Toml 'autounattend.preferences.taskbar_search' '0')
    }
    $cmds = New-Object System.Collections.Generic.List[string]
    foreach ($k in $d.Keys) { $p = $k -split '\|'; $cmds.Add(('reg add "HKCU\{0}" /v {1} /t {2} /d {3} /f' -f $p[0],$p[1],$p[2],$d[$k])) }
    $cmds.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"')
    foreach ($k in $d.Keys) { $p = $k -split '\|'; $cmds.Add(('reg add "HKU\MiOSDefault\{0}" /v {1} /t {2} /d {3} /f' -f $p[0],$p[1],$p[2],$d[$k])) }
    $cmds.Add('reg unload "HKU\MiOSDefault"')
    return $cmds
}

function New-MiOSBrandingCommands {
    # FULL MiOS visual identity applied GLOBALLY (HKLM + Default hive + first
    # HKCU), ALL from SSOT ([branding], [colors].accent, [theme]).
    param($Toml)
    if ((Get-Toml $Toml 'branding.windows.enable' 'true') -notmatch '^(true|1|yes)$') { return @() }
    $c = New-Object System.Collections.Generic.List[string]
    # OEM information (machine-wide).
    $oem = [ordered]@{
        Manufacturer = Get-Toml $Toml 'branding.oem_manufacturer' 'MiOS'
        Model        = Get-Toml $Toml 'branding.oem_model'        (Get-Toml $Toml 'branding.tagline' 'My Personal Operating System')
        SupportURL   = Get-Toml $Toml 'branding.oem_support_url'  'https://github.com/mios-dev'
        SupportHours = Get-Toml $Toml 'branding.oem_support_hours' 'Always on'
        SupportPhone = Get-Toml $Toml 'branding.oem_support_phone' ''
        Logo         = Get-Toml $Toml 'branding.oem_logo'         'C:\Windows\Web\MiOS\mios-logo.bmp'
    }
    foreach ($k in $oem.Keys) { if ("$($oem[$k])" -ne '') { $c.Add(('reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v {0} /t REG_SZ /d "{1}" /f' -f $k,$oem[$k])) } }
    # System UI font: Segoe UI -> Geist (machine-wide; Geist installed by bootstrap).
    if ((Get-Toml $Toml 'branding.font_substitute' 'true') -match '^(true|1|yes)$') {
        $uiFont = Get-Toml $Toml 'branding.ui_font' 'Geist'
        foreach ($face in @('Segoe UI','Segoe UI Semibold','Segoe UI Light','Segoe UI Semilight')) {
            $c.Add(('reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes" /v "{0}" /t REG_SZ /d "{1}" /f' -f $face,$uiFont))
        }
    }
    # Lockscreen (machine-wide).
    $wallpaper  = Get-Toml $Toml 'branding.wallpaper'  'C:\Windows\Web\MiOS\mios-wallpaper.jpg'
    $lockscreen = Get-Toml $Toml 'branding.lockscreen' $wallpaper
    if ("$lockscreen" -ne '') {
        $csp = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
        $c.Add(('reg add "{0}" /v LockScreenImageStatus /t REG_DWORD /d 1 /f' -f $csp))
        $c.Add(('reg add "{0}" /v LockScreenImagePath /t REG_SZ /d "{1}" /f' -f $csp,$lockscreen))
        $c.Add(('reg add "{0}" /v LockScreenImageUrl /t REG_SZ /d "{1}" /f' -f $csp,$lockscreen))
    }
    # Theme + accent + wallpaper + RGB (per hive).
    $accentDword = ConvertTo-AccentDword (Get-Toml $Toml 'colors.accent' '#1A407F')
    $darkApps    = if ((Get-Toml $Toml 'theme.mode' 'dark') -match '^(?i)light$') { '1' } else { '0' }
    $wallStyle   = Get-Toml $Toml 'branding.wallpaper_style' '10'
    $perHive = {
        param($hp)
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
            'Software\Microsoft\Lighting|UseSystemAccentColor|REG_DWORD'                                   = '1'
            'Software\Microsoft\Lighting|AmbientLightingEnabled|REG_DWORD'                                 = '1'
        }
        $lines = @()
        foreach ($k in $per.Keys) { $p = $k -split '\|'; $lines += ('reg add "{0}\{1}" /v {2} /t {3} /d {4} /f' -f $hp,$p[0],$p[1],$p[2],$(if ($p[2] -eq 'REG_SZ') { '"' + $per[$k] + '"' } else { $per[$k] })) }
        return $lines
    }
    $curEnable = (Get-Toml $Toml 'branding.cursor' 'true') -match '^(true|1|yes)$'
    $curDir    = Get-Toml $Toml 'branding.cursor_dir'    '%SystemRoot%\Cursors\Bibata-Modern-Classic'
    $curName   = Get-Toml $Toml 'branding.cursor_scheme' 'Bibata-Modern-Classic'
    $curMap = [ordered]@{ AppStarting='Working.ani'; Arrow='Default.cur'; Crosshair='Cross.cur'; Hand='Link.cur'; Help='Help.cur'; IBeam='IBeam.cur'; No='Unavailiable.cur'; NWPen='Handwriting.cur'; Person='Person.cur'; Pin='Pin.cur'; SizeAll='Move.cur'; SizeNESW='Diagonal_2.cur'; SizeNS='Vertical.cur'; SizeNWSE='Diagonal_1.cur'; SizeWE='Horizontal.cur'; UpArrow='Alternate.cur'; Wait='Busy.ani' }
    $cursorCmds = {
        param($hp)
        $ll = @()
        if (-not $curEnable) { return $ll }
        $ll += ('reg add "{0}\Control Panel\Cursors" /ve /t REG_SZ /d "{1}" /f' -f $hp,$curName)
        $ll += ('reg add "{0}\Control Panel\Cursors" /v "Scheme Source" /t REG_DWORD /d 2 /f' -f $hp)
        foreach ($cn in $curMap.Keys) { $ll += ('reg add "{0}\Control Panel\Cursors" /v {1} /t REG_EXPAND_SZ /d "{2}\{3}" /f' -f $hp,$cn,$curDir,$curMap[$cn]) }
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
    # STRIP Windows' default per-user sprawl, THEN impose a UNIFIED, Linux-like
    # layout that mirrors the WSL tree (C:\etc <-> /mnt/c/etc). This is a
    # strip-and-rebuild, not an additive overlay: OneDrive setup/autorun/links,
    # premade Desktop/Start shortcuts, and redundant known-folders are removed
    # from the Default profile (every future account) + Public + current user
    # BEFORE the clean MiOS tree is created.
    param($Toml)
    if ((Get-Toml $Toml 'autounattend.layout.enable' 'true') -notmatch '^(true|1|yes)$') { return @() }
    $sys = '%SystemDrive%'
    $tree = (Get-Toml $Toml 'autounattend.layout.linux_tree' 'etc usr var home opt srv tmp bin lib root').Trim()
    $c = New-Object System.Collections.Generic.List[string]

    # --- STRIP defaults (SSOT-gated) --------------------------------------
    if ((Get-Toml $Toml 'autounattend.layout.strip_defaults' 'true') -match '^(true|1|yes)$') {
        # OneDrive: kill autorun (machine + default hive), setup stubs, and the shortcut.
        $c.Add('reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f')
        $c.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"')
        $c.Add('reg delete "HKU\MiOSDefault\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f')
        $c.Add('reg unload "HKU\MiOSDefault"')
        $c.Add('del /f /q "%SystemRoot%\System32\OneDriveSetup.exe"')
        $c.Add('del /f /q "%SystemRoot%\SysWOW64\OneDriveSetup.exe"')
        $c.Add('del /f /q "C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"')
        # Premade shortcuts on Default/Public/current desktops (nothing pre-pinned).
        foreach ($dt in @('C:\Users\Default\Desktop','%PUBLIC%\Desktop','%USERPROFILE%\Desktop')) {
            $c.Add(('del /f /q "{0}\*.lnk"' -f $dt))
        }
        # Redundant default-profile known folders (kept: downloads/documents which we redirect).
        $redundant = (Get-Toml $Toml 'autounattend.layout.strip_folders' '3D Objects;Contacts;Favorites;Links;Saved Games;Searches;OneDrive')
        foreach ($rf in ($redundant -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $c.Add(('rmdir /s /q "C:\Users\Default\{0}"' -f $rf))
            $c.Add(('rmdir /s /q "%USERPROFILE%\{0}"' -f $rf))
        }
    }

    # --- REBUILD the clean MiOS tree --------------------------------------
    foreach ($d in ($tree -split '\s+' | Where-Object { $_ })) { $c.Add("mkdir $sys\$d") }
    if ((Get-Toml $Toml 'autounattend.layout.lowercase_userfolders' 'true') -match '^(true|1|yes)$') {
        $map = [ordered]@{
            '{374DE290-123F-4565-9164-39C4925E467B}' = 'downloads'
            'Personal'                               = 'documents'
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
            foreach ($k in $map.Keys) { $c.Add(('reg add "{0}" /v "{1}" /t REG_EXPAND_SZ /d "%USERPROFILE%\{2}" /f' -f $usf,$k,$map[$k])) }
            if ($needLoad) { $c.Add('reg unload "HKU\MiOSDefault"') }
        }
    }
    $stripGuids = (Get-Toml $Toml 'autounattend.layout.strip_thispc' '{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}').Trim()
    foreach ($g in ($stripGuids -split '\s+' | Where-Object { $_ })) {
        $c.Add("reg delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$g`" /f")
        $c.Add("reg delete `"HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\$g`" /f")
    }
    return $c
}

function New-MiOSProvisionCommands {
    # The UNIFIED, ordered MiOS provisioning set (layout -> branding -> prefs).
    # Returns @( @{ Description; Commands=@(...) }, ... ). Consumed as
    # <FirstLogonCommands> (ISO) or run live (existing Windows) -- one source.
    param($Toml)
    return @(
        @{ Description = 'MiOS unified Linux-like directory layout';                 Commands = @(New-MiOSLinuxLayoutCommands -Toml $Toml) }
        @{ Description = 'MiOS global branding + theme (OEM/accent/wallpaper/RGB)';   Commands = @(New-MiOSBrandingCommands   -Toml $Toml) }
        @{ Description = 'MiOS global user preferences';                              Commands = @(New-MiOSGlobalPrefCommands -Toml $Toml) }
    )
}

function Invoke-MiOSHostCommands {
    # LIVE-apply the emitted `reg`/`mkdir` command strings on THIS machine (the
    # existing-Windows path applies exactly what the ISO bakes at first logon).
    param([string[]]$Commands, [string]$Label)
    if ($Label) { Write-Host "[*] $Label ($($Commands.Count) commands) ..." -ForegroundColor Cyan }
    foreach ($cmd in $Commands) {
        try { & cmd.exe /c $cmd *> $null } catch {}
    }
}
