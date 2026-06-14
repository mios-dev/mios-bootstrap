<!-- AI-hint: Documentation of the MiOS multi-repo architecture from the installer's vantage point — the split between the build/system layer (mios.git) and the user/AI layer (mios-bootstrap.git), the install entry points, the three-layer profile resolution, and the hierarchical resolution of AI system prompts and configs. Read this to understand how a host gets built and how operator/user overrides win over vendor defaults; it is the bootstrap-side companion to the system architecture doc.
     AI-related: /usr/share/doc/mios/reference/PACKAGES.md, /usr/share/mios/ai/, /etc/mios/profile.toml, /usr/share/mios/profile.toml, /usr/share/mios/ai/system.md, /usr/share/mios/ai/v1/models.json, /usr/share/mios/ai/v1/mcp.json, /etc/mios/ai/config.json, /etc/mios/ai/system-prompt.md, /usr/share/mios/memory/, /usr/share/mios/llamacpp/llama-swap.yaml -->
# 'MiOS' Bootstrap -- Architecture Summary

**Version:** v0.2.4

## What this doc is for

MiOS is one thing built two ways at once: an **immutable, bootc/OCI-shaped
Fedora workstation** (the whole OS is a single container image — boot it,
`bootc upgrade` it like a `git pull`, `bootc rollback` it like a Ctrl-Z) that is
*also* a **local, self-hosted agentic AI operating system** (local inference
lanes behind one OpenAI-compatible endpoint, a multi-agent orchestration
pipeline, and a PostgreSQL+pgvector memory — all on the operator's own
hardware, offline-capable).

This document is the **bootstrap-side** view of that system: how a host is
laid out across two repos, how the installer turns those repos into the image
and deploys it, and how the layered overrides decide which profile, AI config,
and system prompt actually win at runtime. It is the installer's companion to
the system-level layout in
[`usr/share/doc/mios/concepts/architecture.md`](../../mios/concepts/architecture.md).
Its audience is anyone running or extending the installer and reasoning about
"which file beats which."

The throughline to keep in mind: **two repos resolve to one `/` → the build
pipeline bakes that `/` into an OCI image → the bootc lifecycle carries the
image forward on the host.** Everything below is a slice of that lifecycle seen
from the entry point.

## Repo ownership

`mios-bootstrap.git` owns the user and AI layer. `mios.git` owns build scripts
and the system FHS overlay. They resolve to the same `/` on a deployed host;
gitignore partitions ownership so the two never double-track a path. This split
is what lets the *user-editable* layer (identity, AI prompts, profile
overrides, installer scripts) evolve independently of the *immutable system*
layer (Containerfile, Quadlets, kernel args, tmpfiles, sysusers) while both
bake into the same image.

| Layer | Repo | Key paths |
|---|---|---|
| Build / system | `mios.git` | `/Containerfile`, `/automation/`, `/usr/lib/`, `/usr/share/doc/mios/reference/PACKAGES.md` |
| User / AI | `mios-bootstrap.git` | `/install.sh`, `/install.ps1`, `/usr/share/mios/ai/`, `/etc/mios/`, `/etc/skel/` |

## Install entry points

The installer is the front of the build pipeline: it merges both repos into one
`/`, builds the OCI image, and hands off to the bootc lifecycle on the host.

**Windows 11** (Podman Desktop + WSL2):
```powershell
irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
```
Creates the `MiOS-BUILDER` Podman machine (all host resources), clones both
repos, builds the OCI image. Fully automated -- no input required after launch.

**Linux** (Fedora bootc):
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.sh)"
```

Both paths produce the same image (`ghcr.io/mios-dev/mios:latest` by default);
on a bootc host the deployed image is upgraded with `bootc upgrade` and reverted
with `bootc rollback`.

## Profile resolution (three layers, higher wins)

The same three-layer override governs the operator profile. `install.sh`
field-level overlays all three; **empty strings do NOT override non-empty values
below**, so an empty per-user TOML is the vendor-default state, not an error.

1. `~/.config/mios/profile.toml` -- per-user (highest)
2. `/etc/mios/profile.toml` -- host/admin (this repo's editable copy)
3. `/usr/share/mios/profile.toml` -- vendor defaults (`mios.git`, lowest)

This is the same precedence pattern used everywhere in MiOS (per-user beats
host beats vendor), and the reason the immutable vendor layer can ship sane
defaults that operators override without ever editing the image.

## AI file locations (flat structure, OpenAI-compatible)

The AI layer is the "agentic OS" half of MiOS. These files are the *contract*
the local agent stack runs against — the canonical system prompt, the model and
MCP-server catalogs, and the host-local inference config — all owned by
`mios-bootstrap.git` and all resolved through `MIOS_AI_ENDPOINT` (Architectural
Law 5: every agent and tool targets the one local endpoint, no vendor-hardcoded
URLs).

| File | Purpose |
|---|---|
| `/usr/share/mios/ai/system.md` | Canonical agent system prompt (day-zero ready) |
| `/usr/share/mios/ai/v1/models.json` | OpenAI `/v1/models` format local model catalog |
| `/usr/share/mios/ai/v1/mcp.json` | MCP server registry |
| `/etc/mios/ai/config.json` | Host-local inference config (base_url, models) |
| `/etc/mios/ai/system-prompt.md` | Host-local system prompt override |
| `/etc/skel/.config/mios/system-prompt.md` | Per-user prompt override template (seeded on first login) |
| `/var/lib/mios/ai/memory/` | AI episodic journal (JSONL) — runtime, not committed |
| `/usr/share/mios/knowledge/` | RAG knowledge graphs |

**System prompt resolution** (same higher-wins shape as the profile):
`$MIOS_AI_SYSTEM_PROMPT` → `~/.config/mios/system-prompt.md` →
`/etc/mios/ai/system-prompt.md` → `/usr/share/mios/ai/system.md`

### How these files plug into the running brain

The config above points the agent stack at the local inference plane that the
image ships. Named by *function*, not by upstream tool:

- **`mios-llm-light` (`:11450`)** — the **primary** lane: a `llama.cpp`
  multi-model server fronted by the upstream
  [llama-swap](https://github.com/mostlygeek/llama-swap) proxy image. It
  auto-swaps the everyday chat/reasoning models behind one endpoint, KV-pages
  each conversation to disk, **and** serves embeddings (`nomic-embed-text`,
  OpenAI-compatible `/v1/embeddings`) plus the `mios-opencode` coder model. Its
  model map is
  [`/usr/share/mios/llamacpp/llama-swap.yaml`](../../../mios/llamacpp/llama-swap.yaml).
- **`mios-llm-heavy` (`:11441`, served-name `mios-heavy`)** — the heavy GPU lane
  (SGLang), gated off by default on VRAM grounds.
- **`mios-llm-heavy-alt`** — the alternate heavy lane (vLLM), likewise gated.
- **`mios-llm-worker@`** — single-model swarm workers for fan-out.

These engines speak the OpenAI/Ollama-compatible API (a legitimate *upstream
API-compat reference* — the live MiOS inference backend is `llama.cpp`/SGLang/
vLLM, not Ollama). Front-ends (Open WebUI, the chat gateways, the `mios` CLI)
reach the brain through the **agent-pipe** orchestrator (`:8640`), which refines
and fans requests across a council/swarm; **MiOS-Hermes** (`:8642`) is the
OpenAI-compatible agent gateway and tool-loop; a **prefilter** (`:8641`) injects
fan-out hints. The unified agent datastore is **PostgreSQL + pgvector**
(`mios-pgvector`, `:5432`) — agent memory, events, tool calls, sessions, skills,
scratch, and a `knowledge` table with vector recall (embedded by
`nomic-embed-text` from `mios-llm-light`). `web_search` is backed by a local
**SearXNG** (`:8888`), and the coder peer is served via the **opencode-gateway**
(`:8633`). Agents call tools over **MCP** and reach peer agents over **A2A**.

The shape to remember: **inference lanes → agent-pipe/Hermes orchestration →
pgvector memory → MCP/A2A**, all behind `MIOS_AI_ENDPOINT`. The files in the
table above are how the installer seeds and overrides that plane per host and
per user.

## Default identity

All defaults are `mios` (username, hostname, password). Override at the
interactive identity prompt (Phase-0) or set in `etc/mios/profile.toml` before
running the installer. Each prompt auto-accepts its `mios.toml`/`profile.toml`
default after **90 seconds** idle (`MIOS_PROMPT_TIMEOUT=0` waits forever, `=1`
is fastest unattended).
