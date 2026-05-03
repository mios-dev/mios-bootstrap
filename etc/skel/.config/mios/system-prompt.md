# 'MiOS' User AI Profile -- system prompt redirect
#
# This file is YOUR personal AI context layer. It is seeded from
# /etc/skel/.config/mios/system-prompt.md on account creation.
# Run `mios reinit-user-space` to reset to the system default.
#
# Resolution order (first match wins -- this file is layer 1):
#   ~/.config/mios/system-prompt.md    ← YOU ARE HERE (per-user dotfile)
#   /etc/mios/ai/system-prompt.md      ← host-local override
#   /usr/share/mios/ai/system.md       ← canonical system prompt (image-baked)
#
# Repo-root AI entry points (context layers below this file):
#   mios.git           → /AI.md    system build/env/architecture layer
#   mios-bootstrap.git → /AI.md    user overlay layer (profile, flatpaks, accounts)
#
# Add personal context, preferred tools, account names, project notes,
# or agent personas BELOW this header. Your version overrides the canonical copy.
#
# ─────────────────────────────────────────────────────────────────────────────
# USER OVERRIDES (edit below this line)
# ─────────────────────────────────────────────────────────────────────────────
