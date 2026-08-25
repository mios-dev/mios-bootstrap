#!/usr/bin/env bash
# AI-hint: Thin Linux bash dispatcher for the mios-install unified provisioning
# AI-related: mios-common.sh, build-mios.sh, cat/MiOS-Cat.sh, cat/MiOS-Cat.bat
# AI-functions: usage, resolve_flash_or_live, resolve_live, resolve_flash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_MIOS_SH="${ROOT}/build-mios.sh"
CAT_DIR="${ROOT}/cat"
if [[ ! -d "$CAT_DIR" && -d "${ROOT}/../mios-bootstrap/cat" ]]; then
    CAT_DIR="$(cd "${ROOT}/../mios-bootstrap/cat" && pwd)"
fi
MIOS_CAT_SH="${CAT_DIR}/MiOS-Cat.sh"

_MIOS_REPO_ROOT="$ROOT"
. "${SCRIPT_DIR}/mios-common.sh"

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

ORIG_ARGS=("$@")

if [[ $# -eq 0 ]]; then usage; exit 1; fi
case "$1" in -h|--help|help) usage; exit 0 ;; esac
case "$1" in -*) die "Missing required <target> as the first argument. Run with" ;; esac

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
            log_info "note: unrecognized flag '$1' -- treating it and everything after as passthrough args (same as '-- $1 ...')."
            PASSTHROUGH=("$@")
            break
            ;;
    esac
done

case "$STAGE" in
    ""|prereqs|fetch|service|iso|flash) ;;
    *) die "Invalid" ;;
esac

CMD=(); ENV=(); STAGE_NOTES=(); REQUIRES_ROOT=0; FORBIDS_ROOT=0; WINDOWS_GUIDANCE=""

resolve_flash_or_live() {
    local target_name="$1"
    TYPE="${TYPE:-usb}"
    case "$TYPE" in
        usb|live) ;;
        *) die "Target '${target_name}' only supports" ;;
    esac
    [[ -f "$MIOS_CAT_SH" ]] || die "Cat/MiOS-Cat.sh not found at ${MIOS_CAT_SH}"
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

resolve_build_mios_sh() {
    local mode="$1"   # fhs | bootc
    REQUIRES_ROOT=1
    ENV+=("INSTALL_MODE=${mode}")
    if (( UNATTENDED )); then
        ENV+=("MIOS_PROMPT_TIMEOUT=1")
        [[ "$mode" == "fhs" ]] && ENV+=("MIOS_FHS_TOTAL_ROOT_MERGE=1")
        if [[ -z "${MIOS_PASSWORD:-}" ]]; then
            STAGE_NOTES+=("--unattended set but MIOS_PASSWORD is not exported -- the Linux-user password prompt will still block (prompt_password() only auto-fills from \$MIOS_PASSWORD). Export it before invoking for a truly unattended run.")
        fi
    fi
    if [[ "$mode" == "bootc" ]] && command -v bootc >/dev/null 2>&1 && bootc status >/dev/null 2>&1; then
        local img
        img="$(mios_ssot_value image ref 'ghcr.io/mios-dev/mios:latest')"
        CMD=(bootc switch "$img")
    else
        CMD=(bash "$0" _install_core "$mode")
    fi
}

resolve_fedora() {
    TYPE="${TYPE:-fhs}"
    [[ "$TYPE" == "fhs" ]] || die "Target 'fedora' only supports"
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
        *) die "Target 'bootc' supports" ;;
    esac
}

resolve_mios_update_like() {
    local via="$1"   # "update" or "bootc --type upgrade" -- both resolve identically, only the error text differs
    local bin
    if bin="$(find_mios_bin mios-update)"; then :; else
        if (( DRY_RUN )); then bin="mios-update"; else
            die "Mios-update not found on PATH or under /usr/bin"
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
        *) die "Target 'update' supports" ;;
    esac
    resolve_mios_update_like update
}

resolve_build() {
    [[ -z "$TYPE" ]] || die "Target 'build' takes no"
    local bin
    if bin="$(find_mios_bin mios-build)"; then :; else
        if (( DRY_RUN )); then bin="mios-build"; else
            die "Mios-build not found on PATH or under /usr/bin"
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
        *) die "Target 'xbox' supports" ;;
    esac
    WINDOWS_GUIDANCE="target 'xbox' (--type ${TYPE}) is a Windows-only entrypoint (DISM servicing / Hyper-V) -- it cannot run on Linux. On a Windows host, run:
  powershell -NoProfile -ExecutionPolicy Bypass -File ${script} ${args_str}${extra}
<ssot> resolves like every existing entrypoint: '..\\mios.toml' relative to the script, else C:\\MiOS\\usr\\share\\mios\\mios.toml. mios.toml on THIS checkout: ${toml}"
}

resolve_oci() {
    TYPE="${TYPE:-local}"
    case "$TYPE" in local|full|push) ;; *) die "Target 'oci' supports" ;; esac
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
    [[ "$TYPE" == "dev" ]] || die "Target 'seed' supports"
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

resolve_install_core() {
    local mode="${1:-fhs}"
    if [[ "$mode" != "fhs" && "$mode" != "bootc" ]]; then
        die "Unknown install mode '${mode}'. Supported modes: fhs, bootc"
    fi
    log_err "The installer core is not implemented in this repository."
    log_err "It lives in mios-bootstrap: installation/mios-install.sh do_install_core."
    log_err "Requested mode: ${mode}. Run the installer from mios-bootstrap, or"
    log_err "port do_install_core here -- see AGY-1750."
    CMD=(false)
    return 1
}

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
    # ${PASSTHROUGH[0]} carries the positional mode from the internal re-entry
    # above; --type still wins when a caller sets it explicitly.
    _install_core) resolve_install_core "${TYPE:-${PASSTHROUGH[0]:-fhs}}" ;;
    default|Default|offlinesync|OfflineSync|buildxboxiso|BuildXboxISO|flashusb|FlashUSB)
        die "'${TARGET}' is a Get-MiOS.ps1 -Action value, not a mios-install target. mios-install only runs AFTER Get-MiOS.ps1 has already cloned this repo locally" ;;
    *)
        die "Unknown target '${TARGET}'. Valid targets: live xbox fedora bootc oci seed flash build update config" ;;
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

if [[ -n "$WINDOWS_GUIDANCE" ]]; then
    log_warn "target '${TARGET}' has no native Linux entrypoint"
    printf '\n%s\n\n' "$WINDOWS_GUIDANCE" >&2
    if (( DRY_RUN )); then exit 0; else exit 2; fi
fi

if (( ${#STAGE_NOTES[@]} )); then
    for _n in "${STAGE_NOTES[@]}"; do log_warn "$_n"; done
fi

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

if (( FORBIDS_ROOT )) && [[ "$(id -u)" -eq 0 ]]; then
    die "Target '${TARGET}' must NOT run as root/sudo"
fi

if (( REQUIRES_ROOT )); then
    mios_self_elevate "$0" "${ORIG_ARGS[@]}"
fi

resolve_target_prereqs "$TARGET"

for _kv in "${ENV[@]:-}"; do
    [[ -z "$_kv" ]] && continue
    export "$_kv"
done

log_phase "Launching: ${TARGET}${TYPE:+ (--type ${TYPE})}${STAGE:+ (--stage ${STAGE})}"
exec "${CMD[@]}"
