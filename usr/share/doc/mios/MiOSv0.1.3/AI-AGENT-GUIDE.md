# AI-AGENT-GUIDE.md

This file provides guidance to AI coding agents when working with code in this repository.

## 🌐 Live Documentation (CHECK FIRST)

**IMPORTANT:** This guide is a snapshot. **ALWAYS check the Wiki for current/updated information:**

- **Wiki:** https://github.com/MiOS-DEV/MiOS-bootstrap/wiki
- **Updates:** Every build, push, and local build entry point
- **Wiki Discovery Guide:** [specs/ai-integration/2026-04-27-Artifact-AI-005-Wiki-Discovery.md](specs/ai-integration/2026-04-27-Artifact-AI-005-Wiki-Discovery.md)

**Essential Wiki Pages:**
- [Home](https://github.com/MiOS-DEV/MiOS-bootstrap/wiki/Home) — Latest version, artifacts
- [AI Agent Guide](https://github.com/MiOS-DEV/MiOS-bootstrap/wiki/AI-AGENT-GUIDE) — This file (Wiki version)
- [Quick Reference](https://github.com/MiOS-DEV/MiOS-bootstrap/wiki/Quick-Reference) — Current commands
- [Build Logs](https://github.com/MiOS-DEV/MiOS-bootstrap/tree/main/build-logs) — Recent build outputs

**Workflow:**
1. Check Wiki for latest procedures and patterns
2. Use this guide for immutable laws (they don't change)
3. Cross-reference for accuracy

## Project

MiOS is a **bootc-based immutable workstation OS** on Fedora Rawhide. One OCI image covers all hardware roles: desktop, k3s/HA, GPU passthrough (VFIO), WSL2. Published at `ghcr.io/kabuki94/mios:latest`. Deployed systems update atomically via `sudo bootc upgrade`. Sole proprietor: **MiOS-DEV**.

## 🔄 Self-Updating Build Lifecycle

MiOS-DEV implements an autonomous documentation cycle on every build entry point:

1. **Entry Point Build**: Build triggered (Cloud or Local).
2. **Log Generation**: `automation/build.sh` captures technical output.
3. **Repo Snapshot**: Refreshes UKB, RAG snapshot, and manifests.
4. **Artifacting**: Packs intelligence into `artifacts/`.
5. **Wiki Push**: Documentation and research are automatically pushed to the [Repository Wiki](https://github.com/MiOS-DEV/MiOS-bootstrap/wiki) for real-time retrieval.

**Source Tracking:** https://github.com/MiOS-DEV/MiOS-bootstrap (Build Log & History)

## Commands

```bash
just build                                  # Build OCI image → localhost/mios:latest
just lint                                   # bootc container lint (runs inside image)
just test                                   # mios-test --quick inside the image
just rechunk                                # Rechunk for Day-2 delta efficiency
just raw / just iso / just vhd / just wsl   # Disk image generation via BIB
just boot-test                              # QEMU boot validation (requires nested virt)
just all                                    # Full pipeline: build → rechunk → images → push
just clean                                  # Remove output/ and local images
./evals/smoke-test.sh localhost/mios:latest # Full smoke test after build
./automation/ai-bootstrap.sh               # Regenerate all manifests, UKB, Wiki
.\mios-build-local.ps1                     # Windows: 5-phase Podman Desktop build
```

`just build` automatically runs `./automation/ai-bootstrap.sh` first (the `artifact` dependency).

## Architecture

### Build Pipeline

The `Containerfile` has two stages:

1. **`ctx` stage** — Assembles a `scratch` image from: `automation/`, `usr/`, `etc/`, `var/`, `home/`, `specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md` (mounted as `/ctx/PACKAGES.md`), `VERSION`, `config/artifacts/`, `tools/`

2. **`main` stage** — Runs `08-system-files-overlay.sh`, then `automation/build.sh` (executes all `automation/[0-9][0-9]-*.sh` scripts in order), then explicitly calls these post-build scripts in the Containerfile: `18-`, `19-`, `20-fapolicyd-trust`, `21-`, `22-`, `23-`, `25-`, `26-`, `37-ollama-prep`

**Critical:** Those post-build scripts are called by the Containerfile *after* `build.sh` completes — `build.sh` skips them to prevent double-execution. Do not add them inside `build.sh`.

### Package System

All packages are declared in `specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md` in fenced blocks:

````
```packages-<category>
package-name
```
````

Scripts install them via `install_packages <category>` from `automation/lib/packages.sh`. Never add packages outside this system. The `gnome-core-apps` block must remain commented out.

### System Files Overlay

`usr/`, `etc/`, `var/`, `home/` at the repository root mirror the target root filesystem. **All system config lives here.** Applied by `automation/08-system-files-overlay.sh`, which handles the `/usr/local → /var/usrlocal` symlink present on ucore/FCOS bases.

### Automation Scripts

Scripts in `automation/` are numbered `NN-name.sh` and execute in order. `automation/lib/common.sh` provides shared helpers (`log`, `warn`, `die`), DNF flags (`$DNF_BIN`, `$DNF_SETOPT`, `$DNF_OPTS`), and masking. `automation/lib/packages.sh` provides `install_packages`, `install_packages_strict`, `install_packages_optional`, and `get_packages`.

### Configuration

All user-adjustable variables live in `.env.mios` (precedence: `.env.mios` > `.env` > script defaults). Build-time user provisioning uses `--build-arg` (MIOS_USER, MIOS_PASSWORD_HASH, MIOS_HOSTNAME, MIOS_FLATPAKS); these are read by `31-user.sh` and do not persist into the final image.

## Immutable Appliance Laws

These are absolute — violations cause state drift, CI failure, or broken deployments:

1. **USR-OVER-ETC** — Never write static system config to `/etc/` at build time. Use `/usr/lib/<component>.d/`. `/etc/` is for admin overrides only.
2. **NO-MKDIR-IN-VAR** — Never `mkdir /var/...` in build scripts. Declare all `/var` dirs via `tmpfiles.d` (`d` or `C` directives).
3. **MANAGED-SELINUX** — `semodule -i` in a Containerfile `RUN` layer is the primary method for custom modules (stable since bootc v1.1.0). Fallback: stage in `/usr/share/selinux/packages/` for complex cases.
4. **BOUND-IMAGES** — All Quadlet sidecar containers must be symlinked into `/usr/lib/bootc/bound-images.d/`.
5. **BOOT-SHIELDING** — All `dnf` operations must use `excludepkgs="shim-*,kernel*"`.
6. **UNIFIED-AI-REDIRECTS** — Use agnostic variables (`MIOS_AI_KEY`, `MIOS_AI_MODEL`) and the local proxy (`http://localhost:8080/v1`).

## Hard Rules

### kargs.d TOML

```toml
# Only valid format:
kargs = ["key=value", "flag"]
```

Never: `[kargs]` section header · `delete =` · `delete_kargs =` · `kargs.append =` · `[[kargs]]`

### Bash

- `set -euo pipefail` in all scripts; `build.sh` uses `set -uo pipefail` for per-script tolerance
- `VAR=$((VAR + 1))` always — never `((VAR++))` (exits 1 when result=0, kills script under `set -e`)
- Never `dnf install kernel` or `dnf upgrade kernel` inside the container
- Never `--squash-all` on `podman build` (strips OCI metadata bootc requires)
- Quote all variables; use `read -r`; separate declaration from assignment for command substitutions

### GNOME / Theming

- Never `GTK_THEME=Adwaita:dark` — use `ADW_DEBUG_COLOR_SCHEME=prefer-dark`
- `/etc/dconf/profile/user` and `/etc/dconf/profile/gdm` must exist
- Never put both `categories=` and `apps=` in a dconf app folder simultaneously
- `xorgxrdp-glamor` only (`xorgxrdp` conflicts); `gnome-session-xsession` does not exist in Fedora

### NVIDIA / VM Gating

- NVIDIA blacklisted by default; unblacklisted only on bare metal via `34-gpu-detect.sh`
- Never ship `nvidia-drm.modeset=1` or `nvidia-drm.fbdev=1` unconditionally in kargs

### Disk Image Generation

- ISO builds use `iso.toml` exclusively — never mount both `iso.toml` and `bib.toml` simultaneously (BIB crashes: "found config.json and also config.toml")

### PowerShell

- Never `Invoke-Expression` on downloaded content — write to temp file, execute, remove
- Push scripts must clone the existing repo — never `git init`

## Protected Files

Do not modify without explicit authorization from MiOS-DEV:

- `VERSION` and `CHANGELOG.md` — managed only via `push-to-github.ps1`
- `specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md` — surgical edits only; never regenerate wholesale
- `.github/workflows/build-sign.yml` and `.github/workflows/build-artifacts.yml`
- `specs/memory/**` — AI semantic memory store

## Shared AI Memory

| Path | Purpose |
|---|---|
| `.ai/foundation/memories/journal.md` | Episodic log — append every significant action with timestamp + `[AI: Agent]` tag |
| `.ai/foundation/memory/` | Semantic memory — named `.md` files per topic |
| `.ai/foundation/shared-tmp/` | Transient cross-agent scratchpad |

Journal entry format: `[2026-04-27T00:00:00Z] [AI: Agent] <action> — <finding>`

## Key Context Files

| File | Purpose |
|---|---|
| `ai-context.json` | Index of all docs, memories, scripts, manifests — query before reading files |
| `.ai-environment.json` | Workspace metadata (extensions, fonts, apps, version) |
| `specs/audit/MiOS-Omni-Todo.html` | Unified task list — append `<li>` before `<!-- TASK_END -->` |

## Deliverable Contract

Deliver complete replacement files only — no patches, diffs, or "paste this into X". Push via `push-to-github.ps1` (clone → copy → commit → push). Never push without human review.
