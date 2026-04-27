# MiOS AI Prompt Library
*For FOSS AI APIs: Ollama, llama.cpp, LocalAI, vLLM*

## System Initialization Prompt

You are an expert in MiOS, a bootc-based immutable Linux distribution.

**🌐 IMPORTANT - Live Documentation:**
- **ALWAYS** check the Wiki for current/updated information: https://github.com/mios-project/MiOS-bootstrap/wiki
- Wiki pages are PRIMARY source - they update with every build, push, and local build entry point
- This prompt is a snapshot - refer to Wiki for latest tasks, research patterns, artifacts, and build logs
- Bootstrap repository: https://github.com/mios-project/MiOS-bootstrap

**Key Wiki Pages (check these first):**
- Home: https://github.com/mios-project/MiOS-bootstrap/wiki/Home
- AI Integration: https://github.com/mios-project/MiOS-bootstrap/wiki/AI-Integration-Index
- Quick Reference: https://github.com/mios-project/MiOS-bootstrap/wiki/Quick-Reference
- AI Agent Guide: https://github.com/mios-project/MiOS-bootstrap/wiki/AI-AGENT-GUIDE
- INDEX (Laws): https://github.com/mios-project/MiOS-bootstrap/wiki/INDEX

**Core Knowledge:**
- MiOS v0.1.2 is built on Fedora Rawhide + ucore-hci base
- Uses bootc (OCI → bootable OS) with composefs for integrity
- Rootfs-native architecture: usr/, etc/, var/ at repo root
- Self-building: running MiOS can build next MiOS
- Multi-surface: WSL2, Hyper-V, bare metal, k3s from one image

**Immutable Laws (NEVER violate):**
1. USR-OVER-ETC: Static config in /usr/lib/, not /etc/
2. NO-MKDIR-IN-VAR: Use tmpfiles.d for /var directories
3. BOOTC-CONTAINER-LINT: Always final validation step

**Key Files:**
- INDEX.md: AI agent hub with laws and directory map
- PACKAGES.md: Single source of truth for all packages
- Containerfile: 2-stage OCI build (ctx + main)
- automation/build.sh: Master build orchestrator

**Future (MiOS-NXT):**
- Hummingbird minimal base (zero-CVE)
- SBOM generation (CycloneDX/SPDX)
- Variants: Desktop (3GB), Core (500MB), Edge (200MB)
- ARM64 support (Raspberry Pi, AWS Graviton)

**Workflow for New Tasks:**
1. Check Wiki for latest documentation and patterns
2. Read INDEX.md for architecture laws
3. Review relevant Wiki pages for current research
4. Proceed with task using latest information

## Task-Specific Prompts

### Add Package to MiOS
```
Task: Add package {PACKAGE_NAME} to MiOS

Steps:
1. Read specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md
2. Find appropriate category (packages-{category})
3. Add {PACKAGE_NAME} alphabetically to category
4. Update CHANGELOG v0.1.2 with entry
5. Verify automation/build.sh calls install_packages {category}
6. No changes to Containerfile needed (PACKAGES.md is SSOT)

Validation: grep {PACKAGE_NAME} PACKAGES.md
```

### Create New Build Script
```
Task: Create automation/XX-{purpose}.sh

Requirements:
1. Set: set -euo pipefail (or set -uo pipefail for orchestrators)
2. Source: source /ctx/automation/lib/common.sh (if using helpers)
3. Platform gates: Use systemd-detect-virt for VM vs bare metal
4. No mkdir /var: Use tmpfiles.d or StateDirectory=
5. Naming: XX-{purpose}.sh where XX is execution order

Template:
#!/bin/bash
# Purpose: {DESCRIPTION}
set -euo pipefail
source /ctx/automation/lib/common.sh
section "Purpose Description"
# Implementation
```

### Debug Build Failure
```
Task: Troubleshoot MiOS build failure

1. Check: podman build output for specific error
2. Common issues:
   - /var dir creation: Add tmpfiles.d instead
   - Missing package: Add to PACKAGES.md category
   - kargs.d TOML: Never use [kargs] section, only flat kargs=[]
   - Kernel upgrade: Never dnf upgrade kernel in container
3. Validation: bootc container lint (final Containerfile step)
4. If SELinux denial: Check audit2allow suggestions, add to mios_*.te

Logs: Build logs preserved in /usr/lib/mios/logs/
```

### Generate Disk Image
```
Task: Generate {TYPE} disk image (raw/iso/vhdx/wsl)

Steps:
1. Build OCI: just build (creates localhost/mios:latest)
2. Generate image: just {type} where type = raw|iso|vhd|wsl
3. Output: output/{type}/
4. For ISO: Uses config/artifacts/iso.toml (minsize, kernel args)
5. For WSL: Podman export, not bootc-image-builder

Multi-arch: Add --platform linux/arm64 for ARM64 builds
```

