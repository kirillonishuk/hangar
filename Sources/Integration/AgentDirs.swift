import Exec
import Foundation

private let marker = "__hangar_dirs__"

/// Settings files the agents read: `$CLAUDE_CONFIG_DIR/settings.json` and `$CODEX_HOME/config.toml` when set (absolute), else under home.
public func integrationPaths(home: URL, claudeConfigDir: String?, codexHome: String?) -> (claude: URL, codex: URL) {
    func dir(_ v: String?) -> URL? {
        guard let v else { return nil }
        let p = (v as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : nil
    }
    return ((dir(claudeConfigDir) ?? home.appendingPathComponent(".claude")).appendingPathComponent("settings.json"),
            (dir(codexHome) ?? home.appendingPathComponent(".codex")).appendingPathComponent("config.toml"))
}

/// Fields after the last marker; an interactive shell may print anything before it.
func parseAgentDirs(_ out: String) -> (claude: String?, codex: String?) {
    guard let r = out.range(of: marker, options: .backwards) else { return (nil, nil) }
    let f = out[r.upperBound...].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    func v(_ i: Int) -> String? { i < f.count && !f[i].isEmpty ? f[i] : nil }
    return (v(0), v(1))
}

/// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` as the user's login shell sets them (a GUI app does not inherit them), like `resolveCodex`.
public func resolveAgentDirs(runner: Runner, shell: String, timeout: Duration = .seconds(10)) async -> (claude: String?, codex: String?) {
    let script = "printf '\\n\(marker)%s\\0%s\\0' \"$CLAUDE_CONFIG_DIR\" \"$CODEX_HOME\""
    let out: String? = await withTaskGroup(of: String?.self) { group in
        group.addTask { try? await runner.run([shell, "-l", "-i", "-c", script], NSHomeDirectory()).stdout }
        group.addTask { try? await Task.sleep(for: timeout); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()  // kills a hung shell (Runner terminates on cancellation)
        return first
    }
    return parseAgentDirs(out ?? "")
}
