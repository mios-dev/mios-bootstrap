# 'MiOS' Per-User System Prompt

> Per-user overlay. Empty by default — uncomment lines below to
> customize. Higher precedence than `/etc/mios/ai/system-prompt.md`
> and the canonical `/usr/share/mios/ai/system.md`.

## My preferences (uncomment to enable)

# - Default to terse output unless explicitly asked to elaborate.
# - When proposing changes, always include the verification command in
#   the same code fence as the change.
# - Prefer image-time fixes (rebuild) over runtime mutations
#   (`bootc kargs --append`, `firewall-cmd --add-port=...`).

## My pinned context

# - Hardware: <CPU> / <GPU> / <network>
# - Workflow: <e.g. "I primarily develop in WSL2 inside MiOS">
# - Repos I work on: <list>

## My memory hints

# - <Anything you want the agent to remember across sessions.
#   Stored in /var/lib/mios/ai/memory/ when the agent decides
#   it's relevant; this is the seed.>
