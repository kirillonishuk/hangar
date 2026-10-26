#!/usr/bin/env bash
# Packs build/Hangar.app into build/Hangar.dmg with a styled Finder window
# (navy background, drag arrow, Hangar left / Applications right, volume icon).
# Built-in macOS tools only: swift, tiffutil, hdiutil, osascript (Finder), SetFile (optional).
#
#   scripts/bundle.sh && scripts/make-dmg.sh
#
# The first run may show "Terminal wants to control Finder" — allow it
# (System Settings → Privacy & Security → Automation) and rerun.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Hangar.app
OUT=build/Hangar.dmg
RW=build/Hangar-rw.dmg
VOL=Hangar
MNT="/Volumes/$VOL"
[ -d "$APP" ] || { echo "no $APP — run scripts/bundle.sh first" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { hdiutil detach "$MNT" -quiet -force 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# 0. Stale state from an interrupted run.
[ -d "$MNT" ] && hdiutil detach "$MNT" -force -quiet || true
rm -f "$RW" "$OUT"

# 1. Background: 1x + 2x PNG → multi-resolution TIFF.
swift scripts/dmg-background.swift "$TMP/bg.png" "$TMP/bg@2x.png"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$TMP/background.tiff" >/dev/null 2>&1

# 2. Read-write image with the app, Applications link and background.
SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 20 ))
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$VOL" -ov "$RW" -quiet
hdiutil attach "$RW" -mountpoint "$MNT" -noautoopen -quiet
cp -R "$APP" "$MNT/"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"
cp "$TMP/background.tiff" "$MNT/.background/background.tiff"

# 3. Finder layout (writes .DS_Store). Bounds: 640×400 content + 32 pt title bar.
# Best effort: without Finder automation (e.g. a headless CI runner) the DMG is still valid, just unstyled.
layout() {
osascript <<OSA &
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 552}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set shows item info of opts to false
    set background picture of opts to file ".background:background.tiff"
    set position of item "Hangar.app" of container window to {160, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    set the bounds of container window to {200, 120, 840, 552}
    update without registering applications
    delay 2
    close
    delay 1
  end tell
end tell
OSA
  local pid=$!
  ( sleep 120; kill "$pid" ) >/dev/null 2>&1 &  # a Finder automation prompt nobody answers must not hang the build
  local watchdog=$!
  wait "$pid" || return 1
  kill "$watchdog" 2>/dev/null || true
  # Finder writes .DS_Store asynchronously; wait for it before detaching.
  for _ in $(seq 1 20); do [ -f "$MNT/.DS_Store" ] && break; sleep 0.5; done
  [ -f "$MNT/.DS_Store" ] || { echo "Finder did not write .DS_Store" >&2; return 1; }
}
layout || echo "warning: Finder layout failed; the DMG window will be unstyled" >&2

# 4. Volume icon — after the layout: Finder's layout pass deletes .VolumeIcon.icns.
cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then SetFile -a C "$MNT"; fi
sync
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true

# 5. Compress.
hdiutil detach "$MNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$RW"
echo "Built $OUT"
