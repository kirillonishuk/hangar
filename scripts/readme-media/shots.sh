#!/bin/bash
# README screenshots (docs/assets/screenshots/*.png) from the DEBUG app in the fixture world → $OUT/screenshots.
source "$(dirname "$0")/common.sh"
stop_app
bash "$D/setup.sh" >/dev/null
launch; sleep 4
$C "resize 1440 900" "window front"; sleep 0.5
$C "select 0"
$C "task css-grid-spike|Try a CSS grid layout for the product page"; sleep 3
$C "archive 0"; sleep 2
$C "task currency-rounding|Fix rounding of cart totals in EUR"; sleep 2
$C "task search-bar|Build a search bar with keyboard navigation"; sleep 2
$C "task discount-codes|Add a discount code field to the checkout"; sleep 13
$C "key toggleInspector" "inspector git"; sleep 3
$C "window front"; sleep 1; cap main

# The palette closes when it loses key; retry until its panel (580 pt wide) is on screen.
for _ in 1 2 3 4 5; do
  $C "palette close" "palette open" "palette type dis"; sleep 1.5
  "$T/wid" "$(pid)" | awk '$5==580 && $8=="1"{f=1} END{exit !f}' && break
done
cap palette
$C "palette close"

$C "inspector files" "open $R/work/acme-web/src/checkout/DiscountField.tsx 8"; sleep 6
$C "edjs (function(){const e=monaco.editor.getEditors().find(x=>!x.getOption(monaco.editor.EditorOption.readOnly)); const m=e.getModel(); const r=m.findMatches('applyDiscount(cart',false,false,true,null,false)[0].range; e.setPosition({lineNumber:r.startLineNumber,column:r.startColumn+3}); e.trigger('debug','editor.action.revealDefinition',{});})()"
sleep 3
$C "edjs (function(){const e=monaco.editor.getEditors().find(x=>!x.getOption(monaco.editor.EditorOption.readOnly)); e.trigger('debug','editor.action.showHover',{});})()"
sleep 2; $C "window front"; sleep 1; cap editor

$C "key toggleInspector" "eddiff src/checkout/cart.ts"; sleep 3
$C "window front"; sleep 1; cap diff

$C "key sessions"; sleep 3
$C "window front"; sleep 1; cap sessions

$C "select 2" "key toggleInspector"; sleep 1
$C "remote sheet"; sleep 1
$C "remote fill devbox ~/srv/api" "remote connect"; sleep 6
$C "remote install"; sleep 5
$C "window front"; sleep 0.5; cap remote-sheet
$C "remote add"; sleep 3
$C "ptask 1 healthz"; sleep 12
$C "inspector git"; sleep 3
$C "window front"; sleep 1; cap remote

# Settings → Appearance (theme tiles): its own window, captured by id (760 pt wide).
$C "settings appearance"; sleep 2
S=$("$T/wid" "$(pid)" | awk '$5==760 && $8=="1"{print $1; exit}')
[ -n "$S" ] && screencapture -l "$S" -o -x $R/snaps/settings.png
$C "closeSettings"
$C "remote close"; sleep 0.5
stop_app
# 2× captures scaled to 2/3 (the 1440 pt window → 1920 px), as committed.
for f in $R/snaps/*.png; do
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  sips --resampleWidth $((w * 2 / 3)) "$f" --out "$OUT/screenshots/$(basename "$f")" >/dev/null
done
ls -1 "$OUT/screenshots"
