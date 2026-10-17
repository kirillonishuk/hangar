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
    // shortcut: non-POSIX shells get the zsh wrapper; agents then see zsh's PATH, change if a fish user hits it
    let posix: Set<String> = ["zsh", "bash", "sh"]
    let shell = posix.contains((userShell as NSString).lastPathComponent) ? userShellQuoted : "/bin/zsh"
    let inner = innerCommand(for: leaf, config: config, shell: userShellQuoted, restoring: restoring, initialPrompt: initialPrompt)
    let script = inner + #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#
    return LaunchSpec(command: "\(shell) -l -i -c \(shellQuote(script))",
                      cwd: leaf.cwd,
                      env: ["HANGAR_TAB_ID": tabId.uuidString, "HANGAR_SOCKET": socketPath])
}

private func innerCommand(for leaf: Leaf, config: HangarConfig, shell: String,
                          restoring: Bool, initialPrompt: String?) -> String {
    func agent(_ kind: LeafKind) -> String { config.agentCommands[kind] ?? kind.rawValue }
    let id = leaf.agentSessionId.map(shellQuote)
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
