import ControlServer
import Foundation
import Git
import Workspace

/// What CLI/MCP commands need from the terminals (Ghostty surfaces live in the views, not in the model).
struct TerminalAccess {
    /// Starts the tab's surfaces hidden if they never ran (a `--prompt` agent must not wait to be shown).
    var start: (UUID /* tab */) -> Void
    /// One check for send and read, so both answer the same way.
    var state: (UUID /* leaf */) -> LeafState
    /// Only called on a `running` leaf.
    var send: (UUID /* leaf */, String?, [SendKey]) -> Void
    var read: (UUID /* leaf */) -> String?
}

/// `starting`: spawned but nothing drawn yet (the agent may not take a paste); `failed`: the launch failed or cannot
/// happen (missing folder), so a retry will not help.
enum LeafState { case notStarted, starting, running, exited, failed }

/// Requests from the control socket (decision #45); handlers run on the main actor.
extension AppState {
    public func respond(_ id: Int, _ call: ControlCall) async -> ControlResponse {
        func fail(_ e: ControlError) -> ControlResponse { ControlResponse(id: id, body: .failure(e)) }
        switch call {
        case .projectsList:
            return .ok(id, ProjectsResult(projects: state.projects.map(projectInfo)))

        case .projectsAdd(let raw):
            let path = (raw as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return fail(ControlError(code: .notFound, message: "no such directory"))
            }
            // A remote project with the same path is another folder.
            if let existing = state.projects.first(where: { $0.host == nil && ($0.path as NSString).standardizingPath == path }) {
                return .ok(id, ProjectAddResult(project: projectInfo(existing), added: false))
            }
            let added = addProject(path: path)
            return .ok(id, ProjectAddResult(project: projectInfo(project(added)!), added: true))

        case .tasksList(let ref):
            var projects = state.projects
            if let ref {
                switch resolveProject(ref) {
                case .success(let p): projects = projects.filter { $0.id == p }
                case .failure(let e): return fail(e)
                }
            }
            return .ok(id, TasksResult(tasks: projects.flatMap { state.tasks(in: $0.id) }.map(taskInfo)))

        case let .tasksCreate(ref, name, worktree, base, prompt):
            let projectId: UUID
            switch resolveProject(ref) {
            case .success(let p): projectId = p
            case .failure(let e): return fail(e)
            }
            var mode = TaskMode.mainFolder
            if worktree, let project = project(projectId) {
                switch await countingCreation({ await worktreeMode(project, name: name, base: base) }) {
                case .success(let m): mode = m
                case .failure(let e): return fail(e)
                }
                // Removed while git ran: the worktree stays on disk like after an archive.
                guard self.project(projectId) != nil else {
                    var left = ""
                    if case .worktree(let path, let branch, _) = mode { left = "; worktree left at \(path) (branch \(branch))" }
                    return fail(ControlError(code: .notFound, message: "project \"\(ref)\" was removed while creating the worktree" + left))
                }
            }
            let created = createTask(projectId: projectId, name: name, firstMessage: prompt ?? "", mode: mode, select: false)
            terminals?.start(created.tab)
            guard let task = state.tasks.first(where: { $0.id == created.task }) else {
                return fail(ControlError(code: .failed, message: "task was not created"))
            }
            return .ok(id, TaskResult(task: taskInfo(task)))

        case .tasksArchive(let ref):
            switch resolveTask(ref) {
            case .success(let t):
                archive(taskId: t)
                return .ok(id, ArchiveResult(task: t, archived: true))
            case .failure(let e): return fail(e)
            }

        case let .tabsOpen(ref, kind, prompt):
            let taskId: UUID
            switch resolveTask(ref) {
            case .success(let t): taskId = t
            case .failure(let e): return fail(e)
            }
            var tabId = UUID()
            perform { s in
                guard let i = s.tasks.firstIndex(where: { $0.id == taskId }) else { return }
                let previous = s.tasks[i].activeTabId
                tabId = s.addTab(taskId: taskId, kind: leafKind(kind))
                if let previous { s.tasks[i].activeTabId = previous }
                let message = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !message.isEmpty, let leaf = s.tasks[i].tabs.last?.root.leaves.first { pendingPrompts[leaf.id] = message }
            }
            terminals?.start(tabId)
            guard let tab = state.tasks.first(where: { $0.id == taskId })?.tabs.first(where: { $0.id == tabId }) else {
                return fail(ControlError(code: .failed, message: "tab was not created"))
            }
            return .ok(id, TabResult(task: taskId, tab: tabInfo(tab)))

        case let .tabsSend(ref, text, keys):
            let target: (tab: UUID, leaf: UUID)
            switch resolveLeaf(ref) {
            case .success(let t): target = t
            case .failure(let e): return fail(e)
            }
            switch leafState(target) {
            case .running:
                terminals?.send(target.leaf, text, keys)
                return .ok(id, SendResult(tab: target.tab, leaf: target.leaf))
            case .notStarted, .starting: return fail(ControlError(code: .notStarted, message: "tab is starting, retry"))
            case .exited: return fail(ControlError(code: .exited, message: "process has exited; relaunch the tab"))
            case .failed: return fail(Self.couldNotStart)
            }

        case let .tabsRead(ref, lines):
            let target: (tab: UUID, leaf: UUID)
            switch resolveLeaf(ref) {
            case .success(let t): target = t
            case .failure(let e): return fail(e)
            }
            if leafState(target) == .failed { return fail(Self.couldNotStart) }
            guard let screen = terminals?.read(target.leaf) else {
                return fail(ControlError(code: .notStarted, message: "tab is starting, retry"))
            }
            let tail = screenTail(screen, lines: lines)
            return .ok(id, ScreenResult(tab: target.tab, leaf: target.leaf, text: tail.text, lines: tail.lines, truncated: tail.truncated))
        }
    }

    private static let couldNotStart = ControlError(code: .failed, message: "tab could not start")

    /// A never-started leaf is started hidden first (a `--prompt`-less tab may never have been shown).
    private func leafState(_ target: (tab: UUID, leaf: UUID)) -> LeafState {
        guard let terminals else { return .notStarted }
        let state = terminals.state(target.leaf)
        if state != .notStarted { return state }
        terminals.start(target.tab)
        return terminals.state(target.leaf)
    }

    /// `--tab`: a tab id (→ its focused leaf) or a leaf id, among non-archived tasks; TERMINAL panel leaves are not addressable
    /// (shortcut: no drawer refs, add one if orchestrators need the panel shell).
    private func resolveLeaf(_ ref: String) -> Result<(tab: UUID, leaf: UUID), ControlError> {
        let tabs = state.tasks.filter { !$0.archived }.flatMap(\.tabs)
        var targets: [UUID: (tab: UUID, leaf: UUID)] = [:]
        for tab in tabs {
            targets[tab.id] = (tab.id, tab.focusedLeafId)
            for leaf in tab.root.leaves { targets[leaf.id] = (tab.id, leaf.id) }
        }
        return resolveRef(ref, in: targets.keys.sorted { $0.uuidString < $1.uuidString }.map { RefCandidate(id: $0, names: []) })
            .map { targets[$0]! }
            .mapError { refError($0, ref, "tab") }
    }

    private func leafKind(_ kind: TabKind) -> LeafKind {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        case .editor: .editor
        case .shell: .shell
        }
    }

    func taskInfo(_ task: HangarTask) -> TaskInfo {
        let project = project(task.projectId)
        var path = project?.path ?? "", base: String?
        var mode = "main-folder"
        if case .worktree(let p, _, let b) = task.mode { (path, base, mode) = (p, b, "worktree") }
        return TaskInfo(id: task.id, name: task.name, project: task.projectId, projectName: project?.name ?? "",
                        status: displayState(of: task).rawValue, mode: mode, path: path, branch: task.branch, base: base,
                        tabs: task.tabs.map(tabInfo))
    }

    private func tabInfo(_ tab: Tab) -> TabInfo {
        let leaves = tab.root.leaves.map {
            LeafInfo(id: $0.id, kind: tabKind($0.kind), status: displayState(ofLeaf: $0.id, kind: $0.kind).rawValue)
        }
        let focused = leaves.first { $0.id == tab.focusedLeafId } ?? leaves[0]
        return TabInfo(id: tab.id, kind: focused.kind, title: tabLabel(tab), status: focused.status, leaves: leaves)
    }

    private func tabKind(_ kind: LeafKind) -> TabKind {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        case .editor: .editor
        case .shell: .shell
        }
    }

    private func projectInfo(_ p: Project) -> ProjectInfo {
        ProjectInfo(id: p.id, name: p.name, path: p.path, exists: isAvailable(p), host: p.host)
    }

    private func resolveProject(_ ref: String) -> Result<UUID, ControlError> {
        resolveRef(ref, in: state.projects.map { RefCandidate(id: $0.id, names: [$0.name, $0.path]) })
            .mapError { refError($0, ref, "project") }
    }

    /// Archived tasks are never found (decision #45).
    private func resolveTask(_ ref: String) -> Result<UUID, ControlError> {
        resolveRef(ref, in: state.tasks.filter { !$0.archived }.map { RefCandidate(id: $0.id, names: [$0.name]) })
            .mapError { refError($0, ref, "task") }
    }

    private func refError(_ e: RefError, _ ref: String, _ what: String) -> ControlError {
        switch e {
        case .notFound: ControlError(code: .notFound, message: "no \(what) \"\(ref)\"")
        case .ambiguous(let ids):
            ControlError(code: .ambiguous, message: "\"\(ref)\" matches: \(ids.prefix(5).map(\.uuidString).joined(separator: ", "))")
        }
    }

    /// The new-task sheet's path without the sheet (decision #45): fetch, branch check, worktree path; a failed fetch fails.
    private func worktreeMode(_ project: Project, name: String, base: String?) async -> Result<TaskMode, ControlError> {
        let failed = { (message: String) in Result<TaskMode, ControlError>.failure(ControlError(code: .failed, message: message)) }
        let model = NewTaskModel(project: project, git: git(for: project), taskBranches: taskBranches(project.id))
        await model.load()
        switch model.availability {
        case .notRepository: return failed("not a git repository")
        case .noCommits: return failed("repository has no commits")
        case .loading, .ready: break
        }
        if let base {
            guard model.branches.contains(where: { $0.name == base }) else {
                return .failure(ControlError(code: .notFound, message: "no branch \"\(base)\""))
            }
            model.base = base
        }
        guard model.base != nil else { return failed("no default branch; pass base") }
        model.worktree = true
        model.name = name
        if let mode = await model.create(skipFetch: false) { return .success(mode) }
        var fetchError: String?
        if case .failed(let message) = model.fetch { fetchError = message }
        // branchError is L10n text for the sheet; the wire gets fixed English.
        let branchError = model.branchError.map { _ in branchProblemMessage(model.branch, branches: model.branches) }
        return failed(model.createError ?? branchError ?? fetchError ?? "worktree was not created")
    }
}

/// English counterpart of `NewTaskModel`'s branch problems (empty, already exists, else invalid).
func branchProblemMessage(_ branch: String, branches: [Branch]) -> String {
    if branch.isEmpty { return "task name gives an empty branch name" }
    if branches.contains(where: { !$0.isRemote && $0.name == branch }) { return "branch \"\(branch)\" already exists" }
    return "invalid branch name \"\(branch)\""
}

/// `tabs.read`: the last `lines` lines without trailing blank ones, at most 512 KiB (cut from the start).
func screenTail(_ screen: String, lines: Int) -> (text: String, lines: Int, truncated: Bool) {
    var all = screen.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = all.last, last.allSatisfy({ $0 == " " || $0 == "\r" }) { all.removeLast() }
    var truncated = all.count > lines
    var text = all.suffix(lines).joined(separator: "\n")
    let maxBytes = 524_288
    if text.utf8.count > maxBytes {
        truncated = true
        var bytes = text.utf8.suffix(maxBytes)
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }  // not mid-character
        text = String(decoding: bytes, as: UTF8.self)
    }
    return (text, text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count, truncated)
}
