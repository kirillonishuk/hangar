import Foundation

public enum TabKind: String, CaseIterable, Codable, Sendable { case claude, codex, editor, shell }

public enum SendKey: String, CaseIterable, Codable, Sendable {
    case enter, escape, tab, backspace, up, down, left, right
    case ctrlC = "ctrl-c", ctrlD = "ctrl-d"
    /// Stops the running turn: Esc in claude/codex, Ctrl-C in a shell or editor (resolved per leaf by the app).
    case interrupt
}

public enum ParamType: Sendable {
    case string(maxBytes: Int)
    case bool
    case int(ClosedRange<Int>)
    case oneOf([String])
    case list(of: [String], max: Int)
}

public struct ParamSpec: Sendable {
    public var name: String
    public var type: ParamType
    public var required: Bool
    public var summary: String

    public init(name: String, type: ParamType, required: Bool, summary: String) {
        self.name = name
        self.type = type
        self.required = required
        self.summary = summary
    }
}

/// The single source of parameters: server validation, CLI and the MCP JSON Schema all read `params`.
public enum ControlMethod: String, CaseIterable, Sendable {
    case projectsList = "projects.list", projectsAdd = "projects.add", tasksList = "tasks.list", tasksCreate = "tasks.create"
    case tabsOpen = "tabs.open", tabsSend = "tabs.send", tabsRead = "tabs.read", tasksArchive = "tasks.archive"
    case doctor
    case tasksRestore = "tasks.restore"
    case sshOpen = "ssh.open"
    case linksCreate = "links.create"

    /// MCP tool name: `tasks.*` methods are `sessions_*` since the rename (#73); the socket method stays.
    public var toolName: String { legacyToolName.replacingOccurrences(of: "tasks_", with: "sessions_") }
    /// Pre-rename tool name: still callable over MCP, never listed.
    public var legacyToolName: String { rawValue.replacingOccurrences(of: ".", with: "_") }

    /// Exposed by `hangar mcp --read-only`: listings and screen reads, nothing that changes Hangar or types into a terminal.
    public var readOnly: Bool { [.projectsList, .tasksList, .tabsRead, .doctor].contains(self) }

    public static let maxText = 32_768
    public static let maxPrompt = 16_384
    public static let maxNameChars = 200
    public static let sendWaitSeconds = 10

    public var summary: String {
        switch self {
        case .projectsList: "List the projects registered in Hangar."
        case .projectsAdd: "Register a folder as a Hangar project (idempotent). With host: a folder on that ssh server; Hangar connects and checks the server (up to ~1 min), installs nothing and returns warnings for missing tools."
        case .tasksList: "List sessions with their tabs, TERMINAL drawer shell and agent statuses, optionally for one project. With git: true also changes against the base (+added −removed lines, files), dirty and ahead/behind the base (runs git per session)."
        case .tasksCreate: "Create a session in a project, in the main folder or in a new git worktree, optionally starting an agent with a prompt."
        case .tabsOpen: "Open a new tab (claude, codex, editor or shell) in a session, optionally with an initial prompt for agents."
        case .tabsSend: "Type text into a tab's terminal (pasted) and then press keys. Works on a tab waiting for permission. Result status: sent, queued (claude was already working; it runs after the current turn), started / not-started-yet (with wait). Enter into a working codex is refused (busy): wait for it or send keys [interrupt] first."
        case .tabsRead: "Read the last lines of a tab's terminal screen. The text may contain secrets."
        case .doctor: "Read-only health report: app and socket, CLI/app versions, claude/codex, agent hooks, Ghostty resources, ssh hosts, keep-awake, disk space. Each check is ok, warn or fail with a fix hint."
        case .tasksArchive: "Archive a session. A worktree session's folder is removed and its branch kept (restoring re-creates the worktree); a worktree with uncommitted changes or ignored files (.env) is refused unless force: true. Requires yes: true."
        case .tasksRestore: "Restore an archived session. A worktree session's folder is re-created from its kept branch; fails if that branch is gone."
        case .sshOpen: "Open a plain ssh shell tab on a host (no project, no tmux, no server check) in that host's terminal and show it. The shell ends when the connection drops."
        case .linksCreate: "Get a hangar:// link to a session, a tab or a project. Clicking it in Hangar only selects and focuses it; nothing runs."
        }
    }

    public var params: [ParamSpec] {
        let ref = ParamType.string(maxBytes: 256)
        switch self {
        case .projectsList, .doctor:
            return []
        case .projectsAdd:
            return [
                ParamSpec(name: "path", type: .string(maxBytes: 1024), required: true,
                          summary: "Absolute folder path; with host, a path on the server (~ and relative paths are from the server home)."),
                ParamSpec(name: "host", type: .string(maxBytes: 255), required: false, summary: "ssh host (ssh config name or user@host) for a remote project."),
            ]
        case .tasksList:
            return [
                ParamSpec(name: "project", type: ref, required: false, summary: "Project id (or unique prefix) or name."),
                ParamSpec(name: "git", type: .bool, required: false, summary: "Add changes, dirty and ahead/behind per session (slower: runs git)."),
            ]
        case .tasksCreate:
            return [
                ParamSpec(name: "project", type: ref, required: true, summary: "Project id (or unique prefix) or name."),
                ParamSpec(name: "name", type: .string(maxBytes: Self.maxNameChars * 4), required: true, summary: "Session name, 1-200 characters."),
                ParamSpec(name: "worktree", type: .bool, required: false, summary: "Create a git worktree instead of using the main folder."),
                ParamSpec(name: "base", type: .string(maxBytes: 255), required: false, summary: "Base branch for the worktree (only with worktree)."),
                ParamSpec(name: "prompt", type: .string(maxBytes: Self.maxPrompt), required: false, summary: "Start the default agent's tab with this prompt."),
            ]
        case .tabsOpen:
            return [
                ParamSpec(name: "task", type: ref, required: true, summary: "Session id (or unique prefix) or name."),
                ParamSpec(name: "kind", type: .oneOf(TabKind.allCases.map(\.rawValue)), required: true, summary: "Tab kind."),
                ParamSpec(name: "prompt", type: .string(maxBytes: Self.maxPrompt), required: false, summary: "Initial prompt (claude and codex only)."),
            ]
        case .tabsSend:
            return [
                ParamSpec(name: "tab", type: ref, required: true, summary: "Tab id, leaf id or a session's drawer leaf id from sessions_list (or unique prefix)."),
                ParamSpec(name: "text", type: .string(maxBytes: Self.maxText), required: false, summary: "Text to paste."),
                ParamSpec(name: "keys", type: .list(of: SendKey.allCases.map(\.rawValue), max: 32), required: false,
                          summary: "Keys to press after the text; interrupt = Esc for claude/codex, Ctrl-C for a shell."),
                ParamSpec(name: "wait", type: .bool, required: false,
                          summary: "Wait up to \(Self.sendWaitSeconds) s for a claude tab to report the turn started (status working)."),
            ]
        case .tabsRead:
            return [
                ParamSpec(name: "tab", type: ref, required: true, summary: "Tab id, leaf id or a session's drawer leaf id from sessions_list (or unique prefix)."),
                ParamSpec(name: "lines", type: .int(1...5000), required: false, summary: "Number of last lines (default 100)."),
            ]
        case .tasksArchive:
            return [
                ParamSpec(name: "task", type: ref, required: true, summary: "Session id (or unique prefix) or name."),
                ParamSpec(name: "yes", type: .bool, required: true, summary: "Must be true to confirm."),
                ParamSpec(name: "force", type: .bool, required: false,
                          summary: "Remove the worktree even with uncommitted changes or ignored files; they are deleted."),
            ]
        case .tasksRestore:
            return [ParamSpec(name: "task", type: ref, required: true, summary: "Archived session id (or unique prefix) or name.")]
        case .sshOpen:
            return [ParamSpec(name: "host", type: .string(maxBytes: 255), required: true, summary: "ssh host (ssh config name or user@host).")]
        case .linksCreate:
            return [
                ParamSpec(name: "kind", type: .oneOf(LinkKind.allCases.map(\.rawValue)), required: true, summary: "What the link points at."),
                ParamSpec(name: "ref", type: ref, required: true,
                          summary: "Session or project id (or unique prefix) or name; for a tab, a tab or leaf id from sessions_list (or unique prefix)."),
            ]
        }
    }
}

public enum ControlCall: Equatable, Sendable {
    case projectsList
    /// `host`: checked with `validSSHHost` by the app (Exec is not linked into the CLI).
    case projectsAdd(path: String, host: String? = nil)
    case tasksList(project: String?, git: Bool = false)
    case tasksCreate(project: String, name: String, worktree: Bool, base: String?, prompt: String?)
    case tabsOpen(task: String, kind: TabKind, prompt: String?)
    case tabsSend(tab: String, text: String?, keys: [SendKey], wait: Bool = false)
    case tabsRead(tab: String, lines: Int)
    case tasksArchive(task: String, force: Bool = false)
    case doctor
    case tasksRestore(task: String)
    /// `host`: checked with `validSSHHost` by the app.
    case sshOpen(host: String)
    case linksCreate(kind: LinkKind, ref: String)

    public static let defaultLines = 100

    public var method: ControlMethod {
        switch self {
        case .projectsList: .projectsList
        case .projectsAdd: .projectsAdd
        case .tasksList: .tasksList
        case .tasksCreate: .tasksCreate
        case .tabsOpen: .tabsOpen
        case .tabsSend: .tabsSend
        case .tabsRead: .tabsRead
        case .tasksArchive: .tasksArchive
        case .doctor: .doctor
        case .tasksRestore: .tasksRestore
        case .sshOpen: .sshOpen
        case .linksCreate: .linksCreate
        }
    }

    public func paramsJSON() -> Data {
        var p: [String: Any] = [:]
        switch self {
        case .projectsList, .doctor: break
        case let .projectsAdd(path, host):
            p["path"] = path
            p["host"] = host
        case let .tasksList(project, git):
            p["project"] = project
            if git { p["git"] = true }
        case let .tasksCreate(project, name, worktree, base, prompt):
            p = ["project": project, "name": name, "worktree": worktree]
            p["base"] = base
            p["prompt"] = prompt
        case let .tabsOpen(task, kind, prompt):
            p = ["task": task, "kind": kind.rawValue]
            p["prompt"] = prompt
        case let .tabsSend(tab, text, keys, wait):
            p = ["tab": tab]
            p["text"] = text
            if !keys.isEmpty { p["keys"] = keys.map(\.rawValue) }
            if wait { p["wait"] = true }
        case let .tabsRead(tab, lines): p = ["tab": tab, "lines": lines]
        case let .tasksArchive(task, force):
            p = ["task": task, "yes": true]
            if force { p["force"] = true }
        case let .tasksRestore(task): p = ["task": task]
        case let .sshOpen(host): p = ["host": host]
        case let .linksCreate(kind, ref): p = ["kind": kind.rawValue, "ref": ref]
        }
        return (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// Trust boundary: `params` comes from any local process of this user.
    public static func decode(method: String, params: [String: Any]) -> Result<ControlCall, ControlError> {
        guard let m = ControlMethod(rawValue: method) else {
            return .failure(ControlError(code: .unknownMethod, message: "unknown method \"\(method.prefix(64))\""))
        }
        do {
            let v = try validate(m, params)
            return .success(try build(m, v))
        } catch let e as ControlError {
            return .failure(e)
        } catch {
            return .failure(ControlError(code: .badParams, message: "invalid parameters"))
        }
    }

    // MARK: validation

    /// Line/paragraph separators and bidi overrides/isolates: invisible, they spoof names in listings.
    private static let invisibleSeparators: Set<UInt32> = [0x2028, 0x2029, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    private static func bad(_ message: String) -> ControlError { ControlError(code: .badParams, message: message) }

    private struct Values {
        var strings: [String: String] = [:]
        var bools: [String: Bool] = [:]
        var ints: [String: Int] = [:]
        var lists: [String: [String]] = [:]
    }

    private static func validate(_ m: ControlMethod, _ params: [String: Any]) throws -> Values {
        let specs = m.params
        let known = Set(specs.map(\.name))
        if let extra = params.keys.sorted().first(where: { !known.contains($0) }) {
            throw bad("unknown parameter \"\(extra.prefix(64))\"")
        }
        var v = Values()
        for spec in specs {
            guard let raw = params[spec.name], !(raw is NSNull) else {
                if spec.required { throw ControlError(code: spec.name == "yes" ? .confirmRequired : .badParams, message: spec.name == "yes" ? "confirmation required: pass yes: true" : "missing parameter \"\(spec.name)\"") }
                continue
            }
            let n = spec.name
            switch spec.type {
            case let .string(maxBytes):
                guard let s = raw as? String else { throw bad("\"\(n)\" must be a string") }
                guard !s.isEmpty else { throw bad("\"\(n)\" must not be empty") }
                guard s.utf8.count <= maxBytes else { throw bad("\"\(n)\" is too long (max \(maxBytes) bytes)") }
                guard !s.unicodeScalars.contains("\0") else { throw bad("\"\(n)\" must not contain NUL") }
                v.strings[n] = s
            case .bool:
                guard let b = bool(raw) else { throw bad("\"\(n)\" must be a boolean") }
                v.bools[n] = b
            case let .int(range):
                guard let i = int(raw), range.contains(i) else { throw bad("\"\(n)\" must be an integer in \(range.lowerBound)...\(range.upperBound)") }
                v.ints[n] = i
            case let .oneOf(options):
                guard let s = raw as? String, options.contains(s) else { throw bad("\"\(n)\" must be one of: \(options.joined(separator: ", "))") }
                v.strings[n] = s
            case let .list(options, max):
                guard let a = raw as? [Any], a.count <= max else { throw bad("\"\(n)\" must be an array of at most \(max) items") }
                var out: [String] = []
                for item in a {
                    guard let s = item as? String, options.contains(s) else { throw bad("\"\(n)\" items must be one of: \(options.joined(separator: ", "))") }
                    out.append(s)
                }
                v.lists[n] = out
            }
        }
        return v
    }

    private static func build(_ m: ControlMethod, _ v: Values) throws -> ControlCall {
        switch m {
        case .projectsList: return .projectsList
        case .doctor: return .doctor
        case .projectsAdd:
            let path = v.strings["path"]!, host = v.strings["host"]
            guard host != nil || path.hasPrefix("/") else { throw bad("\"path\" must be absolute") }
            return .projectsAdd(path: path, host: host)
        case .tasksList: return .tasksList(project: v.strings["project"], git: v.bools["git"] ?? false)
        case .tasksCreate:
            let name = v.strings["name"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...ControlMethod.maxNameChars).contains(name.count) else { throw bad("\"name\" must be 1-\(ControlMethod.maxNameChars) characters") }
            guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || invisibleSeparators.contains($0.value) }) else { throw bad("\"name\" must not contain control characters") }
            let worktree = v.bools["worktree"] ?? false
            if v.strings["base"] != nil, !worktree { throw bad("\"base\" requires worktree: true") }
            return .tasksCreate(project: v.strings["project"]!, name: name, worktree: worktree, base: v.strings["base"], prompt: v.strings["prompt"])
        case .tabsOpen:
            let kind = TabKind(rawValue: v.strings["kind"]!)!
            if v.strings["prompt"] != nil, kind != .claude, kind != .codex { throw bad("\"prompt\" is only for claude and codex tabs") }
            return .tabsOpen(task: v.strings["task"]!, kind: kind, prompt: v.strings["prompt"])
        case .tabsSend:
            let keys = (v.lists["keys"] ?? []).compactMap(SendKey.init(rawValue:))
            // ESC would end the bracketed paste early; keys like escape/ctrl-c have their own `keys`.
            var text = v.strings["text"]?.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
            if text?.isEmpty == true { text = nil }
            guard text != nil || !keys.isEmpty else { throw bad("pass \"text\" or \"keys\"") }
            return .tabsSend(tab: v.strings["tab"]!, text: text, keys: keys, wait: v.bools["wait"] ?? false)
        case .tabsRead: return .tabsRead(tab: v.strings["tab"]!, lines: v.ints["lines"] ?? defaultLines)
        case .tasksArchive:
            guard v.bools["yes"] == true else { throw ControlError(code: .confirmRequired, message: "confirmation required: pass yes: true") }
            return .tasksArchive(task: v.strings["task"]!, force: v.bools["force"] ?? false)
        case .tasksRestore: return .tasksRestore(task: v.strings["task"]!)
        case .sshOpen: return .sshOpen(host: v.strings["host"]!)
        case .linksCreate: return .linksCreate(kind: LinkKind(rawValue: v.strings["kind"]!)!, ref: v.strings["ref"]!)
        }
    }

    // NSNumber from JSONSerialization: booleans and numbers share the class.
    private static func bool(_ raw: Any) -> Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func int(_ raw: Any) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }

    static func wireInt(_ raw: Any) -> Int? { int(raw) }
}
