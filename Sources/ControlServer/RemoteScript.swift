import Foundation

/// Bumped whenever the script below changes; the host check compares it with the installed copy's second line.
public let hangarRemoteVersion = 2

/// `~/.hangar/bin/hangar-remote` on an ssh host: the same argv as `hangar event` / `hangar statusline`.
/// No JSON in sh: a header line plus the raw payload bytes; the Mac parses them (RemoteMessage).
public let hangarRemoteScript = #"""
#!/bin/sh
# hangar-remote \#(hangarRemoteVersion)
# Hooks must never see output or a non-zero exit from `event`; the payload is parsed by Hangar on the Mac.
max=262144

uuid() {
  case $1 in
    *[!0-9A-Fa-f-]*) return 1 ;;
    ????????-????-????-????-????????????) return 0 ;;
  esac
  return 1
}

# shortcut: no read timeout on a silent open stdin (hooks and the status line always close it), change if one hangs
# The trailing x keeps trailing newlines through $(…); dash/ash drop NUL bytes, which JSON never has.
read_stdin() {
  if [ -t 0 ]; then p=; else p=$(head -c $max; printf x); p=${p%x}; fi
}

# $1: header without len. Client output (the server's reply, errors) never reaches the agent.
deliver() {
  [ -S "$HANGAR_SOCKET" ] || return 0
  n=$(printf %s "$p" | wc -c | tr -cd 0-9)
  h="$1,\"len\":$n}"
  {
    if command -v python3 >/dev/null 2>&1; then
      { printf '%s\n' "$h"; printf %s "$p"; } | python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
s.recv(256)' "$HANGAR_SOCKET"
    elif command -v socat >/dev/null 2>&1; then
      # shortcut: a socket path with `,` or `:` would be misread by socat, ~/.hangar/hangar.sock has neither
      { printf '%s\n' "$h"; printf %s "$p"; } | socat -T2 - "UNIX-CONNECT:$HANGAR_SOCKET"
    elif command -v nc >/dev/null 2>&1; then
      { printf '%s\n' "$h"; printf %s "$p"; } | nc -U -w 2 "$HANGAR_SOCKET"
    fi
  } >/dev/null 2>&1
}

cmd=$1
[ $# -gt 0 ] && shift
case $cmd in
  version)
    echo \#(hangarRemoteVersion)
    ;;
  event)
    kind=$1
    [ $# -gt 0 ] && shift
    last=
    for a in "$@"; do last=$a; done
    session=
    while [ $# -gt 0 ]; do
      case $1 in
        --session) [ $# -ge 2 ] || break; session=$(printf %s "$2" | tr -cd 'A-Za-z0-9._-'); shift 2 ;;
        --then) shift; break ;;
        *) shift ;;
      esac
    done
    # After the loop "$@" is the user's original notify argv (plus codex's JSON), or empty.
    case $kind in
      session-start|prompt|tool|notification|stop|stop-failure|codex-notify) ;;
      *) kind= ;;
    esac
    if [ -n "$kind" ] && uuid "$HANGAR_TAB_ID" && uuid "$HANGAR_LEAF_ID" && [ -n "$HANGAR_SOCKET" ]; then
      case $last in
        "{"*) p=$last ;;
        *) read_stdin ;;
      esac
      s=
      [ -n "$session" ] && s=",\"session\":\"$session\""
      deliver "{\"v\":1,\"type\":\"hook\",\"tab\":\"$HANGAR_TAB_ID\",\"leaf\":\"$HANGAR_LEAF_ID\",\"kind\":\"$kind\"$s"
    fi
    # The original notify command still runs outside Hangar or without the app.
    if [ "$kind" = codex-notify ] && [ $# -gt 0 ]; then
      "$@" </dev/null >/dev/null 2>&1 &
    fi
    exit 0
    ;;
  statusline)
    then=
    while [ $# -gt 0 ]; do
      case $1 in
        --then) [ $# -ge 2 ] && then=$2; break ;;
        *) shift ;;
      esac
    done
    # shortcut: input above 256 KiB is truncated for the original command too (real payloads are a few KB)
    read_stdin
    [ -n "$p" ] && deliver '{"v":1,"type":"statusline"'
    [ -n "$then" ] || exit 0
    printf %s "$p" | sh -c "$then"
    exit $?
    ;;
  *)
    echo "usage: hangar-remote version | event <kind> [--session ID] [--then argv…] [json] | statusline [--then CMD]" >&2
    exit 2
    ;;
esac
"""#
