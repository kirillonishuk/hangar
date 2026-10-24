import Foundation

/// `hangar projects|tasks|tabs …` (decision #45): argv → one `ControlCall`; output text is English.
public enum CLIParse: Equatable, Sendable {
    case call(ControlCall, json: Bool)
    case usage(String)
    case confirmRequired(String)
}

public let cliUsage = """
usage:
  hangar projects list [--json]
  hangar projects add <path> [--host H] [--json]   (with --host: a path on the server, quote ~ so the local shell keeps it)
  hangar tasks list [--project P] [--git] [--json]   (--git: +added −removed lines and files vs the base, dirty, ↑ahead ↓behind)
  hangar tasks create --project P --name N [--worktree [--base B]] [--prompt TEXT] [--json]
  hangar tasks archive --task T --yes [--force] [--json]   (removes a worktree, keeps its branch; --force: even with uncommitted or ignored files)
  hangar tasks restore --task T [--json]   (an archived task; re-creates its worktree from the kept branch)
  hangar tabs open --task T --kind claude|codex|editor|shell [--prompt TEXT] [--json]
  hangar tabs send --tab T [TEXT…] [--key K]… [--enter] [--wait] [--json]   (keys: \(SendKey.allCases.map(\.rawValue).joined(separator: ", ")))
  hangar tabs read --tab T [--lines N] [--json]
  hangar ssh <host> [--json]   (opens a plain ssh shell tab in the app: no project, no tmux)
  hangar link task|tab|project <ref> [--json]   (prints a hangar:// link; opening it only selects, nothing runs)
  (T: a tab id, a leaf id or a task's drawer leaf id from `tasks list`, or a unique prefix)
  hangar doctor [--json]   (read-only health report; exit 1 when a check fails)
  hangar mcp [--read-only]   (MCP server over stdio; --read-only: only projects_list, tasks_list, tabs_read, doctor)
  hangar event <kind> [--session ID]
  hangar statusline [--then <command>]
"""

private struct Grammar {
    var values: Set<String> = []
    var flags: Set<String> = []
    /// Value flags that may repeat; only `tabs send --key`, collected into `keys`.
    var repeated: Set<String> = []
    var positionals: ClosedRange<Int> = 0...0
}

private func grammar(_ command: String) -> Grammar? {
    switch command {
    case "projects list": Grammar()
    case "projects add": Grammar(values: ["--host"], positionals: 1...1)
    case "tasks list": Grammar(values: ["--project"], flags: ["--git"])
    case "tasks restore": Grammar(values: ["--task"])
    case "tasks create": Grammar(values: ["--project", "--name", "--base", "--prompt"], flags: ["--worktree"])
    case "tasks archive": Grammar(values: ["--task"], flags: ["--yes", "--force"])
    case "tabs open": Grammar(values: ["--task", "--kind", "--prompt"])
    case "tabs send": Grammar(values: ["--tab"], flags: ["--enter", "--wait"], repeated: ["--key"], positionals: 0...Int.max)
    case "tabs read": Grammar(values: ["--tab", "--lines"])
    case "ssh": Grammar(positionals: 1...1)
    case "link task", "link tab", "link project": Grammar(positionals: 1...1)
    default: nil
    }
}

/// `ssh` is the one single-word command; the rest are `<noun> <verb>`.
private func commandWords(_ args: [String]) -> Int { args.first == "ssh" ? 1 : 2 }

public func parseCLI(_ args: [String], cwd: String) -> CLIParse {
    let n = commandWords(args)
    let command = args.prefix(n).joined(separator: " ")
    guard args.count >= n, let g = grammar(command) else {
        return .usage("unknown command \"\(command)\"")
    }
    var values: [String: String] = [:], flags: Set<String> = [], keys: [SendKey] = [], words: [String] = []
    var json = false, rest = args.dropFirst(n)[...], flagsEnded = false
    while let a = rest.popFirst() {
        if flagsEnded || !a.hasPrefix("--") { words.append(a); continue }
        if a == "--" { flagsEnded = true; continue }
        if a == "--json" { json = true; continue }
        if g.flags.contains(a) { flags.insert(a); continue }
        let isKey = g.repeated.contains(a)
        guard isKey || g.values.contains(a) else { return .usage("unknown flag \"\(a)\"") }
        guard let v = rest.popFirst() else { return .usage("\(a) needs a value") }
        if isKey {
            guard let k = SendKey(rawValue: v) else { return .usage("unknown key \"\(v)\"") }
            keys.append(k)
            continue
        }
        guard values[a] == nil else { return .usage("\(a) given twice") }
        values[a] = v
    }
    guard g.positionals.contains(words.count) else {
        return .usage(words.isEmpty ? "missing argument" : "unexpected argument \"\(words.last!)\"")
    }
    func required(_ name: String) -> String? { values["--" + name] }
    let missing = { (name: String) in CLIParse.usage("missing --\(name)") }
    let call: ControlCall
    switch command {
    case "projects list":
        call = .projectsList
    case "projects add":
        guard !words[0].isEmpty else { return .usage("path must not be empty") }
        // A server path is resolved on the server (`~` = its home), never against this Mac's cwd.
        if let host = values["--host"] { return .call(.projectsAdd(path: words[0], host: host), json: json) }
        let path = words[0].hasPrefix("/") ? words[0] : cwd + "/" + words[0]
        call = .projectsAdd(path: URL(fileURLWithPath: path).standardized.path)
    case "tasks list":
        call = .tasksList(project: values["--project"], git: flags.contains("--git"))
    case "tasks restore":
        guard let task = required("task") else { return missing("task") }
        call = .tasksRestore(task: task)
    case "tasks create":
        guard let project = required("project") else { return missing("project") }
        guard let name = required("name") else { return missing("name") }
        let worktree = flags.contains("--worktree")
        if values["--base"] != nil, !worktree { return .usage("--base requires --worktree") }
        call = .tasksCreate(project: project, name: name, worktree: worktree, base: values["--base"], prompt: values["--prompt"])
    case "tasks archive":
        guard let task = required("task") else { return missing("task") }
        guard flags.contains("--yes") else { return .confirmRequired("refusing to archive without --yes") }
        call = .tasksArchive(task: task, force: flags.contains("--force"))
    case "tabs open":
        guard let task = required("task") else { return missing("task") }
        guard let raw = required("kind") else { return missing("kind") }
        guard let kind = TabKind(rawValue: raw) else { return .usage("--kind must be one of: \(TabKind.allCases.map(\.rawValue).joined(separator: ", "))") }
        call = .tabsOpen(task: task, kind: kind, prompt: values["--prompt"])
    case "ssh":
        call = .sshOpen(host: words[0])
    case "tabs send":
        guard let tab = required("tab") else { return missing("tab") }
        if flags.contains("--enter") { keys.append(.enter) }
        let text = words.isEmpty ? nil : words.joined(separator: " ")
        guard text != nil || !keys.isEmpty else { return .usage("nothing to send: pass text, --key or --enter") }
        call = .tabsSend(tab: tab, text: text, keys: keys, wait: flags.contains("--wait"))
    case "link task", "link tab", "link project":
        call = .linksCreate(kind: LinkKind(rawValue: args[1])!, ref: words[0])
    default:  // tabs read
        guard let tab = required("tab") else { return missing("tab") }
        var lines = ControlCall.defaultLines
        if let raw = values["--lines"] {
            guard let n = Int(raw), (1...5000).contains(n) else { return .usage("--lines must be an integer in 1...5000") }
            lines = n
        }
        call = .tabsRead(tab: tab, lines: lines)
    }
    return .call(call, json: json)
}

/// A worktree create runs `git fetch`/`worktree add`, which can take minutes on a big repo; a remote add connects
/// (ConnectTimeout 10 s) and checks the server (up to 30 s) first.
public func requestTimeout(_ call: ControlCall) -> Double {
    switch call {
    case .tasksCreate: 300
    case .projectsAdd(_, .some): 60
    // git status and `worktree remove` of a big folder (node_modules), possibly over ssh.
    case .tasksArchive: 120
    // Login shell plus `--version` of each agent, ssh hosts' state.
    case .doctor: 30
    case .tabsSend(_, _, _, true): Double(ControlMethod.sendWaitSeconds + 10)
    // `worktree add` of the kept branch (checkout of a big tree), possibly over ssh.
    case .tasksRestore: 120
    // A few git runs per task, possibly over ssh.
    case .tasksList(_, true): 60
    default: 10
    }
}

private func id(_ u: UUID) -> String { u.uuidString.lowercased() }
private func id8(_ u: UUID) -> String { String(id(u).prefix(8)) }

/// Human-readable result; falls back to the raw JSON if it does not decode.
public func formatHuman(_ call: ControlCall, result: Data) -> String {
    let d = JSONDecoder()
    let text: String?
    switch call {
    case .projectsList:
        text = (try? d.decode(ProjectsResult.self, from: result)).map { r in
            r.projects.map { "\(id8($0.id))  \($0.name)  \($0.host.map { $0 + ":" } ?? "")\($0.path)" }.joined(separator: "\n")
        }
    case .projectsAdd:
        text = (try? d.decode(ProjectAddResult.self, from: result)).map { r in
            "\(id(r.project.id))  \(r.project.host.map { $0 + ":" } ?? "")\(r.project.path)" + (r.added ? "" : "  (already added)")
                + (r.warnings ?? []).map { "\nwarning: " + $0 }.joined()
        }
    case .tasksList:
        text = (try? d.decode(TasksResult.self, from: result)).map { r in
            r.tasks.flatMap { t -> [String] in
                var head = "\(id8(t.id))  \(t.status)  \(t.projectName)/\(t.name)" + (t.branch.map { "  ⎇ \($0)" } ?? "")
                if let c = t.changes { head += "  +\(c.added) −\(c.removed) in \(c.files) file" + (c.files == 1 ? "" : "s") }
                if t.dirty == true { head += "  dirty" }
                if let a = t.ahead, let b = t.behind { head += "  ↑\(a) ↓\(b)" }
                var lines = [head]
                lines += t.tabs.map { "    \(id8($0.id))  \($0.kind.rawValue)  \($0.status)  \($0.title)" }
                if let d = t.drawer { lines.append("    \(id8(d.id))  drawer  \(d.status)  TERMINAL") }
                return lines
            }.joined(separator: "\n")
        }
    case .tasksCreate:
        text = (try? d.decode(TaskResult.self, from: result)).map { r in
            "task \(id(r.task.id))" + (r.task.tabs.first.map { " tab \(id($0.id))" } ?? "") + (r.note.map { "\nnote: " + $0 } ?? "")
        }
    case .tabsOpen:
        text = (try? d.decode(TabResult.self, from: result)).map { "tab \(id($0.tab.id))" }
    case .tabsSend:
        // A plain `sent` prints nothing, as before `status` existed.
        text = (try? d.decode(SendResult.self, from: result)).map { r in
            r.status == "sent" && r.hint == nil ? "" : r.status + (r.hint.map { ": " + $0 } ?? "")
        }
    case .tabsRead:
        text = (try? d.decode(ScreenResult.self, from: result))?.text
    case .doctor:
        text = (try? d.decode(DoctorReport.self, from: result)).map(formatDoctor)
    case .tasksRestore:
        text = (try? d.decode(TaskResult.self, from: result)).map { "restored \(id($0.task.id))" }
    case .sshOpen:
        text = (try? d.decode(TabResult.self, from: result)).map { "tab \(id($0.tab.id))" }
    case .tasksArchive:
        text = (try? d.decode(ArchiveResult.self, from: result)).map { "archived \(id($0.task))" + ($0.worktreeRemoved ? "; worktree removed, branch kept" : "") }
    case .linksCreate:
        text = (try? d.decode(LinkResult.self, from: result))?.url
    }
    return text ?? String(decoding: result, as: UTF8.self)
}

/// `{"error":{"code","message"}}` for `--json` failures.
public func errorJSON(_ e: ControlError) -> Data {
    struct Wrapper: Encodable { var error: ControlError }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(Wrapper(error: e))) ?? Data(#"{"error":{"code":"failed","message":"encoding failed"}}"#.utf8)
}

/// Whether a failed parse should still answer in JSON: `--json` as a flag, not as the value of `--task` etc.
public func jsonRequested(_ args: [String]) -> Bool {
    let n = commandWords(args)
    let command = args.prefix(n).joined(separator: " ")
    guard args.count >= n, let g = grammar(command) else { return args.prefix(while: { $0 != "--" }).contains("--json") }
    var rest = args.dropFirst(n)[...]
    while let a = rest.popFirst(), a != "--" {
        if a == "--json" { return true }
        if g.values.contains(a) || g.repeated.contains(a) { _ = rest.popFirst() }
    }
    return false
}
