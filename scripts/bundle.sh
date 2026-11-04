#!/usr/bin/env bash
# Builds build/Hangar.app (release) with Ghostty resources. Signing identity: $HANGAR_SIGN_IDENTITY (name or SHA-1,
# "-" = ad-hoc), else "Hangar Self-Signed" from the keychain, else ad-hoc with a warning (decision #129).
set -euo pipefail
cd "$(dirname "$0")/.."

# A stable certificate keeps macOS permissions (screen recording, files…) across updates; ad-hoc loses them.
# find-identity without -v: the self-signed certificate is untrusted, but codesign signs with it.
IDENTITY="${HANGAR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$({ security find-identity -p codesigning 2>/dev/null || true; } | awk '/"Hangar Self-Signed"/ && !n++ { print $2 }')"
  [ -n "$IDENTITY" ] || {
    echo "warning: no \"Hangar Self-Signed\" identity in the keychain: signing ad-hoc (macOS permissions reset on every update)" >&2
    IDENTITY=-
  }
fi
# No Apple timestamp server for a self-signed certificate.
sign() { codesign --force --timestamp=none -s "$IDENTITY" "$1"; }

SHARE=vendor/ghostty-src/zig-out/share
[ -d vendor/GhosttyKit.xcframework ] && [ -d "$SHARE/terminfo" ] && [ -d "$SHARE/ghostty" ] || {
  echo "GhosttyKit or Ghostty's resources are missing: run scripts/build-ghosttykit.sh first" >&2; exit 1
}
XCODE_VERSION="$({ xcodebuild -version 2>/dev/null || true; } | awk 'NR == 1 { print $2 }')"
case "${XCODE_VERSION%%.*}" in
  2[6-9]|[3-9][0-9]) ;;
  *) echo "warning: Hangar is built with Xcode 26; found ${XCODE_VERSION:-no Xcode} (xcode-select -s /Applications/Xcode.app)" >&2 ;;
esac

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/HangarApp"

APP=build/Hangar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hangar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

cp -R "$SHARE/terminfo" "$APP/Contents/Resources/terminfo"
cp -R "$SHARE/ghostty" "$APP/Contents/Resources/ghostty"
# Dotfiles are easy to lose in CI artifacts; without .zshenv ZDOTDIR is never restored and ~/.zshrc is skipped (#98).
for f in ghostty/shell-integration/zsh/.zshenv; do
  [ -f "$APP/Contents/Resources/$f" ] || { echo "error: $f is missing from the bundle (hidden files dropped from the Ghostty resources?)" >&2; exit 1; }
done
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resources (ru/en strings, FileIcons/); L10n looks in Contents/Resources first.
cp -R "$BIN_DIR/Hangar_HangarUI.bundle" "$APP/Contents/Resources/Hangar_HangarUI.bundle"

mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/hangar" "$APP/Contents/Helpers/hangar"
sign "$APP/Contents/Helpers/hangar"

sign "$APP"
echo "Built $APP (signed: $IDENTITY)"
