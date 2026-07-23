<!-- AI-hint: The SSOT-mapped implementation contract for the MiOS-Xbox provisioning fixes. Every
     setting resolves from mios.toml (NO hardcoded keys/values/passwords in emitters) -> projected to
     the offline image / Default hive / SetupComplete. Synthesizes the root-cause audit (ws9z5qoc6),
     the Win11-keys/RDP/OEM research (wmqkec3hy), and the ground-truth flash-log bugs. Status tags:
     READY (implement now), CAPTURE (needs a reference-machine binary capture), FLASH (only verifiable
     by flashing+inspecting), IMPOSSIBLE (OS limitation). Logs lie (fake-pass) -> verify via image, not logs. -->
# MiOS-Xbox fix blueprint — SSOT-driven, no hardcodes

**Governing rule:** every value below is defined in `mios.toml` and READ by the emitter. No literal
reg key/value/password in `New-MiOSISO.ps1` / `New-MiOSAutounattend.ps1` / `SetupComplete.cmd` / the
XMLs. New SSOT home for shell prefs: **`[autounattend.preferences]`** (already read by
`New-MiOSGlobalPrefCommands`), plus `[branding]`, `[colors]`, `[accounts]`, `[autounattend.service]`,
`[autounattend.xbox]`. Verify by mounting `install.wim` + reading the hives, NOT by trusting logs.

## 0. KEYSTONE — accounts: AutoLogon on mios-sudo, no stray `user` [READY]
Root cause (CONFIRMED in code): `New-MiOSAutounattend.ps1` L138 `$accounts=@($Toml.accounts)`, L170
`$first=$accounts[0]` drives AutoLogon; `mios.toml` L1438 `[[autounattend.accounts]] name="user"` is
accounts[0] → AutoLogon logs into **user**, not mios-sudo (the renamed RID-500 admin). svc_password=""
→ inherits `default_password="user"`.
- **mios.toml:** remove the `[[autounattend.accounts]] name="user"` block; add
  `[autounattend].autologon_user` (default `= autounattend.service.svc_user`). Keep one SSOT password
  (`default_password`) used by specialize (RID-500), AutoLogon, `SetupComplete __SVCPW__`, schtasks
  `/rp` — one value everywhere (mismatch today = AutoLogon fail → falls back).
- **New-MiOSAutounattend.ps1:** emit `<AutoLogon><Username>` from `autologon_user`/svc_user (not
  accounts[0]); in the LocalAccounts loop SKIP any account name == svc_user (RID-500 already exists
  from specialize → duplicate collides). Order OK: specialize renames+activates before oobeSystem.
- mios-sudo is the setup admin; "released after setup" = a post-setup SetupComplete step re-secures
  RID-500 (disable/repassword) once provisioning is done. [FLASH to confirm end-to-end AutoLogon]

## 1. Desktop background / RDP + living wallpaper on ALL images
- `[branding].living_wallpaper=true` (already). **No static bitmap, RDP-clean:** [READY, SSOT]
  - MACHINE policy: `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services | fNoRemoteDesktopWallpaper | DWORD | 1` (authoritative; FreeRDP client flag is a no-op).
  - PER-USER (Default hive), solid color from `[colors].bg`: `Control Panel\Desktop | Wallpaper=""`, `WallpaperStyle=0`, `TileWallpaper=0`; `...\Explorer\Wallpapers | BackgroundType | DWORD | 1`; `Control Panel\Colors | Background | REG_SZ | "R G B"` (from mios.toml [colors].bg).
  - **FIX (audit STEP7b):** `Get-MiOSPerUserBrandingReg` currently sets `Desktop\WallPaper` to the DELETED `mios-wallpaper.jpg` → set EMPTY when living_wallpaper on.
- **Living wallpaper RDP-gate [READY, app code]:** the WorkerW WebView must render **console-only**.
  In the wallpaper host (`MiOS-Wallpaper.cs` now, `mios-wallpaperd` Rust target): attach to WorkerW
  only if `GetSystemMetrics(SM_REMOTESESSION)==0`; `WTSRegisterSessionNotification` + on
  `WM_WTSSESSION_CHANGE` detach on WTS_REMOTE_CONNECT / re-attach on WTS_CONSOLE_CONNECT. True
  see-through over RDP is IMPOSSIBLE (opaque framebuffer) → "no bg" = solid color; RemoteApp is the
  only zero-desktop path. Living wallpaper HTML already deploys to Linux + Windows images.
- **FIX (audit STEP7a):** make csc/WebView2 compile failure LOUD (empty catch L458 swallows it → a
  build can silently ship no wallpaper binary). [READY]

## 2. Desktop icons — none [READY, SSOT]
`[autounattend.preferences]`: `hide_desktop_icons`, `hide_recycle_bin`, `remove_edge_shortcut`.
- `...\Explorer\Advanced | HideIcons | DWORD | 1`.
- Recycle Bin GUID `{645FF040-5081-101B-9F08-00AA002F954E}=1` under **BOTH** `HideDesktopIcons\NewStartPanel` AND `HideDesktopIcons\ClassicStartMenu`.
- Edge: `HKLM\...\Explorer | DisableEdgeDesktopShortcutCreation=1` + `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate | CreateDesktopShortcutDefault=0, RemoveDesktopShortcutDefault=1` + SetupComplete `del "C:\Users\Public\Desktop\Microsoft Edge.lnk"` (reg only blocks FUTURE creation).

## 3. Taskbar [READY, SSOT] — `[autounattend.preferences]`
- `taskbar_align` → `...\Advanced | TaskbarAl | DWORD | 1` (center). ✅ default already flipped.
- `taskbar_search=0` → `...\Search | SearchboxTaskbarMode | DWORD | 0` (HIDDEN — matches new spec; the audit's "make visible" is WRONG here). Optional machine `Policies\...\Windows Search | SearchOnTaskbarMode | 0`.
- `taskbar_touch_keyboard=1` → `HKCU\SOFTWARE\Microsoft\TabletTip\1.7 | TipbandDesiredVisibility | DWORD | 1` — **this IS the "emoji on taskbar" mechanism; Win11 has no dedicated emoji taskbar button.**
- `taskbar_emoji_hotkey` → `HKLM\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1 | EnableExpressiveInputShellHotkey | DWORD | 1` (Win+. panel; LOCALE-dependent loc_0409=en-US — [UNCERTAIN] multi-lang).
- **No taskbar pins:** keep current `PinListPlacement="Replace"` empty (matches new spec; audit's "add pins" is WRONG).

## 4. Start menu [SSOT + CAPTURE]
- **No pins:** keep empty. NOTE [CAPTURE]: a truly empty pinned grid needs a captured `start2.bin`
  from an emptied Start on the SAME build family (24H2/26100 or 25H2/26200) dropped into the Default
  profile package path — LayoutModification.json only does OEM pins, cannot empty it. Store the
  captured blob under `cat/autounattend/resources/start/` and reference via SSOT path.
- **Folder row = {Personal, Network, File Explorer, Settings} only** [CAPTURE]: the Win10 `Start_Show*`
  DWORDs are INERT on Win11. It is one REG_BINARY `HKCU\...\Start | VisiblePlaces` blob (concatenated
  16-byte FOLDERIDs). Capture from a reference machine configured to exactly those 4, store under
  `resources/start/VisiblePlaces.bin`, inject via SSOT. (FOLDERIDs: Personal {5E6C858F-...}, etc.)
- `start_track_progs=0`, `start_track_docs=0`, `HideRecentlyAddedApps=1`, `Start_Layout` — [READY] DWORDs.

## 5. Xbox Mode — entirely out of box [READY]
`[autounattend.xbox].enable=true` (base default). **FIX:** `Build-MiOSXbox.ps1 -Edition` must default
to `mios-xbox` (building `-Edition mios` flips `[editions.mios].enable=false` → Xbox off). [FLASH: FSE
home needs Store Gaming Services (MiOS-XBOX-Hydrate) + Xbox sign-in; logged-out = sign-in wall.]

## 6. New Start menu + Windows features [SSOT + FLASH]
Optional features (VMP/WSL/Hyper-V) via `Removals.EnableFeatures`. The 2026 "new Start menu" is a CFR
flag — confirm its id is in `mios-xbox-features.txt` (SSOT-unioned). [FLASH to confirm the flag flips.]

## 7. OEM branding — integrator level [READY + IMPOSSIBLE note]
- `[branding].oem_*` → `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation` (Manufacturer/
  Model/Logo/SupportURL/SupportHours) written to the offline SOFTWARE hive.
- Theme: cannot be the DEFAULT `.theme`; customize in-place via unattend specialize `<Themes>`
  (DesktopBackground MUST be a subfolder under %WINDIR%). Default profile = Sysprep+CopyProfile
  supported; direct NTUSER.DAT edits work but unsupported — keep minimal.
- Lock screen forced = `PersonalizationCSP`/`ForceDefaultLockScreen` is Enterprise/Education/IoT ONLY
  → [IMPOSSIBLE on Pro]: brand via theme/oobe.json/staged asset, accept it is user-changeable.

## 8. Deploy MiOS systems BEFORE first desktop [FLASH]
SetupComplete (SYSTEM, pre-logon) must bring up MiOS-Dev (podman/WSL) + the built OCI image, gated by
SSOT, before any interactive desktop. Baked scripts (MiOS-Host/Hydrate/Daemon/FirstBoot) exist; verify
they RUN and complete pre-desktop (blocked by KEYSTONE password fix + B1 servicing).

## 9. Flash-log bugs (see flash-log-bugs-2026-07-23.md)
B1 DISM mount conflict (stale M:\MountUUP → under-servicing) — clean mounts before converter [READY].
B2 empty driverpack — populate + harden the $builtNative driver-skip gate [READY]. B3 no seeds — wire
Build-MiOSSeed [READY]. B4 OpenSSH offline add — stage the Server FOD [READY]. B5 `!py_exe!` batch —
resolve py_exe robustly [READY]. B6 ventoy/theme not found [READY]. B7 PortableApps 2532 skipped —
verify [READY]. B8 keypress at end — non-interactive under monitored path [READY].

## 10. Verification gate — stop the fake pass [READY]
`MiOS-Cat.bat:463-475` only checks ISO **existence** then prints "100% compiled, serviced, and
verified" — overclaim. Replace with a REAL gate: mount `install.wim`, assert the SSOT-expected hive
values + SetupComplete + MiOS scripts + Xbox reg are actually present (fail hard, no fake pass).
