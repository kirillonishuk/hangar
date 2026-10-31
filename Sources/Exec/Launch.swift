import AgentStatus
import Foundation
import Workspace

public struct LaunchSpec: Equatable, Sendable {
    public var command: String
    public var cwd: String
    public var env: [String: String]
}

public enum LaunchError: Error, Equatable {
    case missingCwd(String)
    /// A remote project's host has no live master yet; the leaf waits for `onConnected`.
    case notConnected(host: String)
    /// An agent tab waits for the answer to «Подключить Hangar к …?» (#111): its hooks must be in place before it starts.
    case awaitingConsent
}

/// Command a terminal tab is started with. Ghostty runs it via /usr/bin/login (exit code always 0),
/// so the command is wrapped to emit OSC 133 C/D with the real exit code (decisions #26, #27).
/// `-l -i` is needed so PATH matches the user's terminal (~/.local/bin is set in ~/.zshrc).
/// `hookCLI`: this app's `hangar`, for the hooks every claude tab gets on its command line (#119); nil — none.
public func launchSpec(for leaf: Leaf, tabId: UUID, config: HangarConfig, socketPath: String,
                       userShell: String, restoring: Bool, initialPrompt: String?, port: Int? = nil,
                       hookCLI: String? = nil) throws -> LaunchSpec {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: leaf.cwd, isDirectory: &isDir), isDir.boolValue else {
        throw LaunchError.missingCwd(leaf.cwd)
    }
    let isZsh = (userShell as NSString).lastPathComponent == "zsh"
    let userShellQuoted = (isZsh ? ghosttyZshIntegration : "") + shellQuote(userShell)
    let shell = shellQuote(posixShell(userShell))
    let inner = agentCommand(for: leaf, agent: { config.agentCommands[$0] ?? $0.rawValue },
                             shell: userShellQuoted, restoring: restoring, initialPrompt: initialPrompt,
                             hookCLI: hookCLI.map(shellQuote))
    let script = inner + #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#
    var env = ["HANGAR_TAB_ID": tabId.uuidString, "HANGAR_LEAF_ID": leaf.id.uuidString, "HANGAR_SOCKET": socketPath]
    env["HANGAR_PORT"] = port.map(String.init)  // the task's port (#60)
    return LaunchSpec(command: "\(shell) -l -i -c \(shellQuote(script))", cwd: leaf.cwd, env: env)
}

/// The account's login shell (what Ghostty.app and login(1) use); `$SHELL` is only the launching process's (#71).
/// A shell that is not there (a Homebrew fish/bash since uninstalled, an Intel prefix after migration) is skipped,
/// else every tab would fail to start.
public func resolveUserShell(passwd: String?, env: String?,
                             isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
    if let passwd, !passwd.isEmpty, isExecutable(passwd) { return passwd }
    if let env, !env.isEmpty, isExecutable(env) { return env }
    return "/bin/zsh"
}

/// zsh prefix for the tab's interactive shell: Ghostty injects its integration (ZDOTDIR) only into the outer `-c` zsh,
/// whose .zshenv then restores ZDOTDIR; `_ghostty_state` there means it was injected (not `shell-integration = none`).
public let ghosttyZshIntegration = #"(( ${+_ghostty_state} )) && { [[ -n ${ZDOTDIR+x} ]] && export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; export ZDOTDIR="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh"; }; "#

/// Shell for `-l -i -c` wrappers.
// shortcut: non-POSIX shells get the zsh wrapper; agents then see zsh's PATH, change if a fish user hits it
public func posixShell(_ userShell: String) -> String {
    let posix: Set<String> = ["zsh", "bash", "sh"]
    return posix.contains((userShell as NSString).lastPathComponent) ? userShell : "/bin/zsh"
}

/// What the tab runs inside its shell, for local and remote launches alike; `agent` names the CLI per kind
/// (locally `[agents]` from the config, on a server the bare name).
/// A conversation is only ever resumed by its own id, never by recency (`--continue` / `resume --last` took the folder's
/// latest chat, another tab's or terminal's, #119). A new claude conversation starts under the leaf's id (`--session-id`,
/// given by the caller); a conversation never written (nothing was said: no transcript) starts under that same id instead.
/// `hookCLI`: a shell word for `hangar` / `hangar-remote`; claude then gets Hangar's own hooks via `--settings`.
public func agentCommand(for leaf: Leaf, agent: (LeafKind) -> String, shell: String,
                         restoring: Bool, initialPrompt: String?, hookCLI: String? = nil,
                         transcriptCheck: (loginShell: String, note: String)? = nil) -> String {
    // state.json is editable: an id that is not valid never reaches argv.
    let id = validSessionId(leaf.agentSessionId)
    switch leaf.kind {
    case .shell:
        // A new worktree's setup script (decision #58) runs first; the shell stays for the user.
        guard let script = initialPrompt, !script.isEmpty else { return "\(shell) -l -i" }
        return "\(script)\n\(shell) -l -i"
    case .editor, .choose:
        // The editor is Monaco (#81) and a chooser runs nothing; neither launches a terminal, a shell if one ever does.
        return "\(shell) -l -i"
    case .claude:
        let claude = agent(.claude) + (hookCLI.map { " --settings " + shellQuote(tabAgentSettings(hookCLI: $0)) } ?? "")
        let uuid = id.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        if restoring, let id {
            // On this Mac the caller has already chosen by the transcript (`transcriptChoice`). On a server the choice is
            // made there, before the start, so a resumed chat that ends with an error is never followed by another start;
            // `sh -c` keeps it POSIX under fish, claude itself runs in the login shell (aliases, functions).
            guard let uuid, let check = transcriptCheck else { return "\(claude) --resume \(shellQuote(id))" }
            let spare = UUID().uuidString.lowercased()
            return "sh -c \(shellQuote(resumeOrStartScript)) sh \(uuid) \(spare) \(shellQuote(check.note)) \(check.loginShell) \(shellQuote(claude))"
        }
        return withPrompt(claude + (uuid.map { " --session-id \($0)" } ?? ""), initialPrompt)
    case .codex:
        if restoring, let id { return "\(agent(.codex)) resume \(shellQuote(id))" }
        return withPrompt(agent(.codex), initialPrompt)
    }
}

/// `--settings` JSON with the hooks Hangar's control of a tab relies on (#119): the conversation id, from the tab's own agent
/// only (`$PPID` of the hook's shell is that claude; a nested `claude -p` never gets these). They only track the conversation:
/// the installed hooks (if any) still drive the status. A missing CLI (app moved, no `hangar-remote`) is a silent no-op.
/// `--tab-agent` marks them: with `CLAUDE_CODE_SHELL_PREFIX` each hook's `$PPID` is another wrapper process.
public func tabAgentSettings(hookCLI: String) -> String {
    func hook(_ kind: HookKind) -> [String: Any] {
        ["hooks": [["type": "command", "command": "h=\(hookCLI); [ -x \"$h\" ] && \"$h\" event \(kind.rawValue) --tab-agent --agent-pid \"$PPID\"; exit 0"]]]
    }
    let root: [String: Any] = ["hooks": ["SessionStart": [hook(.sessionStart)], "UserPromptSubmit": [hook(.prompt)]]]
    let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Where a claude conversation stands on this Mac (#119): `resume` — its transcript was recorded in `cwd`; `start` — none
/// (nothing was said), start it under its id; `foreign` — recorded in another folder, so claude would never find it from here.
public enum TranscriptChoice: Equatable, Sendable { case resume, start, foreign }

/// The transcript is `<configDir>/projects/*/<id>.jsonl` — first the folder claude names after `cwd` (a copy made for a
/// moved worktree, #122, wins over the original elsewhere), then any; its folder is the first `cwd` among its first lines
/// (JSON, so escaped paths compare right). No `cwd` in them → this folder.
public func transcriptChoice(id: String, cwd: String, configDir: URL) -> TranscriptChoice {
    let projects = configDir.appendingPathComponent("projects")
    let own = [claudeProjectFolder(cwd), claudeProjectFolder(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)]
    let folders = own + ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [])
    guard let file = folders.lazy.map({ projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl") })
        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return .start }
    guard let handle = try? FileHandle(forReadingFrom: file) else { return .resume }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 1_048_576)) ?? Data()
    func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
    for line in head.split(separator: UInt8(ascii: "\n")).prefix(200) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let recorded = object["cwd"] as? String else { continue }
        return recorded == cwd || real(recorded) == real(cwd) ? .resume : .foreign
    }
    return .resume
}

/// `$1` id, `$2` a spare id, `$3` note, `$4` login shell (empty → /bin/sh), `$5` the claude command. The id's transcript (this
/// folder's project folder first, then any: ids are unique) recorded in this folder → `--resume`; none (nothing was said) → a new conversation under that id;
/// recorded elsewhere (claude would not find it from here, every time) → the note and a new conversation under the spare id,
/// which the tab's own SessionStart hook then stores.
let resumeOrStartScript = ##"""
id=$1 spare=$2 note=$3 sh=${4:-/bin/sh} c=$5
p=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
for f in "$p/$(enc "$PWD")/$id.jsonl" "$p/$(enc "$(pwd -P)")/$id.jsonl" "$p"/*/"$id".jsonl; do
  [ -e "$f" ] || continue
  if command -v python3 >/dev/null 2>&1 && ! python3 -I -c '
import json, os, sys
try:
    here = {os.getcwd(), os.path.realpath(os.getcwd()), os.environ.get("PWD")}
    with open(sys.argv[1], "rb") as f:
        for n, line in enumerate(f):
            if n >= 200: break
            try: cwd = json.loads(line).get("cwd")
            except Exception: continue
            if isinstance(cwd, str): sys.exit(0 if cwd in here or os.path.realpath(cwd) in here else 1)
except SystemExit: raise
except Exception: pass
' "$f"; then
    [ -z "$note" ] || printf '%s\n' "$note"
    exec "$sh" -l -i -c "$c --session-id $spare"
  fi
  exec "$sh" -l -i -c "$c --resume $id"
done
exec "$sh" -l -i -c "$c --session-id $id"
"""##

/// The hooks' CLI on a server (`hangar-remote`, installed by the server check).
public let remoteHookCLI = #""$HOME/.hangar/bin/hangar-remote""#

private func withPrompt(_ cmd: String, _ prompt: String?) -> String {
    guard let prompt, !prompt.isEmpty else { return cmd }
    // A leading space keeps agent CLIs from parsing a prompt like "--help" as a flag.
    return "\(cmd) \(shellQuote(prompt.hasPrefix("-") ? " " + prompt : prompt))"
}

/// What a launch passes to `launchSpec`; computed anew for every launch, never reused (decision #41).
public struct LaunchMode: Equatable, Sendable {
    public var restoring: Bool
    public var initialPrompt: String?
    /// A restored agent tab had no conversation id (saved before #119): it starts anew and says so.
    public var unlinked: Bool
    public init(restoring: Bool, initialPrompt: String?, unlinked: Bool = false) {
        self.restoring = restoring
        self.initialPrompt = initialPrompt
        self.unlinked = unlinked
    }
}

public enum LaunchContext: Equatable, Sendable {
    /// New task or tab; the prompt goes only into this first launch.
    case created(prompt: String?)
    /// From state.json at startup, an unarchived task or an opened conversation: resumes by the leaf's id.
    case restored
    /// ↩ or wake retry; `exitCode` nil = the surface never started (nothing ran).
    case relaunch(previous: LaunchMode, exitCode: Int32?)
    /// A remote tab whose session outlived its client (connection lost, detach): the session is attached again;
    /// if it is gone, agents resume instead of starting over.
    case reattach(previous: LaunchMode)
}

/// Relaunch never re-sends the prompt; a failed codex resume starts fresh (else "No conversation found" loops),
/// any other exit (and every claude exit) resumes the conversation.
public func launchMode(for leaf: Leaf, _ context: LaunchContext) -> LaunchMode {
    switch context {
    case .created(let prompt): return LaunchMode(restoring: false, initialPrompt: prompt)
    case .restored: return LaunchMode(restoring: true, initialPrompt: nil)
    case .relaunch(let previous, nil): return previous
    case .reattach(let previous):
        return LaunchMode(restoring: leaf.kind == .claude || leaf.kind == .codex || previous.restoring, initialPrompt: nil)
    case .relaunch(let previous, let code?):
        // A claude resume never fails for a missing chat (the command starts it instead): any exit resumes the same id.
        let resumeFailed = leaf.kind == .codex && previous.restoring && code != 0
        return LaunchMode(restoring: !resumeFailed, initialPrompt: nil)
    }
}

/// Markers of an enclosing Claude Code / Codex session (app started from an agent's terminal): tabs inheriting them
/// would make agents think they run nested or sandboxed. Config locations (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) stay.
public func inheritedAgentEnvToScrub(_ env: [String: String]) -> [String] {
    env.keys.filter { $0 == "CLAUDECODE" || $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("CODEX_SANDBOX") }
}
