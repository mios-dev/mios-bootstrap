<!-- AI-hint: Tracking doc for the MiOS-Xbox ISO pipeline: UUP Dump (stock Microsoft media) -> merged NTLite preset -> SSOT-sanitized preset + autounattend.xml -> DISM offline servicing -> oscdimg ISO. Records the ordered stages, the tool at each hop, current implementation status, and open items. NO ISO build performed this pass. -->
<!-- AI-related: Merge-MiOSPresets.ps1, ConvertTo-MiOSPreset.ps1, New-MiOSAutounattend.ps1, Export-MiOSDrivers.ps1, dism-native-conversion-map.md, MiOS-Xbox-Merged.xml -->

# MiOS-Xbox ISO pipeline: UUP Dump -> autounattend -> DISM -> ISO

Status legend: **[done]** implemented + validated | **[partial]** implemented, not end-to-end |
**[todo]** designed, not built | **[ext]** external tool / operator step.

This is the reproducible-from-Microsoft-media path. It replaces "NTLite builds the ISO
internally" with a scripted DISM + oscdimg pipeline that consumes the same merged preset.
The identity-agnostic merge + SSOT sanitizer already exist and are validated; the servicing
and ISO-assembly stages are the remaining work.

**Roadmap linkage** (tracked in `mios.git` ROADMAP.md / TASKS.md, WS-XBOX / WS-WEDITION):
Stage 0 (UUP Dump acquisition) == **T-137 (WISO-06 `mios-uup-fetch`)**. Stages 6-10 (DISM
offline servicing + optional deep debloat + oscdimg ISO assembly + CI) == **T-138 (WISO-07)**,
the operator-decided *DISM-native-canonical* path. The SSOT keys this doc references
(`[autounattend]` iso_out / iso_label / bootstrap_url / computer_name / accounts) are added by
**T-147 (WEDITION-02)** — until then `ConvertTo-MiOSPreset.ps1` reads them with MiOS-default
fallbacks (so the flow is forward-accurate but the keys are not yet populated in `mios.toml`).

## Stage map

| # | Stage | Tool | Input -> Output | Status |
|---|---|---|---|---|
| 0 | Acquire stock media | **UUP Dump** | Build id -> `Windows 11 25H2 x64 en-US` ESD/WIM + `uup_download_windows.cmd` -> `sources\install.wim` (+ `boot.wim`, `winre.wim`) | [ext] |
| 1 | Merge presets | `Merge-MiOSPresets.ps1` | 3 intact NTLite presets -> `MiOS-Xbox-Merged.xml` (deduped, identity-agnostic) | **[done]** |
| 2 | Sanitize + inject identity | `ConvertTo-MiOSPreset.ps1` | `MiOS-Xbox-Merged.xml` + `mios.toml` -> `MiOS-Xbox.xml` (SSOT hostname/accounts/AutoLogon/FirstLogonCommands, GUID `{MIOS-XBOX-SSOT}`, AutoIso, Posture B) | **[done]** |
| 3 | Emit autounattend | `New-MiOSAutounattend.ps1` | SSOT -> `autounattend.xml` (Setup-consumed: OOBE, LabConfig bypass, disk layout, accounts, FirstLogon) | **[partial]** |
| 4 | Export drivers | `Export-MiOSDrivers.ps1` | live OEM -> `M:\MiOS\drivers\*.inf` for slipstream | **[partial]** |
| 5 | Mount image | `Mount-WindowsImage` | `install.wim` (index = Pro) -> `M:\mount` | [todo] |
| 6 | Offline servicing | `DISM` module | remove appx/capabilities/features, add packages/drivers, offline-reg tweaks (per conversion map) | [todo] |
| 7 | Deep debloat (optional) | **NTLite** *or* skip | the ~200 CBS-only component removals DISM cannot do | [todo]/[ext] |
| 8 | Commit + optimize | `Dismount-WindowsImage -Save` + `Export-WindowsImage` (or `dism /Export-Image`) | serviced mount -> trimmed `install.wim`/`.esd` | [todo] |
| 9 | Stage ISO tree | copy | serviced `install.wim` + `autounattend.xml` + boot files -> `M:\MiOS\iso\root\` | [todo] |
| 10 | Build ISO | **oscdimg.exe** (ADK) | ISO tree -> `MiOS-Xbox.iso` (BIOS+UEFI El-Torito) | [todo] |

## Stage detail

### 0 — UUP Dump (stock, signed media)
Pick the target build (**Windows 11 Professional 25H2 x64, 10.0.26220.7670, en-US** — matches all
three source presets' `ImageInfo/Version`). UUP Dump's `uup_download_windows.cmd` reconstructs a
Microsoft-signed `install.wim` (or `.esd`) from Windows Update payloads — no third-party media.
This is what makes the whole path reproducible: every downstream op is DISM on Microsoft bits.

### 1 — Merge (DONE)
`Merge-MiOSPresets.ps1` unions the debloat intent of all three intact presets into one
well-formed, deduped, **identity-agnostic** preset. Base/canonical = `Xbox-Minimal-ULTRA-PLUS.xml`
(sole `Unattended`, `ApplyOptions`, `ImageInfo`, `Packages`, `Drivers`). Validated: 286 unique
`<c>`, 81 unique Features, exactly 1 oobeSystem Shell-Setup, exactly 1 ApplyOptions, no purged identity token.

### 2 — Sanitize (DONE)
`ConvertTo-MiOSPreset.ps1` consumes the merged preset and applies SSOT identity + Posture B.
Validated end-to-end: GUID -> `{MIOS-XBOX-SSOT}`, `lxss` removals stripped (WSL preserved),
`FirstLogonCommands` + `AutoLogon` injected from `mios.toml`, no purged identity token. **The merged preset is
the sanitizer's input contract and it passes without throwing.**

### 3 — autounattend.xml
Windows-Setup-consumed answer file. Carries what DISM cannot: OOBE skips, disk layout (96 GB C:
carve + M: = rest), local accounts, `FirstLogonCommands` (MiOS `irm|iex` bootstrap), and the
Win11 hardware bypass — `windowsPE` `RunSynchronousCommand` writing
`HKLM\System\Setup\LabConfig` (`BypassTPMCheck`/`BypassSecureBootCheck`/`BypassRAMCheck`/
`BypassCPUCheck`/`BypassStorageCheck` = 1). Placed at the ISO root so Setup auto-consumes it.

### 5-6 — Mount + DISM servicing
```powershell
Mount-WindowsImage -ImagePath M:\iso\root\sources\install.wim -Index <Pro> -Path M:\mount
# removals (verify against the mounted manifest, then act -- see conversion map)
Get-AppxProvisionedPackage  -Path M:\mount   # -> Remove-AppxProvisionedPackage  (dotted appx)
Get-WindowsCapability       -Path M:\mount   # -> Remove-WindowsCapability        (Name~~~lang~ver)
Get-WindowsOptionalFeature  -Path M:\mount   # -> Disable-WindowsOptionalFeature -Remove
# adds
Add-WindowsPackage        -Path M:\mount -PackagePath <KB.cab/.msu>
Add-AppxProvisionedPackage -Path M:\mount -PackagePath <winget/vclibs.msixbundle>
Add-WindowsDriver         -Path M:\mount -Driver M:\MiOS\drivers -Recurse
# registry tweaks (offline hive)
reg load  HKLM\OFF M:\mount\Windows\System32\config\SOFTWARE
reg add   "HKLM\OFF\..." /v <name> /t REG_DWORD /d <val> /f
reg unload HKLM\OFF
```
Repeat mount+servicing for `boot.wim` and `winre.wim` where the preset's ApplyOptions targets them.

### 7 — Deep debloat (NTLite-only, optional)
The ~200 lowercase `Microsoft-Windows-*` component removals have no DISM front (conversion map).
Either (a) run the merged preset through NTLite here for the deep pass, or (b) skip and accept a
larger image in exchange for a 100%-DISM, fully-reproducible build. MiOS default target = (b) for
reproducibility; (a) is the "maximum-debloat" opt-in.

### 8 — Commit + optimize
`Dismount-WindowsImage -Path M:\mount -Save`, then
`Export-WindowsImage -SourcePath install.wim -SourceIndex 1 -DestinationImagePath install-trim.wim
-CompressionType Max` (PS cmdlet; `-CompressionType` accepts `Fast|Max|None`). For `recovery`
(`.esd`) compression, DISM only: `dism /Export-Image /SourceImageFile:install.wim /SourceIndex:1
/DestinationImageFile:install.esd /Compress:recovery`. Mirrors ApplyOptions `imageSaveTrim`.

### 9-10 — Stage + oscdimg
DISM cannot create an ISO. Assemble the boot tree and call ADK `oscdimg.exe`:
```
oscdimg.exe -m -o -u2 -udfver102 ^
  -bootdata:2#p0,e,b<root>\boot\etfsboot.com#pEF,e,b<root>\efi\microsoft\boot\efisys.bin ^
  <root> M:\MiOS\iso\MiOS-Xbox.iso
```
Label + output path come from SSOT (`autounattend.iso_out`/`iso_label`) — the same values the
sanitizer writes into `ApplyOptions/AutoIsoFile`+`AutoIsoLabel`.

## Open items
- [todo] `New-MiOSISO.ps1` orchestrator for stages 5-10 (mount, DISM verbs from the conversion
  map with live-manifest verification, dismount+trim, oscdimg). Reads `mios.toml` for iso_out/label.
- [todo] ADK dependency: detect/install `oscdimg.exe` (Deployment Tools) on the builder.
- [partial] Confirm `New-MiOSAutounattend.ps1` emits the LabConfig bypass + disk layout matching
  the merged preset's intent.
- [decision] Stage 7 default: pure-DISM (reproducible) vs NTLite deep-pass (max debloat). Expose as
  an `mios.toml` switch rather than hardcoding.
- **No ISO built this pass** — pipeline stages 1-2 validated; 3-10 tracked here for the build pass.
