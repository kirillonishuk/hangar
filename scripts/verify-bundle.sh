#!/usr/bin/env bash
# Smoke-checks a bundled Hangar.app (built dir or mounted DMG): Ghostty resources complete (dotfiles included),
# zsh integration really restores the user's ~/.zshrc, version stamped, signature valid. Usage:
#   scripts/verify-bundle.sh path/to/Hangar.app [expected-version]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: verify-bundle.sh path/to/Hangar.app [expected-version]}"
EXPECTED="${2:-}"
SHARE=vendor/ghostty-src/zig-out/share
RES="$APP/Contents/Resources"
fail() { echo "verify-bundle FAILED: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP is not a directory"

# 1. Every Ghostty resource (hidden files too) made it into the bundle.
for d in ghostty terminfo; do
  [ -d "$SHARE/$d" ] || fail "$SHARE/$d missing: build GhosttyKit first"
  while IFS= read -r f; do
    [ -e "$RES/$d/${f#"$SHARE/$d/"}" ] || fail "$d/${f#"$SHARE/$d/"} is missing from the bundle (dotfile dropped by an artifact/copy step?)"
  done < <(find "$SHARE/$d" -type f -o -type l)
done

# 2. Reproduce the real failure: a tab's zsh must still read the user's ~/.zshrc through Ghostty's ZDOTDIR.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/marker"
echo "export PATH=\"$TMP/marker:\$PATH\"" > "$TMP/home/.zshrc"
PATH_OUT="$(env -i HOME="$TMP/home" PATH=/usr/bin:/bin ZDOTDIR="$RES/ghostty/shell-integration/zsh" \
  GHOSTTY_RESOURCES_DIR="$RES/ghostty" /bin/zsh -l -i -c 'echo "$PATH"' 2>/dev/null </dev/null | tail -n 1)"
case ":$PATH_OUT:" in
  *":$TMP/marker:"*) ;;
  *) fail "zsh with Ghostty's ZDOTDIR did not read ~/.zshrc (PATH=$PATH_OUT): shell-integration/zsh/.zshenv is broken or missing" ;;
esac
# bash: Ghostty's integration is a single non-hidden file loaded via --rcfile; checked by step 1.

# 3. Version and signature.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "bad CFBundleShortVersionString '$VERSION'"
[ -z "$EXPECTED" ] || [ "$VERSION" = "$EXPECTED" ] || fail "version is $VERSION, expected $EXPECTED"
codesign --verify --deep --strict "$APP" || fail "codesign verification failed"

echo "verify-bundle OK: $APP ($VERSION)"
