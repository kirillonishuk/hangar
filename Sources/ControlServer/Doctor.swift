import Foundation

/// `hangar doctor` / MCP `doctor` (decision #NN-doctor): a read-only health report, English, one line per check.
public enum DoctorLevel: String, Codable, Sendable { case ok, warn, fail }

public struct DoctorCheck: Codable, Equatable, Sendable {
    public var name: String
    public var level: DoctorLevel
    public var detail: String
    /// What to do about a warn or fail.
    public var fix: String?

    public init(name: String, level: DoctorLevel, detail: String, fix: String? = nil) {
        self.name = name; self.level = level; self.detail = detail; self.fix = fix
    }
}

/// The app's part of the report (the `doctor` method); the CLI adds the socket and version lines.
public struct DoctorResult: Codable, Equatable, Sendable {
    public var appVersion: String
    public var checks: [DoctorCheck]

    public init(appVersion: String, checks: [DoctorCheck]) {
        self.appVersion = appVersion; self.checks = checks
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var ok: Bool
    public var checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
        ok = !checks.contains { $0.level == .fail }
    }

    /// 0 when nothing failed (warnings included), else 1.
    public var exitCode: Int32 { ok ? 0 : 1 }
}

/// The whole report from the app's answer: an unreachable app is the one failing line.
public func doctorReport(app: Result<DoctorResult, ControlError>, cliVersion: String) -> DoctorReport {
    switch app {
    case let .failure(e):
        return DoctorReport(checks: [DoctorCheck(name: "app", level: .fail, detail: e.message,
                                                 fix: "Open Hangar.app; the other checks run inside it")])
    case let .success(r):
        let version = r.appVersion == cliVersion
            ? DoctorCheck(name: "version", level: .ok, detail: "CLI and app \(cliVersion)")
            : DoctorCheck(name: "version", level: .warn, detail: "CLI \(cliVersion), app \(r.appVersion)",
                          fix: "Restart Hangar, or point `hangar` at the running app's Contents/Helpers/hangar")
        return DoctorReport(checks: [DoctorCheck(name: "app", level: .ok, detail: "running, socket reachable"), version] + r.checks)
    }
}

/// `ok    name  detail` lines, a `fix:` line under each warn/fail, then a summary.
public func formatDoctor(_ r: DoctorReport) -> String {
    let width = r.checks.map(\.name.count).max() ?? 0
    var lines: [String] = []
    for c in r.checks {
        let level = c.level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        lines.append(level + c.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + c.detail)
        if c.level != .ok, let fix = c.fix { lines.append(String(repeating: " ", count: 6 + width + 2) + "fix: " + fix) }
    }
    let warns = r.checks.filter { $0.level == .warn }.count, fails = r.checks.filter { $0.level == .fail }.count
    func count(_ n: Int, _ word: String) -> String { n == 0 ? "no \(word)s" : "\(n) \(word)\(n == 1 ? "" : "s")" }
    lines.append(warns == 0 && fails == 0 ? "all ok" : count(warns, "warning") + ", " + count(fails, "failure"))
    return lines.joined(separator: "\n")
}

public func doctorJSON(_ r: DoctorReport) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(r)) ?? Data("{}".utf8)
}

/// `hangar doctor [--json]`.
public func parseDoctorArgs(_ args: [String]) -> CLIParse {
    var json = false
    for a in args.dropFirst() {
        guard a == "--json" else { return .usage(a.hasPrefix("--") ? "unknown flag \"\(a)\"" : "unexpected argument \"\(a)\"") }
        json = true
    }
    return .call(.doctor, json: json)
}
