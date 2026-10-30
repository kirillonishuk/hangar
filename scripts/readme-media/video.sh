#!/bin/bash
# README demo (hangar-demo.mp4 + .gif): window captures by id at a steady cadence → $OUT/hangar-demo.{mp4,gif}.
source "$(dirname "$0")/common.sh"
stop_app
bash "$D/setup.sh" >/dev/null
launch; sleep 5
$C "resize 1440 900" "window back"; sleep 0.5
scene
$C "select 2"; sleep 1

# Recording keeps the window in front (a hidden window pauses its terminals).
$C "window front"; sleep 1
F=$R/frames; rm -rf "$F"; mkdir -p "$F"; rm -f $R/stop
( i=0
  while [ ! -f $R/stop ]; do
    t=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); n=$(printf '%05d' $i)
    if "$T/comp" "$(pid)" "$F/$n.png" 2>/dev/null; then echo "$t $n.png" >> "$F/index.txt"; i=$((i+1)); fi
    [ $((i % 4)) = 0 ] && $C "window front"
    sleep 0.12
  done ) & REC=$!
sleep 2
$C "select 1"; sleep 2
$C "select 0"; $C "task discount-codes|Add a discount code field to the checkout"; sleep 11
$C "key toggleInspector" "inspector" "inspector changes"; sleep 2
$C "eddiff src/checkout/cart.ts"; sleep 3.5
$C "select 2"; sleep 1
$C "branchMenu"; sleep 3
$C "menuPanel key 53"; sleep 0.5
$C "key sessions"; sleep 3.5
touch $R/stop; wait $REC
$C "window back"
stop_app
wc -l < "$F/index.txt"
"$T/mkvideo" "$F" "$OUT/hangar-demo.mp4" "$OUT/hangar-demo.gif" 960
