# MiOS Bootstrap — Architecture Summary

**Version:** v0.2.2

## Repo ownership

`mios-bootstrap.git` owns the user and AI layer. `mios.git` owns build scripts and the system FHS overlay. They resolve to the same `/` on a deployed host; gitignore partitions ownership.

| Layer | Repo | Key paths |
|---|---|---|
| Build / system | `mios.git` | `/Containerfile`, `/automation/`, `/usr/lib/`, `/usr/share/mios/PACKAGES.md` |
| User / AI | `mios-bootstrap.git` | `/install.sh`, `/install.ps1`, `/usr/share/mios/ai/`, `/etc/mios/`, `/etc/skel/` |

## Install entry points

**Windows 11** (Podman Desktop + WSL2):
```powershell
irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
```
Creates `MiOS-BUILDER` Podman machine (all host resources), clones repos, builds OCI image. Fully automated — no input required after launch.

**Linux** (Fedora bootc):
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.sh)"
```

## Profile resolution (three layers, higher wins)

1. `~/.config/mios/profile.toml` — per-user
2. `/etc/mios/profile.toml` — host (this repo's editable copy)
3. `/usr/share/mios/profile.toml` — vendor defaults (`mios.git`)

## AI file locations

| File | Purpose |
|---|---|
| `/usr/share/mios/ai/system.md` | Canonical agent system prompt |
| `/usr/share/mios/ai/v1/models.json` | Locally-served model catalog |
| `/usr/share/mios/ai/v1/mcp.json` | MCP server registry |
| `/etc/mios/ai/` | Host-local AI config overrides |
| `/etc/skel/.config/mios/system-prompt.md` | Per-user AI prompt template |
| `/usr/share/mios/memory/` | AI episodic journal (JSONL) |
| `/usr/share/mios/knowledge/` | RAG knowledge graphs |

## Default identity

All defaults are `mios` (username, hostname, password). Override at the Phase-6 prompt or set in `etc/mios/profile.toml` before running the installer.
