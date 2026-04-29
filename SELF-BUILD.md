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
# Self-Build Mode Guide

MiOS is a self-replicating OS  the published image can be used as the builder for the next generation. This document explains the self-build architecture and when to use each mode.

## How Self-Build Works

MiOS ships all the tools needed to rebuild itself: Podman, Buildah, bootc, and bootc-image-builder (BIB) are all baked into the image. This means you can boot a running MiOS system and use it to build the next version, without needing a separate build environment.

The build chain is:

```
MiOS v0.1.3 (running)  builds  MiOS v0.1.4 (OCI image)
                                        
                                  Rechunk  Sign  Push to GHCR
                                        
                              MiOS v0.1.4 (running via bootc upgrade)
                                        
                                  builds  MiOS-NXT ...
```

## Build Modes

### Mode 0: Bootstrap (Initial Install)

If you are starting from a fresh Linux installation (Fedora/Debian/Ubuntu), you can bootstrap the entire MiOS build environment with a single command:

```bash
curl -sL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/install.sh | sudo bash
```

This will:
1.  Install system prerequisites (`git`, `podman`, `just`, `rsync`).
2.  Clone the latest MiOS source to `/usr/src/mios`.
3.  Symlink the system directories and install the unified `mios` CLI.
4.  Configure `tmpfiles.d` for persistent state management.

### Mode 1: CI/CD (GitHub Actions)  Recommended

The GitHub Actions workflow automatically builds, rechunks, signs, and pushes the image on every commit to `main` and on a weekly schedule. This is the recommended approach for production use.

```bash
# Users receive updates via:
sudo bootc upgrade
```

No local build infrastructure needed. The CI runner is an Ubuntu 24.04 GitHub-hosted runner.

### Mode 2: Windows Local Build (mios-build-local.ps1)

For local development and testing on Windows with Podman Desktop:

```powershell
# Run the 5-phase orchestrator
.\mios-build-local.ps1
```

This creates a dedicated `mios-builder` Podman machine, builds the OCI image, rechunks it, generates disk images (RAW, VHDX, WSL, ISO), and optionally pushes to GHCR. Phase by phase:

1. **Phase 0**: Prompts for username, password, LUKS passphrase, registry credentials
2. **Phase 1**: Creates the `mios-builder` Podman machine (rootful, all cores, all RAM, 250 GB disk)
3. **Phase 2**: Injects credentials into `99-overrides.sh`, runs `podman build`, rechunks, restores placeholders
4. **Phase 3**: Generates disk images via BIB (RAW  VHDX, WSL tarball, Anaconda ISO)
5. **Phase 4**: Pushes to GHCR, sets package public
6. **Phase 5**: Restores default Podman machine, prints report

### Mode 3: Linux Local Build (Justfile)

For local development on a Linux system (including a running MiOS):

```bash
# Full build
just build

# Build + rechunk
just build rechunk

# Build + all disk images
just all

### Mode 4: Appliance (Ignition Builder)

For fully automated, hardware-native builds on a fresh machine, you can use the Fedora CoreOS (FCOS) or Fedora Server Ignition builder:

```bash
# Configuration located in:
# config/ignition/mios-builder.bu
# config/ignition/build-mios-iso.sh
```

1.  **Customize**: Edit `mios-builder.bu` to add your SSH key and password hash.
2.  **Compile**: Use Butane to convert the `.bu` file to an Ignition `.ign` file.
3.  **Deploy**: Provision a fresh FCOS or Fedora Server instance with the resulting Ignition file.

Upon first boot, the appliance will:
1.  Connect to the network.
2.  Install dependencies (`git`, `podman`, `just`).
3.  Automatically clone and bootstrap the MiOS build environment.
4.  Build a live MiOS installer ISO at `/usr/src/mios/output/mios-installer.iso`.

# Individual targets
just raw       # RAW disk image
just iso       # Anaconda ISO
just vhd       # VHDX for Hyper-V
just wsl       # WSL2 tarball
just push      # Push to GHCR
just lint      # Run bootc container lint
just clean     # Clean build artifacts
```

### Mode 4: Self-Build (running MiOS builds next MiOS)

Boot into a running MiOS system and build from source:

```bash
# Clone the repo
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd MiOS

# Build the OCI image (rootful Podman required)
sudo podman build --no-cache -t localhost/mios:dev .

# Validate
sudo podman run --rm localhost/mios:dev bootc container lint

# Rechunk for optimal delta updates
sudo bootc-base-imagectl rechunk --max-layers 67 \
  localhost/mios:dev \
  localhost/mios:rechunked

# Test locally: switch to the locally-built image
sudo bootc switch --transport containers-storage localhost/mios:rechunked
sudo systemctl reboot
```

## Bootstrapping the First Image

If you're starting from scratch (no existing MiOS image):

1. Install Podman on any Linux system (Fedora, Ubuntu, etc.) or use Podman Desktop on Windows
2. Clone the repo and run `podman build` (or `mios-build-local.ps1` on Windows)
3. The Containerfile pulls `quay.io/fedora/fedora-bootc:rawhide` as the base  no prior MiOS image needed
4. Deploy the resulting image to your target (bare metal via ISO, Hyper-V via VHDX, etc.)
5. Subsequent builds can use the running MiOS itself (self-build mode)

## Verifying Self-Build Capability

To confirm that a running MiOS image can build the next generation:

```bash
# Check required tools are present
which podman buildah bootc bootc-image-builder

# Check Podman can build (rootful)
sudo podman info | grep -E "rootless|graphRoot"

# Check disk space (need ~50 GB free for build)
df -h /var/lib/containers

# Test a minimal build
sudo podman build --no-cache -t test-build . && echo "Self-build: OK"
sudo podman rmi test-build
```

## Build Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU cores | 4 | 8+ |
| RAM | 8 GB | 16+ GB |
| Disk (builder) | 100 GB | 250 GB |
| Network | Required (pulls base image + packages) | Fast connection for RPM downloads |

## Future Considerations: image-builder-cli

The `bootc-image-builder` (BIB) tool is currently used for generating disk images. However, the `image-builder-cli` is an emerging alternative with advantages such as SBOM generation and cross-architecture support.

**Actionable Item:** Evaluate `image-builder-cli` as a potential successor to BIB.
- **Current Status:** `image-versions.yml` has commented-out entries for `image_builder_cli_digest`, indicating an intention to track this tool.
- **Next Steps:**
    1. Uncomment and populate `image_builder_cli_digest` in `image-versions.yml` to enable Renovate Bot for version management.
    2. Investigate the `ghcr.io/osautomation/image-builder-cli:latest` container image as a potential replacement for the BIB container.
    3. Compare output formats and build times against current BIB usage.
    4. Assess its compatibility with MiOS's existing build pipeline and testing infrastructure.

This evaluation should be conducted before considering a full migration.

## Future Considerations: image-builder-cli

The `bootc-image-builder` (BIB) tool is currently used for generating disk images. However, the `image-builder-cli` is an emerging alternative with advantages such as SBOM generation and cross-architecture support.

**Actionable Item:** Evaluate `image-builder-cli` as a potential successor to BIB.
- **Current Status:** `image-versions.yml` has commented-out entries for `image_builder_cli_digest`, indicating an intention to track this tool.
- **Next Steps:**
    1. Uncomment and populate `image_builder_cli_digest` in `image-versions.yml` to enable Renovate Bot for version management.
    2. Investigate the `ghcr.io/osautomation/image-builder-cli:latest` container image as a potential replacement for the BIB container.
    3. Compare output formats and build times against current BIB usage.
    4. Assess its compatibility with MiOS's existing build pipeline and testing infrastructure.

This evaluation should be conducted before considering a full migration.

## Build Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU cores | 4 | 8+ |
| RAM | 8 GB | 16+ GB |
| Disk (builder) | 100 GB | 250 GB |
| Network | Required (pulls base image + packages) | Fast connection for RPM downloads |

The build process downloads ~2-4 GB of RPM packages from Fedora repos, RPM Fusion, Terra, and CrowdSec. Subsequent builds with dnf5 cache mounts are 5-10x faster.

---
###  Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
- **Sole Proprietor:** MiOS-DEV
---
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
