import AgentStatus
import Foundation
import Workspace

public struct LaunchSpec: Equatable, Sendable {
    public var command: String
    public var cwd: String
    public var env: [String: String]
}

public enum LaunchError: Error, Equatable { case missingCwd(String) }

/// Command a terminal tab is started with. Ghostty runs it via /usr/bin/login (exit code always 0),
/// so the command is wrapped to emit OSC 133 C/D with the real exit code (decisions #26, #27).
/// `-l -i` is needed so PATH matches the user's terminal (~/.local/bin is set in ~/.zshrc).
public func launchSpec(for leaf: Leaf, tabId: UUID, config: HangarConfig, socketPath: String,
                       userShell: String, restoring: Bool, initialPrompt: String?) throws -> LaunchSpec {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: leaf.cwd, isDirectory: &isDir), isDir.boolValue else {
        throw LaunchError.missingCwd(leaf.cwd)
    }
    let userShellQuoted = shellQuote(userShell)
    let shell = shellQuote(posixShell(userShell))
    let inner = innerCommand(for: leaf, config: config, shell: userShellQuoted, restoring: restoring, initialPrompt: initialPrompt)
    let script = inner + #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#
    return LaunchSpec(command: "\(shell) -l -i -c \(shellQuote(script))",
                      cwd: leaf.cwd,
                      env: ["HANGAR_TAB_ID": tabId.uuidString, "HANGAR_LEAF_ID": leaf.id.uuidString, "HANGAR_SOCKET": socketPath])
}

/// Shell for `-l -i -c` wrappers.
// shortcut: non-POSIX shells get the zsh wrapper; agents then see zsh's PATH, change if a fish user hits it
public func posixShell(_ userShell: String) -> String {
    let posix: Set<String> = ["zsh", "bash", "sh"]
    return posix.contains((userShell as NSString).lastPathComponent) ? userShell : "/bin/zsh"
}

private func innerCommand(for leaf: Leaf, config: HangarConfig, shell: String,
                          restoring: Bool, initialPrompt: String?) -> String {
    func agent(_ kind: LeafKind) -> String { config.agentCommands[kind] ?? kind.rawValue }
    // A known id is used only when resuming: a fresh start after a failed `--resume <id>` ignores it.
    // state.json is editable: an id that is not valid falls back to the no-id resume instead of reaching argv.
    let id = restoring ? validSessionId(leaf.agentSessionId).map(shellQuote) : nil
    switch leaf.kind {
    case .shell:
        return "\(shell) -l -i"
    case .editor:
        return leaf.openFile.map { "\(config.editor) \(shellQuote($0))" } ?? config.editor
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
    return "\(cmd) \(shellQuote(prompt))"
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
}

/// Relaunch never re-sends the prompt; a failed resume starts fresh (else "No conversation found" loops),
/// any other exit resumes the conversation.
public func launchMode(for leaf: Leaf, _ context: LaunchContext) -> LaunchMode {
    switch context {
    case .created(let prompt): return LaunchMode(restoring: false, initialPrompt: prompt)
    case .restored(let inSet): return LaunchMode(restoring: inSet, initialPrompt: nil)
    case .relaunch(let previous, nil): return previous
    case .relaunch(let previous, let code?):
        let isAgent = leaf.kind == .claude || leaf.kind == .codex
        let resumeFailed = isAgent && previous.restoring && code != 0
        return LaunchMode(restoring: !resumeFailed, initialPrompt: nil)
    }
}
