#!/usr/bin/env bash
# AI-hint: Thin Linux bash dispatcher for the mios-install unified provisioning
# funnel -- validates a <target>, resolves it to ONE of the existing
# mios-bootstrap entrypoints (build-mios.sh, cat/MiOS-Cat.sh, mios-build,
# mios-update; the Windows-only cat/autounattend/*.ps1 + build-mios.ps1
# entrypoints get printed as ready-to-run guidance, never executed here),
# builds that entrypoint's real argv/env, and execs it. No business logic is
# duplicated from any wrapped script.
# The themed logger, layered SSOT resolver, find_mios_bin, self-elevate, and repo-fetch are the ONE
# shared contract in installation/mios-common.sh (sourced below); this file adds only the dispatcher.
# AI-related: mios-common.sh, build-mios.sh, cat/MiOS-Cat.sh, cat/MiOS-Cat.bat,
# cat/autounattend/Build-MiOSXboxISO.ps1, cat/autounattend/Deploy-MiOSXbox.ps1,
# cat/autounattend/Invoke-MiOSProvision.ps1, cat/autounattend/Build-MiOSSeed.ps1,
# build-mios.ps1, mios-build, mios-update, mios.toml, installation/mios-install.ps1,
# installation/mios-install.bat, installation/README.md
# AI-functions: usage, resolve_flash_or_live, resolve_live, resolve_flash,
# resolve_build_mios_sh, resolve_fedora, resolve_bootc, resolve_mios_update_like,
# resolve_update, resolve_build, resolve_xbox, resolve_oci, resolve_seed
#   (shared from mios-common.sh: mios_ssot_value, mios_ssot_path, find_mios_bin,
#    mios_self_elevate, mios_ensure_repo, log_info, log_ok, log_warn, log_err, log_phase, die)
#
# mios-install.sh -- unified MiOS provisioning dispatcher (Linux)
#
# One dispatcher for launching provisioning from ANY stage and targeting a
# specific deployment TYPE (live / xbox / fedora / bootc / oci / seed /
# flash / build / update). THIS FILE NEVER MOVES, RENAMES, OR REWRITES THE
# EXISTING ENTRYPOINTS -- it only builds the right argv/env for one of them
# and launches it. See installation/README.md for the full grammar, the
# target -> entrypoint mapping table, and the design rationale (what's a
# genuine flag vs. best-effort per target/stage).
#
# Usage:
#   mios-install.sh <target> [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]
#
# Targets natively runnable FROM Linux: fedora, bootc, build, update, flash,
# live. xbox/oci/seed wrap Windows-only entrypoints (ISO servicing/DISM,
# WSL2/Hyper-V orchestration) -- this script prints the exact command to run
# on a Windows host instead of pretending to run them here.
#
# Examples:
#   ./mios-install.sh flash --dry-run
#   sudo -E ./mios-install.sh fedora --unattended            # (or let it self-sudo)
#   ./mios-install.sh bootc --type upgrade --stage prereqs   # -> mios-update --check
#   ./mios-install.sh update --check                         # -> mios-update --check
#   ./mios-install.sh build -- --tag mios:test
#
# Exit code: mirrors the wrapped entrypoint's exit code (final step is
# `exec`, i.e. process replacement -- same convention as `"$@"; exit $?`).

set -euo pipefail

# ============================================================================
# Paths -- resolved relative to THIS script so it works from any CWD/symlink.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_MIOS_SH="${ROOT}/build-mios.sh"
CAT_DIR="${ROOT}/cat"
MIOS_CAT_SH="${CAT_DIR}/MiOS-Cat.sh"

# ============================================================================
# Shared library -- ONE SSOT-[colors] themed logger (log_info/ok/warn/err/phase/
# die), ONE layered SSOT resolver (mios_ssot_value / mios_ssot_path, the same
# user>host>vendor order as usr/lib/mios/mios_toml.py), find_mios_bin, ONE
# self-elevate (mios_self_elevate), ONE repo-fetch (mios_ensure_repo).
# Set _MIOS_REPO_ROOT BEFORE sourcing so the resolver includes this checkout's
# mios.toml as the repo-local layer (and the theme reads its [colors]).
# ============================================================================
_MIOS_REPO_ROOT="$ROOT"
# shellcheck source=installation/mios-common.sh
. "${SCRIPT_DIR}/mios-common.sh"

# ============================================================================
# Usage
# ============================================================================
usage() {
    cat <<'EOF'
mios-install.sh -- unified MiOS provisioning dispatcher (Linux)

  mios-install.sh <target> [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]

  <target>      live | xbox | fedora | bootc | oci | seed | flash | build | update
  --type NAME   narrows the target to a concrete flavor (per-target; omit for the default)
  --stage NAME  prereqs | fetch | service | iso | flash (best-effort unless the target's
                row in installation/README.md marks it REAL; omit to run the whole pipeline)
  --dry-run     print the resolved command + env, execute nothing, exit 0
  --unattended  maps to whatever real non-interactive switch the target already has;
                if none exists, this script says so and still runs interactively
  -- ARGS       everything after a literal `--` is appended verbatim to the invocation
                (also: any unrecognized flag, WITHOUT `--`, is treated the same way --
                e.g. `mios-install.sh update --check` == `mios-install.sh update -- --check`)

Native on Linux: fedora, bootc, build, update, flash, live.
Windows-only (guidance printed, not executed here): xbox, oci, seed.

Examples:
  mios-install.sh flash --dry-run
  mios-install.sh fedora --unattended
  mios-install.sh bootc --type upgrade --stage prereqs   # -> mios-update --check
  mios-install.sh update --check                         # -> mios-update --check
  mios-install.sh build -- --tag mios:test

Full grammar, the target -> entrypoint mapping table, and per-stage
REAL-vs-best-effort notes: installation/README.md.
EOF
}

# ============================================================================
# Argument parsing
# ============================================================================
ORIG_ARGS=("$@")

if [[ $# -eq 0 ]]; then usage; exit 1; fi
case "$1" in -h|--help|help) usage; exit 0 ;; esac
case "$1" in -*) die "missing required <target> as the first argument (got '$1'). Run with --help." ;; esac

TARGET="$1"; shift
TYPE=""
STAGE=""
DRY_RUN=0
UNATTENDED=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)      TYPE="${2:-}"; shift 2 ;;
        --type=*)    TYPE="${1#*=}"; shift ;;
        --stage)     STAGE="${2:-}"; shift 2 ;;
        --stage=*)   STAGE="${1#*=}"; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --unattended) UNATTENDED=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; PASSTHROUGH=("$@"); break ;;
        *)
            # Lenient escape hatch: an unrecognized flag (no literal `--`
            # given) is treated as the start of the passthrough tail rather
            # than a hard parse error -- this is what makes
            # `mios-install.sh update --check` work the same as
            # `mios-install.sh update -- --check`.
            log_info "note: unrecognized flag '$1' -- treating it and everything after as passthrough args (same as '-- $1 ...')."
            PASSTHROUGH=("$@")
            break
            ;;
    esac
done

case "$STAGE" in
    ""|prereqs|fetch|service|iso|flash) ;;
    *) die "invalid --stage '${STAGE}' (valid: prereqs|fetch|service|iso|flash)" ;;
esac

# ============================================================================
# Per-target resolution. Each resolve_* function fills these globals:
#   CMD               argv array to exec
#   ENV               ("KEY=VALUE" ...) to export before exec
#   REQUIRES_ROOT      1 -> dispatcher self-execs `sudo -E "$0" "${ORIG_ARGS[@]}"`
#                       (only for targets whose entrypoint does NOT already
#                       self-elevate -- mios-build/mios-update do it
#                       themselves, so those leave this 0)
#   FORBIDS_ROOT        1 -> entrypoint errors out if run as root (MiOS-Cat.sh)
#   STAGE_NOTES         array of caveats printed before running (best-effort
#                       stage isolation, missing unattended support, etc.)
#   WINDOWS_GUIDANCE    if set, nothing is executed -- this text is printed
#                       instead (the target's entrypoint is Windows-only)
# ============================================================================
CMD=(); ENV=(); STAGE_NOTES=(); REQUIRES_ROOT=0; FORBIDS_ROOT=0; WINDOWS_GUIDANCE=""

# --- live / flash: cat/MiOS-Cat.sh (Linux-native Ventoy/MediCat kickstart) --
# Source-verified: MiOS-Cat.sh's CheckNotElevated EXITS if EUID==0 ("do not
# run using sudo") -- it calls sudo itself, per privileged step. Must run as
# a normal user, never pre-sudo'd. It also has zero CLI-arg parsing and zero
# non-interactive mode: --unattended cannot be honored, --stage cannot
# isolate anything (one monolithic interactive pipeline).
resolve_flash_or_live() {
    local target_name="$1"
    TYPE="${TYPE:-usb}"
    case "$TYPE" in
        usb|live) ;;
        *) die "target '${target_name}' only supports --type usb (got '${TYPE}')" ;;
    esac
    [[ -f "$MIOS_CAT_SH" ]] || die "cat/MiOS-Cat.sh not found at ${MIOS_CAT_SH}"
    FORBIDS_ROOT=1
    CMD=(env -C "$CAT_DIR" bash ./MiOS-Cat.sh "${PASSTHROUGH[@]}")
    STAGE_NOTES+=("stage isolation: NONE -- MiOS-Cat.sh is one monolithic interactive pipeline; --stage is documentation-only here.")
    [[ -n "$STAGE" ]] && STAGE_NOTES+=("--stage ${STAGE} requested but not isolable; running the full pipeline.")
    if (( UNATTENDED )); then
        STAGE_NOTES+=("--unattended requested but MiOS-Cat.sh has no non-interactive mode on Linux -- it WILL prompt for the USB device, Medicat source, and partition-scheme choice.")
    fi
    if [[ "$target_name" == "live" ]]; then
        STAGE_NOTES+=("'live' and 'flash' resolve to the SAME call today -- MiOS-Cat.sh has no lighter zero-install mode exposed via flag/env yet (documented open design question, not solved here).")
    fi
}
resolve_live()  { resolve_flash_or_live live; }
resolve_flash() { resolve_flash_or_live flash; }

# --- fedora / bootc(switch): build-mios.sh -----------------------------
# Source-verified: build-mios.sh's main() calls require_root() which EXITS
# (telling the operator to re-run with sudo) rather than self-elevating --
# so THIS dispatcher does the self-sudo for it. main() also never reads
# "$@" -- it is entirely env-var driven, so passthrough args are accepted
# for grammar consistency but have no effect on this target; say so.
resolve_build_mios_sh() {
    local mode="$1"   # fhs | bootc
    [[ -f "$BUILD_MIOS_SH" ]] || die "build-mios.sh not found at ${BUILD_MIOS_SH}"
    REQUIRES_ROOT=1
    ENV+=("INSTALL_MODE=${mode}")
    if (( UNATTENDED )); then
        ENV+=("MIOS_PROMPT_TIMEOUT=1")
        [[ "$mode" == "fhs" ]] && ENV+=("MIOS_FHS_TOTAL_ROOT_MERGE=1")
        if [[ -z "${MIOS_PASSWORD:-}" ]]; then
            STAGE_NOTES+=("--unattended set but MIOS_PASSWORD is not exported -- the Linux-user password prompt will still block (prompt_password() only auto-fills from \$MIOS_PASSWORD). Export it before invoking for a truly unattended run.")
        fi
    fi
    CMD=(bash "$BUILD_MIOS_SH")
    STAGE_NOTES+=("stage isolation: BEST-EFFORT only -- build-mios.sh is one monolithic Phase-0..4 script with no --stage flags and no CLI arg parsing at all (main() never reads \"\$@\"); MIOS_REPO/BOOTSTRAP_REPO env vars scope WHAT is fetched, not whether a stage runs.")
    [[ -n "$STAGE" ]] && STAGE_NOTES+=("--stage ${STAGE} noted but not isolable here; the full pipeline runs regardless.")
    if (( ${#PASSTHROUGH[@]} )); then
        STAGE_NOTES+=("passthrough args (${PASSTHROUGH[*]}) accepted for grammar consistency but ignored -- build-mios.sh takes no CLI args.")
    fi
}

resolve_fedora() {
    TYPE="${TYPE:-fhs}"
    [[ "$TYPE" == "fhs" ]] || die "target 'fedora' only supports --type fhs (got '${TYPE}')"
    resolve_build_mios_sh fhs
}

resolve_bootc() {
    TYPE="${TYPE:-switch}"
    case "$TYPE" in
        switch)
            resolve_build_mios_sh bootc
            STAGE_NOTES+=("'bootc switch' only actually engages bootc mode if THIS host is already bootc-booted (build-mios.sh's detect_host_kind checks 'bootc status'); on a plain Fedora (non-bootc) host it silently falls back to the fhs path regardless of INSTALL_MODE.")
            STAGE_NOTES+=("the target image is NOT settable via an IMAGE_TAG env var (source-verified: gather_user_choices() unconditionally re-prompts via prompt_default, ignoring any pre-set IMAGE_TAG) -- pin it in mios.toml [image].ref before an --unattended run, or omit --unattended and answer the prompt.")
            ;;
        upgrade)
            resolve_mios_update_like "bootc --type upgrade"
            ;;
        *) die "target 'bootc' supports --type switch|upgrade (got '${TYPE}')" ;;
    esac
}

# --- bootc(upgrade) / update: mios-update -----------------------------
# Source-verified (per project record): mios-update already self-execs sudo
# internally if not root -- this dispatcher must NOT pre-sudo it too.
resolve_mios_update_like() {
    local via="$1"   # "update" or "bootc --type upgrade" -- both resolve identically, only the error text differs
    local bin
    if bin="$(find_mios_bin mios-update)"; then :; else
        if (( DRY_RUN )); then bin="mios-update"; else
            die "mios-update not found on PATH or under /usr/bin -- target '${via}' requires an already-provisioned MiOS host (mios-update ships with the OS image, not this bootstrap checkout)."
        fi
    fi
    local args=()
    case "$STAGE" in
        prereqs) args+=(--check); STAGE_NOTES+=("--stage prereqs -> mios-update --check (dry preview, REAL isolation).") ;;
        flash)   args+=(--apply); STAGE_NOTES+=("--stage flash -> mios-update --apply (stages + reboots, REAL isolation).") ;;
        fetch|service|iso) STAGE_NOTES+=("--stage ${STAGE} collapses into bootc-upgrade internals -- not isolable here; running with no stage flag.") ;;
        "") ;;
    esac
    if (( UNATTENDED )) && [[ "$STAGE" != prereqs && "$STAGE" != flash ]]; then
        args+=(--apply)
        STAGE_NOTES+=("--unattended -> mios-update --apply (closest analog; the script itself is already non-interactive).")
    fi
    args+=("${PASSTHROUGH[@]}")
    CMD=("$bin" "${args[@]}")
}

resolve_update() {
    case "$TYPE" in
        ""|update) ;;
        repo)
            WINDOWS_GUIDANCE="target 'update' --type repo is Windows-only: it maps to 'cat\\MiOS-Cat.bat update' (git fetch/pull of BOTH C:\\MiOS and C:\\mios-bootstrap). There is no Linux row for this in installation/README.md -- run it on the Windows checkout instead, or just 'git pull' this repo yourself."
            return
            ;;
        *) die "target 'update' supports --type repo (Windows-only) or the default mios-update passthrough (got '${TYPE}')" ;;
    esac
    resolve_mios_update_like update
}

# --- build: mios-build --------------------------------------------------
resolve_build() {
    [[ -z "$TYPE" ]] || die "target 'build' takes no --type (got '${TYPE}')"
    local bin
    if bin="$(find_mios_bin mios-build)"; then :; else
        if (( DRY_RUN )); then bin="mios-build"; else
            die "mios-build not found on PATH or under /usr/bin -- this target requires an already-provisioned MiOS host (it ships with the OS image, not this bootstrap checkout)."
        fi
    fi
    local args=()
    case "$STAGE" in
        flash)   args+=(--apply); STAGE_NOTES+=("--stage flash -> mios-build --apply (build + switch + reboot, REAL isolation).") ;;
        prereqs) STAGE_NOTES+=("--stage prereqs: N/A for mios-build -- no isolable preflight-only mode.") ;;
        fetch|service|iso) STAGE_NOTES+=("--stage ${STAGE}: N/A -- mios-build operates on the tree already present on this host; no fetch/iso stages.") ;;
        "") ;;
    esac
    if (( UNATTENDED )) && [[ "$STAGE" != flash ]]; then
        args+=(--apply)
        STAGE_NOTES+=("--unattended -> mios-build --apply (closest analog; the script itself is always non-interactive).")
    fi
    args+=("${PASSTHROUGH[@]}")
    CMD=("$bin" "${args[@]}")
}

# --- xbox / oci / seed: Windows-only entrypoints ------------------------
# These wrap DISM/oscdimg servicing (xbox) or WSL2+Hyper-V orchestration
# (oci, seed) -- none of that exists on Linux, so this dispatcher prints
# the exact command to paste on a Windows host rather than faking a run.
resolve_xbox() {
    TYPE="${TYPE:-iso}"
    local toml; toml="$(mios_ssot_path)"
    local script args_str extra=""
    (( ${#PASSTHROUGH[@]} )) && extra=" ${PASSTHROUGH[*]}"
    case "$TYPE" in
        iso)
            script='cat\autounattend\Build-MiOSXboxISO.ps1'
            args_str="-TomlPath '<ssot>'"
            case "$STAGE" in
                fetch|service|iso|flash) args_str+=" -SkipPrereqs" ;;
            esac
            [[ -n "$STAGE" ]] && STAGE_NOTES+=("--stage ${STAGE}: only -SkipPrereqs is a REAL flag at this wrapper level; service/iso isolation needs New-MiOSISO.ps1 directly.")
            ;;
        vm)
            script='cat\autounattend\Deploy-MiOSXbox.ps1'
            args_str="-TomlPath '<ssot>' -VMName MiOS-XBOX-Test -LogDir C:\\MiOS\\logs"
            if [[ "$STAGE" == flash ]]; then
                args_str+=" -SkipBuild"
                if (( ${#PASSTHROUGH[@]} == 0 )); then
                    args_str+=" -SourceIso <path-to-existing-iso>"
                fi
                STAGE_NOTES+=("--stage flash -> -SkipBuild (REAL: create+boot the VM only, against an existing ISO). Supply the ISO path via -- -SourceIso <path> (shown below if not already given).")
            fi
            ;;
        provision)
            script='cat\autounattend\Invoke-MiOSProvision.ps1'
            args_str="-TomlPath '<ssot>'"
            (( UNATTENDED )) && args_str+=" -SkipBootstrap"
            ;;
        *) die "target 'xbox' supports --type iso|vm|provision (got '${TYPE}')" ;;
    esac
    WINDOWS_GUIDANCE="target 'xbox' (--type ${TYPE}) is a Windows-only entrypoint (DISM servicing / Hyper-V) -- it cannot run on Linux. On a Windows host, run:
  powershell -NoProfile -ExecutionPolicy Bypass -File ${script} ${args_str}${extra}
<ssot> resolves like every existing entrypoint: '..\\mios.toml' relative to the script, else C:\\MiOS\\usr\\share\\mios\\mios.toml. mios.toml on THIS checkout: ${toml}"
}

resolve_oci() {
    TYPE="${TYPE:-local}"
    case "$TYPE" in local|full|push) ;; *) die "target 'oci' supports --type local|full|push (got '${TYPE}')" ;; esac
    local unattended_flag="" skip_bib_note=""
    (( UNATTENDED )) && unattended_flag=" -Unattended"
    case "$TYPE" in
        local) skip_bib_note='$env:MIOS_SKIP_BIB=1 before calling (OCI image only -- what MiOS-Cat.bat''s build_oci menu item sets)' ;;
        full)  skip_bib_note='MIOS_SKIP_BIB left UNSET (full raw/iso/qcow2/vhd/wsl2 matrix -- what build_all sets)' ;;
        push)  skip_bib_note='MIOS_SKIP_BIB left UNSET, plus $env:MIOS_GITHUB_TOKEN exported first for the ghcr push' ;;
    esac
    local extra=""
    (( ${#PASSTHROUGH[@]} )) && extra=" ${PASSTHROUGH[*]}"
    WINDOWS_GUIDANCE="target 'oci' (--type ${TYPE}) is a Windows-only entrypoint -- it cannot run on Linux. On a Windows host, run:
  ${skip_bib_note}
  powershell -NoProfile -ExecutionPolicy Bypass -File build-mios.ps1${unattended_flag}${extra}
IMPORTANT (source-verified against the CURRENT build-mios.ps1): its -BootstrapOnly/-BuildOnly/-FullBuild switches are hard-forced no-ops now. This step only acks + provisions the MiOS-DEV podman machine + installs the 'mios build' launcher -- it does NOT by itself produce a finished OCI image or the BIB matrix any more. The actual build happens afterward when the operator runs 'mios build' inside the provisioned MiOS terminal (SSHes into MiOS-DEV -> /usr/libexec/mios/mios-build-driver). See installation/README.md's 'Verified caveat -- oci and MIOS_SKIP_BIB' section."
}

resolve_seed() {
    TYPE="${TYPE:-dev}"
    [[ "$TYPE" == "dev" ]] || die "target 'seed' supports --type dev (got '${TYPE}')"
    local toml; toml="$(mios_ssot_path)"
    local extra=""
    (( ${#PASSTHROUGH[@]} )) && extra=" ${PASSTHROUGH[*]}"
    WINDOWS_GUIDANCE="target 'seed' (--type dev) is a Windows-only entrypoint (exports an existing MiOS-DEV WSL2 distro + OCI image as an offline seed blob) -- it cannot run on Linux. On a Windows host, run:
  powershell -NoProfile -ExecutionPolicy Bypass -File cat\\autounattend\\Build-MiOSSeed.ps1 -TomlPath '<ssot>'${extra}
--stage/--unattended have no mapping here -- the script has no stage flags and (per source) no interactive prompts, so it already runs unattended. mios.toml on THIS checkout: ${toml}"
}

resolve_config() {
    local port
    port="$(mios_ssot_value ports agent_pipe 8640)"
    local url="http://localhost:${port}/configure"
    local html_path="${ROOT}/usr/share/mios/configurator/mios.html"
    log_info "Opening MiOS Configurator at ${url} ..."
    if command -v xdg-open >/dev/null 2>&1; then
        CMD=(xdg-open "$url")
    elif command -v python3 >/dev/null 2>&1; then
        CMD=(python3 -m webbrowser "$url")
    elif [[ -f "$html_path" ]]; then
        log_warn "No browser launcher found; offline HTML available at ${html_path}"
        CMD=(echo "Offline configurator HTML: ${html_path}")
    else
        log_warn "No browser launcher found -- open ${url} manually."
        CMD=(true)
    fi
}

# ============================================================================
# Dispatch
# ============================================================================
case "$TARGET" in
    live)   resolve_live ;;
    flash)  resolve_flash ;;
    xbox)   resolve_xbox ;;
    fedora) resolve_fedora ;;
    bootc)  resolve_bootc ;;
    oci)    resolve_oci ;;
    seed)   resolve_seed ;;
    build)  resolve_build ;;
    update) resolve_update ;;
    config|configure) resolve_config ;;
    default|Default|offlinesync|OfflineSync|buildxboxiso|BuildXboxISO|flashusb|FlashUSB)
        die "'${TARGET}' is a Get-MiOS.ps1 -Action value, not a mios-install target. mios-install only runs AFTER Get-MiOS.ps1 has already cloned this repo locally -- it does not re-wrap Get-MiOS.ps1's bootstrap/offline-sync actions (installation/README.md, 'Out of scope')." ;;
    *)
        die "unknown target '${TARGET}'. Valid targets: live xbox fedora bootc oci seed flash build update config (run with --help)" ;;
esac

resolve_target_prereqs() {
    local target="$1"
    log_info "Resolving prerequisites for target '${target}'..."
    case "$target" in
        build|fedora|bootc)
            if command -v dnf >/dev/null 2>&1; then
                for pkg in git curl podman; do
                    if ! rpm -q "$pkg" >/dev/null 2>&1; then
                        log_info "Target prerequisite missing: ${pkg}"
                        (( DRY_RUN )) || sudo dnf install -y "$pkg" || true
                    fi
                done
            fi
            if ! command -v cargo >/dev/null 2>&1 && ! command -v rustup >/dev/null 2>&1; then
                log_info "Target prerequisite missing: rustup/cargo for native tools"
                if (( ! DRY_RUN )) && command -v dnf >/dev/null 2>&1; then
                    sudo dnf install -y cargo rust || true
                fi
            fi
            ;;
        live|flash)
            if command -v dnf >/dev/null 2>&1; then
                for pkg in git curl podman ventoy; do
                    if ! rpm -q "$pkg" >/dev/null 2>&1; then
                        log_info "Target prerequisite missing: ${pkg}"
                        (( DRY_RUN )) || sudo dnf install -y "$pkg" || true
                    fi
                done
            fi
            ;;
        update)
            if command -v dnf >/dev/null 2>&1; then
                for pkg in git curl; do
                    if ! rpm -q "$pkg" >/dev/null 2>&1; then
                        log_info "Target prerequisite missing: ${pkg}"
                        (( DRY_RUN )) || sudo dnf install -y "$pkg" || true
                    fi
                done
            fi
            ;;
    esac
}

# ============================================================================
# Windows-only targets: print guidance, execute nothing.
# ============================================================================
if [[ -n "$WINDOWS_GUIDANCE" ]]; then
    log_warn "target '${TARGET}' has no native Linux entrypoint"
    printf '\n%s\n\n' "$WINDOWS_GUIDANCE" >&2
    if (( DRY_RUN )); then exit 0; else exit 2; fi
fi

# ============================================================================
# Print any best-effort/caveat notes before doing anything real.
# ============================================================================
if (( ${#STAGE_NOTES[@]} )); then
    for _n in "${STAGE_NOTES[@]}"; do log_warn "$_n"; done
fi

# ============================================================================
# --dry-run: print the resolved env + command, execute nothing.
# ============================================================================
if (( DRY_RUN )); then
    log_phase "DRY RUN -- target=${TARGET} type=${TYPE:-<default>} stage=${STAGE:-<full pipeline>} unattended=${UNATTENDED}"
    if (( ${#ENV[@]} )); then
        log_info "Environment:"
        for _kv in "${ENV[@]}"; do printf '    %s\n' "$_kv"; done
    fi
    log_info "Command:"
    printf '    '
    for _a in "${CMD[@]}"; do printf '%q ' "$_a"; done
    printf '\n'
    exit 0
fi

# ============================================================================
# Root handling. Self-elevate only for targets whose entrypoint does NOT
# already self-sudo (build-mios.sh); never blanket-elevate; MiOS-Cat.sh must
# NEVER be run as root (source-verified CheckNotElevated).
# ============================================================================
if (( FORBIDS_ROOT )) && [[ "$(id -u)" -eq 0 ]]; then
    die "target '${TARGET}' must NOT run as root/sudo -- the underlying script (MiOS-Cat.sh) self-invokes sudo internally for the individual steps that need it, and exits immediately if launched already-elevated. Re-run as your normal user."
fi

if (( REQUIRES_ROOT )); then
    # mios_self_elevate (mios-common) no-ops if already root, else exec's sudo -E.
    mios_self_elevate "$0" "${ORIG_ARGS[@]}"
fi

resolve_target_prereqs "$TARGET"

# ============================================================================
# Apply env, launch. exec = process replacement, exit code mirrors the
# wrapped entrypoint exactly (same convention as: "$@"; exit $?).
# ============================================================================
for _kv in "${ENV[@]:-}"; do
    [[ -z "$_kv" ]] && continue
    export "$_kv"
done

log_phase "Launching: ${TARGET}${TYPE:+ (--type ${TYPE})}${STAGE:+ (--stage ${STAGE})}"
exec "${CMD[@]}"
