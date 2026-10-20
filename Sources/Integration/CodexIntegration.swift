import Foundation

// verify: проверить, когда codex будет установлен — `notify` в ~/.codex/config.toml (массив argv, JSON-payload добавляется последним аргументом).

private let notifyKey = "notify"

/// Line `i` without its `\r`; line endings themselves are never rewritten.
private func stripped(_ s: String) -> String { s.hasSuffix("\r") ? String(s.dropLast()) : s }

private func tomlQuoted(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        case _ where u.value < 0x20 || u.value == 0x7F: out += String(format: "\\u%04X", u.value)
        default: out.unicodeScalars.append(u)
        }
    }
    return out + "\""
}

/// One walk over the file for every root-level decision (where a key lives, where the root ends).
/// It tracks basic/literal/multi-line strings, comments and bracket/brace depth, so nothing inside a value is mistaken for a table header.
/// Anything it does not understand is refused (`.unsupportedNotify`): the user's file is then left untouched.
private struct TOMLScanner {
    struct Statement {
        var name: String?  // bare, undotted key; nil for other keys
        var lines: Range<Int>
        var value: Range<Int>  // scalar offsets of the value, without trailing comment
        var comment: String  // text after the value on its last line (spaces and `# …`), "" if only blanks
    }

    let s: [Unicode.Scalar]
    init(_ text: String) { s = Array(text.unicodeScalars) }

    func line(_ off: Int) -> Int { s[..<min(off, s.count)].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } }

    /// Root statements and the index of the first line that is a real table header (or the line count).
    func root() throws(IntegrationError) -> (statements: [Statement], rootEndLine: Int) {
        var out: [Statement] = []
        var i = 0
        let total = line(s.count) + 1
        while true {
            while i < s.count, " \t\r\n".unicodeScalars.contains(s[i]) || s[i] == "#" {
                if s[i] == "#" { while i < s.count, s[i] != "\n" { i += 1 } } else { i += 1 }
            }
            guard i < s.count else { return (out, total) }
            if s[i] == "[" { return (out, line(i)) }
            let start = i
            var parts: [(text: String, quoted: Bool)] = [], dotted = false
            while true {
                while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
                guard i < s.count else { throw .unsupportedNotify }
                if s[i] == "\"" || s[i] == "'" {
                    let (text, end) = try quotedSingleLine(i)
                    parts.append((text, true)); i = end
                } else {
                    let b = i
                    while i < s.count, bare(s[i]) { i += 1 }
                    guard i > b else { throw .unsupportedNotify }
                    parts.append((String(String.UnicodeScalarView(s[b..<i])), false))
                }
                while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
                if i < s.count, s[i] == "." { dotted = true; i += 1; continue }
                break
            }
            guard i < s.count, s[i] == "=" else { throw .unsupportedNotify }
            if parts[0].text == "notify", dotted || parts[0].quoted { throw .unsupportedNotify }
            i += 1
            let vStart = i
            let (vEnd, lineEnd) = try skipValue(from: i, statementLine: line(start))
            var v = vStart
            while v < vEnd, " \t".unicodeScalars.contains(s[v]) { v += 1 }
            let tail = String(String.UnicodeScalarView(s[vEnd..<lineEnd])).replacingOccurrences(of: "\r", with: "")
            out.append(Statement(name: parts.count == 1 && !dotted && !parts[0].quoted ? parts[0].text : nil,
                                 lines: line(start)..<line(max(vEnd - 1, start)) + 1, value: v..<vEnd,
                                 comment: tail.contains("#") ? tail : ""))
            i = lineEnd
        }
    }

    private func bare(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) || c == "_" || c == "-"
    }

    /// Single-line `"…"` / `'…'` at `i`; returns the decoded text and the offset after the closing quote.
    func quotedSingleLine(_ i: Int) throws(IntegrationError) -> (String, Int) {
        let q = s[i]
        // shortcut: a multi-line string element is refused, not parsed.
        if i + 2 < s.count, s[i + 1] == q, s[i + 2] == q { throw .unsupportedNotify }
        var k = i + 1
        var out = String.UnicodeScalarView()
        while true {
            guard k < s.count, s[k] != "\n" else { throw .invalidTOML(line: line(i) + 1) }
            let c = s[k]
            k += 1
            if c == q { return (String(out), k) }
            guard q == "\"", c == "\\" else { out.append(c); continue }
            guard k < s.count else { throw .invalidTOML(line: line(i) + 1) }
            let e = s[k]
            k += 1
            switch e {
            case "\"", "\\": out.append(e)
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{c}")
            case "u", "U":
                let n = e == "u" ? 4 : 8
                guard k + n <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[k..<k + n])), radix: 16), let u = Unicode.Scalar(v) else {
                    throw .invalidTOML(line: line(i) + 1)
                }
                out.append(u)
                k += n
            default: throw .invalidTOML(line: line(i) + 1)
            }
        }
    }

    /// Walks a value; returns the offset after its last significant scalar and the offset of the line's end (`\n` or EOF).
    private func skipValue(from: Int, statementLine: Int) throws(IntegrationError) -> (end: Int, lineEnd: Int) {
        var i = from, depth = 0, last = from
        while i < s.count {
            let c = s[i]
            switch c {
            case "\n":
                if depth == 0 { return (last, i) }
                i += 1
            case "#":
                while i < s.count, s[i] != "\n" { i += 1 }
            case "\"", "'":
                if i + 2 < s.count, s[i + 1] == c, s[i + 2] == c {
                    var k = i + 3
                    while true {
                        guard k < s.count else { throw .invalidTOML(line: statementLine + 1) }
                        if c == "\"", s[k] == "\\" { k += 2; continue }
                        if k + 2 < s.count, s[k] == c, s[k + 1] == c, s[k + 2] == c {
                            k += 3
                            var extra = 0
                            while extra < 2, k < s.count, s[k] == c { k += 1; extra += 1 }
                            break
                        }
                        k += 1
                    }
                    i = k
                } else {
                    i = try quotedSingleLine(i).1
                }
                last = i
            case "[", "{": depth += 1; i += 1; last = i
            case "]", "}":
                depth -= 1
                guard depth >= 0 else { throw .unsupportedNotify }
                i += 1; last = i
            case " ", "\t", "\r": i += 1
            default: i += 1; last = i
            }
        }
        guard depth == 0 else { throw .invalidTOML(line: statementLine + 1) }
        return (last, s.count)
    }

    /// Strict `["…", '…']`, possibly over several lines. A comment inside is refused so it is never dropped on rewrite.
    func stringArray(_ r: Range<Int>) throws(IntegrationError) -> [String] {
        var i = r.lowerBound
        guard i < r.upperBound, s[i] == "[" else { throw .unsupportedNotify }
        i += 1
        var values: [String] = [], needComma = false
        while i < r.upperBound {
            switch s[i] {
            case " ", "\t", "\r", "\n": i += 1
            case "#": throw .unsupportedNotify
            case ",":
                guard needComma else { throw .invalidTOML(line: line(i) + 1) }
                needComma = false; i += 1
            case "]":
                guard i + 1 == r.upperBound else { throw .invalidTOML(line: line(i) + 1) }
                return values
            case "\"", "'":
                guard !needComma else { throw .invalidTOML(line: line(i) + 1) }
                let (v, end) = try quotedSingleLine(i)
                values.append(v); i = end; needComma = true
            default: throw .unsupportedNotify
            }
        }
        throw .invalidTOML(line: line(r.lowerBound) + 1)
    }
}

private struct NotifyEntry {
    var lines: Range<Int>
    var values: [String]
    var comment: String
}

private func scanNotify(_ toml: String, key: String) throws(IntegrationError) -> (entry: NotifyEntry?, rootEndLine: Int) {
    let sc = TOMLScanner(toml)
    let (statements, rootEnd) = try sc.root()
    let hits = statements.filter { $0.name == key }
    guard hits.count <= 1 else { throw .unsupportedNotify }  // duplicate key is invalid TOML: do not guess
    guard let h = hits.first else { return (nil, rootEnd) }
    return (NotifyEntry(lines: h.lines, values: try sc.stringArray(h.value), comment: h.comment), rootEnd)
}

/// A root-level (before the first `[table]`) `key = ["…", '…']`; the array may span lines. `lines` are 0-based line indexes.
public func tomlRootStringArray(_ toml: String, key: String) throws(IntegrationError) -> (lines: Range<Int>, values: [String])? {
    try scanNotify(toml, key: key).entry.map { ($0.lines, $0.values) }
}

private func isHangarNotify(_ v: [String]) -> Bool {
    v.count >= 3 && (v[0] == "hangar" || v[0].hasSuffix("/hangar")) && v[1] == "event" && v[2] == "codex-notify"
}

/// Original notify argv Hangar wraps (after `--then`); empty when Hangar has nothing to chain.
private func chained(_ v: [String]) -> [String] { v.count > 4 && v[3] == "--then" ? Array(v[4...]) : [] }

private func notifyLine(_ values: [String]) -> String { "\(notifyKey) = [" + values.map(tomlQuoted).joined(separator: ", ") + "]" }

private func hangarValues(_ cli: String, then: [String]) -> [String] {
    [cli, "event", "codex-notify"] + (then.isEmpty ? [] : ["--then"] + then)
}

public func codexInstall(_ toml: String?, cli: String) throws(IntegrationError) -> String {
    let text = toml ?? ""
    var lines = text.components(separatedBy: "\n")
    let cr = text.contains("\r\n") ? "\r" : ""
    let (entry, rootEnd) = try scanNotify(text, key: notifyKey)
    if let found = entry {
        let then = isHangarNotify(found.values) ? chained(found.values) : found.values
        let last = lines[found.lines.upperBound - 1].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(found.lines, with: [notifyLine(hangarValues(cli, then: then)) + found.comment + last])
        return lines.joined(separator: "\n")
    }
    // New key goes after the last non-empty root line (before the first table), like HangarConfig.updating.
    let end = min(rootEnd, lines.count)
    let after = (lines[..<end].lastIndex { !stripped($0).allSatisfy { $0 == " " || $0 == "\t" } }).map { $0 + 1 } ?? 0
    let line = notifyLine(hangarValues(cli, then: [])) + cr
    if after == lines.count {
        lines.append(line)  // shortcut: a root without trailing newline gets one, so uninstall will not restore the exact bytes
    } else {
        lines.insert(line, at: after)
    }
    return lines.joined(separator: "\n")
}

public func codexUninstall(_ toml: String) throws(IntegrationError) -> String {
    guard let found = try scanNotify(toml, key: notifyKey).entry, isHangarNotify(found.values) else { return toml }
    var lines = toml.components(separatedBy: "\n")
    let then = chained(found.values)
    if then.isEmpty {
        lines.removeSubrange(found.lines)
    } else {
        let last = lines[found.lines.upperBound - 1].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(found.lines, with: [notifyLine(then) + found.comment + last])
    }
    return lines.joined(separator: "\n")
}

public func codexState(_ toml: String?, cli: String) -> IntegrationState {
    guard let toml, let found = (try? scanNotify(toml, key: notifyKey))?.entry, isHangarNotify(found.values) else { return .notInstalled }
    return found.values[0] == cli ? .installed : .outdated
}
