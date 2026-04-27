<!-- 🌐 MiOS Artifact | Proprietor: MiOS Project | https://github.com/mios-project/mios -->
# 🌐 MiOS

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
  "last_rag_sync": "2026-04-27T15:03:21.271935",
  "version": "MiOSv0.1.2"
}
```

> **Proprietor:** MiOS Project
> **Infrastructure:** Self-Building Infrastructure (Personal Property)
> **License:** Licensed as personal property to MiOS Project
---
# 🌐 MiOS: Immutable Cloud-Native Workstation

```json
{
  "status": "Production Stable",
  "baseline": "v0.1.2",
  "kernel": "Fedora Rawhide (OCI-Mode)",
  "build": "just all",
  "last_sync": "2026-04-27T15:03:21.271935"
}
```

---

## 🚀 Overview
MiOS is a container-native, mathematically verifiable workstation operating system. Built for high-performance virtualization (VFIO), hardware agnosticism, and zero-trust security, it transforms the host OS into a cryptographically sealed OCI payload.

### 🛡️ Core Mandates
- **Naked Core:** Minimalist base OS; applications reside in sandboxes (Flatpak/Distrobox).
- **Atomic Reliability:** Transactional image swaps with autonomous rollbacks.
- **Hardware Agnostic:** Optimized drivers for Intel, AMD, and NVIDIA.

---

## 🏗️ Build Entry Points

Depending on your environment, use one of the following primary entry points to build and deploy MiOS:

### 🐧 Linux / WSL2 (One-Liner)
Bootstraps the environment, clones the latest repository, and initiates the build process.
```bash
curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.sh | bash
```

### 🪟 Windows 11 (One-Liner)
One-click repository fetch and max-resource environment setup. **Run as Administrator.**
```powershell
irm https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.ps1 | iex
```

### 🐚 [Justfile](Justfile) (Unified Runner)
The recommended entry point for developers with the repository already cloned.
```bash
just build    # Synthesis OCI image
just wsl      # Generate WSL2 tarball
just all      # Full artifact synthesis (RAW, VHDX, ISO, WSL)
```

### 🛠️ [automation/build.sh](automation/build.sh) (Internal Master Runner)
The core build logic that executes all numbered scripts in sequence. This is typically invoked automatically during the OCI build phase.

---

## 🏗️ Documentation Hub

| Document | Description |
|----------|-------------|
| [Strategic Blueprint](specs/core/2026-04-26-Artifact-COR-001-Blueprint.md) | Technical specs, filesystem hierarchy, and kernel tuning. |
| [Operational Handbook](specs/core/2026-04-26-Artifact-COR-004-Operations.md) | Setup guides (WSL2, Hyper-V), backup steps, and upgrade cycles. |
| [Security Guide](specs/engineering/2026-04-26-Artifact-ENG-002-Security.md) | Execution whitelisting, integrity checks (fs-verity), and network rules. |
| [Hardware Support](specs/core/2026-04-26-Artifact-COR-002-Infrastructure.md) | GPU-PV, SR-IOV, VFIO, and Silicon vendor details. |
| [Windows Workflow](specs/knowledge/guides/WINDOWS-BUILD-WORKFLOW.md) | Primary building environment: Windows 11 + Podman Desktop + WSL2/g. |
| [Package SSOT](specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md) | Single Source of Truth for all system components. |
| [AI-Native Standards](specs/knowledge/research/2026-04-27-Artifact-KBX-025-FOSS-AI-Deep-Dive.md) | 2026 FOSS AI integration and ingestion patterns. |

## 🚀 Developer Workflow

MiOS is optimized for development:

1. **Self-Initializing:** `./automation/ai-bootstrap.sh` synchronizes all manifests and sub-projects.
2. **Unified Environment:** All user overrides live in `.env.mios` and `user/identity.env`.
3. **Automated Verification:** `just lint` and `./evals/smoke-test.sh` gate all builds.
4. **CI/CD:** Automated builds, signing, and pushes via GitHub Actions.

---

## 🛠️ Quick Start

```bash
# Build the entire stack (RAW, VHDX, ISO, WSL)
just all

# Run localized system tests
just test
```

---

---
### 📚 Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [mios-project/mios](https://github.com/mios-project/mios)
- **Sole Proprietor:** MiOS Project
---
<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS Project -->