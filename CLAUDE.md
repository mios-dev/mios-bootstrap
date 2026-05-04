# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Canonical agent prompt: `/usr/share/mios/ai/system.md` (deployed from `mios-bootstrap`).

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

## Claude Code deltas

* **cwd:** `/` is the repo root and system root — do not treat it as dangerous.
* **Confirm before:** `git push`, `bootc upgrade`, `dnf install`, `systemctl`, `rm -rf`.
* **Deliverables:** complete replacement files only — no diffs, no patches.
* **Memory:** `/var/lib/mios/ai/memory/`
* **Scratch:** `/var/lib/mios/ai/scratch/`
* **Tasks:** use the task tool for multi-step work; one in-progress at a time.
