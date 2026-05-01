<!-- MiOS User Preferences Card — LAW 3: JSON-embedded Markdown SSOT -->
<!-- This file is the canonical record of user-defined build parameters.  -->
<!-- It is read by automation/build.sh and tools/load-user-env.sh.        -->
<!-- Blank fields are auto-populated with MiOS current defaults at build. -->

# MiOS User Preferences Card

```json
{
  "schema_version": "1",
  "description": "MiOS User Preferences — Single Source of Truth for all user-configurable build parameters.",
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
      "description": "OCI base image used by the Containerfile FROM clause.",
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
      "description": "bootc-image-builder container image used for artifact generation (ISO, VHDX, RAW).",
      "type": "string"
    }
  }
}
```

## How this card is consumed

1. **Build entry** — `automation/build.sh` sources `tools/load-user-env.sh`, which reads this card.
   Any field with an empty `value` falls back to its `default`.
2. **Justfile** — `_load_env` at the top of the Justfile runs `tools/load-user-env.sh` to export all `MIOS_*` variables.
3. **Bootstrap** — `automation/bootstrap.sh` prompts for missing values and saves them back to
   `$XDG_CONFIG_HOME/mios/mios-build.env`, which is sourced on subsequent runs.

## Editing

To customise your build, edit the `value` field for any parameter above, then run:

```bash
just build
```

Leaving `value` as `""` always selects the MiOS-maintained default, ensuring forward compatibility.
