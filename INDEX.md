<!-- [NET] MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# INDEX.md  MiOS Universal Agent Hub

```json:knowledge
{
  "summary": "Single source of truth for AI agent architecture, laws, and conventions in MiOS. Indexes directory maps, instruction patterns, and research presets. Native OpenAI API protocol compatible.",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "AI",
    "Agent Hub",
    "Index",
    "OpenAI"
  ],
  "relations": {
    "depends_on": [
      ".env.mios",
      "ai-context.json"
    ],
    "impacts": [
      "INDEX.md",
      "INDEX.md",
      "INDEX.md",
      ".cursorrules",
      ".clinerules",
      ".windsurfrules"
    ]
  },
  "last_rag_sync": "2026-04-27T17:48:00Z",
  "version": "0.1.3"
}
```

> **Single source of truth** for every AI agent, LLM, copilot, and API operating in this repository.
> All provider entry files (`INDEX.md`, `INDEX.md`, `INDEX.md`, `.cursorrules`, `.windsurfrules`,
> `.clinerules`, `.github/copilot-instructions.md`) defer to this file for architecture laws and conventions.

## [NET] Live Documentation (CHECK FIRST)

**IMPORTANT:** This INDEX.md is a snapshot. **ALWAYS check the Wiki for current/updated information:**

- **Wiki Home:** https://github.com/Kabuki94/MiOS-bootstrap/wiki
- **Update Frequency:** Every build, push, and local build entry point
- **Purpose:** PRIMARY source for current tasks, research patterns, artifacts, and build logs

**Key Wiki Pages:**
- [Home](https://github.com/Kabuki94/MiOS-bootstrap/wiki/Home)  Latest version, quick start
- [AI Integration](https://github.com/Kabuki94/MiOS-bootstrap/wiki/AI-Integration-Index)  Current AI patterns
- [Quick Reference](https://github.com/Kabuki94/MiOS-bootstrap/wiki/Quick-Reference)  Essential commands
- [AI Agent Guide](https://github.com/Kabuki94/MiOS-bootstrap/wiki/AI-AGENT-GUIDE)  Hard rules, protected files
- [INDEX](https://github.com/Kabuki94/MiOS-bootstrap/wiki/INDEX)  This file (Wiki version)

**Bootstrap Repository:** https://github.com/Kabuki94/MiOS-bootstrap
- Artifacts: https://github.com/Kabuki94/MiOS-bootstrap/tree/main/ai-rag-packages
- Build Logs: https://github.com/Kabuki94/MiOS-bootstrap/tree/main/build-logs

**Workflow for New Tasks:**
1. Check Wiki for latest documentation and patterns
2. Read this INDEX.md for immutable architecture laws
3. Review relevant Wiki pages for current research
4. Proceed with task using latest information

## Project

MiOS is a **bootc-based, self-building, immutable workstation OS** on Fedora Rawhide.
One OCI image covers all hardware roles: desktop, k3s/HA, GPU passthrough (VFIO), WSL2.
Published at `$MIOS_IMAGE_NAME:latest`. Deployed systems update atomically via `sudo bootc upgrade`.
Sole proprietor: **MiOS-DEV**. Target: AMD Ryzen 9 9950X3D + NVIDIA RTX 4090, hardware-agnostic by design.

**Version History:** MiOS-1 (Fedora bootc + akmod drivers)  MiOS-2/v0.1.x (ucore-hci + pre-signed NVIDIA)  MiOS-NXT (future: Project Hummingbird integration, SBOM generation, minimal variants).

## [BUILD] Repository Directory Map (Rootfs-Native)

AI agents MUST use this map for context retrieval and navigation:

| Path | Purpose | Machine-Readable Manifest |
|---|---|---|
| `usr/` | System Binaries & Libraries (Immutable) | `usr/manifest.json` |
| `etc/` | System Configuration (Templates) | `etc/manifest.json` |
| `var/` | Mutable System State (Templates) | `var/manifest.json` |
| `home/` | User Home Directories (Persistent) | `home/manifest.json` |
| `specs/` | Architectural Blueprints & Research | `specs/manifest.json` |
| `automation/` | Build & Configuration Automation | `automation/manifest.json` |
| `evals/` | System Validation & Smoke Tests | `evals/manifest.json` |
| `identity.env.example` | User Identity SSOT | (Direct Read) |
| `.ai/foundation/memories/` | Shared AI Journal & Brain | `.ai/foundation/memories/manifest.json` |


##  Instruction Patterns

All agents MUST adhere to these operational patterns:

1. **Context First:** Always query `ai-context.json` to find the relevant manifest before reading files.
2. **Journaling:** Append every significant action/discovery to `.ai/foundation/memories/journal.md` using the [MiOS Journaling Protocol](specs/knowledge/research/2026-04-26-Artifact-KBX-022-AI-RESEARCH-TEMPLATE.md).
3. **Surgical Edits:** Use `replace` or `sed` for minimal changes to large files (especially `PACKAGES.md`).
4. **Validation:** No task is complete without automated verification (`just lint`, `just test`, or custom scripts).
5. **Secret Redaction:** Never output or commit secrets. Use placeholders like `INJ_PASSWORD` in templates.

## [RES] Research Presets (Upstream Targeting)

When researching or integrating upstream technologies, use these presets:

- **Target: bootc/fedora-bootc**
  - Priority Docs: `specs/knowledge/research/2026-04-26-Artifact-KBX-01-bootc-ecosystem-advances-2025-2026.md`
  - Pattern: Focus on "USR-OVER-ETC" and "NO-MKDIR-IN-VAR" laws.
- **Target: NVIDIA/GPU Passthrough**
  - Priority Docs: `specs/knowledge/research/2026-04-26-Artifact-KBX-10-vfio-gpu-passthrough-fedora-2025.md`
  - Pattern: Verify blacklist/unblacklist logic in `34-gpu-detect.sh`.

## [PLUG] Standardized Ingestion Protocol (OpenAI Native)

MiOS is optimized for OpenAI API standards and AI scrapers:

1. **`llms.txt` Standard:** High-density context ingestion point at root and `.well-known/`.
2. **Function Calling Schemas:** All automated tools (`tools/*.py`) and build scripts (`automation/*.sh`) are documented with clear input/output types compatible with JSON-based function calling.
3. **API Proxies:** Native bridge to OpenAI `/v1/chat/completions` protocol via `tools/openai-proxy.py` (Linux) or `agents/research/app/openai_proxy.py` (ADK sub-project).
4. **Seed Context:** New agents initialized in this workspace should immediately ingest `INDEX.md` and the latest RAG snapshot at `.ai/foundation/shared-tmp/latest-context.json.gz` to establish full structural awareness.


## [SYNC] Self-Updating Build Lifecycle

MiOS-DEV implements an autonomous documentation and artifact cycle triggered on every build entry point (Local, Windows, or Cloud):

1. **Entry Point Build**: A build is triggered (Cloud, Local, or platform-agnostic).
2. **Log Generation**: The master build runner (`automation/build.sh`) captures a deep technical log.
3. **Repo Snapshot**: The `artifact` target refreshes the UKB, RAG snapshot, and machine-readable manifests.
4. **Artifacting**: All build-time intelligence is packed into `.json.gz` and `.tar.gz` blobs in `artifacts/`.
5. **Wiki Push**: Documentation, task lists, and research results are automatically pushed to the [Repository Wiki](https://github.com/Kabuki94/MiOS-bootstrap/wiki) for real-time AI retrieval.

**Source Tracking:** https://github.com/Kabuki94/MiOS-bootstrap (Build Log & History)

---

## Build & Test

```bash
just build                                 # Build OCI image  localhost/mios:latest
just lint                                  # bootc container lint
just rechunk                               # Rechunk for Day-2 delta efficiency
just raw / just iso / just vhd / just wsl  # Disk image generation via BIB
just all                                   # Full pipeline: build  rechunk  images  push
just clean                                 # Remove output/ and local images
./evals/smoke-test.sh localhost/mios:dev   # Validate image (run after just build)
.\mios-build-local.ps1                    # Windows: 5-phase Podman Desktop build
```

## Architecture

### Build pipeline

The `Containerfile` has two stages:

1. **`ctx` stage**  `scratch` image assembling: `automation/`, `usr/share/mios/PACKAGES.md` (as `/ctx/PACKAGES.md`), `VERSION`, `config/`, `tools/`
2. **`main` stage**  applies system overlay via `08-system-files-overlay.sh`, then runs `automation/build.sh` (all `automation/[0-9][0-9]-*.sh` in order)

Scripts `18-`, `19-`, `20-`, `21-`, `22-`, `23-`, `25-`, `26-`, `37-` are called explicitly by the Containerfile *after* `build.sh` completes  do not also run them inside `build.sh`.

### Unified Manifest System (v0.1.3)

MiOS-DEV uses a multi-layered manifest system for AI agent awareness:
- **`root-manifest.json`**: Global map of root files and core scripts.
- **`ai-context.json`**: Entry point for agents; maps all sub-manifests (`usr/`, `etc/`, `specs/`, etc.).
- **`artifacts/manifest.json.gz`**: Machine-readable index of historical blobs and compressed research.

All packages declared in `usr/share/mios/PACKAGES.md` in fenced blocks:

````
```packages-<category>
package-name
another-package
```
````

Scripts install via `install_packages <category>` from `automation/lib/packages.sh`.
Never add packages outside this system.

### System files overlay

`` mirrors the root filesystem. **All system config lives here**  no top-level overlay
directories. Files are applied by `automation/08-system-files-overlay.sh`, which handles the
`/usr/local  /var/usrlocal` symlink present on ucore/FCOS bases.

## Immutable Appliance Laws

These are absolute. Any violation causes state drift, CI failure, or broken deployments.

1. **USR-OVER-ETC**  Never write static system config to `/etc/` at build time. Use `/usr/lib/<component>.d/`. `/etc/` is for user/admin overrides only.
2. **NO-MKDIR-IN-VAR**  Never `mkdir /var/...` in build scripts. Declare all `/var` dirs via `tmpfiles.d` (`d` or `C` directives) or `StateDirectory=` in unit files. `bootc container lint` (v1.1.6+) actively enforces this. Exception: `mkdir /var/home` is required when symlinking `/home` to prevent a dangling symlink in the OCI layer  document it clearly.
3. **MANAGED-SELINUX**  `semodule -i` **in a Containerfile `RUN` layer** is the correct primary method for custom SELinux modules (bootc v1.1.0 resolved historic instability). Fallback only: stage `.te` modules in `/usr/share/selinux/packages/` and load via `mios-selinux-init.service` for policies that cannot be compiled at build time.
4. **BOUND-IMAGES**  All primary Quadlet sidecar containers must be symlinked into `/usr/lib/bootc/bound-images.d/` for atomic updates via `bootc upgrade` (stable since v1.1.0). Only the `Image=` field is parsed by bootc; all other Quadlet fields are ignored by the bound-images mechanism.
5. **BOOT-SHIELDING**  Use `excludepkgs="shim-*,kernel*"` as a regression guard in `dnf` operations. Exception: with `rpm-ostree 2025.2+` and `/usr/lib/kernel/install.conf` containing `layout=ostree`, kernel upgrades via DNF are fully supported  do not exclude kernels in that case.
6. **NOVA-CORE-BLACKLIST**  On Fedora 44+ (kernel 6.15+), blacklist both `nouveau` **and** `nova_core`. The `nova_core` module was introduced in kernel 6.15 and conflicts with the proprietary NVIDIA driver if not blacklisted.
7. **BOOTC-CONTAINER-LINT**  `RUN bootc container lint` must be the final instruction in every Containerfile. Since v1.1.6 it enforces: single kernel present, valid kargs.d syntax, `/var` content has `tmpfiles.d` backing, correct kernel path, and other hygiene checks.
8. **NO-DNF-UPGRADE-UNCONDITIONAL**  Never `RUN dnf -y upgrade` without specifying package names. Use targeted `dnf install` or `dnf upgrade <package>` to maintain build reproducibility.
9. **UNIFIED-AI-REDIRECTS**  AI API integration MUST use agnostic environment variables (`MIOS_AI_KEY`, `MIOS_AI_MODEL`) and target the local proxy at `http://localhost:8080/v1` (FOSS-priority). Gemini and Claude specific patterns are supported via standard redirects documented in `specs/ai-integration/`.

## Hard Rules (build-breaking violations)

### kargs.d TOML  most common AI mistake

```toml
# Valid fields (flat TOML only  no section headers):
kargs = ["key=value", "flag"]
match-architectures = ["x86_64"]  # optional; Rust names: x86_64, aarch64, powerpc64  NOT amd64/arm64/ppc64le
```

Never: `[kargs]` section header  `delete =`  `delete_kargs =`  `kargs.append =`  `[[kargs]]`

`--karg-delete` exists as a **bootc CLI flag only**  it is not a TOML field. TOML files can only add kargs; deletion is a deployment-time CLI operation.

### Bash

- `set -euo pipefail` in all scripts; `build.sh` uses `set -uo pipefail` for per-script error tolerance
- `VAR=$((VAR + 1))` always  never `((VAR++))` (exits 1 when result=0, kills script under `set -e`)
- Never `dnf install kernel` or `dnf upgrade kernel` inside the container
- Never `--squash-all` on `podman build` (destroys layer structure required for bootc delta upgrades and composefs chunking)
- Quote all variables; use `read -r`; separate declaration from assignment for command substitutions

### GNOME / theming

- Never `GTK_THEME=Adwaita:dark`  for per-session debug use `ADW_DEBUG_COLOR_SCHEME=prefer-dark` (internal libadwaita var, not a public API). System-wide dark mode in the image must use a dconf profile drop-in: set `org.gnome.desktop.interface color-scheme prefer-dark` in `/etc/dconf/db/local.d/` with a corresponding lock file.
- `/etc/dconf/profile/user` and `/etc/dconf/profile/gdm` must exist
- Never put both `categories=` and `apps=` in a dconf app folder at the same time
- `xorgxrdp-glamor` only (`xorgxrdp` conflicts with it)
- `gnome-session-xsession` was removed in Fedora 43 (WaylandOnlyGNOME); GNOME 49+ disabled X11 session at compile time; GNOME 50 (Fedora 44) is Wayland-only  do not suggest it

### NVIDIA / VM gating

- NVIDIA blacklisted by default; unblacklisted only on bare metal via `34-gpu-detect.sh`. On Fedora 44+ (kernel 6.15+) also blacklist `nova_core`  it was added in kernel 6.15 and competes with the proprietary driver.
- Never ship `nvidia-drm.modeset=1` or `nvidia-drm.fbdev=1` unconditionally in kargs (gate to bare metal via `34-gpu-detect.sh`). Both remain required for Wayland on current drivers; future NVIDIA releases may enable them by default.

### PowerShell

- Never `Invoke-Expression` on downloaded content  write to temp file + `& $tmp.FullName` + remove
- Never empty `catch {}`
- Secrets via `Read-Host -MaskInput` or `[SecureString]`
- Push scripts must clone the existing repo  never `git init`

### Packages / Containerfile

- `usr/share/mios/PACKAGES.md` is the package SSOT  never regenerate wholesale
- The `gnome-core-apps` block must remain commented out
- COPY path for packages: `COPY usr/share/mios/PACKAGES.md /ctx/PACKAGES.md`

### Disk image generation

- Current `bootc-image-builder` uses a single config file mounted at `/config.toml`. ISO-specific settings go under `[customizations.iso]` within that file. Never mount multiple config files simultaneously (BIB crashes: "found config.json and also config.toml"). The `iso.toml` / `bib.toml` naming is obsolete  use `/config.toml` exclusively.
- `--type vhd` outputs VPC/VHD, **not VHDX**  always post-convert: `qemu-img convert -f raw -O vhdx -o subformat=dynamic disk.raw disk.vhdx`. Hyper-V targets require Gen 2 VMs (UEFI); Gen 1 (BIOS/MBR) is incompatible with bootc's EFI boot chain.
- No WSL2 tarball output from BIB (issue #172, open since 2024). WSL2 distribution is built via: `podman export $(podman create ghcr.io/kabuki94/mios:latest) -o mios.tar && wsl --import MiOS ...`

### Platform detection & runtime gating

Use `systemd-detect-virt 2>/dev/null || echo "none"` as the single authoritative platform detector in all scripts. Never add secondary detection paths unless systemd is unavailable.

| Platform | `systemd-detect-virt` value | Notes |
|---|---|---|
| Bare metal | `none` | Only safe context for `bootc upgrade` |
| Hyper-V VM | `microsoft` | DMI-distinguished from WSL2 |
| WSL2 | `wsl` | OCI container import  not bootc-managed |
| QEMU/KVM | `kvm` or `qemu` | virtio-gpu for display |
| Podman container | `container-podman` | Matches `container*` glob |
| Docker container | `container-docker` | Matches `container*` glob |

Fallback when systemd unavailable: `grep -qi microsoft /proc/version` (WSL2); `/.containerenv` (Podman); `/.dockerenv` (Docker).

**WSL2 law:** MiOS in WSL2 runs as a container-import distribution  `bootc upgrade` is non-functional and must be blocked in `wsl` and `container*` contexts. All upgrade scripts gate on `systemd-detect-virt` and print re-import instructions instead.

**bootc status API:** `bootc status --format=json` is the stable parseable interface. Never parse `bootc upgrade` stdout for automation  its text output is not a versioned API and changes across releases.

## Shared Memory System

| Path | Purpose |
|---|---|
| `.ai/foundation/memories/journal.md` | Episodic memory  timestamped log of all AI actions |
| `.ai/foundation/memory/` | Semantic memory  named `.md` files per topic |
| `.ai/foundation/shared-tmp/` | Scratchpad  transient cross-agent data |

All agents append to `journal.md` with timestamp + agent identity tag:

```
[2026-04-26T14:00:00Z] [AI: System Code] Analyzed automation/35-gpu-passthrough.sh  found...
```

## Machine-readable Context

| File | Purpose |
|---|---|
| `.ai-environment.json` | Workspace metadata (fonts, extensions, apps, version) |
| `ai-context.json` | Index of all docs, memories, scripts, manifests |
| `specs/audit/MiOS-Omni-Todo.html` | Unified HTML To-Do list for Users and Agents (append `<li>` before `<!-- TASK_END -->`) |
| `automation/ai-bootstrap.sh` | Regenerates manifests; initializes sub-project envs |

## Protected Files

Do not modify without explicit authorization from MiOS-DEV:

- `VERSION` and `CHANGELOG.md`  managed only via `push-to-github.ps1`
- `usr/share/mios/PACKAGES.md`  surgical edits only
- `.github/workflows/build-sign.yml` and `.github/workflows/build-artifacts.yml`
- `specs/memory/**`  AI semantic memory store

## Deliverable Contract

Complete replacement files only  no patches, no diffs, no "paste this into X". One push script:
`push-to-github.ps1` (clone  copy  commit  push). Never `git init`. Never push without human review.

## API & Client Surface

MiOS is OpenAI-API native. Any client that speaks the OpenAI REST protocol
(`/v1/chat/completions`, `/v1/responses`, `/v1/models`, `/v1/embeddings`)
targets a deployed MiOS host directly at `http://localhost:8080/v1`. The
filesystem mirror under `/v1/` exposes the same discovery surface for offline
tooling. No vendor-specific IDE plugin, agent SDK, or cloud provider is
required or assumed.

The reference inference backend is LocalAI (Quadlet `mios-ai.container`) with
drop-in compatibility for Ollama, vLLM, and llama.cpp via the same
OpenAI-compatible endpoint. Model weights live under `/srv/ai/`; model and
MCP discovery under `/usr/share/mios/ai/` and `/v1/`.

---
## Universal Knowledge Base (UKB)  RAG Protocols

MiOS uses a Unified Knowledge Base (UKB) for RAG and agent bootstrapping.

1. **RAG Snapshot:** `artifacts/repo-rag-snapshot.json.gz` contains a flattened, secret-redacted map of the entire repository, including environment configs and hidden dotfiles.
2. **Auto-Wiki:** The `specs/` folder is synchronized via `tools/sync-wiki.py` to reflect the current state of scripts and packages.
3. **Build Lifecycle:** Every `just build` (via the `artifact` target) refreshes the UKB and Wiki.
4. **Bootstrapping:** New agents should execute `./automation/ai-bootstrap.sh` to synchronize their local context with the UKB.

## Unified Environment Configuration (.env.mios)

All user-adjustable variables, including OCI images, account credentials, and Flatpak lists, MUST be consolidated in `.env.mios`.
- **Precedence:** `.env.mios` > root `.env` > script defaults.
- **Indexing:** This file is indexed by the UKB and serves as the single point of truth for deployment customization.
- **Security:** Plaintext passwords should be avoided; use SHA-512 hashes if possible.

## Knowledge Embedding Protocol (KEP)

To ensure all Markdown files are machine-parsable and referencable, they must include a `json:knowledge` block containing structured logic, summaries, and tags.

```json:knowledge
{
  "summary": "Brief description of the file's purpose.",
  "logic_type": "documentation | automation | configuration",
  "tags": [
    "tag1",
    "tag2"
  ],
  "relations": {
    "depends_on": [
      "path/to/dependency"
    ],
    "impacts": [
      "path/to/impacted/file"
    ]
  },
  "last_rag_sync": "2026-04-27T15:03:21.271935",
  "version": "0.1.3"
}
```
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
