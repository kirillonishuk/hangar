import Foundation

public enum Location: Codable, Equatable, Sendable {
    case local(path: String)
    case ssh(host: String, path: String)
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var location: Location
    public var lastBaseBranch: String?
    /// Sidebar group folded.
    public var collapsed: Bool
    /// New-task sheet starts with the worktree toggle on.
    public var worktreeByDefault: Bool
    /// Parent folder for this project's worktrees; nil = the default location.
    public var worktreeRoot: String?
    /// Gitignored paths/globs copied from the main checkout into a new worktree; nil = the default for the repo's
    /// package manager (`WorktreeDefaults`), [] = none.
    public var worktreeCopy: [String]?
    /// Run at the new worktree's top in a shell tab after the copy; nil = the package manager's default, "" = none.
    public var setupCommand: String?

    public init(id: UUID = UUID(), name: String, location: Location, lastBaseBranch: String? = nil, collapsed: Bool = false,
                worktreeByDefault: Bool = false, worktreeRoot: String? = nil, worktreeCopy: [String]? = nil,
                setupCommand: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.lastBaseBranch = lastBaseBranch
        self.collapsed = collapsed
        self.worktreeByDefault = worktreeByDefault
        self.worktreeRoot = worktreeRoot
        self.worktreeCopy = worktreeCopy
        self.setupCommand = setupCommand
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, location, lastBaseBranch, collapsed, worktreeByDefault, worktreeRoot, worktreeCopy, setupCommand
    }

    /// `collapsed` and the worktree fields were added later; older files decode with the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  location: try c.decode(Location.self, forKey: .location),
                  lastBaseBranch: try c.decodeIfPresent(String.self, forKey: .lastBaseBranch),
                  collapsed: try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false,
                  worktreeByDefault: try c.decodeIfPresent(Bool.self, forKey: .worktreeByDefault) ?? false,
                  worktreeRoot: try c.decodeIfPresent(String.self, forKey: .worktreeRoot),
                  worktreeCopy: try c.decodeIfPresent([String].self, forKey: .worktreeCopy),
                  setupCommand: try c.decodeIfPresent(String.self, forKey: .setupCommand))
    }


    public var path: String {
        switch location {
        case .local(let path), .ssh(_, let path): return path
        }
    }

    /// nil for a local project.
    public var host: String? {
        if case .ssh(let host, _) = location { return host }
        return nil
    }
}

public enum TaskMode: Codable, Equatable, Sendable {
    case mainFolder
    case worktree(path: String, branch: String, base: String)
}

public enum Axis: String, Codable, Equatable, Sendable { case horizontal, vertical }

public enum LeafKind: String, Codable, Equatable, Sendable { case claude, codex, editor, shell }

public struct Leaf: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: LeafKind
    public var cwd: String
    public var agentSessionId: String?
    public var openFile: String?
    /// 1-based line the editor opens at; nil in states saved before it existed.
    public var openLine: Int?

    public init(id: UUID = UUID(), kind: LeafKind, cwd: String, agentSessionId: String? = nil,
                openFile: String? = nil, openLine: Int? = nil) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.agentSessionId = agentSessionId
        self.openFile = openFile
        self.openLine = openLine
    }
}

public indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(Leaf)
    case split(axis: Axis, ratio: Double, first: SplitNode, second: SplitNode)

    public var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): return [leaf]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    public func leaf(id: UUID) -> Leaf? { leaves.first { $0.id == id } }

    func mapLeaves(_ transform: (Leaf) -> Leaf) -> SplitNode {
        switch self {
        case .leaf(let leaf): return .leaf(transform(leaf))
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.mapLeaves(transform), second: second.mapLeaves(transform))
        }
    }

    /// Replaces the leaf with `leafId` by `.split(first: oldLeaf, second: newLeaf)`.
    func splitting(leafId: UUID, axis: Axis, newLeaf: Leaf) -> SplitNode {
        switch self {
        case .leaf(let leaf):
            guard leaf.id == leafId else { return self }
            return .split(axis: axis, ratio: 0.5, first: self, second: .leaf(newLeaf))
        case .split(let a, let ratio, let first, let second):
            return .split(axis: a, ratio: ratio,
                          first: first.splitting(leafId: leafId, axis: axis, newLeaf: newLeaf),
                          second: second.splitting(leafId: leafId, axis: axis, newLeaf: newLeaf))
        }
    }

    func settingRatio(at path: ArraySlice<Int>, _ value: Double) -> SplitNode {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(axis: axis, ratio: value, first: first, second: second) }
        let rest = path.dropFirst()
        return step == 0
            ? .split(axis: axis, ratio: ratio, first: first.settingRatio(at: rest, value), second: second)
            : .split(axis: axis, ratio: ratio, first: first, second: second.settingRatio(at: rest, value))
    }

    /// Removes the leaf; its sibling takes the parent's place. nil when the tree becomes empty.
    func removing(leafId: UUID) -> SplitNode? {
        switch self {
        case .leaf(let leaf):
            return leaf.id == leafId ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let f = first.removing(leafId: leafId)
            let s = second.removing(leafId: leafId)
            switch (f, s) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let f?, let s?): return .split(axis: axis, ratio: ratio, first: f, second: s)
            }
        }
    }
}

public struct Tab: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var root: SplitNode
    public var focusedLeafId: UUID
    /// Set by the user (rename); wins over the terminal's own title.
    public var customTitle: String?

    public init(id: UUID = UUID(), title: String, root: SplitNode, focusedLeafId: UUID, customTitle: String? = nil) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedLeafId = focusedLeafId
        self.customTitle = customTitle
    }

    public func label(auto: String) -> String { customTitle ?? auto }
}

/// Bottom terminal of a task: one shell leaf, created on first show and kept while hidden.
public struct Drawer: Codable, Equatable, Sendable {
    public var leaf: Leaf?
    public var visible: Bool
    public var height: Double

    public static let minHeight: Double = 120

    public init(leaf: Leaf? = nil, visible: Bool = false, height: Double = 220) {
        self.leaf = leaf
        self.visible = visible
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case leaf, visible, height }

    /// Missing keys decode to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(leaf: try c.decodeIfPresent(Leaf.self, forKey: .leaf),
                  visible: try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false,
                  height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 220)
    }
}

public struct HangarTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var mode: TaskMode
    public var order: Int
    public var archived: Bool
    public var tabs: [Tab]
    public var activeTabId: UUID?
    public var pinned: Bool
    public var drawer: Drawer

    /// Branch of a worktree task; nil for main-folder tasks.
    public var branch: String? {
        if case .worktree(_, let branch, _) = mode { return branch }
        return nil
    }

    public init(id: UUID = UUID(), projectId: UUID, name: String, mode: TaskMode = .mainFolder,
                order: Int, archived: Bool = false, tabs: [Tab] = [], activeTabId: UUID? = nil, pinned: Bool = false,
                drawer: Drawer = Drawer()) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.mode = mode
        self.order = order
        self.archived = archived
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.pinned = pinned
        self.drawer = drawer
    }

    private enum CodingKeys: String, CodingKey { case id, projectId, name, mode, order, archived, tabs, activeTabId, pinned, drawer }

    /// `pinned` and `drawer` were added later; older files decode with the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), projectId: try c.decode(UUID.self, forKey: .projectId),
                  name: try c.decode(String.self, forKey: .name), mode: try c.decode(TaskMode.self, forKey: .mode),
                  order: try c.decode(Int.self, forKey: .order), archived: try c.decode(Bool.self, forKey: .archived),
                  tabs: try c.decode([Tab].self, forKey: .tabs),
                  activeTabId: try c.decodeIfPresent(UUID.self, forKey: .activeTabId),
                  pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
                  drawer: try c.decodeIfPresent(Drawer.self, forKey: .drawer) ?? Drawer())
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [HangarTask]
    public var selectedTaskId: UUID?
    public var inspectorVisible: Bool
    /// Last expanded sidebar width; kept while collapsed so expanding restores it.
    public var sidebarWidth: Double
    public var sidebarCollapsed: Bool
    /// Last inspector width (clamped to 180...480 by the view).
    public var inspectorWidth: Double
    /// Plain ssh logins without a project (#NN-ssh-shell); their tasks sit in `tasks` with the shell's id as `projectId`.
    public var hostShells: [HostShell]

    public init(projects: [Project] = [], tasks: [HangarTask] = [],
                selectedTaskId: UUID? = nil, inspectorVisible: Bool = false,
                sidebarWidth: Double = 220, sidebarCollapsed: Bool = false, inspectorWidth: Double = 220,
                hostShells: [HostShell] = []) {
        self.projects = projects
        self.hostShells = hostShells
        self.tasks = tasks
        self.selectedTaskId = selectedTaskId
        self.inspectorVisible = inspectorVisible
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.inspectorWidth = inspectorWidth
    }

    private enum CodingKeys: String, CodingKey {
        case projects, tasks, selectedTaskId, inspectorVisible, sidebarWidth, sidebarCollapsed, inspectorWidth, hostShells
    }

    /// Keys added after the first release decode with defaults so older state.json files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projects: try c.decode([Project].self, forKey: .projects),
                  tasks: try c.decode([HangarTask].self, forKey: .tasks),
                  selectedTaskId: try c.decodeIfPresent(UUID.self, forKey: .selectedTaskId),
                  inspectorVisible: try c.decode(Bool.self, forKey: .inspectorVisible),
                  sidebarWidth: try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 220,
                  sidebarCollapsed: try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false,
                  inspectorWidth: try c.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 220,
                  hostShells: try c.decodeIfPresent([HostShell].self, forKey: .hostShells) ?? [])
    }

    // MARK: Projects / tasks

    @discardableResult
    public mutating func addProject(name: String, path: String) -> UUID {
        let project = Project(name: name, location: .local(path: path))
        projects.append(project)
        return project.id
    }

    /// The same host + path is the same project: returns the existing id.
    @discardableResult
    public mutating func addRemoteProject(name: String, host: String, path: String) -> UUID {
        let location = Location.ssh(host: host, path: path)
        if let existing = projects.first(where: { $0.location == location }) { return existing.id }
        let project = Project(name: name, location: location)
        projects.append(project)
        return project.id
    }

    /// `mode` is set before any tab exists, so leaves take the worktree path as cwd.
    @discardableResult
    public mutating func addTask(projectId: UUID, name: String, mode: TaskMode = .mainFolder) -> UUID {
        let order = (tasks.filter { $0.projectId == projectId }.map(\.order).max() ?? -1) + 1
        let task = HangarTask(projectId: projectId, name: name, mode: mode, order: order)
        tasks.append(task)
        return task.id
    }

    /// Active tasks of the project sorted by `order`.
    public func tasks(in projectId: UUID) -> [HangarTask] {
        tasks.filter { $0.projectId == projectId && !$0.archived }.sorted { $0.order < $1.order }
    }

    /// Moves the task to index `to` of `tasks(in:)` (clamped), keeps archived siblings in their slots, renumbers `order`.
    public mutating func moveTask(id: UUID, to index: Int) {
        guard let task = tasks.first(where: { $0.id == id }), !task.archived else { return }
        var all = tasks.filter { $0.projectId == task.projectId }.sorted { $0.order < $1.order }
        let slots = all.indices.filter { !all[$0].archived }
        var visible = slots.map { all[$0] }
        guard let from = visible.firstIndex(where: { $0.id == id }) else { return }
        let moved = visible.remove(at: from)
        visible.insert(moved, at: min(max(index, 0), visible.count))
        for (slot, t) in zip(slots, visible) { all[slot] = t }
        for (order, t) in all.enumerated() {
            if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i].order = order }
        }
    }

    public mutating func select(taskId: UUID?) { selectedTaskId = taskId }

    public mutating func archiveTask(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].archived = true
        if selectedTaskId == id { selectedTaskId = nil }
    }

    // MARK: Tabs / leaves

    private func cwd(for task: HangarTask) -> String {
        switch task.mode {
        case .worktree(let path, _, _): return path
        case .mainFolder: return projects.first { $0.id == task.projectId }?.path ?? ""
        }
    }

    @discardableResult
    public mutating func addTab(taskId: UUID, kind: LeafKind, openFile: String? = nil, openLine: Int? = nil) -> UUID {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else {
            assertionFailure("addTab: unknown task")
            return UUID()
        }
        // A host's terminal holds only ssh shells.
        let kind = isHostShellTask(tasks[i]) ? .shell : kind
        let leaf = Leaf(kind: kind, cwd: cwd(for: tasks[i]), openFile: openFile, openLine: openLine)
        let tab = Tab(title: kind.rawValue, root: .leaf(leaf), focusedLeafId: leaf.id)
        tasks[i].tabs.append(tab)
        tasks[i].activeTabId = tab.id
        return tab.id
    }

    public mutating func closeTab(taskId: UUID, tabId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tasks[i].tabs.remove(at: t)
        // A host's terminal lives only while it has tabs.
        if tasks[i].tabs.isEmpty, let shell = hostShells.first(where: { $0.id == tasks[i].projectId }) {
            return closeHostShell(host: shell.host)
        }
        guard tasks[i].activeTabId == tabId else { return }
        let tabs = tasks[i].tabs
        tasks[i].activeTabId = tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
    }

    /// Drag-reorder in the tab bar: the tab goes to index `to` (clamped); the array order is what gets saved.
    public mutating func moveTab(taskId: UUID, tabId: UUID, to index: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let from = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tasks[i].tabs.remove(at: from)
        tasks[i].tabs.insert(tab, at: min(max(index, 0), tasks[i].tabs.count))
    }

    /// Splits the leaf, focuses the new leaf and returns its id (a fresh id if the target is not found).
    @discardableResult
    public mutating func split(taskId: UUID, tabId: UUID, leafId: UUID, axis: Axis, kind: LeafKind) -> UUID {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }),
              tasks[i].tabs[t].root.leaf(id: leafId) != nil else {
            assertionFailure("split: unknown task, tab or leaf")
            return UUID()
        }
        let newLeaf = Leaf(kind: isHostShellTask(tasks[i]) ? .shell : kind, cwd: cwd(for: tasks[i]))
        tasks[i].tabs[t].root = tasks[i].tabs[t].root.splitting(leafId: leafId, axis: axis, newLeaf: newLeaf)
        tasks[i].tabs[t].focusedLeafId = newLeaf.id
        return newLeaf.id
    }

    /// Closing the last leaf closes the tab.
    public mutating func closeLeaf(taskId: UUID, tabId: UUID, leafId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tasks[i].tabs[t]
        guard let leafIndex = tab.root.leaves.firstIndex(where: { $0.id == leafId }) else { return }
        guard let newRoot = tab.root.removing(leafId: leafId) else {
            closeTab(taskId: taskId, tabId: tabId)
            return
        }
        tasks[i].tabs[t].root = newRoot
        if tab.focusedLeafId == leafId {
            let remaining = newRoot.leaves
            tasks[i].tabs[t].focusedLeafId = remaining[min(leafIndex, remaining.count - 1)].id
        }
    }

    /// `path` walks from the root: 0 = first child, 1 = second. Ratio is clamped to 0.05…0.95.
    public mutating func setRatio(taskId: UUID, tabId: UUID, path: [Int], ratio: Double) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tasks[i].tabs[t].root = tasks[i].tabs[t].root.settingRatio(at: path[...], min(max(ratio, 0.05), 0.95))
    }

    // MARK: Drawer

    /// First show creates the shell leaf (cwd = task cwd); later toggles keep it.
    public mutating func toggleDrawer(taskId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        if tasks[i].drawer.leaf == nil { tasks[i].drawer.leaf = Leaf(kind: .shell, cwd: cwd(for: tasks[i])) }
        tasks[i].drawer.visible.toggle()
    }

    /// The window-height cap is applied by the UI; the model only keeps the minimum.
    public mutating func setDrawerHeight(taskId: UUID, _ height: Double) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].drawer.height = max(height, Drawer.minHeight)
    }

    /// The shell exited cleanly: hide the drawer and forget the leaf (the next show starts a new shell).
    public mutating func closeDrawerLeaf(taskId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].drawer.leaf = nil
        tasks[i].drawer.visible = false
    }

    // MARK: Sidebar actions

    public mutating func setPinned(taskId: UUID, _ pinned: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].pinned = pinned
    }

    public mutating func setProjectCollapsed(id: UUID, _ collapsed: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].collapsed = collapsed
    }

    public mutating func restoreTask(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].archived = false
    }

    /// Restore without its worktree (the branch is gone): a main-folder task whose leaves move from the worktree to the project.
    public mutating func detachWorktree(taskId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), case .worktree(let path, _, _) = tasks[i].mode else { return }
        tasks[i].mode = .mainFolder
        let folder = cwd(for: tasks[i])
        func move(_ leaf: Leaf) -> Leaf {
            var leaf = leaf
            if leaf.cwd == path || leaf.cwd.hasPrefix(path + "/") { leaf.cwd = folder + leaf.cwd.dropFirst(path.count) }
            return leaf
        }
        for tab in tasks[i].tabs.indices { tasks[i].tabs[tab].root = tasks[i].tabs[tab].root.mapLeaves(move) }
        tasks[i].drawer.leaf = tasks[i].drawer.leaf.map(move)
    }

    /// Names are trimmed; an empty name is ignored.
    public mutating func renameTask(id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].name = name
    }

    public mutating func renameProject(id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
    }

    /// Blank titles are ignored (like task/project names).
    public mutating func renameTab(taskId: UUID, tabId: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tasks[i].tabs[t].customTitle = title
    }

    /// Only archived tasks can be deleted; removes it from the state (files on disk stay).
    public mutating func deleteTask(id: UUID) {
        guard tasks.contains(where: { $0.id == id && $0.archived }) else { return }
        tasks.removeAll { $0.id == id }
        if selectedTaskId == id { selectedTaskId = nil }
    }

    /// Removes the project and all its tasks from the state; the folder on disk is not touched.
    public mutating func removeProject(id: UUID) {
        if let selected = selectedTaskId, tasks.contains(where: { $0.id == selected && $0.projectId == id }) {
            selectedTaskId = nil
        }
        tasks.removeAll { $0.projectId == id }
        projects.removeAll { $0.id == id }
    }

    /// Moves the project to `index` (clamped) of `projects`.
    public mutating func moveProject(id: UUID, to index: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }) else { return }
        let project = projects.remove(at: from)
        projects.insert(project, at: min(max(index, 0), projects.count))
    }

    /// Remembers the last choice from the new-task sheet; a nil `base` keeps the previous one.
    public mutating func rememberNewTaskChoice(projectId: UUID, worktree: Bool, base: String?) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].worktreeByDefault = worktree
        if let base { projects[i].lastBaseBranch = base }
    }

    /// Blank entries are dropped; nil = the default (list or command), an empty list / blank command = none.
    public mutating func setWorktreeSetup(id: UUID, copy: [String]?, command: String?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].worktreeCopy = copy?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        projects[i].setupCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Blank name keeps the old one; nil `baseBranch` = automatic (from origin/HEAD), stored as is; blank `worktreeRoot` resets to default (nil).
    /// A new path also moves the cwd of main-folder tasks' leaves that sat in the old path.
    public mutating func updateProject(id: UUID, name: String, path: String, baseBranch: String?, worktreeRoot: String?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        renameProject(id: id, name: name)
        projects[i].lastBaseBranch = baseBranch
        let root = worktreeRoot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        projects[i].worktreeRoot = root.isEmpty ? nil : root
        let old = projects[i].path
        guard !path.isEmpty, path != old else { return }
        projects[i].location = projects[i].host.map { .ssh(host: $0, path: path) } ?? .local(path: path)
        for t in tasks.indices where tasks[t].projectId == id && tasks[t].mode == .mainFolder {
            for tab in tasks[t].tabs.indices {
                tasks[t].tabs[tab].root = tasks[t].tabs[tab].root.mapLeaves { leaf in
                    var leaf = leaf
                    if leaf.cwd == old { leaf.cwd = path }
                    return leaf
                }
            }
            if tasks[t].drawer.leaf?.cwd == old { tasks[t].drawer.leaf?.cwd = path }
        }
    }

    /// Session id captured from the agent's hooks (restore uses `--resume <id>`); unknown leaf ids are ignored.
    public mutating func setAgentSessionId(leafId: UUID, _ id: String) {
        for i in tasks.indices {
            if tasks[i].drawer.leaf?.id == leafId { tasks[i].drawer.leaf?.agentSessionId = id; return }
            for t in tasks[i].tabs.indices where tasks[i].tabs[t].root.leaf(id: leafId) != nil {
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { leaf in
                    var leaf = leaf
                    if leaf.id == leafId { leaf.agentSessionId = id }
                    return leaf
                }
                return
            }
        }
    }

    /// Points an editor leaf at another file and line; unknown leaf ids are ignored.
    public mutating func setOpenFile(leafId: UUID, path: String, line: Int?) {
        for i in tasks.indices {
            if tasks[i].drawer.leaf?.id == leafId {
                tasks[i].drawer.leaf?.openFile = path; tasks[i].drawer.leaf?.openLine = line; return
            }
            for t in tasks[i].tabs.indices where tasks[i].tabs[t].root.leaf(id: leafId) != nil {
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { leaf in
                    var leaf = leaf
                    if leaf.id == leafId { leaf.openFile = path; leaf.openLine = line }
                    return leaf
                }
                return
            }
        }
    }

    /// Follows the real keyboard focus (click into a pane); leaves of other tabs are ignored.
    public mutating func setFocusedLeaf(taskId: UUID, tabId: UUID, leafId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }),
              tasks[i].tabs[t].root.leaf(id: leafId) != nil else { return }
        tasks[i].tabs[t].focusedLeafId = leafId
    }
}
