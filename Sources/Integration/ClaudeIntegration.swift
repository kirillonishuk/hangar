import Foundation
import Exec

public enum IntegrationState: Equatable, Sendable {
    case notInstalled, installed
    case outdated  // Hangar entries point at another CLI path, or only some are present
    case installedStatuslineByUser  // hooks are current; a statusLine we cannot wrap (not an object / no string command) stays the user's
}

/// Hook kinds are `HookKind.rawValue` literals: Integration must not depend on AgentStatus.
public let claudeHooks: [(event: String, matcher: String?, kind: String)] = [
    ("SessionStart", nil, "session-start"),
    ("UserPromptSubmit", nil, "prompt"),
    ("PreToolUse", "Task|Agent", "subagent-start"),
    ("PostToolUse", "*", "tool"),
    ("Notification", nil, "notification"),
    ("Stop", nil, "stop"),
    ("SubagentStop", nil, "subagent-stop"),
    ("StopFailure", "rate_limit", "stop-failure"),
]

/// POSIX-sh word splitting for the subset settings files use: '…', "…", backslash. Unclosed quote → nil.
public func shellWords(_ s: String) -> [String]? {
    var words: [String] = []
    var cur = "", inWord = false
    var it = s.makeIterator()
    while let c = it.next() {
        switch c {
        case " ", "\t", "\n":
            if inWord { words.append(cur); cur = ""; inWord = false }
        case "'":
            inWord = true
            while true {
                guard let d = it.next() else { return nil }
                if d == "'" { break }
                cur.append(d)
            }
        case "\"":
            inWord = true
            while true {
                guard let d = it.next() else { return nil }
                if d == "\"" { break }
                if d == "\\" {
                    guard let e = it.next() else { return nil }
                    if "\"\\$`".contains(e) { cur.append(e) } else if e != "\n" { cur.append(d); cur.append(e) }
                } else {
                    cur.append(d)
                }
            }
        case "\\":
            guard let e = it.next() else { return nil }
            inWord = true
            if e != "\n" { cur.append(e) }
        default:
            inWord = true
            cur.append(c)
        }
    }
    if inWord { words.append(cur) }
    return words
}

public func isHangarCommand(_ command: String) -> Bool {
    guard let w = shellWords(command), w.count >= 2 else { return false }
    let exe = w[0].split(separator: "/").last.map(String.init) ?? ""
    return (exe == "hangar" || exe == "hangar-remote") && (w[1] == "event" || w[1] == "statusline")
}

private func hookCommand(_ cli: String, _ kind: String) -> String { "\(shellQuote(cli)) event \(kind)" }

private func statuslineCommand(_ cli: String, then: String?) -> String {
    "\(shellQuote(cli)) statusline" + (then.map { " --then \(shellQuote($0))" } ?? "")
}

/// `--then` argument of a Hangar statusline command, if any.
private func thenArgument(_ command: String) -> String? {
    guard let w = shellWords(command), let i = w.firstIndex(of: "--then"), i + 1 < w.count else { return nil }
    return w[i + 1]
}

private extension Array where Element == JSONMember {
    subscript(key: String) -> JSONValue? {
        get { first { $0.key == key }?.value }
        set {
            if let i = firstIndex(where: { $0.key == key }) {
                if let newValue { self[i].value = newValue } else { remove(at: i) }
            } else if let newValue {
                append(JSONMember(key: key, value: newValue))
            }
        }
    }
}

private func rootObject(_ text: String?) throws(IntegrationError) -> [JSONMember] {
    guard let text, !text.allSatisfy(\.isWhitespace) else { return [] }
    guard case .object(let m) = try parseJSON(text) else { throw .notAnObject }
    return m
}

private func command(of handler: JSONValue) -> String? {
    guard case .object(let m) = handler, case .string(let c)? = m["command"] else { return nil }
    return c
}

/// Drops Hangar handlers everywhere; a group/event/`hooks` emptied by that removal goes too (pre-existing empty ones stay).
/// Install keeps an emptied `hooks` key so it does not move to the end of the file on every reinstall.
private func removeHangarHooks(_ root: inout [JSONMember], keepHooksKey: Bool = false) {
    guard case .object(var events)? = root["hooks"] else { return }
    var touchedHooks = false
    for (ei, event) in events.enumerated().reversed() {
        guard case .array(var groups) = event.value else { continue }
        var touchedEvent = false
        for (gi, group) in groups.enumerated().reversed() {
            guard case .object(var g) = group, case .array(let handlers)? = g["hooks"] else { continue }
            let kept = handlers.filter { command(of: $0).map(isHangarCommand) != true }
            guard kept.count != handlers.count else { continue }
            touchedEvent = true
            if kept.isEmpty { groups.remove(at: gi) } else { g["hooks"] = .array(kept); groups[gi] = .object(g) }
        }
        // shortcut: an event/group array that was already empty before we touched anything is kept; only emptying by our removal deletes it.
        guard touchedEvent else { continue }
        touchedHooks = true
        if groups.isEmpty { events.remove(at: ei) } else { events[ei].value = .array(groups) }
    }
    guard touchedHooks else { return }
    root["hooks"] = events.isEmpty && !keepHooksKey ? nil : .object(events)
}

public func claudeInstall(_ text: String?, cli: String) throws(IntegrationError) -> String {
    var root = try rootObject(text)
    removeHangarHooks(&root, keepHooksKey: true)

    var events: [JSONMember] = []
    if let hooks = root["hooks"] {
        guard case .object(let e) = hooks else { throw .notAnObject }
        events = e
    }
    for h in claudeHooks {
        var groups: [JSONValue] = []
        if let existing = events[h.event] {
            guard case .array(let a) = existing else { throw .notAnObject }
            groups = a
        }
        var group: [JSONMember] = []
        if let m = h.matcher { group["matcher"] = .string(m) }
        group["hooks"] = .array([.object([
            JSONMember(key: "type", value: .string("command")),
            JSONMember(key: "command", value: .string(hookCommand(cli, h.kind))),
            JSONMember(key: "timeout", value: .number("5")),
        ])])
        groups.append(.object(group))
        events[h.event] = .array(groups)
    }
    root["hooks"] = .object(events)

    switch root["statusLine"] {
    case nil:
        root["statusLine"] = .object([
            JSONMember(key: "type", value: .string("command")),
            JSONMember(key: "command", value: .string(statuslineCommand(cli, then: nil))),
        ])
    case .object(var sl)?:
        // shortcut: a statusLine without a string `command` is left alone; Hangar then gets no usage from it.
        if case .string(let c)? = sl["command"] {
            sl["command"] = .string(isHangarCommand(c) ? statuslineCommand(cli, then: thenArgument(c)) : statuslineCommand(cli, then: c))
            root["statusLine"] = .object(sl)
        }
    default: break
    }
    return printJSON(.object(root))
}

public func claudeUninstall(_ text: String) throws(IntegrationError) -> String {
    guard case .object(var root) = try parseJSON(text) else { throw .notAnObject }
    removeHangarHooks(&root)
    if case .object(var sl)? = root["statusLine"], case .string(let c)? = sl["command"], isHangarCommand(c) {
        if let then = thenArgument(c) {
            sl["command"] = .string(then)
            root["statusLine"] = .object(sl)
        } else {
            root["statusLine"] = nil
        }
    }
    return printJSON(.object(root))
}

public func claudeState(_ text: String?, cli: String) -> IntegrationState {
    guard let root = try? rootObject(text) else { return .notInstalled }
    var found: [String] = []  // "event|matcher|command" of every Hangar handler
    if case .object(let events)? = root["hooks"] {
        for event in events {
            guard case .array(let groups) = event.value else { continue }
            for case .object(let g) in groups {
                guard case .array(let handlers)? = g["hooks"] else { continue }
                let matcher: String? = if case .string(let m)? = g["matcher"] { m } else { nil }
                for h in handlers {
                    if let c = command(of: h), isHangarCommand(c) { found.append("\(event.key)|\(matcher ?? "")|\(c)") }
                }
            }
        }
    }
    var statusOurs = false, statusCurrent = false
    if case .object(let sl)? = root["statusLine"], case .string(let c)? = sl["command"], isHangarCommand(c) {
        statusOurs = true
        statusCurrent = shellWords(c)?.first == cli
    }
    if found.isEmpty && !statusOurs { return .notInstalled }
    let expected = claudeHooks.map { "\($0.event)|\($0.matcher ?? "")|\(hookCommand(cli, $0.kind))" }
    guard found.sorted() == expected.sorted() else { return .outdated }
    if statusCurrent { return .installed }
    // shortcut: install leaves such a statusLine alone, so reporting .outdated would never clear.
    switch root["statusLine"] {
    case nil: return .outdated
    case .object(let sl)?:
        if case .string? = sl["command"] { return .outdated }  // a plain user command: install would wrap it
        return .installedStatuslineByUser
    default: return .installedStatuslineByUser
    }
}
