#!/usr/bin/env bash
# Renders an app icon SVG into an .iconset and packs it into .icns.
# Built-in macOS tools only: swift (NSImage/CoreSVG) + iconutil.
#
#   scripts/make-icon.sh master.svg [small.svg] [out.icns]
#
# master.svg — 1024×1024 Big Sur template (docs/superpowers/mockups/app-icon/*.svg).
# small.svg  — optional simplified variant for 16, 16@2x and 32 px ("-" to skip).
# out.icns   — default Resources/AppIcon.icns.
# Note: CoreSVG ignores SVG filters; shadows must be plain shapes (as in the masters).
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="${1:?usage: scripts/make-icon.sh master.svg [small.svg] [out.icns]}"
SMALL="${2:--}"
OUT="${3:-Resources/AppIcon.icns}"
[ "$SMALL" = "-" ] && SMALL="$MASTER"
for f in "$MASTER" "$SMALL"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
// render.swift in.svg out.png pixels — draws the vector at the target size (no downscaling).
let a = CommandLine.arguments
guard a.count == 4, let px = Int(a[3]), let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else {
    FileHandle.standardError.write("render: cannot load \(CommandLine.arguments.dropFirst().first ?? "")\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swiftc -O -o "$TMP/render" "$TMP/render.swift" 2>/dev/null || { echo "swiftc failed (install Xcode CLT)" >&2; exit 1; }

# name:pixels
for spec in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
            icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 \
            icon_512x512:512 icon_512x512@2x:1024; do
  name="${spec%%:*}"; px="${spec##*:}"
  src="$MASTER"; [ "$px" -le 32 ] && [ "$name" != "icon_32x32@2x" ] && src="$SMALL"
  "$TMP/render" "$src" "$SET/$name.png" "$px"
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
echo "Wrote $OUT"
