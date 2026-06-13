#!/usr/bin/env bash
# AI-hint: Legacy redirector script that forwards execution to build-mios.sh to maintain backward compatibility for curl-based installation commands while ensuring the core build logic is centralized.
# AI-related: mios-dev, mios-bootstrap
# 'MiOS' bootstrap installer -- legacy redirector.
#
# This file was renamed to build-mios.sh to align with the cross-platform
# entry-point convention (build-mios.{sh,ps1}). This redirector exists so
# existing curl | bash one-liners that point at the old install.sh URL
# keep working.
set -euo pipefail
target="$(dirname "${BASH_SOURCE[0]}")/build-mios.sh"
if [[ ! -x "$target" && ! -r "$target" ]]; then
    echo "[FAIL] build-mios.sh not found alongside this redirector." >&2
    echo "       Re-clone https://github.com/mios-dev/mios-bootstrap" >&2
    exit 1
fi
exec bash "$target" "$@"
