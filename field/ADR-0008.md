<!-- AI-hint: MiOS-Cat is the ONE unified front door (stage/install/build/update/provision/manual) that deploys the whole system on every platform off a SMALL always-present MiOS-Repo shadow-config USB partition (the brain: mios.toml + configurator + Portal + MiOS-Cat + a small repos-clone) plus a SEPARATE MiOS-Data bulk store created only on 512 GB+ disks (the OCI tar, disk artifacts, model weights, package mirrors); owned by mios-bootstrap at cat/, with the deep medicat_installer nest flattened and de-duped. Read before touching any install/deploy entry point. -->
<!-- AI-related: C:\mios-bootstrap\cat\MiOS-Cat.{ps1,sh,bat}, C:\mios-bootstrap\Get-MiOS.ps1, C:\mios-bootstrap\bootstrap.ps1, usr/share/mios/mios.toml [cat]/[ai]/[editions]/[colors]/[portal], Justfile (all, vhdx-m), usr/share/doc/mios/adr/0005-sovereign-run-off-m-drive.md, usr/share/doc/mios/adr/0009-unified-config-surface.md -->
---
adr: 0008
title: MiOS-Cat unified entry point + repo minification
status: proposed
date: 2026-07-16
deciders: [operator, ai-pair]
tags: [entry-point, installer, ventoy, usb, offline, provisioning, minification, all-platform]
laws: [1, 7, 8, 9, 12]
ssot_keys: [cat, cat.repo_partition, cat.data_partition, cat.models, editions, ai.bake_models, ai.vllm.bake_model, colors]
related_ws: [WS-CAT, WS-CATREPO, WS-CATFLAT]
supersedes: []
superseded_by: []
---

# ADR-0008: MiOS-Cat unified entry point + repo minification

## Status
Proposed — 2026-07-16. Architecture accepted in principle; implementation is
PLANNED in waves (WS-CAT → WS-CATREPO → WS-CATFLAT). Flips to `accepted` on
operator sign-off of the open questions in the Consequences section. The
deployment *mechanisms* MiOS-Cat fronts (Hyper-V VHDX / WSL) are unchanged — they
remain ADR-0005; the shareable-link config surface it opens onto is ADR-0009.

## Context

MiOS has ~6 parallel install/deploy entry points, each partially overlapping and
none authoritative:

- `irm …/Get-MiOS.ps1 | iex` — the Windows web one-liner (`C:\mios-bootstrap\Get-MiOS.ps1`, ~411 KB).
- `irm …/bootstrap.ps1 | iex` and `curl …/bootstrap.sh | sh` — host bring-up.
- the UUP / autounattend Windows-ISO pipeline (`src\autounattend\{New-MiOSISO,mios-uup-fetch,New-MiOSAutounattend}.ps1`).
- the Fedora `mios-kickstart.cfg` (Ventoy-driven bare-metal).
- the `just` build (`C:\MiOS\Justfile` `build/raw/iso/qcow2/vhdx/wsl2/all`).
- the MiOS-Cat USB installer (`MiOS-Cat.{bat,ps1,sh}`).

Three concrete defects compound the sprawl:

1. **Double-track.** The MiOS-Cat tree is buried 3–5 levels deep at
   `src\autounattend\medicat_installer\` and is **byte-identical across both
   repos** (`C:\MiOS\…` and `C:\mios-bootstrap\…`) — a two-repo no-double-track
   violation, and a Law-1 problem because `C:\MiOS`'s tree *is* the deployed
   system root (`usr/` → `/usr`), so a host-side installer must not live under it.
2. **Dangling SSOT reads.** MiOS-Cat reads `..\..\..\..\mios.toml` (the 63 KB root
   seed copy, not the 597 KB SSOT `usr/share/mios/mios.toml`), and the keys it
   looks for — `drivepath`, `medicatver`, `cache_path` — **exist in no
   `mios.toml`**, so it silently falls back to hardcoded defaults (a Law 7 / Law 8
   violation hiding in plain sight).
3. **Payload confusion.** The USB `MiOS-Repo` partition today holds an ad-hoc mix
   (git repos + a Fedora ISO) with no clear model of what is mandatory vs
   large-disk-only, and the kickstart looks for repos at a path the stager never
   writes.

The operator directive: make MiOS-Cat the single preferred front door that
deploys everything, everywhere, offline-complete off a USB — with the **brain**
(the shadow-config) always present on a small partition and the **bulk** (images,
artifacts, model weights, package mirrors) only materialized when the disk is
large enough to hold it.

## Decision

1. **`mios-bootstrap` owns MiOS-Cat, canonically at `C:\mios-bootstrap\cat\`.**
   The `C:\MiOS\src\autounattend\medicat_installer\` duplicate is **deleted**
   (verified byte-identical; verify no live consumer first). `C:\MiOS` retains
   only this ADR, a generated root ADR breadcrumb, and the `[cat]` SSOT block that
   MiOS-Cat projects from. This honors Law 1 (the image tree is `/`; a host
   installer is not baked at `/usr`) and the two-repo rule (nothing double-tracked).

2. **One tri-launcher exposes six SSOT-projected verbs.**
   `MiOS-Cat.ps1` (Windows), `MiOS-Cat.sh` (Linux/WSL/bare-metal), and
   `MiOS-Cat.bat` (the WinPE/legacy-cmd shim) share one verb vocabulary —
   **`stage · install · build · update · provision · manual`** — over which every
   existing entry point becomes a *sub-system* (a verb back-end), not a peer. Each
   launcher is a thin dispatch; zero business logic is duplicated (shared
   `cat/lib/` PowerShell module + bash lib). The current interactive menu becomes
   the **no-verb default** (`cat` → menu; `cat install` → headless).

3. **`irm|iex` and `curl` are the same front door from two shells**, mutually
   delegating (Windows `.ps1` shells out to the `curl` path for a Linux/WSL
   target; the `.sh` invokes `pwsh`/`powershell.exe` for a Windows-side action).
   One name, one vocabulary, one SSOT, three shells — the Law 9
   (ONE-CANONICAL-NAME) closure applied to the entry surface.

4. **The USB carries a SMALL always-present MiOS-Repo (shadow-config) and, only on
   512 GB+ disks, a SEPARATE MiOS-Data bulk store.** This is the load-bearing
   re-scope of the earlier "Tier A / Tier B on one partition" sketch:

   - **`MiOS-Repo` (small, always) = the shadow-config brain.** It carries
     `mios.toml` (the SSOT), `mios.html` (the configurator), the **MiOS Portal**,
     **MiOS-Cat itself**, and a **small repos-clone** (the config/source, not the
     binary payload). This is the offline embodiment of the ADR-0009 shareable-link
     config surface — the same "open → configure → deploy" surface, on a stick.
     It stays small (target ~≤16 GB) and fits any USB.
   - **`MiOS-Data` (512 GB+ only, separate partition/store) = the bulk.** MiOS-Cat
     creates it **only** when `Get-Disk` reports ≥ 512 GB. It carries the ~78 GB
     `podman save` OCI tar (offline `podman load`), the `just all` disk artifacts
     (`raw/iso/qcow2/vhdx/wsl2`, incl. the ADR-0005 VHDX), the `mios.toml`-defined
     **model weights**, and the offline `dnf`/`flatpak`/`pip` **package mirrors**.
   - Ventoy-bootable ISOs/WIMs (`MiOS-Xbox.iso`, driver-injected `MiOS_PE.wim`,
     `Fedora-Server.iso`) stay on the Ventoy data partition, as today.

   Every fetch is **degrade-open**: try the network first, fall back to the USB
   (`git clone`→repos-clone; `podman pull`→`podman load`; `hf download`→copy from
   MiOS-Data; live dnf mirror→file:// mirror). `cat update` self-refreshes both
   stores when online and re-stamps a `manifest.json`.

5. **Deployment mechanisms delegate to ADR-0005; the config/API surface is
   ADR-0009.** `cat install --target hyperv` calls the ADR-0005 `just vhdx-m` +
   `deploy-mios-hyperv-m.ps1` verbatim; `cat install --target wsl` calls
   `just wsl2` + the `95-mios-wsl.preset` preview path. MiOS-Cat only *fronts*
   these — WS-MDRIVE stays the mechanism (`WS-CAT deps: [WS-MDRIVE]`). Every
   deployed target exposes the single `:8640/` front door (Portal + configurator +
   OpenAI `/v1`, ADR-0006 / ADR-0009).

6. **A `[cat]` SSOT block replaces the dangling reads; ADRs stay baked with a
   generated breadcrumb.** Add `[cat]` to `usr/share/mios/mios.toml`
   (`drivepath`, `medicatver`, `cache_path`, `repo_partition.label = "MiOS-Repo"`,
   `data_partition.label = "MiOS-Data"`, `data_partition.min_disk_gb = 128`,
   `models` = a reference to `[ai].bake_models`); repoint MiOS-Cat to resolve the
   real 597 KB SSOT. The ADRs stay **baked** under `/usr/share/doc/mios/adr/`
   (Law 1 — a running MiOS carries its own *why*); a generated `C:\MiOS\ADR.md`
   root breadcrumb + a `cat\ADR-0008.md` copy make the record discoverable near
   each repo root without moving it (Law 8, drift-checked).

## Rationale

- **Law 1 (USR-OVER-ETC) + the two-repo rule** force a host-side installer out of
  the image tree: `C:\MiOS/usr/` *is* `/usr` on the deployed host, so MiOS-Cat
  belongs in `mios-bootstrap`, and the byte-identical `C:\MiOS` copy is a pure
  liability. One owner is also the Law 9 closure — one canonical MiOS-Cat, one
  verb vocabulary.
- **Law 7 / Law 8 make the dangling reads a real bug, not cosmetics.** Silent
  hardcoded fallbacks for keys absent from any `mios.toml` are exactly what NO-
  HARDCODE + SSOT-PROJECTION forbid; the `[cat]` block gives every MiOS-Cat value
  a real SSOT home and a drift-check.
- **The small/bulk split is what makes "one stick, any computer" honest.** The
  brain (config + Portal + MiOS-Cat + a small clone) is tiny and belongs on every
  USB; the bulk (78 GB tar, disk artifacts, model weights, mirrors) is enormous
  and only fits — and is only worth carrying — on a large disk. Forcing both onto
  one "MiOS-Repo" tier either bloated every stick or left the small case broken.
  Separating them lets a 16 GB stick still deploy (network-degraded) while a
  512 GB+ stick is fully offline-sovereign.
- **Law 12 (BAKE-NOT-FETCH) realized as offline provisioning.** The OCI image
  bakes engines only (weights stay a-la-carte per ADR-0001/0002, keeping the image
  lean); MiOS-Data is the offline weight + package store, so `cat provision`
  brings a host up fully-featured with **zero network** — the sovereignty
  guarantee. The model weights are already declared in the SSOT (`[ai].bake_models`
  L5744/L6116, `[ai.vllm].bake_model` L6724, `[ai.sglang].bake_model` L6742) —
  `cat stage` reads them, never invents them (Law 8), and checksums them (the
  WS-SBOM / `38-llamacpp-prep.sh` resolved-not-hardcoded pattern).
- **ADR-0005 / ADR-0006 / ADR-0009 are fronted, not forked.** MiOS-Cat adds a
  unifying front door over the existing run-off-M: mechanism and the single
  `:8640/` surface; it does not re-implement or contradict them.

## Alternatives considered

- **Keep the entry points as peers.** Rejected — no single front door; this *is*
  the sprawl the directive removes.
- **Own MiOS-Cat in `C:\MiOS`.** Rejected — the image tree *is* `/`; a host
  installer must not live at `/usr` (Law 1), and it re-creates the double-track.
- **One "MiOS-Repo" partition carrying both the config brain and the 78 GB bulk
  (the original Tier A / Tier B sketch).** Rejected per operator reconciliation —
  it bloats every stick and couples the always-present shadow-config to a payload
  that only fits on large disks. The brain (small, always) and the bulk (MiOS-Data,
  512 GB+ only) are **separate stores**.
- **Bake MiOS-Cat into the image as an in-guest `mios cat` verb.** Rejected as the
  primary form — it is a host/bare-metal provisioner, not an in-guest tool — though
  the manual + ADRs it surfaces do stay baked.
- **Flatten but keep MediCat's i18n / bundled binaries.** Rejected — leave-nothing-
  behind: the Ventoy/7z/MediCat binaries are fetched-on-demand, not tracked.

## Consequences

Positive:
- One auditable front door; no cross-repo double-track; SSOT-clean (Laws 7/8/9).
- Offline-sovereign deploy (Law 12) with an honest small/large-disk story: a small
  stick still deploys (degrade-open); a 512 GB+ stick is fully offline.
- ADR-0005 / ADR-0006 / ADR-0009 unchanged (fronted, not forked).
- The USB becomes the offline embodiment of the ADR-0009 shareable-link surface —
  "a link + a stick + a computer" is the whole acceptance bar.

Negative / costs & open questions (gate the flip to `accepted`):
- Porting the advanced `.bat` logic (MiOS-Repo staging, WinPE DISM, self-update)
  into the canonical `.ps1` so the three launchers reach parity is real work.
- **Model redistribution** — may the `mios.toml` models (esp.
  `Qwen3-30B-A3B-Instruct-2507-AWQ`, ~16 GB, and the GGUFs) be redistributed on
  USB? HF licenses gate MiOS-Data; if not, it stores a *fetch manifest* + checksums
  instead of weights.
- **MiOS-Data contents on 512 GB+** — the 78 GB tar, the VHDX, *all* `just all`
  artifacts, or a chosen subset (M: budget considerations).
- **`mios.toml` canonicalization** — confirm the 63 KB root seed vs the 597 KB SSOT
  relationship before repointing.
- Deleting the `C:\MiOS` duplicate + bootstrap cruft must be verified free of live
  consumers first (the flatten-campaign guardrail).

## Implementation

- **Ownership + flatten (WS-CAT / WS-CATFLAT):** `git mv`
  `C:\mios-bootstrap\src\autounattend\medicat_installer\` → `C:\mios-bootstrap\cat\`;
  **delete** `C:\MiOS\src\autounattend\medicat_installer\`; move the Windows-ISO
  subsystem (`New-MiOSISO`/`mios-uup-fetch`/`New-MiOSAutounattend`/
  `Build-MiOSXboxISO`/`MiOS-Provision.lib`) to `cat\iso\`; collapse
  `Get-MiOS.ps1`/`bootstrap.{ps1,sh}`/`install.*` bodies to thin `cat install`
  shims (keep the published URLs).
- **Verbs (WS-CAT):** `cat/MiOS-Cat.{ps1,sh,bat}` dispatch over
  `stage/install/build/update/provision/manual`; shared `cat/lib/`; the `.bat`
  reduced to the WinPE shim.
- **`[cat]` SSOT (WS-CAT):** add `[cat]` to `usr/share/mios/mios.toml`
  (`drivepath`, `medicatver`, `cache_path`, `repo_partition.label`,
  `data_partition.label`, `data_partition.min_disk_gb = 128`, `models`); a new
  `automation/38-drift-checks.sh` check that the `[cat]`/`[colors]` reads resolve.
- **MiOS-Repo shadow-config (WS-CATREPO):** `cat stage` populates the small P3
  partition with `mios.toml` + `mios.html` + Portal assets + a self-contained
  MiOS-Cat copy + a small repos-clone; align the kickstart repo path to one
  canonical `MiOS-Repo/repos/`.
- **MiOS-Data bulk (WS-CATREPO):** gate on `Get-Disk` ≥ 512 GB; `podman save` the
  OCI image, copy the `just all` artifacts, fetch+checksum the models into
  `MiOS-Data/models/`, build `dnf`/`flatpak`/`pip` mirrors; `cat provision` copies
  weights to `/usr/share/mios/vllm/model` (+ the GGUF dir) offline (Law 12).
- **Delegation:** `cat install --target hyperv|wsl` calls the ADR-0005 `just
  vhdx-m` / `deploy-mios-hyperv-m.ps1` / `just wsl2` + `95-mios-wsl.preset`
  verbatim; the `:8640/` surface is ADR-0006 / ADR-0009.
- **Breadcrumb:** generate `C:\MiOS\ADR.md` + `cat\ADR-0008.md` from SSOT (Law 8);
  link from `llms.txt` / `AGENTS.md`.

## References

- ADR-0005 (Sovereign run-off-M: Hyper-V VHDX deployment) — the deployment
  mechanism MiOS-Cat fronts: `0005-sovereign-run-off-m-drive.md`.
- ADR-0006 (OpenAI-API-only AI contract) — the single `:8640` `/v1` front door
  every deployed target exposes: `0006-openai-api-only-ai-contract.md`.
- ADR-0009 (Unified config surface) — the shareable-link Portal + configurator +
  `/v1` surface at `:8640/` that the MiOS-Repo USB is the offline embodiment of:
  `0009-unified-config-surface.md`.
- ADR-0001 / ADR-0002 (bake groups / MiOS-Sys) — why weights stay a-la-carte and
  the image bakes engines only.
- SSOT: `usr/share/mios/mios.toml` — `[ai].bake_models` (L5744/L6116),
  `[ai.vllm].bake_model` (L6724), `[ai.sglang].bake_model` (L6742), `[editions]`
  (L10713+), `[colors]` (L8537), `[portal]` (L220); the proposed `[cat]` block.
- Entry points: `C:\mios-bootstrap\{Get-MiOS,bootstrap,install}.ps1`,
  `bootstrap.sh`, `MiOS-Cat.{bat,ps1,sh}`, `mios-kickstart.cfg`; `C:\MiOS\Justfile`
  (`all`, planned `vhdx-m`).
- Upstream mechanisms: Ventoy multiboot (`VTOYCLI /I`, `ventoy.json`); bootc
  `install to-disk` + bootc-image-builder; Anaconda kickstart; UUP Dump + DISM +
  `oscdimg`; `wsl --import`; dnf offline mirror (`reposync`+`createrepo_c`);
  `flatpak create-usb`; `pip download`/`bandersnatch`; Hugging Face hub;
  `podman save`/`load`.
- MiOS Laws 1/7/8/9/12: `usr/share/mios/mios.toml [laws]`, enforced by
  `automation/38-drift-checks.sh` + `automation/99-postcheck.sh` + `bootc container lint`.
