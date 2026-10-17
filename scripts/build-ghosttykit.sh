#!/usr/bin/env bash
# Builds vendor/GhosttyKit.xcframework from Ghostty at the SHA in vendor/GHOSTTY_COMMIT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ghostty-src"
OUT="$ROOT/vendor/GhosttyKit.xcframework"
SHA="$(tr -d '[:space:]' < "$ROOT/vendor/GHOSTTY_COMMIT")"
# Ghostty v1.3.x requires Zig 0.15.x; keg-only brew formula, PATH untouched on purpose.
ZIG="/opt/homebrew/opt/zig@0.15/bin/zig"

[ -x "$ZIG" ] || { echo "missing $ZIG (brew install zig@0.15)" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if [ "$(git -C "$SRC" rev-parse -q --verify HEAD || true)" != "$SHA" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$SHA"
  git -C "$SRC" checkout -q --detach FETCH_HEAD
fi

# As Ghostty's release-tip.yml "Build GhosttyKit"; native = only this Mac's arch (no iOS slices).
(cd "$SRC" && "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native)

rm -rf "$OUT"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT"
echo "built $OUT at $SHA"
