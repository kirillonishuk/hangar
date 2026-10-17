import Foundation

public struct HangarConfig: Equatable, Sendable {
    public var defaultAgent: LeafKind = .claude
    public var editor: String = "hx"
    public var agentCommands: [LeafKind: String] = [.claude: "claude", .codex: "codex"]

    public init() {}

    public enum ParseError: Error, Equatable {
        case syntax(line: Int)
        case unknownAgent(String)
        case unknownKey(String)
    }

    // shortcut: минимальный TOML-подмножество, менять, если конфиг вырастет за плоские строки
    public static func parse(_ toml: String) throws -> HangarConfig {
        var config = HangarConfig()
        var section = ""
        for (n, raw) in toml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError.syntax(line: n + 1) }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw ParseError.syntax(line: n + 1) }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = try stringValue(line[line.index(after: eq)...], line: n + 1)
            switch (section, key) {
            case ("", "default_agent"):
                guard let kind = LeafKind(rawValue: value), kind == .claude || kind == .codex else {
                    throw ParseError.unknownAgent(value)
                }
                config.defaultAgent = kind
            case ("", "editor"):
                config.editor = value
            case ("agents", _):
                guard let kind = LeafKind(rawValue: key), kind == .claude || kind == .codex else {
                    throw ParseError.unknownAgent(key)
                }
                config.agentCommands[kind] = value
            default:
                throw ParseError.unknownKey(section.isEmpty ? key : "\(section).\(key)")
            }
        }
        return config
    }

    /// Missing or unreadable/invalid file → defaults.
    public static func load(from url: URL) -> HangarConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let config = try? parse(text) else { return HangarConfig() }
        return config
    }

    /// Parses `"..."` (with `\"` and `\\` escapes) optionally followed by a `#` comment.
    private static func stringValue(_ s: Substring, line: Int) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\"") else { throw ParseError.syntax(line: line) }
        var out = ""
        var escaped = false
        var rest = t.dropFirst()
        while let c = rest.first {
            rest = rest.dropFirst()
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" {
                let tail = rest.trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw ParseError.syntax(line: line) }
                return out
            } else { out.append(c) }
        }
        throw ParseError.syntax(line: line)
    }
}
