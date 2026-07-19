<!-- AI-hint: The plan to unify every MiOS install path + configurator behind one native web
     entry and flatten the redundant loops. Grounded in the landscape map (Explore pass, this repo
     + C:\MiOS). Implement incrementally; each step keeps the existing entrypoints working. -->

# MiOS — Unified Native Installation + Configuration

**Goal:** one native web-pulled entry (`irm | iex` / `curl | bash`) that pulls everything and hands
into the single guided `mios-install` surface, which both installs *and* opens the MiOS Portal /
configurator — all reading/writing one SSOT. Flatten every redundant elevation / repo-fetch /
prereq-install / toml-resolution / redirector into one shared step.

## Where things are (map)

**Entrypoints (Windows):** `Get-MiOS.ps1` (the `irm|iex` web door, `-Action` router + Default
bootstrap → `bootstrap.ps1` → `build-mios.ps1`), `installation/mios-install.{ps1,sh,bat}` (guided
dispatcher), `cat/MiOS-Cat.bat` (USB flasher/menu hub), `build-mios.ps1` (MiOS-DEV builder).
**Linux:** `build-mios.sh` (canonical), `bootstrap.sh`/`install.sh` (redirectors → build-mios.sh).

**Portal + configurator = one app.** The Portal is routes inside the agent-pipe FastAPI
(`server.py`, `MIOS_PORT_AGENT_PIPE=8640`; `mios-agent-pipe.service`). `mios_pipe/routing/portal.py`
serves `/` (dashboard, embedded `_PORTAL_HTML`), `/configure` (Settings shell), `/portal/configurator`
(iframes on-disk `usr/share/mios/configurator/mios.html`), and `GET/POST /portal/config` (read/write).
`POST /portal/config` writes a **delta to the USER layer** `~/.config/mios/mios.toml` (`kernel/config.py`
`write_user_config`, atomic `os.replace`). `usr/libexec/mios/mios-configurator-launch` probes
`localhost:8640/configure` first, else the offline `~/Downloads/mios-configurator.html`.

**SSOT — 3× mios.toml, layered `vendor < host < user`** (resolver `usr/lib/mios/mios_toml.py`):
- `C:\MiOS\usr\share\mios\mios.toml` — **canonical VENDOR** SSOT (every derived surface + drift-gate reads this).
- `C:\MiOS\mios.toml` — curated root "edit me" subset (drift-gate 48: key-subset of canonical).
- `C:\mios-bootstrap\mios.toml` — Windows/`[cat]`/`[autounattend]` copy (drift-gate 22: `[ports]` parity).

## The redundancy to flatten

| Redundant work | Today | Target |
|---|---|---|
| UAC self-elevate | 4 impls (Get-MiOS, MiOS-Cat.bat, mios-install, build-mios) | ONE shared `Test/Invoke-Elevate` |
| Repo fetch/clone | 6 paths, 2 targets (`M:\MiOS\repo\mios-bootstrap` vs `C:\mios-bootstrap`) | ONE fetch, ONE canonical checkout |
| Prereq install | Get-MiOS (winget), build-mios (WSL/podman), MiOS-Cat (7z), Xbox (DISM) | ONE resolver keyed off the chosen target |
| mios.toml resolve | 5 hand-rolled PS resolvers, different search orders | ONE layered resolver (PS port of `mios_toml.py`) |
| Bootstrap redirectors | `bootstrap.ps1`, `install.ps1`, `bootstrap.sh`, `install.sh` all → build-mios | collapse to ONE canonical entry per OS |
| Guided menus | `mios-install` catalog **and** MiOS-Cat.bat menu; MiOS-Cat.bat even re-runs `irm Get-MiOS\|iex` (a loop back to the web door) | `mios-install` is the ONLY guided surface; MiOS-Cat.bat becomes the **flash executor only** |

## Target flow

```
irm .../mios | iex   (Windows)   /   curl .../mios | bash   (Linux)
  └─ ONE bootstrap, shared steps EXACTLY ONCE:
       agreement → elevate → repo-fetch → prereq(target) → SSOT-resolve
  └─ hands into  installation/mios-install.{ps1,sh}   (the single guided surface)
       flash/live → cat/MiOS-Cat.bat   (flash executor only; no self-update, no web re-entry)
       oci/build  → build-mios.{ps1,sh}
       xbox       → cat/autounattend/*.ps1
       configure  → Portal/configurator @ :8640/configure   (the one SSOT editor)
```

## Steps (incremental; each keeps things working)

1. **[DONE] `configure` target in `mios-install`** — the guided installer now opens the Portal /
   configurator (`:8640/configure`, else MiOS-DEV launcher, else offline HTML). One surface for
   install **and** config.
2. **[DONE] Shared `installation/mios-common.ps1` + `.sh`** — the ONE contract: layered SSOT
   resolver (`Get-MiosSsotValue` / `mios_ssot_value`, `user > host > vendor`, same order as
   `mios_toml.py`), SSOT-`[colors]` themed console/logger, `Test/Invoke-Elevate` +
   `mios_self_elevate`, and `Ensure-MiosRepo` / `mios_ensure_repo`. Both `mios-install.ps1` and
   `mios-install.sh` now source it and keep only their guided/dispatch surface (the two files each
   shed ~40 lines of duplicated theme/elevation/resolver code). Verified: parse + all-target
   dry-runs green in pwsh7 + WPS5.1 + Git-Bash. **Next:** migrate `Get-MiOS.ps1`, `build-mios.{ps1,sh}`,
   and `MiOS-Cat.bat` to source the same contract (one at a time, each re-tested).
3. **Break the loops in `MiOS-Cat.bat`** — drop the self-update `git pull` + the `irm Get-MiOS|iex`
   re-entry (line ~476); it calls the local `build-mios` directly. It becomes the flash executor.
4. **Collapse redirectors** — `bootstrap.ps1`/`install.ps1`/`bootstrap.sh`/`install.sh` become thin
   aliases of the one web door (or are removed once the door hands into `mios-install`).
5. **One canonical checkout path** — pick one (`C:\mios-bootstrap`), retire `M:\MiOS\repo\...`.
6. **SSOT consolidation** — keep vendor canonical; generate the two repo copies from it at build
   (they are projections, not hand-edited), so the ~7× drift can't recur. Portal keeps writing the
   user layer. Nothing hand-maintains three copies.
