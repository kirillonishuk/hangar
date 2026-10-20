import Foundation

extension HangarConfig {
    // shortcut: line-based edit of flat root keys only; replace with a real TOML writer if the config grows nested tables
    /// Sets root key `key = "value"`, touching only that line (its trailing comment is kept). A missing key is
    /// added after the last non-blank line of the root section, i.e. before the first `[section]`.
    public static func updating(_ text: String, key: String, value: String) -> String {
        updating(text, key: key, literal: "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"")
    }

    /// Like the string variant, but `literal` is written as is (a bare `true` / `false`).
    public static func updating(_ text: String, key: String, literal: String) -> String {
        // Lines keep their own "\r" (CRLF files); edited and inserted lines get the file's ending.
        var lines = text.components(separatedBy: "\n")
        let cr = text.contains("\r\n") ? "\r" : ""
        let assignment = "\(key) = \(literal)"
        var lastRootLine: Int?
        for (i, raw) in lines.enumerated() {
            let ending = raw.hasSuffix("\r") ? "\r" : ""
            let line = (ending.isEmpty ? Substring(raw) : raw.dropLast()).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.isEmpty { continue }
            lastRootLine = i
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            lines[i] = assignment + trailingComment(line[line.index(after: eq)...]) + ending
            return lines.joined(separator: "\n")
        }
        let at = lastRootLine.map { $0 + 1 } ?? 0
        // Appending after a last line that has no terminator: give it the file's ending first.
        if at > 0, !cr.isEmpty, !lines[at - 1].hasSuffix("\r") { lines[at - 1] += cr }
        lines.insert(assignment + (at < lines.count ? cr : ""), at: at)
        return lines.joined(separator: "\n")
    }

    /// Edits (or creates) the config file, writing atomically; a symlinked config keeps its link.
    public static func save(key: String, value: String, to url: URL) throws {
        try save(to: url) { updating($0, key: key, value: value) }
    }

    /// Same, for a bare literal (`true` / `false`).
    public static func save(key: String, literal: String, to url: URL) throws {
        try save(to: url) { updating($0, key: key, literal: literal) }
    }

    private static func save(to url: URL, edit: (String) -> String) throws {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let text = fm.fileExists(atPath: target.path) ? try String(contentsOf: target, encoding: .utf8) : ""
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(edit(text).utf8).write(to: target, options: .atomic)
    }

    /// The `   # comment` (with its leading spaces) after the old value, or "". A `#` inside a `"..."` (escapes)
    /// or `'...'` value is part of the value; an unquoted value ends at the first `#`.
    private static func trailingComment(_ s: Substring) -> String {
        var rest = s.drop { $0 == " " || $0 == "\t" }
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            var escaped = false
            while let c = rest.first {
                rest = rest.dropFirst()
                if escaped { escaped = false } else if quote == "\"", c == "\\" { escaped = true } else if c == quote { break }
            }
        } else {
            guard let hash = rest.firstIndex(of: "#") else { return "" }
            rest = rest[hash...]
            let value = s.drop { $0 == " " || $0 == "\t" }
            let spaces = value[..<hash].reversed().prefix { $0 == " " || $0 == "\t" }
            return String(spaces.reversed()) + rest
        }
        return rest.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? String(rest) : ""
    }
}
