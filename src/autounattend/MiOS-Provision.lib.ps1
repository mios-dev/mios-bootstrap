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

# Posture-B virtualization allowlist -- the NTLite component-removal texts and
# DISM feature names MiOS MUST keep for its WSL2/podman substrate. Defined ONCE
# here (single source) and consumed by ConvertTo-MiOSPreset.ps1 (re-preserve on
# sanitize) AND Merge-MiOSPresets.ps1 (prefer ENABLED on a Feature conflict), so
# the virt-preserve set can never drift between the two. Was duplicated verbatim
# in both scripts (NO-HARDCODE: SSOT-restated literal) -> centralized here.
function Get-MiOSVirtComponentMatch { @('lxss', 'windowssubsystemforlinux') }
function Get-MiOSVirtFeatureMatch {
    @('VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V',
      'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM',
      'Windows.HyperV.OptionalFeature')
}

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

function New-MiOSXboxModeCommands {
    # Xbox Full Screen Experience (FSE) "out of the box" for the MiOS-XBOX edition.
    # Emits the REG-ONLY equivalent of `vivetool /enable` (importing these keys
    # produces the same result -- no vivetool.exe shipped): a FeatureManagement
    # override per feature ID + the DeviceForm spoof so the toggle surfaces on
    # non-handheld hardware. Gated on [autounattend.xbox].enable (default off --
    # only the MiOS-XBOX edition turns it on). Feature IDs come from SSOT, NOT a
    # hardcoded list: they are Controlled-Feature-Rollout IDs that CHANGE PER
    # BUILD, so the target build pins them via [autounattend.xbox].feature_ids
    # (Dev-channel default = the single stable FSE id; 24H2 needs the pair).
    #
    # Live form only (HKLM\SYSTEM\CurrentControlSet...): this runs at FirstLogon.
    # The offline image-servicing form (ControlSet001) is written by New-MiOSISO.ps1
    # from the SAME SSOT ids. NOTE (honest limitation): the FSE HOME still needs a
    # signed-in Microsoft/Xbox account at runtime + the Xbox app; those cannot be
    # pre-baked. This gets the mode enabled + discoverable; sign-in is first-run.
    param($Toml)
    $cmds = New-Object System.Collections.Generic.List[string]
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -notmatch '^(?i:true|1|yes)$') { return $cmds }

    $ov = 'HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8'
    $ids = (Get-Toml $Toml 'autounattend.xbox.feature_ids' '59765208') -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
    foreach ($id in $ids) {
        $cmds.Add(('reg add "{0}\{1}" /v EnabledState /t REG_DWORD /d 2 /f'        -f $ov,$id))   # 2 = Enabled
        $cmds.Add(('reg add "{0}\{1}" /v EnabledStateOptions /t REG_DWORD /d 0 /f' -f $ov,$id))
        $cmds.Add(('reg add "{0}\{1}" /v Variant /t REG_DWORD /d 0 /f'             -f $ov,$id))
        $cmds.Add(('reg add "{0}\{1}" /v VariantPayload /t REG_DWORD /d 0 /f'      -f $ov,$id))
        $cmds.Add(('reg add "{0}\{1}" /v VariantPayloadKind /t REG_DWORD /d 0 /f'  -f $ov,$id))
    }
    # DeviceForm spoof (0x2E = 46 = "gaming handheld") so the FSE toggle surfaces
    # on a desktop/laptop that doesn't self-identify as a handheld. SSOT-gated.
    if ((Get-Toml $Toml 'autounattend.xbox.device_form_spoof' 'true') -match '^(?i:true|1|yes)$') {
        $cmds.Add('reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OEM" /v DeviceForm /t REG_DWORD /d 46 /f')
    }
    # Set the Xbox app as the gaming HOME APP so the box boots into the full-screen
    # Xbox console UI (paired with AutoLogon to the local account + the autounattend
    # Microsoft-Windows-Gaming-Configuration StartupToGamingHome=true). Empty
    # home_app disables Xbox mode. HONEST LIMIT: with no Microsoft account the FSE
    # chrome renders at the Xbox SIGN-IN screen -- there is no logged-out populated
    # dashboard (hard MS gate). This is the operator-chosen logged-out end state.
    $homeApp = Get-Toml $Toml 'autounattend.xbox.home_app' 'Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
    if ($homeApp) {
        $cmds.Add(('reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GamingConfiguration" /v GamingHomeApp /t REG_SZ /d "{0}" /f' -f $homeApp))
    }
    return $cmds
}

# ── MiOS-XBOX protect-list (never debloat these -- Xbox/gaming + virt survival) ──
# Centralized, consumed by Merge-MiOSPresets.ps1 (strip from the union) and
# New-MiOSISO.ps1 (never remove/disable during DISM servicing). Sourced from the
# researched "removing X breaks Y" manifest -- NOT a guess. The union merge of the
# NTLite presets re-added several of these as removals (bioenrollment/sechealthui/
# storepurchaseapp/contentdeliverymanager) even though the curated ULTRA-PLUS base
# preserved them; this list is the hard exclusion that makes the merged artifact a
# TRULY perfected MiOS-XBOX preset that can still boot Xbox mode + the MiOS brain.

# NTLite RemoveComponents/<c> KEY tokens (case-insensitive, matched as the leading
# token before the friendly-name quote) that must NEVER be removed.
function Get-MiOSXboxProtectComponents {
    @(
        # --- Xbox / gaming / Store (removing these breaks FSE + Game Pass) ---
        'microsoft.gamingapp', 'microsoft.xboxgamingoverlay', 'microsoft.xboxgameoverlay',
        'microsoft.xboxidentityprovider', 'microsoft.xbox.tcui', 'microsoft.xboxspeechtotextoverlay',
        'microsoft.xboxgamecallableui', 'microsoft.gamingservices', 'microsoft.windowsstore',
        'microsoft.storepurchaseapp', 'microsoft.desktopappinstaller',
        'microsoft.bioenrollment', 'microsoft.sechealthui', 'microsoft.windows.contentdeliverymanager',
        'gameexplorer', 'captureservice', 'microsoft.windows.capturepicker',
        # --- virtualization / MiOS brain (WSL2 + podman + Hyper-V + HCS) ---
        'lxss', 'lxssmanager', 'microsoftcorporationii.windowssubsystemforlinux',
        'windowssubsystemforlinux', 'virtualmachineplatform', 'virtual machine platform',
        'hyper-v', 'hypervisorplatform', 'windows hypervisor platform',
        'containers', 'containers-disposableclientvm', 'windows sandbox', 'vmcompute'
    )
}

# NTLite Features <Feature name=...> that must NEVER be disabled (kept enabled/present).
# Virtualization set comes from the shared Posture-B allowlist; WebView2 is added
# because the Xbox app's account/store panels render in it.
function Get-MiOSXboxProtectFeatures {
    @(Get-MiOSVirtFeatureMatch) + @(
        'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services',
        'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell',
        'Microsoft-Hyper-V-Management-Clients', 'Containers',
        'Edge.Webview2.Platform'
    )
}

# ── MiOS as a boot-time SYSTEM service, up BEFORE logon (SPECIALIZE pass) ──────
# Emits the commands that register the MiOS service plane so it starts at Windows
# BOOT, before any interactive/RDP session shows a desktop. These run in the
# autounattend `specialize` pass as SYSTEM (pre-OOBE, pre-logon, OEM-key-safe) --
# NOT FirstLogonCommands (per-user, post-logon), which is what MiOS moves away from.
#
# HARD CONSTRAINT (researched, high-confidence): wsl.exe CANNOT run as
# LocalSystem/SYSTEM -- WSL is tied to a user profile (microsoft/WSL#11280,
# "by design"). So the persistent boot task runs under a DEDICATED, NON-admin
# local account (default `mios-svc`), which owns the WSL distro registration and
# the keep-alive holder. The specialize provisioner (SYSTEM) only: enables the
# WSL2 optional feature, creates that account, enables RDP, and registers the
# MiOS-Host ONSTART task. The heavy one-time install (wsl import + podman) is done
# BY MiOS-Host.ps1 on its first run, under mios-svc. See docs/pre-logon-system-services.md.
function New-MiOSHostServiceCommands {
    param($Toml)
    $cmds = New-Object System.Collections.Generic.List[string]
    if ((Get-Toml $Toml 'autounattend.service.enable' 'true') -notmatch '^(?i:true|1|yes)$') { return $cmds }

    $svcUser  = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-svc'
    # Service-account password: SSOT service key, else the global default_password.
    # An answer-file credential is a first-boot temporary cred (rotate on first run).
    $svcPass  = Get-Toml $Toml 'autounattend.service.svc_password' (Get-Toml $Toml 'identity.default_password' 'mios')
    $distro   = Get-Toml $Toml 'autounattend.service.wsl_distro' 'MiOS'
    $script   = Get-Toml $Toml 'autounattend.service.host_script' 'C:\ProgramData\MiOS\MiOS-Host.ps1'
    $bootUrl  = Get-Toml $Toml 'autounattend.bootstrap_url' 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1'

    # 1) WSL2 platform feature (the only OC strictly required for the MiOS brain).
    $cmds.Add('dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart')
    $cmds.Add('dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart')
    # 2) Dedicated NON-admin service account (WSL can't run as SYSTEM).
    $cmds.Add(('net user "{0}" "{1}" /add /y' -f $svcUser, $svcPass))
    $cmds.Add(('wmic useraccount where "name=''{0}''" set PasswordExpires=false' -f $svcUser))
    # 3) RDP: allow connections + firewall group + NLA (all three are required).
    if ((Get-Toml $Toml 'autounattend.service.enable_rdp' 'true') -match '^(?i:true|1|yes)$') {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f')
        $cmds.Add('netsh advfirewall firewall set rule group="remote desktop" new enable=Yes')
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f')
    }
    # 4) Register MiOS-Host as an ONSTART task under mios-svc (ONSTART fires in
    #    Session 0 at boot, before any logon; schtasks grants the batch-logon right).
    #    HIGHEST run level so the first-run install can elevate.
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{0}\" -Distro {1} -BootstrapUrl {2}' -f $script, $distro, $bootUrl
    $cmds.Add(('schtasks /create /tn "MiOS-Host" /sc ONSTART /rl HIGHEST /ru "{0}" /rp "{1}" /tr "{2}" /f' -f $svcUser, $svcPass, $tr))

    # 5) MiOS-XBOX first-login HYDRATION task: an ONLOGON task (runs in the
    #    interactive/auto-login user's session, HIGHEST) that fetches the
    #    Store-delivered gaming runtime the WU-stripped image can't bake
    #    (Gaming Services + WebView2 + deps). No /ru -> runs for whoever logs on
    #    (the AutoLogon admin); self-removes once its marker is set. Gated on the
    #    Xbox edition. Runs "post 1 login while the user signs into Xbox".
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -match '^(?i:true|1|yes)$') {
        $hydrate = Get-Toml $Toml 'autounattend.xbox.hydrate_script' 'C:\ProgramData\MiOS\MiOS-XBOX-Hydrate.ps1'
        $htr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{0}\"' -f $hydrate
        $cmds.Add(('schtasks /create /tn "MiOS-XBOX-Hydrate" /sc ONLOGON /rl HIGHEST /tr "{0}" /f' -f $htr))
    }
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
        @{ Description = 'MiOS-XBOX: Xbox Full Screen Experience enablement';         Commands = @(New-MiOSXboxModeCommands   -Toml $Toml) }
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
