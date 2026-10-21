import Foundation

/// Read-only probe of a server (POSIX sh). Prints only `HANGAR <key> <value>` lines, control characters removed,
/// `end` last. Tools are only asked for `--version` (`tmux -V`); nothing is written.
/// shortcut: a tool whose `--version` hangs hangs the check; the caller's cancel kills ssh. Add a timeout if seen.
public let serverCheckScript = #"""
p() { printf 'HANGAR %s\n' "$(printf '%s' "$*" | tr -d '\000-\037\177')"; }
p os "$(uname -s)"
if [ -r /etc/os-release ]; then
  d=$(sed -n 's/^ID=//p' /etc/os-release | tr -d "\"'" | head -n 1)
  if [ -n "$d" ]; then p distro "$d"; fi
fi
pm=none
for m in apt-get dnf yum pacman apk brew; do
  if command -v "$m" >/dev/null 2>&1; then pm=$m; break; fi
done
p pm "$pm"
p uid "$(id -u)"
if command -v sudo >/dev/null 2>&1; then p sudo yes; else p sudo no; fi
p home "$HOME"
p shell "${SHELL:-}"
for t in git tmux claude codex hx curl npm; do
  x=$(command -v "$t" 2>/dev/null)
  case $x in
    /*) if [ "$t" = tmux ]; then f=-V; else f=--version; fi
        p tool "$t" "$x" "$("$x" "$f" </dev/null 2>/dev/null | head -n 1 | cut -c 1-80)" ;;
    *) p missing "$t" ;;
  esac
done
c=none
for m in python3 socat nc; do
  if command -v "$m" >/dev/null 2>&1; then c=$m; break; fi
done
p client "$c"
r=none
f="$HOME/.hangar/bin/hangar-remote"
if [ -f "$f" ] && [ -x "$f" ]; then
  r=$(head -n 2 "$f" | sed -n '2s/^# hangar-remote \([0-9][0-9]*\)$/\1/p')
  if [ -z "$r" ]; then r=none; fi
fi
p remote "$r"
p claude_dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
p codex_home "${CODEX_HOME:-$HOME/.codex}"
p end
"""#

/// `$1` = the check script. The login shell (maybe fish) only supplies PATH and env, as for tabs; the script itself
/// always runs in /bin/sh, so it never has to parse in fish and `command -v` sees no rc aliases.
let serverCheckLauncher = #"HANGAR_CHECK=$1; export HANGAR_CHECK; exec "${SHELL:-/bin/sh}" -l -i -c 'exec /bin/sh -c "$HANGAR_CHECK"' </dev/null 2>/dev/null"#

public enum PackageManager: String, Sendable {
    case aptGet = "apt-get", dnf, yum, pacman, apk, brew
}

public enum RemoteTool: String, CaseIterable, Sendable {
    case git, tmux, claude, codex, hx, curl, npm
}

public struct ToolInfo: Equatable, Sendable {
    public var path: String
    public var version: String
}

public struct ServerReport: Equatable, Sendable {
    public var os, home, shell, claudeDir, codexHome: String
    public var distro: String?
    public var packageManager: PackageManager?
    /// -1 when the server did not report a valid uid (treated as a normal user).
    public var uid: Int
    public var hasSudo: Bool
    public var tools: [RemoteTool: ToolInfo]
    public var socketClient: String?
    public var remoteVersion: Int?

    public var tmux: Bool { tools[.tmux] != nil }
    public var missingRequired: [RemoteTool] { [RemoteTool.git, .tmux].filter { tools[$0] == nil } }
    /// Missing counts as outdated: either way the script has to be written.
    public func remoteOutdated(current: Int) -> Bool { (remoteVersion ?? 0) < current }
}

/// Strict parse of the (untrusted) check output: rc-file noise and anything after `end` is skipped, every value is
/// checked against its expected shape and length; nil without `end` or a valid `home`.
public func parseServerReport(_ stdout: String) -> ServerReport? {
    var r = ServerReport(os: "", home: "", shell: "", claudeDir: "", codexHome: "", distro: nil, packageManager: nil,
                         uid: -1, hasSudo: false, tools: [:], socketClient: nil, remoteVersion: nil)
    var ended = false
    for line in stdout.components(separatedBy: .newlines) where line.utf8.count <= 4096 && line.hasPrefix("HANGAR ") {
        let kv = line.dropFirst(7).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(kv[0]), value = kv.count > 1 ? String(kv[1]) : ""
        switch key {
        case "os": r.os = printable(value, max: 64) ?? ""
        case "distro":
            let ok = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
            r.distro = (1...64).contains(value.count) && value.allSatisfy(ok.contains) ? value : nil
        case "pm": r.packageManager = PackageManager(rawValue: value)
        case "uid": r.uid = Int(value).flatMap { (0...Int(UInt32.max)).contains($0) ? $0 : nil } ?? -1
        case "sudo": r.hasSudo = value == "yes"
        case "home": r.home = absolutePath(value) ?? ""
        case "shell": r.shell = absolutePath(value) ?? ""
        case "tool":
            let parts = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            // shortcut: a tool path with a space is not supported (the line is space-separated); rare on servers.
            guard parts.count >= 2, let tool = RemoteTool(rawValue: String(parts[0])),
                  let path = absolutePath(String(parts[1])) else { continue }
            let version = parts.count > 2 ? String(String.UnicodeScalarView(parts[2].unicodeScalars.filter { !isControl($0) })) : ""
            r.tools[tool] = ToolInfo(path: path, version: String(version.prefix(80)))
        case "missing": if let tool = RemoteTool(rawValue: value) { r.tools[tool] = nil }
        case "client": r.socketClient = ["python3", "socat", "nc"].contains(value) ? value : nil
        case "remote": r.remoteVersion = Int(value).flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        case "claude_dir": r.claudeDir = absolutePath(value) ?? ""
        case "codex_home": r.codexHome = absolutePath(value) ?? ""
        case "end": ended = true
        default: continue
        }
        if ended { break }
    }
    guard ended, !r.home.isEmpty else { return nil }
    if r.claudeDir.isEmpty { r.claudeDir = r.home + "/.claude" }
    if r.codexHome.isEmpty { r.codexHome = r.home + "/.codex" }
    return r
}

private func isControl(_ u: Unicode.Scalar) -> Bool { u.value < 0x20 || (0x7f...0x9f).contains(u.value) }

private func printable(_ s: String, max: Int) -> String? {
    !s.isEmpty && s.count <= max && !s.unicodeScalars.contains(where: isControl) ? s : nil
}

private func absolutePath(_ s: String) -> String? {
    s.hasPrefix("/") ? printable(s, max: 1024) : nil
}

/// Runs the check through `runner` (normally `Runner.ssh` over the master). Status 255 is ssh's own failure.
public func checkServer(_ runner: Runner) async -> Result<ServerReport, SSHFailure> {
    let r: RunResult
    do {
        r = try await runner.run(["/bin/sh", "-c", serverCheckLauncher, "sh", serverCheckScript], "")
    } catch {
        return .failure(.exited(-1, String("\(error)".prefix(300))))
    }
    if r.status != 255, let report = parseServerReport(r.stdout) { return .success(report) }
    return .failure(sshFailure(status: r.status, stderr: r.stderr.isEmpty ? "server check printed no report" : r.stderr))
}

public struct InstallStep: Equatable, Sendable {
    public var title: String
    public var command: String
    /// true: typed into a terminal tab (`ssh -t`, sudo asks there); false: run by `sshWrite` with the file on stdin.
    public var inTerminal: Bool
}

/// The install plan, built only from the fixed table below and the report's enums/booleans, never from server text.
/// `manual` = tools Hangar cannot install here (the sheet tells the user to install them themselves).
public func installPlan(_ r: ServerReport, remoteVersion: Int) -> (steps: [InstallStep], manual: [RemoteTool]) {
    var steps: [InstallStep] = [], manual: [RemoteTool] = []
    let has = { (t: RemoteTool) in r.tools[t] != nil }
    var pkgs: [(name: String, tool: RemoteTool?)] = []
    if !has(.git) { pkgs.append(("git", .git)) }
    if !has(.tmux) { pkgs.append(("tmux", .tmux)) }
    if r.socketClient == nil { pkgs.append(("socat", nil)) }
    if !has(.hx) { pkgs.append(("helix", .hx)) }
    if !has(.claude) && !has(.curl) { pkgs.append(("curl", .curl)) }

    let pm = r.packageManager.flatMap { $0 == .brew || r.uid == 0 || r.hasSudo ? $0 : nil }
    // apt-get and yum (RHEL/CentOS base) mostly have no helix package.
    if pm == .aptGet || pm == .yum, let i = pkgs.firstIndex(where: { $0.tool == .hx }) {
        manual.append(.hx)
        pkgs.remove(at: i)
    }
    if let pm, !pkgs.isEmpty {
        let list = pkgs.map(\.name).joined(separator: " ")
        let s = r.uid != 0 && pm != .brew ? "sudo " : ""
        let command = switch pm {
        case .aptGet: "\(s)apt-get update && \(s)apt-get install -y \(list)"
        case .dnf, .yum: "\(s)\(pm.rawValue) install -y \(list)"
        case .pacman: "\(s)pacman -S --needed --noconfirm \(list)"
        case .apk: "\(s)apk add \(list)"
        case .brew: "brew install \(list)"
        }
        steps.append(InstallStep(title: "packages", command: command, inTerminal: true))
    } else {
        manual += pkgs.compactMap(\.tool)
    }

    if !has(.claude) {
        if has(.curl) || !steps.isEmpty && pkgs.contains(where: { $0.tool == .curl }) {
            steps.append(InstallStep(title: "claude", command: "curl -fsSL https://claude.ai/install.sh | bash", inTerminal: true))
        } else {
            manual.append(.claude)
        }
    }
    if !has(.codex) {
        // verify: codex не установлен — команда не проверена
        if pm == .brew {
            steps.append(InstallStep(title: "codex", command: "brew install codex", inTerminal: true))
        } else if has(.npm) {
            steps.append(InstallStep(title: "codex", command: "npm install -g @openai/codex", inTerminal: true))
        } else {
            manual.append(.codex)
        }
    }
    if r.remoteOutdated(current: remoteVersion) {
        steps.append(InstallStep(
            title: "hangar-remote",
            command: #"mkdir -p "$HOME/.hangar/bin" && cat > "$HOME/.hangar/bin/hangar-remote" && chmod 700 "$HOME/.hangar/bin/hangar-remote""#,
            inTerminal: false))
    }
    return (steps, manual)
}

/// Exactly what the confirmation sheet shows and `ssh -t` receives.
public func terminalScript(_ steps: [InstallStep]) -> String {
    "set -e\n" + steps.filter(\.inTerminal).map(\.command).joined(separator: "\n")
}
