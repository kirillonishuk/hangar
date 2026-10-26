import Foundation

/// UI language setting; `system` resolves to ru when the first system language is Russian, else en.
public enum Language: String, Sendable, CaseIterable { case system, ru, en }

public struct HangarConfig: Equatable, Sendable {
    public var defaultAgent: LeafKind = .claude
    public var agentCommands: [LeafKind: String] = [.claude: "claude", .codex: "codex"]
    public var terminalBackground: TerminalBackground = .hangar
    public var language: Language = .system
    /// Command opening files outside Hangar (e.g. `zed`); nil = off.
    public var externalEditor: String?
    /// macOS notifications when an agent waits or finishes in a leaf that isn't on screen.
    public var notifications = true
    /// Notifications for subscription-limit thresholds (Task 11).
    public var limitNotifications = true
    /// Hold a sleep assertion while agents work (spec §5.2).
    public var keepAwake = true
    /// Dock badge with the number of tasks waiting for the user, and a Dock bounce when one starts waiting out of focus.
    public var dockBadge = true

    public enum TerminalBackground: String, Sendable { case hangar, theme }

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case syntax(line: Int, reason: String)
        case unknownAgent(line: Int, name: String)
        case unknownKey(line: Int, key: String)

        public var description: String {
            switch self {
            case .syntax(let n, let r): return "line \(n): \(r)"
            case .unknownAgent(let n, let a): return "line \(n): unknown agent \"\(a)\""
            case .unknownKey(let n, let k): return "line \(n): unknown key \"\(k)\""
            }
        }
    }

    // shortcut: минимальный TOML-подмножество, менять, если конфиг вырастет за плоские строки
    public static func parse(_ toml: String) throws -> HangarConfig {
        var config = HangarConfig()
        var section = ""
        for (n, raw) in toml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError.syntax(line: n + 1, reason: "unterminated section header") }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw ParseError.syntax(line: n + 1, reason: "expected key = \"value\"") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
            if section.isEmpty, key == "notifications" || key == "limit_notifications" || key == "keep_awake" || key == "dock_badge" {
                let flag = try boolValue(rawValue, line: n + 1)
                switch key {
                case "notifications": config.notifications = flag
                case "limit_notifications": config.limitNotifications = flag
                case "dock_badge": config.dockBadge = flag
                default: config.keepAwake = flag
                }
                continue
            }
            let value = try stringValue(rawValue, line: n + 1)
            switch (section, key) {
            case ("", "default_agent"):
                guard let kind = LeafKind(rawValue: value), kind == .claude || kind == .codex else {
                    throw ParseError.unknownAgent(line: n + 1, name: value)
                }
                config.defaultAgent = kind
            case ("", "editor"):
                continue  // the Helix-era terminal editor (#81): ignored, so old configs still load
            case ("", "terminal_background"):
                guard let bg = TerminalBackground(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: "terminal_background must be \"hangar\" or \"theme\"")
                }
                config.terminalBackground = bg
            case ("", "language"):
                guard let lang = Language(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"language must be "system", "ru" or "en""#)
                }
                config.language = lang
            case ("", "external_editor"):
                config.externalEditor = value.isEmpty ? nil : value
            case ("agents", _):
                guard let kind = LeafKind(rawValue: key), kind == .claude || kind == .codex else {
                    throw ParseError.unknownAgent(line: n + 1, name: key)
                }
                config.agentCommands[kind] = value
            default:
                throw ParseError.unknownKey(line: n + 1, key: section.isEmpty ? key : "\(section).\(key)")
            }
        }
        return config
    }

    /// Missing file → (defaults, nil). Unreadable or invalid file → (defaults, "<file>: line N: reason").
    public static func load(from url: URL) -> (config: HangarConfig, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (HangarConfig(), nil) }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return (try parse(text), nil)
        } catch {
            return (HangarConfig(), "\(url.lastPathComponent): \(error)")
        }
    }

    /// Parses a bare `true` / `false` optionally followed by a `#` comment.
    private static func boolValue(_ s: Substring, line: Int) throws -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let word = t.prefix { $0 != " " && $0 != "\t" && $0 != "#" }
        let tail = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        guard word == "true" || word == "false", tail.isEmpty || tail.hasPrefix("#") else {
            throw ParseError.syntax(line: line, reason: "value must be true or false")
        }
        return word == "true"
    }

    /// Parses `"..."` (with `\"` and `\\` escapes) optionally followed by a `#` comment.
    private static func stringValue(_ s: Substring, line: Int) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\"") else { throw ParseError.syntax(line: line, reason: "value must be a quoted string") }
        var out = ""
        var escaped = false
        var rest = t.dropFirst()
        while let c = rest.first {
            rest = rest.dropFirst()
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" {
                let tail = rest.trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw ParseError.syntax(line: line, reason: "unexpected text after string") }
                return out
            } else { out.append(c) }
        }
        throw ParseError.syntax(line: line, reason: "unterminated string")
    }
}
