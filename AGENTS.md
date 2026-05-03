# AGENTS.md

> Generic agent entry point (agents.md standard). Canonical prompt: `/usr/share/mios/ai/system.md`.

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## Operating context

- **cwd:** `/` is the repo root and system root.
- **Confirm before:** `git push`, `bootc upgrade`, `dnf install`, `systemctl`, `rm -rf`.
- **Deliverables:** complete replacement files only.
- **Memory:** `/var/lib/mios/ai/memory/`
