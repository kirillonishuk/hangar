# Sourced by setup/shots/video/social: paths and helpers for the README media fixture.
# Usage (macOS, Screen Recording allowed for the terminal; a DEBUG build that records the real SDK, so the window gets
# the current macOS chrome: `swift build --build-system native --scratch-path .build-native --product HangarApp` and
# `--product hangar`; BIN=<dir> picks another build dir):
#   TYPESCRIPT_DIR=<some node_modules/typescript> scripts/readme-media/shots.sh   # → $OUT/screenshots/*.png
#   scripts/readme-media/social.sh                                               # → $OUT/social-preview.png
#   scripts/readme-media/video.sh                                                # → $OUT/hangar-demo.{mp4,gif}
#   cp -R /tmp/hg-media-out/* docs/assets/   # after the owner has looked
# HANGAR_REPO=<checkout> to shoot another build. Everything lives under /tmp; the app never sees the real state/config.
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HANGAR_REPO=${HANGAR_REPO:-$(cd "$D/../.." && pwd)}  # a checkout with a DEBUG build
BIN=${BIN:-$HANGAR_REPO/.build-native/debug}
R=/tmp/hg-media          # fixture world (the fake ssh script hardcodes this path)
T=/tmp/hg-media-tools    # compiled Swift helpers
OUT=/tmp/hg-media-out    # results, laid out as docs/assets (setup.sh wipes $R, not this)
mkdir -p "$T" "$OUT/screenshots"
for t in hgcmd comp wid mkvideo social; do
  [ "$T/$t" -nt "$D/$t.swift" ] || swiftc -O "$D/$t.swift" -o "$T/$t" || exit 1
done
C="$T/hgcmd"

# DEBUG app only: isolated state/config, no activation, fake agents/ssh. Never a release build.
launch() {
  ( cd /tmp; exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin USER="$USER" LOGNAME="$LOGNAME" HOME="$HOME" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
    SHELL=/bin/zsh TERM=xterm-256color ZDOTDIR=$R/zdot \
    HANGAR_STATE_DIR=$R/state HANGAR_CONFIG=$R/config.toml HANGAR_DEBUG_NO_ACTIVATE=1 HANGAR_DEBUG_CHANNEL=media \
    HANGAR_DEBUG_PROJECT=$R/work/acme-web HANGAR_CLAUDE_SETTINGS=$R/claude/settings.json HANGAR_CODEX_CONFIG=$R/codex/config.toml \
    HANGAR_SSH=$R/sshd/ssh HANGAR_SSH_CONFIG=$R/sshd/config \
    "$BIN/HangarApp" > $R/app.log 2>&1 ) & echo $! > $R/app.pid
}
pid() { cat $R/app.pid; }
# cap <name>: the main window plus its sheets/panels, captured by window id → $R/snaps/<name>.png
cap() { "$T/comp" "$(pid)" "$R/snaps/$1.png" 2>>$R/comp.log || echo "cap $1 failed" >&2; }
stop_app() {
  [ -f $R/app.pid ] && kill -TERM "$(pid)" 2>/dev/null; sleep 2
  for p in $(pgrep -f "tmux -L hangar"); do lsof -p $p -a -d cwd 2>/dev/null | grep -q hg-media && kill -TERM $p; done
  pkill -f "$R/bin/" 2>/dev/null; pkill -f "$R/sshd/ssh" 2>/dev/null; true
}
# The demo world after launch: acme-web (chats in error / waiting / working states, two in their own copies, one
# archived), api, and api on the devbox server. `select` indices afterwards: 0 e2e-checkout, 1 currency-rounding,
# 2 search-bar, then a new acme-web chat at 3, 4 healthz, 5 orders-migration.
scene() {
  $C "project $R/work/api"; sleep 1
  $C "select 0"
  $C "task css-grid-spike|Try a CSS grid layout for the product page"; sleep 3
  $C "archive 0"; sleep 2
  $C "task e2e-checkout|Fix the flaky e2e checkout test"; sleep 6
  $C "wtask currency-rounding $R/work/acme-web.worktrees/currency-rounding fix/currency-rounding main"; sleep 2
  $C "tab codex"; sleep 6
  $C "wtask search-bar $R/work/acme-web.worktrees/search-bar feat/search-bar main"; sleep 2
  $C "ptask 1 healthz"; sleep 2
  $C "remote sheet"; sleep 1
  $C "remote fill devbox ~/srv/api" "remote connect"; sleep 6
  $C "remote add"; sleep 3
  $C "ptask 2 orders-migration"; sleep 6
}
