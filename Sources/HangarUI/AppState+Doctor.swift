import ControlServer
import Exec
import Foundation
import Integration

/// The app's part of `hangar doctor` (decision #61). Read-only: nothing is written, installed or connected.
extension AppState {
    func doctorResult() async -> DoctorResult {
        let cmds = [config.agentCommands[.claude] ?? "claude", config.agentCommands[.codex] ?? "codex"].map(firstWord)
        let probe = await probeTools(cmds)
        var checks = [toolCheck("claude", cmds[0], probe[cmds[0]], missing: .fail),
                      toolCheck("codex", cmds[1], probe[cmds[1]], missing: .warn)]
        let paths = await doctorAgentPaths()
        let cli = hangarCLIPath(bundle: .main) ?? ""
        checks.append(hookCheck("claude hooks", claudeState(try? readUserFile(paths.claude) ?? nil, cli: cli), file: paths.claude))
        if probe[cmds[1]] != nil {
            checks.append(hookCheck("codex hooks", codexState(try? readUserFile(paths.codex) ?? nil, cli: cli), file: paths.codex))
        }
        checks.append(ghosttyCheck(resources: Bundle.main.resourceURL, bundled: hangarCLIPath(bundle: .main) != nil))
        for host in Set(state.projects.compactMap(\.host)).sorted() { checks.append(hostCheck(host, remote.hosts[host])) }
        checks.append(keepAwakeCheck(enabled: config.keepAwake, held: keepAwake.held, working: keepAwake.working))
        let stateDir = URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent)
        let free = try? stateDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        checks.append(diskCheck(free: free, path: tildePath(stateDir.path)))
        let version = Bundle.main.executableURL.map(MCPSession.appVersion) ?? "dev"
        return DoctorResult(appVersion: version, checks: checks)
    }

    /// As Settings: the agent dirs from the login shell, unless DEBUG pinned the files (`findAgentDirs` nil).
    private func doctorAgentPaths() async -> (claude: URL, codex: URL) {
        guard let find = findAgentDirs else { return (claudeSettingsURL, codexConfigURL) }
        let dirs = await find()
        return integrationPaths(home: FileManager.default.homeDirectoryForCurrentUser, claudeConfigDir: dirs.claude, codexHome: dirs.codex)
    }

    /// Path and first `--version` line per command, through the login shell (the PATH agents start with); 15 s at most.
    private func probeTools(_ commands: [String]) async -> [String: (path: String, version: String)] {
        let script = #"for a; do p=$(command -v "$a" 2>/dev/null) || continue; v=$("$a" --version </dev/null 2>/dev/null | head -n 1); printf 'HANGAR-DOCTOR\t%s\t%s\t%s\n' "$a" "$p" "$v"; done"#
        let shell = posixShell(userShell)
        let out: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await Runner.local.run([shell, "-l", "-i", "-c", script, "doctor"] + commands, NSHomeDirectory()).stdout }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return parseToolProbe(out ?? "")
    }
}

private func firstWord(_ command: String) -> String { command.split(separator: " ").first.map(String.init) ?? command }

/// `HANGAR-DOCTOR\t<cmd>\t<path>\t<version>` lines; rc-file noise around them is skipped.
func parseToolProbe(_ out: String) -> [String: (path: String, version: String)] {
    var found: [String: (path: String, version: String)] = [:]
    for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("HANGAR-DOCTOR\t") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, !f[2].isEmpty else { continue }
        found[f[1]] = (f[2], f[3].trimmingCharacters(in: .whitespaces))
    }
    return found
}

func toolCheck(_ name: String, _ command: String, _ found: (path: String, version: String)?, missing: DoctorLevel) -> DoctorCheck {
    guard let found else {
        let fix = "Install \(name), or set its path under [agents] in ~/.config/hangar/config.toml"
        return DoctorCheck(name: name, level: missing, detail: "`\(command)` not found in the login shell's PATH", fix: fix)
    }
    return DoctorCheck(name: name, level: .ok, detail: found.path + (found.version.isEmpty ? "" : "  " + found.version))
}

func hookCheck(_ name: String, _ state: IntegrationState, file: URL) -> DoctorCheck {
    let where_ = tildePath(file.path)
    switch state {
    case .installed: return DoctorCheck(name: name, level: .ok, detail: "installed in \(where_)")
    case .installedStatuslineByUser:
        return DoctorCheck(name: name, level: .warn, detail: "hooks installed; the status line is your own, so limits are not shown",
                           fix: "Make `statusLine` a command object, then reinstall in Settings → Integrations")
    case .outdated:
        return DoctorCheck(name: name, level: .warn, detail: "outdated in \(where_) (another CLI path or missing entries)",
                           fix: "Settings → Integrations → Install again")
    case .notInstalled:
        return DoctorCheck(name: name, level: .warn, detail: "not installed in \(where_): no agent statuses", fix: "Settings → Integrations → Install")
    }
}

/// The bundle's `ghostty` (shell integration, themes) and `terminfo` (xterm-ghostty); a DEBUG run has no bundle.
func ghosttyCheck(resources: URL?, bundled: Bool) -> DoctorCheck {
    guard bundled else { return DoctorCheck(name: "ghostty", level: .warn, detail: "not a bundled app (DEBUG run)", fix: "Build with scripts/bundle.sh") }
    let missing = ["ghostty", "terminfo"].filter { dir in
        resources.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(dir).path) } ?? true
    }
    guard missing.isEmpty else {
        return DoctorCheck(name: "ghostty", level: .fail, detail: "missing in Contents/Resources: " + missing.joined(separator: ", "),
                           fix: "Reinstall Hangar.app (scripts/bundle.sh copies them)")
    }
    return DoctorCheck(name: "ghostty", level: .ok, detail: "resources present")
}

func hostCheck(_ host: String, _ info: HostInfo?) -> DoctorCheck {
    let name = "ssh " + host
    let reconnect = "Reconnect from the project's menu, or check `ssh \(host)` in a terminal"
    switch info?.state ?? .disconnected {
    case .unreachable(let reason): return DoctorCheck(name: name, level: .fail, detail: "unreachable: \(reason)", fix: reconnect)
    case .disconnected, .connecting, .reconnecting: return DoctorCheck(name: name, level: .warn, detail: "not connected", fix: reconnect)
    case .connected: break
    }
    guard let r = info?.report else { return DoctorCheck(name: name, level: .warn, detail: "connected, server not checked yet", fix: "Open «Server \(host)»") }
    let problems = remoteAddWarnings(info ?? HostInfo())
    let tmux = r.tools[.tmux].map { "tmux \($0.version)" } ?? "no tmux"
    let remote = r.remoteVersion.map { "hangar-remote \($0)" } ?? "no hangar-remote"
    guard problems.isEmpty else {
        return DoctorCheck(name: name, level: .warn, detail: "connected; " + problems.joined(separator: "; "),
                           fix: "Open «Server \(host)» from the project's menu and install what is missing")
    }
    return DoctorCheck(name: name, level: .ok, detail: "connected, \(tmux), \(remote)")
}

func keepAwakeCheck(enabled: Bool, held: Bool, working: Int) -> DoctorCheck {
    guard enabled else { return DoctorCheck(name: "keep-awake", level: .ok, detail: "off (Settings)") }
    return DoctorCheck(name: "keep-awake", level: .ok, detail: held ? "on, holding sleep off (\(working) working)" : "on, idle")
}

/// Under 1 GB the state file may fail to save; under 5 GB, a warning.
func diskCheck(free: Int64?, path: String) -> DoctorCheck {
    guard let free else { return DoctorCheck(name: "disk", level: .warn, detail: "free space of \(path) unknown") }
    let text = String(format: "%.1f GB free on %@", Double(free) / 1e9, path)  // English, whatever the locale
    if free < 1_000_000_000 { return DoctorCheck(name: "disk", level: .fail, detail: text, fix: "Free disk space: state saves may fail") }
    if free < 5_000_000_000 { return DoctorCheck(name: "disk", level: .warn, detail: text, fix: "Free some disk space") }
    return DoctorCheck(name: "disk", level: .ok, detail: text)
}
