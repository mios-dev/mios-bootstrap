# GEMINI.md

> Agent entry point (un-labeled). Pointer file -- no MiOS-internal
> documentation. The filename exists for tooling discovery only; the
> content is vendor-neutral and OpenAI-API-shaped.

> Canonical prompt: `/usr/share/mios/ai/system.md`.

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## OpenAI-API-compatible endpoint

All clients route through `MIOS_AI_ENDPOINT=http://localhost:8080/v1`
(Architectural Law 5: UNIFIED-AI-REDIRECTS). The vendor's native API
surface (`generativelanguage.googleapis.com`) is not used in-image;
the vendor CLI's OpenAI-compatibility flag points at `MIOS_AI_ENDPOINT`.

## Operating deltas

- **cwd:** `/` is the repo root and the deployed system root.
- **Read-only tools:** `read_file`, `list_directory`, `glob`,
  `search_file_content`.
- **Mutating tools (confirm first):** `write_file`, `replace`,
  `run_shell_command`.
- **Memory:** `/var/lib/mios/ai/memory/<agent-id>/`
