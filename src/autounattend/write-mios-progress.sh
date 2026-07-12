#!/usr/bin/env bash
# AI-hint: POSIX twin of MiOS-Progress.psm1's Write-MiOSProgress. Runs INSIDE the
# MiOS WSL distro so in-distro provisioning sub-steps (podman load, systemd/Quadlet
# bring-up) report into the SAME single-bar json the Windows driver + full-screen
# app use. Writes /mnt/c/ProgramData/MiOS/provision-state.json with the identical
# schema {schema,phase_index,total_pct(monotonic),reboot_pending,updated,phases[]}
# via a temp+rename atomic replace. SINGLE WRITER: only ever invoked BY the Windows
# driver (MiOS-Provision.ps1) as a serialized sub-step, so it never races the PS
# writer. Uses python3 (present in the Fedora bootc rootfs); degrades to a minimal
# best-effort writer if python3 is somehow absent.
# AI-related: mios-bootstrap, MiOS-Progress.psm1, MiOS-Provision.ps1
# Usage: write-mios-progress.sh --step <id> --pct <0-100> --state <pending|running|done|error> [--reboot-pending 0|1] [--note "..."]
set -u

STATE_ROOT="${MIOS_PROGRESS_ROOT:-/mnt/c/ProgramData/MiOS}"
STATE_FILE="${MIOS_PROGRESS_FILE:-$STATE_ROOT/provision-state.json}"

STEP=""; PCT="0"; PSTATE=""; REBOOT=""; NOTE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --step)           STEP="${2:-}"; shift 2 ;;
        --pct)            PCT="${2:-0}"; shift 2 ;;
        --state)          PSTATE="${2:-}"; shift 2 ;;
        --reboot-pending) REBOOT="${2:-}"; shift 2 ;;
        --note)           NOTE="${2:-}"; shift 2 ;;
        *) echo "write-mios-progress: unknown arg '$1'" >&2; shift ;;
    esac
done

if [ -z "$STEP" ] || [ -z "$PSTATE" ]; then
    echo "write-mios-progress: --step and --state are required" >&2
    exit 2
fi

mkdir -p "$STATE_ROOT" 2>/dev/null || true

# Canonical order + labels + default weights -- MUST mirror MiOS-Progress.psm1.
# Weights are env-overridable (MIOS_W_<id-with-dashes-as-underscores>) so the same
# operator mios.toml tuning can be threaded in by the driver if desired.
PHASES="wsl-feature seed-stage wsl-import m-volume podman-machine image-load distro-boot firstboot"

if command -v python3 >/dev/null 2>&1; then
    STATE_FILE="$STATE_FILE" STEP="$STEP" PCT="$PCT" PSTATE="$PSTATE" REBOOT="$REBOOT" NOTE="$NOTE" PHASES="$PHASES" python3 - <<'PYEOF'
import json, os, sys, tempfile, datetime

state_file = os.environ["STATE_FILE"]
step  = os.environ["STEP"]
pct   = int(float(os.environ.get("PCT", "0") or 0))
pstate= os.environ["PSTATE"]
reboot= os.environ.get("REBOOT", "")
note  = os.environ.get("NOTE", "")
order = os.environ["PHASES"].split()

labels = {
    "wsl-feature":    "Enabling Windows virtualization",
    "seed-stage":     "Staging the MiOS seed image",
    "wsl-import":     "Importing the MiOS system",
    "m-volume":       "Preparing the MiOS data volume",
    "podman-machine": "Starting the container engine",
    "image-load":     "Loading MiOS containers",
    "distro-boot":    "Starting the MiOS brain",
    "firstboot":      "Finalizing your MiOS",
}
defw = {
    "wsl-feature": 8, "seed-stage": 5, "wsl-import": 30, "m-volume": 5,
    "podman-machine": 10, "image-load": 22, "distro-boot": 15, "firstboot": 5,
}
def weight(pid):
    env = "MIOS_W_" + pid.replace("-", "_")
    try: return float(os.environ.get(env)) if os.environ.get(env) else float(defw[pid])
    except Exception: return float(defw[pid])

# Load existing (atomic writes mean it is never torn); else init all-pending.
st = None
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        st = json.load(fh)
except Exception:
    st = None
if not isinstance(st, dict) or "phases" not in st:
    st = {"schema": 1, "phase_index": 0, "total_pct": 0, "reboot_pending": False,
          "updated": "", "phases": [
              {"id": p, "label": labels[p], "weight": weight(p), "state": "pending", "pct": 0}
              for p in order]}

by_id = {p.get("id"): p for p in st["phases"]}
if step in by_id:
    ph = by_id[step]
    p = max(0, min(100, pct))
    if pstate == "done": p = 100
    if pstate == "pending" and pct <= 0: p = 0
    ph["state"] = pstate
    ph["pct"] = p
    if note: ph["note"] = note

if reboot in ("0", "1"):
    st["reboot_pending"] = (reboot == "1")

# Monotonic weighted aggregate + phase_index.
sumw = 0.0; acc = 0.0; idx = 0; seen = False; all_done = True
for i, ph in enumerate(st["phases"]):
    w = float(ph.get("weight", defw.get(ph.get("id"), 0)))
    sumw += w
    s = ph.get("state", "pending")
    eff = 100.0 if s == "done" else (float(ph.get("pct", 0)) if s in ("running", "error") else 0.0)
    acc += w * (eff / 100.0)
    if s != "done": all_done = False
    if not seen and s != "done":
        idx = i; seen = True
if not seen:
    idx = max(0, len(st["phases"]) - 1)
total = int(round(100.0 * acc / sumw)) if sumw > 0 else 0
total = max(total, int(st.get("total_pct", 0)))   # never go backwards
if all_done: total = 100
st["phase_index"] = idx
st["total_pct"] = total
st["updated"] = datetime.datetime.utcnow().isoformat() + "Z"

d = os.path.dirname(state_file) or "."
fd, tmp = tempfile.mkstemp(prefix=".provision-state.", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(st, fh, indent=2)
    os.replace(tmp, state_file)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    with open(state_file, "w", encoding="utf-8") as fh:
        json.dump(st, fh, indent=2)
PYEOF
    exit 0
fi

# --- Degraded fallback (python3 absent): write a minimal, still-valid single-phase
#     json so the bar keeps rendering. Cannot recompute the weighted aggregate here,
#     so it echoes the phase and a coarse total; the next PS-side write corrects it.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP="$STATE_FILE.$$.tmp"
{
    printf '{ "schema": 1, "phase_index": 0, "total_pct": 0, "reboot_pending": %s, "updated": "%s", "phases": [' \
        "$( [ "$REBOOT" = "1" ] && echo true || echo false )" "$NOW"
    first=1
    for p in $PHASES; do
        [ $first -eq 1 ] || printf ', '
        first=0
        s="pending"; pc=0
        if [ "$p" = "$STEP" ]; then s="$PSTATE"; pc="$PCT"; fi
        printf '{ "id": "%s", "state": "%s", "pct": %s }' "$p" "$s" "$pc"
    done
    printf '] }\n'
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE_FILE" 2>/dev/null || true
exit 0
