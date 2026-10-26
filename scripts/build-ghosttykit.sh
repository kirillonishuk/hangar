#!/usr/bin/env bash
# Builds vendor/GhosttyKit.xcframework from Ghostty at the SHA in vendor/GHOSTTY_COMMIT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ghostty-src"
OUT="$ROOT/vendor/GhosttyKit.xcframework"
SHA="$(tr -d '[:space:]' < "$ROOT/vendor/GHOSTTY_COMMIT")"
# Ghostty v1.3.x requires Zig 0.15.x: $ZIG, else the keg-only brew formula (PATH untouched on purpose).
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"

[ -x "$ZIG" ] || { echo "missing $ZIG (brew install zig@0.15, or set ZIG=/path/to/zig-0.15)" >&2; exit 1; }

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

LIB="$SRC/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
nm -gU "$LIB" 2>/dev/null | grep " T _ghostty_app_new$" >/dev/null || { echo "libghostty-fat.a lacks ghostty_app_new" >&2; exit 1; }

rm -rf "$OUT"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT"
echo "built $OUT at $SHA"
