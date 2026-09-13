#!/bin/bash
# Verify downloads.machiilabs.com Skagway.dmg matches dist/ appcast (length + optional signature).
# Run after uploading BOTH files — prevents Sparkle "improperly signed" from a stale CDN DMG.
#
# Usage:
#   bash scripts/verify_sparkle_publish.sh [path/to/Skagway.appcast.xml]

set -euo pipefail

cd "$(dirname "$0")/.."

APPCAST="${1:-dist/Skagway.appcast.xml}"
DMG_URL="${SPARKLE_DOWNLOAD_URL:-https://downloads.machiilabs.com/Skagway.dmg}"
APPCAST_URL="${SPARKLE_APPCAST_URL:-https://downloads.machiilabs.com/Skagway.appcast.xml}"

if [[ ! -f "$APPCAST" ]]; then
  echo "Appcast not found: $APPCAST" >&2
  exit 1
fi

LOCAL_LENGTH=$(python3 - <<'PY' "$APPCAST"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'<enclosure[^>]*length="([0-9]+)"', text)
if not m:
    raise SystemExit("Could not parse enclosure length from appcast")
print(m.group(1))
PY
)

LOCAL_SIG=$(python3 - <<'PY' "$APPCAST"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'sparkle:edSignature="([^"]+)"', text)
print(m.group(1) if m else "")
PY
)

echo "Local appcast enclosure length: ${LOCAL_LENGTH}"

REMOTE_LENGTH=$(curl -fsIL "$DMG_URL" | awk -F': ' 'tolower($1)=="content-length" { print $2; exit }' | tr -d '\r')
if [[ -z "$REMOTE_LENGTH" ]]; then
  echo "Could not read Content-Length for ${DMG_URL}" >&2
  exit 1
fi

echo "Remote DMG Content-Length:      ${REMOTE_LENGTH}"

if [[ "$LOCAL_LENGTH" != "$REMOTE_LENGTH" ]]; then
  echo ""
  echo "MISMATCH — Sparkle will show “improperly signed”." >&2
  echo "Upload dist/Skagway.dmg to ${DMG_URL} (overwrite in place)." >&2
  echo "Appcast expects ${LOCAL_LENGTH} bytes; CDN serves ${REMOTE_LENGTH} bytes." >&2
  exit 1
fi

REMOTE_APPCAST_LENGTH=$(curl -fsIL "$APPCAST_URL" | awk -F': ' 'tolower($1)=="content-length" { print $2; exit }' | tr -d '\r')
echo "Remote appcast Content-Length:  ${REMOTE_APPCAST_LENGTH:-unknown}"

TMP=$(mktemp -t skagway-verify.XXXXXX.dmg)
trap 'rm -f "$TMP"' EXIT
curl -fsL "$DMG_URL" -o "$TMP"
DOWNLOADED=$(stat -f%z "$TMP" 2>/dev/null || stat -c%s "$TMP")

if [[ "$DOWNLOADED" != "$LOCAL_LENGTH" ]]; then
  echo "Downloaded DMG size ${DOWNLOADED} != appcast length ${LOCAL_LENGTH}" >&2
  exit 1
fi

if [[ -n "$LOCAL_SIG" && -f secrets/sparkle_ed25519 ]]; then
  SPARKLE_BIN="${SPARKLE_BIN:-}"
  if [[ -z "$SPARKLE_BIN" ]]; then
    candidate=$(find "${HOME}/Library/Developer/Xcode/DerivedData" "/Volumes/SSD/MacLibraryOffload/DerivedData" \
      -path '*/artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1 || true)
    [[ -n "$candidate" ]] && SPARKLE_BIN=$(dirname "$candidate")
  fi
  if [[ -n "$SPARKLE_BIN" && -x "${SPARKLE_BIN}/sign_update" ]]; then
    REMOTE_SIG=$("${SPARKLE_BIN}/sign_update" --ed-key-file secrets/sparkle_ed25519 "$TMP" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
    if [[ "$REMOTE_SIG" != "$LOCAL_SIG" ]]; then
      echo "EdDSA signature mismatch between CDN DMG and appcast." >&2
      exit 1
    fi
    echo "EdDSA signature: OK"
  fi
fi

echo "✓ Sparkle publish verified (${LOCAL_LENGTH} bytes at ${DMG_URL})"
