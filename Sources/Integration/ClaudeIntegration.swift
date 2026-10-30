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
    ("StopFailure", nil, "stop-failure"),
    ("PermissionRequest", nil, "permission-request"),
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

func statuslineCommand(_ cli: String, then: String?) -> String {
    "\(shellQuote(cli)) statusline" + (then.map { " --then \(shellQuote($0))" } ?? "")
}

/// `--then` argument of a Hangar statusline command, if any.
func thenArgument(_ command: String) -> String? {
    guard let w = shellWords(command), let i = w.firstIndex(of: "--then"), i + 1 < w.count else { return nil }
    return w[i + 1]
}

extension Array where Element == JSONMember {
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

func rootObject(_ text: String?) throws(IntegrationError) -> [JSONMember] {
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

private func hookGroup(_ h: (event: String, matcher: String?, kind: String), cli: String) -> JSONValue {
    var group: [JSONMember] = []
    if let m = h.matcher { group["matcher"] = .string(m) }
    group["hooks"] = .array([.object([
        JSONMember(key: "type", value: .string("command")),
        JSONMember(key: "command", value: .string(hookCommand(cli, h.kind))),
        JSONMember(key: "timeout", value: .number("5")),
    ])])
    return .object(group)
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
        groups.append(hookGroup(h, cli: cli))
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

/// Entries an older Hangar installed: only these exact ones are removed as obsolete by `claudeApply`.
let claudeHooksRetired: [(event: String, matcher: String?, kind: String)] = [
    ("StopFailure", "rate_limit", "stop-failure"),
]

/// The one install the app's own updater and the DMG point at: it wins over any other copy.
public let canonicalHelper = "/Applications/Hangar.app/Contents/Helpers/hangar"

/// Which CLI paths in a user's file are this Hangar's own (#111): the current helper, or another `Hangar.app` helper
/// that no longer exists (the app moved or was re-installed elsewhere: its entries move here). A helper of another
/// copy that still exists stays that copy's, unless this one is `/Applications/Hangar.app` (the one preferred copy):
/// so two copies never pull the entries back and forth at every launch.
public func localOwnership(cli: String, exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
    -> @Sendable (String) -> Bool {
    { path in
        if path == cli { return true }
        guard path.hasSuffix("/Contents/Helpers/hangar") else { return false }
        return cli == canonicalHelper || !exists(path)
    }
}

/// On a server the hooks call `~/.hangar/bin/hangar-remote`; any `hangar-remote` path is Hangar's.
public func remoteOwnership(cli: String) -> @Sendable (String) -> Bool {
    { $0 == cli || $0.hasSuffix("/hangar-remote") }
}

/// The CLI word of a command Hangar writes: `<cli> event <kind>` exactly, or `<cli> statusline …`; nil for the user's.
private func hangarCLI(of c: String) -> String? {
    guard isHangarCommand(c), let w = shellWords(c) else { return nil }
    if w[1] == "event" { return w.count == 3 ? w[0] : nil }
    return w[0]
}

/// The state Hangar's entries in Claude's user settings should be in (#111): `hooks` and `statusline` say which are
/// wanted, everything else is left alone. Hangar owns a handler only if its command is exactly `<cli> event <kind>`
/// with a CLI `ours` accepts (an older path is moved to `cli`); compound commands, user-changed matchers and the user's
/// handlers stay (#96). Missing hooks are appended to their events; the obsolete ones (`claudeHooksRetired`) go; an
/// unwanted function's entries are removed (the wrapped status line is restored). An entry of another Hangar copy
/// (a CLI `ours` refuses) leaves the whole file alone (`.otherCopy`). nil = nothing to write.
public func claudeApply(_ text: String?, cli: String, hooks: Bool, statusline: Bool,
                        ours: (String) -> Bool) throws(IntegrationError) -> String? {
    let original = try rootObject(text)
    var root = original
    var events: [JSONMember] = []
    switch root["hooks"] {
    case nil: break
    case .object(let e)?: events = e
    default: throw .notAnObject
    }
    func eachCommand(_ body: (String) -> Void) {
        for event in events {
            guard case .array(let groups) = event.value else { continue }
            for case .object(let g) in groups {
                guard case .array(let handlers)? = g["hooks"] else { continue }
                for h in handlers { if let c = command(of: h) { body(c) } }
            }
        }
        if case .object(let sl)? = root["statusLine"], case .string(let c)? = sl["command"] { body(c) }
    }
    var foreign = false
    eachCommand { c in if let x = hangarCLI(of: c), !ours(x) { foreign = true } }
    if foreign { throw .otherCopy }

    func matcher(_ g: [JSONMember]) -> String { if case .string(let m)? = g["matcher"] { m } else { "" } }
    let current = Set(claudeHooks.map { "\($0.event)|\($0.matcher ?? "")|\($0.kind)" })
    let retired = Set(claudeHooksRetired.map { "\($0.event)|\($0.matcher ?? "")|\($0.kind)" }).subtracting(current)
    var emptied: Set<String> = []
    for ei in events.indices {
        guard case .array(var groups) = events[ei].value else { continue }
        var touched = false
        for gi in groups.indices.reversed() {
            guard case .object(var g) = groups[gi], case .array(let handlers)? = g["hooks"] else { continue }
            var kept: [JSONValue] = []
            for h in handlers {
                guard let c = command(of: h), let x = hangarCLI(of: c), let w = shellWords(c), w[1] == "event" else { kept.append(h); continue }
                if !hooks || retired.contains("\(events[ei].key)|\(matcher(g))|\(w[2])") { continue }
                guard x != cli, case .object(var m) = h else { kept.append(h); continue }
                m["command"] = .string(hookCommand(cli, w[2]))  // a moved app: the same entry, the current path
                kept.append(.object(m))
            }
            guard kept != handlers else { continue }
            touched = true
            if kept.isEmpty { groups.remove(at: gi) } else { g["hooks"] = .array(kept); groups[gi] = .object(g) }
        }
        guard touched else { continue }
        events[ei].value = .array(groups)
        if groups.isEmpty { emptied.insert(events[ei].key) }
    }

    func present(_ h: (event: String, matcher: String?, kind: String)) -> Bool {
        guard case .array(let groups)? = events[h.event] else { return false }
        for case .object(let g) in groups {
            guard case .array(let handlers)? = g["hooks"] else { continue }
            for x in handlers {
                if let c = command(of: x), let w = shellWords(c), w.count >= 3, w[0] == cli, w[1] == "event", w[2] == h.kind { return true }
            }
        }
        return false
    }
    if hooks {
        for h in claudeHooks where !present(h) {
            var groups: [JSONValue] = []
            if let existing = events[h.event] {
                guard case .array(let a) = existing else { throw .notAnObject }
                groups = a
            }
            groups.append(hookGroup(h, cli: cli))
            events[h.event] = .array(groups)
            emptied.remove(h.event)
        }
    }
    events.removeAll { emptied.contains($0.key) }
    if root["hooks"] != nil || !events.isEmpty {
        // Hooks emptied by Hangar's removal take the key with them; a key that was already empty stays.
        root["hooks"] = events.isEmpty && !emptied.isEmpty ? nil : .object(events)
    }

    switch root["statusLine"] {
    case nil:
        if statusline {
            root["statusLine"] = .object([
                JSONMember(key: "type", value: .string("command")),
                JSONMember(key: "command", value: .string(statuslineCommand(cli, then: nil))),
            ])
        }
    case .object(var sl)?:
        // shortcut: a statusLine without a string `command` is left alone; Hangar then gets no usage from it.
        guard case .string(let c)? = sl["command"] else { break }
        if hangarCLI(of: c) == nil {
            guard statusline else { break }
            sl["command"] = .string(statuslineCommand(cli, then: c))
        } else if statusline {
            sl["command"] = .string(statuslineCommand(cli, then: thenArgument(c)))
        } else if let then = thenArgument(c) {
            sl["command"] = .string(then)
        } else {
            root["statusLine"] = nil
            break
        }
        root["statusLine"] = .object(sl)
    default: break
    }
    return root == original ? nil : printJSON(.object(root))
}

/// `claudeApply` on a file: backup next to it, atomic write that refuses if the file changed meanwhile.
/// nil = nothing written. Throws (file untouched) on an unreadable or unparsable file or a failed write.
public func claudeApplyFile(_ url: URL, cli: String, hooks: Bool, statusline: Bool, ours: (String) -> Bool, now: Date) throws -> FileWrite? {
    let original = try readUserFile(url)
    guard let updated = try claudeApply(original, cli: cli, hooks: hooks, statusline: statusline, ours: ours) else { return nil }
    return FileWrite(backup: try writeUserFile(url, text: updated, expected: original, now: now))
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
