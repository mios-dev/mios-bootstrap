<!-- AI-hint: The AUTHORITATIVE operator spec for MiOS-Xbox (and shared-across-all-MiOS-images)
     provisioning. Every item is SSOT-driven (mios.toml) at build-time + runtime, synced to MiOS-Env
     OS-wide. The MiOS-Xbox fix work (T-283..T-286 + this) implements + verifies against THIS list.
     "Research" items need the exact registry key / mechanism confirmed before implementing. -->
# MiOS-Xbox Provisioning Spec (operator-defined, SSOT-driven)

> Source of truth for the MiOS-Xbox provisioning fixes. Everything below is defined in `mios.toml`
> (build-time), projected to the live system (runtime), and re-synced to **MiOS-Env** across all
> systems/platforms after any modification. The desktop is **completely secondary** for MiOS-Xbox.

## 0. Deployment order (THE core requirement)
- **MiOS systems fully deploy BEFORE a visible desktop is ever seen.** During OOBE / `SetupComplete`
  (running as SYSTEM, pre-first-interactive-logon): provision accounts + branding + Xbox mode, AND
  bring up the MiOS stack — **MiOS-Dev** (the podman/WSL dev machine) for development, and the
  **fully-built MiOS OCI image(s)** once development is done. No first desktop until this completes.
- Provisioning runs on **MiOS-Sudo = the built-in Administrator (RID 500), renamed** — it IS the
  default admin during setup and is *released/re-secured after setup completes*. NO stray `user`
  account driving a post-desktop install.

## 1. Desktop background / wallpaper (ALL MiOS images — Linux AND Windows)
- **No static desktop background at all** — completely invisible, so RDP / Remote / Linux-host
  integrations show a clean/transparent desktop (see Research §R1). `fNoRemoteDesktopWallpaper=1`,
  desktop `Wallpaper=""`, solid/none.
- **The MiOS Living Wallpaper is embedded and deploys to EVERY MiOS image** (Linux + Windows) — it
  is the only desktop visual. (Windows: WebView2 WorkerW host / the Rust `mios-wallpaperd`; Linux:
  the same `living-wallpaper.html` via the Linux launcher.)

## 2. Desktop icons — NONE visible
- Hide ALL desktop icons.
- **Remove the built-in Microsoft Edge desktop shortcut/icon.**
- **Hide the Recycle Bin icon** (`HideDesktopIcons\...\{645FF040-5081-101B-9F08-00AA002F954E}=1`).

## 3. Taskbar
- **Centered** by default (`TaskbarAl=1`). ✅ (default flipped)
- **No pinned taskbar applications.**
- **Search NOT visible** (`Search\SearchboxTaskbarMode=0`).
- **Emoji button ON, always** on the taskbar. (Research §R2 — exact key.)
- **Touch-keyboard / keyboard button ON** on the taskbar (`TipbandDesiredVisibility=1` /
  `ShowTouchKeyboardButton`). (Research §R2 confirm.)

## 4. Start menu
- **NO pins or shortcuts AT ALL** — empty pinned grid (Start2 `LayoutModification` / import empty).
- **Start "folders" (the row by the power button) ON for exactly: Personal Folder, Network, File
  Explorer, Settings.** Everything else OFF. (Start_Show* DWORDs — Research §R2 exact set.)
- **Centered** Start by default.

## 5. Xbox Mode — enabled ENTIRELY, out of the box
- Xbox Full Screen Experience baked image-wide (FeatureManagement override + DeviceForm spoof in the
  offline SYSTEM hive). Desktop is secondary; Xbox mode is the primary shell.

## 6. Other Windows enablements / hidden features
- ALL the Windows enablements + hidden features already shared in code (dark mode, dev mode, long
  paths, verbose status, end-task, etc.) integrated into **ALL MiOS images**, SSOT-driven.

## 7. Accounts
- **MiOS-Sudo = renamed built-in Administrator (RID 500)** — the default admin during setup, released
  after. `[autounattend.service].svc_user = "mios-sudo"`. No separate `user` login as the driver.

## 8. Branding — DISM / OEM systems-integrator level
- OEM-integrator-grade branding (OEMInformation, OOBE, logos, theme, lock screen) applied at the
  DISM/offline-image level, not just per-user. (Research §R3 — proper OEM/DISM branding surface.)

## 9. SSOT sync — build + runtime + post-modification
- Every setting above resolves from `mios.toml` at build-time, is projected to the live system at
  runtime, and any later modification re-syncs to **MiOS-Env** and is visible across all systems and
  platforms OS-wide. No hand-maintained divergence.

---
## Research items (confirm exact mechanism BEFORE implementing)
- **R1** — Windows desktop with NO background that stays clean/transparent over RDP/Remote + Linux
  (xrdp/FreeRDP/RemoteApp) host integration, while a WebView living wallpaper renders locally.
- **R2** — Exact Win11 (build 26200+) registry keys for: taskbar Search off, **emoji** button on,
  **touch-keyboard** button on; Start pins EMPTY; Start folder row = {Personal, Network, Explorer,
  Settings} only.
- **R3** — DISM/OEM systems-integrator branding surface (OEMInformation, `$OEM$`, OOBE theme, offline
  Default-hive branding) at integrator quality.
