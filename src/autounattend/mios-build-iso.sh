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
API=https://api.uupdump.net
WEB=https://uupdump.net

mkdir -p "$WORKDIR"
LOG="$WORKDIR/build.log"
STATUS="$WORKDIR/STATUS"
say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
setst() { echo "$*" > "$STATUS"; say "STATUS: $*"; }
pick() { python3 -c "$1" 2>/dev/null; }

setst "starting"

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
    J=$(curl -sS --max-time 30 "$API/fetchupd.php?arch=amd64&ring=Dev&flight=Mainline" 2>/dev/null)
    UUID=$(echo "$J" | pick 'import sys,json;a=json.load(sys.stdin).get("response",{}).get("updateArray",[]);print(a[0]["updateId"] if a else "")')
    [ -n "$UUID" ] && { BUILD=$(echo "$J" | pick 'import sys,json;a=json.load(sys.stdin).get("response",{}).get("updateArray",[]);print(a[0].get("foundBuild",""))'); say "fetchupd Dev -> $UUID ($BUILD)"; break; }
    say "fetchupd attempt $i: $(echo "$J" | head -c 80)"; sleep 20
  done
  # catalog fallback: newest amd64 full "Feature Update" (buildable base), prefer 26200
  if [ -z "$UUID" ]; then
    for i in 1 2 3 4 5 6; do
      L=$(curl -sS --max-time 40 "$API/listid.php?search=Windows%2011%20Insider%20Preview%20Feature%20Update&sortByDate=1" 2>/dev/null)
      RES=$(echo "$L" | pick '
import sys,json
r=json.load(sys.stdin).get("response",{}); b=r.get("builds",[])
if isinstance(b,dict): b=list(b.values())
cand=[x for x in b if x.get("arch")=="amd64" and "Feature Update" in x.get("title","")]
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
  ( cd "$PKG" && ./uup_download_linux.sh ) >>"$LOG" 2>&1
  STOCK=$(find_stock)
  [ -z "$STOCK" ] && { setst "FAILED: converter produced no ISO"; exit 1; }
fi
say "stock ISO: $STOCK ($(du -h "$STOCK" | cut -f1))"

# --- Stage 3: inject the MiOS autounattend + re-master (preserve boot) -------
setst "injecting MiOS autounattend"
[ -f "$AUTOUNATTEND" ] || { setst "FAILED: autounattend.xml not found at $AUTOUNATTEND"; exit 1; }
mkdir -p "$(dirname "$OUTISO")"
# xorriso: copy the stock ISO, replay its El Torito (BIOS+UEFI) boot, add the
# answer file at the ISO root AND \sources\ (Setup searches both).
xorriso -indev "$STOCK" -outdev "$OUTISO" \
        -boot_image any replay \
        -map "$AUTOUNATTEND" /autounattend.xml \
        -map "$AUTOUNATTEND" /sources/autounattend.xml >>"$LOG" 2>&1
[ -s "$OUTISO" ] || { setst "FAILED: xorriso produced no output"; exit 1; }

SHA=$(sha256sum "$OUTISO" | cut -d' ' -f1)
say "DONE: $OUTISO ($(du -h "$OUTISO" | cut -f1))  sha256=$SHA  build=$BUILD"
setst "DONE $OUTISO $(du -h "$OUTISO" | cut -f1) sha256=$SHA"
