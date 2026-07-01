# MiOS App (scaffold)

> Status: **scaffold only** — no working implementation yet. This directory
> exists so the shape of the future component is tracked in git and future
> syncs/design work have somewhere to land. See `RESEARCH.md` for the
> build-approach feasibility research behind the notes below.

## What MiOS App is for

MiOS App is the future artifact an operator pulls to either:

1. **Deploy MiOS locally** — a client-side entry point equivalent to
   `Get-MiOS.ps1`/`build-mios.sh`, packaged as an app instead of a
   paste-and-run script, or
2. **Connect as a MiOS client to the cluster VPN** — join an existing MiOS
   cluster (the k3s+Ceph one-node-or-more path described in the system repo)
   as a remote peer over WireGuard, without running a full local bootstrap.

Both jobs share the same deployment backend and bootstrapping methods this
repo already owns (`install.sh`/`install.ps1`, the three-layer `mios.toml`
overlay, the Phase 0–4 model) — MiOS App is a new *front end* onto that
existing pipeline, not a second implementation of it.

## Why it lives in `mios-bootstrap`, not `mios`

Per this repo's identity: `mios.git` owns the system FHS overlay (what MiOS
*is*); `mios-bootstrap.git` owns the installer and user-facing layer (*how
an operator gets onto it*). MiOS App is squarely the latter — another way in,
alongside the existing PowerShell/bash entry points — so it belongs here.

## Current scope of this scaffold

- `README.md` (this file) — purpose and roadmap.
- `RESEARCH.md` — feasibility research on one candidate build approach for a
  future "hybrid IDE/browser" surface (kept separate from the VPN-client and
  local-deploy jobs above, which don't depend on that choice).

No code, no `mios.toml` wiring beyond the placeholder `[mios_app]` section
(see below), and no `mios` verb yet — those are follow-up work once the
approach below is actually chosen and scoped.

## Roadmap (not yet started)

1. Decide the actual client shape needed for "local deploy" and "VPN client"
   — these may not require the same UI surface; scope them independently
   before picking a tech stack for either.
2. If a rich desktop/browser-style shell is wanted for the "AIO surface"
   idea, revisit `RESEARCH.md`'s verdict (prebuilt Zen/Firefox + chrome
   customization, not a from-source Gecko fork) before committing engineering
   time.
3. Wire whichever client into the existing `mios.toml` SSOT and, if it grows
   a CLI surface, the `mios <verb>` dispatcher (`build-mios.ps1`) as a new
   verb — following the existing TOML-first, no-hardcoding conventions.
4. Only then write implementation code under this directory.

## `mios.toml` placeholder

A `[mios_app]` section exists in `mios.toml` at the repo root, gated
`enabled = false`. It carries no behavior yet — it's there so future
operator-tunable fields (VPN endpoint, client mode, etc.) have a
conventions-compliant home to land in without a later hardcoding cleanup.
