#!/bin/bash
# Build Skagway and install it to /Applications.
#
# Default: Release build, auto-bumps CURRENT_PROJECT_VERSION in project.yml.
#
# Flags:
#   --debug            Build Debug configuration instead of Release.
#   --no-bump          Skip the build-number bump (useful for quick retries).
#   --no-install       Build only; don't copy to /Applications.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"
BUMP=1
INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG="Debug"; shift ;;
    --no-bump) BUMP=0; shift ;;
    --no-install) INSTALL=0; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

PROJECT_YML="project.yml"

if [[ $BUMP -eq 1 ]]; then
  CURRENT_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")
  if [[ -z "$CURRENT_BUILD" ]]; then
    echo "Could not find CURRENT_PROJECT_VERSION in $PROJECT_YML" >&2
    exit 1
  fi
  NEW_BUILD=$((CURRENT_BUILD + 1))
  # Portable in-place edit (no -i backup arg) for macOS sed.
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[0-9]+(\")/\1${NEW_BUILD}\2/" "$PROJECT_YML"
  echo "Bumped build: ${CURRENT_BUILD} -> ${NEW_BUILD}"
else
  NEW_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")
  echo "Build (no bump): ${NEW_BUILD}"
fi

MARKETING=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")
echo "Version: ${MARKETING} (${NEW_BUILD}) [${CONFIG}]"

# Regenerate project so the bumped version lands in the Xcode target's Info.plist.
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found on PATH (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate >/dev/null

DEVELOPER_DIR_PATH="/Volumes/Crucial X10/Apps/Xcode.app/Contents/Developer"
if [[ ! -d "$DEVELOPER_DIR_PATH" ]]; then
  echo "Expected Xcode at $DEVELOPER_DIR_PATH" >&2
  exit 1
fi

BUILD_LOG=$(mktemp -t skagway-build.XXXXXX)
trap 'rm -f "$BUILD_LOG"' EXIT

echo "Building (${CONFIG})... (log: ${BUILD_LOG})"
set +e
DEVELOPER_DIR="$DEVELOPER_DIR_PATH" \
  xcodebuild \
    -project Skagway.xcodeproj \
    -scheme Skagway \
    -configuration "$CONFIG" \
    build >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "BUILD FAILED (exit ${BUILD_STATUS}). Last 40 lines:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit $BUILD_STATUS
fi

# Locate the freshly-built app in DerivedData (Xcode build folder).
BUILD_SETTINGS=$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" \
  xcodebuild -project Skagway.xcodeproj -scheme Skagway -configuration "$CONFIG" -showBuildSettings 2>/dev/null)
BUILT_PRODUCTS_DIR=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/BUILT_PRODUCTS_DIR/ { print $2; exit }')
FULL_PRODUCT_NAME=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/FULL_PRODUCT_NAME/ { print $2; exit }')
APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at expected path: $APP_PATH" >&2
  exit 1
fi

echo "Built: ${APP_PATH}"

if [[ $INSTALL -eq 1 ]]; then
  DEST="/Applications/${FULL_PRODUCT_NAME}"
  # Prefer updating the same /Applications/Skagway.app path so TCC grants
  # (Removable Volumes, etc.) stay attached to that location + signing identity.
  #
  # Normal day-to-day: in-place rsync (works while the app is running; the
  # process keeps the old binary mapped until relaunch).
  #
  # After a browser/DMG/Sparkle install, macOS often stamps com.apple.macl on the
  # bundle. That label blocks *in-place* writes (rsync mkstemp → "Operation not
  # permitted"). Rename-aside + ditto still works — including while Skagway is
  # running (the process keeps the old binary mapped from the aside path).

  install_ok=0
  if [[ -d "$DEST" ]]; then
    if touch "${DEST}/Contents/.skagway_install_probe" 2>/dev/null; then
      rm -f "${DEST}/Contents/.skagway_install_probe"
      if rsync -a --delete "${APP_PATH}/" "${DEST}/"; then
        install_ok=1
      fi
    fi
  else
    ditto "$APP_PATH" "$DEST"
    install_ok=1
  fi

  if [[ $install_ok -eq 0 ]]; then
    ASIDE="${DEST}.pre-update.$$"
    rm -rf "$ASIDE"
    echo "In-place update blocked (likely TCC macl on the existing app) — replacing via rename…"
    mv "$DEST" "$ASIDE"
    # Fresh bundle at the same path (keeps Launch Services / TCC path stable).
    ditto "$APP_PATH" "$DEST"
    rm -rf "$ASIDE"
    install_ok=1
  fi

  echo "Installed: ${DEST}"

  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  fi
  mdimport "$DEST" >/dev/null 2>&1 || true

  bash "$(dirname "$0")/cleanup_stray_skagway_apps.sh"
fi

echo ""
echo "✓ Skagway ${MARKETING} (${NEW_BUILD}) [${CONFIG}]"
