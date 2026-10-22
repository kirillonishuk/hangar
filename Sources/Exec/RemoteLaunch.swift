import Foundation
import Workspace

/// One tmux session per remote leaf (#47).
public func remoteSessionName(_ leaf: UUID) -> String { "hangar-" + leaf.uuidString.lowercased() }

/// Runs on the host through `Runner.ssh`; `=` makes tmux match the name exactly, not as a prefix.
public func killSessionArgs(_ leaf: UUID) -> [String] { ["tmux", "kill-session", "-t", "=" + remoteSessionName(leaf)] }

/// A remote tab: `ssh -t` through the host's master into the leaf's tmux session (or straight into the agent without tmux).
/// Exit codes: the agent's own (255 → 254), 254 for a missing folder, 255 = the session did not end (lost or detached).
public func remoteLaunchSpec(for leaf: Leaf, tabId: UUID, target: RemoteTarget, editor: String,
                             restoring: Bool, initialPrompt: String?) -> LaunchSpec {
    // The server's PATH finds the agents; local `[agents]` are paths on this Mac.
    let cmd = agentCommand(for: leaf, agent: { $0.rawValue }, editor: editor, shell: #""$SHELL""#,
                           restoring: restoring, initialPrompt: initialPrompt)
    return LaunchSpec(command: remoteTabCommand(target: target, tabId: tabId, leafId: leaf.id, cwd: leaf.cwd, agentCommand: cmd),
                      cwd: NSHomeDirectory(), env: [:])
}

/// The local command line, wrapped like a local tab for the OSC 133 exit code (#26). Every value reaches the server
/// as a quoted word and is read as a positional parameter, never spliced into code.
func remoteTabCommand(target: RemoteTarget, tabId: UUID, leafId: UUID, cwd: String, agentCommand: String) -> String {
    let name = remoteSessionName(leafId)
    let args = [target.tmux ? remoteTmuxScript : remoteDirectScript, cwd, name, target.home + "/.hangar/run/" + name + ".exit",
                tabId.uuidString, leafId.uuidString, target.home + "/.hangar/hangar.sock", agentCommand]
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
HANGAR_S=$1 HANGAR_CWD=$2 HANGAR_SESSION=$3 HANGAR_EXIT=$4 HANGAR_TAB_ID=$5 HANGAR_LEAF_ID=$6 HANGAR_SOCKET=$7 HANGAR_CMD=$8
export HANGAR_S HANGAR_CWD HANGAR_SESSION HANGAR_EXIT HANGAR_TAB_ID HANGAR_LEAF_ID HANGAR_SOCKET HANGAR_CMD
exec "${SHELL:-/bin/sh}" -l -i -c 'exec /bin/sh -c "$HANGAR_S"'
"""#

/// Values back into locals; the launcher's variables are dropped so they never reach a tmux server's global env.
private let remoteScriptPrologue = #"""
cwd=$HANGAR_CWD s=$HANGAR_SESSION f=$HANGAR_EXIT tab=$HANGAR_TAB_ID leaf=$HANGAR_LEAF_ID sock=$HANGAR_SOCKET cmd=$HANGAR_CMD
unset HANGAR_S HANGAR_CWD HANGAR_SESSION HANGAR_EXIT HANGAR_TAB_ID HANGAR_LEAF_ID HANGAR_SOCKET HANGAR_CMD
cd "$cwd" 2>/dev/null || { echo "hangar: no such folder: $cwd" >&2; exit 254; }

"""#

/// An exit file means the agent ended (maybe while no client was attached): report it, start nothing.
/// tmux gets the pane command as argv (no shell parses it) and `-A` attaches to a live session as is.
/// The pane writes the agent's code; no file after the client returns = detached or lost.
let remoteTmuxScript = remoteScriptPrologue + #"""
if [ -f "$f" ]; then c=$(cat "$f"); rm -f "$f"; exit "${c:-0}"; fi
mkdir -p "${f%/*}"
tmux new-session -A -s "$s" -c "$cwd" /bin/sh -c 'export HANGAR_TAB_ID="$1" HANGAR_LEAF_ID="$2" HANGAR_SOCKET="$3"; "${SHELL:-/bin/sh}" -l -i -c "$4"; c=$?; [ $c = 255 ] && c=254; echo $c > "$5"' sh "$tab" "$leaf" "$sock" "$cmd" "$f" \; set-option -t "=$s" status off
if [ -f "$f" ]; then c=$(cat "$f"); rm -f "$f"; exit "${c:-0}"; fi
exit 255
"""#

/// Without tmux the agent runs in the ssh session itself; 255 stays ssh's "connection lost".
let remoteDirectScript = remoteScriptPrologue + #"""
export HANGAR_TAB_ID="$tab" HANGAR_LEAF_ID="$leaf" HANGAR_SOCKET="$sock"
"${SHELL:-/bin/sh}" -l -i -c "$cmd"; c=$?; [ $c = 255 ] && c=254; exit $c
"""#
