#!/usr/bin/env bash
# Builds vendor/GhosttyKit.xcframework from Ghostty at the SHA in vendor/GHOSTTY_COMMIT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ghostty-src"
OUT="$ROOT/vendor/GhosttyKit.xcframework"
SHA="$(tr -d '[:space:]' < "$ROOT/vendor/GHOSTTY_COMMIT")"
# Ghostty v1.3.x requires Zig 0.15.x: $ZIG, else the first 0.15 among the keg-only brew formula (Apple silicon or
# Intel prefix) and `zig` on PATH.
zig_ok() { case "$("$1" version 2>/dev/null || true)" in 0.15.*) return 0 ;; *) return 1 ;; esac; }
if [ -n "${ZIG:-}" ]; then
  [ -x "$ZIG" ] && zig_ok "$ZIG" || {
    echo "ZIG=$ZIG is not Zig 0.15.x (found: $("$ZIG" version 2>/dev/null || echo none)); Ghostty at $SHA needs 0.15" >&2; exit 1
  }
else
  for z in /opt/homebrew/opt/zig@0.15/bin/zig /usr/local/opt/zig@0.15/bin/zig "$(command -v zig || true)"; do
    if [ -n "$z" ] && [ -x "$z" ] && zig_ok "$z"; then ZIG="$z"; break; fi
  done
  [ -n "${ZIG:-}" ] || {
    echo "Zig 0.15 not found: brew install zig@0.15, or download it from https://ziglang.org/download/ and set ZIG=/path/to/zig" >&2
    exit 1
  }
fi
# Ghostty's xcframework needs full Xcode (SDK, metal, libtool), not only the Command Line Tools.
xcode-select -p >/dev/null 2>&1 && xcrun metal --version >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 || {
  echo "Needs Xcode with the Metal toolchain selected (xcode-select -s /Applications/Xcode.app;" \
       "on Xcode 26: xcodebuild -downloadComponent MetalToolchain)" >&2
  exit 1
}

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if [ "$(git -C "$SRC" rev-parse -q --verify HEAD || true)" != "$SHA" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$SHA"
  git -C "$SRC" checkout -q --detach FETCH_HEAD
fi

# Upstream a83a82b (after v1.3.1): Xcode 26 libtool silently drops misaligned zig archive members
# (libghostty_zcu.o) from libghostty-fat.a; apply that one-file fix. Drop when pinning a tag that has it.
FIX=a83a82b3f87b6efeb4384cbc9350056be70ecde0
git -C "$SRC" checkout -q -- src/build/LibtoolStep.zig
git -C "$SRC" cat-file -e "$FIX^{commit}" 2>/dev/null || git -C "$SRC" fetch -q --depth 2 origin "$FIX"
git -C "$SRC" diff "$FIX^" "$FIX" -- src/build/LibtoolStep.zig | git -C "$SRC" apply

# As Ghostty's release-tip.yml "Build GhosttyKit"; native = only this Mac's arch (no iOS slices).
(cd "$SRC" && "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native)

LIB="$(ls "$SRC"/macos/GhosttyKit.xcframework/macos-*/libghostty-fat.a | head -n 1)"
nm -gU "$LIB" 2>/dev/null | grep " T _ghostty_app_new$" >/dev/null || { echo "libghostty-fat.a lacks ghostty_app_new" >&2; exit 1; }

rm -rf "$OUT"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT"
echo "built $OUT at $SHA"
