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

/// Parses one single-line TOML string starting at the opening quote in `chars[ci]`; leaves `ci` after the closing quote.
private func tomlString(_ chars: [Character], _ ci: inout Int, line: Int) throws(IntegrationError) -> String {
    let q = chars[ci]
    // shortcut: multi-line strings inside `notify` are not supported.
    if ci + 2 < chars.count, chars[ci + 1] == q, chars[ci + 2] == q { throw .unsupportedNotify }
    ci += 1
    var out = ""
    while true {
        guard ci < chars.count else { throw .invalidTOML(line: line) }
        let c = chars[ci]
        ci += 1
        if c == q { return out }
        guard q == "\"", c == "\\" else { out.append(c); continue }
        guard ci < chars.count else { throw .invalidTOML(line: line) }
        let e = chars[ci]
        ci += 1
        switch e {
        case "\"", "\\": out.append(e)
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "b": out.append("\u{8}")
        case "f": out.append("\u{c}")
        case "u", "U":
            let n = e == "u" ? 4 : 8
            guard ci + n <= chars.count, let v = UInt32(String(chars[ci..<ci + n]), radix: 16), let s = Unicode.Scalar(v) else { throw .invalidTOML(line: line) }
            out.unicodeScalars.append(s)
            ci += n
        default: throw .invalidTOML(line: line)
        }
    }
}

/// A root-level (before the first `[table]`) `key = ["…", '…']`; the array may span lines. `lines` are 0-based line indexes.
public func tomlRootStringArray(_ toml: String, key: String) throws(IntegrationError) -> (lines: Range<Int>, values: [String])? {
    let all = toml.components(separatedBy: "\n").map(stripped)
    var inMultiline: String?  // open `"""` / `'''` of another key; its lines may look like headers or keys
    for start in all.indices {
        let line = all[start]
        if let d = inMultiline {
            if line.components(separatedBy: d).count % 2 == 0 { inMultiline = nil }
            continue
        }
        let t = line.drop { $0 == " " || $0 == "\t" }
        if t.hasPrefix("[") { return nil }
        guard t.hasPrefix(key), case let rest = t.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" }), rest.hasPrefix("=") else {
            for d in ["\"\"\"", "'''"] where line.components(separatedBy: d).count % 2 == 0 { inMultiline = d }
            continue
        }
        var li = start
        var chars = Array(rest.dropFirst())
        var ci = 0
        func skipSpace() { while ci < chars.count, chars[ci] == " " || chars[ci] == "\t" { ci += 1 } }
        skipSpace()
        guard ci < chars.count, chars[ci] == "[" else { throw .unsupportedNotify }
        ci += 1
        var values: [String] = [], needComma = false
        while true {
            if ci >= chars.count {
                li += 1
                guard li < all.count else { throw .invalidTOML(line: start + 1) }
                chars = Array(all[li]); ci = 0
                continue
            }
            switch chars[ci] {
            case " ", "\t": ci += 1
            case "#": ci = chars.count
            case ",":
                guard needComma else { throw .invalidTOML(line: li + 1) }
                needComma = false; ci += 1
            case "]":
                ci += 1
                skipSpace()
                guard ci >= chars.count || chars[ci] == "#" else { throw .invalidTOML(line: li + 1) }
                return (start..<li + 1, values)
            case "\"", "'":
                guard !needComma else { throw .invalidTOML(line: li + 1) }
                values.append(try tomlString(chars, &ci, line: li + 1))
                needComma = true
            default: throw .unsupportedNotify
            }
        }
    }
    return nil
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
    if let found = try tomlRootStringArray(text, key: notifyKey) {
        let then = isHangarNotify(found.values) ? chained(found.values) : found.values
        let last = lines[found.lines.upperBound - 1].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(found.lines, with: [notifyLine(hangarValues(cli, then: then)) + last])
        return lines.joined(separator: "\n")
    }
    // New key goes after the last non-empty root line (before the first table), like HangarConfig.updating.
    let rootEnd = lines.firstIndex { stripped($0).drop { $0 == " " || $0 == "\t" }.hasPrefix("[") } ?? lines.count
    let after = (lines[..<rootEnd].lastIndex { !stripped($0).allSatisfy { $0 == " " || $0 == "\t" } }).map { $0 + 1 } ?? 0
    let line = notifyLine(hangarValues(cli, then: [])) + cr
    if after == lines.count - 1 && lines[after].isEmpty {
        lines.insert(line, at: after)  // file ends with a newline, no table: new line before the final empty element
    } else if after == lines.count {
        lines.append(line)  // shortcut: a root without trailing newline gets one, so uninstall will not restore the exact bytes
    } else {
        lines.insert(line, at: after)
    }
    return lines.joined(separator: "\n")
}

public func codexUninstall(_ toml: String) throws(IntegrationError) -> String {
    guard let found = try tomlRootStringArray(toml, key: notifyKey), isHangarNotify(found.values) else { return toml }
    var lines = toml.components(separatedBy: "\n")
    let then = chained(found.values)
    if then.isEmpty {
        lines.removeSubrange(found.lines)
    } else {
        let last = lines[found.lines.upperBound - 1].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(found.lines, with: [notifyLine(then) + last])
    }
    return lines.joined(separator: "\n")
}

public func codexState(_ toml: String?, cli: String) -> IntegrationState {
    guard let toml, let found = try? tomlRootStringArray(toml, key: notifyKey), isHangarNotify(found.values) else { return .notInstalled }
    return found.values[0] == cli ? .installed : .outdated
}
