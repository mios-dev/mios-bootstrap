# MiOS Bootstrap — User Overlay AI Entry Point

> Merge order: `mios.git` (system defaults) ← `mios-bootstrap.git` (user overlay). Bootstrap always wins at build ignition.

This repo owns all user-configurable surfaces: installer, user identity, AI configuration, flatpak selections, and the per-host profile overlay merged into the system image at build or applied via `install.sh` post-boot.

## What mios-bootstrap.git owns (user + AI layer)

| Path | Purpose |
|---|---|
| `/install.sh` | Linux installer entry point |
| `/install.ps1` | Windows installer (Podman machine + WSL2 + build pipeline) |
| `/etc/mios/profile.toml` | **Host-local profile** — edit to customize this deployment |
| `/etc/skel/.config/mios/` | User dotfile templates (seeded on `useradd -m`) |
| `/usr/share/mios/ai/system.md` | Canonical agent system prompt |
| `/usr/share/mios/ai/models.json` | OpenAI `/v1/models` format model catalog |
| `/usr/share/mios/ai/mcp.json` | MCP server registry |
| `/usr/share/mios/memory/` | Episodic AI journal (JSONL, agent-writable) |
| `/usr/share/mios/knowledge/` | RAG knowledge graphs |

## User customization surface (`etc/mios/profile.toml`)

All user choices live here:

| Section | Key fields |
|---|---|
| `[identity]` | `username`, `fullname`, `hostname`, `shell`, `groups` |
| `[locale]` | `timezone`, `keyboard_layout`, `language` |
| `[auth]` | `ssh_key_action`, `password_policy`, `github_pat` |
| `[ai]` | `endpoint`, `model`, `embed_model`, `enable_ollama`, `enable_localai` |
| `[desktop]` | `session`, `color_scheme`, `flatpaks` (list of Flatpak app IDs) |
| `[image]` | `ref`, `branch` (bootc switch target) |
| `[bootstrap]` | `mode` (`auto`/`bootc`/`fhs`), repo URLs, `reboot_on_finish` |
| `[quadlets.enable]` | Per-Quadlet enable/disable flags |

**Secrets** (`password_hash`, `luks_passphrase`, `github_pat`) are never committed — the installer prompts interactively and writes to root-owned `0600` files.

## Profile resolution (three layers, higher wins)

```
~/.config/mios/profile.toml     ← per-user  (highest)
/etc/mios/profile.toml          ← host-local (this file)
/usr/share/mios/profile.toml    ← vendor defaults (lowest)
```

## AI system prompt resolution (three layers, higher wins)

```
~/.config/mios/system-prompt.md     ← per-user dotfile redirect  (highest)
/etc/mios/ai/system-prompt.md       ← host-local override
/usr/share/mios/ai/system.md        ← canonical image-baked prompt (lowest)
```

## Local AI stack

- **Endpoint:** `http://localhost:8080/v1` (LocalAI v2.20.0, OpenAI-compatible)
- **Inference model:** `qwen2.5-coder:7b`
- **Embedding model:** `nomic-embed-text`
- **Models registry:** `/usr/share/mios/ai/models.json`
- **MCP registry:** `/usr/share/mios/ai/mcp.json`
- **Inference config:** `/etc/mios/ai/config.json`

## Bootstrap merge at build ignition

At install/build time this repo is overlaid onto `mios.git` via `automation/00-bootstrap-merge.sh`. User profile values, AI files, and skel templates replace the vendor defaults in the system image. Bootstrap is the final layer — it always wins.
