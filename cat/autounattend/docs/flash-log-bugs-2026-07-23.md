<!-- AI-hint: Ground-truth bug list extracted from a REAL MiOS-Cat flash log (2026-07-23, UUP converter
     v124 -> New-MiOSISO -> AIO flash to D:). Folds into the MiOS-Xbox fix work. Corrects the earlier
     "native-converter skips all provisioning" hypothesis: servicing + branding + SetupComplete +
     autounattend DO bake. These are the actual defects to fix. -->
# MiOS-Cat / MiOS-Xbox flash-log bugs — 2026-07-23 (ground truth)

Build: UUP converter v124, stock **26100.8968** (24H2) -> New-MiOSISO servicing -> MiOS-Xbox.iso 3.2 GB
-> AIO single-pass flash to D:. **Provisioning IS baked** (Xbox FSE 109 ids, debloat 45 ops into Default
hive, SetupComplete svc=mios-sudo, autounattend.xml, wallpaper+theme+cursors+fonts, mios-identity 195
cmds, RDP+EnhancedSession, virtio 18 pkgs). The bugs below are what still breaks / is missing.

## B1 — CRITICAL: DISM mount conflict during UUP servicing (image may be UNDER-serviced)
The converter's install.wim / winre.wim / boot.wim update phases repeatedly fail:
- `M:\MountUUP\Windows\System32\config\SOFTWARE - The process cannot access the file because it is
  being used by another process` (SOFTWARE + .LOG1/2 + TM.blf + regtrans-ms).
- `Error: 0xc1420127 The specified image ... is already mounted for read/write access`
- `Error: 0xc1420117 The directory could not be completely unmounted`
- `Error: 0xc1420114 The user attempted to mount to a directory that is not empty`
- Rebuild reports **"Space saved: 0 KiB"** → the servicing/LCU updates likely did NOT apply.
**Root cause:** a stale/leftover DISM mount at `M:\MountUUP` with the offline SOFTWARE hive still held
open by another process (prior run not cleaned; or an antivirus/indexer/our own reg-load holding it).
**Fix:** before the converter runs, hard-clean: `dism /Cleanup-Mountpoints`, `dism /Unmount-Image
/MountDir:M:\MountUUP /Discard` (loop), `reg unload` any MIOS_*/pe-* hives, kill hive holders, and
ensure `M:\MountUUP` is EMPTY (0xc1420114). Gate the converter on a clean mount root.

## B2 — Driver-pack bake is ON but the directory is EMPTY (T-281)
`[*] Driver-pack bake ON but ...\driverpacks is empty -- populate MiOS-Repo\drivers with chipset/GPU/
NIC .inf trees`. The mechanism I wired runs, but there's no content. NOTE: the stock UUP CompDB DOES
pull a broad inbox NIC set (Intel/Realtek/Broadcom/Qualcomm/Marvell/Ralink WiFi + Intel/Realtek/VMware
Ethernet FODs) — so basic networking is partly covered. STILL MISSING: **AMD Adrenalin + Intel
chipset, base GPU** drivers. **Fix:** populate `driver_pack_dir` (MiOS-Repo\drivers) with those .inf
trees, and/or fetch them at build; MiOS-PE driver installer (T-282) covers the tail at runtime.

## B3 — No offline seeds → Stage-1 provisioning falls back to ONLINE (not self-contained)
`No seed dir found (autounattend.seed.source / build_root\MiOS\seed) -- Stage-1 falls back to embedded
Get-MiOS build. Run Build-MiOSSeed.ps1 on MiOS-DEV to bake offline seeds.` Violates "fully self-
contained". **Fix:** run/wire `Build-MiOSSeed.ps1` so seeds bake into the image (SSOT-gated).

## B4 — OpenSSH.Server offline add failed (online fallback) — not self-contained
`OpenSSH.Server offline add skipped (The source files could not be found.) -- online fallback in
mios-remote.cmd`. **Fix:** stage the OpenSSH.Server FOD source into the offline add (or bake the
capability from the UUP FOD set, which includes OpenSSH-Client — add the Server FOD).

## B5 — Batch bug: `!py_exe!` unresolved after ISO build
`The system cannot find the file !py_exe!.` + `'""' is not recognized as an internal or external
command`. A `%py_exe%`/`!py_exe!` variable (real python.exe path) is empty/unexpanded in the AIO
verification gate (relates to mios-bootstrap 76cf402 "pin full path to real python.exe"). **Fix:**
resolve py_exe robustly (setlocal enabledelayedexpansion + a real python path; guard empty).

## B6 — Flash: `File not found - ventoy` + `File not found - theme`
During "Installing Ventoy bootloader" and "Applying MiOSTheme branding to PortableApps Menu". A
ventoy binary/plugin and a theme asset path aren't found at flash time. **Fix:** resolve the ventoy +
theme asset paths (staging/casing).

## B7 — PortableApps: 2532 of 2539 files SKIPPED (only 7 copied, 1.835 GB skipped)
The PortableApps robocopy skipped almost everything. If intentional (incremental) it's fine; if the
debloat removed them but the copy then skips, the suite is incomplete on the USB. **Fix:** verify the
PortableApps set actually lands (or confirm the skip is the intended incremental behaviour).

## B8 — Flash ends on `Press any key to continue` (not fully unattended)
Minor: the AIO flush waits for a keypress at the very end. **Fix:** make the terminal step
non-interactive under the unattended/monitored path.

## Account note (relates T-284)
`mios-provision.cmd (... svc=mios-sudo desktop=user count=6)` — provisioning correctly targets
**mios-sudo**, but a **`user` desktop account still exists** (6 desktop accts). Per the new spec,
mios-sudo IS the default admin; reconcile whether the `user` account should exist at all / be the
post-setup released login.

## RUNTIME-APPLICATION (must verify by booting the flashed image)
The build STAGES everything; the open question is whether `SetupComplete.cmd` (SYSTEM, pre-logon) +
FirstLogon actually APPLY the specs on first boot (icons off, Start layout, taskbar, wallpaper live,
Xbox FSE active, MiOS stack deployed pre-desktop). B1 (under-servicing) could also cause runtime gaps.
This is the item the operator audited as "nothing applied" — verify in-image after fixing B1.
