import Foundation

/// UI language setting; `system` resolves to ru when the first system language is Russian, else en.
public enum Language: String, Sendable, CaseIterable { case system, ru, en }

/// App colour theme (themes-v1.html): `theme = "dark-plus" | "graphite" | "navy"`.
public enum AppTheme: String, Sendable, CaseIterable { case darkPlus = "dark-plus", graphite, navy }

public struct HangarConfig: Equatable, Sendable {
    public var defaultAgent: LeafKind = .claude
    public var agentCommands: [LeafKind: String] = [.claude: "claude", .codex: "codex"]
    public var terminalBackground: TerminalBackground = .hangar
    /// Dark+ for new installs and existing configs alike (the user's choice).
    public var theme: AppTheme = .darkPlus
    public var language: Language = .system
    /// Command opening files outside Hangar (e.g. `zed`); nil = off.
    public var externalEditor: String?
    /// macOS notifications when an agent waits or finishes in a leaf that isn't on screen.
    public var notifications = true
    /// Notifications for subscription-limit thresholds (Task 11).
    public var limitNotifications = true
    /// Per-reason banners (limit uses `limitNotifications`).
    public var notifyPermission = true
    public var notifyQuestion = true
    public var notifyDone = true
    public var notifyFailed = true
    /// Sound per attention reason (key = AttentionReason.rawValue; Workspace doesn't import AgentStatus):
    /// "" = silent, "default" = standard, otherwise a /System/Library/Sounds name without extension.
    public var sounds: [String: String] = ["permission": "default", "question": "default", "done": "", "failed": "default", "limit": "default"]
    /// Banners even when Hangar is frontmost and the session is on screen.
    public var notifyWhenActive = true
    /// Allow answering a permission request from the notification.
    public var allowFromNotification = false
    /// Forward the terminal bell from ssh sessions as a notification.
    public var sshTerminalBell = false
    /// Hold a sleep assertion while agents work (spec §5.2).
    public var keepAwake = true
    /// Dock badge with the number of leaves needing the user (permission, question, failed), and a Dock bounce on a new request out of focus.
    public var dockBadge = true
    /// The editor theme (#84, #108): VS Code Dark Modern (default, also for configs that never chose one), Dark+,
    /// Hangar's muted palette or «Своя» (a built-in `editorCustomBase` plus `editorColors`); rainbow indents and TODO pills.
    public var editorPalette: EditorPalette = .darkModern
    public var editorCustomBase: EditorPalette = .darkModern
    /// «Своя»'s changed colors only (`#rrggbb` / `#rrggbbaa`, lower case).
    public var editorColors: [EditorColor: String] = [:]
    public var editorOptions = EditorOptions()
    public var editorRainbowIndent = true
    public var editorTodoHighlight = true
    /// Look for a new GitHub release on launch and on activation, at most hourly (#86).
    public var checkUpdates = true
    /// Claude Code's status line (#105): Hangar's own line everywhere, or the user's original command.
    public var statusline: StatuslineMode = .hangar
    /// The segments of Hangar's line, in the order shown; unknown and repeated names in the file are skipped.
    public var statuslineSegments: [StatuslineSegment] = StatuslineSegment.defaults
    /// Settings' row of chips, the off ones too (`statusline_order`, #110): every segment once, missing ones appended.
    public var statuslineOrder: [StatuslineSegment] = StatuslineSegment.allCases

    /// The chips as Settings shows them: `statuslineOrder`'s slots, the on ones refilled in `statuslineSegments`' order,
    /// so a hand-edited `statusline_segments` wins and the off chips keep their places.
    public var statuslineChips: [StatuslineSegment] {
        var on = statuslineSegments.makeIterator()
        return statuslineOrder.map { statuslineSegments.contains($0) ? on.next() ?? $0 : $0 }
    }

    /// `hangar`: the Hangar theme's background wins over the user's Ghostty config (#36); `ghostty`: Ghostty's own.
    public enum TerminalBackground: String, Sendable { case hangar, ghostty }
    public enum EditorPalette: String, Sendable, CaseIterable { case darkModern = "dark-modern", darkPlus = "dark-plus", hangar, custom }

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
            let flags = ["notifications", "limit_notifications", "keep_awake", "dock_badge", "editor_rainbow_indent", "editor_todo_highlight", "check_updates",
                         "notify_permission", "notify_question", "notify_done", "notify_failed", "notify_when_active", "allow_from_notification", "ssh_terminal_bell"]
            if section.isEmpty, flags.contains(key) {
                let flag = try boolValue(rawValue, line: n + 1)
                switch key {
                case "notifications": config.notifications = flag
                case "limit_notifications": config.limitNotifications = flag
                case "dock_badge": config.dockBadge = flag
                case "editor_rainbow_indent": config.editorRainbowIndent = flag
                case "editor_todo_highlight": config.editorTodoHighlight = flag
                case "check_updates": config.checkUpdates = flag
                case "notify_permission": config.notifyPermission = flag
                case "notify_question": config.notifyQuestion = flag
                case "notify_done": config.notifyDone = flag
                case "notify_failed": config.notifyFailed = flag
                case "notify_when_active": config.notifyWhenActive = flag
                case "allow_from_notification": config.allowFromNotification = flag
                case "ssh_terminal_bell": config.sshTerminalBell = flag
                default: config.keepAwake = flag
                }
                continue
            }
            if section.isEmpty, key == "statusline_segments" {
                config.statuslineSegments = StatuslineSegment.list(try stringArray(rawValue, line: n + 1))
                continue
            }
            if section.isEmpty, key == "statusline_order" {
                let order = StatuslineSegment.list(try stringArray(rawValue, line: n + 1))
                config.statuslineOrder = order + StatuslineSegment.allCases.filter { !order.contains($0) }
                continue
            }
            if section.isEmpty, try parseEditorKey(key, rawValue, line: n + 1, into: &config) { continue }
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
                // Before the themes `"theme"` meant the Ghostty theme's background: read as `ghostty`, rewritten on save.
                guard let bg = value == "theme" ? .ghostty : TerminalBackground(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"terminal_background must be "hangar" or "ghostty""#)
                }
                config.terminalBackground = bg
            case ("", "theme"):
                guard let theme = AppTheme(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"theme must be "dark-plus", "graphite" or "navy""#)
                }
                config.theme = theme
            case ("", "editor_palette"):
                guard let palette = EditorPalette(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"editor_palette must be "dark-modern", "dark-plus", "hangar" or "custom""#)
                }
                config.editorPalette = palette
            case ("", "language"):
                guard let lang = Language(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"language must be "system", "ru" or "en""#)
                }
                config.language = lang
            case ("", "statusline"):
                guard let mode = StatuslineMode(rawValue: value) else {
                    throw ParseError.syntax(line: n + 1, reason: #"statusline must be "hangar" or "user""#)
                }
                config.statusline = mode
            case ("", "external_editor"):
                config.externalEditor = value.isEmpty ? nil : value
            case ("", "sound_permission"), ("", "sound_question"), ("", "sound_done"), ("", "sound_failed"), ("", "sound_limit"):
                config.sounds[String(key.dropFirst("sound_".count))] = value  // unknown names kept; the UI treats them as default
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
    static func boolValue(_ s: Substring, line: Int) throws -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let word = t.prefix { $0 != " " && $0 != "\t" && $0 != "#" }
        let tail = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        guard word == "true" || word == "false", tail.isEmpty || tail.hasPrefix("#") else {
            throw ParseError.syntax(line: line, reason: "value must be true or false")
        }
        return word == "true"
    }

    /// Parses a one-line `["a", "b"]` of strings optionally followed by a `#` comment.
    private static func stringArray(_ s: Substring, line: Int) throws -> [String] {
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        guard rest.hasPrefix("[") else { throw ParseError.syntax(line: line, reason: "value must be an array of strings") }
        rest = rest.dropFirst()
        var out: [String] = []
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.hasPrefix("]") {
                let tail = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw ParseError.syntax(line: line, reason: "unexpected text after array") }
                return out
            }
            guard rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(where: { $0 == "\"" || $0 == "\\" }), rest[end] == "\"" else {
                throw ParseError.syntax(line: line, reason: "array items must be plain quoted strings")
            }
            out.append(String(rest[rest.index(after: rest.startIndex)..<end]))
            rest = rest[rest.index(after: end)...].drop { $0 == " " || $0 == "\t" }
            if rest.hasPrefix(",") { rest = rest.dropFirst() } else if !rest.hasPrefix("]") {
                throw ParseError.syntax(line: line, reason: "expected , or ] in array")
            }
        }
    }

    /// Parses `"..."` (with `\"` and `\\` escapes) optionally followed by a `#` comment.
    static func stringValue(_ s: Substring, line: Int) throws -> String {
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
