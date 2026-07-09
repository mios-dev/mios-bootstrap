#!/usr/bin/env bash
# AI-hint: Linux MiOS-XBOX ISO builder -- the no-Windows-elevation path. Builds a bootable MiOS-XBOX Windows 11 ISO entirely inside a Linux (sudo) environment: resolves a buildable Insider/Dev build from UUP Dump (fetchupd live-scan -> listid catalog fallback, rate-limit backoff), fetches the "download+convert" package, runs uup_download_linux.sh (aria2 fetch from the MS CDN + cabextract/wimlib reconstruct install.wim + mkisofs stock ISO), then xorriso-injects the MiOS autounattend.xml (accounts, LabConfig bypass, pre-logon MiOS-Host service, Xbox FSE config, FirstLogon layout + nested bootstrap) preserving the dual BIOS/UEFI boot. Complements the Windows DISM pipeline (New-MiOSISO.ps1) which needs admin/oscdimg; this needs only Linux root + wimlib/xorriso/aria2/cabextract. Stage-marker resumable, STATUS-file driven for monitoring.
# AI-related: mios-bootstrap, New-MiOSAutounattend.ps1, New-MiOSISO.ps1, mios-uup-fetch.ps1
set -uo pipefail

# --- config (env-overridable) ------------------------------------------------
WORKDIR="${MIOS_ISO_WORKDIR:-/var/tmp/mios-isobuild}"
OUTISO="${MIOS_ISO_OUT:-$WORKDIR/MiOS-Xbox.iso}"
AUTOUNATTEND="${MIOS_AUTOUNATTEND:-/mnt/c/../M/MiOS/iso/autounattend.xml}"   # overridden by caller
EDITION="${MIOS_EDITION:-professional}"
LANG_="${MIOS_LANG:-en-us}"

# Accept optional edition as the first argument (T-146)
EDITION_ARG="${1:-}"
if [ -n "$EDITION_ARG" ]; then
  TOML_PATH="${MIOS_TOML:-/mnt/c/mios-bootstrap/mios.toml}"
  if [ ! -f "$TOML_PATH" ]; then
    TOML_PATH="$(dirname "$0")/../../mios.toml"
  fi
  if [ -f "$TOML_PATH" ]; then
    eval "$(python3 -c "
import sys, tomllib
def get_val(d, k):
    for p in k.split('.'):
        d = d.get(p) if isinstance(d, dict) else None
    return d
try:
    with open('$TOML_PATH', 'rb') as f:
        data = tomllib.load(f)
    ed = data.get('editions', {}).get('$EDITION_ARG', {})
    if ed:
        mapping = {
            'autounattend.uup_channel': 'MIOS_CHANNEL',
            'autounattend.uup_arch': 'MIOS_ARCH',
            'autounattend.uup_edition': 'EDITION',
            'autounattend.posture': 'MIOS_POSTURE',
            'autounattend.debloat_profile': 'MIOS_DEBLOAT_PROFILE',
            'autounattend.xbox.enable': 'MIOS_XBOX_ENABLE',
            'colors.accent': 'MIOS_ACCENT'
        }
        for toml_key, env_var in mapping.items():
            val = get_val(ed, toml_key)
            if val is not None:
                print(f'{env_var}=\"{val}\"')
except Exception as e:
    print(f'echo \"[!] Error parsing edition overrides: {e}\" >&2', file=sys.stderr)
")"
  fi
fi

MIOS_CHANNEL="${MIOS_CHANNEL:-dev}"
MIOS_ARCH="${MIOS_ARCH:-amd64}"
export MIOS_ARCH

case "${MIOS_CHANNEL,,}" in
  dev)      RING="Dev";;
  beta)     RING="Beta";;
  release*) RING="ReleasePreview";;
  *)        RING="Retail";;
esac

API=https://api.uupdump.net
WEB=https://uupdump.net

mkdir -p "$WORKDIR"
LOG="$WORKDIR/build.log"
STATUS="$WORKDIR/STATUS"
say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
setst() { echo "$*" > "$STATUS"; say "STATUS: $*"; }
pick() { python3 -c "$1" 2>/dev/null; }

setst "starting"

# --- Stage -1: converter prerequisites (idempotent) --------------------------
# The UUP converter (uup_download_linux.sh + files/convert.sh) needs: aria2c,
# cabextract, wimlib-imagex (Fedora ships this in the SEPARATE wimlib-utils
# package, not libwimlib), chntpw, and a genisoimage/mkisofs.
if ! command -v wimlib-imagex >/dev/null 2>&1; then
  setst "installing converter deps"
  sudo dnf install -y wimlib-utils cabextract chntpw aria2 xorriso >>"$LOG" 2>&1 || true
fi
# convert.sh (files/convert.sh) masters a UDF-PRIMARY ISO: files are visible
# via UDF and the ISO9660 duplicates are hidden via --hide "*", with no -R/-J.
# But Fedora's xorriso build has NO UDF support -- so its mkisofs-emulation
# rejects "--udf", and simply dropping UDF would leave every file hidden.
# cdrkit genisoimage also cannot master the >4GB install.wim. So install a
# genisoimage SHIM that ignores convert.sh's boot/hide/udf flags and masters an
# EQUIVALENT bootable Windows ISO via xorriso: ISO9660 level 3 (multi-extent,
# handles >4GB install.wim) + Rock Ridge + Joliet + dual BIOS/UEFI El Torito.
# Lives outside the package so it survives convert.sh's per-run re-download;
# convert.sh prefers genisoimage, so it picks up the shim.
SHIM=/usr/local/bin/genisoimage
if ! grep -q 'MiOS build shim' "$SHIM" 2>/dev/null; then
  setst "installing genisoimage->xorriso shim"
  sudo tee "$SHIM" >/dev/null <<'SHIMEOF'
#!/bin/bash
# MiOS build shim standing in for genisoimage in the UUP converter. This host's
# xorriso has NO UDF; master an ISO9660-L3 + Rock Ridge + Joliet + dual El
# Torito image instead (level 3 handles the >4GB install.wim via multi-extent).
out=""; src=""; vol=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)                 out="$2"; shift 2;;
    -V|-volid|--volid)  vol="$2"; shift 2;;
    -b)                 shift 2;;   # convert.sh boot images -- we set our own
    -hide|--hide)       shift 2;;   # drop --hide "*"
    -iso-level)         shift 2;;   # we force level 3
    -*)                 shift;;     # any other flag (no value): --udf, --no-emul-boot, ...
    *)                  src="$1"; shift;;
  esac
done
: "${vol:=MIOS_XBOX}"
exec xorriso -as mkisofs \
  -iso-level 3 -rational-rock -joliet -joliet-long \
  -volid "$vol" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -o "$out" "$src"
SHIMEOF
  sudo chmod +x "$SHIM"
fi

# --- Stage 0: resolve a BUILDABLE Insider build UUID -------------------------
# Prefer a Dev/25H2 (26200-range) Feature Update; else the newest amd64 Feature
# Update. fetchupd (live WU scan) is flaky/rate-limited, so fall back to the
# listid catalog with long backoff.
UUIDFILE="$WORKDIR/uuid.txt"
if [ ! -s "$UUIDFILE" ]; then
  setst "resolving build uuid"
  UUID=''; BUILD=''
  # try live Dev scan a few times
  for i in 1 2 3; do
    J=$(curl -sS --max-time 30 "$API/fetchupd.php?arch=$MIOS_ARCH&ring=$RING&flight=Mainline" 2>/dev/null)
    UUID=$(echo "$J" | pick 'import sys,json;a=json.load(sys.stdin).get("response",{}).get("updateArray",[]);print(a[0]["updateId"] if a else "")')
    [ -n "$UUID" ] && { BUILD=$(echo "$J" | pick 'import sys,json;a=json.load(sys.stdin).get("response",{}).get("updateArray",[]);print(a[0].get("foundBuild",""))'); say "fetchupd $RING -> $UUID ($BUILD)"; break; }
    say "fetchupd attempt $i: $(echo "$J" | head -c 80)"; sleep 20
  done
  # catalog fallback: newest arch full "Feature Update" (buildable base), prefer 26200
  if [ -z "$UUID" ]; then
    for i in 1 2 3 4 5 6; do
      L=$(curl -sS --max-time 40 "$API/listid.php?search=Windows%2011%20Insider%20Preview%20Feature%20Update&sortByDate=1" 2>/dev/null)
      RES=$(echo "$L" | pick '
import sys,json,os
r=json.load(sys.stdin).get("response",{}); b=r.get("builds",[])
if isinstance(b,dict): b=list(b.values())
cand=[x for x in b if x.get("arch")==os.environ.get("MIOS_ARCH", "amd64") and "Feature Update" in x.get("title","")]
pref=[x for x in cand if x.get("build","").startswith("26200") or x.get("build","").startswith("26120")]
pick=(pref or cand)
if pick: print(pick[0]["uuid"], pick[0].get("build",""))
')
      if [ -n "$RES" ]; then UUID=$(echo "$RES" | awk "{print \$1}"); BUILD=$(echo "$RES" | awk "{print \$2}"); say "listid Feature Update -> $UUID ($BUILD)"; break; fi
      say "listid attempt $i (rate-limit backoff): $(echo "$L" | head -c 80)"; sleep 45
    done
  fi
  [ -z "$UUID" ] && { setst "FAILED: no buildable UUID"; exit 1; }
  echo "$UUID" > "$UUIDFILE"; echo "$BUILD" > "$WORKDIR/build.txt"
fi
UUID=$(cat "$UUIDFILE"); BUILD=$(cat "$WORKDIR/build.txt" 2>/dev/null || echo '?')
say "using build $BUILD  uuid=$UUID"

# --- Stage 1: fetch the download+convert package -----------------------------
PKG="$WORKDIR/package"
if [ ! -f "$PKG/uup_download_linux.sh" ]; then
  setst "fetching UUP package"
  mkdir -p "$PKG"; ZIP="$WORKDIR/uup.zip"
  for i in 1 2 3 4 5; do
    code=$(curl -sS -o "$ZIP" -w '%{http_code}' --max-time 120 -X POST "$WEB/get.php?id=$UUID&pack=$LANG_&edition=$EDITION" -d 'autodl=2&updates=1&cleanup=1' 2>/dev/null)
    if [ "$code" = "200" ] && unzip -l "$ZIP" 2>/dev/null | grep -q uup_download_linux.sh; then
      unzip -o "$ZIP" -d "$PKG" >/dev/null 2>&1; say "package fetched + extracted"; break
    fi
    say "get.php attempt $i -> http $code (backoff)"; sleep 30
  done
  [ -f "$PKG/uup_download_linux.sh" ] || { setst "FAILED: no convert package"; exit 1; }
fi

# --- Stage 2: run the UUP converter (aria2 fetch + build stock ISO) ----------
find_stock() { find "$PKG" -maxdepth 3 -type f -iname '*.iso' 2>/dev/null | sort | tail -1; }
STOCK=$(find_stock)
if [ -z "$STOCK" ]; then
  setst "downloading + converting (LONG: multi-GB from MS CDN)"
  # headless ConvertConfig
  INI="$PKG/ConvertConfig.ini"
  if [ -f "$INI" ]; then
    for kv in "AutoStart=1" "AddUpdates=1" "Cleanup=1" "ResetBase=1" "NetFx3=0" "StartVirtual=0" "wim2esd=0" "SkipISO=0"; do
      k="${kv%%=*}"; if grep -q "^\s*$k\s*=" "$INI"; then sed -i "s|^\s*$k\s*=.*|$kv|" "$INI"; else echo "$kv" >> "$INI"; fi
    done
  fi
  chmod +x "$PKG/uup_download_linux.sh"
  # If the UUP set + converter are already downloaded (resumed build), run the
  # converter DIRECTLY. uup_download_linux.sh re-fetches convert.sh from
  # git.uupdump.net on every run, which frequently returns HTTP 522 and aborts
  # the whole build even though nothing else needs downloading. Running
  # convert.sh directly is fully offline (local UUPs/ + files/convert.sh).
  if [ -f "$PKG/files/convert.sh" ] && [ -n "$(ls -A "$PKG/UUPs" 2>/dev/null)" ]; then
    say "UUP set + converter present -> convert.sh direct (skip network re-fetch)"
    ( cd "$PKG" && chmod +x ./files/convert.sh && ./files/convert.sh wim UUPs 0 ) >>"$LOG" 2>&1
  else
    ( cd "$PKG" && ./uup_download_linux.sh ) >>"$LOG" 2>&1
  fi
  STOCK=$(find_stock)
fi

# --- Stage 3: produce MiOS-XBOX.iso with the MiOS autounattend injected -------
setst "injecting MiOS autounattend"
[ -f "$AUTOUNATTEND" ] || { setst "FAILED: autounattend.xml not found at $AUTOUNATTEND"; exit 1; }
mkdir -p "$(dirname "$OUTISO")"

# Master the final ISO straight from the converter's ISODIR tree, baking the
# answer file in at root + /sources/. iso-level 3 + Rock Ridge + Joliet (this
# xorriso has no UDF) with dual BIOS/UEFI El Torito; handles the >4GB image.
master_from_isodir() {
  local d="$1"
  cp -f "$AUTOUNATTEND" "$d/autounattend.xml"
  cp -f "$AUTOUNATTEND" "$d/sources/autounattend.xml"
  xorriso -as mkisofs -iso-level 3 -rational-rock -joliet -joliet-long \
    -volid "MIOS_XBOX" \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
    -o "$OUTISO" "$d" >>"$LOG" 2>&1
}

if [ -n "$STOCK" ]; then
  # convert.sh produced a stock ISO -> copy it, replay its El Torito (BIOS+UEFI)
  # boot, and add the answer file at the ISO root AND /sources/ (Setup searches
  # both). ISODIR is already gone (convert.sh cleans up on success).
  say "stock ISO: $STOCK ($(du -h "$STOCK" | cut -f1)) -> replay-inject autounattend"
  xorriso -indev "$STOCK" -outdev "$OUTISO" \
          -boot_image any replay \
          -map "$AUTOUNATTEND" /autounattend.xml \
          -map "$AUTOUNATTEND" /sources/autounattend.xml >>"$LOG" 2>&1
else
  # convert.sh's own ISO step failed or was interrupted, but the reconstructed
  # ISODIR survives -> master the final ISO directly from it (this is also the
  # recovery path when a long run is killed mid-mastering).
  ISODIR=$(find "$PKG" -maxdepth 2 -type d -name ISODIR 2>/dev/null | head -1)
  if [ -n "$ISODIR" ] && [ -f "$ISODIR/sources/install.wim" ]; then
    say "no stock ISO; ISODIR complete -> mastering directly from $ISODIR"
    master_from_isodir "$ISODIR"
  else
    setst "FAILED: converter produced neither a stock ISO nor a complete ISODIR"; exit 1
  fi
fi
[ -s "$OUTISO" ] || { setst "FAILED: no output ISO produced"; exit 1; }

SHA=$(sha256sum "$OUTISO" | cut -d' ' -f1)
say "DONE: $OUTISO ($(du -h "$OUTISO" | cut -f1))  sha256=$SHA  build=$BUILD"
setst "DONE $OUTISO $(du -h "$OUTISO" | cut -f1) sha256=$SHA"
