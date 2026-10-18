import Foundation

extension HangarConfig {
    // shortcut: line-based edit of flat root keys only; replace with a real TOML writer if the config grows nested tables
    /// Sets root key `key = "value"`, touching only that line (its trailing comment is kept). A missing key is
    /// added after the last non-blank line of the root section, i.e. before the first `[section]`.
    public static func updating(_ text: String, key: String, value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let assignment = "\(key) = \"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        var lastRootLine: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.isEmpty { continue }
            lastRootLine = i
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            lines[i] = assignment + trailingComment(line[line.index(after: eq)...])
            return lines.joined(separator: "\n")
        }
        lines.insert(assignment, at: lastRootLine.map { $0 + 1 } ?? 0)
        return lines.joined(separator: "\n")
    }

    /// Edits (or creates) the config file, writing atomically; a symlinked config keeps its link.
    public static func save(key: String, value: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let text = fm.fileExists(atPath: target.path) ? try String(contentsOf: target, encoding: .utf8) : ""
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updating(text, key: key, value: value).utf8).write(to: target, options: .atomic)
    }

    /// `   # comment` after the closing quote of a `"..."` value (with its leading spaces), or "".
    private static func trailingComment(_ s: Substring) -> String {
        var rest = s.drop { $0 == " " || $0 == "\t" }
        guard rest.first == "\"" else { return "" }
        rest = rest.dropFirst()
        var escaped = false
        while let c = rest.first {
            rest = rest.dropFirst()
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
        }
        return rest.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? String(rest) : ""
    }
}
