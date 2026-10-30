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
public func launchSpec(for leaf: Leaf, tabId: UUID, config: HangarConfig, socketPath: String,
                       userShell: String, restoring: Bool, initialPrompt: String?, port: Int? = nil) throws -> LaunchSpec {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: leaf.cwd, isDirectory: &isDir), isDir.boolValue else {
        throw LaunchError.missingCwd(leaf.cwd)
    }
    let isZsh = (userShell as NSString).lastPathComponent == "zsh"
    let userShellQuoted = (isZsh ? ghosttyZshIntegration : "") + shellQuote(userShell)
    let shell = shellQuote(posixShell(userShell))
    let inner = agentCommand(for: leaf, agent: { config.agentCommands[$0] ?? $0.rawValue },
                             shell: userShellQuoted, restoring: restoring, initialPrompt: initialPrompt)
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
public func agentCommand(for leaf: Leaf, agent: (LeafKind) -> String, shell: String,
                         restoring: Bool, initialPrompt: String?) -> String {
    // A known id is used only when resuming: a fresh start after a failed `--resume <id>` ignores it.
    // state.json is editable: an id that is not valid falls back to the no-id resume instead of reaching argv.
    let id = restoring ? validSessionId(leaf.agentSessionId).map(shellQuote) : nil
    switch leaf.kind {
    case .shell:
        // A new worktree's setup script (decision #58) runs first; the shell stays for the user.
        guard let script = initialPrompt, !script.isEmpty else { return "\(shell) -l -i" }
        return "\(script)\n\(shell) -l -i"
    case .editor, .choose:
        // The editor is Monaco (#81) and a chooser runs nothing; neither launches a terminal, a shell if one ever does.
        return "\(shell) -l -i"
    case .claude:
        if let id { return "\(agent(.claude)) --resume \(id)" }
        if restoring { return "\(agent(.claude)) --continue" }
        return withPrompt(agent(.claude), initialPrompt)
    case .codex:
        if let id { return "\(agent(.codex)) resume \(id)" }
        if restoring { return "\(agent(.codex)) resume --last" }
        return withPrompt(agent(.codex), initialPrompt)
    }
}

private func withPrompt(_ cmd: String, _ prompt: String?) -> String {
    guard let prompt, !prompt.isEmpty else { return cmd }
    // A leading space keeps agent CLIs from parsing a prompt like "--help" as a flag.
    return "\(cmd) \(shellQuote(prompt.hasPrefix("-") ? " " + prompt : prompt))"
}

/// What a launch passes to `launchSpec`; computed anew for every launch, never reused (decision #41).
public struct LaunchMode: Equatable, Sendable {
    public var restoring: Bool
    public var initialPrompt: String?
    public init(restoring: Bool, initialPrompt: String?) {
        self.restoring = restoring
        self.initialPrompt = initialPrompt
    }
}

public enum LaunchContext: Equatable, Sendable {
    /// New task or tab; the prompt goes only into this first launch.
    case created(prompt: String?)
    /// From state.json at startup or an unarchived task; `inResumeSet` per `resumeSet`.
    case restored(inResumeSet: Bool)
    /// ↩ or wake retry; `exitCode` nil = the surface never started (nothing ran).
    case relaunch(previous: LaunchMode, exitCode: Int32?)
    /// A remote tab whose session outlived its client (connection lost, detach): the session is attached again;
    /// if it is gone, agents resume instead of starting over.
    case reattach(previous: LaunchMode)
}

/// Relaunch never re-sends the prompt; a failed resume starts fresh (else "No conversation found" loops),
/// any other exit resumes the conversation.
public func launchMode(for leaf: Leaf, _ context: LaunchContext) -> LaunchMode {
    switch context {
    case .created(let prompt): return LaunchMode(restoring: false, initialPrompt: prompt)
    case .restored(let inSet): return LaunchMode(restoring: inSet, initialPrompt: nil)
    case .relaunch(let previous, nil): return previous
    case .reattach(let previous):
        return LaunchMode(restoring: leaf.kind == .claude || leaf.kind == .codex || previous.restoring, initialPrompt: nil)
    case .relaunch(let previous, let code?):
        let isAgent = leaf.kind == .claude || leaf.kind == .codex
        let resumeFailed = isAgent && previous.restoring && code != 0
        return LaunchMode(restoring: !resumeFailed, initialPrompt: nil)
    }
}

/// Markers of an enclosing Claude Code / Codex session (app started from an agent's terminal): tabs inheriting them
/// would make agents think they run nested or sandboxed. Config locations (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) stay.
public func inheritedAgentEnvToScrub(_ env: [String: String]) -> [String] {
    env.keys.filter { $0 == "CLAUDECODE" || $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("CODEX_SANDBOX") }
}
