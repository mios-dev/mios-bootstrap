#!/usr/bin/env bash
# tests/post-bootstrap-smoke.sh
#
# Acceptance test for the "post-bootstrap = full MiOS environment" contract
# (operator 2026-05-09; feedback_mios_bootstrap_stops_at_dev_ready.md inverted).
#
# RUN FROM INSIDE MiOS-DEV (the podman-MiOS-DEV WSL distro / any deployed
# MiOS host). NOT from Windows. Exits 0 if every P0 check passes, non-zero
# if any P0 fails. P1 / P2 failures warn but don't fail the run.
#
# Invocation:
#   wsl.exe -d MiOS-DEV --user root -- bash /mnt/m/tests/post-bootstrap-smoke.sh
#   or, on a deployed bootc host:
#   sudo bash /usr/share/mios/tests/post-bootstrap-smoke.sh
#
# Trigger: should run automatically at the end of `mios build` once
# Get-MiOS.ps1's auto-chain block reports flatpaks installed, AND on
# operator demand via `mios smoke`.

set -u
PASS=0; FAIL=0; WARN=0
P0_FAIL=0

# ── ANSI helpers (no-color if NO_COLOR set or stdout isn't a tty) ────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else
    G=''; R=''; Y=''; D=''; N=''
fi

ok()   { printf '  %s[+]%s %s\n' "$G" "$N" "$1"; PASS=$((PASS+1)); }
warn() { printf '  %s[~]%s %s%s\n' "$Y" "$N" "$1" "${2:+$D ($2)$N}"; WARN=$((WARN+1)); }
fail() { printf '  %s[!]%s %s%s\n' "$R" "$N" "$1" "${2:+$D ($2)$N}"; FAIL=$((FAIL+1)); [[ "${3:-P0}" == "P0" ]] && P0_FAIL=$((P0_FAIL+1)); }
hdr()  { printf '\n%s── %s ──%s\n' "$D" "$1" "$N"; }

# ── 1. bootc status: deployed image is localhost/mios:* (or ghcr.io/mios-dev/mios:*) ─
# P0. The whole point of the contract: dev VM ≡ MiOS, not vanilla Fedora.
hdr "bootc deployment"
if ! command -v bootc >/dev/null 2>&1; then
    fail "bootc not installed" "host isn't bootc-managed -- post-bootstrap state cannot be MiOS" P0
else
    deployed="$(bootc status --format=json 2>/dev/null | grep -oE '"image":[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"image":[[:space:]]*"([^"]*)"/\1/')"
    if [[ -z "${deployed}" ]]; then
        fail "bootc status returned no booted image" "" P0
    elif [[ "${deployed}" == *"localhost/mios"* ]] || [[ "${deployed}" == *"ghcr.io/mios-dev/mios"* ]] || [[ "${deployed}" == *"/mios:"* ]]; then
        ok "bootc deployed: ${deployed}"
    else
        fail "bootc deployed image is NOT MiOS" "${deployed}" P0
    fi
fi

# ── 2. fastfetch / /etc/os-release: identifies as MiOS, not bare Fedora ──────
# P0. Branding without substance is the regression we're hunting.
hdr "OS identity"
if [[ -r /etc/os-release ]]; then
    osr_pretty="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
    osr_id="$(. /etc/os-release; echo "${ID:-}")"
    if [[ "${osr_pretty}" == *MiOS* ]] || [[ "${osr_id}" == "mios" ]]; then
        ok "/etc/os-release identifies host as MiOS (${osr_pretty})"
    else
        fail "/etc/os-release does not identify as MiOS" "PRETTY_NAME=${osr_pretty}" P0
    fi
else
    fail "/etc/os-release missing" "" P0
fi

# ── 3. mios-flatpak-install.service oneshot completed ───────────────────────
# P0. The "block bootstrap until flatpaks installed" directive (operator
# 2026-05-09) means this oneshot must reach inactive(success) before the
# Windows-side bootstrap returns. If still 'activating' the test caller
# should poll-retry rather than fail outright.
hdr "first-boot flatpak installer"
if systemctl list-unit-files mios-flatpak-install.service >/dev/null 2>&1; then
    state="$(systemctl is-active mios-flatpak-install.service 2>/dev/null || true)"
    result="$(systemctl show mios-flatpak-install.service --property=Result --value 2>/dev/null || true)"
    case "${state}" in
        inactive)
            if [[ "${result}" == "success" ]]; then
                ok "mios-flatpak-install.service completed successfully"
            else
                fail "mios-flatpak-install.service inactive but result=${result}" "" P0
            fi
            ;;
        active)    warn "mios-flatpak-install.service still running" "re-run smoke after it finishes" ;;
        activating) warn "mios-flatpak-install.service activating" "still installing flatpaks" ;;
        failed)    fail "mios-flatpak-install.service FAILED" "journalctl -u mios-flatpak-install" P0 ;;
        *)         warn "mios-flatpak-install.service state unknown" "${state}" ;;
    esac
else
    fail "mios-flatpak-install.service unit not installed" "" P0
fi

# ── 4. Required flatpaks are present in the system installation ─────────────
# P0 for Epiphany / Nautilus / GNOME runtime; P1 for the rest.
hdr "system flatpak inventory"
required_p0=( org.gnome.Epiphany org.gnome.Nautilus )
required_p1=( org.gnome.Software com.github.tchx84.Flatseal org.gnome.Ptyxis )
gnome_runtime_present=0

if command -v flatpak >/dev/null 2>&1; then
    flat_list="$(flatpak list --system --columns=application 2>/dev/null || true)"
    runtime_list="$(flatpak list --system --runtime --columns=application 2>/dev/null || true)"
    for app in "${required_p0[@]}"; do
        if printf '%s\n' "${flat_list}" | grep -Fxq "${app}"; then ok "flatpak: ${app}"; else fail "flatpak missing: ${app}" "" P0; fi
    done
    for app in "${required_p1[@]}"; do
        if printf '%s\n' "${flat_list}" | grep -Fxq "${app}"; then ok "flatpak: ${app}"; else warn "flatpak missing: ${app}" "P1 -- not blocking" ; fi
    done
    if printf '%s\n' "${runtime_list}" | grep -Eq '^org\.gnome\.(Platform|Sdk)$'; then
        ok "GNOME runtime installed"; gnome_runtime_present=1
    else
        fail "GNOME runtime (org.gnome.Platform / Sdk) not installed" "" P0
    fi
else
    fail "flatpak CLI not installed" "" P0
fi

# ── 5. Epiphany launches (smoke -- WSLg or whatever the local display is) ───
# P1. Test --version since headless contexts can't actually open a window.
hdr "epiphany launch smoke"
if [[ ${gnome_runtime_present} -eq 1 ]] && command -v flatpak >/dev/null 2>&1; then
    if timeout 30 flatpak run org.gnome.Epiphany --version >/dev/null 2>&1; then
        ok "flatpak run org.gnome.Epiphany --version returned 0"
    else
        warn "flatpak run org.gnome.Epiphany --version failed" "may be display-bound; not P0"
    fi
else
    warn "skipping epiphany launch -- prerequisites failed earlier"
fi

# ── 6. mios-build-driver present + executable (image overlay or staged copy) ─
# P0. Without it, `mios build` re-runs cannot drive the build.
hdr "mios-build-driver"
if [[ -x /usr/libexec/mios/mios-build-driver ]]; then
    sz="$(stat -c%s /usr/libexec/mios/mios-build-driver 2>/dev/null || echo '?')"
    ok "/usr/libexec/mios/mios-build-driver present (${sz} bytes, executable)"
else
    fail "/usr/libexec/mios/mios-build-driver missing or not executable" "" P0
fi

# ── 7. Quadlet enable flags ([quadlets.enable] in mios.toml) ─────────────────
# P1. Skip if mios.toml resolver helper isn't available.
hdr "quadlet enablement"
toml_get_bool() {
    local section="$1" key="$2" toml found
    for toml in "${HOME}/.config/mios/mios.toml" /etc/mios/mios.toml /usr/share/mios/mios.toml; do
        [[ -r "${toml}" ]] || continue
        found="$(awk -v section="[${section}]" -v key="${key}" '
            $0 == section { in_sec = 1; next }
            /^\[/         { in_sec = 0 }
            in_sec && $1 == key { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
        ' "${toml}")"
        if [[ -n "${found}" ]]; then echo "${found}"; return 0; fi
    done
    return 1
}
for unit in mios-ai mios-ceph mios-k3s mios-forge ollama; do
    enabled_in_toml="$(toml_get_bool 'quadlets.enable' "${unit}" 2>/dev/null || echo true)"
    sysd_state="$(systemctl is-enabled "${unit}.service" 2>/dev/null || echo not-installed)"
    if [[ "${enabled_in_toml}" == "true" ]]; then
        case "${sysd_state}" in
            enabled|generated|static|alias) ok "quadlet ${unit}: ${sysd_state}" ;;
            disabled)                       warn "quadlet ${unit}: TOML says enable=true but systemd says disabled" ;;
            not-installed)                  warn "quadlet ${unit}: not installed (Quadlet may not have generated yet)" ;;
            *)                              warn "quadlet ${unit}: state=${sysd_state}" ;;
        esac
    fi
done

# ── 8. mios.toml resolver round-trip ────────────────────────────────────────
# P1. Confirms the SSOT chain works. Reads [meta].mios_version from
# /usr/share/mios/mios.toml and prints it.
hdr "mios.toml resolver"
ver="$(toml_get_bool 'meta' 'mios_version' 2>/dev/null | tr -d '"' || true)"
if [[ -n "${ver}" ]]; then
    ok "[meta].mios_version resolves to ${ver}"
else
    warn "[meta].mios_version did not resolve" "vendor SSOT may be missing"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
printf '%s%s pass=%d fail=%d warn=%d (P0 fail=%d)%s\n' "${D}" "==============================" "${PASS}" "${FAIL}" "${WARN}" "${P0_FAIL}" "${N}"
if [[ ${P0_FAIL} -gt 0 ]]; then
    printf '%sFAIL%s -- post-bootstrap acceptance failed (%d P0 issues). MiOS-DEV is NOT full-parity MiOS.\n' "${R}" "${N}" "${P0_FAIL}"
    exit 1
fi
printf '%sOK%s -- post-bootstrap acceptance passes. MiOS-DEV ≡ MiOS.\n' "${G}" "${N}"
exit 0
