# 'MiOS' Knowledge Index

## Primary sources (mios.git)

| Document | Purpose |
|---|---|
| `INDEX.md` | Architectural laws, API surface, pipeline phases (SSOT) |
| `ARCHITECTURE.md` | Filesystem layout, hardware, virtualization |
| `ENGINEERING.md` | Build pipeline, shell conventions, toolchain |
| `SECURITY.md` | Hardening, SELinux, sysctl, firewall |
| `SELF-BUILD.md` | Build modes 0-4, self-replication |
| `DEPLOY.md` | Deployment targets and day-2 lifecycle |
| `CONTRIBUTING.md` | Code conventions, submission process |
| `usr/share/mios/PACKAGES.md` | SSOT for all RPMs (fenced `packages-<category>` blocks) |
| `usr/share/mios/env.defaults` | Global `MIOS_*` environment variable defaults |
| `Containerfile` | OCI image build definition (two-stage: ctx + main) |
| `Justfile` | Linux build orchestrator |

## Primary sources (mios-bootstrap.git)

| Document | Purpose |
|---|---|
| `install.sh` | Interactive bootstrap installer |
| `usr/share/mios/ai/system.md` | Canonical agent system prompt |
| `usr/share/mios/ai/vars.json` | Global variables index |
| `usr/share/mios/knowledge/` | Structured knowledge graph and script inventory |

## AI surface

| File | Purpose |
|---|---|
| `usr/share/mios/ai/system.md` | Canonical agent system prompt |
| `usr/share/mios/ai/v1/models.json` | OpenAI-compatible models listing |
| `usr/share/mios/ai/v1/mcp.json` | MCP server registry |
| `usr/share/mios/ai/v1/context.json` | Agent context and endpoint metadata |
| `usr/share/mios/ai/v1/config.json` | Minimal AI connection config |
| `usr/share/mios/ai/vars.json` | Full `MIOS_*` variable definitions |

## Agent entry points (mios.git)

| File | Tool |
|---|---|
| `CLAUDE.md` | Claude Code |
| `AGENTS.md` | Generic agents (agents.md standard) |
| `GEMINI.md` | Gemini |
| `.cursorrules` | Cursor |
| `.clinerules` | Cline |
| `.github/ai-instructions.md` | GitHub Copilot |
