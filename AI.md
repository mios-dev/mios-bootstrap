# 'MiOS' Bootstrap -- AI Entry Point

The locally hosted MiOS AI models orchestrate all work in this stack.
Every agent CLI, IDE plugin, and runtime tool routes through
`MIOS_AI_ENDPOINT=http://localhost:8080/v1` (Architectural Law 5) and
defers to those models. Strict adherence to OpenAI API standards and
patterns -- no vendor branding, no vendor-native protocols, no
proprietary side-channels. The AI files inventoried below are what
those locally hosted models load and serve.

Merge order: `mios.git` (system layer) ← `mios-bootstrap.git` (user overlay). Bootstrap profile values, AI files, and skel templates overlay the vendor defaults at install time.

## What mios-bootstrap.git owns

| Path | Purpose |
|---|---|
| `/install.sh` | Linux installer |
| `/install.ps1` | Windows installer (Podman machine + WSL2 + build pipeline) |
| `/etc/mios/profile.toml` | Host-local profile -- edit to customize this deployment |
| `/etc/skel/.config/mios/` | User dotfile templates (seeded on `useradd -m`) |
| `/usr/share/mios/ai/system.md` | Agent system prompt (host-override layer) |
| `/usr/share/mios/ai/models.json` | OpenAI `/v1/models` model catalog |
| `/usr/share/mios/ai/mcp.json` | MCP server registry |
| `/usr/share/mios/ai/vars.json` | Global variables index (all version pins, ports, paths) |
| `/usr/share/mios/knowledge/` | RAG knowledge graphs |

## User customization (`etc/mios/profile.toml`)

| Section | Key fields |
|---|---|
| `[identity]` | `username`, `fullname`, `hostname`, `shell`, `groups` |
| `[locale]` | `timezone`, `keyboard_layout`, `language` |
| `[auth]` | `ssh_key_action`, `password_policy`, `github_pat` |
| `[ai]` | `endpoint`, `model`, `embed_model`, `enable_localai` |
| `[desktop]` | `session`, `color_scheme`, `flatpaks` |
| `[image]` | `ref`, `branch` (bootc switch target) |
| `[bootstrap]` | `mode` (`auto`/`bootc`/`fhs`), repo URLs, `reboot_on_finish` |
| `[quadlets.enable]` | Per-Quadlet enable/disable flags |

Secrets (`password_hash`, `luks_passphrase`, `github_pat`) are never committed.

## Profile resolution (three layers, higher wins)

```
~/.config/mios/profile.toml     per-user  (highest)
/etc/mios/profile.toml          host-local
/usr/share/mios/profile.toml    vendor defaults (lowest)
```

## AI system prompt resolution

```
$MIOS_AI_SYSTEM_PROMPT > ~/.config/mios/system-prompt.md > /etc/mios/ai/system-prompt.md > /usr/share/mios/ai/system.md
```

## Local AI stack

- **base_url:** `http://localhost:8080/v1` (`MIOS_AI_ENDPOINT`)
- **model:** `qwen2.5-coder:7b` (`MIOS_AI_MODEL`)
- **embed_model:** `nomic-embed-text` (`MIOS_AI_EMBED_MODEL`)
- **models registry:** `/usr/share/mios/ai/models.json`
- **MCP registry:** `/usr/share/mios/ai/mcp.json`
- **inference config:** `/etc/mios/ai/config.json`
- **global vars:** `/usr/share/mios/ai/vars.json`

## Full agent context

Load `/usr/share/mios/ai/system.md` for the complete prompt. For the image-baked authoritative version, see `/usr/share/mios/ai/system.md` in the deployed image (same file, image layer).
