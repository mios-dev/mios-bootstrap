#!/bin/bash
# 'MiOS' Bootstrap (Linux / WSL2) -- legacy redirector.
#
# Renamed to build-mios.sh to align with the cross-platform entry-point
# convention (build-mios.{sh,ps1}). Redirector kept for legacy shortcuts
# and curl|bash one-liners that point at the old bootstrap.sh URL.
#
# By invoking this script you acknowledge AGREEMENTS.md (Apache-2.0 main
# + bundled-component licenses in LICENSES.md + attribution in
# usr/share/doc/mios/reference/credits.md). 'MiOS' is a research project (pronounced 'MyOS';
# generative, seed-script-derived).
set -euo pipefail

case "${MIOS_AGREEMENT_BANNER:-}" in
    quiet|silent|off|0|false|FALSE) ;;
    *)
        cat >&2 <<'__EOF__'
[mios] By invoking bootstrap.sh you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in usr/share/doc/mios/reference/credits.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
__EOF__
        ;;
esac

target="$(dirname "${BASH_SOURCE[0]}")/build-mios.sh"
if [[ -r "$target" ]]; then
    exec bash "$target" "$@"
fi

# Fallback: pulled via curl|bash with no on-disk neighbor; fetch canonical.
url="https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh"
if command -v curl >/dev/null 2>&1; then
    exec bash <(curl -fsSL "$url") "$@"
fi
echo "[FAIL] build-mios.sh not found and curl unavailable." >&2
echo "       Re-clone https://github.com/mios-dev/mios-bootstrap" >&2
exit 1
