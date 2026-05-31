# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Canonical agent prompt: `AGENTS.md` (this repo's agents.md-standard entry) → `/usr/share/mios/ai/system.md` (deployed vendor canonical).

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override, deployed by bootstrap).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## Claude Code deltas

* **cwd:** `/` IS the repo root AND system root on a deployed host. Bootstrap files map directly to FHS destinations — `etc/` → `/etc/`, `usr/` → `/usr/`. Don't treat `/` as dangerous.
* **Confirm before:** `git push`, `bootc switch`, `dnf install`, `systemctl`, `rm -rf`, `git reset --hard`, `git clean -fd`, `wsl --unregister`, `podman machine rm`, `Remove-Partition`.
* **Deliverables:** complete replacement files only — no diffs, no patches, no `# ... rest unchanged ...` placeholders.
* **Memory:** `/var/lib/mios/ai/memory/`
* **Scratch:** `/var/lib/mios/ai/scratch/`
* **Tasks:** use the task tool for multi-step work; one in-progress at a time.

## Repo identity

This repo is the **interactive installer and user-editable layer** of MiOS. It owns AI files (`usr/share/mios/ai/`), knowledge graphs, user profile templates, and all installer scripts. It does **not** own the system FHS overlay, Containerfile, systemd units, Quadlets, kernel args, tmpfiles, or sysusers — those live in `mios.git`. Never double-track paths across the two repos.

## Entry points

```powershell
# Windows — canonical irm|iex (Win+R)
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
```

```bash
# Linux — canonical curl|bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh)"
```

### `mios` verb dispatcher (Windows host, after bootstrap)

```powershell
mios dash      # dashboard (fastfetch + MOTD)
mios config    # open mios.html configurator in local browser
mios update    # git pull on mios.git + mios-bootstrap
mios build     # promote Downloads edits → SSH into MiOS-DEV → ignite pipeline
mios dev       # drop into MiOS-DEV shell
mios help      # verb list
```

Each prompt auto-accepts its `mios.toml` default after **90 seconds**. Override with `MIOS_PROMPT_TIMEOUT=` (seconds; `0` = wait forever, `1` = fastest unattended).

## Phase model (0..4)

| Phase | Owner | Purpose |
|---|---|---|
| 0 | `mios-bootstrap` | Preflight, profile load (3-layer overlay), interactive identity capture |
| 1 | `mios-bootstrap` | **Total Root Merge** — `git clone mios.git /`, overlay `etc/`, `usr/`, `var/` on top |
| 2 | `mios` | Build — `dnf install` from `[packages]` SSOT, or `bootc switch ghcr.io/mios-dev/mios:latest` |
| 3 | both | `systemd-sysusers`, `systemd-tmpfiles`, `daemon-reload`, services, per-user `~/.config/mios/` seeding |
| 4 | `mios-bootstrap` | Reboot |

**`.git` IS `/` is the load-bearing premise.** Phase-1's Total Root Merge makes it so. Edits to `/` on a running MiOS host are edits to the source; the next `bootc upgrade` bakes them.

## `mios.toml` — the singular SSOT

Every operator-tunable value in the entire pipeline lives in `mios.toml`. Hardcoded values that could be in the TOML are bugs — lift them, expose them in `mios.html`, then read from the layered overlay.

### Three-layer resolution (highest wins)

```
~/.config/mios/profile.toml      # per-user (seeded from /etc/skel)
/etc/mios/profile.toml           # host/admin
/usr/share/mios/profile.toml     # vendor defaults (lowest)
```

`install.sh:resolve_profile_layers` walks all three and field-level overlays them. **Empty strings do NOT override non-empty values below.** Empty user TOML is the vendor-default state, not an error.

### Edit-save-fetch lifecycle

1. Operator opens `mios.html` in a local browser (`file://` works — no server needed).
2. Configurator writes updated TOML to `%USERPROFILE%\Downloads\mios.toml` (Windows) or `~/.config/mios/mios.toml` (Linux).
3. `mios build` promotes the newest `mios*.toml` from Downloads to `M:\etc\mios` + `M:\usr\share\mios` and archives the source as `.imported-<timestamp>` **before** running `mios-pull --hard`, so operator edits are never clobbered.

## Windows bootstrap architecture (`Get-MiOS.ps1`)

Contract: **one paste, one shot, no follow-up step.** The script:

1. Self-cache-busts (Fastly 5-min TTL on `raw.githubusercontent.com`).
2. Full reset — reaps prior MiOS state: temp clones, WSL distros (`MiOS`, `MiOS-DEV`, `podman-MiOS-DEV`, `MiOS-BUILDER`), podman machines, Hyper-V `MiOS-*` VMs, install dirs, Start Menu shortcuts.
3. Two-pass self-elevation — Pass 1 (user): WT + Geist Mono Nerd Font + oh-my-posh + fastfetch + native-app shortcut. Pass 2 (admin): disk + machines.
4. Provisions `M:\` at exactly **256 GB NTFS** (label `MIOS-DEV`). Junctions all candidate podman-machine storage paths onto `M:\podman\machine\*` before any `podman` command.
5. Clones to `M:\MiOS\repo\{mios,mios-bootstrap}`.
6. Provisions `podman-MiOS-DEV` machine.
7. **Stops** — prints hint banner. Build is operator-triggered via `mios build`.

Windows Terminal profiles:

| Profile | Command | Notes |
|---|---|---|
| **MiOS** | `pwsh.exe` → MiOS PS profile | `mios <verb>` dispatcher; verbs `build`/`dev` hand off to MiOS-DEV via `wsl.exe` |
| **MiOS-DEV** | `wsl.exe -d <BuilderDistro> --user mios` | Direct dev-VM shell |

Do **not** bind the MiOS profile directly to `wsl.exe` — that hits `WSL_E_DISTRO_NOT_FOUND`. Locked names: `MIOS_WSL_DISTRO=MiOS`, `MIOS_BUILDER_DISTRO=MiOS-DEV`. Every spawned window opens at **80 × 40** (`wt.exe --size 80,40`).

## MiOS-DEV is THE builder

All build operations (`podman build`, BIB, `bootc switch`, manifest gen) run **inside** `podman-MiOS-DEV`. Windows is provisioning + handoff only. `MiOS-DEV ≡ MiOS` in runtime surface — it runs every Quadlet container that ships in production.

## AI stack (endpoint contract)

`http://localhost:8080/v1` via the `mios-ai.container` Quadlet (LocalAI). Every client resolves through `MIOS_AI_ENDPOINT`, `MIOS_AI_MODEL`, `MIOS_AI_KEY`. **No vendor-cloud URLs. No vendor-specific agent names anywhere.**

Default model auto-selection from `[ai.host_thresholds]`:

| Host RAM | Model |
|---|---|
| ≥ 32 GB | `qwen3.5:14b` |
| ≥ 12 GB | `qwen3.5:2b` (vendor default) |
| < 12 GB | `phi4-mini:3.8b-q4_K_M` |

AI files owned by this repo:

| Path | Purpose |
|---|---|
| `usr/share/mios/ai/system.md` | Vendor canonical system prompt |
| `usr/share/mios/ai/models.json` | OpenAI `/v1/models` catalog |
| `usr/share/mios/ai/mcp.json` | MCP server registry |
| `usr/share/mios/knowledge/` | RAG knowledge graphs |
| `etc/mios/ai/config.json` | Inference config (base_url, models) |
| `etc/skel/.config/mios/system-prompt.md` | Per-user prompt template (seeded on first login) |
| `/var/lib/mios/ai/memory/` | Episodic journal (JSONL) — runtime, not committed |
| `/var/lib/mios/ai/scratch/` | Transient working dir — runtime, not committed |

## User-space templates (`etc/skel/`)

Seeded into every uid ≥ 1000 home by Phase-3 (`seed_user_skel_for_all_accounts`):

* `~/.config/mios/profile.toml` — per-user TOML override template
* `~/.config/mios/system-prompt.md` — per-user AI prompt template
* `~/.config/aichat/config.yaml` — aichat CLI config

## Operator behavioural rules (binding on every Claude session)

### TOML-first

Before adding a constant to a script, check whether it's operator-tunable. If yes: add it to `mios.toml`, expose it in `mios.html`, read it from the layered overlay. Never hardcode a value that belongs in the TOML.

### OpenAI-API-only

Never reference vendor-specific agent CLIs, dev-tool products, or cloud-AI URLs in MiOS docs, code, or commit messages. The OpenAI public API surface (`/v1/chat/completions`, `/v1/responses`, `/v1/embeddings`, `/v1/models`, function-calling, structured outputs, MCP via Responses API) is the only addressable contract.

### Latest packages

Default to newest stable upstream when pinning RPMs, OCI tags, binaries, or base images. Bump conservative pins forward on next touch unless held for a documented reason.

### Every artifact is tracked

When generating any file in this repo, add a `.gitignore` whitelist line, stage, commit, push. `git pull` must restore full context.

### No double-tracking

`mios.git` owns system FHS overlay. `mios-bootstrap.git` owns the user-facing installer. Never cross-track paths between them.

### Persistence sanitization

Before writing to `/var/lib/mios/ai/memory/` or `scratch/`: strip vendor-specific names, drop chat metadata (`user-id`, `session-id`), reduce paths to FHS canonicals, never persist secrets.
