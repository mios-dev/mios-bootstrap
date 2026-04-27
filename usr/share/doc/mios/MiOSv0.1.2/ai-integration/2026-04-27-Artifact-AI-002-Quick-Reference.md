# MiOS Quick Reference for AI Agents

## Essential Commands
```bash
just build         # Build OCI image
just iso           # Generate bootable ISO
just wsl           # Generate WSL2 tarball
just all           # Full pipeline: build → rechunk → images
bootc container lint  # Validate image
```

## File Hierarchy (Rootfs-Native)
```
mios/
├── INDEX.md              # AI agent hub (ALWAYS READ FIRST)
├── Containerfile         # 2-stage OCI build
├── Justfile              # Build orchestration
├── .env.mios             # Unified config
├── specs/
│   ├── engineering/
│   │   └── 2026-04-26-Artifact-ENG-001-Packages.md  # Package SSOT
│   ├── core/             # Blueprints
│   └── knowledge/        # Research
├── automation/
│   ├── build.sh          # Master orchestrator
│   ├── 01-repos.sh       # RPM repos
│   ├── 10-gnome.sh       # Desktop packages
│   └── 99-cleanup.sh     # Final cleanup
├── usr/                  # System binaries (immutable)
├── etc/                  # Config templates
└── var/                  # State templates
```

## Immutable Laws (NEVER Break)
1. **USR-OVER-ETC**: Static config → /usr/lib/, not /etc/
2. **NO-MKDIR-IN-VAR**: Use tmpfiles.d, never mkdir /var/foo
3. **BOOTC-CONTAINER-LINT**: Final validation step (mandatory)

## Package Management
- **SSOT**: specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md
- **Categories**: packages-{repos,kernel,gnome,gpu,virt,etc}
- **Installation**: automation/lib/packages.sh → install_packages <category>

## Platform Detection
```bash
systemd-detect-virt  # Returns: none, microsoft, wsl, kvm, container-*
```

## Version Roadmap
- **MiOS-1**: Fedora bootc + akmod NVIDIA
- **MiOS-2 (current)**: v0.1.2, ucore-hci base, pre-signed kmods
- **MiOS-NXT (future)**: Hummingbird, SBOM, ARM64, minimal variants

## MiOS-NXT Preview
- **Timeline**: Q4 2026 - Q2 2027
- **Variants**: Desktop (3GB), Core (500MB), Edge (200MB)
- **Features**: Zero-CVE, SBOM (CycloneDX/SPDX), ARM64, composefs-native

## Common AI Tasks

### Add Package
1. Edit PACKAGES.md → Add to appropriate category
2. Update CHANGELOG v0.1.2
3. Verify automation/build.sh calls install_packages {category}

### Create Script
1. Naming: automation/XX-{purpose}.sh
2. Header: #!/bin/bash + set -euo pipefail
3. No /var mkdir → Use tmpfiles.d

### Debug Build
1. Check bootc container lint errors
2. Verify PACKAGES.md for missing deps
3. Check kargs.d TOML (no [kargs] section!)

## Key URLs
- Repo: https://github.com/mios-project/mios
- Image: ghcr.io/mios-project/mios:latest
- Docs: INDEX.md (in repo)

