#!/bin/bash
# README screenshots (docs/assets/screenshots/*.png) from the DEBUG app in the fixture world → $OUT/screenshots.
# Real window captures by id (titlebar and corners included); the app is never activated.
# SNAP=1: the app draws its own window (`snap …-window`, with the traffic lights) when the terminal may not capture
# the screen; the corners are cut to the window's radius afterwards. A menu or sheet is then snapped on its own and drawn
# over the window snap at its place (`over`). Settings needs SNAP unset.
source "$(dirname "$0")/common.sh"
stop_app
bash "$D/setup.sh" >/dev/null
# Front only while capturing (a hidden window pauses its terminals); otherwise behind the owner's windows.
shoot() {
  $C "window front"; sleep 1.2
  if [ -n "${SNAP:-}" ]; then $C "snap $R/snaps/$1-window.png"; sleep 1.5; mv "$R/snaps/$1-window.png" "$R/snaps/$1.png"; else cap "$1"; fi
  $C "window back"
}
# over <name> <radius>: $R/<name>-panel.png (the open menu or sheet) over $R/snaps/<name>.png, its corners cut to <radius> pt.
over() { "$T/over" "$(pid)" "$R/snaps/$1.png" "$R/$1-panel.png" "$2" "$R/over.png" 2>>$R/comp.log && mv "$R/over.png" "$R/snaps/$1.png"; }
launch; sleep 5
$C "resize 1440 900" "window back"; sleep 0.5
scene  # common.sh: projects, chats in every state, the devbox project
# Chats without a project (#126): one open, one asleep; `select` indices below are one more than in `scene`.
$C "chat new"; sleep 6
$C "chat new"; sleep 6
$C "chat sleep 0"; sleep 2
# docs-site: no open chats, one archived → «+ New chat» and «Archive · 1» (#125).
$C "project $R/work/docs-site"; sleep 1
$C "ptask 3 old-landing"; sleep 3
$C "key archiveTask"; sleep 6
$C "select 1"
$C "task discount-codes|Add a discount code field to the checkout"; sleep 16
$C "key toggleInspector" "inspector" "inspector changes"; sleep 3
shoot main

# The branch switcher of a chat in its own copy (clean, so every branch can be switched to).
$C "select 3" "inspector" "inspector files"; sleep 2
$C "branchMenu"; sleep 1.5
[ -n "${SNAP:-}" ] && { $C "menuPanel snap $R/branch-panel.png"; sleep 1; }
shoot branch
[ -n "${SNAP:-}" ] && over branch 10  # radius.popover
$C "menuPanel key 53"; sleep 0.5

# SNAP: the window is snapped before the sheet opens (with a sheet up, `snap` draws the sheet).
[ -n "${SNAP:-}" ] && shoot new-chat
$C "sheet 0"; sleep 1.5
$C "ntWorktree on" "ntName Add Apple Pay to checkout" "ntSetup on"; sleep 1.5
if [ -n "${SNAP:-}" ]; then
  $C "window front" "snap $R/new-chat-panel.png"; sleep 1.5; over new-chat 27; $C "window back"  # the system sheet's radius
else shoot new-chat; fi
$C "ntCancel"; sleep 1

$C "key sessions" "sessionsHover -1"; sleep 3; shoot history
$C "key sessions"; sleep 1

# The devbox terminal (#124): its Files panel follows the shell's folder; a dropped folder the server has → «Merge».
$C "hostShell devbox"; sleep 5
$C "type cd srv/api" "type git --no-pager log --oneline"; sleep 3
$C "inspector" "inspector files"; sleep 3
mkdir -p $R/upload/internal/billing; printf 'package billing\n' > $R/upload/internal/billing/invoice.go
$C "rf drop $R/upload/internal"; sleep 3; shoot remote
$C "rf answer esc"; sleep 1

# Settings → Appearance: its own window, captured by id.
$C "settings appearance"; sleep 2.5
S=$("$T/wid" "$(pid)" | awk '$7=="Settings" && $8=="1"{print $1; exit}')
[ -n "$S" ] && screencapture -l "$S" -o -x $R/snaps/settings.png
$C "closeSettings"; sleep 0.5

# Dark+: the diff, inspector hidden for width.
$C "theme dark-plus" "select 4" "inspector" "inspector changes"; sleep 2
$C "eddiff src/checkout/cart.ts" "key toggleInspector"; sleep 4
shoot diff
$C "key toggleInspector" "theme navy"

# Russian UI: the Codex chat waiting for an approval.
$C "lang ru" "select 2" "inspector" "inspector git"; sleep 3
shoot main-ru
$C "lang en"
stop_app
# 2× captures scaled to 2/3 (the 1440 pt window → 1920 px), then quantized to a 256-color palette (alpha kept).
# SNAP: square corners → the window's radius (35 px at 2×, decision #123), antialiased.
[ -n "${SNAP:-}" ] && for f in $R/snaps/*.png; do
  ffmpeg -loglevel error -y -i "$f" -vf "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='clip((35.5-hypot(max(0,abs(X-W/2+0.5)-(W/2-35)),max(0,abs(Y-H/2+0.5)-(H/2-35))))*255,0,255)'" "$R/rounded.png" && mv "$R/rounded.png" "$f"
done
for f in $R/snaps/*.png; do
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  sips --resampleWidth $((w * 2 / 3)) "$f" --out "$R/scaled.png" >/dev/null
  ffmpeg -loglevel error -y -i "$R/scaled.png" -vf "split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=none:alpha_threshold=128" \
    "$OUT/screenshots/$(basename "$f")"
done
ls -l "$OUT/screenshots"
