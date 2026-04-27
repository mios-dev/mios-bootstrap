<!-- 🌐 MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# 🧠 MiOS Unified Knowledge Hub

```json:knowledge
{
  "summary": "Centralized index for all MiOS knowledge, context, and memories.",
  "logic_type": "index",
  "rag_compatible": true,
  "last_sync": "2026-04-27 22:47:48 UTC"
}
```

## 📖 Overview
This hub provides a navigable map of the MiOS ecosystem, compacting research, memories, and engineering patterns into a unified structure.

> **AI AGENT HINT:** Use this page to discover deep context paths. Structured JSON context is available at `/usr/share/mios/knowledge/mios-knowledge-graph.json`.

---

## 🏛️ Knowledge Categories

### 🧱 Core Foundation
*Architectural laws and fundamental blueprints.*

- [🏗️ MiOS Strategic Blueprint](specs/core/2026-04-26-Artifact-COR-001-Blueprint)
- [🌐 MiOS — AI-Native Architectural Patterns](specs/core/2026-04-27-Artifact-COR-005-AI-Native-Patterns)
- [🌐 MiOS](specs/core/2026-04-26-Artifact-COR-002-Infrastructure)
- [🐧 Linux-Native Memory Standards](specs/core/2026-04-27-Artifact-COR-006-Linux-Native-Memory-Standards)
- [🌐 MiOS](specs/core/2026-04-26-Artifact-COR-004-Operations)
- [🌐 MiOS](specs/core/2026-04-26-Artifact-COR-003-Manifest)

### 🔧 Engineering Patterns
*Implementation details and technical standards.*

- [ENG-008: User-Space Separation and XDG Compliance](specs/engineering/2026-04-27-Artifact-ENG-008-UserSpace-Separation)
- [🌐 MiOS](specs/engineering/2026-04-26-Artifact-ENG-003-Self-Build)
- [Linux Filesystem Hierarchy Standard (FHS) Compliance Audit](specs/engineering/2026-04-27-Artifact-ENG-006-FHS-Compliance-Audit)
- [🌐 MiOS](specs/engineering/2026-04-27-Artifact-ENG-004-AI-Tool-Interface)
- [📜 MiOS Scripts Index](specs/engineering/2026-04-26-Artifact-ENG-002-Scripts-Index)
- [🌐 MiOS](specs/engineering/2026-04-26-Artifact-ENG-002-Security)
- [🧬 MiOS Technology & Architectural Patterns](specs/engineering/2026-04-27-Artifact-ENG-005-Technology-Patterns)
- [🌐 MiOS](specs/engineering/2026-04-26-Artifact-ENG-001-Packages)
- [🌐 MiOS](specs/engineering/2026-04-26-Artifact-ENG-004-Testing)
- [MiOS Bootstrap Repository Integration](specs/engineering/2026-04-27-Artifact-ENG-007-Bootstrap-Integration)

### 📜 Historical Context
*Journals, changelogs, and decision records.*

- [🌐 MiOS](specs/audit/2026-04-26-Artifact-ADT-001-Next-Research)
- [🌐 MiOS](specs/audit/2026-04-26-Artifact-ADT-002-Research-April2026)
- [🌐 MiOS](specs/memory/2026-04-26-Artifact-MEM-003-Research-Strategy)
- [🌐 MiOS](specs/memory/2026-04-26-Artifact-MEM-004-Work-Plan)
- [🌐 MiOS](specs/memory/2026-04-26-Artifact-MEM-002-Research-Plan)
- [🧠 MiOS Cognitive Journal (Episodic Memory)](specs/memory/2026-04-26-Artifact-MEM-001-Journal)
- [🌐 MiOS](specs/changelogs/2026-04-26-Artifact-CHL-003-v0.1.1)

### 🤖 Automation Logic
*Build scripts and deployment orchestration.*

- [43-uupd-installer.sh - install uupd + greenboot (from PACKAGES.md](automation/43-uupd-installer.sh)
- [🌐 MiOS](automation/37-ai-agnostic.sh)
- [MiOS v0.1.3 — 02-kernel: Kernel extras + development headers](automation/02-kernel.sh)
- [---------------------------------------------------------------------------](automation/mios-build-builder.ps1)
- [99-postcheck.sh - build-time technical invariant validation](automation/99-postcheck.sh)
- [MiOS v0.1.3 — 31-user: PAM, user creation, groups, sudoers](automation/31-user.sh)
- [53-bake-lookingglass-client.sh - git clone Looking Glass B7, cmake/make,](automation/53-bake-lookingglass-client.sh)
- [MiOS v0.1.3 — 01-repos: Fedora 44 overlay on ucore (base kernel preserved)](automation/01-repos.sh)
- [During an OCI container build, the firewalld daemon is not running.](automation/25-firewall-ports.sh)
- [40-composefs-verity.sh - promote composefs from default (yes) to verity mode](automation/40-composefs-verity.sh)
- [manifest.json](automation/manifest.json)
- [─────────────────────────────────────────────────────────────────────────────](automation/18-apply-boot-fixes.sh)
- [MiOS v0.1.3 — 30-locale-theme: Unified dark theme for EVERY window type](automation/30-locale-theme.sh)
- [MiOS v0.1.3 — 39-desktop-polish: Desktop entries, Cockpit webapp, MOTD](automation/39-desktop-polish.sh)
- [automation/35-gpu-pv-shim.sh - MiOS v0.1.3](automation/35-gpu-pv-shim.sh)
- [22-freeipa-client.sh — install FreeIPA/SSSD client + arm zero-touch enrollment.](automation/22-freeipa-client.sh)
- [49-finalize.sh - final cleanup, systemd preset application, image linting](automation/49-finalize.sh)
- [============================================================================](automation/08-system-files-overlay.sh)
- [MiOS v0.1.3 — Master build runner](automation/build.sh)
- [52-bake-kvmfr.sh - compile Looking Glass kvmfr kmod against the ucore-hci](automation/52-bake-kvmfr.sh)
- [shellcheck source=lib/common.sh](automation/19-k3s-selinux.sh)
- [============================================================================](automation/35-gpu-passthrough.sh)
- [============================================================================](automation/36-akmod-guards.sh)
- [MiOS Omni-Agent Bootstrap Script](automation/ai-bootstrap.sh)
- [MiOS v0.1.3 — Bootc kargs.d validator](automation/validate-kargs.py)
- [shellcheck source=lib/common.sh](automation/20-fapolicyd-trust.sh)
- [MiOS v0.1.3 — 10-gnome: GNOME 50 desktop — PURE BUILD-UP](automation/10-gnome.sh)
- [============================================================================](automation/05-enable-external-repos.sh)
- [MiOS v0.1.3 — 11-hardware: GPU drivers (Mesa + AMD ROCm + Intel + NVIDIA)](automation/11-hardware.sh)
- [MiOS v0.1.3 — 12-virt: Virtualization, containers, orchestration, gaming](automation/12-virt.sh)
- [MiOS v0.1.3 — 32-hostname: Unique per-instance hostname](automation/32-hostname.sh)
- [MiOS v0.1.3 — 13-ceph-k3s: Ceph distributed storage + K3s Kubernetes](automation/13-ceph-k3s.sh)
- [============================================================================](automation/42-cosign-policy.sh)
- [🌐 MiOS](automation/37-aichat.sh)
- [MiOS v0.1.3 — 34-gpu-detect: Bridge to GPU detection service](automation/34-gpu-detect.sh)
- [MiOS v0.1.3 — 98-boot-config: Boot console + service configuration](automation/98-boot-config.sh)
- [47-hardening.sh - enable hardening services (USBGuard, auditd).](automation/47-hardening.sh)
- [🌐 MiOS](automation/37-ollama-prep.sh)
- [generate-mok-key.sh — one-shot MiOS MOK key generator.](automation/generate-mok-key.sh)
- [Pre-emptively disable/mask legacy xrdp services just in case they bleed in from a base image](automation/26-gnome-remote-desktop.sh)
- [44-podman-machine-compat.sh - Podman-machine backend compatibility.](automation/44-podman-machine-compat.sh)
- [MiOS v0.1.3 — 38-vm-gating: VM service gating + Hyper-V Enhanced Session](automation/38-vm-gating.sh)
- [MiOS v0.1.3 — 20-services: Enable systemd services + bare-metal/VM gating](automation/20-services.sh)
- [shellcheck source=lib/common.sh](automation/23-uki-render.sh)
- [enroll-mok.sh — MiOS Secure Boot MOK enrollment helper.](automation/enroll-mok.sh)
- [MiOS v0.1.3 — 99-cleanup: Final image cleanup (mirrors ucore/cleanup.sh)](automation/99-cleanup.sh)
- [MiOS v0.1.3 — 35-init-service: Bridge to Unified Role Engine](automation/35-init-service.sh)
- [MiOS v0.1.3 — 37-flatpak-env: Capture Flatpak environment for boot-time install](automation/37-flatpak-env.sh)
- [Normalize to LF line endings (fixes SC1017)](automation/21-moby-engine.sh)
- [MiOS v0.1.3 — 36-tools: CLI tools and consolidated mios command](automation/36-tools.sh)
- [50-enable-log-copy-service.sh](automation/50-enable-log-copy-service.sh)
- [46-greenboot.sh - wire greenboot services; package installs via PACKAGES.md](automation/46-greenboot.sh)
- [45-nvidia-cdi-refresh.sh - wire up NVIDIA CDI auto-refresh services.](automation/45-nvidia-cdi-refresh.sh)
- [MiOS v0.1.3 — 33-firewall: Firewall configuration script](automation/33-firewall.sh)
- [MiOS v0.1.3 — Ephemeral QEMU boot test](automation/bcvk-wrapper.sh)
- [MiOS v0.1.3 — 37-selinux: Build-time SELinux policy fixes](automation/37-selinux.sh)
- [============================================================================](automation/lib/common.sh)
- [============================================================================](automation/lib/masking.sh)
- [MiOS v0.1.3 — Package extraction library](automation/lib/packages.sh)

### ✅ Validation & Evals
*Health checks and smoke tests.*

- [MiOS v0.1.3 — Post-boot serial log smoke check](evals/smoke-check.sh)
- [─────────────────────────────────────────────────────────────────────────────](evals/smoke-test.sh)
- [manifest.json](evals/manifest.json)
- [MiOS: QEMU Boot Validation](evals/qemu-boot-check.sh)

### 🔬 Research & Status
*Upstream analysis and upcoming features.*

- [🌐 MiOS](specs/knowledge/research/2026-04-27-Artifact-KBX-025-FOSS-AI-Deep-Dive)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-106-WSL2-DEPLOYMENT)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-110-mios-full-script-readme)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-104-vm-cpu-pin-manager-readme)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-102-looking-glass-integration)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-107-cpu-isolation-optimization-notes)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-108-cpu-isolation-preset-corrections)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-105-WINDOWS-BUILD-WORKFLOW)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-103-vfio-toolkit-readme)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-109-cpu-isolator-script-improvements)
- [🌐 MiOS](specs/knowledge/guides/2026-04-26-Artifact-KBX-101-cpu-isolation-guide)

---

## 🤖 FOSS AI Native Discovery
MiOS is designed for native parsing by local FOSS AI APIs.

### Parsing Instructions
1. **Context Ingestion**: Local LLMs should prioritize `usr/share/mios/knowledge/mios-knowledge-graph.json`.
2. **Episodic Memory**: The human-readable journal is at `specs/memory/journal.md`, backed by the JSONL stream at `var/lib/mios/memory/journal/v1.jsonl`.
3. **Artifact Mapping**: All build-time artifacts and repository snapshots are mapped to standard Linux paths in `/var/lib/mios/`.

### Supported APIs
- **Ollama**: Native JSON/Markdown ingestion.
- **llama.cpp**: High-fidelity RAG via structured manifests.
- **LocalAI**: OpenAI-compatible endpoint for unified tool use.

---
### ⚖️ Legal & Source Reference
- **Copyright:** (c) 2026 MiOS-DEV
- **Status:** Personal Property / Private Infrastructure
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
---
<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
