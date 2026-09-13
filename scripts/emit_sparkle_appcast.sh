#!/bin/bash
# Emit Skagway.appcast.xml for Sparkle from a notarized Skagway.dmg.
#
# Usage:
#   bash scripts/emit_sparkle_appcast.sh path/to/Skagway.dmg [output-dir]
#
# Defaults:
#   output-dir = dist/
#   feed URL prefix = https://downloads.machiilabs.com/
#   Keychain account = machiilabs.skagway (or --ed-key-file secrets/sparkle_ed25519)
#
# Prerequisites: Sparkle tools from SPM (DerivedData) or SPARKLE_BIN pointing at …/Sparkle/bin

set -euo pipefail

cd "$(dirname "$0")/.."

DMG_PATH="${1:?Usage: $0 path/to/Skagway.dmg [output-dir]}"
OUT_DIR="${2:-dist}"
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://downloads.machiilabs.com/}"
KEY_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-machiilabs.skagway}"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-secrets/sparkle_ed25519}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

find_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" && -x "${SPARKLE_BIN}/generate_appcast" ]]; then
    echo "$SPARKLE_BIN"
    return 0
  fi
  local candidate dd
  # Prefer this project's DerivedData (fast); fall back to a bounded search.
  for dd in "${HOME}/Library/Developer/Xcode/DerivedData"/Skagway-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    if [[ -x "${dd}/generate_appcast" ]]; then
      echo "$dd"
      return 0
    fi
  done
  candidate=$(find "${HOME}/Library/Developer/Xcode/DerivedData" -maxdepth 6 \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1 || true)
  if [[ -n "$candidate" ]]; then
    dirname "$candidate"
    return 0
  fi
  return 1
}

if ! SPARKLE_TOOLS=$(find_sparkle_bin); then
  echo "Sparkle tools not found. Build the app once (to resolve SPM) or set SPARKLE_BIN to …/Sparkle/bin" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
APPCAST_OUT="${OUT_DIR}/Skagway.appcast.xml"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/skagway-appcast.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Stable enclosure name matches the public download URL basename.
cp -f "$DMG_PATH" "${WORK}/Skagway.dmg"

# Stable URL strategy (Skagway.dmg overwritten each release): always emit a fresh
# single-item feed. Merging into a prior appcast leaves old items pointing at the
# same URL with stale signatures/lengths.
rm -f "$APPCAST_OUT"

GEN_ARGS=(
  --account "$KEY_ACCOUNT"
  --download-url-prefix "$DOWNLOAD_PREFIX"
  -o "$APPCAST_OUT"
)

if [[ -f "$PRIVATE_KEY_FILE" ]]; then
  GEN_ARGS+=(--ed-key-file "$PRIVATE_KEY_FILE")
fi

echo "Generating appcast with ${SPARKLE_TOOLS}/generate_appcast…"
"${SPARKLE_TOOLS}/generate_appcast" "${GEN_ARGS[@]}" "$WORK"

# Ensure stable DMG name sits next to the appcast for upload.
if [[ "$DMG_PATH" != "${OUT_DIR}/Skagway.dmg" ]]; then
  cp -f "$DMG_PATH" "${OUT_DIR}/Skagway.dmg"
fi

if [[ ! -f "$APPCAST_OUT" ]]; then
  echo "generate_appcast did not write ${APPCAST_OUT}" >&2
  exit 1
fi

echo "✓ Appcast: ${APPCAST_OUT}"
echo "  Enclosure URL: ${DOWNLOAD_PREFIX}Skagway.dmg"
echo "  Publish BOTH Skagway.dmg and Skagway.appcast.xml to downloads.machiilabs.com (see docs/SPARKLE.md)."
echo "  After upload: bash scripts/verify_sparkle_publish.sh ${APPCAST_OUT}"