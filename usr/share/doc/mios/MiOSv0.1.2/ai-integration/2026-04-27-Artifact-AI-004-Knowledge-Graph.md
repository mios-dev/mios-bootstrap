<!-- 🌐 MiOS Artifact | Proprietor: MiOS Project | https://github.com/mios-project/mios -->
# 🌐 MiOS Knowledge Graph

```json:knowledge
{
  "project": "MiOS",
  "version": "0.1.2",
  "type": "bootc-immutable-os",
  "base": "Fedora Rawhide + ucore-hci",
  "architecture": "rootfs-native",
  "future": "MiOS-NXT (Hummingbird, SBOM, minimal variants)",
  "core_concepts": {
    "bootc": "OCI image \u2192 bootable OS, atomic updates, composefs backend",
    "immutability": "/usr read-only, /etc + /var mutable, OSTree/composefs integrity",
    "self_building": "Podman + Buildah + bootc in-image, v1.x builds v1.(x+1)",
    "multi_surface": "WSL2, Hyper-V, bare metal, k3s nodes from single OCI image",
    "security": "SELinux enforcing, fapolicyd, CrowdSec, composefs verification"
  },
  "key_files": {
    "index": "INDEX.md (AI agent hub, laws, directory map)",
    "packages": "specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md",
    "build": "Containerfile (2-stage OCI build)",
    "orchestration": "Justfile (build targets), automation/build.sh (master runner)",
    "config": ".env.mios (unified environment variables)",
    "self_build": "SELF-BUILD.md (4 build modes: CI/CD, Windows, Linux, self-build)"
  },
  "immutable_laws": [
    "USR-OVER-ETC: No static config in /etc/ at build time, use /usr/lib/",
    "NO-MKDIR-IN-VAR: All /var dirs via tmpfiles.d, never mkdir in Containerfile",
    "MANAGED-SELINUX: semodule -i in RUN layer, or stage in /usr/share/selinux/",
    "BOUND-IMAGES: Quadlet containers in /usr/lib/bootc/bound-images.d/",
    "BOOTC-CONTAINER-LINT: Mandatory final validation, enforces kernel hygiene"
  ],
  "build_pipeline": {
    "stages": [
      "ctx (scratch + automation)",
      "main (FROM base + apply overlays)"
    ],
    "numbered_scripts": "automation/01-repos.sh through automation/99-cleanup.sh",
    "package_installation": "install_packages <category> via automation/lib/packages.sh",
    "system_overlay": "usr/, etc/, var/ copied via 08-system-files-overlay.sh",
    "outputs": "OCI image \u2192 rechunk \u2192 RAW/ISO/VHDX/WSL via bootc-image-builder"
  },
  "version_history": {
    "MiOS-1": "Fedora bootc + akmod NVIDIA drivers",
    "MiOS-2": "v0.1.x, ucore-hci base, pre-signed NVIDIA kmods",
    "MiOS-NXT": "Future: Hummingbird, SBOM, ARM64, minimal variants"
  },
  "mios_nxt_roadmap": {
    "timeline": "Q4 2026 - Q2 2027",
    "hummingbird": "Zero-CVE minimal base from Red Hat/Fedora",
    "sbom": "CycloneDX + SPDX via Syft, EU CRA compliance",
    "variants": {
      "Desktop": "2-3GB, GNOME, GPU passthrough, Steam/Wine",
      "Core": "<500MB, bootc+podman+k3s, container hosts",
      "Edge": "<200MB, IoT/embedded (future)"
    },
    "arm64": "Raspberry Pi 5, AWS Graviton, cross-arch builds",
    "composefs": "Fedora 42+ default, runtime integrity verification"
  },
  "security_hardening": {
    "kernel": "init_on_alloc=1, pti=on, spectre_v2=on, iommu=pt",
    "application": "fapolicyd whitelisting, USBGuard, CrowdSec IPS",
    "filesystem": "composefs + fs-verity, transient /etc",
    "image": "cosign keyless signing via GitHub OIDC"
  },
  "integration_points": {
    "ollama": "Pre-pulled in Containerfile, Quadlet service",
    "k3s": "SELinux policies, automated install via automation/13-ceph-k3s.sh",
    "vfio": "GPU passthrough for VMs, 34-gpu-detect.sh gates NVIDIA on bare metal",
    "flatpak": "Desktop apps isolation, install list in .env.mios"
  }
}
```

> **Proprietor:** MiOS Project
> **Type:** Structured Knowledge Graph
> **Version:** 0.1.2
> **Format:** JSON (machine-readable)

---

## Usage

This knowledge graph can be loaded directly into AI agents for immediate context:

```python
import json

with open("mios-knowledge-graph.json") as f:
    knowledge = json.load(f)
    
# Use as system prompt
system_prompt = json.dumps(knowledge, indent=2)
```

Or via command line:

```bash
# Direct injection into Ollama
curl http://localhost:11434/api/chat -d @- << EOF
{
  "model": "llama3.1:8b",
  "messages": [
    {"role": "system", "content": ""},
    {"role": "user", "content": "Explain MiOS architecture"}
  ]
}
EOF
```

---

**Last Updated:** 2026-04-27
<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS Project -->
