#!/usr/bin/env bash
# Builds build/Hangar.app (release, ad-hoc signed) with Ghostty resources.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/HangarApp"

APP=build/Hangar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hangar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SHARE=vendor/ghostty-src/zig-out/share
cp -R "$SHARE/terminfo" "$APP/Contents/Resources/terminfo"
cp -R "$SHARE/ghostty" "$APP/Contents/Resources/ghostty"
cp -R Resources/Icons "$APP/Contents/Resources/Icons"
# SwiftPM resources (ru/en strings); L10n looks in Contents/Resources first.
cp -R "$BIN_DIR/Hangar_HangarUI.bundle" "$APP/Contents/Resources/Hangar_HangarUI.bundle"

mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/hangar" "$APP/Contents/Helpers/hangar"
codesign --force -s - "$APP/Contents/Helpers/hangar"

codesign --force -s - "$APP"
echo "Built $APP"
