# AGENTS.md

> Generic agent entry point (agents.md standard). The locally hosted
> MiOS AI models orchestrate all work in this stack; any external
> agent CLI that discovers this file routes through the same
> OpenAI-API-compatible endpoint those models serve. Strict adherence
> to OpenAI API standards and patterns. Canonical prompt:
> `/usr/share/mios/ai/system.md`.

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## Orchestration

The locally hosted models behind `MIOS_AI_ENDPOINT=http://localhost:8080/v1`
are the orchestrators. External agents defer to them via the OpenAI
public API surface — `/v1/chat/completions`, `/v1/responses`,
`/v1/embeddings`, function-calling, structured outputs. No vendor-native
protocols, no proprietary side-channels.

## Operating context

* **cwd:** `/` is the repo root and system root.
* **Confirm before:** `git push`, `bootc upgrade`, `dnf install`, `systemctl`, `rm -rf`.
* **Deliverables:** complete replacement files only.
* **Memory:** `/var/lib/mios/ai/memory/`
