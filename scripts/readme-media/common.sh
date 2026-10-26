# Sourced by setup/shots/video/social: paths and helpers for the README media fixture.
# Usage (macOS, Screen Recording allowed for the terminal; a DEBUG build: `swift build`):
#   TYPESCRIPT_DIR=<some node_modules/typescript> scripts/readme-media/shots.sh   # → $OUT/screenshots/*.png
#   scripts/readme-media/social.sh                                               # → $OUT/social-preview.png
#   scripts/readme-media/video.sh                                                # → $OUT/hangar-demo.{mp4,gif}
#   cp -R /tmp/hg-media-out/* docs/assets/
# HANGAR_REPO=<checkout> to shoot another build. Everything lives under /tmp; the app never sees the real state/config.
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HANGAR_REPO=${HANGAR_REPO:-$(cd "$D/../.." && pwd)}  # a checkout with a DEBUG build (swift build)
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
    "$HANGAR_REPO/.build/debug/HangarApp" > $R/app.log 2>&1 ) & echo $! > $R/app.pid
}
pid() { cat $R/app.pid; }
# cap <name>: the main window plus its sheets/panels, captured by window id → $R/snaps/<name>.png
cap() { "$T/comp" "$(pid)" "$R/snaps/$1.png" 2>>$R/comp.log || echo "cap $1 failed" >&2; }
stop_app() {
  [ -f $R/app.pid ] && kill -TERM "$(pid)" 2>/dev/null; sleep 2
  for p in $(pgrep -f "tmux -L hangar"); do lsof -p $p -a -d cwd 2>/dev/null | grep -q hg-media && kill -TERM $p; done
  pkill -f "$R/bin/" 2>/dev/null; pkill -f "$R/sshd/ssh" 2>/dev/null; true
}
