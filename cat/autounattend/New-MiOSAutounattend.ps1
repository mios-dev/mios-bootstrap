# AI-hint: SSOT-driven generator that renders a MiOS autounattend.xml (with a nested MiOS irm|iex bootstrap + all local offline accounts from mios.toml) and optionally injects it into a UUP-Dump / winutil source ISO via oscdimg to produce a custom "MiOS Windows 11" install image.
# AI-related: mios-bootstrap, Get-MiOS.ps1, cat/autounattend/autounattend.xml, Invoke-MiOSProvision.ps1
# AI-functions: Read-MiosToml, ConvertTo-UnattendPassword, New-MiOSAutounattendXml, Build-MiOSIso
#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a MiOS autounattend.xml from mios.toml SSOT, and (optionally) inject
    it into a Windows 11 ISO to produce a custom MiOS install image.

.DESCRIPTION
    Part of the MiOS custom-Windows pipeline:

        UUP Dump            -> latest, slipstreamed Windows 11 source ISO
        winutil / MicroWin  -> debloat + hardware-check bypass (optional)
        THIS SCRIPT         -> Schneegans-style autounattend.xml with:
                                 * ALL local ("offline") accounts from SSOT
                                   (mios.toml [[autounattend.accounts]]),
                                   NO Microsoft account, fully offline
                                 * OOBE skip + long-path enable + optional
                                   Win11 TPM/SecureBoot/RAM bypass
                                 * a NESTED MiOS irm|iex in FirstLogonCommands
                                   that runs Get-MiOS.ps1 at first boot
        oscdimg (ADK)       -> rebuilt dual BIOS/UEFI bootable MiOS ISO

    "During install" (fresh media) and "post install" (existing Windows users,
    via Invoke-MiOSProvision.ps1) both converge on the SAME irm|iex bootstrap.

    SSOT: accounts, computer name, timezone, and the bootstrap URL all resolve
    from mios.toml. Missing keys degrade-open to safe defaults derived from
    [identity]. No value is hardcoded that belongs in the TOML.

.PARAMETER TomlPath
    mios.toml to read. Default: first of M:\etc\mios\mios.toml,
    M:\usr\share\mios\mios.toml, <repo>\mios.toml.

.PARAMETER OutXml
    Output autounattend.xml path. Default: .\autounattend.xml (cwd).

.PARAMETER SourceIso
    A Windows 11 ISO (from UUP Dump, or a winutil/MicroWin output) to inject the
    autounattend into. When set with -OutIso, rebuilds a bootable ISO via oscdimg.

.PARAMETER OutIso
    Output ISO path for the injected MiOS image.

.PARAMETER WinutilToolsDir
    If given, also copies the generated autounattend.xml to
    <WinutilToolsDir>\autounattend.xml so a winutil/MicroWin build picks up the
    MiOS answer file (MicroWin ships its own tools\autounattend.xml at ISO root).

.PARAMETER FullDiskWindows
    Give Windows the whole disk (C: = all), provisioning M:\ later via Get-MiOS.ps1.
    DEFAULT (off) is the MiOS carve: C: = [autounattend].c_partition_gb (96 GB) and
    the REST of the disk allocated to MiOS as M:\ (MIOS-DEV).

.PARAMETER ObfuscatePasswords
    Base64-obscure account passwords in the XML (Schneegans "Base64 obscuration").
    NOT encryption -- an answer file on media is always readable. Treat passwords
    as first-boot temporary credentials and rotate on first logon.

.PARAMETER BootstrapUrl
    Override the nested-bootstrap URL. Default: mios.toml [autounattend].bootstrap_url
    or the canonical raw Get-MiOS.ps1.

.EXAMPLE
    # SSOT -> autounattend.xml only
    .\New-MiOSAutounattend.ps1 -OutXml .\autounattend.xml

.EXAMPLE
    # Full custom MiOS ISO from a UUP-Dump source ISO
    .\New-MiOSAutounattend.ps1 -SourceIso .\Win11_UUP.iso -OutIso .\MiOS-Win11.iso -CarveDataPartition
#>
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$OutXml = (Join-Path (Get-Location) 'autounattend.xml'),
    [string]$SourceIso,
    [string]$OutIso,
    [string]$WinutilToolsDir,
    [switch]$FullDiskWindows,
    [switch]$ObfuscatePasswords,
    [string]$BootstrapUrl,
    [string]$Edition
)
$ErrorActionPreference = 'Stop'

$CANONICAL_BOOTSTRAP = 'https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1'

# Shared MiOS provisioning core -- same strip-and-rebuild layout + branding the
# NTLite preset (ConvertTo-MiOSPreset) and existing-Windows path (Invoke-MiOSProvision)
# use, so all three stay in parity. (Provides New-MiOSLinuxLayoutCommands, etc.)
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')


function ConvertTo-UnattendPassword {
    # Emits the <Value>/<PlainText> pair for a LocalAccount/AutoLogon password.
    # Base64 form per Windows Setup: Base64( UTF16LE( password + "Password" ) ),
    # PlainText=false. Otherwise PlainText=true.
    param([string]$Pw,[bool]$Obfuscate)
    if ($Obfuscate) {
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Pw + 'Password'))
        return @{ Value = $enc; PlainText = 'false' }
    }
    return @{ Value = [Security.SecurityElement]::Escape($Pw); PlainText = 'true' }
}

function New-MiOSAutounattendXml {
    param($Toml)

    # --- Resolve SSOT ------------------------------------------------------
    $computerName = Get-Toml $Toml 'autounattend.computer_name' (Get-Toml $Toml 'identity.hostname' 'MIOS')
    $timezone     = Get-Toml $Toml 'autounattend.timezone'      (Get-Toml $Toml 'locale.timezone' 'UTC')
    $uiLang       = Get-Toml $Toml 'autounattend.ui_language'   'en-US'
    $inputLocale  = Get-Toml $Toml 'autounattend.input_locale'  '0409:00000409'
    $edition      = Get-Toml $Toml 'autounattend.image_name'    'Windows 11 Pro'
    $productKey   = Get-Toml $Toml 'autounattend.product_key'   'VK7JG-NPHTM-C97JM-9MPGT-3V66T'  # generic Pro
    $bypassHw     = (Get-Toml $Toml 'autounattend.bypass_hardware_checks' 'true') -match '^(true|1|yes)$'
    $runBootstrap = (Get-Toml $Toml 'autounattend.run_bootstrap' 'true') -match '^(true|1|yes)$'
    $bootUrl      = if ($BootstrapUrl) { $BootstrapUrl } else { Get-Toml $Toml 'autounattend.bootstrap_url' $CANONICAL_BOOTSTRAP }
    $cGb          = [int](Get-Toml $Toml 'autounattend.c_partition_gb' '96')   # Windows C: size; MiOS M:\ gets the rest
    $layoutTree   = (Get-Toml $Toml 'autounattend.layout.linux_tree' 'etc usr var home opt srv tmp bin lib root').Trim()

    # Windows <TimeZone> takes a Windows tz id (tzutil), NOT an IANA name. Map the
    # common IANA ids; an unmapped '/'-style value falls back to UTC (a valid Windows
    # id). A plain value (already a Windows id, or the UTC default) passes through.
    $_iana = @{ 'America/New_York'='Eastern Standard Time'; 'America/Chicago'='Central Standard Time'; 'America/Denver'='Mountain Standard Time'; 'America/Los_Angeles'='Pacific Standard Time'; 'America/Phoenix'='US Mountain Standard Time'; 'Europe/London'='GMT Standard Time'; 'Europe/Paris'='Romance Standard Time'; 'Europe/Berlin'='W. Europe Standard Time'; 'Asia/Tokyo'='Tokyo Standard Time'; 'Australia/Sydney'='AUS Eastern Standard Time' }
    if ($timezone -match '/') { $timezone = if ($_iana.ContainsKey($timezone)) { $_iana[$timezone] } else { 'UTC' } }
    # XML-escape scalars that land in the answer-file here-string (an SSOT value with
    # & / < / > would malform the XML). $bootUrl is escaped at its FirstLogon use.
    $computerName = [Security.SecurityElement]::Escape($computerName)
    $timezone     = [Security.SecurityElement]::Escape($timezone)
    $uiLang       = [Security.SecurityElement]::Escape($uiLang)
    $inputLocale  = [Security.SecurityElement]::Escape($inputLocale)
    $edition      = [Security.SecurityElement]::Escape($edition)
    $productKey   = [Security.SecurityElement]::Escape($productKey)

    # --- Accounts (SSOT; fallback to [identity].username as sole admin) -----
    $accounts = @($Toml.accounts)
    if ($accounts.Count -eq 0) {
        $u = Get-Toml $Toml 'identity.username' 'mios'
        $accounts = @(@{ name = $u; display_name = (Get-Toml $Toml 'identity.fullname' 'MiOS User'); group = 'Administrators'; password = $u })
    }

    $localAccountsXml = New-Object System.Text.StringBuilder
    foreach ($a in $accounts) {
        $name  = [Security.SecurityElement]::Escape([string]$a.name)
        # Strip stylistic 'quoted-word' emphasis from a display name so an SSOT value
        # like "'MiOS' User" renders clean on the logon screen (-> "MiOS User"), without
        # destroying legitimate apostrophes (O'Brien has no closing quote, so it is kept).
        $dispRaw = [string]($a.display_name | ForEach-Object { if ($_) { $_ } else { $a.name } })
        $dispRaw = ($dispRaw -replace "'([^']+)'", '$1').Trim()
        $disp  = [Security.SecurityElement]::Escape($dispRaw)
        $group = [string]($a.group | ForEach-Object { if ($_) { $_ } else { 'Users' } })
        $pw    = ConvertTo-UnattendPassword -Pw ([string]$a.password) -Obfuscate:$ObfuscatePasswords
        [void]$localAccountsXml.Append(@"
          <LocalAccount wcm:action="add">
            <Name>$name</Name>
            <DisplayName>$disp</DisplayName>
            <Group>$group</Group>
            <Password>
              <Value>$($pw.Value)</Value>
              <PlainText>$($pw.PlainText)</PlainText>
            </Password>
          </LocalAccount>

"@)
    }

    # First (admin) account drives AutoLogon so FirstLogonCommands run unattended.
    $first   = $accounts[0]
    $firstPw = ConvertTo-UnattendPassword -Pw ([string]$first.password) -Obfuscate:$ObfuscatePasswords
    $firstName = [Security.SecurityElement]::Escape([string]$first.name)

    # --- FirstLogonCommands (USER context): per-user Linux-like layout, then the
    #     nested MiOS irm|iex bootstrap. Layout MUST run here (not specialize) so
    #     HKCU/%USERPROFILE% resolve to the real user, not the systemprofile. -----
    $firstLogonXml = ''
    $_flc = New-Object System.Text.StringBuilder
    $_flOrd = 1
    foreach ($lc in @(New-MiOSLinuxLayoutCommands -Toml $Toml)) {
        [void]$_flc.AppendLine(('        <SynchronousCommand wcm:action="add"><Order>{0}</Order><CommandLine>cmd /c {1}</CommandLine><Description>MiOS user Linux-like layout</Description></SynchronousCommand>' -f $_flOrd, [Security.SecurityElement]::Escape($lc)))
        $_flOrd++
    }
    # Run the custom FirstLogon.ps1 script containing guest tools installs
    $flCmd = "powershell.exe -WindowStyle Normal -ExecutionPolicy Unrestricted -NoProfile -File C:\Windows\Setup\Scripts\FirstLogon.ps1"
    [void]$_flc.AppendLine(('        <SynchronousCommand wcm:action="add"><Order>{0}</Order><CommandLine>{1}</CommandLine><Description>Custom FirstLogon defaults</Description></SynchronousCommand>' -f $_flOrd, [Security.SecurityElement]::Escape($flCmd)))
    $_flOrd++

    # Expire passwords of all local interactive/non-service accounts to force rotation on next logon
    $svcUser = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-sudo'
    # svc_user IS the renamed built-in Administrator (RID 500) = the MiOS AI admin; its
    # account description is SSOT-driven too and stamped onto RID-500 in the specialize pass.
    $svcDesc = Get-Toml $Toml 'autounattend.service.svc_description' 'MiOS AI -- autonomous system administrator (the renamed built-in Administrator, RID 500)'
    $expireCmd = 'powershell.exe -NoProfile -Command "Get-LocalUser | Where-Object { $_.Name -ne ''Administrator'' -and $_.Name -ne ''' + $svcUser + ''' -and $_.Name -ne ''Guest'' -and $_.Name -ne ''DefaultAccount'' -and $_.Name -ne ''WDAGUtilityAccount'' } | Set-LocalUser -PasswordExpired $true"'
    [void]$_flc.AppendLine(('        <SynchronousCommand wcm:action="add"><Order>{0}</Order><CommandLine>{1}</CommandLine><Description>Expire first-boot temporary passwords</Description></SynchronousCommand>' -f $_flOrd, [Security.SecurityElement]::Escape($expireCmd)))
    $_flOrd++


    if ($runBootstrap) {
        # Escape $bootUrl -- an SSOT override with '&' would otherwise break the XML.
        $_url = [Security.SecurityElement]::Escape($bootUrl)
        # UNATTENDED: declare agreement acceptance + fastest prompt timeout so the nested
        # bootstrap never blocks on the interactive AGREEMENTS gate / 90s prompts.
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command &quot;`$env:MIOS_AGREEMENT_ACK='accepted'; `$env:MIOS_AGREEMENT_BANNER='silent'; `$env:MIOS_PROMPT_TIMEOUT='1'; irm $_url | iex&quot;"
        [void]$_flc.AppendLine(('        <SynchronousCommand wcm:action="add"><Order>{0}</Order><CommandLine>{1}</CommandLine><Description>MiOS bootstrap (nested irm|iex)</Description><RequiresUserInput>true</RequiresUserInput></SynchronousCommand>' -f $_flOrd, $cmd))
        $_flOrd++
    }
    if ($_flc.Length -gt 0) {
        $firstLogonXml = "      <FirstLogonCommands>`n" + $_flc.ToString().TrimEnd() + "`n      </FirstLogonCommands>"
    }

    # --- Optional Win11 hardware-check bypass (windowsPE) -------------------
    $bypassXml = ''
    if ($bypassHw) {
        $bypassXml = @"
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
"@
    }

    # --- Disk layout: standard (C: only) OR carve M: at install -------------
    if (-not $FullDiskWindows) {
        # MiOS carve: C: = $cGb GB (Windows), the REST of the disk -> MiOS M:\ (MIOS-DEV).
        $cMb = $cGb * 1024
        $diskXml = @"
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Size>$cMb</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>4</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>4</Order><PartitionID>4</PartitionID><Format>NTFS</Format><Label>MIOS-DEV</Label><Letter>M</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
"@
        $installPartId = 3
    } else {
        $diskXml = @"
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
"@
        $installPartId = 3
    }

    # --- specialize (SYSTEM) provisioner: boot-time services ---------------------
    # MiOS as boot-time SYSTEM services (up BEFORE logon): enable WSL2, make svc_user
    # BE the MiOS AI admin (the renamed built-in Administrator / RID 500), enable RDP,
    # register the MiOS-Host ONSTART task. Runs in the Microsoft-Windows-Deployment
    # RunSynchronous below.
    # NB: the per-USER Linux-like layout is DELIBERATELY NOT here -- specialize runs
    # as SYSTEM, where HKCU=HKU\S-1-5-18 and %USERPROFILE%=systemprofile, so the
    # layout would land on the wrong profile. It is emitted in FirstLogonCommands
    # (user context) below instead.
    $_preOobe = New-Object System.Text.StringBuilder
    $_ord = 2
    foreach ($sc in @(New-MiOSHostServiceCommands -Toml $Toml)) {
        [void]$_preOobe.AppendLine(('        <RunSynchronousCommand wcm:action="add"><Order>{0}</Order><Path>cmd /c {1}</Path><Description>MiOS boot-time service plane (pre-logon)</Description></RunSynchronousCommand>' -f $_ord, [Security.SecurityElement]::Escape($sc)))
        $_ord++
    }
    # --- MiOS AI identity: the built-in Administrator (RID 500) IS svc_user ---------
    # RID-500 rename + svc_description are DELIBERATELY NOT stamped in `specialize`.
    # Identity mutation in the boot-critical pass can strand it ("The computer restarted
    # unexpectedly...") and is redundant: SetupComplete.cmd renames RID-500 + sets the SSOT
    # description POST-OOBE, where Windows Setup ignores exit codes and a failure cannot
    # abort the install (SetupComplete.cmd L66-84; New-MiOSISO substitutes __SVCUSER__ /
    # __SVCPW__ / __SVCDESC__ from mios.toml). `specialize` stays identity-mutation-free.
    $preOobeXml = $_preOobe.ToString().TrimEnd()

    # Boot-into-Xbox FSE: the Microsoft-Windows-Gaming-Configuration component
    # (StartupToGamingHome + GamingHomeApp) launches the full-screen Xbox home on
    # startup. Emitted only when [autounattend.xbox].enable + .start_on_startup.
    $gamingXml = ''
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -match '^(?i:true|1|yes)$' -and
        (Get-Toml $Toml 'autounattend.xbox.start_on_startup' 'true') -match '^(?i:true|1|yes)$') {
        $_homeApp = Get-Toml $Toml 'autounattend.xbox.home_app' 'Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
        $gamingXml = @"
    <component name="Microsoft-Windows-Gaming-Configuration" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <StartupToGamingHome>true</StartupToGamingHome>
      <GamingHomeApp>$([Security.SecurityElement]::Escape($_homeApp))</GamingHomeApp>
    </component>
"@
    }

    # --- Full document -----------------------------------------------------
    return @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by New-MiOSAutounattend.ps1 from mios.toml SSOT. Nested MiOS
     irm|iex runs Get-MiOS.ps1 at first logon. Passwords are $(if($ObfuscatePasswords){'Base64-obscured (NOT encrypted)'}else{'PLAINTEXT'}); treat as first-boot temporary. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>$uiLang</UILanguage></SetupUILanguage>
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$uiLang</SystemLocale>
      <UILanguage>$uiLang</UILanguage>
      <UserLocale>$uiLang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
$bypassXml
      <UserData>
        <ProductKey><Key>$productKey</Key><WillShowUI>OnError</WillShowUI></ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
$diskXml
      <ImageInstall>
        <OSImage>
          <InstallTo><DiskID>0</DiskID><PartitionID>$installPartId</PartitionID></InstallTo>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$edition</Value></MetaData></InstallFrom>
          <Compact>true</Compact>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="offlineServicing">
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$computerName</ComputerName>
      <RegisteredOwner>MiOS</RegisteredOwner>
      <RegisteredOrganization>MiOS</RegisteredOrganization>
      <TimeZone>$timezone</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd /c reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f || exit 0</Path><Description>Enable NTFS long paths for MiOS</Description></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>cmd /c reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f || exit 0</Path><Description>Disable BitLocker Automatic Device Encryption</Description></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>cmd /c reg add HKLM\SOFTWARE\Policies\Microsoft\FVE /v PreventDeviceEncryption /t REG_DWORD /d 1 /f || exit 0</Path><Description>Disable BitLocker Group Policy Encryption</Description></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>cmd /c manage-bde -off C: || exit 0</Path><Description>Turn off BitLocker on SystemDrive</Description></RunSynchronousCommand>
$preOobeXml
      </RunSynchronous>
    </component>
$gamingXml  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$uiLang</SystemLocale>
      <UILanguage>$uiLang</UILanguage>
      <UserLocale>$uiLang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <!-- NB: do NOT set SkipMachineOOBE/SkipUserOOBE. They are deprecated and
             SUPPRESS FirstLogonCommands (so the Linux-like layout + the nested
             irm|iex MiOS bootstrap never fire). The Hide* pages above + the
             LocalAccount + AutoLogon below already auto-complete OOBE, and
             leaving the OOBE flow intact is what lets FirstLogonCommands run. -->
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
$($localAccountsXml.ToString())        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$firstName</Username>
        <LogonCount>1</LogonCount>
        <Password><Value>$($firstPw.Value)</Value><PlainText>$($firstPw.PlainText)</PlainText></Password>
      </AutoLogon>
$firstLogonXml
    </component>
  </settings>
</unattend>
"@
}

function Build-MiOSIso {
    param([string]$SourceIso,[string]$XmlPath,[string]$OutIso)
    # Locate oscdimg (Windows ADK Deployment Tools).
    $oscdimg = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools" -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) { $oscdimg = (Get-Command oscdimg.exe -ErrorAction SilentlyContinue).Source }
    if (-not $oscdimg) {
        throw "oscdimg.exe not found. Install the Windows ADK 'Deployment Tools', or run winutil/MicroWin which bundles the ISO build. autounattend.xml written to '$XmlPath' -- copy it to the ISO root manually."
    }
    Write-Host "[*] Mounting $SourceIso ..." -ForegroundColor Cyan
    $mount = Mount-DiskImage -ImagePath (Resolve-Path $SourceIso) -PassThru
    try {
        $drive = ($mount | Get-Volume).DriveLetter + ':'
        $scratch = Join-Path $env:TEMP ("mios-iso-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        Write-Host "[*] Copying ISO contents to $scratch ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $scratch -Force | Out-Null
        Copy-Item -Path "$drive\*" -Destination $scratch -Recurse -Force
        Copy-Item -LiteralPath $XmlPath -Destination (Join-Path $scratch 'autounattend.xml') -Force
        $boot = "-bootdata:2#p0,e,b$scratch\boot\etfsboot.com#pEF,e,b$scratch\efi\microsoft\boot\efisys.bin"
        Write-Host "[*] Building $OutIso via oscdimg ..." -ForegroundColor Cyan
        & $oscdimg -m -o -u2 -udfver102 $boot $scratch $OutIso
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)" }
        Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[+] MiOS ISO built: $OutIso" -ForegroundColor Green
    } finally {
        Dismount-DiskImage -ImagePath (Resolve-Path $SourceIso) | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',
                     (Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
# A caller-supplied -TomlPath may be relative. Read-MiosToml reads via .NET file
# APIs ([IO.File]::ReadAllLines), whose working directory is the PROCESS start dir,
# NOT PowerShell's $PWD -- so a relative path after `cd` resolves against the wrong
# root (CI runs `cd cat/autounattend; -TomlPath ../../mios.toml`, which .NET
# resolved to D:\a\mios.toml and failed). Resolve against $PWD to an absolute path.
if ($TomlPath -and -not [System.IO.Path]::IsPathRooted($TomlPath)) {
    $resolved = Resolve-Path -LiteralPath $TomlPath -ErrorAction SilentlyContinue
    if ($resolved) { $TomlPath = $resolved.Path }
}
# Same $PWD-vs-.NET-cwd hazard for the OUTPUT: [IO.File]::WriteAllText resolves a
# relative -OutXml against the process cwd, not $PWD -- so `cd cat/autounattend;
# -OutXml ./autounattend.xml` would write to the wrong dir and the CI verify step
# (cd cat/autounattend; Test-Path ./autounattend.xml) would not find it. Anchor a
# relative -OutXml to $PWD.
if (-not [System.IO.Path]::IsPathRooted($OutXml)) {
    $OutXml = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutXml))
}
Write-Host "[*] Reading SSOT: $(if ($TomlPath) { $TomlPath } else { '(none found -- using identity defaults)' })" -ForegroundColor DarkGray
$toml = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@() } }
$toml = Apply-MiosEdition -T $toml -Edition $Edition

$xml = New-MiOSAutounattendXml -Toml $toml
[IO.File]::WriteAllText($OutXml, $xml, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[+] autounattend.xml written: $OutXml" -ForegroundColor Green

if ($WinutilToolsDir) {
    if (-not (Test-Path -LiteralPath $WinutilToolsDir)) { New-Item -ItemType Directory -Path $WinutilToolsDir -Force | Out-Null }
    Copy-Item -LiteralPath $OutXml -Destination (Join-Path $WinutilToolsDir 'autounattend.xml') -Force
    Write-Host "[+] Copied to winutil tools dir: $WinutilToolsDir\autounattend.xml (MicroWin will use the MiOS answer file)" -ForegroundColor Green
}

if ($SourceIso -and $OutIso) {
    Build-MiOSIso -SourceIso $SourceIso -XmlPath $OutXml -OutIso $OutIso
} elseif ($SourceIso -or $OutIso) {
    Write-Warning "Both -SourceIso and -OutIso are required to build an ISO. Skipped ISO build; XML is ready at $OutXml."
}

Write-Host ''
Write-Host "Post-install path for EXISTING Windows users (same bootstrap):" -ForegroundColor Cyan
Write-Host '  powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"' -ForegroundColor DarkGray
Write-Host "  (or cat\autounattend\Invoke-MiOSProvision.ps1 to also create the SSOT local accounts first)" -ForegroundColor DarkGray
