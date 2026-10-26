#!/bin/bash
# README demo (hangar-demo.mp4 + .gif): window captures by id at a steady cadence → $OUT/hangar-demo.{mp4,gif}.
source "$(dirname "$0")/common.sh"
stop_app
bash "$D/setup.sh" >/dev/null
launch; sleep 4
$C "resize 1440 900" "window front"; sleep 0.5
$C "select 0"
$C "task currency-rounding|Fix rounding of cart totals in EUR"; sleep 2
$C "task search-bar|Build a search bar with keyboard navigation"; sleep 9
$C "window front"; sleep 0.5

F=$R/frames; rm -rf "$F"; mkdir -p "$F"; rm -f $R/stop
( i=0
  while [ ! -f $R/stop ]; do
    t=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); n=$(printf '%05d' $i)
    if "$T/comp" "$(pid)" "$F/$n.png" 2>/dev/null; then echo "$t $n.png" >> "$F/index.txt"; i=$((i+1)); fi
    [ $((i % 4)) = 0 ] && $C "window front"
    sleep 0.12
  done ) & REC=$!
sleep 1
$C "task discount-codes|Add a discount code field to the checkout"; sleep 11
$C "window front" "key toggleInspector" "inspector git"; sleep 2.5
$C "inspector changes"; sleep 1.2
$C "eddiff src/checkout/cart.ts"; sleep 3
$C "window front" "inspector files"; sleep 1.5
$C "open $R/work/acme-web/src/checkout/DiscountField.tsx"; sleep 2.5
$C "edjs (function(){const e=monaco.editor.getEditors().find(x=>!x.getOption(monaco.editor.EditorOption.readOnly)); const m=e.getModel(); const r=m.findMatches('applyDiscount(cart',false,false,true,null,false)[0].range; e.setPosition({lineNumber:r.startLineNumber,column:r.startColumn+3}); e.revealLineInCenter(r.startLineNumber);})()"
sleep 1
$C "edjs (function(){const e=monaco.editor.getEditors().find(x=>!x.getOption(monaco.editor.EditorOption.readOnly)); e.trigger('debug','editor.action.revealDefinition',{});})()"
sleep 1.5
$C "edjs (function(){const e=monaco.editor.getEditors().find(x=>!x.getOption(monaco.editor.EditorOption.readOnly)); e.trigger('debug','editor.action.showHover',{});})()"
sleep 2.5
$C "window front" "key sessions"; sleep 3.5
touch $R/stop; wait $REC
stop_app
wc -l < "$F/index.txt"
"$T/mkvideo" "$F" "$OUT/hangar-demo.mp4" "$OUT/hangar-demo.gif" 1200
