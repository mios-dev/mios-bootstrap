<!-- AI-hint: Tracked follow-ups from the adversarial pipeline review (commit d889383 fixed the build-breakers). These are the remaining MEDIUM/LOW findings + the ones needing a real elevated build to validate -- correctness/robustness/security-posture that do NOT break the default build path. -->
<!-- AI-related: Build-MiOSXboxISO.ps1, New-MiOSISO.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1 -->

# Pipeline review — remaining follow-ups

The adversarial multi-dimension review (5 dimensions, 28 findings) had its verify
pass cut short by a session limit; the **build-breakers were confirmed + fixed**
(commit d889383: `net user /y`, wmic-on-25H2, `wsl --list` UTF-16 mojibake, native
stdout contaminating the returned ISO path, install.esd mount, the TOML
comment/backslash/prefs parser bugs, the ICMP gate, `foundBuild`, `-Esd` forward).

These remain (none break the DEFAULT build path; ranked):

## Medium
1. **Windows `<TimeZone>` takes a Windows tz ID, not IANA.** `New-MiOSAutounattend`
   sources it from `[locale].timezone` (default `UTC` — which *is* a valid Windows id,
   so the default works), but a non-UTC IANA override (e.g. `America/Chicago`) would be
   rejected by Setup. Fix: add `[autounattend].timezone` (Windows id) + a small
   IANA→Windows map, or validate against `tzutil /l`.
2. **Linux-layout commands run as SYSTEM in the specialize pass.**
   `New-MiOSLinuxLayoutCommands` emits `reg add HKCU\...` / `%USERPROFILE%\...`, but
   specialize RunSynchronous runs as SYSTEM → `HKCU`=`HKU\S-1-5-18`,
   `%USERPROFILE%`=`systemprofile`. The layout lands on the wrong profile. Fix: apply
   to the **Default User** hive (so new users inherit) or move to a FirstLogon/user step.
3. **SSOT surface completeness (T-147).** Many keys the pipeline reads exist only as
   in-code defaults, not in `mios.toml`: `[branding].oem_*/ui_font/wallpaper/lockscreen/
   cursor*`, `[autounattend].ui_language/input_locale/image_name/product_key/timezone/
   bypass_hardware_checks/run_bootstrap`, `[autounattend.layout].*`, `[theme].mode`.
   They degrade open but aren't operator-tunable via the one-file SSOT. Fix: add them +
   expose in `configurator/mios.html` (this is exactly ROADMAP T-147).
4. **Security posture (by-design, document + option).** The autounattend bakes the
   local admin + `mios-svc` passwords **cleartext** (`PlainText=true`, `ObfuscatePasswords`
   off) and enables RDP on first boot. These are first-boot temporary creds (rotate on
   first run), but the build should default `-ObfuscatePasswords` on and/or force a
   first-run rotation, and gate RDP behind an explicit SSOT opt-in.

## Low
5. **Servicing `finally { Dismount -Save }` commits a partial image on error.** If a
   step inside the try throws, the half-serviced image is saved, not discarded. Fix:
   `-Discard` on caught error, `-Save` only on the success path. Also the trim export
   keeps only the chosen index (drops other editions — intended for a single-edition
   MiOS-XBOX, but note it).
6. **XML-escape scalar interpolations.** `$computerName/$edition/$productKey/$timezone/
   $uiLang/$inputLocale` and especially `$bootUrl` (in the FirstLogon CommandLine) are
   interpolated into the answer-file here-string un-escaped; a `&` in an SSOT override
   would break the XML. Run them through `[Security.SecurityElement]::Escape`.
7. **`prereqs` stage can't fail.** `Install-MiOSBuildPrereqs` only warns if oscdimg is
   absent → `Build-MiOSXboxISO` records the stage ok=true, then the ISO stage fails
   later with a less obvious message. Fix: return a failing code when oscdimg is still
   missing.
8. **Staging is inside the `-not $SkipServicing` gate** while the tasks are always
   registered — only matters in the `-SkipServicing` test mode (image is stock anyway).

## Re-review update (post-d889383, commit e525c67)

A second adversarial review (26 agents, 0 errors) of the *fixed* code found — and I
then fixed (e525c67) — **2 regressions my d889383 fixes had introduced**:
- CRITICAL: `& native ... 2>&1 | Out-Host` throws `NativeCommandError` under
  `EAP=Stop` in **PowerShell 5.1** (the build interpreter) on the first stderr line →
  aborted the default build. Fixed by scoping `EAP=Continue` around the native call.
- HIGH: `MiOS-Host` keep-alive targeted `wsl -d MiOS`, but the bootstrap registers
  `podman-MiOS-DEV`/`MiOS-DEV` → `WSL_E_DISTRO_NOT_FOUND`, brain never held alive.
  Fixed with exact-name `Resolve-MiOSDistro` + a bounded first-run attempt cap.

It also confirmed the Medium/Low items above are real, and added a few **new Low**
finds still open:
- `New-MiOSISO` `Build-MiOSBootableIso`: the BIOS boot file `boot\etfsboot.com` is
  passed to `-bootdata` with **no existence check** (only the UEFI one is checked).
- `Set-MiOSXboxOfflineReg`: the `reg unload` of the offline hives is fire-and-forget
  (`| Out-Null`, no retry) — a held handle → the later `Dismount -Save` fails on a
  locked hive.
- `Build-MiOSXboxISO`: the merged-preset artifact is written into `$PSScriptRoot`
  (the repo checkout), not `$WorkDir` — every build mutates a repo file, and two
  concurrent builds collide on the path.

## Needs a real elevated+networked build to validate
The whole pipeline has only been unit-verified. A real run (`Build-MiOSXboxISO.ps1`
elevated) is the only way to confirm: the live UUP Dump Dev fetch + converter, the
DISM capability/feature removal counts against a real image manifest, the offline
FeatureManagement/DeviceForm reg, oscdimg boot, and that Setup accepts the autounattend
end-to-end. Smoke-test order: (1) `Install-MiOSBuildPrereqs` surfaces oscdimg; (2)
`mios-uup-fetch` returns a single ISO path (not an array); (3) `New-MiOSISO -SourceIso
<stock>` services + masters an ISO that boots in a VM and reaches FirstLogon.
