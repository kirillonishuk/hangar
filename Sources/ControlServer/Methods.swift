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
    /// Free strings (session refs), each up to 256 bytes.
    case refs(max: Int)
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
    case tasksSpawn = "tasks.spawn", tasksWait = "tasks.wait"
    case actionsList = "actions.list", actionsRun = "actions.run"

    /// MCP tool name: `tasks.*` methods are `sessions_*` since the rename (#73); the socket method stays.
    public var toolName: String { legacyToolName.replacingOccurrences(of: "tasks_", with: "sessions_") }
    /// Pre-rename tool name: still callable over MCP, never listed.
    public var legacyToolName: String { rawValue.replacingOccurrences(of: ".", with: "_") }

    /// Exposed by `hangar mcp --read-only`: listings and screen reads, nothing that changes Hangar or types into a terminal.
    public var readOnly: Bool { [.projectsList, .tasksList, .tabsRead, .doctor, .tasksWait, .actionsList].contains(self) }

    public static let maxText = 32_768
    public static let maxPrompt = 16_384
    public static let maxNameChars = 200
    public static let sendWaitSeconds = 10
    /// `sessions_wait` default: under Claude Code's 2-minute move of a long MCP call into the background.
    public static let waitDefaultSeconds = 110
    /// `sessions_wait` default for Codex, whose MCP calls time out after 60 s.
    public static let waitCodexSeconds = 50
    public static let waitMaxSeconds = 3600

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
        case .tasksSpawn: "Start a sub-session of the calling chat (or of parent) to do something in parallel: a full chat with its own terminal and agent, shown under the parent in Hangar's sidebar, started with prompt (Hangar asks it to end with a concise final result). By default it works in the parent's own folder (the same worktree or main folder); worktree: true gives it a new git worktree instead. Returns its id and hangar:// link. Nothing is ever typed into the parent: when it has fully finished (agent stopped and no background tasks left), needs input or failed, the user gets a notification. To get its result, call sessions_wait."
        case .tasksWait: "Wait until sub-sessions have fully finished (agent stopped and no background tasks it started are left), need input, or failed; or until timeout. Returns per sub-session: status (done, needs-input, error, still-running), id, name, link, tab, the agent's final message (capped at ~1500 characters; truncated: true when cut). still-running means the timeout passed: call again. Without sessions: all open sub-sessions of the calling chat. Full output: tabs_read."
        case .actionsList: "List a session's project actions (named commands like Dev server or Test, from the project's settings and the repository's .hangar/actions.json in the session's folder), with whether each is running and in which tab. The repository file's problems are reported in error."
        case .actionsRun: "Run a project action in a session's folder in its own tab (like the Run button). With restart on (the default), a running copy is interrupted (Ctrl-C) and started again in the same tab; else another tab opens. An action from .hangar/actions.json whose command the user has not approved in Hangar is refused: they run it once from the app first."
        case .linksCreate: "Get a hangar:// link to a session, a tab, a project, an SSH host or a project's Sessions view. Clicking it in Hangar only selects and shows it; nothing runs."
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
        case .tasksSpawn:
            return [
                ParamSpec(name: "name", type: .string(maxBytes: Self.maxNameChars * 4), required: true, summary: "Sub-session name, 1-200 characters."),
                ParamSpec(name: "prompt", type: .string(maxBytes: Self.maxPrompt), required: true, summary: "The sub-session agent's task."),
                ParamSpec(name: "agent", type: .oneOf(["claude", "codex"]), required: false, summary: "Agent to run (default: Hangar's default agent)."),
                ParamSpec(name: "worktree", type: .bool, required: false,
                          summary: "Work in a new git worktree of the parent's project instead of the parent's own folder (default: the same worktree or main folder as the parent)."),
                ParamSpec(name: "base", type: .string(maxBytes: 255), required: false, summary: "Base branch for the worktree (only with worktree)."),
                ParamSpec(name: "parent", type: ref, required: false,
                          summary: "Parent session id/prefix/name or a tab/leaf id; default: the calling chat (HANGAR_LEAF_ID)."),
            ]
        case .tasksWait:
            return [
                ParamSpec(name: "sessions", type: .refs(max: 16), required: false,
                          summary: "Sub-session ids (or unique prefixes / names); default: all open sub-sessions of the calling chat."),
                ParamSpec(name: "timeout", type: .int(1...Self.waitMaxSeconds), required: false,
                          summary: "Seconds to wait at most (default \(Self.waitDefaultSeconds); \(Self.waitCodexSeconds) under Codex)."),
                ParamSpec(name: "parent", type: ref, required: false,
                          summary: "Whose sub-sessions to wait for when sessions is omitted; default: the calling chat (HANGAR_LEAF_ID)."),
            ]
        case .actionsList:
            return [ParamSpec(name: "task", type: ref, required: false,
                              summary: "Session id/prefix/name or a tab/leaf id; default: the calling chat (HANGAR_LEAF_ID).")]
        case .actionsRun:
            return [
                ParamSpec(name: "task", type: ref, required: false,
                          summary: "Session id/prefix/name or a tab/leaf id; default: the calling chat (HANGAR_LEAF_ID)."),
                ParamSpec(name: "name", type: .string(maxBytes: 240), required: true, summary: "The action's name, as actions_list shows it."),
            ]
        case .linksCreate:
            return [
                ParamSpec(name: "kind", type: .oneOf(LinkKind.allCases.map(\.rawValue)), required: true, summary: "What the link points at: task (a session), tab, project, host, sessions (a project's Sessions view)."),
                ParamSpec(name: "ref", type: ref, required: true,
                          summary: "Session or project id (or unique prefix) or name (sessions: the project); for a tab, a tab or leaf id from sessions_list (or unique prefix); for a host, its name in SSH HOSTS."),
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
    /// `parent`: a session ref or a tab/leaf id (the CLI/MCP fill in `HANGAR_LEAF_ID`).
    case tasksSpawn(parent: String?, name: String, prompt: String, agent: TabKind?, worktree: Bool, base: String?)
    case tasksWait(sessions: [String], parent: String?, timeout: Int)
    /// `task`: a session ref or a tab/leaf id (the CLI/MCP fill in `HANGAR_LEAF_ID`).
    case actionsList(task: String)
    case actionsRun(task: String, name: String)

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
        case .tasksSpawn: .tasksSpawn
        case .tasksWait: .tasksWait
        case .actionsList: .actionsList
        case .actionsRun: .actionsRun
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
        case let .tasksSpawn(parent, name, prompt, agent, worktree, base):
            p = ["name": name, "prompt": prompt]
            p["parent"] = parent
            p["agent"] = agent?.rawValue
            if worktree { p["worktree"] = true }
            p["base"] = base
        case let .tasksWait(sessions, parent, timeout):
            p = ["timeout": timeout]
            if !sessions.isEmpty { p["sessions"] = sessions }
            p["parent"] = parent
        case let .actionsList(task): p = ["task": task]
        case let .actionsRun(task, name): p = ["task": task, "name": name]
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

    /// Shared by `tasks.create` and `tasks.spawn`.
    private static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...ControlMethod.maxNameChars).contains(name.count) else { throw bad("\"name\" must be 1-\(ControlMethod.maxNameChars) characters") }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || invisibleSeparators.contains($0.value) }) else { throw bad("\"name\" must not contain control characters") }
        return name
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
            case let .refs(max):
                guard let a = raw as? [Any], a.count <= max else { throw bad("\"\(n)\" must be an array of at most \(max) strings") }
                var out: [String] = []
                for item in a {
                    guard let s = item as? String, !s.isEmpty, s.utf8.count <= 256, !s.unicodeScalars.contains("\0") else {
                        throw bad("\"\(n)\" items must be non-empty strings of at most 256 bytes")
                    }
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
            let name = try validName(v.strings["name"]!)
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
        case .tasksSpawn:
            let name = try validName(v.strings["name"]!)
            let worktree = v.bools["worktree"] ?? false
            if v.strings["base"] != nil, !worktree { throw bad("\"base\" requires worktree: true") }
            let prompt = v.strings["prompt"]!
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw bad("\"prompt\" must not be blank") }
            return .tasksSpawn(parent: v.strings["parent"], name: name, prompt: prompt, agent: v.strings["agent"].flatMap(TabKind.init(rawValue:)),
                               worktree: worktree, base: v.strings["base"])
        case .tasksWait:
            return .tasksWait(sessions: v.lists["sessions"] ?? [], parent: v.strings["parent"], timeout: v.ints["timeout"] ?? ControlMethod.waitDefaultSeconds)
        case .actionsList:
            guard let task = v.strings["task"] else { throw bad("not inside a Hangar chat: pass \"session\"") }
            return .actionsList(task: task)
        case .actionsRun:
            guard let task = v.strings["task"] else { throw bad("not inside a Hangar chat: pass \"session\"") }
            let name = v.strings["name"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw bad("\"name\" must not be blank") }
            return .actionsRun(task: task, name: name)
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
