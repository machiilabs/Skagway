#!/bin/bash
# Remove Skagway.app copies that pollute Launchpad / Launch Services.
# Keeps /Applications/Skagway.app untouched and re-registers it at the end.
#
# Called automatically from build_and_install.sh after each install.

set -euo pipefail

CANONICAL="/Applications/Skagway.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

removed=0
ejected=0

unregister_app() {
  local path="$1"
  [[ -x "$LSREGISTER" ]] || return 0
  "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
}

remove_app() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  [[ "$path" == "$CANONICAL" || "$path" == "${CANONICAL}/"* ]] && return 0
  [[ -d "$path" ]] || return 0
  unregister_app "$path"
  if rm -rf "$path" 2>/dev/null; then
    echo "Removed stray app: ${path}"
    removed=$((removed + 1))
  else
    echo "Note: could not delete ${path} — remove manually (e.g. Empty Trash)." >&2
  fi
}

remove_sparkle_cache() {
  local cache_root="$1"
  [[ -d "$cache_root" ]] || return 0
  local app
  while IFS= read -r app; do
    remove_app "$app"
  done < <(find "$cache_root" -name Skagway.app -type d 2>/dev/null)
  rm -rf "$cache_root"
  echo "Removed Sparkle appcast cache: ${cache_root}"
}

for cache_root in \
  "${HOME}/Library/Caches/Sparkle_generate_appcast" \
  "/Volumes/SSD/MacLibraryOffload/Caches/Sparkle_generate_appcast"; do
  remove_sparkle_cache "$cache_root"
done

for dd_root in \
  "${HOME}/Library/Developer/Xcode/DerivedData"/Skagway-* \
  "/Volumes/SSD/MacLibraryOffload/DerivedData"/Skagway-*; do
  [[ -d "$dd_root" ]] || continue
  remove_app "${dd_root}/Build/Products/Debug/Skagway.app"
  remove_app "${dd_root}/Build/Products/Release/Skagway.app"
  remove_app "${dd_root}/Build/Intermediates.noindex/ArchiveIntermediates/Skagway/InstallationBuildProductsLocation/Applications/Skagway.app"
done

remove_app "${REPO_ROOT}/dist/dmg-stage/Skagway.app"
remove_app "${REPO_ROOT}/dist/Skagway.xcarchive/Products/Applications/Skagway.app"

if [[ -d "${HOME}/.Trash/Skagway.app" ]]; then
  unregister_app "${HOME}/.Trash/Skagway.app"
  echo "Note: Skagway.app is in Trash — use Finder → Empty Trash to drop the extra launcher icon." >&2
fi

# Eject read-only install DMGs left mounted after packaging or manual opens.
for vol in /Volumes/Skagway /Volumes/Skagway\ *; do
  [[ -d "$vol/Skagway.app" ]] || continue
  unregister_app "${vol}/Skagway.app"
  if hdiutil detach "$vol" -quiet 2>/dev/null; then
    echo "Ejected install volume: ${vol}"
    ejected=$((ejected + 1))
  else
    echo "Note: install volume still mounted — eject manually: ${vol}" >&2
  fi
done

if [[ -x "$LSREGISTER" ]]; then
  echo "Rebuilding Launch Services database (drops stale Skagway launcher entries)…"
  "$LSREGISTER" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
fi

if [[ -d "$CANONICAL" && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$CANONICAL" >/dev/null 2>&1 || true
  mdimport "$CANONICAL" >/dev/null 2>&1 || true
fi

if [[ $((removed + ejected)) -eq 0 ]]; then
  echo "No stray Skagway.app copies found (canonical: ${CANONICAL})."
else
  echo "Cleaned ${removed} stray Skagway.app cop$( [[ $removed -eq 1 ]] && echo y || echo ies )$( [[ $ejected -gt 0 ]] && echo " and ejected ${ejected} install volume(s)" || echo "" )."
fi
