<!-- [NET] MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# [NET] MiOS

```json:knowledge
{
  "summary": "Primary overview and entry point for the MiOS operating system project.",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "Overview",
    "Cloud-Native"
  ],
  "relations": {
    "depends_on": [
      ".env.mios"
    ],
    "impacts": []
  },
  "last_rag_sync": "2026-04-28T06:00:00.000000",
  "version": "MiOSv0.1.4"
}
```

> **Proprietor:** MiOS-DEV
> **Infrastructure:** Self-Building Infrastructure (Personal Property)
> **License:** Licensed as personal property to MiOS-DEV
---
# [NET] MiOS: Immutable Cloud-Native Workstation

```json
{
  "status": "Production Stable",
  "baseline": "v0.1.4",
  "kernel": "Fedora Rawhide (OCI-Mode)",
  "build": "just all",
  "last_sync": "2026-04-28T06:00:00.000000"
}
```

---

## [START] Quick Deployment - Linux Filesystem Native

MiOS deploys as a **native Linux application** on minimal Fedora Server using the **automated bootstrap script**:

### One-Liner Installation (Recommended)

```bash
# Fedora Server bootstrap - clones, installs, configures, and builds
curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/build-mios.sh | sudo bash
```

**What it does:**
1. ✅ Clones repository from GitHub
2. ✅ Installs to FHS directories (merge-only, no deletions)
3. ✅ **Prompts for user configuration** (interactive)
   - Username (default: mios)
   - Password (SHA-512 hashed)
   - Hostname (default: mios)
   - Base image selection (NVIDIA/No NVIDIA/Minimal/Custom)
   - Flatpak applications
   - AI configuration (optional)
4. ✅ **Automatically initializes user-space** (no separate command needed)
   - Creates user accounts with full group memberships (wheel, libvirt, kvm, video, render, docker)
   - Sets up XDG-compliant directories (~/.config/mios, ~/.local/share/mios, ~/.cache/mios)
   - Creates configuration files (env.toml, images.toml, build.toml, flatpaks.list, ai.env)
   - Initializes Python virtual environment (~/.local/share/mios/venv)
   - Sets up dotfiles directory (~/.config/mios/dotfiles/)
   - Creates credentials directory with .gitignore (~/.config/mios/credentials/)
5. ✅ Optionally builds MiOS OCI image

### Manual Installation

```bash
# 1. Clone repository
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios

# 2. Run bootstrap installer (handles everything)
sudo ./build-mios.sh
```

**Note:** `build-mios.sh` is the **automated entry script** that integrates `install.sh` and user-space initialization. No separate `mios init-user-space` command is needed.

**Installs to:**
- `/usr/share/mios/` - Application data (scripts, templates, source)
- `/usr/bin/mios*` - Command binaries
- `/usr/libexec/mios*` - Internal executables
- `/etc/mios/` - System configuration templates
- `/var/lib/mios/` - Build artifacts and snapshots
- `/var/log/mios/` - Build logs
- `~/.config/mios/` - User configuration (XDG-compliant)
- `/etc/skel/` - User skeleton files

**See:** [DEPLOY.md](DEPLOY.md) for complete deployment guide

---

## [NET] Overview
MiOS is a container-native, mathematically verifiable workstation operating system. Built for high-performance virtualization (VFIO), hardware agnosticism, and zero-trust security, it transforms the host OS into a cryptographically sealed OCI payload.

### [SEC] Core Mandates
- **Naked Core:** Minimalist base OS; applications reside in sandboxes (Flatpak/Distrobox).
- **Atomic Reliability:** Transactional image swaps with autonomous rollbacks.
- **Hardware Agnostic:** Optimized drivers for Intel, AMD, and NVIDIA.

---

## [BUILD] Build Entry Points

Depending on your environment, use one of the following primary entry points to build and deploy MiOS:

###  Linux / WSL2 (One-Liner)
Bootstraps the environment, clones the latest repository, and initiates the build process.
```bash
curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.sh | bash
```

###  Windows 11 (One-Liner)
One-click repository fetch and max-resource environment setup. **Run as Administrator.**
```powershell
irm https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.ps1 | iex
```

###  [Justfile](Justfile) (Unified Runner)
The recommended entry point for developers with the repository already cloned.
```bash
just build    # Synthesis OCI image
just wsl      # Generate WSL2 tarball
just all      # Full artifact synthesis (RAW, VHDX, ISO, WSL)
```

### [ENG] [automation/build.sh](automation/build.sh) (Internal Master Runner)
The core build logic that executes all numbered scripts in sequence. This is typically invoked automatically during the OCI build phase.

---

## [BUILD] Documentation Hub

| Document | Description |
|----------|-------------|
| [Strategic Blueprint](specs/core/2026-04-26-Artifact-COR-001-Blueprint.md) | Technical specs, filesystem hierarchy, and kernel tuning. |
| [Operational Handbook](specs/core/2026-04-26-Artifact-COR-004-Operations.md) | Setup guides (WSL2, Hyper-V), backup steps, and upgrade cycles. |
| [Security Guide](specs/engineering/2026-04-26-Artifact-ENG-002-Security.md) | Execution whitelisting, integrity checks (fs-verity), and network rules. |
| [Hardware Support](specs/core/2026-04-26-Artifact-COR-002-Infrastructure.md) | GPU-PV, SR-IOV, VFIO, and Silicon vendor details. |
| [Windows Workflow](specs/knowledge/guides/WINDOWS-BUILD-WORKFLOW.md) | Primary building environment: Windows 11 + Podman Desktop + WSL2/g. |
| [Package SSOT](usr/share/mios/PACKAGES.md) | Single Source of Truth for all system components. |
| [AI-Native Standards](specs/knowledge/research/2026-04-27-Artifact-KBX-025-FOSS-AI-Deep-Dive.md) | 2026 FOSS AI integration and ingestion patterns. |

## [START] Developer Workflow

MiOS is optimized for development:

1. **Self-Initializing:** `./automation/ai-bootstrap.sh` synchronizes all manifests and sub-projects.
2. **Unified Environment:** All user overrides live in `.env.mios` and `user/identity.env`.
3. **Automated Verification:** `just lint` and `./evals/smoke-test.sh` gate all builds.
4. **CI/CD:** Automated builds, signing, and pushes via GitHub Actions.

### [SYNC] Self-Updating Build Lifecycle

MiOS-DEV implements an autonomous documentation cycle on every build entry point:
`build >> log >> snapshot >> artifact >> repo wiki push`

Documentation, task lists, and research results are automatically pushed to the [Repository Wiki](https://github.com/Kabuki94/MiOS-bootstrap/wiki) for real-time AI retrieval.

---

## [ENG] Quick Start

```bash
# Build the entire stack (RAW, VHDX, ISO, WSL)
just all

# Run localized system tests
just test
```

---

---
###  Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
- **Sole Proprietor:** MiOS-DEV
---
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->