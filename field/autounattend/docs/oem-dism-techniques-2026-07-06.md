<!-- AI-hint: Verified (primary-MS-doc) OEM/DISM techniques for the MiOS-XBOX Win11 26xxx custom ISO: Compact OS, SSD myth-busting, hidden built-in Administrator (RID 500) as the mios-sudo service account, FHS+Windows hybrid layout, and the CANONICAL way to bake the per-user theme into the image (Themes unattend component + correct offline Default-hive edit) so branding ships in-image with no runtime task. Drives the OEM re-architecture of New-MiOSHostServiceCommands / New-MiOSAutounattend / Set-MiOSIdentityOffline / mios-debloat.json. -->
<!-- AI-related: New-MiOSISO.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1, mios-debloat.json, docs/pre-logon-system-services.md, docs/dism-native-conversion-map.md -->

# MiOS-XBOX — OEM/DISM techniques (Win11 26xxx), verified against primary MS docs (2026-07-06)

Every item flagged **[OFFLINE]** (bake into the mounted image / answer file / Default hive) or **[FIRST-BOOT]**. Offline-registry rule: a hive loaded offline has **no `CurrentControlSet`** — edit **`ControlSet001`**.

## 1. Compact OS (compressed install)
- **[OFFLINE]** `DISM /Apply-Image /ImageFile:install.wim /Index:1 /ApplyDir:D:\ /Compact` OR `Expand-WindowsImage -ImagePath install.wim -ApplyPath D:\ -Index 1 -Compact`. (`Add/Export-WindowsImage` do NOT support `-Compact`.)
- **[OFFLINE]** autounattend `Microsoft-Windows-Setup\ImageInstall\OSImage\Compact = true` (windowsPE) — NOT in the schema-reference page (documented only on Compact-OS conceptual pages) → **validate on the 26xxx SIM catalog**.
- **[FIRST-BOOT] fallback that always works:** `compact.exe /compactos:always`. Verify: `compact /compactos:query` → "in the Compact state". Query offline: `compact /CompactOS:query /WinDir:E:\Windows`.
- **NVMe reality:** buys **disk footprint, not speed** (fewer reads vs more CPU decompress; roughly CPU-neutral on fast NVMe). Setup auto-decides if unset.

## 2. SSD/NVMe — most "tweaks" are myths on modern Windows. LEAVE ALONE:
- **SysMain/Superfetch** (SSD-aware since Win8), **ScheduledDefrag** (issues ReTrim, not head-defrag — disabling loses ReTrim + risks NTFS extent-limit), **pagefile** (keep system-managed).
- Real, safe bakes only: **hibernation off** (`ControlSet001\Control\Power\HibernateEnabled=0` / `powercfg /h off`); **TRIM** (`Control\FileSystem\DisableDeleteNotify=0` — already default; useful in-guest to pass UNMAP to thin VHDX); **LastAccess** auto-off on >128 GiB (`NtfsDisableLastAccessUpdate` default `0x80000002`).
- **NVMe APST / power states are HOST-side** — inert inside a Hyper-V guest (virtualized disk). Do NOT bake them into the guest image. → prune such keys from mios-debloat.json.

## 3. Hidden built-in Administrator (RID 500) = `mios-sudo` service account  ⭐ fixes the brain-task failure
- **VERIFIED (MS UAC doc + MS-GPSB):** RID 500 runs with a **FULL, UNFILTERED admin token** while `FilterAdministratorToken=0` (the shipped default) — keyed to **RID, not name** (survives rename). No UAC/AAM, silent elevation, and it holds `SeBatchLogonRight` by default → a scheduled task run as RID-500 executes elevated with **no batch-logon / stored-password fragility** (the exact failure that stopped every `mios-svc` task + blocked the brain deploy).
- Enable + name + hide:
  - Enable **[OFFLINE]** via autounattend `Shell-Setup\AutoLogon\Username=Administrator` ("enables the built-in Administrator..."), OR **[FIRST-BOOT]** `net user Administrator /active:yes`.
  - Password **[OFFLINE]** `Shell-Setup\UserAccounts\AdministratorPassword`.
  - Rename **[FIRST-BOOT, bakeable in answer file]** `Rename-LocalUser -Name Administrator -NewName mios-sudo` (specialize `RunSynchronousCommand`; autounattend `LocalAccount` cannot name an account "Administrator").
  - Hide **[OFFLINE]** `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList` DWORD `mios-sudo=0` (matches by **current name** → hide AFTER rename). Only suppresses LogonUI enumeration; account still works as a task run-as principal; **autologon still works**.
- **Task LogonType:** use **S4U** (`New-ScheduledTaskPrincipal -UserId mios-sudo -LogonType S4U -RunLevel Highest`) — no stored password, local resources only (WSL is local, so fine).
- **Security:** MS guidance is to keep RID-500 disabled; enabling it = silent elevation for anything in that session, prime lateral-movement target. Operator-accepted trade for a headless WSL launcher. Prefer S4U over autologon (autologon stores `DefaultPassword` cleartext).

## 4. FHS + Windows hybrid (bridge, not merge)
- Lowercase FHS dirs (`C:\etc usr var home opt srv tmp bin lib root`) — zero reserved-name collision; Windows never auto-recreates custom top-level dirs.
- **NEVER** move/junction/hide `C:\Windows`, `C:\Users`, `C:\ProgramData`, `C:\Program Files(( x86))` (FIXED known folders, non-redirectable) or the Windows compat junctions.
- `mklink /J C:\home C:\Users` (junction: no privilege, same volume). Redirect known folders in the **Default hive** `Explorer\User Shell Folders` (Desktop/Personal/Downloads → `%USERPROFILE%\...`). Hide from This PC via `FolderDescriptions\{GUID}\PropertyBag\ThisPCPolicy=Hide` (+ WOW6432Node).
- **WSL honesty:** `/mnt/c/etc` is a free *view* of `C:\etc`; the distro's real `/etc /usr /var` live in the ext4 rootfs VHDX and can NEVER be the same dir. Ship it as a `/mnt/c` bridge + convenience symlinks, not a merge.
- `attrib +h` only (never `+s` — super-hidden + AV-flagged LOLBin). Disable OneDrive KFM or it fights the redirection.

## 5. OEM theme baking — bake it IN, no runtime task  ⭐ replaces the runtime provisioner
- **`.theme`-as-default is DEPRECATED** (verbatim MS): "Theme files can no longer be set as the default Windows theme." Use the **`Microsoft-Windows-Shell-Setup\Themes` unattend component** instead.
- **Primary [OFFLINE], oobeSystem pass:**
  ```xml
  <Themes>
    <ThemeName>MiOS</ThemeName>
    <DesktopBackground>%WINDIR%\web\wallpaper\MiOS\mios.jpg</DesktopBackground>   <!-- must live under %WINDIR% -->
    <WindowColor>0xFF7F401A</WindowColor>   <!-- ARGB accent, or literal "Automatic"; drives Start/taskbar accent -->
    <UWPAppsUseLightTheme>false</UWPAppsUseLightTheme>   <!-- apps dark; does NOT set SystemUsesLightTheme -->
  </Themes>
  ```
  Reliable for wallpaper + accent + apps-dark. Points new users' `CurrentTheme` at the built default → first logon applies it (doesn't reset to light).
- **Supplement [OFFLINE], offline Default hive** for the two gaps (system-dark taskbar + Bibata cursor):
  ```
  reg load HKLM\DEF C:\mount\Users\Default\NTUSER.DAT
  reg add "HKLM\DEF\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v SystemUsesLightTheme /t REG_DWORD /d 0 /f
  reg add "HKLM\DEF\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v AppsUseLightTheme   /t REG_DWORD /d 0 /f
  reg add "HKLM\DEF\Control Panel\Cursors" /ve /t REG_SZ /d "Bibata-Modern-Classic" /f
  reg add "HKLM\DEF\Control Panel\Cursors" /v "Scheme Source" /t REG_DWORD /d 2 /f
  reg add "HKLM\DEF\Control Panel\Cursors" /v Arrow ... (17 roles -> %SystemRoot%\Cursors\Bibata-Modern-Classic\*.cur)
  [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep 5   # <-- release handles BEFORE unload
  reg unload HKLM\DEF
  ```
- **⭐ WHY offline Default-hive editing corrupted profiles before (and the fix):** it is **PROCEDURAL, not inherent** — `reg unload` fails "Access denied" from **unreleased handles** (PS provider / `New-ItemProperty`). Correct OEM procedure = use `reg.exe add` (not the PS provider), then `[gc]::Collect()` + `WaitForPendingFinalizers()` + sleep before `reg unload` (and before dism unmount). Then it is SAFE. This is the missing piece that lets MiOS bake the theme offline instead of via the runtime MINUTE task.
- Theme-mode DWORDs + cursor scheme survive to a new account reliably; **raw accent in Default is recomputed at logon** → must go through `WindowColor`.
- Register the Bibata scheme once in `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Schemes`; stage `.cur/.ani` under `%WINDIR%\Cursors\Bibata-Modern-Classic\`.
- Reliability rank on 26xxx: (1) Themes component + (2) Default-hive supplement = **recommended**; (3) CopyProfile fallback; (4) `.theme` default = dead; (5) `.ppkg` has no theme CSP.

## Build-order cheat sheet
1. **[OFFLINE DISM]** mount → remove provisioned appx OFFLINE (avoids 26xxx sysprep `0x80073cf2`) → reg-load SYSTEM/SOFTWARE/DEFAULT, edit `ControlSet001` (SSD §2, hide-admin UserList §3, known-folder redirect + ThisPCPolicy §4, Default-hive dark+cursor §5) → stage wallpaper/cursors under `%WINDIR%` → mkdir FHS → **`[gc]::Collect()`+sleep** → reg unload → `/Cleanup-Image /StartComponentCleanup /ResetBase` → commit → `/Export-Image`.
2. **[OFFLINE autounattend]** windowsPE: `OSImage\Compact=true`; specialize: RunSynchronous rename admin→mios-sudo (+CopyProfile if used); oobeSystem: `AdministratorPassword`, `Themes` component, OOBE skips, FirstLogonCommands.
3. **[FIRST-BOOT]** SetupComplete/FirstLogon: `mklink /J C:\home C:\Users`; register WSL task as RID-500 S4U; `powercfg /h off`; `compact /compactos:always` fallback. (SetupComplete is DEAD on OEM/MSDM keys — known MiOS-Host caveat.)
