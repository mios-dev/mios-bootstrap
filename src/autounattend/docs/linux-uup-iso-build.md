# Linux UUP → MiOS-XBOX ISO build path

`src/autounattend/mios-build-iso.sh` builds a bootable **MiOS-XBOX** Windows 11
install ISO entirely inside Linux (the `podman-MiOS-DEV` distro, which has
passwordless sudo). It exists because the Windows DISM path
(`New-MiOSISO.ps1` + `oscdimg`) needs an elevated token, and on this host `mios`
is a *filtered* admin (Medium IL) — registering a SYSTEM/elevated task returns
"Access is denied", so there is no local Windows elevation path. Linux root
sidesteps that entirely.

First successful build: **2026-07-05**, UUP Dump set **26120.6982** (base image
build 26100.1), Windows 11 Professional, amd64, en-us → `MiOS-XBOX.iso` 4.1 GB,
delivered to `C:\MiOS-XBOX\`.

## Pipeline

```
resolve UUID ─▶ fetch UUP package ─▶ convert.sh (aria2 CDN + wimlib rebuild) ─▶ master ISO ─▶ inject autounattend
   (Stage 0)        (Stage 1)                    (Stage 2)                        (Stage 3)
```

- **Stage 0 — resolve build.** `fetchupd.php?ring=Dev` is the live WU scan and is
  flaky (returns `NO_UPDATE_FOUND` when there is no current Dev flight, and
  `USER_RATE_LIMITED` under load). Fall back to the **`listid.php` catalog**
  (8k+ builds), newest amd64 **"Feature Update"** (a full buildable base; a
  "Quality Update" is only a CU delta and cannot make a full ISO), preferring
  the 26200/26120 Dev range. Long backoff between attempts.
- **Stage 1 — package.** `get.php?...&autodl=2` → the download+convert package
  (`uup_download_linux.sh`, `files/convert.sh`, `ConvertConfig.ini`).
- **Stage 2 — convert.** Runs the converter: aria2 pulls the ~7 GB UUP set from
  the MS CDN, then `files/convert.sh` reconstructs `install.wim` (LZX, ~3.5 GB),
  `boot.wim`, and `winre.wim` into an `ISODIR` tree.
- **Stage 3 — master + inject.** Produce the final ISO with the MiOS
  `autounattend.xml` at `/autounattend.xml` **and** `/sources/autounattend.xml`,
  dual BIOS/UEFI El Torito preserved.

## Environment gotchas (all handled by the script)

1. **`wimlib-imagex` is in a separate package.** On Fedora, `wimlib` ships only
   `libwimlib`; the `wimlib-imagex` CLI the converter needs is in
   **`wimlib-utils`**. Stage -1 installs it (plus `cabextract`, `chntpw`,
   `aria2`, `xorriso`).

2. **Fedora's `xorriso` has NO UDF support.** `xorriso -as mkisofs` rejects
   `-udf`/`--udf` outright ("Unsupported option"). But `convert.sh` masters a
   **UDF-primary** ISO: files visible via UDF, ISO9660 duplicates hidden via
   `--hide "*"`, and it passes **no `-R`/`-J`** — so naively dropping UDF would
   hide every file. Fix: a **`genisoimage` shim** in `/usr/local/bin` that
   ignores convert.sh's boot/hide/udf flags and masters an equivalent bootable
   image with **ISO9660 level 3 + Rock Ridge + Joliet + dual El Torito**.
   - Level 3 (multi-extent) handles the >4 GB (uncompressed 15.7 GB) install
     image; verified xorriso writes and reads back a 5 GB file intact.
   - The shim lives outside the package so it survives convert.sh's per-run
     re-download; convert.sh prefers `genisoimage`, so it picks up the shim.

3. **`git.uupdump.net` returns HTTP 522 (Cloudflare) intermittently.**
   `uup_download_linux.sh` re-fetches `convert.sh` from there on *every* run and
   aborts the whole build on a 522 — even when the ~7 GB set is already present.
   Fix: on a resumed build (UUP set + `files/convert.sh` already local), run
   `convert.sh` **directly** — fully offline, no aria2 / get.php / git.uupdump.

4. **`convert.sh` is monolithic and self-cleaning.** It has no `SkipISO`; its
   `cleanup()`/`errorHandler()` always `rm -rf ISODIR`. So Stage 3 has two paths:
   - **stock ISO present** (convert.sh finished) → `xorriso ... -boot_image any
     replay` the stock ISO and map the answer file in;
   - **no stock ISO but ISODIR complete** (convert.sh's ISO step failed or the
     run was killed mid-master) → `master_from_isodir` directly. This is also
     the recovery path for an interrupted long build.

## WSL-from-PowerShell landmine

Inline `wsl -d … -- bash -lc '… $var …'` loses shell variables and `for`-loop
vars across the PS→WSL boundary (they arrive empty). **Always run build logic
from a script *file*** (`bash -l /mnt/c/…/script.sh`); reserve inline `bash -lc`
for single commands with no local variables. `command -v x` inside `$(…)` works;
bare `$loopvar` expansion does not.

## Verify / write

```bash
xorriso -indev MiOS-XBOX.iso -report_el_torito plain   # expect BIOS + UEFI imgs
xorriso -indev MiOS-XBOX.iso -find / -name autounattend.xml
certutil -hashfile MiOS-XBOX.iso SHA256                # Windows
```

Write with Rufus/Ventoy (USB) or attach as a VM optical drive. A FAT32 USB tool
splits the install image automatically; the on-ISO layout needs no split.
