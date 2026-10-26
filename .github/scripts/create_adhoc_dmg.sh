#!/usr/bin/env bash
set -euo pipefail

# Native, certificate-free installer image. Does not open Finder or modify the input app.
# Usage: bash create_adhoc_dmg.sh path/to/App.app path/to/output.dmg
DMG_APP="${1:?App bundle path required}"
DMG_OUTPUT="${2:?DMG output path required}"

[[ -d "$DMG_APP" && -f "$DMG_APP/Contents/Info.plist" ]] || {
  echo "App bundle not found: $DMG_APP" >&2
  exit 1
}
[[ ! -e "$DMG_OUTPUT" ]] || {
  echo "Refusing to overwrite an existing image: $DMG_OUTPUT" >&2
  exit 1
}
mkdir -p "$(dirname "$DMG_OUTPUT")"
DMG_APP="$(cd "$(dirname "$DMG_APP")" && pwd)/$(basename "$DMG_APP")"
DMG_OUTPUT="$(cd "$(dirname "$DMG_OUTPUT")" && pwd)/$(basename "$DMG_OUTPUT")"
DMG_WORK="$(mktemp -d "${TMPDIR:-/tmp/}hermes-dmg.XXXXXX")"
DMG_MOUNTED=false

cleanup() {
  if [[ "$DMG_MOUNTED" == true ]]; then
    diskutil eject "$DMG_WORK/mount" >/dev/null 2>&1 || true
  fi
  rm -rf "$DMG_WORK"
}
trap cleanup EXIT

mkdir "$DMG_WORK/staging" "$DMG_WORK/mount"
codesign --verify --deep --strict "$DMG_APP"
ditto "$DMG_APP" "$DMG_WORK/staging/Boring Notch.app"
ln -s /Applications "$DMG_WORK/staging/Applications"

diskutil image create from --format UDZO --volumeName 'Boring Notch Hermes' \
  "$DMG_WORK/staging" "$DMG_OUTPUT"
codesign --force --sign - --timestamp=none "$DMG_OUTPUT"
codesign --verify --strict "$DMG_OUTPUT"
hdiutil verify "$DMG_OUTPUT"

# Verify the actual mounted payload and drag-to-Applications link before publishing.
DMG_MOUNTED=true
diskutil image attach --readOnly --nobrowse --mountPoint "$DMG_WORK/mount" "$DMG_OUTPUT" > "$DMG_WORK/attach.log"
codesign --verify --deep --strict "$DMG_WORK/mount/Boring Notch.app"
test -x "$DMG_WORK/mount/Boring Notch.app/Contents/MacOS/Boring Notch"
test "$(readlink "$DMG_WORK/mount/Applications")" = /Applications
diskutil eject "$DMG_WORK/mount"
DMG_MOUNTED=false
echo "Verified DMG: $DMG_OUTPUT"
