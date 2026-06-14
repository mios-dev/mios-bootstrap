<!-- AI-hint: Human-readable reference card for the build-identity subset of MiOS user-configurable parameters (admin username, hostname, layered Flatpaks, OCI base/local/remote image refs, BIB image). These fields are part of the singular `mios.toml` SSOT (three-layer overlay) consumed by the build pipeline (build-mios.sh / build-mios.ps1) and the configurator (mios.html); this card documents that subset and is NOT itself the live parser input.
     AI-related: /usr/share/mios/mios.toml, /etc/mios/mios.toml, mios.toml, /usr/share/mios/configurator/mios.html, build-mios.sh, build-mios.ps1, mios-dev, ghcr.io/mios-dev/mios -->
<!-- 'MiOS' User Preferences Card -- LAW 3 family: image refs that get BOUND/baked into the OCI image. -->
<!-- This card documents the build-IDENTITY subset of the mios.toml SSOT.            -->
<!-- The live, machine-parsed source of truth is mios.toml (three-layer overlay);   -->
<!-- blank fields below resolve to the 'MiOS' vendor default at build time.          -->

# 'MiOS' User Preferences Card

## What this card is for

MiOS is one system built two ways at once: an **immutable, bootc/OCI-shaped
Fedora workstation** (the whole OS is a single container image — boot it,
`bootc upgrade` it like a `git pull`, `bootc rollback` it like a Ctrl-Z) that is
*also* a **local, self-hosted agentic AI operating system** (local inference
lanes behind one OpenAI-compatible endpoint, a multi-agent orchestration
pipeline, and a PostgreSQL + pgvector memory — all on your hardware).

Because **the repo root IS the deployed system root**, the build pipeline bakes
`usr/`, `etc/`, `srv/`, `var/` straight into that OCI image, and the bootc
lifecycle carries it forward. A handful of parameters decide *which* image gets
built and *who* it is built for: the admin account, the hostname, the Flatpaks
layered in, and the OCI image references (base / local tag / remote name / BIB).

This card is the **human-readable reference for exactly that build-identity
subset**. It documents the fields, their meanings, and the 'MiOS'-maintained
defaults so an operator can understand them at a glance. The fields themselves
live in the singular `mios.toml` SSOT (see *How this card relates to the SSOT*
below) — editing them is what personalizes the otherwise-identical image every
host pulls.

## The fields

```json
{
  "schema_version": "1",
  "description": "MiOS build-identity parameters -- the image refs and account/host fields that personalize the OCI image. Live values are resolved from the mios.toml SSOT (three-layer overlay); blank values here fall back to the MiOS vendor default.",
  "fields": {
    "MIOS_USER": {
      "value": "",
      "default": "mios",
      "description": "Linux admin username created in the image.",
      "type": "string"
    },
    "MIOS_HOSTNAME": {
      "value": "",
      "default": "mios",
      "description": "Base hostname. A random 5-digit suffix is appended on first boot (e.g. mios-83427).",
      "type": "string"
    },
    "MIOS_FLATPAKS": {
      "value": "",
      "default": "",
      "description": "Comma-separated list of Flatpak app IDs to layer at build time (e.g. com.spotify.Client,com.valvesoftware.Steam).",
      "type": "csv"
    },
    "MIOS_BASE_IMAGE": {
      "value": "",
      "default": "ghcr.io/ublue-os/ucore-hci:stable-nvidia",
      "description": "OCI base image used by the Containerfile FROM clause. The build auto-picks the NVIDIA vs non-NVIDIA ucore-hci variant from detected hardware; this overrides it (e.g. fedora-bootc for the minimal track).",
      "type": "string"
    },
    "MIOS_LOCAL_TAG": {
      "value": "",
      "default": "localhost/mios:latest",
      "description": "Local Podman tag for the built image.",
      "type": "string"
    },
    "MIOS_IMAGE_NAME": {
      "value": "",
      "default": "ghcr.io/mios-dev/mios",
      "description": "Remote GHCR image name used for push and rechunk targets.",
      "type": "string"
    },
    "MIOS_BIB_IMAGE": {
      "value": "",
      "default": "quay.io/centos-bootc/bootc-image-builder:latest",
      "description": "bootc-image-builder container image used for artifact generation (ISO, VHDX, RAW, qcow2, WSL2).",
      "type": "string"
    }
  }
}
```

## How these fields serve the whole system

Each field shapes one stage of the **build pipeline → OCI image → bootc
lifecycle**:

- `MIOS_BASE_IMAGE` is the `Containerfile` `FROM` — the upstream
  [`ucore-hci`](https://github.com/ublue-os/ucore) foundation the rest of the
  image (desktop, GPU/CDI wiring, virt stack, **and the local AI plane**) is
  layered onto.
- `MIOS_LOCAL_TAG` is the tag the local `podman build` writes.
- `MIOS_IMAGE_NAME` is the remote GHCR path a built image is pushed/rechunked to
  for Day-2 `bootc switch ghcr.io/mios-dev/mios:latest` on real hosts.
- `MIOS_BIB_IMAGE` is the converter that cuts disk artifacts (ISO / VHDX / RAW /
  qcow2 / WSL2) from that OCI image.
- `MIOS_USER` / `MIOS_HOSTNAME` / `MIOS_FLATPAKS` personalize the otherwise-
  identical image: the admin account, the base hostname (a random 5-digit suffix
  is appended at first boot, e.g. `mios-83427`), and any Flatpaks layered in.

Because the image is immutable and self-contained (Architectural Law 3,
**BOUND-IMAGES** — every shipped container is baked into the image at build
time), these refs are not runtime knobs you flip on a live box; they are
*build-time identity*. The AI lanes that ship inside the image
(`mios-llm-light` on `:11450` as the primary llama.cpp lane plus embeddings, and
the gated heavy GPU lanes) and the `mios-pgvector` agent datastore all come from
the same baked image — so the same parameters that build the desktop also
build the brain.

## How this card relates to the SSOT

The singular, machine-parsed source of truth for **every** operator-tunable
value — packages, ports, AI lanes, services, agent behaviour, *and* these
build-identity fields — is **`mios.toml`**, resolved through a three-layer
overlay (highest wins):

```
~/.config/mios/mios.toml     # per-user
/etc/mios/mios.toml          # host/admin (written by bootstrap)
/usr/share/mios/mios.toml    # vendor defaults (immutable, shipped in image)
```

The fields on this card map to the `mios.toml` `[image]` and `[user]` /
`[flatpaks]` sections:

| Card field | `mios.toml` |
|---|---|
| `MIOS_USER` | `[user] name` |
| `MIOS_HOSTNAME` | `[user] hostname` |
| `MIOS_FLATPAKS` | `[flatpaks] install` |
| `MIOS_BASE_IMAGE` | `[image] base` |
| `MIOS_LOCAL_TAG` | `[image] local_tag` |
| `MIOS_IMAGE_NAME` | `[image] name` |
| `MIOS_BIB_IMAGE` | `[image] bib` |

This card is documentation of that subset, not a separate parser input. An empty
`value` here corresponds to leaving the field unset in the upper `mios.toml`
layers, which always resolves to the 'MiOS'-maintained vendor default in
`/usr/share/mios/mios.toml` — ensuring forward compatibility.

## Editing

To customise your build, edit the matching field in `mios.toml`. The supported
ways:

1. **Configurator (recommended)** — open the static `mios.html` configurator at
   `/usr/share/mios/configurator/` in a local browser (`file://` works, no
   server needed). It is a browser-local TOML editor that writes an updated
   `mios.toml`.
2. **Direct edit** — edit `~/.config/mios/mios.toml` (per-user) or
   `/etc/mios/mios.toml` (host/admin) by hand.

Then rebuild the image. On Linux the build entry point is `build-mios.sh`
(via the `mios` CLI / build driver); on Windows it is `build-mios.ps1`, both of
which run the OCI build inside the **MiOS-DEV** builder. The bootstrap installer
(`bootstrap.sh`) walks the three `mios.toml` layers and field-level overlays
them; **empty strings do NOT override non-empty values below**, so leaving a
field blank is the vendor-default state, not an error.
