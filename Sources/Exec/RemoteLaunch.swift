import Foundation
import Workspace

/// One tmux session per remote leaf (#47).
public func remoteSessionName(_ leaf: UUID) -> String { "hangar-" + leaf.uuidString.lowercased() }

/// Runs on the host through `Runner.ssh`; `=` makes tmux match the name exactly, not as a prefix.
/// `-L hangar`: Hangar's own tmux server, so the user's `kill-server` on the default one never ends agents.
public func killSessionArgs(_ leaf: UUID) -> [String] { ["tmux", "-L", "hangar", "kill-session", "-t", "=" + remoteSessionName(leaf)] }

/// A remote tab: `ssh -t` through the host's master into the leaf's tmux session (or straight into the agent without tmux).
/// Exit codes: the agent's own (255 → 254), 254 for a missing folder, 255 = the session did not end (lost or detached).
public func remoteLaunchSpec(for leaf: Leaf, tabId: UUID, target: RemoteTarget,
                             restoring: Bool, initialPrompt: String?, port: Int? = nil) -> LaunchSpec {
    // The server's PATH finds the agents; local `[agents]` are paths on this Mac.
    let cmd = agentCommand(for: leaf, agent: { $0.rawValue }, shell: #""$SHELL""#,
                           restoring: restoring, initialPrompt: initialPrompt, hookCLI: remoteHookCLI)
    return LaunchSpec(command: remoteTabCommand(target: target, tabId: tabId, leafId: leaf.id, cwd: leaf.cwd, agentCommand: cmd, port: port),
                      cwd: NSHomeDirectory(), env: [:])
}

/// «<host> · терминал» (#64): a plain interactive `ssh -t` login to the host's home — no master, no server
/// check, no tmux — so a password or 2FA prompt works and the tab ends with the connection (255 → ↩ logs in again).
/// `host` must pass `validSSHHost`. ServerAlive ends a connection that died while the Mac slept instead of hanging.
public func sshShellSpec(host: String, sshPath: String) -> LaunchSpec {
    let ssh = [sshPath, "-t", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "--", host]
    let script = "TERM=xterm-256color " + ssh.map(shellQuote).joined(separator: " ")
        + #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#
    return LaunchSpec(command: "/bin/sh -c " + shellQuote(script), cwd: NSHomeDirectory(), env: [:])
}

/// The local command line, wrapped like a local tab for the OSC 133 exit code (#26). Every value reaches the server
/// as a quoted word and is read as a positional parameter, never spliced into code.
/// `port`: the task's `HANGAR_PORT` (#60); nil = not exported.
func remoteTabCommand(target: RemoteTarget, tabId: UUID, leafId: UUID, cwd: String, agentCommand: String, port: Int? = nil) -> String {
    let name = remoteSessionName(leafId)
    let args = [target.tmux ? remoteTmuxScript : remoteDirectScript, cwd, name, target.home + "/.hangar/run/" + name + ".exit",
                tabId.uuidString, leafId.uuidString, target.home + "/.hangar/hangar.sock", agentCommand, port.map(String.init) ?? ""]
    let ssh = [target.sshPath, "-t", "-e", "none"] + sshBaseArgs(controlPath: target.controlPath) + ["--", target.host]
    // `-e none`: a `~.` typed at a line start must not drop the connection.
    let inner = "TERM=xterm-256color " + ssh.map(shellQuote).joined(separator: " ") + " "
        + shellQuote(remoteShellArgs(script: remoteTabLauncher, args))
    let script = inner + #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#
    // ssh is an absolute path: no login shell is needed on this side.
    return "/bin/sh -c " + shellQuote(script)
}

/// `$1` = the script, the rest = its values. The login shell (maybe fish) only supplies PATH and env, as for the
/// server check; the values travel in the environment because a fish `-c` has no `"$@"`.
let remoteTabLauncher = #"""
HANGAR_S=$1 HANGAR_CWD=$2 HANGAR_SESSION=$3 HANGAR_EXIT=$4 HANGAR_TAB_ID=$5 HANGAR_LEAF_ID=$6 HANGAR_SOCKET=$7 HANGAR_CMD=$8 HANGAR_P=$9
export HANGAR_S HANGAR_CWD HANGAR_SESSION HANGAR_EXIT HANGAR_TAB_ID HANGAR_LEAF_ID HANGAR_SOCKET HANGAR_CMD HANGAR_P
exec "${SHELL:-/bin/sh}" -l -i -c 'exec /bin/sh -c "$HANGAR_S"'
"""#

/// Values back into locals; the launcher's variables are dropped so they never reach a tmux server's global env.
private let remoteScriptPrologue = #"""
cwd=$HANGAR_CWD s=$HANGAR_SESSION f=$HANGAR_EXIT tab=$HANGAR_TAB_ID leaf=$HANGAR_LEAF_ID sock=$HANGAR_SOCKET cmd=$HANGAR_CMD port=$HANGAR_P
unset HANGAR_S HANGAR_CWD HANGAR_SESSION HANGAR_EXIT HANGAR_TAB_ID HANGAR_LEAF_ID HANGAR_SOCKET HANGAR_CMD HANGAR_P
cd "$cwd" 2>/dev/null || { echo "hangar: no such folder: $cwd" >&2; exit 254; }

"""#

/// Attach first: `attach -d` to a live session (detaching any other client, so a lingering old connection never
/// reads the code). Only when that fails is the session gone, and then an exit file is final: the agent ended (maybe
/// while no client was attached) — report it, start nothing; an empty or garbled file is "exit status lost" (254),
/// never success. Else `new-session` (`-A -D` for a racing second client). A check-then-act (`has-session`, `rm`,
/// `new-session`) could lose a code written in between and start the agent again.
/// tmux gets the pane command as argv (no shell parses it). No `-c`: tmux format-expands it (`#`, `;`), the pane
/// starts in the client's folder from the `cd` above. `set-option -t "=$s:"`: the trailing `:` makes it a session
/// target (a bare `=$s` is read as a pane and fails).
/// The pane writes the agent's code; no file after the client returns = detached or lost.
// shortcut: a client detached by `-d` in the same instant the agent exits may still read the code; harmless for one view per leaf
let remoteTmuxScript = remoteScriptPrologue + #"""
code() { c=$(cat "$f" 2>/dev/null); rm -f "$f"; case $c in ''|*[!0-9]*) c=254 ;; esac; exit "$c"; }
if tmux -L hangar attach -d -t "=$s" 2>/dev/null; then
  if [ -f "$f" ]; then code; fi
  exit 255
fi
if [ -f "$f" ]; then code; fi
mkdir -p "${f%/*}"
tmux -L hangar new-session -A -D -s "$s" /bin/sh -c 'export HANGAR_TAB_ID="$1" HANGAR_LEAF_ID="$2" HANGAR_SOCKET="$3"; [ -z "$6" ] || export HANGAR_PORT="$6"; "${SHELL:-/bin/sh}" -l -i -c "$4"; c=$?; [ $c = 255 ] && c=254; echo $c > "$5"' sh "$tab" "$leaf" "$sock" "$cmd" "$f" "$port" \; set-option -t "=$s:" status off
if [ -f "$f" ]; then code; fi
exit 255
"""#

/// Without tmux the agent runs in the ssh session itself; 255 stays ssh's "connection lost".
let remoteDirectScript = remoteScriptPrologue + #"""
export HANGAR_TAB_ID="$tab" HANGAR_LEAF_ID="$leaf" HANGAR_SOCKET="$sock"
[ -z "$port" ] || export HANGAR_PORT="$port"
"${SHELL:-/bin/sh}" -l -i -c "$cmd"; c=$?; [ $c = 255 ] && c=254; exit $c
"""#
