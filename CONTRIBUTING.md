<!-- [NET] MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# [NET] MiOS
```json:knowledge
{
  "summary": "> **Proprietor:** MiOS-DEV",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "root"
  ],
  "relations": {
    "depends_on": [
      ".env.mios"
    ],
    "impacts": []
  }
}
```
> **Proprietor:** MiOS-DEV
> **Infrastructure:** Self-Building Infrastructure (Personal Property)
> **License:** Licensed as personal property to MiOS-DEV
---
# Contributing to MiOS

Thank you for your interest in contributing to MiOS. This document explains the project's conventions and how to submit changes.

## Project Philosophy

MiOS is an immutable, cloud-native workstation OS built on Fedora Rawhide bootc. Every decision follows these principles:

- **Architectural Purity (Single Source of Truth):** ALL system configuration files, units, rules, and kargs MUST reside in the `` overlay. Top-level configuration directories are forbidden to prevent build-time path desynchronization.
- **Declarative State (No Mkdir in Var):** In the bootc model, `/var` is a persistent volume. Any new directory or configuration required in `/var` MUST be declared in a `tmpfiles.d` file within the overlay. Manual `mkdir -p /var/...` calls in provisioning scripts are strictly forbidden.
- **Pure build-up for GNOME**  only the explicitly needed ~25 GNOME packages are installed. No `dnf remove` bloat blocks. All user-facing apps are Flatpaks; RPMs are restricted to kernel modules, drivers, virtualization stack, container runtime, system tools, and GNOME infrastructure.
- **PACKAGES.md is the single source of truth**  all package lists live in fenced code blocks parsed by `automation/lib/packages.sh`. Scripts use `install_packages`/`get_packages` helpers. Never add packages outside this system.
- **Nothing gets removed without explicit permission**  if a file or package exists in the repo, do not remove it in your PR without discussing it first.
- **Deliver complete files only**  never submit patches, diffs, fragments, or "paste this into X" instructions. Every contribution must be a drop-in replacement file.

## Getting Started

### Prerequisites

- Podman (rootful, for building bootc images)
- A machine with at least 8 GB RAM and 250 GB disk for the builder
- On Windows: PowerShell 7+ and WSL2

### Building locally

On Linux (using the Justfile):

```bash
just build      # Build the OCI image
just lint       # Run bootc container lint
just rechunk    # Rechunk for optimized deltas
just raw        # Generate RAW disk image via BIB
just iso        # Generate Anaconda ISO via BIB
```

On Windows (using the PowerShell orchestrator):

```powershell
.\mios-build-local.ps1
```

The PowerShell script handles Podman machine creation, credential injection, image build, rechunk, disk image generation (RAW, VHDX, WSL, ISO), GHCR push, and cleanup.

## Code Conventions

### Shell scripts

- Always start with `set -euo pipefail` (except `build.sh` which uses `set -uo pipefail` for per-script error handling).
- Use `VAR=$((VAR + 1))` for arithmetic. Never use `((VAR++))`  it exits 1 when the result is 0, which kills the script under `set -e`.
- Use the `install_packages` / `install_packages_strict` / `install_packages_optional` helpers from `automation/lib/packages.sh`.
- Numbered script naming: `NN-name.sh` where NN is the execution order (01, 02, 10, 11, 12, 20, 99).

### Containerfile

- Bind mounts from the `ctx` stage are READ-ONLY. Any `sed -i` or `chmod` must operate on `/tmp/build` copies.
- `SYSTEMD_OFFLINE=1` and `container=podman` must be set to prevent systemd scriptlet hangs.
- Always end with `bootc container lint`.

### System files

- Configuration that should be immutable goes in `/usr/lib/` (sysctl, systemd units, bootc kargs).
- Configuration that admins may override goes in `/etc/`.
- The `` directory mirrors the root filesystem  files are copied via `cp -a` in the Containerfile.

### SELinux

- Custom policies use individual per-rule `.te` modules (not monolithic).
- New booleans and fcontexts go in the semanage import block in `99-overrides.sh`.

### Services

- Bare-metal-only services get `ConditionVirtualization=no` drop-ins.
- WSL2-incompatible services get `ConditionVirtualization=!wsl` gating (native systemd detection, v252+).
- Use `systemctl enable ... || true` for optional services that may not be installed.

## Submitting Changes

1. Fork the repository and create a feature branch from `main`.
2. Make your changes following the conventions above.
3. Test locally with `podman build` and `bootc container lint` at minimum.
4. Update `PACKAGES.md` if you added or changed packages.
5. Update `VERSION` if the change is user-facing.
6. Add an entry to `changelogs/03-Cumulative-Changelog.md`.
7. Open a pull request against `main` using the PR template.

## Reporting Issues

Use the GitHub issue templates:

- **Bug Report**  for things that are broken
- **Feature Request**  for new functionality
- **Security**  for vulnerabilities (use private reporting for sensitive issues)

## License

By contributing, you agree that your contributions will be licensed under the same terms as the project (see LICENSE file).

---
###  Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
- **Sole Proprietor:** MiOS-DEV
---
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
