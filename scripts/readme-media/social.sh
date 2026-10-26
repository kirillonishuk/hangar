#!/bin/bash
# social-preview.png (1280×640) from the icon and the fresh main screenshot (run shots.sh first).
source "$(dirname "$0")/common.sh"
"$T/social" "$D/../../docs/assets/icon-512.png" "$OUT/screenshots/main.png" "$OUT/social-preview.png"
