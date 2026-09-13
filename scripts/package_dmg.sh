#!/bin/bash
# Build a Developer ID–signed, notarized, stapled Skagway DMG for public download.
#
# Prerequisites:
#   - Developer ID Application identity in the keychain
#   - notarytool keychain profile (default: SkagwayNotary)
#       xcrun notarytool store-credentials "SkagwayNotary" \
#         --apple-id "…" --team-id "99DA5P7M35" --password "app-specific-password"
#
# Default: bumps CURRENT_PROJECT_VERSION, archives Release, signs with hardened runtime,
# builds a styled drag-to-Applications DMG (create-dmg + packaging/dmg-background.png),
# notarizes, staples.
#
# Requires: brew install create-dmg
#
# Flags:
#   --no-bump          Skip the build-number bump
#   --skip-notarize    Build + sign DMG only (no notarytool / stapler)
#   --notary-profile NAME   Keychain profile (default: SkagwayNotary)

set -euo pipefail

cd "$(dirname "$0")/.."

BUMP=1
NOTARIZE=1
NOTARY_PROFILE="SkagwayNotary"
TEAM_ID="99DA5P7M35"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-bump) BUMP=0; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --notary-profile)
      NOTARY_PROFILE="${2:?--notary-profile requires a name}"
      shift 2
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

PROJECT_YML="project.yml"
ENTITLEMENTS="Skagway/Skagway.entitlements"
DEVELOPER_DIR_PATH="/Volumes/Crucial X10/Apps/Xcode.app/Contents/Developer"

if [[ ! -d "$DEVELOPER_DIR_PATH" ]]; then
  echo "Expected Xcode at $DEVELOPER_DIR_PATH" >&2
  exit 1
fi
export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"

IDENTITY=$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application identity found. Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
echo "Signing identity: ${IDENTITY}"

if [[ $BUMP -eq 1 ]]; then
  CURRENT_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")
  if [[ -z "$CURRENT_BUILD" ]]; then
    echo "Could not find CURRENT_PROJECT_VERSION in $PROJECT_YML" >&2
    exit 1
  fi
  NEW_BUILD=$((CURRENT_BUILD + 1))
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[0-9]+(\")/\1${NEW_BUILD}\2/" "$PROJECT_YML"
  echo "Bumped build: ${CURRENT_BUILD} -> ${NEW_BUILD}"
else
  NEW_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")
  echo "Build (no bump): ${NEW_BUILD}"
fi

MARKETING=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")
echo "Packaging Skagway ${MARKETING} (${NEW_BUILD})"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found on PATH (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate >/dev/null

DIST_DIR="dist"
ARCHIVE_PATH="${DIST_DIR}/Skagway.xcarchive"
STAGE_DIR="${DIST_DIR}/dmg-stage"
APP_NAME="Skagway.app"
VERSIONED_DMG="${DIST_DIR}/Skagway-${MARKETING}-${NEW_BUILD}.dmg"
STABLE_DMG="${DIST_DIR}/Skagway.dmg"

rm -rf "$ARCHIVE_PATH" "$STAGE_DIR"
mkdir -p "$DIST_DIR"

BUILD_LOG=$(mktemp -t skagway-package.XXXXXX)
cleanup() {
  rm -f "$BUILD_LOG"
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

echo "Archiving (Release, Developer ID + hardened runtime)... (log: ${BUILD_LOG})"
set +e
xcodebuild \
  -project Skagway.xcodeproj \
  -scheme Skagway \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  >"$BUILD_LOG" 2>&1
ARCHIVE_STATUS=$?
set -e

if [[ $ARCHIVE_STATUS -ne 0 ]]; then
  echo "ARCHIVE FAILED (exit ${ARCHIVE_STATUS}). Last 60 lines:" >&2
  tail -60 "$BUILD_LOG" >&2
  exit $ARCHIVE_STATUS
fi

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "Archived app not found at ${ARCHIVED_APP}" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"
ditto "$ARCHIVED_APP" "${STAGE_DIR}/${APP_NAME}"
APP_PATH="${STAGE_DIR}/${APP_NAME}"

# Strip extended attributes that can break notarization / Gatekeeper.
xattr -cr "$APP_PATH"

sign_item() {
  local target=$1
  local with_entitlements=${2:-0}
  if [[ $with_entitlements -eq 1 ]]; then
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" \
      --entitlements "$ENTITLEMENTS" \
      "$target"
  else
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" \
      "$target"
  fi
}

echo "Signing nested code (inside-out)…"
# Frameworks / dylibs first, then the app bundle with entitlements.
if [[ -d "${APP_PATH}/Contents/Frameworks" ]]; then
  # Sign nested binaries inside frameworks, then each .framework bundle.
  while IFS= read -r -d '' nested; do
    sign_item "$nested" 0
  done < <(find "${APP_PATH}/Contents/Frameworks" \( -type f -perm -111 -o -name "*.dylib" \) -print0 2>/dev/null || true)

  while IFS= read -r -d '' fw; do
    sign_item "$fw" 0
  done < <(find "${APP_PATH}/Contents/Frameworks" -name "*.framework" -print0 2>/dev/null || true)
fi

if [[ -d "${APP_PATH}/Contents/MacOS" ]]; then
  while IFS= read -r -d '' bin; do
    # Main executable gets entitlements with the outer app sign; helpers get runtime only.
    if [[ "$(basename "$bin")" == "Skagway" ]]; then
      continue
    fi
    sign_item "$bin" 0
  done < <(find "${APP_PATH}/Contents/MacOS" -type f -perm -111 -print0 2>/dev/null || true)
fi

sign_item "$APP_PATH" 1

echo "Verifying app signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 || true

DMG_BACKGROUND="packaging/dmg-background.png"
DMG_WINDOW_W=640
DMG_WINDOW_H=480
if [[ ! -f "$DMG_BACKGROUND" ]]; then
  echo "Missing DMG background: ${DMG_BACKGROUND}" >&2
  exit 1
fi
BG_W=$(sips -g pixelWidth "$DMG_BACKGROUND" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
BG_H=$(sips -g pixelHeight "$DMG_BACKGROUND" 2>/dev/null | awk '/pixelHeight/ { print $2 }')
if [[ "$BG_W" != "$DMG_WINDOW_W" || "$BG_H" != "$DMG_WINDOW_H" ]]; then
  echo "DMG background must be exactly ${DMG_WINDOW_W}×${DMG_WINDOW_H} px (got ${BG_W}×${BG_H})." >&2
  echo "Finder maps background pixels 1:1 to the window; a larger image only shows the top-left." >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found on PATH (brew install create-dmg)" >&2
  exit 1
fi

echo "Creating styled DMG (create-dmg)…"
rm -f "$VERSIONED_DMG" "$STABLE_DMG"
# Keep this path simple: create-dmg owns Finder background + icon layout.
# Do not rewrite .DS_Store afterward — volume-relative background aliases break
# and Finder falls back to a blank gray window.
create-dmg \
  --volname "Skagway" \
  --background "$DMG_BACKGROUND" \
  --window-pos 200 120 \
  --window-size "$DMG_WINDOW_W" "$DMG_WINDOW_H" \
  --icon-size 128 \
  --text-size 12 \
  --icon "Skagway.app" 165 285 \
  --hide-extension "Skagway.app" \
  --app-drop-link 475 285 \
  --no-internet-enable \
  --overwrite \
  "$VERSIONED_DMG" \
  "$STAGE_DIR"

echo "Signing DMG…"
codesign --force --timestamp --sign "$IDENTITY" "$VERSIONED_DMG"

if [[ $NOTARIZE -eq 1 ]]; then
  echo "Submitting to Apple notary service (profile: ${NOTARY_PROFILE})…"
  xcrun notarytool submit "$VERSIONED_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling notarization ticket…"
  xcrun stapler staple "$VERSIONED_DMG"
  xcrun stapler validate "$VERSIONED_DMG"
else
  echo "Skipping notarization (--skip-notarize)."
fi

cp -f "$VERSIONED_DMG" "$STABLE_DMG"

echo ""
echo "Emitting Sparkle appcast…"
bash scripts/emit_sparkle_appcast.sh "$STABLE_DMG" "$DIST_DIR"

bash scripts/cleanup_stray_skagway_apps.sh

echo ""
echo "✓ Packaged Skagway ${MARKETING} (${NEW_BUILD})"
echo "  ${VERSIONED_DMG}"
echo "  ${STABLE_DMG}"
echo "  ${DIST_DIR}/Skagway.appcast.xml"
if [[ $NOTARIZE -eq 1 ]]; then
  echo "  Notarized + stapled (Gatekeeper-ready)."
else
  echo "  Signed DMG only — run without --skip-notarize for public distribution."
fi
echo ""
echo "  ═══ RELEASE: PUBLISH SPARKLE (required) ═══"
echo "  1. Upload to R2 (machiilabs-download), overwrite in place:"
echo "       dist/Skagway.dmg"
echo "       dist/Skagway.appcast.xml"
echo "  2. Verify:"
echo "       bash scripts/verify_sparkle_publish.sh dist/Skagway.appcast.xml"
echo "  3. Smoke-test: Skagway → Check for Updates…"
echo "  See docs/SPARKLE.md"
