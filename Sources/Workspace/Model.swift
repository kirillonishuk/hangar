import Foundation

public enum Location: Codable, Equatable, Sendable {
    case local(path: String)
    case ssh(host: String, path: String)
}

/// Which attention reasons of a project raise notifications: everything, only urgent ones, nothing.
public enum ProjectNotifications: String, Codable, Sendable, CaseIterable { case all, urgent, off }

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
    public var notifications: ProjectNotifications = .all

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
        case id, name, location, lastBaseBranch, collapsed, worktreeByDefault, worktreeRoot, worktreeCopy, setupCommand, notifications
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
        notifications = try c.decodeIfPresent(ProjectNotifications.self, forKey: .notifications) ?? .all
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

/// `choose` is a pane that runs nothing yet: the user picks its kind. It is never saved (`prunedChoosers`).
public enum LeafKind: String, Codable, Equatable, Sendable { case claude, codex, editor, shell, choose }

/// The side of a pane a dragged/new pane is inserted at.
public enum SplitEdge: String, Codable, Equatable, Sendable {
    case left, right, top, bottom

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// The new pane goes first (left/top).
    public var isFirst: Bool { self == .left || self == .top }
}

public struct Leaf: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: LeafKind
    public var cwd: String
    public var agentSessionId: String?
    /// The editor's active file.
    public var openFile: String?
    /// Files open in an editor tab (Monaco, #80), in tab order; `openFile` is the active one.
    public var editorFiles: [EditorFile]?
    /// Set by the user (rename); wins over the automatic pane name.
    public var customTitle: String?

    /// `openLine`: the new editor's cursor line in `openFile`.
    public init(id: UUID = UUID(), kind: LeafKind, cwd: String, agentSessionId: String? = nil,
                openFile: String? = nil, openLine: Int? = nil) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.agentSessionId = agentSessionId
        self.openFile = openFile
        if kind == .editor, let openFile { editorFiles = [EditorFile(path: openFile, line: openLine ?? 1, column: 1)] }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, cwd, agentSessionId, openFile, editorFiles, openLine, customTitle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: try c.decode(LeafKind.self, forKey: .kind),
                  cwd: try c.decode(String.self, forKey: .cwd),
                  agentSessionId: try c.decodeIfPresent(String.self, forKey: .agentSessionId),
                  // A Helix-era editor leaf (decision #81): `openFile` + `openLine` become its one file tab.
                  openFile: try c.decodeIfPresent(String.self, forKey: .openFile),
                  openLine: try c.decodeIfPresent(Int.self, forKey: .openLine))
        if let files = try c.decodeIfPresent([EditorFile].self, forKey: .editorFiles) { editorFiles = files }
        // An editor pane is named by its file: a name from a version that allowed renaming it is dropped.
        if kind != .editor { customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try c.encodeIfPresent(openFile, forKey: .openFile)
        try c.encodeIfPresent(editorFiles, forKey: .editorFiles)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
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

    /// The leaf `anchor` becomes a split of itself and `node`, `node` on the `edge` side.
    func inserting(_ node: SplitNode, at anchor: UUID, edge: SplitEdge) -> SplitNode {
        switch self {
        case .leaf(let leaf):
            guard leaf.id == anchor else { return self }
            return .split(axis: edge.axis, ratio: 0.5, first: edge.isFirst ? node : self, second: edge.isFirst ? self : node)
        case .split(let a, let ratio, let first, let second):
            return .split(axis: a, ratio: ratio, first: first.inserting(node, at: anchor, edge: edge),
                          second: second.inserting(node, at: anchor, edge: edge))
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
    /// A file opened with one click (Files): the next such open reuses this tab, until it is edited or opened for real (#83).
    public var preview: Bool = false

    public init(id: UUID = UUID(), title: String, root: SplitNode, focusedLeafId: UUID, customTitle: String? = nil) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedLeafId = focusedLeafId
        self.customTitle = customTitle
    }

    private enum CodingKeys: String, CodingKey { case id, title, root, focusedLeafId, customTitle, preview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  root: try c.decode(SplitNode.self, forKey: .root), focusedLeafId: try c.decode(UUID.self, forKey: .focusedLeafId),
                  customTitle: try c.decodeIfPresent(String.self, forKey: .customTitle))
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        // A file tab is named by its file (as its pane): an old rename is dropped.
        if case .leaf(let leaf) = root, leaf.kind == .editor { customTitle = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(root, forKey: .root)
        try c.encode(focusedLeafId, forKey: .focusedLeafId)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        if preview { try c.encode(true, forKey: .preview) }
    }

    public func label(auto: String) -> String { customTitle ?? auto }

    public var editorCount: Int { root.leaves.filter { $0.kind == .editor }.count }
    /// Editor panes one tab can hold.
    public static let maxEditorPanes = 2
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
    /// `HANGAR_PORT` of its tabs (#60); set when the task is added or an older state loads.
    public var port: Int?
    /// When it was closed (archived); nil while open and for sessions closed before this was recorded.
    public var archivedAt: Date?
    /// Its `+N −M` against the base when the worktree was closed; nil when unknown.
    public var archivedChanges: LineChanges?
    /// Notifications of this session are muted.
    public var muted = false
    /// Named «Чат N» for want of a name or message (#116): the first prompt of its agent names it; any rename clears it.
    public var autoNamed = false

    /// Branch of a worktree task; nil for main-folder tasks.
    public var branch: String? {
        if case .worktree(_, let branch, _) = mode { return branch }
        return nil
    }

    public init(id: UUID = UUID(), projectId: UUID, name: String, mode: TaskMode = .mainFolder,
                order: Int, archived: Bool = false, tabs: [Tab] = [], activeTabId: UUID? = nil, pinned: Bool = false,
                drawer: Drawer = Drawer(), port: Int? = nil) {
        self.id = id
        self.projectId = projectId
        self.port = port
        self.name = name
        self.mode = mode
        self.order = order
        self.archived = archived
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.pinned = pinned
        self.drawer = drawer
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, mode, order, archived, tabs, activeTabId, pinned, drawer, port, archivedAt, archivedChanges, muted
        case autoNamed
    }

    /// `pinned`, `drawer`, `port` and the `archived…` details were added later; older files decode with the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), projectId: try c.decode(UUID.self, forKey: .projectId),
                  name: try c.decode(String.self, forKey: .name), mode: try c.decode(TaskMode.self, forKey: .mode),
                  order: try c.decode(Int.self, forKey: .order), archived: try c.decode(Bool.self, forKey: .archived),
                  tabs: try c.decode([Tab].self, forKey: .tabs),
                  activeTabId: try c.decodeIfPresent(UUID.self, forKey: .activeTabId),
                  pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
                  drawer: try c.decodeIfPresent(Drawer.self, forKey: .drawer) ?? Drawer(),
                  port: try c.decodeIfPresent(Int.self, forKey: .port))
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        archivedChanges = try c.decodeIfPresent(LineChanges.self, forKey: .archivedChanges)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        autoNamed = try c.decodeIfPresent(Bool.self, forKey: .autoNamed) ?? false
    }
}

/// Added / deleted line counts of a diff.
public struct LineChanges: Codable, Equatable, Sendable {
    public var added: Int
    public var deleted: Int

    public init(added: Int, deleted: Int) { self.added = added; self.deleted = deleted }
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
    /// Plain ssh logins without a project (#64); their tasks sit in `tasks` with the shell's id as `projectId`.
    public var hostShells: [HostShell]
    /// Sidebar «Требуют внимания»: only waiting/failed tasks (#67).
    public var attentionOnly: Bool
    /// Diff tab: inline instead of side by side (#80).
    public var diffInline: Bool = false
    /// Editor tabs show the minimap (#80; off by default).
    public var editorMinimap: Bool = false

    public init(projects: [Project] = [], tasks: [HangarTask] = [],
                selectedTaskId: UUID? = nil, inspectorVisible: Bool = false,
                sidebarWidth: Double = 256, sidebarCollapsed: Bool = false, inspectorWidth: Double = 320,
                hostShells: [HostShell] = [], attentionOnly: Bool = false) {
        self.projects = projects
        self.hostShells = hostShells
        self.tasks = tasks
        self.selectedTaskId = selectedTaskId
        self.inspectorVisible = inspectorVisible
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.inspectorWidth = inspectorWidth
        self.attentionOnly = attentionOnly
    }

    private enum CodingKeys: String, CodingKey {
        case projects, tasks, selectedTaskId, inspectorVisible, sidebarWidth, sidebarCollapsed, inspectorWidth, hostShells
        case attentionOnly, diffInline, editorMinimap
    }

    /// Keys added after the first release decode with defaults so older state.json files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projects: try c.decode([Project].self, forKey: .projects),
                  tasks: try c.decode([HangarTask].self, forKey: .tasks),
                  selectedTaskId: try c.decodeIfPresent(UUID.self, forKey: .selectedTaskId),
                  inspectorVisible: try c.decode(Bool.self, forKey: .inspectorVisible),
                  sidebarWidth: try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 256,
                  sidebarCollapsed: try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false,
                  inspectorWidth: try c.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 320,
                  hostShells: try c.decodeIfPresent([HostShell].self, forKey: .hostShells) ?? [],
                  attentionOnly: try c.decodeIfPresent(Bool.self, forKey: .attentionOnly) ?? false)
        diffInline = try c.decodeIfPresent(Bool.self, forKey: .diffInline) ?? false
        editorMinimap = try c.decodeIfPresent(Bool.self, forKey: .editorMinimap) ?? false
        assignMissingPorts()
        splitEditorTabs()
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
        var task = HangarTask(projectId: projectId, name: name, mode: mode, order: order)
        task.port = taskPort(for: task.id, taken: Set(tasks.compactMap(\.port)))
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

    /// The closed worktree's `+N −M`, measured just before its folder went away.
    public mutating func setArchivedChanges(id: UUID, _ changes: LineChanges) {
        guard let i = tasks.firstIndex(where: { $0.id == id && $0.archived }) else { return }
        tasks[i].archivedChanges = changes
    }

    public mutating func archiveTask(id: UUID, at date: Date = Date()) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].archived = true
        tasks[i].archivedAt = date
        tasks[i].archivedChanges = nil
        if selectedTaskId == id { selectedTaskId = nil }
    }

    // MARK: Tabs / leaves

    func cwd(for task: HangarTask) -> String {
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

    /// A tab resuming conversation `sessionId` in its own `cwd` (history «Сессии»); nil in a host's terminal (ssh shells only).
    @discardableResult
    public mutating func addResumeTab(taskId: UUID, kind: LeafKind, cwd: String, sessionId: String) -> UUID? {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), !isHostShellTask(tasks[i]) else { return nil }
        let leaf = Leaf(kind: kind, cwd: cwd, agentSessionId: sessionId)
        let tab = Tab(title: kind.rawValue, root: .leaf(leaf), focusedLeafId: leaf.id)
        tasks[i].tabs.append(tab)
        tasks[i].activeTabId = tab.id
        return leaf.id
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
    /// `kind == nil` makes a chooser; a host's terminal always gets a shell; `first` puts the new leaf first.
    @discardableResult
    public mutating func split(taskId: UUID, tabId: UUID, leafId: UUID, axis: Axis, kind: LeafKind?, first: Bool = false) -> UUID {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }),
              tasks[i].tabs[t].root.leaf(id: leafId) != nil else {
            assertionFailure("split: unknown task, tab or leaf")
            return UUID()
        }
        let newLeaf = Leaf(kind: isHostShellTask(tasks[i]) ? .shell : kind ?? .choose, cwd: cwd(for: tasks[i]))
        tasks[i].tabs[t].root = tasks[i].tabs[t].root.inserting(
            .leaf(newLeaf), at: leafId, edge: axis == .horizontal ? (first ? .left : .right) : (first ? .top : .bottom))
        tasks[i].tabs[t].focusedLeafId = newLeaf.id
        tasks[i].tabs[t].preview = false  // a Files click replaces a preview tab's whole root: it must not take the new pane
        return newLeaf.id
    }

    /// A chooser leaf becomes `kind`, keeping its id. An editor needs a `file` not yet open in the session and a free editor slot;
    /// `resume` (an agent only) continues that conversation in its folder.
    @discardableResult
    public mutating func chooseKind(leafId: UUID, kind: LeafKind, file: String? = nil,
                                    resume: (cwd: String, sessionId: String)? = nil) -> Bool {
        guard kind != .choose, resume == nil || kind == .claude || kind == .codex else { return false }
        for i in tasks.indices {
            for t in tasks[i].tabs.indices where tasks[i].tabs[t].root.leaf(id: leafId)?.kind == .choose {
                if kind == .editor {
                    guard let file, fileTab(taskId: tasks[i].id, path: file) == nil,
                          tasks[i].tabs[t].editorCount < Tab.maxEditorPanes else { return false }
                }
                tasks[i].tabs[t].preview = false  // never a preview: its next Files click would replace the started pane
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { leaf in
                    guard leaf.id == leafId else { return leaf }
                    var leaf = leaf
                    leaf.kind = kind
                    if kind == .editor, let file {
                        leaf.openFile = file
                        leaf.editorFiles = [EditorFile(path: file, line: 1, column: 1)]
                    }
                    if let resume {
                        leaf.cwd = resume.cwd
                        leaf.agentSessionId = resume.sessionId
                    }
                    return leaf
                }
                return true
            }
        }
        return false
    }

    /// Removes chooser leaves like `closeLeaf` (a tab of only choosers goes); used so no chooser is ever saved or restored.
    public func prunedChoosers() -> WorkspaceState {
        var s = self
        for i in s.tasks.indices {
            // `tab` is a copy: closeLeaf mutates s.tasks[i].tabs (even removes tabs) while we iterate.
            for tab in s.tasks[i].tabs {
                for leaf in tab.root.leaves where leaf.kind == .choose {
                    s.closeLeaf(taskId: s.tasks[i].id, tabId: tab.id, leafId: leaf.id)
                }
            }
        }
        return s
    }

    /// Closing the last leaf closes the tab.
    public mutating func closeLeaf(taskId: UUID, tabId: UUID, leafId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard tasks[i].tabs[t].root.leaf(id: leafId) != nil else { return }
        if !dropLeaf(taskIndex: i, tabIndex: t, leafId: leafId) { closeTab(taskId: taskId, tabId: tabId) }
    }

    /// Removes the leaf from the tab and repairs focus (the neighbour at the same position). False, untouched, when it was the last leaf.
    private mutating func dropLeaf(taskIndex i: Int, tabIndex t: Int, leafId: UUID) -> Bool {
        let tab = tasks[i].tabs[t]
        guard let leafIndex = tab.root.leaves.firstIndex(where: { $0.id == leafId }),
              let rest = tab.root.removing(leafId: leafId) else { return false }
        tasks[i].tabs[t].root = rest
        if tab.focusedLeafId == leafId {
            let remaining = rest.leaves
            tasks[i].tabs[t].focusedLeafId = remaining[min(leafIndex, remaining.count - 1)].id
        }
        return true
    }

    // MARK: Merge, move, detach (splits)

    public func canMergeTab(taskId: UUID, source: UUID, into target: UUID) -> Bool {
        guard source != target, let task = tasks.first(where: { $0.id == taskId }),
              let s = task.tabs.first(where: { $0.id == source }),
              let t = task.tabs.first(where: { $0.id == target }) else { return false }
        return s.editorCount + t.editorCount <= Tab.maxEditorPanes
    }

    /// The whole `source` tab joins `target` next to its leaf `leafId`; `source` goes away, `target` loses preview.
    @discardableResult
    public mutating func mergeTab(taskId: UUID, source: UUID, into target: UUID, at leafId: UUID, edge: SplitEdge) -> Bool {
        guard canMergeTab(taskId: taskId, source: source, into: target),
              let i = tasks.firstIndex(where: { $0.id == taskId }),
              let s = tasks[i].tabs.firstIndex(where: { $0.id == source }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == target }),
              tasks[i].tabs[t].root.leaf(id: leafId) != nil else { return false }
        let src = tasks[i].tabs[s]
        var node = src.root
        // The tab's name moves onto its only pane.
        if case .leaf(var leaf) = node, leaf.customTitle == nil, let name = src.customTitle {
            leaf.customTitle = name
            node = .leaf(leaf)
        }
        tasks[i].tabs[t].root = tasks[i].tabs[t].root.inserting(node, at: leafId, edge: edge)
        tasks[i].tabs[t].focusedLeafId = src.focusedLeafId
        tasks[i].tabs[t].preview = false
        tasks[i].tabs.remove(at: s)
        tasks[i].activeTabId = target
        return true
    }

    public func canMoveLeaf(taskId: UUID, leafId: UUID, to target: UUID, anchor: UUID) -> Bool {
        guard anchor != leafId, let task = tasks.first(where: { $0.id == taskId }),
              let src = task.tabs.first(where: { $0.root.leaf(id: leafId) != nil }),
              let dst = task.tabs.first(where: { $0.id == target }), dst.root.leaf(id: anchor) != nil,
              let leaf = src.root.leaf(id: leafId) else { return false }
        if src.id == dst.id || leaf.kind != .editor { return true }
        return dst.editorCount + 1 <= Tab.maxEditorPanes
    }

    /// The pane leaves its tab (an emptied tab goes away) and lands next to `anchor` in `target`.
    @discardableResult
    public mutating func moveLeaf(taskId: UUID, leafId: UUID, to target: UUID, at anchor: UUID, edge: SplitEdge) -> Bool {
        guard canMoveLeaf(taskId: taskId, leafId: leafId, to: target, anchor: anchor),
              let i = tasks.firstIndex(where: { $0.id == taskId }),
              let s = tasks[i].tabs.firstIndex(where: { $0.root.leaf(id: leafId) != nil }),
              let leaf = tasks[i].tabs[s].root.leaf(id: leafId),
              tasks[i].tabs.contains(where: { $0.id == target }) else { return false }
        // Everything is validated: from here on nothing can fail, so no partial mutation.
        if !dropLeaf(taskIndex: i, tabIndex: s, leafId: leafId) { tasks[i].tabs.remove(at: s) }
        let t = tasks[i].tabs.firstIndex { $0.id == target }!
        tasks[i].tabs[t].root = tasks[i].tabs[t].root.inserting(.leaf(leaf), at: anchor, edge: edge)
        tasks[i].tabs[t].focusedLeafId = leafId
        tasks[i].tabs[t].preview = false
        tasks[i].activeTabId = target
        return true
    }

    /// A pane of a split tab becomes a tab of its own (named like the pane), right after its tab or at `toIndex`; returns the new tab.
    @discardableResult
    public mutating func detachLeaf(taskId: UUID, leafId: UUID, toIndex: Int?) -> UUID? {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let s = tasks[i].tabs.firstIndex(where: { $0.root.leaf(id: leafId) != nil }),
              case .split = tasks[i].tabs[s].root,
              let leaf = tasks[i].tabs[s].root.leaf(id: leafId),
              dropLeaf(taskIndex: i, tabIndex: s, leafId: leafId) else { return nil }
        let tab = Tab(title: leaf.kind.rawValue, root: .leaf(leaf), focusedLeafId: leaf.id, customTitle: leaf.customTitle)
        tasks[i].tabs.insert(tab, at: min(max(toIndex ?? s + 1, 0), tasks[i].tabs.count))
        tasks[i].activeTabId = tab.id
        return tab.id
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

    public mutating func setMuted(taskId: UUID, _ muted: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].muted = muted
    }

    public mutating func setProjectNotifications(projectId: UUID, _ value: ProjectNotifications) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].notifications = value
    }

    public mutating func setProjectCollapsed(id: UUID, _ collapsed: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].collapsed = collapsed
    }

    public mutating func restoreTask(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].archived = false
        tasks[i].archivedAt = nil
        tasks[i].archivedChanges = nil
    }

    /// Restore without its worktree (the branch is gone): a main-folder task whose leaves move from the worktree to the project.
    /// Session ids are dropped: the worktree's conversations don't belong in the project folder.
    public mutating func detachWorktree(taskId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), case .worktree(let path, _, _) = tasks[i].mode else { return }
        tasks[i].mode = .mainFolder
        let folder = cwd(for: tasks[i])
        func move(_ leaf: Leaf) -> Leaf {
            var leaf = leaf
            leaf.agentSessionId = nil
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
        tasks[i].autoNamed = false
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

    /// Trimmed; blank or nil goes back to the automatic name.
    public mutating func renameLeaf(leafId: UUID, title: String?) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in tasks.indices {
            for t in tasks[i].tabs.indices where tasks[i].tabs[t].root.leaf(id: leafId) != nil {
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { leaf in
                    var leaf = leaf
                    if leaf.id == leafId { leaf.customTitle = title?.isEmpty == false ? title : nil }
                    return leaf
                }
                return
            }
        }
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

    /// Follows the real keyboard focus (click into a pane); leaves of other tabs are ignored.
    public mutating func setFocusedLeaf(taskId: UUID, tabId: UUID, leafId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }),
              tasks[i].tabs[t].root.leaf(id: leafId) != nil else { return }
        tasks[i].tabs[t].focusedLeafId = leafId
    }
}
