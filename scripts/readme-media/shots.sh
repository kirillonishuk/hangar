#!/bin/bash
# README screenshots (docs/assets/screenshots/*.png) from the DEBUG app in the fixture world → $OUT/screenshots.
# Real window captures by id (titlebar and corners included); the app is never activated.
source "$(dirname "$0")/common.sh"
stop_app
bash "$D/setup.sh" >/dev/null
# Front only while capturing (a hidden window pauses its terminals); otherwise behind the owner's windows.
shoot() { $C "window front"; sleep 1.2; cap "$1"; $C "window back"; }
launch; sleep 5
$C "resize 1440 900" "window back"; sleep 0.5
scene  # common.sh: projects, chats in every state, the devbox project
$C "select 0"
$C "task discount-codes|Add a discount code field to the checkout"; sleep 16
$C "key toggleInspector" "inspector" "inspector changes"; sleep 3
shoot main

# The branch switcher of a chat in its own copy (clean, so every branch can be switched to).
$C "select 2" "inspector" "inspector files"; sleep 2
$C "branchMenu"; sleep 1.5; shoot branch
$C "menuPanel key 53"; sleep 0.5

$C "sheet 0"; sleep 1.5
$C "ntWorktree on" "ntName Add Apple Pay to checkout" "ntSetup on"; sleep 1.5; shoot new-chat
$C "ntCancel"; sleep 1

$C "key sessions"; sleep 3; shoot history
$C "key sessions"; sleep 1

$C "select 5" "inspector" "inspector git"; sleep 4; shoot remote

# Settings → Appearance: its own window, captured by id.
$C "settings appearance"; sleep 2.5
S=$("$T/wid" "$(pid)" | awk '$7=="Settings" && $8=="1"{print $1; exit}')
[ -n "$S" ] && screencapture -l "$S" -o -x $R/snaps/settings.png
$C "closeSettings"; sleep 0.5

# Dark+: the diff, inspector hidden for width.
$C "theme dark-plus" "select 3" "inspector" "inspector changes"; sleep 2
$C "eddiff src/checkout/cart.ts" "key toggleInspector"; sleep 4
shoot diff
$C "key toggleInspector" "theme navy"

# Russian UI: the Codex chat waiting for an approval.
$C "lang ru" "select 1" "inspector" "inspector git"; sleep 3
shoot main-ru
$C "lang en"
stop_app
# 2× captures scaled to 2/3 (the 1440 pt window → 1920 px), then quantized to a 256-color palette (alpha kept).
for f in $R/snaps/*.png; do
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  sips --resampleWidth $((w * 2 / 3)) "$f" --out "$R/scaled.png" >/dev/null
  ffmpeg -loglevel error -y -i "$R/scaled.png" -vf "split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=none:alpha_threshold=128" \
    "$OUT/screenshots/$(basename "$f")"
done
ls -l "$OUT/screenshots"
