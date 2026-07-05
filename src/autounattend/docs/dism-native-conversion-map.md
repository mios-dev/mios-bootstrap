<!-- AI-hint: Maps every NTLite preset op-type in the merged MiOS-Xbox preset to either a DISM-native offline-servicing command (Remove-AppxProvisionedPackage / Remove-WindowsCapability / Disable-WindowsOptionalFeature / Add-WindowsPackage / Add-WindowsDriver / offline-reg / autounattend) or NTLite-ONLY deep CBS component surgery that DISM cannot replicate. Classification is by the component IDENTIFIER GRAMMAR (verified against the mounted image manifest), not a hardcoded keyword list. -->
<!-- AI-related: Merge-MiOSPresets.ps1, ConvertTo-MiOSPreset.ps1, uup-autounattend-dism-iso-flow.md, Export-MiOSDrivers.ps1 -->

# NTLite -> DISM-native conversion map (merged MiOS-Xbox preset)

Source of truth: `src/autounattend/MiOS-Xbox-Merged.xml` (produced by `Merge-MiOSPresets.ps1`,
then identity-sanitized by `ConvertTo-MiOSPreset.ps1`). This document classifies each NTLite
op-type into what a **pure DISM + Windows Setup** pipeline can reproduce vs. what remains
exclusive to NTLite's component servicing engine.

## Why this matters

NTLite does two categorically different things:

1. **Standard offline servicing** — add/remove packages, capabilities, optional features,
   drivers; edit offline registry hives. All of this is 1:1 reproducible with `DISM` /
   the `Dism` PowerShell module + `reg.exe` + an `autounattend.xml`. MiOS prefers these so
   the build is reproducible from stock Microsoft media (see the UUP-Dump flow doc).
2. **Deep CBS component surgery** — removing individual `Microsoft-Windows-*` OS components
   that Microsoft does **not** expose as an appx package, a Feature-on-Demand capability, or
   an optional feature. NTLite rewrites CBS manifests, deletes owned files, and fixes up
   permissions/registry to keep the image bootable. **DISM has no API for this.** These stay
   NTLite-only.

## Classification key (identifier grammar, not a keyword list)

Every removal target is classified by the **form of its identifier**, which is the same
grammar DISM itself uses — so the mapping is verifiable against the mounted image, not guessed:

| Identifier form (example) | DISM object class | Enumerate/verify on mount | Convert with |
|---|---|---|---|
| `publisher.app` dotted, PascalCase appx (`Microsoft.Windows.Photos`, `Clipchamp.Clipchamp`) | Provisioned Appx | `Get-AppxProvisionedPackage -Path M:` | `Remove-AppxProvisionedPackage -Path M: -PackageName <full>` |
| `Name~~~lang~ver` / `Name~~~~ver` tilde-quad (`Language.OCR~~~en-us~0.0.1.0`, `Print.Management.Console~~~~0.0.1.0`) | Windows Capability (FoD) | `Get-WindowsCapability -Path M:` | `Remove-WindowsCapability -Path M: -Name <full>` |
| Registered optional-feature id (`SMB1Protocol`, `TelnetClient`, `Printing-XPSServices-Features`, `MediaPlayback`, `TFTP`) | Optional Feature | `Get-WindowsOptionalFeature -Path M:` | `Disable-WindowsOptionalFeature -Path M: -FeatureName <id> -Remove` |
| KB `.cab` / `.msu` payload | Package | `Get-WindowsPackage -Path M:` | `Add-WindowsPackage -Path M: -PackagePath <cab/msu>` |
| `.msix` / `.appxbundle` (WinGet, VCLibs, UI.Xaml, WindowsAppRuntime) | Provisioned Appx (add) | — | `Add-AppxProvisionedPackage -Path M: -PackagePath <bundle> -LicensePath/-SkipLicense` |
| `.inf` driver | Driver | `Get-WindowsDriver -Path M:` | `Add-WindowsDriver -Path M: -Driver <inf> -Recurse` |
| lowercase NTLite component key (`asimov`, `ceip`, `ndu`, `srumon`, `hotpatch`, `ruxim`, `lockscreens`, inbox-driver bundles) | **none** — not an appx/capability/feature | absent from all three `Get-*` enumerations | **NTLite-ONLY** (see below) |

> The classifier is a first pass by grammar; the build step then **verifies** each target by
> enumerating the mounted image's actual manifest (`Get-AppxProvisionedPackage` /
> `Get-WindowsCapability` / `Get-WindowsOptionalFeature`). A target that resolves in one of those
> lists is DISM-native; one that resolves in none is NTLite-only. No static keyword allowlist is
> shipped (operator LAW: no hardcoded heuristics) — the image manifest is the authority.

## Per-op-type mapping for the merged preset

Counts below are from the current `MiOS-Xbox-Merged.xml` (286 `RemoveComponents/<c>`,
81 DISM `Features`, plus Compatibility toggles, Tweaks, Packages, Drivers, Unattended, ApplyOptions).

### 1. `RemoveComponents/<c>` (286) — SPLIT

- **DISM-native (~84 dotted appx-form):** Store/inbox apps and media extensions — Edge & Edge
  DevTools, Teams, Photos, Camera, Paint, Sticky Notes, Dev Home, Bing Search, Clipchamp, the
  `Microsoft.*VideoExtension`/`*ImageExtension` set, `windowssubsystemforlinux` (the appx face of
  WSL — **kept** by Posture B), `windows.printdialog`, etc.
  -> `Remove-AppxProvisionedPackage` (a handful, e.g. `assembly.net`, resolve as capability/feature
  instead — grammar is a hint, the mount enumeration decides).
- **NTLite-ONLY (~202 lowercase component keys):** telemetry/servicing components
  (`asimov`, `ceip`, `errorreporting`, `waasassessment`, `whesvc`, `srumon`, `ndu`, `mpe`,
  `hotpatch`, `insiderhub`, `ruxim`, `pushtoinstall`, `webthreatdefense`, `deviceupdatecenter`),
  shell/UX subcomponents (`lockscreens`, `screensavers`, `soundthemes`, `firstlogonanim`),
  inbox Wifi/Ethernet driver bundles, kernel-debugging, Windows Help, IE32 remnants. These are
  `Microsoft-Windows-*` CBS components with **no** appx/capability/feature front — DISM cannot
  remove them. **Left to NTLite** (or accepted as "not removed" in the pure-DISM build).

### 2. `Features/<Feature @name>` (81) — DISM-native (split by grammar)

- **51 tilde-quad = capabilities** (`Language.Speech/TextToSpeech/Basic/Handwriting/OCR`,
  `Print.Management.Console`, etc.) -> `Remove-WindowsCapability`.
- **30 plain optional-feature ids** (`SMB1Protocol[-Client/-Server]`, `TelnetClient`, `TFTP`,
  `Printing-Foundation-*`, `Printing-XPSServices-Features`, `MediaPlayback`, `WCF-*`, `MSMQ-*`,
  `WorkFolders-Client`, `Microsoft-Windows-Subsystem-Linux`) ->
  `Enable-/Disable-WindowsOptionalFeature`. **Value `false` = disable; `true` = enable.**
  Posture B forces the virtualization set (`Microsoft-Windows-Subsystem-Linux`,
  `VirtualMachinePlatform`, `HypervisorPlatform`, `Microsoft-Hyper-V`,
  `Containers-DisposableClientVM`) to **Enable** regardless.

### 3. `Compatibility/ComponentFeatures/<Feature enabled=yes|no>` — NOT a DISM op

These are NTLite's **internal dependency-protection toggles** (`Bluetooth`, `USBCamera`,
`Discord`, `EAC`, `Netflix`, `NvidiaSetup`, `WindowsStore`, `Hyper-V`, `Printing` = "protect /
don't protect this from removal"). They steer NTLite's own remover; they are **not** DISM
commands and emit nothing to a DISM script. In the DISM pipeline they degrade to a **safelist**:
"do not remove components these protect." NTLite-only meta (no DISM equivalent, no-op outside NTLite).

### 4. `Tweaks/Settings/TweakGroup/<Tweak>` (registry) — registry-native (DISM-adjacent)

`Keyboard\PrintScreenKeyForSnippingEnabled`, `Power\HiberbootEnabled` (Fast-Startup off),
`Privacy\TrainedDataStore\HarvestContacts`, `Settings\AcceptedPrivacyPolicy`. Reproduced by
**offline hive editing**, not `dism.exe` proper:
`reg load HKLM\OFF M:\Windows\System32\config\SOFTWARE` -> `reg add ...` -> `reg unload`, and/or
the Default User hive (`NTUSER.DAT`), and/or an autounattend `specialize` RunSynchronousCommand.
Standard offline-servicing, fully reproducible.

### 5. `Packages` (KBs + .NET + PS7 + WinGet stack) — DISM-native

`.cab`/`.msu` cumulative/servicing KBs + .NET 4.8.1 -> `Add-WindowsPackage`. PowerShell 7.5.4
`.msixbundle`, WinGet `DesktopAppInstaller`, VCLibs/UI.Xaml/WindowsAppRuntime appx ->
`Add-AppxProvisionedPackage`. `OptimizeAppX`/`UpdateBootManager` map to
`Set-AppXProvisionedDataFile` cleanup + `bcdboot`/`Add-WindowsPackage` boot-manager handling.

### 6. `Drivers` (INF list) — DISM-native

`Add-WindowsDriver -Path M: -Driver <inf> -Recurse` (Xbox `gameflt.inf`/`xvdd.inf`, NVIDIA/AMD,
virtio/VBox). Export handled by `Export-MiOSDrivers.ps1`; slipstream via `Add-WindowsDriver`.

### 7. `Unattended` — Windows Setup, NOT DISM

Consumed by Windows Setup as `autounattend.xml` (accounts/hostname/OOBE/FirstLogonCommands).
Applied by `ConvertTo-MiOSPreset.ps1` from SSOT, emitted alongside the ISO. Not a servicing op.

### 8. `ApplyOptions/ImageTasks` — mixed

- `imageSaveTrim` / `imageFormatWim` / ESD conversion -> `Export-WindowsImage -CompressionType Max`
  (PS cmdlet: `Fast|Max|None`) or `dism /Export-Image /Compress:recovery` for `.esd` (DISM-native).
- `deledition_boot` / edition trim -> `Remove-WindowsImage` / edition servicing (DISM-native, partial).
- Apply tweaks to `winre.wim` **and** `boot.wim` -> mount each WIM and repeat servicing
  (DISM-native, orchestration-heavy).
- **`imageOptionsCreateIso` -> NOT DISM.** ISO assembly requires `oscdimg.exe` from the Windows
  ADK (BIOS+UEFI El-Torito boot). See the flow doc.

## Bottom line

| Op-type | DISM-native | NTLite-only |
|---|---|---|
| Appx removals (dotted) | yes (`Remove-AppxProvisionedPackage`) | — |
| Capabilities (`~~~`) | yes (`Remove-WindowsCapability`) | — |
| Optional features | yes (`Disable/Enable-WindowsOptionalFeature`) | — |
| Lowercase CBS component keys (~202) | — | **yes** (manifest surgery, file/permission/registry fixups) |
| Compatibility protect-toggles | — | yes (NTLite meta; degrades to a safelist) |
| Registry tweaks | yes (offline `reg` / autounattend) | — |
| Package/appx adds | yes (`Add-WindowsPackage`/`Add-AppxProvisionedPackage`) | — |
| Drivers | yes (`Add-WindowsDriver`) | — |
| Unattend | via Windows Setup autounattend | — |
| ISO creation | **no** — `oscdimg.exe` (ADK) | NTLite builds it internally |

**Net:** ~everything except the ~200 deep `Microsoft-Windows-*` component removals (and the ISO
step) is reproducible on stock UUP-Dump media with DISM + reg + oscdimg + autounattend. The deep
debloat is the one thing that keeps NTLite in the loop; a pure-DISM MiOS build accepts a slightly
larger image in exchange for full reproducibility from Microsoft-signed media.
