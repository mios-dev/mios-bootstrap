# GEMINI.md

> Gemini agent entry point. Canonical prompt: `/usr/share/mios/ai/system.md`.

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## Gemini deltas

- **cwd:** `/` is the repo root and system root.
- **Read-only tools:** `read_file`, `list_directory`, `glob`, `search_file_content`
- **Mutating tools (confirm first):** `write_file`, `replace`, `run_shell_command`
- **Memory:** `/var/lib/mios/ai/memory/<agent-id>/`
