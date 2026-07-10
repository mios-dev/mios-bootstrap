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
        $line = $raw.Trim()
        # Skip blank + full-line comments. Strip only a WHITESPACE-preceded trailing
        # comment -- a bare `#.*$` strip would eat a hex value like accent="#1A407F".
        if (-not $line -or $line.StartsWith('#')) { continue }
        $line = ($line -replace '\s+#.*$', '').Trim()
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
            # Unescape TOML basic-string backslashes ("C:\\x" -> "C:\x") so SSOT paths
            # match the single-backslash in-code defaults.
            $k = $Matches['k'].Trim(); $v = ($Matches['v'].Trim().Trim('"', "'")) -replace '\\\\', '\'
            if ($section -eq 'account' -and $cur -ne $null) { $cur[$k] = $v }
            else { $r.scalars["$section.$k"] = $v }   # incl. autounattend.preferences.* (read via Get-Toml/scalars)
        }
    }
    if ($cur) { $r.accounts += ,$cur }
    return $r
}
function Get-Toml { param($T,[string]$Key,[string]$Def='') if ($T.scalars.ContainsKey($Key) -and $T.scalars[$Key]) { $T.scalars[$Key] } else { $Def } }

function Apply-MiosEdition {
    param($T, [string]$Edition)
    if (-not $Edition) { return $T }
    $prefix = "editions.$Edition."
    $found = $false
    $keys = @($T.scalars.Keys)
    foreach ($k in $keys) {
        if ($k.StartsWith($prefix)) {
            $baseKey = $k.Substring($prefix.Length)
            $T.scalars[$baseKey] = $T.scalars[$k]
            $found = $true
        }
    }
    if (-not $found) {
        Write-Warning "Edition '$Edition' not found in mios.toml (no prefix '$prefix' matched). Using base configuration."
    } else {
        Write-Host "[*] Applied edition overrides for '$Edition'." -ForegroundColor Cyan
    }
    return $T
}


# Resolve the volume used for ISO build scratch + output. SSOT autounattend.work_root
# wins; else auto-select the fixed drive with the MOST free space. NO hardcoded drive
# letter -- the retired 'M:\' default overflowed a 95%-full 256 GB volume mid-WIM-build
# (the install.wim archive alone needs ~15-20 GB). Degrade-open to %TEMP% if the drive
# query fails. Returns a '<drive>\MiOS' root (or the operator's work_root verbatim).
function Resolve-MiOSBuildRoot {
    param($Toml)
    $root = Get-Toml $Toml 'autounattend.work_root' ''
    if ($root) { return $root.TrimEnd('\') }
    try {
        $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                Sort-Object FreeSpace -Descending | Select-Object -First 1
        if ($best) {
            Write-Host ("[*] Build volume: {0} ({1} GB free) -- most-free fixed drive" -f `
                $best.DeviceID, [math]::Round($best.FreeSpace/1GB,1)) -ForegroundColor DarkGray
            return (Join-Path "$($best.DeviceID)\" 'MiOS')
        }
    } catch {}
    return (Join-Path $env:TEMP 'MiOS')
}

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
    $ids = (Get-Toml $Toml 'autounattend.xbox.feature_ids' '58989070,59765208') -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
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

# -- MiOS-XBOX protect-list (never debloat these -- Xbox/gaming + virt survival) --
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

# -- MiOS as a boot-time SYSTEM service, up BEFORE logon (SPECIALIZE pass) ------
# Emits the commands that register the MiOS service plane so it starts at Windows
# BOOT, before any interactive/RDP session shows a desktop. These run in the
# autounattend `specialize` pass as SYSTEM (pre-OOBE, pre-logon, OEM-key-safe) --
# NOT FirstLogonCommands (per-user, post-logon), which is what MiOS moves away from.
#
# HARD CONSTRAINT (researched, high-confidence): wsl.exe CANNOT run as
# LocalSystem/SYSTEM -- WSL is tied to a user profile (microsoft/WSL#11280,
# "by design"). So the persistent boot task runs under a DEDICATED, NON-admin
# local account (default `mios-sudo`), which owns the WSL distro registration and
# the keep-alive holder. The specialize provisioner (SYSTEM) only: enables the
# WSL2 optional feature, creates that account, enables RDP, and registers the
# MiOS-Host ONSTART task. The heavy one-time install (wsl import + podman) is done
# BY MiOS-Host.ps1 on its first run, under mios-sudo. See docs/pre-logon-system-services.md.
function New-MiOSHostServiceCommands {
    param($Toml)
    $cmds = New-Object System.Collections.Generic.List[string]
    if ((Get-Toml $Toml 'autounattend.service.enable' 'true') -notmatch '^(?i:true|1|yes)$') { return $cmds }

    $svcUser  = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-sudo'
    # Service-account password: SSOT service key, else the global default_password.
    # An answer-file credential is a first-boot temporary cred (rotate on first run).
    $svcPass  = Get-Toml $Toml 'autounattend.service.svc_password' (Get-Toml $Toml 'identity.default_password' 'user')
    $script   = Get-Toml $Toml 'autounattend.service.host_script' 'C:\ProgramData\MiOS\MiOS-Host.ps1'

    # 1) WSL2 platform feature (the only OC strictly required for the MiOS brain).
    $cmds.Add('dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart')
    $cmds.Add('dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart')
    # 2) SERVICE ACCOUNT = the built-in Administrator (RID 500), renamed to svcUser + hidden.
    #    * RID-500 runs with a FULL, UNFILTERED token by default (FilterAdministratorToken=0,
    #    keyed to the RID not the name) and holds SeBatchLogonRight -- so its scheduled tasks
    #    (MiOS-Host WSL brain, MiOS-XBOX-Hydrate Gaming Services) actually RUN. A freshly
    #    created service account instead hit a stored-password batch-logon failure -> EVERY
    #    task registered but never executed (brain never deployed, Gaming Services never
    #    installed). Set the password + activate, rename Administrator -> svcUser, hide it.
    #    (MS-doc-verified: docs/oem-dism-techniques-2026-07-06.md S3.)
    $cmds.Add(('net user Administrator "{0}" /active:yes' -f $svcPass))
    $cmds.Add(('powershell.exe -NoProfile -Command "Rename-LocalUser -Name Administrator -NewName ''{0}''"' -f $svcUser))
    $cmds.Add(('powershell.exe -NoProfile -Command "Set-LocalUser -Name ''{0}'' -PasswordNeverExpires $true"' -f $svcUser))
    # Hide the renamed admin from LogonUI (matches by CURRENT name -> AFTER the rename).
    # Only suppresses enumeration; the account still runs tasks, and autologon (the DESKTOP
    # user, a different account) is unaffected.
    $cmds.Add(('reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" /v "{0}" /t REG_DWORD /d 0 /f' -f $svcUser))
    # 3) RDP: allow connections + firewall group + NLA (all three are required).
    if ((Get-Toml $Toml 'autounattend.service.enable_rdp' 'true') -match '^(?i:true|1|yes)$') {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f')
        $cmds.Add('netsh advfirewall firewall set rule group="remote desktop" new enable=Yes')
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f')
    }
    # 4) Register MiOS-Host as an ONSTART task under mios-sudo (ONSTART fires in
    #    Session 0 at boot, before any logon; schtasks grants the batch-logon right).
    #    HIGHEST run level so the first-run install can elevate.
    #    NB: the /tr value must NOT contain nested/escaped quotes (\"...\") -- Windows
    #    Setup's unattend validator REJECTS the whole answer file (0x80220005 "Value
    #    is invalid") for a RunSynchronousCommand/Path that does. The script path is
    #    space-free (SSOT default under C:\ProgramData\MiOS), so it needs no inner
    #    quoting; MiOS-Host.ps1 self-resolves the distro and defaults the bootstrap
    #    URL, so -Distro/-BootstrapUrl are omitted here (keeps the value short + valid).
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}' -f $script
    $cmds.Add(('schtasks /create /tn "MiOS-Host" /sc ONSTART /rl HIGHEST /ru "{0}" /rp "{1}" /tr "{2}" /f' -f $svcUser, $svcPass, $tr))

    # 4b) Register the MiOS-Daemon -- the always-on supervisor that circumvents the
    #     fragile one-shot triggers: a MINUTE/1 task (Task Scheduler IS the service)
    #     run as mios-sudo; each run is one tick then exit (keep-warm + health +
    #     auto-update). MINUTE fires within a minute of boot AND every minute after,
    #     across reboots -- no infinite-loop / execution-time-limit fragility. Same
    #     no-nested-quotes rule as MiOS-Host (space-free SSOT script path).
    if ((Get-Toml $Toml 'autounattend.daemon.enable' 'true') -match '^(?i:true|1|yes)$') {
        $daemon = Get-Toml $Toml 'autounattend.daemon.script' 'C:\ProgramData\MiOS\MiOS-Daemon.ps1'
        $dtr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}' -f $daemon
        $cmds.Add(('schtasks /create /tn "MiOS-Daemon" /sc MINUTE /mo 1 /rl HIGHEST /ru "{0}" /rp "{1}" /tr "{2}" /f' -f $svcUser, $svcPass, $dtr))
    }

    # 4c) Register the MiOS-AccountSync scheduled task if accounts.db_backed is enabled.
    if ((Get-Toml $Toml 'accounts.db_backed' 'false') -match '^(?i:true|1|yes)$') {
        $syncScript = 'C:\ProgramData\MiOS\MiOS-AccountSync.ps1'
        $strCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}' -f $syncScript
        $cmds.Add(('schtasks /create /tn "MiOS-AccountSync" /sc MINUTE /mo 1 /rl HIGHEST /ru "SYSTEM" /tr "{0}" /f' -f $strCmd))
    }

    # 5) MiOS-XBOX HYDRATION: install the Store-delivered gaming runtime the WU-stripped
    #    image cannot bake -- GAMING SERVICES (Store-locked + driver, cannot be provisioned
    #    offline), the Xbox app, WebView2 -- via `winget msstore`. Runs as svcUser (RID-500,
    #    full token) on a MINUTE cadence (NOT ONLOGON: ONLOGON tasks were observed NOT to
    #    register in specialize, so Gaming Services never installed). Marker-gated + self-
    #    removing -> installs once the account is up + network is live, then stops. Gated on
    #    the Xbox edition.
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -match '^(?i:true|1|yes)$') {
        $hydrate = Get-Toml $Toml 'autounattend.xbox.hydrate_script' 'C:\ProgramData\MiOS\MiOS-XBOX-Hydrate.ps1'
        # no nested quotes (see MiOS-Host /tr note above); space-free SSOT path
        $htr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}' -f $hydrate
        $cmds.Add(('schtasks /create /tn "MiOS-XBOX-Hydrate" /sc MINUTE /mo 2 /rl HIGHEST /ru "{0}" /rp "{1}" /tr "{2}" /f' -f $svcUser, $svcPass, $htr))
    }

    # 6) ACCOUNT-DEPENDENT provisioning (KEYSTONE). SetupComplete.cmd runs BEFORE the
    #    desktop account is created -- PROVEN: mios-remote's `net localgroup "Remote
    #    Desktop Users" "mios"` returned System error 1317 "account does not exist"
    #    (mios-sudo, made HERE in specialize, existed; mios, made later in oobeSystem, did
    #    not). So the account-dependent work -- adding the real account to Remote Desktop
    #    Users (enhanced-session sign-in) and applying the per-user MiOS theme to its OWN
    #    hive (SetupComplete's HKCU is SYSTEM's; the Default-hive copy does not carry to
    #    the light-themed account Windows creates) -- must run AFTER the account exists.
    #    ONLOGON tasks were observed NOT to register in specialize (only ONSTART/MINUTE
    #    did), so use a PROVEN MINUTE task run as the admin svc account: mios-provision-
    #    live.ps1 waits for the account, applies RDU + theme to its real profile, marker-
    #    gates, self-deletes. Space-free path -> no inner quotes (unattend validator rule).
    if ((Get-Toml $Toml 'autounattend.remote.onlogon_fallback' 'true') -match '^(?i:true|1|yes)$') {
        $pvr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\mios-provision-live.ps1'
        # Run MiOS-Provision as SYSTEM, NOT the svc account. The account-dependent work
        # (Remote Desktop Users add + per-user theme to the real profile hive + a reboot)
        # needs NO WSL, so SYSTEM can do all of it -- and a SYSTEM scheduled task is the
        # MOST RELIABLE execution context: it has no stored-password / batch-logon
        # dependency (the exact failure that stopped every mios-sudo task from running).
        # This GUARANTEES the MiOS theme + RDU right actually apply post-account.
        $cmds.Add(('schtasks /create /tn "MiOS-Provision" /sc MINUTE /mo 1 /rl HIGHEST /ru "SYSTEM" /tr "{0}" /f' -f $pvr))
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
    # Theme + accent + wallpaper + RGB + cursor are PER-USER; factored into
    # Get-MiOSPerUserBrandingReg so the SAME SSOT-derived key set can also be applied to
    # every EXISTING profile at runtime (mios-identity-peruser.ps1). This matters because
    # under SetupComplete (SYSTEM) 'HKCU' is SYSTEM's hive -- NOT the desktop user's -- so
    # the theme must be loaded into each real NTUSER.DAT. Here we still emit the live HKCU
    # (correct for the Invoke-MiOSProvision parity path, which runs AS the user) + the
    # Default hive (future accounts inherit it).
    foreach ($l in (Get-MiOSPerUserBrandingReg -Toml $Toml -HivePrefix 'HKCU')) { $c.Add($l) }
    $c.Add('reg load "HKU\MiOSDefault" "C:\Users\Default\NTUSER.DAT"')
    foreach ($l in (Get-MiOSPerUserBrandingReg -Toml $Toml -HivePrefix 'HKU\MiOSDefault')) { $c.Add($l) }
    $c.Add('reg unload "HKU\MiOSDefault"')
    $livingWallpaper = Get-Toml $Toml 'branding.living_wallpaper' 'true'
    $livingWallpaperMode = Get-Toml $Toml 'branding.living_wallpaper_mode' 'shader'
    
    $bg = (Get-Toml $Toml 'colors.bg' '#282262').Replace('#', '')
    $accent = (Get-Toml $Toml 'colors.accent' '#1A407F').Replace('#', '')
    $cursor = (Get-Toml $Toml 'colors.cursor' '#F35C15').Replace('#', '')
    $subtle = (Get-Toml $Toml 'colors.subtle' '#B7C9D7').Replace('#', '')
    $success = (Get-Toml $Toml 'colors.success' '#3E7765').Replace('#', '')

    if ($livingWallpaper -match '^(true|1|yes)$' -and $livingWallpaperMode -eq 'shader') {
        $dir = "C:\Windows\Web\MiOS"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        
        $htmlB64 = Get-MiOSLivingWallpaperHtmlB64
        [IO.File]::WriteAllBytes("$dir\living-wallpaper.html", [System.Convert]::FromBase64String($htmlB64))
        
        $csB64 = Get-MiOSLivingWallpaperCsB64
        [IO.File]::WriteAllBytes("$dir\MiOS-Wallpaper.cs", [System.Convert]::FromBase64String($csB64))

        $svcCsB64 = Get-MiOSLivingWallpaperServiceCsB64
        [IO.File]::WriteAllBytes("$dir\MiOS-Wallpaper-Service.cs", [System.Convert]::FromBase64String($svcCsB64))
        
        # Download WebView2 DLLs if not present
        if (-not (Test-Path "$dir\Microsoft.Web.WebView2.Core.dll") -or -not (Test-Path "$dir\Microsoft.Web.WebView2.WinForms.dll")) {
            try {
                $version = "1.0.4022.49"
                $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
                $zipFile = Join-Path $env:TEMP "webview2_$version.zip"
                $extractDir = Join-Path $env:TEMP "webview2_extracted_$version"
                
                Invoke-WebRequest -Uri $url -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
                
                if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force | Out-Null }
                Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
                
                Copy-Item "$extractDir\lib\net462\Microsoft.Web.WebView2.Core.dll" $dir -Force
                Copy-Item "$extractDir\lib\net462\Microsoft.Web.WebView2.WinForms.dll" $dir -Force
                Copy-Item "$extractDir\runtimes\win-x64\native\WebView2Loader.dll" $dir -Force
                
                Remove-Item $zipFile -Force -ErrorAction SilentlyContinue | Out-Null
                Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            } catch {}
        }

        foreach ($csc in @("C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe")) {
            if (Test-Path $csc) {
                & $csc /nologo /target:winexe /optimize+ /platform:x64 /lib:$dir /r:Microsoft.Web.WebView2.Core.dll /r:Microsoft.Web.WebView2.WinForms.dll /out:$dir\MiOS-Wallpaper.exe $dir\MiOS-Wallpaper.cs | Out-Null
                & $csc /nologo /target:exe /optimize+ /platform:x64 /out:$dir\MiOS-Wallpaper-Service.exe /r:System.ServiceProcess.dll $dir\MiOS-Wallpaper-Service.cs | Out-Null
                break
            }
        }

        # Delete or block static wallpaper files to force solid color background
        Remove-Item "$dir\mios-wallpaper.jpg" -Force -ErrorAction SilentlyContinue
        $img0 = "C:\Windows\Web\Wallpaper\Windows\img0.jpg"
        if (Test-Path $img0) {
            Remove-Item $img0 -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $img0)) {
                New-Item -ItemType Directory -Path $img0 -Force | Out-Null
            }
        }
        
        $url = "file:///C:/Windows/Web/MiOS/living-wallpaper.html?bg=$bg^&accent=$accent^&cursor=$cursor^&subtle=$subtle^&success=$success"
        $c.Add(('reg add "HKLM\SOFTWARE\MiOS" /v "WallpaperUrl" /t REG_SZ /d "{0}" /f' -f $url))
        $c.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fNoRemoteDesktopWallpaper /t REG_DWORD /d 1 /f')
        $c.Add('sc.exe create MiOS-Wallpaper-Service binPath= "C:\Windows\Web\MiOS\MiOS-Wallpaper-Service.exe" displayName= "MiOS Living Wallpaper Service" start= auto')
        $c.Add('sc.exe start MiOS-Wallpaper-Service')
    } else {
        $c.Add('reg delete "HKLM\SOFTWARE\MiOS" /v "WallpaperUrl" /f 2>nul')
        $c.Add('sc.exe stop MiOS-Wallpaper-Service 2>nul')
        $c.Add('sc.exe delete MiOS-Wallpaper-Service 2>nul')
    }
    return $c
}

function Get-MiOSCursorMap {
    # Windows cursor-role -> Bibata-Modern-Classic-Windows filename, per the package's own
    # install.inf (authoritative). SINGLE SOURCE -- consumed by Get-MiOSPerUserBrandingReg
    # (the reg scheme) AND the MiOS.theme generator, so the mapping is never duplicated.
    [ordered]@{ AppStarting='Work.ani'; Arrow='Pointer.cur'; Crosshair='Cross.cur'; Hand='Link.cur'; Help='Help.cur'; IBeam='Text.cur'; No='Unavailable.cur'; NWPen='Handwriting.cur'; Person='Person.cur'; Pin='Pin.cur'; SizeAll='Move.cur'; SizeNESW='Dgn2.cur'; SizeNS='Vert.cur'; SizeNWSE='Dgn1.cur'; SizeWE='Horz.cur'; UpArrow='Alternate.cur'; Wait='Busy.ani' }
}

function Get-MiOSPerUserBrandingReg {
    # The PER-USER MiOS visual identity (dark/accent/transparency/RGB + wallpaper +
    # Bibata cursor scheme) as reg-add lines for a GIVEN hive prefix ($HivePrefix, e.g.
    # 'HKCU', 'HKU\MiOSDefault', or a runtime-loaded 'HKU\MIOS_LIVE'). Factored out of
    # New-MiOSBrandingCommands so the identical SSOT-derived key set can be applied to
    # (a) the live user's HKCU (parity path), (b) the Default hive (future users), and
    # (c) EVERY existing real profile at runtime -- the last is required because under
    # SetupComplete's SYSTEM context 'HKCU' is SYSTEM's hive, not the desktop user's, so
    # the already-created account would otherwise never get themed. All values from SSOT.
    param($Toml, [string]$HivePrefix)
    if ((Get-Toml $Toml 'branding.windows.enable' 'true') -notmatch '^(true|1|yes)$') { return @() }
    $accentDword = ConvertTo-AccentDword (Get-Toml $Toml 'colors.accent' '#1A407F')
    $darkApps    = if ((Get-Toml $Toml 'theme.mode' 'dark') -match '^(?i)light$') { '1' } else { '0' }
    $wallpaper   = Get-Toml $Toml 'branding.wallpaper'       'C:\Windows\Web\MiOS\mios-wallpaper.jpg'
    $wallStyle   = Get-Toml $Toml 'branding.wallpaper_style' '10'
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
    foreach ($k in $per.Keys) { $p = $k -split '\|'; $lines += ('reg add "{0}\{1}" /v {2} /t {3} /d {4} /f' -f $HivePrefix,$p[0],$p[1],$p[2],$(if ($p[2] -eq 'REG_SZ') { '"' + $per[$k] + '"' } else { $per[$k] })) }
    if ((Get-Toml $Toml 'branding.cursor' 'true') -match '^(true|1|yes)$') {
        $curDir  = Get-Toml $Toml 'branding.cursor_dir'    '%SystemRoot%\Cursors\Bibata-Modern-Classic'
        $curName = Get-Toml $Toml 'branding.cursor_scheme' 'Bibata-Modern-Classic'
        # Role -> Bibata-Modern-Classic-Windows filename, per the package's own install.inf
        # (authoritative). The prior map used names from an older release (Default/IBeam/
        # Vertical/Horizontal/Diagonal_1/2/Working) that DO NOT EXIST in the current zip --
        # so every mismapped role, including Arrow (the main pointer -> Default.cur), fell
        # back to the Windows default: "no Bibata" even when staged. These match the files.
        $curMap = Get-MiOSCursorMap
        $lines += ('reg add "{0}\Control Panel\Cursors" /ve /t REG_SZ /d "{1}" /f' -f $HivePrefix,$curName)
        $lines += ('reg add "{0}\Control Panel\Cursors" /v "Scheme Source" /t REG_DWORD /d 2 /f' -f $HivePrefix)
        foreach ($cn in $curMap.Keys) { $lines += ('reg add "{0}\Control Panel\Cursors" /v {1} /t REG_EXPAND_SZ /d "{2}\{3}" /f' -f $HivePrefix,$cn,$curDir,$curMap[$cn]) }
    }
    return $lines
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


function Get-MiOSLivingWallpaperHtmlB64 {
    return 'PCFET0NUWVBFIGh0bWw+CjxodG1sPgo8aGVhZD4KICAgIDxtZXRhIGNoYXJzZXQ9InV0Zi04Ij4KICAgIDx0aXRsZT5NaU9TIExpdmluZyBXYWxscGFwZXI8L3RpdGxlPgogICAgPHN0eWxlPgogICAgICAgIGh0bWwsIGJvZHkgewogICAgICAgICAgICBtYXJnaW46IDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAgICBoZWlnaHQ6IDEwMCU7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIGJhY2tncm91bmQtY29sb3I6ICMyODIyNjI7CiAgICAgICAgfQogICAgICAgIGNhbnZhcyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgICAgICB3aWR0aDogMTAwdnc7CiAgICAgICAgICAgIGhlaWdodDogMTAwdmg7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KICAgIDxjYW52YXMgaWQ9ImNhbnZhcyI+PC9jYW52YXM+CiAgICA8c2NyaXB0PgogICAgICAgIGNvbnN0IGNhbnZhcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYW52YXMnKTsKICAgICAgICBjb25zdCBnbCA9IGNhbnZhcy5nZXRDb250ZXh0KCd3ZWJnbCcpIHx8IGNhbnZhcy5nZXRDb250ZXh0KCdleHBlcmltZW50YWwtd2ViZ2wnKTsKICAgICAgICAKICAgICAgICBpZiAoIWdsKSB7CiAgICAgICAgICAgIGNvbnNvbGUuZXJyb3IoJ1dlYkdMIG5vdCBzdXBwb3J0ZWQnKTsKICAgICAgICAgICAgZG9jdW1lbnQuYm9keS5zdHlsZS5iYWNrZ3JvdW5kID0gJyMyODIyNjInOyAvLyBGYWxsYmFjayB0byBiZyBjb2xvcgogICAgICAgIH0KCiAgICAgICAgLy8gSGVscGVyIHRvIHBhcnNlIGhleCBjb2xvcnMKICAgICAgICBmdW5jdGlvbiBwYXJzZUhleChoZXhTdHIsIGRlZmF1bHRIZXgpIHsKICAgICAgICAgICAgbGV0IGhleCA9IGhleFN0ciB8fCBkZWZhdWx0SGV4OwogICAgICAgICAgICBpZiAoaGV4LnN0YXJ0c1dpdGgoJyMnKSkgaGV4ID0gaGV4LnN1YnN0cmluZygxKTsKICAgICAgICAgICAgaWYgKGhleC5sZW5ndGggPT09IDMpIHsKICAgICAgICAgICAgICAgIGhleCA9IGhleFswXStoZXhbMF0raGV4WzFdK2hleFsxXStoZXhbMl0raGV4WzJdOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IHIgPSBwYXJzZUludChoZXguc3Vic3RyaW5nKDAsIDIpLCAxNikgLyAyNTUuMDsKICAgICAgICAgICAgY29uc3QgZyA9IHBhcnNlSW50KGhleC5zdWJzdHJpbmcoMiwgNCksIDE2KSAvIDI1NS4wOwogICAgICAgICAgICBjb25zdCBiID0gcGFyc2VJbnQoaGV4LnN1YnN0cmluZyg0LCA2KSwgMTYpIC8gMjU1LjA7CiAgICAgICAgICAgIHJldHVybiBbaXNOYU4ocikgPyAwIDogciwgaXNOYU4oZykgPyAwIDogZywgaXNOYU4oYikgPyAwIDogYl07CiAgICAgICAgfQoKICAgICAgICAvLyBQYXJzZSBjb2xvcnMgZnJvbSBVUkwgcGFyYW1zIChNaU9TIFNTT1QgUGFsZXR0ZSkKICAgICAgICBjb25zdCBwYXJhbXMgPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHdpbmRvdy5sb2NhdGlvbi5zZWFyY2gpOwogICAgICAgIGNvbnN0IGJnQ29sb3IgPSBwYXJzZUhleChwYXJhbXMuZ2V0KCdiZycpLCAnMjgyMjYyJyk7CiAgICAgICAgY29uc3QgYWNjZW50Q29sb3IgPSBwYXJzZUhleChwYXJhbXMuZ2V0KCdhY2NlbnQnKSwgJzFBNDA3RicpOwogICAgICAgIGNvbnN0IGN1cnNvckNvbG9yID0gcGFyc2VIZXgocGFyYW1zLmdldCgnY3Vyc29yJyksICdGMzVDMTUnKTsKICAgICAgICBjb25zdCBzdWJ0bGVDb2xvciA9IHBhcnNlSGV4KHBhcmFtcy5nZXQoJ3N1YnRsZScpLCAnQjdDOUQ3Jyk7CiAgICAgICAgY29uc3Qgc3VjY2Vzc0NvbG9yID0gcGFyc2VIZXgocGFyYW1zLmdldCgnc3VjY2VzcycpLCAnM0U3NzY1Jyk7CgogICAgICAgIC8vIFNldCBib2R5IGJhY2tncm91bmQgdG8gbWF0Y2hpbmcgc29saWQgY29sb3IgaW1tZWRpYXRlbHkKICAgICAgICBkb2N1bWVudC5ib2R5LnN0eWxlLmJhY2tncm91bmRDb2xvciA9IHBhcmFtcy5nZXQoJ2JnJykgPyAnIycgKyBwYXJhbXMuZ2V0KCdiZycpIDogJyMyODIyNjInOwoKICAgICAgICAvLyBWZXJ0ZXggc2hhZGVyIHNvdXJjZSAoY292ZXJzIHNjcmVlbiB3aXRoIGEgc2luZ2xlIHF1YWQpCiAgICAgICAgY29uc3QgdnNTb3VyY2UgPSBgCiAgICAgICAgICAgIGF0dHJpYnV0ZSB2ZWMyIGFfcG9zaXRpb247CiAgICAgICAgICAgIHZvaWQgbWFpbigpIHsKICAgICAgICAgICAgICAgIGdsX1Bvc2l0aW9uID0gdmVjNChhX3Bvc2l0aW9uLCAwLjAsIDEuMCk7CiAgICAgICAgICAgIH0KICAgICAgICBgOwoKICAgICAgICAvLyBGcmFnbWVudCBzaGFkZXIgc291cmNlIChwcmVtaXVtIGFuaW1hdGVkIG11bHRpLWNvbG9yIG1lc2ggZ3JhZGllbnQpCiAgICAgICAgY29uc3QgZnNTb3VyY2UgPSBgCiAgICAgICAgICAgIHByZWNpc2lvbiBtZWRpdW1wIGZsb2F0OwogICAgICAgICAgICB1bmlmb3JtIGZsb2F0IHVfdGltZTsKICAgICAgICAgICAgdW5pZm9ybSB2ZWMyIHVfcmVzb2x1dGlvbjsKICAgICAgICAgICAgdW5pZm9ybSB2ZWMzIHVfYmc7CiAgICAgICAgICAgIHVuaWZvcm0gdmVjMyB1X2FjY2VudDsKICAgICAgICAgICAgdW5pZm9ybSB2ZWMzIHVfY3Vyc29yOwogICAgICAgICAgICB1bmlmb3JtIHZlYzMgdV9zdWJ0bGU7CiAgICAgICAgICAgIHVuaWZvcm0gdmVjMyB1X3N1Y2Nlc3M7CgogICAgICAgICAgICB2b2lkIG1haW4oKSB7CiAgICAgICAgICAgICAgICB2ZWMyIHV2ID0gZ2xfRnJhZ0Nvb3JkLnh5IC8gdV9yZXNvbHV0aW9uLnh5OwogICAgICAgICAgICAgICAgZmxvYXQgdCA9IHVfdGltZSAqIDAuMTU7IC8vIFNsb3csIGVsZWdhbnQgbW90aW9uCiAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgIC8vIEZvdXIgb3JiaXRpbmcgbm9kZXMgdXNpbmcgZGlmZmVyZW50IHNwZWVkcyBhbmQgcGF0aHMKICAgICAgICAgICAgICAgIHZlYzIgcDEgPSB2ZWMyKDAuMjUgKyAwLjIwICogc2luKHQgKiAwLjgpLCAwLjMwICsgMC4yMCAqIGNvcyh0ICogMS4yKSk7CiAgICAgICAgICAgICAgICB2ZWMyIHAyID0gdmVjMigwLjc1ICsgMC4xNSAqIGNvcyh0ICogMS4xKSwgMC43MCAtIDAuMjAgKiBzaW4odCAqIDAuNykpOwogICAgICAgICAgICAgICAgdmVjMiBwMyA9IHZlYzIoMC41MCArIDAuMjUgKiBzaW4odCAqIDAuOSksIDAuNDUgKyAwLjI1ICogY29zKHQgKiAxLjApKTsKICAgICAgICAgICAgICAgIHZlYzIgcDQgPSB2ZWMyKDAuMzAgKyAwLjE4ICogY29zKHQgKiAxLjMpLCAwLjgwICsgMC4xNSAqIHNpbih0ICogMC42KSk7CgogICAgICAgICAgICAgICAgZmxvYXQgZDEgPSBkaXN0YW5jZSh1diwgcDEpOwogICAgICAgICAgICAgICAgZmxvYXQgZDIgPSBkaXN0YW5jZSh1diwgcDIpOwogICAgICAgICAgICAgICAgZmxvYXQgZDMgPSBkaXN0YW5jZSh1diwgcDMpOwogICAgICAgICAgICAgICAgZmxvYXQgZDQgPSBkaXN0YW5jZSh1diwgcDQpOwoKICAgICAgICAgICAgICAgIC8vIENvbnZlcnQgZGlzdGFuY2UgdG8gc21vb3RoIHdlaWdodAogICAgICAgICAgICAgICAgZmxvYXQgdzEgPSAxLjAgLSBzbW9vdGhzdGVwKDAuMCwgMC45LCBkMSk7CiAgICAgICAgICAgICAgICBmbG9hdCB3MiA9IDEuMCAtIHNtb290aHN0ZXAoMC4wLCAwLjgsIGQyKTsKICAgICAgICAgICAgICAgIGZsb2F0IHczID0gMS4wIC0gc21vb3Roc3RlcCgwLjAsIDAuODUsIGQzKTsKICAgICAgICAgICAgICAgIGZsb2F0IHc0ID0gMS4wIC0gc21vb3Roc3RlcCgwLjAsIDAuNzUsIGQ0KTsKCiAgICAgICAgICAgICAgICB2ZWMzIGMxID0gdV9hY2NlbnQ7CiAgICAgICAgICAgICAgICB2ZWMzIGMyID0gdV9jdXJzb3I7CiAgICAgICAgICAgICAgICB2ZWMzIGMzID0gdV9zdWJ0bGU7CiAgICAgICAgICAgICAgICB2ZWMzIGM0ID0gdV9zdWNjZXNzOwoKICAgICAgICAgICAgICAgIGZsb2F0IHRvdGFsX3cgPSB3MSArIHcyICsgdzMgKyB3NCArIDAuMDE7CiAgICAgICAgICAgICAgICB2ZWMzIG1peGVkQmxvYnMgPSAodzEgKiBjMSArIHcyICogYzIgKyB3MyAqIGMzICsgdzQgKiBjNCkgLyB0b3RhbF93OwogICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICBmbG9hdCBibGVuZEZhY3RvciA9IHNtb290aHN0ZXAoMC4xLCAwLjgsIG1heChtYXgodzEsIHcyKSwgbWF4KHczLCB3NCkpKTsKICAgICAgICAgICAgICAgIHZlYzMgZmluYWxDb2xvciA9IG1peCh1X2JnLCBtaXhlZEJsb2JzLCBibGVuZEZhY3RvciAqIDAuODUpOwoKICAgICAgICAgICAgICAgIGdsX0ZyYWdDb2xvciA9IHZlYzQoZmluYWxDb2xvciwgMS4wKTsKICAgICAgICAgICAgfQogICAgICAgIGA7CgogICAgICAgIGZ1bmN0aW9uIGNyZWF0ZVNoYWRlcihnbCwgdHlwZSwgc291cmNlKSB7CiAgICAgICAgICAgIGNvbnN0IHNoYWRlciA9IGdsLmNyZWF0ZVNoYWRlcih0eXBlKTsKICAgICAgICAgICAgZ2wuc2hhZGVyU291cmNlKHNoYWRlciwgc291cmNlKTsKICAgICAgICAgICAgZ2wuY29tcGlsZVNoYWRlcihzaGFkZXIpOwogICAgICAgICAgICBpZiAoIWdsLmdldFNoYWRlclBhcmFtZXRlcihzaGFkZXIsIGdsLkNPTVBJTEVfU1RBVFVTKSkgewogICAgICAgICAgICAgICAgY29uc29sZS5lcnJvcihnbC5nZXRTaGFkZXJJbmZvTG9nKHNoYWRlcikpOwogICAgICAgICAgICAgICAgZ2wuZGVsZXRlU2hhZGVyKHNoYWRlcik7CiAgICAgICAgICAgICAgICByZXR1cm4gbnVsbDsKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm4gc2hhZGVyOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgdnMgPSBjcmVhdGVTaGFkZXIoZ2wsIGdsLlZFUlRFWF9TSEFERVIsIHZzU291cmNlKTsKICAgICAgICBjb25zdCBmcyA9IGNyZWF0ZVNoYWRlcihnbCwgZ2wuRlJBR01FTlRfU0hBREVSLCBmc1NvdXJjZSk7CiAgICAgICAgCiAgICAgICAgaWYgKHZzICYmIGZzKSB7CiAgICAgICAgICAgIGNvbnN0IHByb2dyYW0gPSBnbC5jcmVhdGVQcm9ncmFtKCk7CiAgICAgICAgICAgIGdsLmF0dGFjaFNoYWRlcihwcm9ncmFtLCB2cyk7CiAgICAgICAgICAgIGdsLmF0dGFjaFNoYWRlcihwcm9ncmFtLCBmcyk7CiAgICAgICAgICAgIGdsLmxpbmtQcm9ncmFtKHByb2dyYW0pOwoKICAgICAgICAgICAgaWYgKCFnbC5nZXRQcm9ncmFtUGFyYW1ldGVyKHByb2dyYW0sIGdsLkxJTktfU1RBVFVTKSkgewogICAgICAgICAgICAgICAgY29uc29sZS5lcnJvcignU2hhZGVyIHByb2dyYW0gbGlua2luZyBmYWlsZWQnKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgZ2wudXNlUHJvZ3JhbShwcm9ncmFtKTsKCiAgICAgICAgICAgIC8vIFBvc2l0aW9uIGJ1ZmZlcgogICAgICAgICAgICBjb25zdCBwb3NpdGlvbkJ1ZmZlciA9IGdsLmNyZWF0ZUJ1ZmZlcigpOwogICAgICAgICAgICBnbC5iaW5kQnVmZmVyKGdsLkFSUkFZX0JVRkZFUiwgcG9zaXRpb25CdWZmZXIpOwogICAgICAgICAgICBjb25zdCBwb3NpdGlvbnMgPSBbCiAgICAgICAgICAgICAgICAtMSwgLTEsCiAgICAgICAgICAgICAgICAgMSwgLTEsCiAgICAgICAgICAgICAgICAtMSwgIDEsCiAgICAgICAgICAgICAgICAtMSwgIDEsCiAgICAgICAgICAgICAgICAgMSwgLTEsCiAgICAgICAgICAgICAgICAgMSwgIDEsCiAgICAgICAgICAgIF07CiAgICAgICAgICAgIGdsLmJ1ZmZlckRhdGEoZ2wuQVJSQVlfQlVGRkVSLCBuZXcgRmxvYXQzMkFycmF5KHBvc2l0aW9ucyksIGdsLlNUQVRJQ19EUkFXKTsKCiAgICAgICAgICAgIGNvbnN0IHBvc2l0aW9uTG9jYXRpb24gPSBnbC5nZXRBdHRyaWJMb2NhdGlvbihwcm9ncmFtLCAnYV9wb3NpdGlvbicpOwogICAgICAgICAgICBnbC5lbmFibGVWZXJ0ZXhBdHRyaWJBcnJheShwb3NpdGlvbkxvY2F0aW9uKTsKICAgICAgICAgICAgZ2wudmVydGV4QXR0cmliUG9pbnRlcihwb3NpdGlvbkxvY2F0aW9uLCAyLCBnbC5GTE9BVCwgZmFsc2UsIDAsIDApOwoKICAgICAgICAgICAgLy8gVW5pZm9ybSBsb2NhdGlvbnMKICAgICAgICAgICAgY29uc3QgdGltZUxvY2F0aW9uID0gZ2wuZ2V0VW5pZm9ybUxvY2F0aW9uKHByb2dyYW0sICd1X3RpbWUnKTsKICAgICAgICAgICAgY29uc3QgcmVzTG9jYXRpb24gPSBnbC5nZXRVbmlmb3JtTG9jYXRpb24ocHJvZ3JhbSwgJ3VfcmVzb2x1dGlvbicpOwogICAgICAgICAgICBjb25zdCBiZ0xvY2F0aW9uID0gZ2wuZ2V0VW5pZm9ybUxvY2F0aW9uKHByb2dyYW0sICd1X2JnJyk7CiAgICAgICAgICAgIGNvbnN0IGFjY2VudExvY2F0aW9uID0gZ2wuZ2V0VW5pZm9ybUxvY2F0aW9uKHByb2dyYW0sICd1X2FjY2VudCcpOwogICAgICAgICAgICBjb25zdCBjdXJzb3JMb2NhdGlvbiA9IGdsLmdldFVuaWZvcm1Mb2NhdGlvbihwcm9ncmFtLCAndV9jdXJzb3InKTsKICAgICAgICAgICAgY29uc3Qgc3VidGxlTG9jYXRpb24gPSBnbC5nZXRVbmlmb3JtTG9jYXRpb24ocHJvZ3JhbSwgJ3Vfc3VidGxlJyk7CiAgICAgICAgICAgIGNvbnN0IHN1Y2Nlc3NMb2NhdGlvbiA9IGdsLmdldFVuaWZvcm1Mb2NhdGlvbihwcm9ncmFtLCAndV9zdWNjZXNzJyk7CgogICAgICAgICAgICAvLyBTZXQgc3RhdGljIGNvbG9yIHVuaWZvcm1zCiAgICAgICAgICAgIGdsLnVuaWZvcm0zZnYoYmdMb2NhdGlvbiwgYmdDb2xvcik7CiAgICAgICAgICAgIGdsLnVuaWZvcm0zZnYoYWNjZW50TG9jYXRpb24sIGFjY2VudENvbG9yKTsKICAgICAgICAgICAgZ2wudW5pZm9ybTNmdihjdXJzb3JMb2NhdGlvbiwgY3Vyc29yQ29sb3IpOwogICAgICAgICAgICBnbC51bmlmb3JtM2Z2KHN1YnRsZUxvY2F0aW9uLCBzdWJ0bGVDb2xvcik7CiAgICAgICAgICAgIGdsLnVuaWZvcm0zZnYoc3VjY2Vzc0xvY2F0aW9uLCBzdWNjZXNzQ29sb3IpOwoKICAgICAgICAgICAgZnVuY3Rpb24gcmVzaXplKCkgewogICAgICAgICAgICAgICAgY2FudmFzLndpZHRoID0gd2luZG93LmlubmVyV2lkdGg7CiAgICAgICAgICAgICAgICBjYW52YXMuaGVpZ2h0ID0gd2luZG93LmlubmVySGVpZ2h0OwogICAgICAgICAgICAgICAgZ2wudmlld3BvcnQoMCwgMCwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0KTsKICAgICAgICAgICAgICAgIGdsLnVuaWZvcm0yZihyZXNMb2NhdGlvbiwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0KTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIHJlc2l6ZSk7CiAgICAgICAgICAgIHJlc2l6ZSgpOwoKICAgICAgICAgICAgbGV0IHN0YXJ0VGltZSA9IERhdGUubm93KCk7CiAgICAgICAgICAgIGZ1bmN0aW9uIHJlbmRlcigpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGVsYXBzZWQgPSAoRGF0ZS5ub3coKSAtIHN0YXJ0VGltZSkgLyAxMDAwLjA7CiAgICAgICAgICAgICAgICBnbC51bmlmb3JtMWYodGltZUxvY2F0aW9uLCBlbGFwc2VkKTsKICAgICAgICAgICAgICAgIGdsLmRyYXdBcnJheXMoZ2wuVFJJQU5HTEVTLCAwLCA2KTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShyZW5kZXIpOwogICAgICAgICAgICB9CgogICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUocmVuZGVyKTsKICAgICAgICB9CiAgICA8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg=='
}

function Get-MiOSLivingWallpaperCsB64 {
    return 'dXNpbmcgU3lzdGVtOwp1c2luZyBTeXN0ZW0uRHJhd2luZzsKdXNpbmcgU3lzdGVtLklPOwp1c2luZyBTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXM7CnVzaW5nIFN5c3RlbS5UZXh0Owp1c2luZyBTeXN0ZW0uVGhyZWFkaW5nOwp1c2luZyBTeXN0ZW0uV2luZG93cy5Gb3JtczsKdXNpbmcgTWljcm9zb2Z0LldlYi5XZWJWaWV3Mi5Db3JlOwp1c2luZyBNaWNyb3NvZnQuV2ViLldlYlZpZXcyLldpbkZvcm1zOwoKbmFtZXNwYWNlIE1pT1NXYWxscGFwZXIKewogICAgLy8vIDxzdW1tYXJ5PgogICAgLy8vIE1pT1MgTGl2aW5nIFdhbGxwYXBlciBIb3N0CiAgICAvLy8gVXNlcyBXZWJWaWV3MiBXaW5Gb3JtcyBjb250cm9sIGNyZWF0ZWQgbmF0aXZlbHkgYXMgYSBkaXJlY3QgY2hpbGQgb2YgdGhlCiAgICAvLy8gV2luZG93cyBXb3JrZXJXIGJhY2tncm91bmQgbGF5ZXIsIGZhbGxpbmcgYmFjayB0byBQcm9nbWFuIGlmIFdvcmtlclcKICAgIC8vLyBjYW5ub3QgYmUgc3Bhd25lZC4gTm8gU2V0UGFyZW50IGJsb2NrIC0gdGhlIERQSSBjb250ZXh0IGlzIG1hdGNoZWQgZHluYW1pY2FsbHkKICAgIC8vLyB0byB0aGUgcGFyZW50IGhhbmRsZSBiZWZvcmUgU2V0UGFyZW50LCBhbmQgRm9ybSBpcyBjcmVhdGVkIGFzIFRvcExldmVsID0gZmFsc2UuCiAgICAvLy8gPC9zdW1tYXJ5PgogICAgc3RhdGljIGNsYXNzIFByb2dyYW0KICAgIHsKICAgICAgICAvLyDilIDilIAgV2luMzIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIEludFB0ciBGaW5kV2luZG93KHN0cmluZyBscENsYXNzTmFtZSwgc3RyaW5nIGxwV2luZG93TmFtZSk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIEludFB0ciBTZW5kTWVzc2FnZVRpbWVvdXQoSW50UHRyIGhXbmQsIHVpbnQgTXNnLCBJbnRQdHIgd1BhcmFtLAogICAgICAgICAgICBJbnRQdHIgbFBhcmFtLCB1aW50IGZ1RmxhZ3MsIHVpbnQgdVRpbWVvdXQsIG91dCBJbnRQdHIgbHBkd1Jlc3VsdCk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiKV0KICAgICAgICBbcmV0dXJuOiBNYXJzaGFsQXMoVW5tYW5hZ2VkVHlwZS5Cb29sKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGJvb2wgRW51bVdpbmRvd3MoRW51bVdpbmRvd3NQcm9jIGxwRW51bUZ1bmMsIEludFB0ciBsUGFyYW0pOwogICAgICAgIGRlbGVnYXRlIGJvb2wgRW51bVdpbmRvd3NQcm9jKEludFB0ciBod25kLCBJbnRQdHIgbFBhcmFtKTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gSW50UHRyIEZpbmRXaW5kb3dFeChJbnRQdHIgaHduZFBhcmVudCwgSW50UHRyIGh3bmRDaGlsZEFmdGVyLAogICAgICAgICAgICBzdHJpbmcgbHBzekNsYXNzLCBzdHJpbmcgbHBzeldpbmRvdyk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGludCBHZXRTeXN0ZW1NZXRyaWNzKGludCBuSW5kZXgpOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIiwgQ2hhclNldCA9IENoYXJTZXQuQXV0byldCiAgICAgICAgc3RhdGljIGV4dGVybiBpbnQgR2V0Q2xhc3NOYW1lKEludFB0ciBoV25kLCBTdHJpbmdCdWlsZGVyIGxwQ2xhc3NOYW1lLCBpbnQgbk1heENvdW50KTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gSW50UHRyIE9wZW5JbnB1dERlc2t0b3AodWludCBkd0ZsYWdzLCBib29sIGZJbmhlcml0LCB1aW50IGR3RGVzaXJlZEFjY2Vzcyk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGJvb2wgU2V0VGhyZWFkRGVza3RvcChJbnRQdHIgaERlc2t0b3ApOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBJbnRQdHIgU2V0VGhyZWFkRHBpQXdhcmVuZXNzQ29udGV4dChJbnRQdHIgZHBpQ29udGV4dCk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGJvb2wgU2V0UGFyZW50KEludFB0ciBoV25kQ2hpbGQsIEludFB0ciBoV25kTmV3UGFyZW50KTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBTZXRXaW5kb3dQb3MoSW50UHRyIGhXbmQsIEludFB0ciBoV25kSW5zZXJ0QWZ0ZXIsCiAgICAgICAgICAgIGludCBYLCBpbnQgWSwgaW50IGN4LCBpbnQgY3ksIHVpbnQgdUZsYWdzKTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIsIEVudHJ5UG9pbnQgPSAiR2V0V2luZG93TG9uZ1ciLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGludCBHZXRXaW5kb3dMb25nMzIoSW50UHRyIGhXbmQsIGludCBuSW5kZXgpOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIiwgRW50cnlQb2ludCA9ICJHZXRXaW5kb3dMb25nUHRyVyIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gSW50UHRyIEdldFdpbmRvd0xvbmdQdHI2NChJbnRQdHIgaFduZCwgaW50IG5JbmRleCk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBFbnRyeVBvaW50ID0gIlNldFdpbmRvd0xvbmdXIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBpbnQgU2V0V2luZG93TG9uZzMyKEludFB0ciBoV25kLCBpbnQgbkluZGV4LCBpbnQgZHdOZXdMb25nKTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIsIEVudHJ5UG9pbnQgPSAiU2V0V2luZG93TG9uZ1B0clciLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIEludFB0ciBTZXRXaW5kb3dMb25nUHRyNjQoSW50UHRyIGhXbmQsIGludCBuSW5kZXgsIEludFB0ciBkd05ld0xvbmcpOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIildCiAgICAgICAgc3RhdGljIGV4dGVybiBJbnRQdHIgR2V0V2luZG93RHBpQXdhcmVuZXNzQ29udGV4dChJbnRQdHIgaHduZCk7CgogICAgICAgIC8vIOKUgOKUgCBDb25zdGFudHMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgIGNvbnN0IGludCBTTV9DWFZJUlRVQUxTQ1JFRU4gPSA3ODsKICAgICAgICBjb25zdCBpbnQgU01fQ1lWSVJUVUFMU0NSRUVOID0gNzk7CiAgICAgICAgY29uc3QgaW50IFNNX1hWSVJUVUFMU0NSRUVOID0gNzY7CiAgICAgICAgY29uc3QgaW50IFNNX1lWSVJUVUFMU0NSRUVOID0gNzc7CiAgICAgICAgY29uc3QgaW50IEdXTF9TVFlMRSA9IC0xNjsKICAgICAgICBjb25zdCBpbnQgR1dMX0VYU1RZTEUgPSAtMjA7CiAgICAgICAgY29uc3QgbG9uZyBXU19DSElMRCA9IDB4NDAwMDAwMDA7CiAgICAgICAgY29uc3QgbG9uZyBXU19QT1BVUCA9IHVuY2hlY2tlZCgobG9uZykweDgwMDAwMDAwKTsKICAgICAgICBjb25zdCBsb25nIFdTX0NBUFRJT04gPSAweDAwQzAwMDAwOwogICAgICAgIGNvbnN0IGxvbmcgV1NfVEhJQ0tGUkFNRSA9IDB4MDAwNDAwMDA7CiAgICAgICAgY29uc3QgaW50IFdTX0VYX1RPT0xXSU5ET1cgPSAweDAwMDAwMDgwOwogICAgICAgIGNvbnN0IGludCBXU19FWF9BUFBXSU5ET1cgPSAweDAwMDQwMDAwOwogICAgICAgIGNvbnN0IGludCBXU19FWF9OT0FDVElWQVRFID0gMHgwODAwMDAwMDsKICAgICAgICBjb25zdCB1aW50IERFU0tUT1BfQUxMX0FDQ0VTUyA9IDB4MUZGOwogICAgICAgIGNvbnN0IHVpbnQgU1dQX05PU0laRSA9IDB4MDAwMTsKICAgICAgICBjb25zdCB1aW50IFNXUF9OT01PVkUgPSAweDAwMDI7CiAgICAgICAgY29uc3QgdWludCBTV1BfTk9BQ1RJVkFURSA9IDB4MDAxMDsKICAgICAgICBjb25zdCB1aW50IFNXUF9GUkFNRUNIQU5HRUQgPSAweDAwMjA7CiAgICAgICAgY29uc3QgdWludCBTV1BfU0hPV1dJTkRPVyA9IDB4MDA0MDsKCiAgICAgICAgLy8g4pSA4pSAIExvZ2dpbmcg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgIHN0YXRpYyBzdHJpbmcgX2xvZ1BhdGggPSBAIkM6XFdpbmRvd3NcV2ViXE1pT1NcbWlvc193YWxscGFwZXIubG9nIjsKICAgICAgICBzdGF0aWMgdm9pZCBMb2coc3RyaW5nIG1zZykKICAgICAgICB7CiAgICAgICAgICAgIHRyeSB7IEZpbGUuQXBwZW5kQWxsVGV4dChfbG9nUGF0aCwgIlsiICsgRGF0ZVRpbWUuTm93LlRvU3RyaW5nKCJ5eXl5LU1NLWRkIEhIOm1tOnNzIikgKyAiXSAiICsgbXNnICsgRW52aXJvbm1lbnQuTmV3TGluZSk7IH0KICAgICAgICAgICAgY2F0Y2ggeyB9CiAgICAgICAgICAgIENvbnNvbGUuV3JpdGVMaW5lKG1zZyk7CiAgICAgICAgfQoKICAgICAgICAvLyBIZWxwZXIgbWV0aG9kcyBmb3IgMzIvNjQgYml0IGNvbXBhdGliaWxpdHkKICAgICAgICBwdWJsaWMgc3RhdGljIEludFB0ciBHZXRXaW5kb3dMb25nKEludFB0ciBoV25kLCBpbnQgbkluZGV4KQogICAgICAgIHsKICAgICAgICAgICAgaWYgKEludFB0ci5TaXplID09IDgpCiAgICAgICAgICAgICAgICByZXR1cm4gR2V0V2luZG93TG9uZ1B0cjY0KGhXbmQsIG5JbmRleCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHJldHVybiBuZXcgSW50UHRyKEdldFdpbmRvd0xvbmczMihoV25kLCBuSW5kZXgpKTsKICAgICAgICB9CgogICAgICAgIHB1YmxpYyBzdGF0aWMgSW50UHRyIFNldFdpbmRvd0xvbmcoSW50UHRyIGhXbmQsIGludCBuSW5kZXgsIEludFB0ciBkd05ld0xvbmcpCiAgICAgICAgewogICAgICAgICAgICBpZiAoSW50UHRyLlNpemUgPT0gOCkKICAgICAgICAgICAgICAgIHJldHVybiBTZXRXaW5kb3dMb25nUHRyNjQoaFduZCwgbkluZGV4LCBkd05ld0xvbmcpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICByZXR1cm4gbmV3IEludFB0cihTZXRXaW5kb3dMb25nMzIoaFduZCwgbkluZGV4LCAoaW50KWR3TmV3TG9uZy5Ub0ludDY0KCkpKTsKICAgICAgICB9CgogICAgICAgIHN0YXRpYyB2b2lkIEVuc3VyZUlncHVQcmVmZXJlbmNlKCkKICAgICAgICB7CiAgICAgICAgICAgIHRyeQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICB1c2luZyAodmFyIGRpcmVjdFhLZXkgPSBNaWNyb3NvZnQuV2luMzIuUmVnaXN0cnkuQ3VycmVudFVzZXIuQ3JlYXRlU3ViS2V5KEAiU29mdHdhcmVcTWljcm9zb2Z0XERpcmVjdFgiKSkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBpZiAoZGlyZWN0WEtleSAhPSBudWxsKQogICAgICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAgICAgdXNpbmcgKHZhciBncHVLZXkgPSBkaXJlY3RYS2V5LkNyZWF0ZVN1YktleSgiVXNlckdwdVByZWZlcmVuY2VzIikpCiAgICAgICAgICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChncHVLZXkgIT0gbnVsbCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdHJpbmcgZXhlUGF0aCA9IFN5c3RlbS5SZWZsZWN0aW9uLkFzc2VtYmx5LkdldEV4ZWN1dGluZ0Fzc2VtYmx5KCkuTG9jYXRpb247CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLy8gR3B1UHJlZmVyZW5jZT0xOyBpcyBQb3dlciBTYXZpbmcgKGlHUFUpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZ3B1S2V5LlNldFZhbHVlKGV4ZVBhdGgsICJHcHVQcmVmZXJlbmNlPTE7IiwgTWljcm9zb2Z0LldpbjMyLlJlZ2lzdHJ5VmFsdWVLaW5kLlN0cmluZyk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTG9nKCJHUFUgUHJlZmVyZW5jZSBzZXQgdG8gUG93ZXIgU2F2aW5nIChpR1BVKSBmb3I6ICIgKyBleGVQYXRoKTsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBMb2coIkVuc3VyZUlncHVQcmVmZXJlbmNlIGVycm9yOiAiICsgZXguTWVzc2FnZSk7CiAgICAgICAgICAgIH0KICAgICAgICB9CgogICAgICAgIC8vIOKUgOKUgCBNYWluIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKICAgICAgICBbU1RBVGhyZWFkXQogICAgICAgIHN0YXRpYyB2b2lkIE1haW4oc3RyaW5nW10gYXJncykKICAgICAgICB7CiAgICAgICAgICAgIHRyeQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBNYWluSW5uZXIoYXJncyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY2F0Y2ggKEV4Y2VwdGlvbiBleCkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgdHJ5IHsgRmlsZS5Xcml0ZUFsbFRleHQoQCJDOlxXaW5kb3dzXFdlYlxNaU9TXGNyYXNoLmxvZyIsIGV4LlRvU3RyaW5nKCkpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICB9CgogICAgICAgIHN0YXRpYyB2b2lkIE1haW5Jbm5lcihzdHJpbmdbXSBhcmdzKQogICAgICAgIHsKICAgICAgICAgICAgQXBwbGljYXRpb24uRW5hYmxlVmlzdWFsU3R5bGVzKCk7CiAgICAgICAgICAgIEFwcGxpY2F0aW9uLlNldENvbXBhdGlibGVUZXh0UmVuZGVyaW5nRGVmYXVsdChmYWxzZSk7CgogICAgICAgICAgICAvLyBFbnN1cmUgd2UgcnVuIG9uIHRoZSBpR1BVIChQb3dlciBTYXZpbmcpCiAgICAgICAgICAgIEVuc3VyZUlncHVQcmVmZXJlbmNlKCk7CgogICAgICAgICAgICBzdHJpbmcgdXJsID0gYXJncy5MZW5ndGggPiAwID8gYXJnc1swXSA6ICJmaWxlOi8vL0M6L1dpbmRvd3MvV2ViL01pT1MvbGl2aW5nLXdhbGxwYXBlci5odG1sIjsKCiAgICAgICAgICAgIExvZygiTWlPUyBMaXZpbmcgV2FsbHBhcGVyIHN0YXJ0aW5nLiBVUkw9IiArIHVybCk7CgogICAgICAgICAgICAvLyBTZXQgRFBJIGF3YXJlbmVzcyBjb250ZXh0IHRvIFBlci1Nb25pdG9yLVYyIGJlZm9yZSBhbnkgd2luZG93IG9wcwogICAgICAgICAgICB0cnkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgU2V0VGhyZWFkRHBpQXdhcmVuZXNzQ29udGV4dChuZXcgSW50UHRyKC00KSk7IC8vIERQSV9BV0FSRU5FU1NfQ09OVEVYVF9QRVJfTU9OSVRPUl9BV0FSRV9WMgogICAgICAgICAgICAgICAgTG9nKCJEUEkgYXdhcmVuZXNzOiBQZXItTW9uaXRvci1WMiIpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNhdGNoIChFeGNlcHRpb24gZXgpIHsgTG9nKCJEUEkgYXdhcmVuZXNzIHNldCBmYWlsZWQ6ICIgKyBleC5NZXNzYWdlKTsgfQoKICAgICAgICAgICAgLy8gQmluZCB0byB0aGUgaW50ZXJhY3RpdmUgaW5wdXQgZGVza3RvcCBCRUZPUkUgYW55IHdpbmRvdyBsb29rdXAKICAgICAgICAgICAgZm9yIChpbnQgYXR0ZW1wdCA9IDA7IGF0dGVtcHQgPCAzOyBhdHRlbXB0KyspCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHRyeQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIEludFB0ciBoRGVzayA9IE9wZW5JbnB1dERlc2t0b3AoMCwgdHJ1ZSwgREVTS1RPUF9BTExfQUNDRVNTKTsKICAgICAgICAgICAgICAgICAgICBpZiAoaERlc2sgIT0gSW50UHRyLlplcm8pCiAgICAgICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICAgICBTZXRUaHJlYWREZXNrdG9wKGhEZXNrKTsKICAgICAgICAgICAgICAgICAgICAgICAgTG9nKCJUaHJlYWQgZGVza3RvcDogaW5wdXQgZGVza3RvcCAoYXR0ZW1wdCAiICsgKGF0dGVtcHQgKyAxKSArICIpIik7CiAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICAgICBMb2coIk9wZW5JbnB1dERlc2t0b3AgcmV0dXJuZWQgbnVsbCwgcmV0cnlpbmcuLi4gZXJyPSIgKyBNYXJzaGFsLkdldExhc3RXaW4zMkVycm9yKCkpOwogICAgICAgICAgICAgICAgICAgICAgICBTeXN0ZW0uVGhyZWFkaW5nLlRocmVhZC5TbGVlcCgxMDAwKTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KSB7IExvZygiU2V0VGhyZWFkRGVza3RvcCBmYWlsZWQ6ICIgKyBleC5NZXNzYWdlKTsgfQogICAgICAgICAgICB9CgogICAgICAgICAgICAvLyDilIDilIAgMS4gU3Bhd24gdGhlIFdvcmtlclcgbGF5ZXIgYmVoaW5kIGRlc2t0b3AgaWNvbnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgICAgICBJbnRQdHIgcHJvZ21hbiA9IEludFB0ci5aZXJvOwogICAgICAgICAgICBmb3IgKGludCBpID0gMDsgaSA8IDE1OyBpKyspCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHByb2dtYW4gPSBGaW5kV2luZG93KCJQcm9nbWFuIiwgbnVsbCk7CiAgICAgICAgICAgICAgICBpZiAocHJvZ21hbiAhPSBJbnRQdHIuWmVybykgYnJlYWs7CiAgICAgICAgICAgICAgICBMb2coIlByb2dtYW4gbm90IHlldCB2aXNpYmxlLCB3YWl0aW5nLi4uICgiICsgaSArICIpIik7CiAgICAgICAgICAgICAgICBTeXN0ZW0uVGhyZWFkaW5nLlRocmVhZC5TbGVlcCgxMDAwKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBMb2coIlByb2dtYW4gSFdORDogIiArIHByb2dtYW4pOwoKICAgICAgICAgICAgaWYgKHByb2dtYW4gPT0gSW50UHRyLlplcm8pCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIExvZygiRkFUQUw6IFByb2dtYW4gbm90IGZvdW5kIGFmdGVyIHJldHJpZXMuIEFib3J0aW5nLiIpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CgogICAgICAgICAgICAvLyBTZW5kaW5nIDB4MDUyQyB0byBQcm9nbWFuIHRyaWdnZXJzIEV4cGxvcmVyIHRvIGNyZWF0ZSB0aGUgV29ya2VyVyBzdWJsYXllcgogICAgICAgICAgICBJbnRQdHIgcmVzdWx0OwogICAgICAgICAgICBTZW5kTWVzc2FnZVRpbWVvdXQocHJvZ21hbiwgMHgwNTJDLCBuZXcgSW50UHRyKDB4MEQpLCBuZXcgSW50UHRyKDEpLCAwLCAyMDAwLCBvdXQgcmVzdWx0KTsKICAgICAgICAgICAgU3lzdGVtLlRocmVhZGluZy5UaHJlYWQuU2xlZXAoNTAwKTsgLy8gR2l2ZSBFeHBsb3JlciB0aW1lIHRvIHNwbGl0CgogICAgICAgICAgICAvLyDilIDilIAgMi4gRmluZCB0aGUgV29ya2VyVyB0aGF0IHNpdHMgQkVISU5EIHRoZSBkZXNrdG9wIGljb24gbGF5ZXIg4pSACiAgICAgICAgICAgIEludFB0ciB3YWxscGFwZXJXb3JrZXJXID0gSW50UHRyLlplcm87CgogICAgICAgICAgICAvLyBGaXJzdCBjaGVjayBpZiB0aGVyZSBpcyBhIGNoaWxkIFdvcmtlclcgZGlyZWN0bHkgdW5kZXIgUHJvZ21hbiAoY29tbW9uIGluIG5ld2VyL21vZGlmaWVkIHNoZWxscykKICAgICAgICAgICAgd2FsbHBhcGVyV29ya2VyVyA9IEZpbmRXaW5kb3dFeChwcm9nbWFuLCBJbnRQdHIuWmVybywgIldvcmtlclciLCBudWxsKTsKICAgICAgICAgICAgTG9nKCJDaGlsZCBXb3JrZXJXIHVuZGVyIFByb2dtYW46ICIgKyB3YWxscGFwZXJXb3JrZXJXKTsKCiAgICAgICAgICAgIGlmICh3YWxscGFwZXJXb3JrZXJXID09IEludFB0ci5aZXJvKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAvLyBJZiBub3QgdW5kZXIgUHJvZ21hbiwgbG9vayBmb3IgdG9wLWxldmVsIFdvcmtlclcgd2luZG93cwogICAgICAgICAgICAgICAgSW50UHRyIHNoZWxsV29ya2VyVyA9IEludFB0ci5aZXJvOwogICAgICAgICAgICAgICAgRW51bVdpbmRvd3MoKGh3bmQsIF8pID0+CiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgU3RyaW5nQnVpbGRlciBzYiA9IG5ldyBTdHJpbmdCdWlsZGVyKDI1Nik7CiAgICAgICAgICAgICAgICAgICAgR2V0Q2xhc3NOYW1lKGh3bmQsIHNiLCAyNTYpOwogICAgICAgICAgICAgICAgICAgIGlmIChzYi5Ub1N0cmluZygpID09ICJXb3JrZXJXIikKICAgICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICAgIEludFB0ciBkZWZWaWV3ID0gRmluZFdpbmRvd0V4KGh3bmQsIEludFB0ci5aZXJvLCAiU0hFTExETExfRGVmVmlldyIsIG51bGwpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoZGVmVmlldyAhPSBJbnRQdHIuWmVybykKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNoZWxsV29ya2VyVyA9IGh3bmQ7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgICAgICAgICAgfSwgSW50UHRyLlplcm8pOwogICAgICAgICAgICAgICAgTG9nKCJTaGVsbCBXb3JrZXJXIChpY29uIGxheWVyKTogIiArIHNoZWxsV29ya2VyVyk7CgogICAgICAgICAgICAgICAgaWYgKHNoZWxsV29ya2VyVyAhPSBJbnRQdHIuWmVybykKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICB3YWxscGFwZXJXb3JrZXJXID0gRmluZFdpbmRvd0V4KEludFB0ci5aZXJvLCBzaGVsbFdvcmtlclcsICJXb3JrZXJXIiwgbnVsbCk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIC8vIElmIHN0aWxsIG5vIHdhbGxwYXBlcldvcmtlclcgd2FzIGZvdW5kLCBmYWxsIGJhY2sgdG8gUHJvZ21hbiBpdHNlbGYKICAgICAgICAgICAgaWYgKHdhbGxwYXBlcldvcmtlclcgPT0gSW50UHRyLlplcm8pCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIExvZygiV2FsbHBhcGVyIFdvcmtlclcgbm90IGZvdW5kLCBmYWxsaW5nIGJhY2sgdG8gUHJvZ21hbiBhcyBwYXJlbnQuIik7CiAgICAgICAgICAgICAgICB3YWxscGFwZXJXb3JrZXJXID0gcHJvZ21hbjsKICAgICAgICAgICAgfQogICAgICAgICAgICBMb2coIldhbGxwYXBlciBsYXllciBIV05EICh0YXJnZXQgcGFyZW50KTogIiArIHdhbGxwYXBlcldvcmtlclcpOwoKICAgICAgICAgICAgLy8g4pSA4pSAIDMuIENyZWF0ZSBhIGhpZGRlbiBob3N0IEZvcm0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgICAgICAvLyBUaGUgRm9ybSBpcyBpbnZpc2libGUgYW5kIHBhcmVudGVkIHRvIFdvcmtlclcvUHJvZ21hbiDigJQgaXQgaXMgdGhlIFdpbjMyIG93bmVyCiAgICAgICAgICAgIC8vIG9mIHRoZSBXZWJWaWV3MiBjb250cm9sLiBXZSBuZXZlciBzaG93IGl0IG9uIHNjcmVlbiBhcyBhIHN0YW5kYWxvbmUgd2luZG93LgogICAgICAgICAgICBXYWxscGFwZXJIb3N0Rm9ybSBmb3JtID0gbmV3IFdhbGxwYXBlckhvc3RGb3JtKHVybCwgd2FsbHBhcGVyV29ya2VyVyk7CgogICAgICAgICAgICBMb2coIlJ1bm5pbmcgYXBwbGljYXRpb24gbWVzc2FnZSBsb29wLi4uIik7CiAgICAgICAgICAgIEFwcGxpY2F0aW9uLlJ1bihmb3JtKTsKICAgICAgICB9CiAgICB9CgogICAgLy8vIDxzdW1tYXJ5PgogICAgLy8vIFdpbkZvcm1zIEZvcm0gdGhhdCBob3N0cyB0aGUgV2ViVmlldzIgY29udHJvbC4KICAgIC8vLyBPbiBMb2FkLCBpdCByZS1wYXJlbnRzIGl0c2VsZiBpbnRvIHRoZSBkZXNrdG9wIGxheWVyLgogICAgLy8vIDwvc3VtbWFyeT4KICAgIGNsYXNzIFdhbGxwYXBlckhvc3RGb3JtIDogRm9ybQogICAgewogICAgICAgIHJlYWRvbmx5IHN0cmluZyBfdXJsOwogICAgICAgIHJlYWRvbmx5IEludFB0ciBfcGFyZW50SHduZDsKICAgICAgICBXZWJWaWV3MiBfd3Y7CgogICAgICAgIC8vIFdpbjMyIGltcG9ydHMgZm9yIGZvcm0gcGFyZW50aW5nCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBTZXRQYXJlbnQoSW50UHRyIGhXbmRDaGlsZCwgSW50UHRyIGhXbmROZXdQYXJlbnQpOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyMzIuZGxsIiwgRW50cnlQb2ludCA9ICJTZXRXaW5kb3dMb25nUHRyVyIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gSW50UHRyIFNldFdpbmRvd0xvbmdQdHI2NChJbnRQdHIgaFduZCwgaW50IG5JbmRleCwgSW50UHRyIGR3TmV3TG9uZyk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBFbnRyeVBvaW50ID0gIkdldFdpbmRvd0xvbmdQdHJXIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBJbnRQdHIgR2V0V2luZG93TG9uZ1B0cjY0KEludFB0ciBoV25kLCBpbnQgbkluZGV4KTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBTZXRXaW5kb3dQb3MoSW50UHRyIGhXbmQsIEludFB0ciBoV25kSW5zZXJ0QWZ0ZXIsCiAgICAgICAgICAgIGludCBYLCBpbnQgWSwgaW50IGN4LCBpbnQgY3ksIHVpbnQgdUZsYWdzKTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIpXQogICAgICAgIHN0YXRpYyBleHRlcm4gaW50IEdldFN5c3RlbU1ldHJpY3MoaW50IG5JbmRleCk7CgogICAgICAgIFtEbGxJbXBvcnQoInVzZXIzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIEludFB0ciBTZXRUaHJlYWREcGlBd2FyZW5lc3NDb250ZXh0KEludFB0ciBkcGlDb250ZXh0KTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcjMyLmRsbCIpXQogICAgICAgIHN0YXRpYyBleHRlcm4gSW50UHRyIEdldFdpbmRvd0RwaUF3YXJlbmVzc0NvbnRleHQoSW50UHRyIGh3bmQpOwoKICAgICAgICBjb25zdCBpbnQgR1dMX1NUWUxFID0gLTE2OwogICAgICAgIGNvbnN0IGludCBHV0xfRVhTVFlMRSA9IC0yMDsKICAgICAgICBjb25zdCBsb25nIFdTX0NISUxEID0gMHg0MDAwMDAwMDsKICAgICAgICBjb25zdCBsb25nIFdTX1BPUFVQID0gdW5jaGVja2VkKChsb25nKTB4ODAwMDAwMDApOwogICAgICAgIGNvbnN0IGxvbmcgV1NfQ0FQVElPTiA9IDB4MDBDMDAwMDA7CiAgICAgICAgY29uc3QgbG9uZyBXU19USElDS0ZSQU1FID0gMHgwMDA0MDAwMDsKICAgICAgICBjb25zdCBpbnQgV1NfRVhfVE9PTFdJTkRPVyA9IDB4MDAwMDAwODA7CiAgICAgICAgY29uc3QgaW50IFdTX0VYX0FQUFdJTkRPVyA9IDB4MDAwNDAwMDA7CiAgICAgICAgY29uc3QgaW50IFdTX0VYX05PQUNUSVZBVEUgPSAweDA4MDAwMDAwOwogICAgICAgIGNvbnN0IHVpbnQgU1dQX0ZSQU1FQ0hBTkdFRCA9IDB4MDAyMDsKICAgICAgICBjb25zdCB1aW50IFNXUF9TSE9XV0lORE9XID0gMHgwMDQwOwogICAgICAgIGNvbnN0IHVpbnQgU1dQX05PQUNUSVZBVEUgPSAweDAwMTA7CgogICAgICAgIHN0YXRpYyBzdHJpbmcgX2xvZ1BhdGggPSBAIkM6XFdpbmRvd3NcV2ViXE1pT1NcbWlvc193YWxscGFwZXIubG9nIjsKICAgICAgICBzdGF0aWMgdm9pZCBMb2coc3RyaW5nIG1zZykKICAgICAgICB7CiAgICAgICAgICAgIHRyeSB7IEZpbGUuQXBwZW5kQWxsVGV4dChfbG9nUGF0aCwgIlsiICsgRGF0ZVRpbWUuTm93LlRvU3RyaW5nKCJ5eXl5LU1NLWRkIEhIOm1tOnNzIikgKyAiXSAiICsgbXNnICsgRW52aXJvbm1lbnQuTmV3TGluZSk7IH0KICAgICAgICAgICAgY2F0Y2ggeyB9CiAgICAgICAgICAgIENvbnNvbGUuV3JpdGVMaW5lKG1zZyk7CiAgICAgICAgfQoKICAgICAgICBwdWJsaWMgV2FsbHBhcGVySG9zdEZvcm0oc3RyaW5nIHVybCwgSW50UHRyIHBhcmVudEh3bmQpCiAgICAgICAgewogICAgICAgICAgICBfdXJsID0gdXJsOwogICAgICAgICAgICBfcGFyZW50SHduZCA9IHBhcmVudEh3bmQ7CgogICAgICAgICAgICAvLyBNYWtlIHRoZSBmb3JtIGEgY2hpbGQgd2luZG93IGZyb20gdGhlIHZlcnkgYmVnaW5uaW5nIHRvIGF2b2lkIFNldFBhcmVudCBlcnJvcnMKICAgICAgICAgICAgVG9wTGV2ZWwgPSBmYWxzZTsKICAgICAgICAgICAgRm9ybUJvcmRlclN0eWxlID0gRm9ybUJvcmRlclN0eWxlLk5vbmU7CiAgICAgICAgICAgIFNob3dJblRhc2tiYXIgPSBmYWxzZTsKCiAgICAgICAgICAgIC8vIFNpemUgdG8gY292ZXIgdGhlIGZ1bGwgdmlydHVhbCBzY3JlZW4KICAgICAgICAgICAgVXBkYXRlQm91bmRzSW50ZXJuYWwoKTsKCiAgICAgICAgICAgIC8vIFN1YnNjcmliZSB0byBkaXNwbGF5IHNldHRpbmdzIGNoYW5nZSBldmVudCB0byBhdXRvLXJlcG9zaXRpb24gb24gcmVtb3RlL2Rpc3BsYXkgY29ubmVjdAogICAgICAgICAgICBNaWNyb3NvZnQuV2luMzIuU3lzdGVtRXZlbnRzLkRpc3BsYXlTZXR0aW5nc0NoYW5nZWQgKz0gU3lzdGVtRXZlbnRzX0Rpc3BsYXlTZXR0aW5nc0NoYW5nZWQ7CiAgICAgICAgfQoKICAgICAgICBwcml2YXRlIHZvaWQgU3lzdGVtRXZlbnRzX0Rpc3BsYXlTZXR0aW5nc0NoYW5nZWQob2JqZWN0IHNlbmRlciwgRXZlbnRBcmdzIGUpCiAgICAgICAgewogICAgICAgICAgICBMb2coIkRpc3BsYXkgc2V0dGluZ3MgY2hhbmdlZCBldmVudCByZWNlaXZlZC4gUmUtYWxpZ25pbmcgd2FsbHBhcGVyIGJvdW5kcy4iKTsKICAgICAgICAgICAgaWYgKEludm9rZVJlcXVpcmVkKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBCZWdpbkludm9rZShuZXcgQWN0aW9uKFVwZGF0ZUJvdW5kc0ludGVybmFsKSk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZWxzZQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBVcGRhdGVCb3VuZHNJbnRlcm5hbCgpOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBwcml2YXRlIHZvaWQgVXBkYXRlQm91bmRzSW50ZXJuYWwoKQogICAgICAgIHsKICAgICAgICAgICAgdHJ5CiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIGludCB2eCA9IEdldFN5c3RlbU1ldHJpY3MoNzYpOyAgLy8gU01fWFZJUlRVQUxTQ1JFRU4KICAgICAgICAgICAgICAgIGludCB2eSA9IEdldFN5c3RlbU1ldHJpY3MoNzcpOyAgLy8gU01fWVZJUlRVQUxTQ1JFRU4KICAgICAgICAgICAgICAgIGludCB2Y3ggPSBHZXRTeXN0ZW1NZXRyaWNzKDc4KTsgLy8gU01fQ1hWSVJUVUFMU0NSRUVOCiAgICAgICAgICAgICAgICBpbnQgdmN5ID0gR2V0U3lzdGVtTWV0cmljcyg3OSk7IC8vIFNNX0NZVklSVFVBTFNDUkVFTgogICAgICAgICAgICAgICAgQm91bmRzID0gbmV3IFJlY3RhbmdsZSh2eCwgdnksIHZjeCwgdmN5KTsKCiAgICAgICAgICAgICAgICBpZiAoSGFuZGxlICE9IEludFB0ci5aZXJvKQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIFNldFdpbmRvd1BvcyhIYW5kbGUsIG5ldyBJbnRQdHIoMSksIHZ4LCB2eSwgdmN4LCB2Y3ksCiAgICAgICAgICAgICAgICAgICAgICAgIFNXUF9GUkFNRUNIQU5HRUQgfCBTV1BfU0hPV1dJTkRPVyB8IFNXUF9OT0FDVElWQVRFKTsKICAgICAgICAgICAgICAgICAgICBMb2coIlJlcG9zaXRpb25lZCB0byBzY3JlZW4gYm91bmRzOiAiICsgdnggKyAiLCIgKyB2eSArICIgIiArIHZjeCArICJ4IiArIHZjeSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY2F0Y2ggKEV4Y2VwdGlvbiBleCkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgTG9nKCJVcGRhdGVCb3VuZHNJbnRlcm5hbCBlcnJvcjogIiArIGV4Lk1lc3NhZ2UpOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBwcm90ZWN0ZWQgb3ZlcnJpZGUgdm9pZCBPbkZvcm1DbG9zZWQoRm9ybUNsb3NlZEV2ZW50QXJncyBlKQogICAgICAgIHsKICAgICAgICAgICAgTWljcm9zb2Z0LldpbjMyLlN5c3RlbUV2ZW50cy5EaXNwbGF5U2V0dGluZ3NDaGFuZ2VkIC09IFN5c3RlbUV2ZW50c19EaXNwbGF5U2V0dGluZ3NDaGFuZ2VkOwogICAgICAgICAgICBiYXNlLk9uRm9ybUNsb3NlZChlKTsKICAgICAgICB9CgogICAgICAgIHByb3RlY3RlZCBvdmVycmlkZSBhc3luYyB2b2lkIE9uTG9hZChFdmVudEFyZ3MgZSkKICAgICAgICB7CiAgICAgICAgICAgIGJhc2UuT25Mb2FkKGUpOwogICAgICAgICAgICBMb2coIkZvcm0gSFdORDogIiArIEhhbmRsZSk7CgogICAgICAgICAgICAvLyDilIDilIAgU3RyaXAgY2FwdGlvbi9wb3B1cCBzdHlsZSwgZW5zdXJlIFdTX0NISUxEIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogICAgICAgICAgICBsb25nIHN0eWxlID0gR2V0V2luZG93TG9uZ1B0cjY0KEhhbmRsZSwgR1dMX1NUWUxFKS5Ub0ludDY0KCk7CiAgICAgICAgICAgIHN0eWxlICY9IH5XU19QT1BVUDsKICAgICAgICAgICAgc3R5bGUgJj0gfldTX0NBUFRJT047CiAgICAgICAgICAgIHN0eWxlICY9IH5XU19USElDS0ZSQU1FOwogICAgICAgICAgICBzdHlsZSB8PSBXU19DSElMRDsKICAgICAgICAgICAgU2V0V2luZG93TG9uZ1B0cjY0KEhhbmRsZSwgR1dMX1NUWUxFLCBuZXcgSW50UHRyKHN0eWxlKSk7CgogICAgICAgICAgICBsb25nIGV4U3R5bGUgPSBHZXRXaW5kb3dMb25nUHRyNjQoSGFuZGxlLCBHV0xfRVhTVFlMRSkuVG9JbnQ2NCgpOwogICAgICAgICAgICBleFN0eWxlICY9IH5XU19FWF9BUFBXSU5ET1c7CiAgICAgICAgICAgIGV4U3R5bGUgfD0gV1NfRVhfVE9PTFdJTkRPVzsKICAgICAgICAgICAgZXhTdHlsZSB8PSBXU19FWF9OT0FDVElWQVRFOwogICAgICAgICAgICBTZXRXaW5kb3dMb25nUHRyNjQoSGFuZGxlLCBHV0xfRVhTVFlMRSwgbmV3IEludFB0cihleFN0eWxlKSk7CgogICAgICAgICAgICAvLyDilIDilIAgUmUtcGFyZW50IGZvcm0gSFdORCBpbnRvIHRoZSBkZXNrdG9wIGxheWVyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogICAgICAgICAgICAvLyBNYXRjaCB0aGUgdGhyZWFkJ3MgRFBJIGNvbnRleHQgZHluYW1pY2FsbHkgdG8gdGhlIHBhcmVudCdzIHRvIGJ5cGFzcyBTZXRQYXJlbnQgcmVzdHJpY3Rpb25zIChlcnI9ODcpCiAgICAgICAgICAgIEludFB0ciBwYXJlbnREcGkgPSBHZXRXaW5kb3dEcGlBd2FyZW5lc3NDb250ZXh0KF9wYXJlbnRId25kKTsKICAgICAgICAgICAgSW50UHRyIHByZXZEcGkgPSBTZXRUaHJlYWREcGlBd2FyZW5lc3NDb250ZXh0KHBhcmVudERwaSk7CiAgICAgICAgICAgIGJvb2wgcGFyZW50T2sgPSBTZXRQYXJlbnQoSGFuZGxlLCBfcGFyZW50SHduZCk7CiAgICAgICAgICAgIGludCBwYXJlbnRFcnIgPSBNYXJzaGFsLkdldExhc3RXaW4zMkVycm9yKCk7CiAgICAgICAgICAgIFNldFRocmVhZERwaUF3YXJlbmVzc0NvbnRleHQocHJldkRwaSk7IC8vIHJlc3RvcmUKICAgICAgICAgICAgTG9nKCJTZXRQYXJlbnQoRm9ybSB0byBwYXJlbnQpOiAiICsgcGFyZW50T2sgKyAiLCBlcnI9IiArIHBhcmVudEVycik7CgogICAgICAgICAgICAvLyBSZXNpemUgYW5kIHBvc2l0aW9uIGF0IHRoZSB2ZXJ5IGJvdHRvbQogICAgICAgICAgICBVcGRhdGVCb3VuZHNJbnRlcm5hbCgpOwoKICAgICAgICAgICAgLy8g4pSA4pSAIENyZWF0ZSBXZWJWaWV3MiBjb250cm9sIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogICAgICAgICAgICBfd3YgPSBuZXcgV2ViVmlldzIoKTsKICAgICAgICAgICAgX3d2LkRvY2sgPSBEb2NrU3R5bGUuRmlsbDsKICAgICAgICAgICAgQ29udHJvbHMuQWRkKF93dik7CgogICAgICAgICAgICB0cnkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgc3RyaW5nIHVzZXJEYXRhRm9sZGVyID0gQCJDOlxXaW5kb3dzXFRlbXBcTWlPUy1XVjItUHJvZmlsZSI7CiAgICAgICAgICAgICAgICB2YXIgb3B0aW9ucyA9IG5ldyBDb3JlV2ViVmlldzJFbnZpcm9ubWVudE9wdGlvbnMoKTsKICAgICAgICAgICAgICAgIG9wdGlvbnMuQWRkaXRpb25hbEJyb3dzZXJBcmd1bWVudHMgPSAiLS1pZ25vcmUtZ3B1LWJsb2NrbGlzdCAtLWRpc2FibGUtZ3B1LWRyaXZlci1idWctd29ya2Fyb3VuZHMgLS1lbmFibGUtZ3B1LXJhc3Rlcml6YXRpb24iOwogICAgICAgICAgICAgICAgQ29yZVdlYlZpZXcyRW52aXJvbm1lbnQgZW52ID0gYXdhaXQgQ29yZVdlYlZpZXcyRW52aXJvbm1lbnQuQ3JlYXRlQXN5bmMoCiAgICAgICAgICAgICAgICAgICAgbnVsbCwgdXNlckRhdGFGb2xkZXIsIG9wdGlvbnMpOwogICAgICAgICAgICAgICAgTG9nKCJXZWJWaWV3MiBlbnZpcm9ubWVudCBjcmVhdGVkIHdpdGggR1BVIGZsYWdzLiIpOwoKICAgICAgICAgICAgICAgIGF3YWl0IF93di5FbnN1cmVDb3JlV2ViVmlldzJBc3luYyhlbnYpOwogICAgICAgICAgICAgICAgTG9nKCJDb3JlV2ViVmlldzIgaW5pdGlhbGl6ZWQuIik7CgogICAgICAgICAgICAgICAgLy8gU3VwcHJlc3MgYnJvd3NlciBVSSBub2lzZQogICAgICAgICAgICAgICAgX3d2LkNvcmVXZWJWaWV3Mi5TZXR0aW5ncy5BcmVEZWZhdWx0Q29udGV4dE1lbnVzRW5hYmxlZCA9IGZhbHNlOwogICAgICAgICAgICAgICAgX3d2LkNvcmVXZWJWaWV3Mi5TZXR0aW5ncy5BcmVEZXZUb29sc0VuYWJsZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgIF93di5Db3JlV2ViVmlldzIuU2V0dGluZ3MuSXNTdGF0dXNCYXJFbmFibGVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICBfd3YuQ29yZVdlYlZpZXcyLlNldHRpbmdzLklzWm9vbUNvbnRyb2xFbmFibGVkID0gZmFsc2U7CgogICAgICAgICAgICAgICAgLy8gU2V0IHZpcnR1YWwgaG9zdCBuYW1lIG1hcHBpbmcgZm9yIGxvY2FsIGZpbGVzIHRvIGFsbG93IHF1ZXJ5IHBhcmFtZXRlcnMKICAgICAgICAgICAgICAgIF93di5Db3JlV2ViVmlldzIuU2V0VmlydHVhbEhvc3ROYW1lVG9Gb2xkZXJNYXBwaW5nKAogICAgICAgICAgICAgICAgICAgICJtaW9zLmxvY2FsIiwKICAgICAgICAgICAgICAgICAgICBAIkM6XFdpbmRvd3NcV2ViXE1pT1MiLAogICAgICAgICAgICAgICAgICAgIENvcmVXZWJWaWV3Mkhvc3RSZXNvdXJjZUFjY2Vzc0tpbmQuQWxsb3cpOwogICAgICAgICAgICAgICAgTG9nKCJWaXJ0dWFsIGhvc3QgbmFtZSBtYXBwaW5nIHJlZ2lzdGVyZWQuIik7CgogICAgICAgICAgICAgICAgc3RyaW5nIHRhcmdldFVybCA9IF91cmw7CiAgICAgICAgICAgICAgICBpZiAodGFyZ2V0VXJsLlN0YXJ0c1dpdGgoImZpbGU6Ly8vQzovV2luZG93cy9XZWIvTWlPUy8iLCBTdHJpbmdDb21wYXJpc29uLk9yZGluYWxJZ25vcmVDYXNlKSkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICB0YXJnZXRVcmwgPSAiaHR0cHM6Ly9taW9zLmxvY2FsLyIgKyB0YXJnZXRVcmwuU3Vic3RyaW5nKCJmaWxlOi8vL0M6L1dpbmRvd3MvV2ViL01pT1MvIi5MZW5ndGgpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZWxzZSBpZiAodGFyZ2V0VXJsLlN0YXJ0c1dpdGgoImZpbGU6Ly8vQzpcXFdpbmRvd3NcXFdlYlxcTWlPU1xcIiwgU3RyaW5nQ29tcGFyaXNvbi5PcmRpbmFsSWdub3JlQ2FzZSkpCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgdGFyZ2V0VXJsID0gImh0dHBzOi8vbWlvcy5sb2NhbC8iICsgdGFyZ2V0VXJsLlN1YnN0cmluZygiZmlsZTovLy9DOlxcV2luZG93c1xcV2ViXFxNaU9TXFwiLkxlbmd0aCkuUmVwbGFjZSgnXFwnLCAnLycpOwogICAgICAgICAgICAgICAgfQoKICAgICAgICAgICAgICAgIF93di5Tb3VyY2UgPSBuZXcgVXJpKHRhcmdldFVybCk7CiAgICAgICAgICAgICAgICBMb2coIk5hdmlnYXRpbmcgdG8gdGFyZ2V0OiAiICsgdGFyZ2V0VXJsKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBMb2coIldlYlZpZXcyIGluaXQgZXJyb3I6ICIgKyBleCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9Cn0K'
}

function Get-MiOSLivingWallpaperServiceCsB64 {
    return 'dXNpbmcgU3lzdGVtOwp1c2luZyBTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYzsKdXNpbmcgU3lzdGVtLkRpYWdub3N0aWNzOwp1c2luZyBTeXN0ZW0uSU87CnVzaW5nIFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlczsKdXNpbmcgU3lzdGVtLlNlcnZpY2VQcm9jZXNzOwp1c2luZyBTeXN0ZW0uVGV4dDsKdXNpbmcgU3lzdGVtLlRocmVhZGluZzsKdXNpbmcgTWljcm9zb2Z0LldpbjMyOwoKbmFtZXNwYWNlIE1pT1NXYWxscGFwZXJTZXJ2aWNlCnsKICAgIHB1YmxpYyBjbGFzcyBXYWxscGFwZXJTZXJ2aWNlIDogU2VydmljZUJhc2UKICAgIHsKICAgICAgICBwcml2YXRlIFRocmVhZCBfd29ya2VyVGhyZWFkOwogICAgICAgIHByaXZhdGUgYm9vbCBfc3RvcHBpbmcgPSBmYWxzZTsKICAgICAgICBwcml2YXRlIHN0YXRpYyByZWFkb25seSBzdHJpbmcgTG9nUGF0aCA9IEAiQzpcV2luZG93c1xXZWJcTWlPU1xtaW9zX3dhbGxwYXBlcl9zZXJ2aWNlLmxvZyI7CgogICAgICAgIC8vIOKUgOKUgCBXaW4zMiBQL0ludm9rZXMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgogICAgICAgIFtEbGxJbXBvcnQoImFkdmFwaTMyLmRsbCIsIFNldExhc3RFcnJvciA9IHRydWUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBPcGVuUHJvY2Vzc1Rva2VuKEludFB0ciBwcm9jLCB1aW50IGFjY2Vzcywgb3V0IEludFB0ciB0b2tlbik7CgogICAgICAgIFtEbGxJbXBvcnQoImFkdmFwaTMyLmRsbCIsIFNldExhc3RFcnJvciA9IHRydWUsIENoYXJTZXQgPSBDaGFyU2V0LlVuaWNvZGUpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBEdXBsaWNhdGVUb2tlbkV4KEludFB0ciBleGlzdGluZywgdWludCBkZXNpcmVkQWNjZXNzLAogICAgICAgICAgICBJbnRQdHIgdG9rZW5BdHRyaWJ1dGVzLCBpbnQgaW1wZXJzb25hdGlvbkxldmVsLCBpbnQgdG9rZW5UeXBlLCBvdXQgSW50UHRyIG5ld1Rva2VuKTsKCiAgICAgICAgW0RsbEltcG9ydCgiYWR2YXBpMzIuZGxsIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSwgQ2hhclNldCA9IENoYXJTZXQuVW5pY29kZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBib29sIENyZWF0ZVByb2Nlc3NBc1VzZXIoSW50UHRyIHRva2VuLCBzdHJpbmcgYXBwTmFtZSwgc3RyaW5nIGNtZExpbmUsCiAgICAgICAgICAgIEludFB0ciBwcm9jQXR0ciwgSW50UHRyIHRocmVhZEF0dHIsIGJvb2wgaW5oZXJpdCwgdWludCBjcmVhdGlvbkZsYWdzLAogICAgICAgICAgICBJbnRQdHIgZW52LCBzdHJpbmcgY3dkLCByZWYgU1RBUlRVUElORk8gc2ksIG91dCBQUk9DRVNTX0lORk9STUFUSU9OIHBpKTsKCiAgICAgICAgW0RsbEltcG9ydCgia2VybmVsMzIuZGxsIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBib29sIENsb3NlSGFuZGxlKEludFB0ciBoYW5kbGUpOwoKICAgICAgICBbRGxsSW1wb3J0KCJrZXJuZWwzMi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIEludFB0ciBPcGVuUHJvY2Vzcyh1aW50IGFjY2VzcywgYm9vbCBpbmhlcml0LCBpbnQgcGlkKTsKCiAgICAgICAgW0RsbEltcG9ydCgidXNlcmVudi5kbGwiLCBTZXRMYXN0RXJyb3IgPSB0cnVlLCBDaGFyU2V0ID0gQ2hhclNldC5Vbmljb2RlKV0KICAgICAgICBzdGF0aWMgZXh0ZXJuIGJvb2wgQ3JlYXRlRW52aXJvbm1lbnRCbG9jayhvdXQgSW50UHRyIGVudiwgSW50UHRyIHRva2VuLCBib29sIGluaGVyaXQpOwoKICAgICAgICBbRGxsSW1wb3J0KCJ1c2VyZW52LmRsbCIpXQogICAgICAgIHN0YXRpYyBleHRlcm4gYm9vbCBEZXN0cm95RW52aXJvbm1lbnRCbG9jayhJbnRQdHIgZW52KTsKCiAgICAgICAgW0RsbEltcG9ydCgid3RzYXBpMzIuZGxsIiwgU2V0TGFzdEVycm9yID0gdHJ1ZSldCiAgICAgICAgc3RhdGljIGV4dGVybiBib29sIFdUU1F1ZXJ5U2Vzc2lvbkluZm9ybWF0aW9uKEludFB0ciBoU2VydmVyLCBpbnQgc2Vzc2lvbklkLAogICAgICAgICAgICBpbnQgd3RzSW5mb0NsYXNzLCBvdXQgSW50UHRyIHBwQnVmZmVyLCBvdXQgaW50IHBCeXRlc1JldHVybmVkKTsKCiAgICAgICAgW0RsbEltcG9ydCgid3RzYXBpMzIuZGxsIildCiAgICAgICAgc3RhdGljIGV4dGVybiB2b2lkIFdUU0ZyZWVNZW1vcnkoSW50UHRyIHBNZW1vcnkpOwoKICAgICAgICAvLyBXVFNfSU5GT19DTEFTUy5XVFNDbGllbnRQcm90b2NvbFR5cGUgPSAxNiAtPiAwIGNvbnNvbGUsIDEgSUNBIChDaXRyaXgpLCAyIFJEUAogICAgICAgIGNvbnN0IGludCBXVFNDbGllbnRQcm90b2NvbFR5cGUgPSAxNjsKICAgICAgICBzdGF0aWMgcmVhZG9ubHkgSW50UHRyIFdUU19DVVJSRU5UX1NFUlZFUl9IQU5ETEUgPSBJbnRQdHIuWmVybzsKCiAgICAgICAgW1N0cnVjdExheW91dChMYXlvdXRLaW5kLlNlcXVlbnRpYWwsIENoYXJTZXQgPSBDaGFyU2V0LlVuaWNvZGUpXQogICAgICAgIHN0cnVjdCBTVEFSVFVQSU5GTwogICAgICAgIHsKICAgICAgICAgICAgcHVibGljIGludCBjYjsKICAgICAgICAgICAgcHVibGljIHN0cmluZyBscFJlc2VydmVkOwogICAgICAgICAgICBwdWJsaWMgc3RyaW5nIGxwRGVza3RvcDsKICAgICAgICAgICAgcHVibGljIHN0cmluZyBscFRpdGxlOwogICAgICAgICAgICBwdWJsaWMgaW50IGR3WCwgZHdZLCBkd1hTaXplLCBkd1lTaXplOwogICAgICAgICAgICBwdWJsaWMgaW50IGR3WENvdW50Q2hhcnMsIGR3WUNvdW50Q2hhcnM7CiAgICAgICAgICAgIHB1YmxpYyBpbnQgZHdGaWxsQXR0cmlidXRlOwogICAgICAgICAgICBwdWJsaWMgaW50IGR3RmxhZ3M7CiAgICAgICAgICAgIHB1YmxpYyBzaG9ydCB3U2hvd1dpbmRvdzsKICAgICAgICAgICAgcHVibGljIHNob3J0IGNiUmVzZXJ2ZWQyOwogICAgICAgICAgICBwdWJsaWMgSW50UHRyIGxwUmVzZXJ2ZWQyOwogICAgICAgICAgICBwdWJsaWMgSW50UHRyIGhTdGRJbnB1dCwgaFN0ZE91dHB1dCwgaFN0ZEVycm9yOwogICAgICAgIH0KCiAgICAgICAgW1N0cnVjdExheW91dChMYXlvdXRLaW5kLlNlcXVlbnRpYWwpXQogICAgICAgIHN0cnVjdCBQUk9DRVNTX0lORk9STUFUSU9OCiAgICAgICAgewogICAgICAgICAgICBwdWJsaWMgSW50UHRyIGhQcm9jZXNzLCBoVGhyZWFkOwogICAgICAgICAgICBwdWJsaWMgaW50IGR3UHJvY2Vzc0lkLCBkd1RocmVhZElkOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgdWludCBUT0tFTl9EVVBMSUNBVEUgPSAweDAwMDI7CiAgICAgICAgY29uc3QgdWludCBUT0tFTl9RVUVSWSA9IDB4MDAwODsKICAgICAgICBjb25zdCB1aW50IFRPS0VOX0FTU0lHTl9QUklNQVJZID0gMHgwMDAxOwogICAgICAgIGNvbnN0IHVpbnQgVE9LRU5fQURKVVNUX0RFRkFVTFQgPSAweDAwODA7CiAgICAgICAgY29uc3QgdWludCBUT0tFTl9BREpVU1RfU0VTU0lPTklEID0gMHgwMTAwOwogICAgICAgIGNvbnN0IHVpbnQgVE9LRU5fQUxMX0FDQ0VTUyA9IDB4RjAxRkY7CiAgICAgICAgY29uc3QgaW50IFNlY3VyaXR5SW1wZXJzb25hdGlvbiA9IDI7CiAgICAgICAgY29uc3QgaW50IFRva2VuUHJpbWFyeSA9IDE7CiAgICAgICAgY29uc3QgdWludCBQUk9DRVNTX0FMTF9BQ0NFU1MgPSAweDFGMEZGRjsKICAgICAgICBjb25zdCB1aW50IENSRUFURV9VTklDT0RFX0VOVklST05NRU5UID0gMHgwMDAwMDQwMDsKICAgICAgICBjb25zdCB1aW50IENSRUFURV9OT19XSU5ET1cgPSAweDA4MDAwMDAwOwoKICAgICAgICAvLyDilIDilIAgU2VydmljZSBMb2dpYyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCiAgICAgICAgcHVibGljIHN0YXRpYyB2b2lkIE1haW4oc3RyaW5nW10gYXJncykKICAgICAgICB7CiAgICAgICAgICAgIGlmIChFbnZpcm9ubWVudC5Vc2VySW50ZXJhY3RpdmUpCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIENvbnNvbGUuV3JpdGVMaW5lKCJNaU9TIFdhbGxwYXBlciBTZXJ2aWNlIHJ1bm5pbmcgaW4gZGVidWcgbW9kZS4gUHJlc3MgQ3RybCtDIHRvIGV4aXQuIik7CiAgICAgICAgICAgICAgICBXYWxscGFwZXJTZXJ2aWNlIHN2YyA9IG5ldyBXYWxscGFwZXJTZXJ2aWNlKCk7CiAgICAgICAgICAgICAgICBzdmMuT25TdGFydChhcmdzKTsKICAgICAgICAgICAgICAgIFRocmVhZC5TbGVlcChUaW1lb3V0LkluZmluaXRlKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIFNlcnZpY2VCYXNlLlJ1bihuZXcgV2FsbHBhcGVyU2VydmljZSgpKTsKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgcHVibGljIFdhbGxwYXBlclNlcnZpY2UoKQogICAgICAgIHsKICAgICAgICAgICAgU2VydmljZU5hbWUgPSAiTWlPUy1XYWxscGFwZXItU2VydmljZSI7CiAgICAgICAgICAgIENhbkhhbmRsZVNlc3Npb25DaGFuZ2VFdmVudCA9IHRydWU7CiAgICAgICAgfQoKICAgICAgICBwcml2YXRlIHN0YXRpYyB2b2lkIExvZyhzdHJpbmcgbXNnKQogICAgICAgIHsKICAgICAgICAgICAgdHJ5CiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIEZpbGUuQXBwZW5kQWxsVGV4dChMb2dQYXRoLCAiWyIgKyBEYXRlVGltZS5Ob3cuVG9TdHJpbmcoInl5eXktTU0tZGQgSEg6bW06c3MiKSArICJdICIgKyBtc2cgKyBFbnZpcm9ubWVudC5OZXdMaW5lKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjYXRjaCB7IH0KICAgICAgICAgICAgQ29uc29sZS5Xcml0ZUxpbmUobXNnKTsKICAgICAgICB9CgogICAgICAgIHByb3RlY3RlZCBvdmVycmlkZSB2b2lkIE9uU3RhcnQoc3RyaW5nW10gYXJncykKICAgICAgICB7CiAgICAgICAgICAgIExvZygiU2VydmljZSBzdGFydGluZy4uLiIpOwogICAgICAgICAgICBfc3RvcHBpbmcgPSBmYWxzZTsKICAgICAgICAgICAgX3dvcmtlclRocmVhZCA9IG5ldyBUaHJlYWQoV29ya2VyTG9vcCk7CiAgICAgICAgICAgIF93b3JrZXJUaHJlYWQuSXNCYWNrZ3JvdW5kID0gdHJ1ZTsKICAgICAgICAgICAgX3dvcmtlclRocmVhZC5TdGFydCgpOwogICAgICAgICAgICBMb2coIlNlcnZpY2Ugc3RhcnRlZCB3b3JrZXIgdGhyZWFkLiIpOwogICAgICAgIH0KCiAgICAgICAgcHJvdGVjdGVkIG92ZXJyaWRlIHZvaWQgT25TdG9wKCkKICAgICAgICB7CiAgICAgICAgICAgIExvZygiU2VydmljZSBzdG9wcGluZy4uLiIpOwogICAgICAgICAgICBfc3RvcHBpbmcgPSB0cnVlOwogICAgICAgICAgICBpZiAoX3dvcmtlclRocmVhZCAhPSBudWxsICYmIF93b3JrZXJUaHJlYWQuSXNBbGl2ZSkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgX3dvcmtlclRocmVhZC5Kb2luKDIwMDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIExvZygiU2VydmljZSBzdG9wcGVkLiIpOwogICAgICAgIH0KCiAgICAgICAgcHJvdGVjdGVkIG92ZXJyaWRlIHZvaWQgT25TZXNzaW9uQ2hhbmdlKFNlc3Npb25DaGFuZ2VEZXNjcmlwdGlvbiBjaGFuZ2VEZXNjcmlwdGlvbikKICAgICAgICB7CiAgICAgICAgICAgIC8vIFJlYWN0IGltbWVkaWF0ZWx5IG9uIGNvbm5lY3QvZGlzY29ubmVjdC9sb2dvbiBzbyB0aGUgd2FsbHBhcGVyIHRvZ2dsZXMKICAgICAgICAgICAgLy8gd2l0aG91dCB3YWl0aW5nIGZvciB0aGUgNXMgcG9sbCDigJQgZS5nLiBhIHJlbW90ZSBzZWFtbGVzcyBzZXNzaW9uIGF0dGFjaGluZy4KICAgICAgICAgICAgTG9nKCJTZXNzaW9uIGNoYW5nZTogIiArIGNoYW5nZURlc2NyaXB0aW9uLlJlYXNvbiArICIgKHNlc3Npb24gIiArIGNoYW5nZURlc2NyaXB0aW9uLlNlc3Npb25JZCArICIpIik7CiAgICAgICAgICAgIHRyeSB7IENoZWNrQW5kTGF1bmNoV2FsbHBhcGVyKCk7IH0KICAgICAgICAgICAgY2F0Y2ggKEV4Y2VwdGlvbiBleCkgeyBMb2coIk9uU2Vzc2lvbkNoYW5nZSBlcnJvcjogIiArIGV4Lk1lc3NhZ2UpOyB9CiAgICAgICAgICAgIGJhc2UuT25TZXNzaW9uQ2hhbmdlKGNoYW5nZURlc2NyaXB0aW9uKTsKICAgICAgICB9CgogICAgICAgIHByaXZhdGUgdm9pZCBXb3JrZXJMb29wKCkKICAgICAgICB7CiAgICAgICAgICAgIHdoaWxlICghX3N0b3BwaW5nKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICB0cnkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBDaGVja0FuZExhdW5jaFdhbGxwYXBlcigpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgY2F0Y2ggKEV4Y2VwdGlvbiBleCkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBMb2coIkV4Y2VwdGlvbiBpbiB3b3JrZXIgbG9vcDogIiArIGV4Lk1lc3NhZ2UpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgVGhyZWFkLlNsZWVwKDUwMDApOyAvLyBDaGVjayBldmVyeSA1IHNlY29uZHMKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgcHJpdmF0ZSB2b2lkIENoZWNrQW5kTGF1bmNoV2FsbHBhcGVyKCkKICAgICAgICB7CiAgICAgICAgICAgIC8vIFRoZSBsaXZpbmcgd2FsbHBhcGVyIGlzIGEgRlVMTC1ERVNLVE9QIGJhY2tncm91bmQgbGF5ZXIuIEl0IHN0YXlzIE9OIGZvcgogICAgICAgICAgICAvLyB0aGUgbG9jYWwgY29uc29sZSBhbmQgZm9yIGEgZnVsbCBSRFAgZGVza3RvcCwgYnV0IGlzIHRvZ2dsZWQgT0ZGIChubyBsYXllcgogICAgICAgICAgICAvLyBhdCBhbGwpIHdoZW4gdGhlIE1pT1MgV2luZG93cyBlbnYgaXMgcHJvamVjdGVkIGFzIGZsb2F0aW5nIG5hdGl2ZSBhcHAKICAgICAgICAgICAgLy8gd2luZG93cyArIHRhc2tiYXIgb250byBhIEhPU1QgZGVza3RvcCAoV2luQm9hdCAvIFJlbW90ZUFwcCBzZWFtbGVzcykg4oCUIHRoZXJlCiAgICAgICAgICAgIC8vIHRoZSBob3N0IGRlc2t0b3AgZW52aXJvbm1lbnQgaXMgdGhlIGJhY2tncm91bmQsIHNvIGEgV2luZG93cyB3YWxscGFwZXIgbXVzdAogICAgICAgICAgICAvLyBub3QgcGFpbnQgb3ZlciBpdC4gVGhlIGludGVncmF0aW9uIGxheWVyIHNpZ25hbHMgdGhhdCBtb2RlIHZpYSB0aGUgcmVnaXN0cnkKICAgICAgICAgICAgLy8gKHNlZSBTaG91bGRSdW5JblNlc3Npb24pLiBFYWNoIGV4cGxvcmVyLmV4ZSA9PSBvbmUgaW50ZXJhY3RpdmUgc2Vzc2lvbi4KICAgICAgICAgICAgUHJvY2Vzc1tdIGV4cGxvcmVyUHJvY3MgPSBQcm9jZXNzLkdldFByb2Nlc3Nlc0J5TmFtZSgiZXhwbG9yZXIiKTsKICAgICAgICAgICAgUHJvY2Vzc1tdIHdhbGxwYXBlclByb2NzID0gUHJvY2Vzcy5HZXRQcm9jZXNzZXNCeU5hbWUoIk1pT1MtV2FsbHBhcGVyIik7CiAgICAgICAgICAgIEhhc2hTZXQ8aW50PiBwcm9jZXNzZWRTZXNzaW9ucyA9IG5ldyBIYXNoU2V0PGludD4oKTsKCiAgICAgICAgICAgIGZvcmVhY2ggKFByb2Nlc3MgZXhwbG9yZXIgaW4gZXhwbG9yZXJQcm9jcykKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgaW50IHNlc3Npb25JZCA9IGV4cGxvcmVyLlNlc3Npb25JZDsKCiAgICAgICAgICAgICAgICAvLyBTa2lwIHNlc3Npb24gMCAodGhlIG5vbi1pbnRlcmFjdGl2ZSBzZXJ2aWNlcyBzZXNzaW9uKQogICAgICAgICAgICAgICAgaWYgKHNlc3Npb25JZCA9PSAwKSBjb250aW51ZTsKCiAgICAgICAgICAgICAgICBpZiAocHJvY2Vzc2VkU2Vzc2lvbnMuQ29udGFpbnMoc2Vzc2lvbklkKSkgY29udGludWU7CiAgICAgICAgICAgICAgICBwcm9jZXNzZWRTZXNzaW9ucy5BZGQoc2Vzc2lvbklkKTsKCiAgICAgICAgICAgICAgICAvLyBJcyBhIGhvc3QgYWxyZWFkeSBydW5uaW5nIGluIHRoaXMgc2Vzc2lvbj8KICAgICAgICAgICAgICAgIGJvb2wgaXNSdW5uaW5nSW5TZXNzaW9uID0gZmFsc2U7CiAgICAgICAgICAgICAgICBQcm9jZXNzIHJ1bm5pbmcgPSBudWxsOwogICAgICAgICAgICAgICAgZm9yZWFjaCAoUHJvY2VzcyB3cCBpbiB3YWxscGFwZXJQcm9jcykKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBpZiAod3AuU2Vzc2lvbklkID09IHNlc3Npb25JZCkgeyBpc1J1bm5pbmdJblNlc3Npb24gPSB0cnVlOyBydW5uaW5nID0gd3A7IGJyZWFrOyB9CiAgICAgICAgICAgICAgICB9CgogICAgICAgICAgICAgICAgc3RyaW5nIHJlYXNvbjsKICAgICAgICAgICAgICAgIGJvb2wgc2hvdWxkUnVuID0gU2hvdWxkUnVuSW5TZXNzaW9uKHNlc3Npb25JZCwgb3V0IHJlYXNvbik7CgogICAgICAgICAgICAgICAgaWYgKHNob3VsZFJ1biAmJiAhaXNSdW5uaW5nSW5TZXNzaW9uKQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIExvZygiTWlPUy1XYWxscGFwZXIgbm90IHJ1bm5pbmcgaW4gU2Vzc2lvbiAiICsgc2Vzc2lvbklkICsgIiAoIiArIHJlYXNvbiArICIpLiBMYXVuY2hpbmcuLi4iKTsKICAgICAgICAgICAgICAgICAgICBMYXVuY2hXYWxscGFwZXJJblNlc3Npb24oZXhwbG9yZXIpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZWxzZSBpZiAoIXNob3VsZFJ1biAmJiBpc1J1bm5pbmdJblNlc3Npb24pCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgLy8gVG9nZ2xlIE9GRjogdGVhciB0aGUgbGF5ZXIgZG93biBzbyB0aGUgaG9zdCBERSAvIGJhcmUgZGVza3RvcCBzaG93cyB0aHJvdWdoLgogICAgICAgICAgICAgICAgICAgIExvZygiU3VwcHJlc3NpbmcgTWlPUy1XYWxscGFwZXIgaW4gU2Vzc2lvbiAiICsgc2Vzc2lvbklkICsgIiAoIiArIHJlYXNvbiArICIpLiBUZXJtaW5hdGluZyBob3N0IFBJRCAiICsgcnVubmluZy5JZCArICIuIik7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcnVubmluZy5LaWxsKCk7IH0KICAgICAgICAgICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KSB7IExvZygiVGVybWluYXRlIGZhaWxlZCBmb3IgUElEICIgKyBydW5uaW5nLklkICsgIjogIiArIGV4Lk1lc3NhZ2UpOyB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CgogICAgICAgIC8vLyA8c3VtbWFyeT4KICAgICAgICAvLy8gRGVjaWRlIHdoZXRoZXIgdGhlIGZ1bGwtZGVza3RvcCBsaXZpbmcgd2FsbHBhcGVyIGJlbG9uZ3MgaW4gdGhpcyBzZXNzaW9uLgogICAgICAgIC8vLyBPTiBmb3IgbG9jYWwgY29uc29sZSArIGZ1bGwgUkRQIGRlc2t0b3A7IE9GRiB3aGVuIHN1cHByZXNzZWQgYnkgdGhlIG1hc3RlcgogICAgICAgIC8vLyBzd2l0Y2ggb3Igd2hlbiB0aGUgc2Vzc2lvbiBydW5zIGluIGZsb2F0aW5nLWFwcHMgLyBzZWFtbGVzcyAoV2luQm9hdCAvCiAgICAgICAgLy8vIFJlbW90ZUFwcCkgaW50ZWdyYXRpb24gbW9kZSwgd2hpY2ggdGhlIGludGVncmF0aW9uIGxheWVyIHNpZ25hbHMgdmlhCiAgICAgICAgLy8vIEhLTE1cU09GVFdBUkVcTWlPU1xXYWxscGFwZXI6CiAgICAgICAgLy8vICAgRW5hYmxlZCAgICAgICAgRFdPUkQgIGRlZmF1bHQgMSDigJQgZ2xvYmFsIG1hc3RlciB0b2dnbGUgKDAgPSBuZXZlciBwYWludCkKICAgICAgICAvLy8gICBTZWFtbGVzc01vZGUgICBEV09SRCAgZGVmYXVsdCAwIOKAlCAxID0gZW52IHByb2plY3RlZCBhcyBmbG9hdGluZyBhcHBzIC0+IE9GRgogICAgICAgIC8vLyAgIFN1cHByZXNzUmVtb3RlIERXT1JEICBkZWZhdWx0IDAg4oCUIDEgPSBhbHNvIE9GRiBmb3IgYW55IHJlbW90ZSAoUkRQKSBzZXNzaW9uCiAgICAgICAgLy8vIDwvc3VtbWFyeT4KICAgICAgICBwcml2YXRlIGJvb2wgU2hvdWxkUnVuSW5TZXNzaW9uKGludCBzZXNzaW9uSWQsIG91dCBzdHJpbmcgcmVhc29uKQogICAgICAgIHsKICAgICAgICAgICAgaWYgKFJlYWRXYWxscGFwZXJEd29yZCgiRW5hYmxlZCIsIDEpID09IDApIHsgcmVhc29uID0gIm1hc3RlciBFbmFibGVkPTAiOyByZXR1cm4gZmFsc2U7IH0KCiAgICAgICAgICAgIGlmIChSZWFkV2FsbHBhcGVyRHdvcmQoIlNlYW1sZXNzTW9kZSIsIDApICE9IDApCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHJlYXNvbiA9ICJTZWFtbGVzc01vZGU9MSAoZmxvYXRpbmctYXBwcyBwcm9qZWN0aW9uIOKAlCBob3N0IERFIGlzIGJhY2tncm91bmQpIjsKICAgICAgICAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgYm9vbCByZW1vdGUgPSAoR2V0U2Vzc2lvblByb3RvY29sKHNlc3Npb25JZCkgPT0gMik7IC8vIDIgPT0gUkRQCiAgICAgICAgICAgIGlmIChyZW1vdGUgJiYgUmVhZFdhbGxwYXBlckR3b3JkKCJTdXBwcmVzc1JlbW90ZSIsIDApICE9IDApCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHJlYXNvbiA9ICJyZW1vdGUgc2Vzc2lvbiArIFN1cHByZXNzUmVtb3RlPTEiOwogICAgICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgICAgICB9CgogICAgICAgICAgICByZWFzb24gPSByZW1vdGUgPyAiZnVsbCBSRFAgZGVza3RvcCIgOiAibG9jYWwgY29uc29sZSI7CiAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KCiAgICAgICAgLy8gV1RTQ2xpZW50UHJvdG9jb2xUeXBlOiAwID0gY29uc29sZSAobG9jYWwpLCAxID0gSUNBIChDaXRyaXgpLCAyID0gUkRQIChyZW1vdGUpLgogICAgICAgIHByaXZhdGUgaW50IEdldFNlc3Npb25Qcm90b2NvbChpbnQgc2Vzc2lvbklkKQogICAgICAgIHsKICAgICAgICAgICAgSW50UHRyIGJ1ZiA9IEludFB0ci5aZXJvOwogICAgICAgICAgICB0cnkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgaW50IGJ5dGVzOwogICAgICAgICAgICAgICAgaWYgKFdUU1F1ZXJ5U2Vzc2lvbkluZm9ybWF0aW9uKFdUU19DVVJSRU5UX1NFUlZFUl9IQU5ETEUsIHNlc3Npb25JZCwKICAgICAgICAgICAgICAgICAgICAgICAgV1RTQ2xpZW50UHJvdG9jb2xUeXBlLCBvdXQgYnVmLCBvdXQgYnl0ZXMpICYmIGJ1ZiAhPSBJbnRQdHIuWmVybyAmJiBieXRlcyA+PSAyKQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIHJldHVybiBNYXJzaGFsLlJlYWRJbnQxNihidWYpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGNhdGNoIChFeGNlcHRpb24gZXgpIHsgTG9nKCJHZXRTZXNzaW9uUHJvdG9jb2woIiArIHNlc3Npb25JZCArICIpIGVycm9yOiAiICsgZXguTWVzc2FnZSk7IH0KICAgICAgICAgICAgZmluYWxseSB7IGlmIChidWYgIT0gSW50UHRyLlplcm8pIFdUU0ZyZWVNZW1vcnkoYnVmKTsgfQogICAgICAgICAgICByZXR1cm4gMDsKICAgICAgICB9CgogICAgICAgIHByaXZhdGUgaW50IFJlYWRXYWxscGFwZXJEd29yZChzdHJpbmcgbmFtZSwgaW50IGRlZikKICAgICAgICB7CiAgICAgICAgICAgIHRyeQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICB1c2luZyAoUmVnaXN0cnlLZXkga2V5ID0gUmVnaXN0cnkuTG9jYWxNYWNoaW5lLk9wZW5TdWJLZXkoQCJTT0ZUV0FSRVxNaU9TXFdhbGxwYXBlciIpKQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIGlmIChrZXkgIT0gbnVsbCkKICAgICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICAgIG9iamVjdCB2ID0ga2V5LkdldFZhbHVlKG5hbWUpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodiAhPSBudWxsKSByZXR1cm4gQ29udmVydC5Ub0ludDMyKHYpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KSB7IExvZygiUmVhZFdhbGxwYXBlckR3b3JkKCIgKyBuYW1lICsgIikgZXJyb3I6ICIgKyBleC5NZXNzYWdlKTsgfQogICAgICAgICAgICByZXR1cm4gZGVmOwogICAgICAgIH0KCiAgICAgICAgcHJpdmF0ZSB2b2lkIExhdW5jaFdhbGxwYXBlckluU2Vzc2lvbihQcm9jZXNzIGV4cGxvcmVyUHJvY2VzcykKICAgICAgICB7CiAgICAgICAgICAgIGludCBzZXNzaW9uSWQgPSBleHBsb3JlclByb2Nlc3MuU2Vzc2lvbklkOwogICAgICAgICAgICBJbnRQdHIgZXhwbG9yZXJIYW5kbGUgPSBJbnRQdHIuWmVybzsKICAgICAgICAgICAgSW50UHRyIGV4cGxvcmVyVG9rZW4gPSBJbnRQdHIuWmVybzsKICAgICAgICAgICAgSW50UHRyIHByaW1hcnlUb2tlbiA9IEludFB0ci5aZXJvOwogICAgICAgICAgICBJbnRQdHIgZW52ID0gSW50UHRyLlplcm87CgogICAgICAgICAgICB0cnkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgZXhwbG9yZXJIYW5kbGUgPSBPcGVuUHJvY2VzcyhQUk9DRVNTX0FMTF9BQ0NFU1MsIGZhbHNlLCBleHBsb3JlclByb2Nlc3MuSWQpOwogICAgICAgICAgICAgICAgaWYgKGV4cGxvcmVySGFuZGxlID09IEludFB0ci5aZXJvKQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgIExvZygiT3BlblByb2Nlc3MgZmFpbGVkIGZvciBleHBsb3JlciBQSUQgIiArIGV4cGxvcmVyUHJvY2Vzcy5JZCArICI6ICIgKyBNYXJzaGFsLkdldExhc3RXaW4zMkVycm9yKCkpOwogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIH0KCiAgICAgICAgICAgICAgICBpZiAoIU9wZW5Qcm9jZXNzVG9rZW4oZXhwbG9yZXJIYW5kbGUsIFRPS0VOX0FMTF9BQ0NFU1MsIG91dCBleHBsb3JlclRva2VuKSkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBMb2coIk9wZW5Qcm9jZXNzVG9rZW4gZmFpbGVkOiAiICsgTWFyc2hhbC5HZXRMYXN0V2luMzJFcnJvcigpKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CgogICAgICAgICAgICAgICAgaWYgKCFEdXBsaWNhdGVUb2tlbkV4KGV4cGxvcmVyVG9rZW4sIFRPS0VOX0FMTF9BQ0NFU1MsIEludFB0ci5aZXJvLAogICAgICAgICAgICAgICAgICAgIFNlY3VyaXR5SW1wZXJzb25hdGlvbiwgVG9rZW5QcmltYXJ5LCBvdXQgcHJpbWFyeVRva2VuKSkKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBMb2coIkR1cGxpY2F0ZVRva2VuRXggZmFpbGVkOiAiICsgTWFyc2hhbC5HZXRMYXN0V2luMzJFcnJvcigpKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CgogICAgICAgICAgICAgICAgLy8gUmVhZCB3YWxscGFwZXIgVVJMIGZyb20gcmVnaXN0cnksIGZhbGwgYmFjayBpZiBub3QgZm91bmQKICAgICAgICAgICAgICAgIHN0cmluZyB3YWxscGFwZXJVcmwgPSBHZXRXYWxscGFwZXJVcmxGcm9tUmVnaXN0cnkoKTsKCiAgICAgICAgICAgICAgICBzdHJpbmcgd2FsbHBhcGVyRXhlID0gQCJDOlxXaW5kb3dzXFdlYlxNaU9TXE1pT1MtV2FsbHBhcGVyLmV4ZSI7CiAgICAgICAgICAgICAgICBpZiAoIUZpbGUuRXhpc3RzKHdhbGxwYXBlckV4ZSkpCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgTG9nKCJXYWxscGFwZXIgZXhlY3V0YWJsZSBub3QgZm91bmQ6ICIgKyB3YWxscGFwZXJFeGUpOwogICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgIH0KCiAgICAgICAgICAgICAgICBDcmVhdGVFbnZpcm9ubWVudEJsb2NrKG91dCBlbnYsIHByaW1hcnlUb2tlbiwgZmFsc2UpOwoKICAgICAgICAgICAgICAgIFNUQVJUVVBJTkZPIHNpID0gbmV3IFNUQVJUVVBJTkZPKCk7CiAgICAgICAgICAgICAgICBzaS5jYiA9IE1hcnNoYWwuU2l6ZU9mKHNpKTsKICAgICAgICAgICAgICAgIHNpLmxwRGVza3RvcCA9ICJ3aW5zdGEwXFxkZWZhdWx0IjsKICAgICAgICAgICAgICAgIHNpLndTaG93V2luZG93ID0gMDsgLy8gSGlkZGVuIHdpbmRvdyBzdHlsZSBmb3IgdGhlIGhvc3QgcHJvY2VzcyBjb250YWluZXIKCiAgICAgICAgICAgICAgICBQUk9DRVNTX0lORk9STUFUSU9OIHBpID0gbmV3IFBST0NFU1NfSU5GT1JNQVRJT04oKTsKCiAgICAgICAgICAgICAgICBzdHJpbmcgY21kTGluZSA9ICJcIiIgKyB3YWxscGFwZXJFeGUgKyAiXCIgXCIiICsgd2FsbHBhcGVyVXJsICsgIlwiIjsKICAgICAgICAgICAgICAgIGJvb2wgY3JlYXRlZCA9IENyZWF0ZVByb2Nlc3NBc1VzZXIocHJpbWFyeVRva2VuLCBudWxsLCBjbWRMaW5lLCBJbnRQdHIuWmVybywKICAgICAgICAgICAgICAgICAgICBJbnRQdHIuWmVybywgZmFsc2UsIENSRUFURV9VTklDT0RFX0VOVklST05NRU5UIHwgQ1JFQVRFX05PX1dJTkRPVywKICAgICAgICAgICAgICAgICAgICBlbnYsIEAiQzpcV2luZG93c1xXZWJcTWlPUyIsIHJlZiBzaSwgb3V0IHBpKTsKCiAgICAgICAgICAgICAgICBpbnQgY3JlYXRlRXJyID0gTWFyc2hhbC5HZXRMYXN0V2luMzJFcnJvcigpOwogICAgICAgICAgICAgICAgaWYgKGNyZWF0ZWQpCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgTG9nKCJTdWNjZXNzZnVsbHkgbGF1bmNoZWQgTWlPUy1XYWxscGFwZXIuZXhlIGluIFNlc3Npb24gIiArIHNlc3Npb25JZCArICIgKFBJRCAiICsgcGkuZHdQcm9jZXNzSWQgKyAiKSIpOwogICAgICAgICAgICAgICAgICAgIENsb3NlSGFuZGxlKHBpLmhQcm9jZXNzKTsKICAgICAgICAgICAgICAgICAgICBDbG9zZUhhbmRsZShwaS5oVGhyZWFkKTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICBMb2coIkNyZWF0ZVByb2Nlc3NBc1VzZXIgZmFpbGVkIGZvciBTZXNzaW9uICIgKyBzZXNzaW9uSWQgKyAiOiAiICsgY3JlYXRlRXJyKTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgICAgICBjYXRjaCAoRXhjZXB0aW9uIGV4KQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBMb2coIkVycm9yIGxhdW5jaGluZyB3YWxscGFwZXIgaW4gU2Vzc2lvbiAiICsgc2Vzc2lvbklkICsgIjogIiArIGV4Lk1lc3NhZ2UpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGZpbmFsbHkKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgaWYgKGVudiAhPSBJbnRQdHIuWmVybykgRGVzdHJveUVudmlyb25tZW50QmxvY2soZW52KTsKICAgICAgICAgICAgICAgIGlmIChwcmltYXJ5VG9rZW4gIT0gSW50UHRyLlplcm8pIENsb3NlSGFuZGxlKHByaW1hcnlUb2tlbik7CiAgICAgICAgICAgICAgICBpZiAoZXhwbG9yZXJUb2tlbiAhPSBJbnRQdHIuWmVybykgQ2xvc2VIYW5kbGUoZXhwbG9yZXJUb2tlbik7CiAgICAgICAgICAgICAgICBpZiAoZXhwbG9yZXJIYW5kbGUgIT0gSW50UHRyLlplcm8pIENsb3NlSGFuZGxlKGV4cGxvcmVySGFuZGxlKTsKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgcHJpdmF0ZSBzdHJpbmcgR2V0V2FsbHBhcGVyVXJsRnJvbVJlZ2lzdHJ5KCkKICAgICAgICB7CiAgICAgICAgICAgIHRyeQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICB1c2luZyAoUmVnaXN0cnlLZXkga2V5ID0gUmVnaXN0cnkuTG9jYWxNYWNoaW5lLk9wZW5TdWJLZXkoQCJTT0ZUV0FSRVxNaU9TIikpCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgaWYgKGtleSAhPSBudWxsKQogICAgICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAgICAgb2JqZWN0IHZhbCA9IGtleS5HZXRWYWx1ZSgiV2FsbHBhcGVyVXJsIik7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh2YWwgIT0gbnVsbCkKICAgICAgICAgICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIHZhbC5Ub1N0cmluZygpOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGNhdGNoIChFeGNlcHRpb24gZXgpCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIExvZygiRmFpbGVkIHRvIHJlYWQgV2FsbHBhcGVyVXJsIGZyb20gcmVnaXN0cnk6ICIgKyBleC5NZXNzYWdlKTsKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm4gImZpbGU6Ly8vQzovV2luZG93cy9XZWIvTWlPUy9saXZpbmctd2FsbHBhcGVyLmh0bWwiOwogICAgICAgIH0KICAgIH0KfQo='
}