#!/usr/bin/env bash
# Builds build/Hangar.app (release, ad-hoc signed) with Ghostty resources.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/HangarApp"

APP=build/Hangar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hangar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SHARE=vendor/ghostty-src/zig-out/share
cp -R "$SHARE/terminfo" "$APP/Contents/Resources/terminfo"
cp -R "$SHARE/ghostty" "$APP/Contents/Resources/ghostty"
cp -R Resources/Icons "$APP/Contents/Resources/Icons"

codesign --force -s - "$APP"
echo "Built $APP"
