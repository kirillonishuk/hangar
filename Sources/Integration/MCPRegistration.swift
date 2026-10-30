import Exec
import Foundation

/// Hangar's MCP server in an agent's user config (#111), as read from the agent's own file (never `claude mcp get`:
/// it starts the server to test it).
public enum MCPEntry: Equatable, Sendable {
    case absent
    /// Hangar's, with the current helper path.
    case current
    /// Hangar's, with an older helper path (the app moved): re-registered.
    case stale
    /// Hangar's, of another copy of the app that keeps it (`localOwnership`): left alone.
    case otherCopy
    /// Something else named `hangar`: never touched.
    case foreign
    /// The file can't be read: nothing is decided.
    case unreadable
}

public enum MCPAgent: String, Sendable { case claude, codex }

/// What the launch (or a Settings toggle) does with the entry.
public enum MCPAction: Equatable, Sendable { case none, add, readd, remove }

/// `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json` when that is set (absolute).
public func claudeJSONPath(home: URL, claudeConfigDir: String?) -> URL {
    if let v = claudeConfigDir {
        let p = (v as NSString).expandingTildeInPath
        if p.hasPrefix("/") { return URL(fileURLWithPath: p).appendingPathComponent(".claude.json") }
    }
    return home.appendingPathComponent(".claude.json")
}

/// Hangar's entry is `<…>/Contents/Helpers/hangar mcp` with no env; whose copy it is decides `ours`.
private func classify(command: String?, args: [String]?, envEmpty: Bool, cli: String, ours: (String) -> Bool) -> MCPEntry {
    guard let command, command.hasSuffix("/Contents/Helpers/hangar"), args == ["mcp"], envEmpty else { return .foreign }
    if command == cli { return .current }
    return ours(command) ? .stale : .otherCopy
}

/// `mcpServers.hangar` of Claude's `.claude.json` (user scope). Project-scope entries are the user's choice and not read.
public func claudeMCPEntry(_ text: String?, cli: String, ours: (String) -> Bool) -> MCPEntry {
    guard let text else { return .absent }
    guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .unreadable }
    guard let servers = root["mcpServers"] else { return .absent }
    guard let dict = servers as? [String: Any] else { return .unreadable }
    guard let entry = dict["hangar"] else { return .absent }
    guard let e = entry as? [String: Any] else { return .foreign }
    if let type = e["type"] as? String, type != "stdio" { return .foreign }
    let env = e["env"].map { ($0 as? [String: Any])?.isEmpty == true } ?? true
    return classify(command: e["command"] as? String, args: e["args"] as? [String], envEmpty: env, cli: cli, ours: ours)
}

/// `[mcp_servers.hangar]` of Codex's `config.toml` (a table, an inline table under `[mcp_servers]`, or dotted keys).
public func codexMCPEntry(_ toml: String?, cli: String, ours: (String) -> Bool) -> MCPEntry {
    guard let toml else { return .absent }
    guard let f = codexHangarServer(toml) else { return .unreadable }
    guard f.found else { return .absent }
    return f.extra ? .foreign : classify(command: f.command, args: f.args, envEmpty: f.envEmpty, cli: cli, ours: ours)
}

public func mcpAction(_ entry: MCPEntry, enabled: Bool) -> MCPAction {
    switch (entry, enabled) {
    case (.absent, true): .add
    case (.stale, true): .readd
    case (.current, false), (.stale, false): .remove
    default: .none
    }
}

/// The agent CLI's own commands for `action` (Hangar never edits these files itself). Claude refuses a second `add`
/// of a name, so a new path is `remove` + `add`; Codex's `add` replaces the entry.
public func mcpCommands(_ agent: MCPAgent, _ action: MCPAction, agentCLI: String, cli: String) -> [[String]] {
    let add: [String], remove: [String]
    switch agent {
    case .claude:
        add = [agentCLI, "mcp", "add", "--scope", "user", "hangar", "--", cli, "mcp"]
        remove = [agentCLI, "mcp", "remove", "--scope", "user", "hangar"]
    case .codex:
        add = [agentCLI, "mcp", "add", "hangar", "--", cli, "mcp"]
        remove = [agentCLI, "mcp", "remove", "hangar"]
    }
    switch action {
    case .none: return []
    case .add: return [add]
    case .readd: return agent == .claude ? [remove, add] : [add]
    case .remove: return [remove]
    }
}

/// An executable's path as the user's login shell finds it (`command -v`), like `resolveCodex`; nil = not there.
public func resolveCommand(_ name: String, runner: Runner, shell: String) async -> String? {
    guard let r = try? await runner.run([shell, "-l", "-i", "-c", "command -v \(shellQuote(name))"], NSHomeDirectory()), r.status == 0 else { return nil }
    return commandPath(r.stdout)
}

/// The path in `command -v` output: a plain path, or the target of `alias name='/path/…'` (zsh prints `name=…`).
/// An alias to anything but an absolute path (`npx …`) is no executable to run: nil.
func commandPath(_ output: String) -> String? {
    guard let line = output.split(whereSeparator: \.isNewline).map(String.init).last(where: { !$0.isEmpty }) else { return nil }
    if line.hasPrefix("/") { return line }
    guard let eq = line.firstIndex(of: "="), let words = shellWords(String(line[line.index(after: eq)...])),
          words.count == 1, words[0].hasPrefix("/") else { return nil }
    return words[0]
}

/// Runs argv through the login shell: its PATH (node for `claude`) and `CLAUDE_CONFIG_DIR` / `CODEX_HOME`.
public func loginShellArgv(_ argv: [String], shell: String) -> [String] {
    [shell, "-l", "-i", "-c", "exec \"$@\"", "hangar"] + argv
}

// MARK: Reading Codex's TOML

private struct HangarServer {
    var found = false, command: String?, args: [String]?, envEmpty = true
    /// A key Hangar never writes (`enabled`, `cwd`, timeouts…): someone else's entry, or ours edited by hand.
    var extra = false
}

private enum Lite { case string(String), strings([String]), table([(String, Lite)]), other }

/// nil = something it can't follow (an unclosed string or bracket): then nothing is decided.
private func codexHangarServer(_ toml: String) -> HangarServer? {
    var out = HangarServer()
    var table: [String] = []
    var lines = toml.components(separatedBy: "\n")[...]
    while let raw = lines.popFirst() {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("[") {
            line = withoutComment(line)
            let array = line.hasPrefix("[[")
            guard let close = line.range(of: array ? "]]" : "]", options: .backwards),
                  let path = keyPath(line[line.index(line.startIndex, offsetBy: array ? 2 : 1)..<close.lowerBound]) else { return nil }
            table = array ? ["[["] + path : path
            if table.starts(with: ["mcp_servers", "hangar"]) { out.found = true }
            continue
        }
        guard let eq = equalsIndex(line), let key = keyPath(line[..<eq]) else { return nil }
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        // A value over several lines: a multi-line string or an open array / inline table.
        while true {
            let (open, multi) = openness(value)
            if open == 0 && !multi { break }
            guard let next = lines.popFirst() else { return nil }
            value += "\n" + next
        }
        let full = table + key
        guard full.starts(with: ["mcp_servers", "hangar"]) else { continue }
        out.found = true
        let parsed = lite(Substring(value))
        switch full.count {
        case 2: if case .table(let members) = parsed { apply(members, to: &out) } else { out.command = nil; out.args = nil; out.envEmpty = false }
        case 3: apply([(full[2], parsed)], to: &out)
        default: if full[2] == "env" { out.envEmpty = false } else { out.extra = true }
        }
    }
    return out
}

private func apply(_ members: [(String, Lite)], to out: inout HangarServer) {
    for (k, v) in members {
        switch (k, v) {
        case ("command", .string(let s)): out.command = s
        case ("args", .strings(let a)): out.args = a
        case ("env", .table(let t)): out.envEmpty = t.isEmpty
        case ("env", _): out.envEmpty = false
        case ("command", _), ("args", _): out.command = nil; out.args = nil
        default: out.extra = true
        }
    }
}

/// A header line without its trailing `# comment` (a `#` inside a quoted key stays).
private func withoutComment(_ s: String) -> String {
    var quote: Character?
    for i in s.indices {
        let c = s[i]
        if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == "#" {
            return s[..<i].trimmingCharacters(in: .whitespaces)
        }
    }
    return s
}

/// `a.b."c d"` → ["a", "b", "c d"]; nil for a malformed key.
private func keyPath(_ s: Substring) -> [String]? {
    var parts: [String] = [], cur = "", quote: Character?, any = false
    for c in s {
        if let q = quote {
            if c == q { quote = nil } else { cur.append(c) }
        } else if c == "\"" || c == "'" {
            quote = c; any = true
        } else if c == "." {
            guard any else { return nil }
            parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; any = false
        } else if c == " " || c == "\t" {
            continue
        } else {
            cur.append(c); any = true
        }
    }
    guard quote == nil, any else { return nil }
    parts.append(cur)
    return parts
}

/// The `=` of `key = value`, outside a quoted key.
private func equalsIndex(_ s: String) -> String.Index? {
    var quote: Character?
    for i in s.indices {
        let c = s[i]
        if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == "=" { return i }
    }
    return nil
}

/// Bracket depth left open and whether a `"""` / `'''` string is still open at the end of `s`.
private func openness(_ s: String) -> (Int, Bool) {
    let c = Array(s)
    var i = 0, depth = 0
    while i < c.count {
        let ch = c[i]
        if ch == "#" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
        if ch == "\"" || ch == "'" {
            if i + 2 < c.count, c[i + 1] == ch, c[i + 2] == ch {
                i += 3
                while i + 2 < c.count, !(c[i] == ch && c[i + 1] == ch && c[i + 2] == ch) { i += ch == "\"" && c[i] == "\\" ? 2 : 1 }
                if i + 2 >= c.count { return (depth, true) }
                i += 3; continue
            }
            i += 1
            while i < c.count, c[i] != ch, c[i] != "\n" { i += ch == "\"" && c[i] == "\\" ? 2 : 1 }
            i += 1; continue
        }
        if ch == "[" || ch == "{" { depth += 1 }
        if ch == "]" || ch == "}" { depth -= 1 }
        i += 1
    }
    return (depth, false)
}

/// A value Hangar's entry may hold: a single-line string, an array of them, an inline table of those; else `.other`.
private func lite(_ v: Substring) -> Lite {
    var s = v.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    if s.hasPrefix("\"") || s.hasPrefix("'") {
        guard let (text, end) = quoted(s) else { return .other }
        let tail = s[end...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty || tail.hasPrefix("#") ? .string(text) : .other
    }
    if s.hasPrefix("[") {
        s = s.dropFirst()
        var items: [String] = []
        while true {
            s = s.drop { separators.contains($0) }
            if s.hasPrefix("]") { return .strings(items) }
            if s.hasPrefix("#") { s = s.drop { $0 != "\n" }; continue }
            guard let (text, end) = quoted(s) else { return .other }
            items.append(text)
            s = s[end...]
        }
    }
    if s.hasPrefix("{") {
        s = s.dropFirst()
        var members: [(String, Lite)] = []
        while true {
            s = s.drop { separators.contains($0) }
            if s.hasPrefix("}") { return .table(members) }
            let rest = String(s)
            guard let eq = equalsIndex(rest), let key = keyPath(rest[..<eq]), key.count == 1 else { return .other }
            s = rest[rest.index(after: eq)...].drop { $0 == " " || $0 == "\t" }
            let end = valueEnd(s)
            members.append((key[0], lite(s[..<end])))
            s = s[end...]
        }
    }
    return .other
}

/// End of one inline-table value: the next top-level `,` or `}`.
private func valueEnd(_ s: Substring) -> Substring.Index {
    var depth = 0, quote: Character?, i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if let q = quote {
            if c == "\\", q == "\"" { i = s.index(after: i) } else if c == q { quote = nil }
        } else if c == "\"" || c == "'" { quote = c }
        else if c == "[" || c == "{" { depth += 1 }
        else if c == "]" || c == "}" { if depth == 0 { return i }; depth -= 1 }
        else if c == ",", depth == 0 { return i }
        i = s.index(after: i)
    }
    return s.endIndex
}

/// A single-line basic or literal string at the start of `s`: its text and the index after it.
private func quoted(_ s: Substring) -> (String, Substring.Index)? {
    guard let q = s.first, q == "\"" || q == "'" else { return nil }
    var out = "", i = s.index(after: s.startIndex)
    while i < s.endIndex {
        let c = s[i]
        if c == "\n" { return nil }
        if c == q { return (out, s.index(after: i)) }
        if q == "\"", c == "\\" {
            i = s.index(after: i)
            guard i < s.endIndex else { return nil }
            switch s[i] {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"", "\\": out.append(s[i])
            default: out.append("\\"); out.append(s[i])  // shortcut: \u escapes kept raw; a path with them reads as foreign
            }
        } else {
            out.append(c)
        }
        i = s.index(after: i)
    }
    return nil
}

/// Blanks and commas between items (a Set: "\r\n" in a string literal is one Character).
private let separators: Set<Character> = [" ", "\t", "\r", "\n", "\r\n", ","]
