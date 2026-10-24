import ControlServer
import Exec
import Foundation
import Git
import Workspace

/// What CLI/MCP commands need from the terminals (Ghostty surfaces live in the views, not in the model).
struct TerminalAccess {
    /// Starts the tab's surfaces hidden if they never ran (a `--prompt` agent must not wait to be shown).
    var start: (UUID /* tab, or a drawer leaf */) -> Void
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

        case .projectsAdd(let raw, .some(let host)):
            return await addRemote(id, path: raw, host: host)

        case .projectsAdd(let raw, nil):
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

        case let .tasksList(ref, withGit):
            var projects = state.projects
            if let ref {
                switch resolveProject(ref) {
                case .success(let p): projects = projects.filter { $0.id == p }
                case .failure(let e): return fail(e)
                }
            }
            var infos = projects.flatMap { state.tasks(in: $0.id) }.map(taskInfo)
            if withGit { infos = await addingGitStatus(infos) }
            return .ok(id, TasksResult(tasks: infos))

        case let .tasksRestore(ref):
            let taskId: UUID
            switch resolveTask(ref, archived: true) {
            case .success(let t): taskId = t
            case .failure(let e): return fail(e)
            }
            switch await restoreFromArchive(taskId) {
            case .restored:
                guard let task = state.tasks.first(where: { $0.id == taskId && !$0.archived }) else {
                    return fail(ControlError(code: .notFound, message: "task \"\(ref)\" is gone"))
                }
                return .ok(id, TaskResult(task: taskInfo(task)))
            case .branchMissing(let branch):
                return fail(ControlError(code: .failed, message: "branch \"\(branch)\" is gone, the worktree cannot be re-created; "
                                         + "restore it in Hangar to keep the task in the project folder"))
            case .failed(let details): return fail(ControlError(code: .failed, message: details))
            }

        case let .tasksCreate(ref, name, worktree, base, prompt):
            let projectId: UUID
            switch resolveProject(ref) {
            case .success(let p): projectId = p
            case .failure(let e): return fail(e)
            }
            var mode = TaskMode.mainFolder, setup: String?
            if worktree, let project = project(projectId) {
                switch await countingCreation({ await worktreeMode(project, name: name, base: base) }) {
                case .success(let m): (mode, setup) = m
                case .failure(let e): return fail(e)
                }
                // Removed while git ran: the worktree stays on disk.
                guard self.project(projectId) != nil else {
                    var left = ""
                    if case .worktree(let path, let branch, _) = mode { left = "; worktree left at \(path) (branch \(branch))" }
                    return fail(ControlError(code: .notFound, message: "project \"\(ref)\" was removed while creating the worktree" + left))
                }
            }
            let created = createTask(projectId: projectId, name: name, firstMessage: prompt ?? "", mode: mode, select: false, setup: setup)
            terminals?.start(created.tab)
            guard let task = state.tasks.first(where: { $0.id == created.task }) else {
                return fail(ControlError(code: .failed, message: "task was not created"))
            }
            return .ok(id, TaskResult(task: taskInfo(task)))

        case let .tasksArchive(ref, force):
            let taskId: UUID
            switch resolveTask(ref) {
            case .success(let t): taskId = t
            case .failure(let e): return fail(e)
            }
            switch await archiveRemovingWorktree(taskId, force: force) {
            case .archived(let removed): return .ok(id, ArchiveResult(task: taskId, archived: true, worktreeRemoved: removed))
            case .worktreeKept(let details):
                return fail(ControlError(code: .failed, message: "task archived, but the worktree was not removed: \(details)"))
            case let .atRisk(dirty, ignored):
                let shown = ignored.prefix(5).joined(separator: ", ") + (ignored.count > 5 ? ", …" : "")
                let what = [dirty ? "uncommitted changes" : nil, ignored.isEmpty ? nil : "ignored files (\(shown))"].compactMap { $0 }
                return fail(ControlError(code: .confirmRequired, message: "worktree has \(what.joined(separator: " and ")) that archiving would delete; "
                                         + "pass --force (MCP: force: true) to archive anyway"))
            case .failed(let details): return fail(ControlError(code: .failed, message: details))
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
                // Agents only: a shell runs its launch prompt as commands (worktree setup), never the wire's text.
                let agent = kind == .claude || kind == .codex
                let message = agent ? prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
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

    /// The «Удалённый проект» sheet without the sheet: connect (with the server check), `pwd -P` on the server, add.
    /// Nothing is installed here; what the server lacks comes back as warnings. A failure lets go of a host no project uses.
    private func addRemote(_ id: Int, path: String, host raw: String) async -> ControlResponse {
        guard let host = validSSHHost(raw) else { return ControlResponse(id: id, body: .failure(ControlError(code: .badParams, message: "invalid host"))) }
        func fail(_ code: ControlErrorCode, _ message: String) -> ControlResponse {
            releaseUnusedHost(host)
            return ControlResponse(id: id, body: .failure(ControlError(code: code, message: message)))
        }
        guard await remote.connect(host) == .connected, let info = remote.hosts[host], let home = info.home else {
            let info = remote.hosts[host]
            if info?.authFailed == true { return fail(.failed, "auth failed: run ssh \(host) in Terminal, then retry") }
            if info?.unsupportedShell != nil { return fail(.failed, "unsupported login shell (csh/tcsh)") }
            return fail(.failed, "host not connected")
        }
        guard let real = await remoteRealPath(path, home: home, runner: remote.runner(host)) else {
            return fail(.notFound, "folder not found on server")
        }
        let added = !state.projects.contains { $0.location == .ssh(host: host, path: real) }
        let project = project(addRemoteProject(host: host, path: real))!
        return .ok(id, ProjectAddResult(project: projectInfo(project), added: added, warnings: remoteAddWarnings(remote.hosts[host] ?? info)))
    }

    /// A never-started leaf is started hidden first (a `--prompt`-less tab may never have been shown).
    private func leafState(_ target: (tab: UUID, leaf: UUID)) -> LeafState {
        guard let terminals else { return .notStarted }
        let state = terminals.state(target.leaf)
        if state != .notStarted { return state }
        terminals.start(target.tab)
        return terminals.state(target.leaf)
    }

    /// `--tab`: a tab id (→ its focused leaf), a leaf id or a drawer leaf id (its own tab, like its HANGAR_TAB_ID),
    /// among non-archived tasks.
    private func resolveLeaf(_ ref: String) -> Result<(tab: UUID, leaf: UUID), ControlError> {
        let tasks = state.tasks.filter { !$0.archived }
        var targets: [UUID: (tab: UUID, leaf: UUID)] = [:]
        for tab in tasks.flatMap(\.tabs) {
            targets[tab.id] = (tab.id, tab.focusedLeafId)
            for leaf in tab.root.leaves { targets[leaf.id] = (tab.id, leaf.id) }
        }
        for leaf in tasks.compactMap(\.drawer.leaf) { targets[leaf.id] = (leaf.id, leaf.id) }
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
                        tabs: task.tabs.map(tabInfo),
                        drawer: task.drawer.leaf.map { LeafInfo(id: $0.id, kind: tabKind($0.kind), status: displayState(ofLeaf: $0.id, kind: $0.kind).rawValue) })
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

    /// Archived tasks are never found (decision #45), except by `tasks.restore`, which finds only them.
    private func resolveTask(_ ref: String, archived: Bool = false) -> Result<UUID, ControlError> {
        resolveRef(ref, in: state.tasks.filter { $0.archived == archived }.map { RefCandidate(id: $0.id, names: [$0.name]) })
            .mapError { refError($0, ref, archived ? "archived task" : "task") }
    }

    /// `tasks.list --git`: per task, in parallel. The inspector's loaded changes of the shown task are reused;
    /// a task whose git fails (not a repository, host offline) just gets no git fields.
    private func addingGitStatus(_ infos: [TaskInfo]) async -> [TaskInfo] {
        var jobs: [(index: Int, git: Git, base: String?, cached: ChangeSet?)] = []
        for (i, info) in infos.enumerated() {
            guard let task = state.tasks.first(where: { $0.id == info.id }), let project = project(task.projectId) else { continue }
            let mode: DiffMode = info.base.map { .base($0) } ?? .uncommitted
            let cached = inspector.shownTaskId == info.id && inspector.changes?.mode == mode ? inspector.changes : nil
            jobs.append((i, git(for: project, repo: info.path), info.base, cached))
        }
        var out = infos
        await withTaskGroup(of: (Int, TaskGitStatus?).self) { group in
            for job in jobs {
                group.addTask { (job.index, try? await taskGitStatus(job.git, base: job.base, cached: job.cached)) }
            }
            for await (i, status) in group {
                guard let status else { continue }
                out[i].changes = status.changes
                out[i].dirty = status.dirty
                out[i].ahead = status.ahead
                out[i].behind = status.behind
            }
        }
        return out
    }

    private func refError(_ e: RefError, _ ref: String, _ what: String) -> ControlError {
        switch e {
        case .notFound: ControlError(code: .notFound, message: "no \(what) \"\(ref)\"")
        case .ambiguous(let ids):
            ControlError(code: .ambiguous, message: "\"\(ref)\" matches: \(ids.prefix(5).map(\.uuidString).joined(separator: ", "))")
        }
    }

    /// The new-task sheet's path without the sheet (decision #45): fetch, branch check, worktree path, copy; a failed fetch fails.
    private func worktreeMode(_ project: Project, name: String, base: String?) async -> Result<(TaskMode, setup: String?), ControlError> {
        typealias R = Result<(TaskMode, setup: String?), ControlError>
        let failed = { (message: String) in R.failure(ControlError(code: .failed, message: message)) }
        let model = NewTaskModel(project: project, git: git(for: project), taskBranches: taskBranches(project.id))
        await model.load()
        switch model.availability {
        case .notRepository: return failed("not a git repository")
        case .noCommits: return failed("repository has no commits")
        case .hostOffline(let host): return failed(RemoteHostError.notConnected(host).description)
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
        if let mode = await model.create(skipFetch: false) { return .success((mode, model.setupScript)) }
        var fetchError: String?
        if case .failed(let message) = model.fetch { fetchError = message }
        // branchError is L10n text for the sheet; the wire gets fixed English.
        let branchError = model.branchError.map { _ in branchProblemMessage(model.branch, branches: model.branches) }
        return failed(model.createError ?? branchError ?? fetchError ?? "worktree was not created")
    }
}

struct TaskGitStatus {
    var changes: ChangesInfo
    var dirty: Bool
    var ahead: Int?
    var behind: Int?
}

/// The inspector's Changes count (vs the merge-base with `base`, else HEAD), dirty from `status`, ahead/behind `base`.
func taskGitStatus(_ git: Git, base: String?, cached: ChangeSet?) async throws -> TaskGitStatus {
    let status = try await git.status(prefix: git.location().prefix)
    let set: ChangeSet
    if let cached { set = cached } else { set = try await git.changedFiles(base.map { .base($0) } ?? .uncommitted, status: status) }
    let changes = ChangesInfo(added: set.files.reduce(0) { $0 + ($1.added ?? 0) }, removed: set.files.reduce(0) { $0 + ($1.deleted ?? 0) },
                              files: set.files.count)
    let counts = base == nil ? nil : try? await git.aheadBehind(base: base!)
    return TaskGitStatus(changes: changes, dirty: !status.entries.isEmpty, ahead: counts?.ahead, behind: counts?.behind)
}

/// `projects.add --host`: the sidebar warning's reasons (`HostInfo.needsAttention`) as fixed English lines.
func remoteAddWarnings(_ info: HostInfo) -> [String] {
    guard let r = info.report else { return [] }
    let install = "; open Hangar → Server to install"
    var out = r.missingRequired.map { "\($0.rawValue) missing on server" + install }
    if r.remoteOutdated(current: hangarRemoteVersion) { out.append("hangar-remote missing or outdated on server" + install) }
    if r.socketClient == nil { out.append("no socket client (python3, socat or nc) on server, agent statuses unavailable" + install) }
    if !info.forwarding { out.append("socket forwarding refused by server, agent statuses unavailable") }
    return out
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
