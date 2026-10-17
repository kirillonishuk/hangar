import Foundation

public enum Location: Codable, Equatable, Sendable {
    case local(path: String)
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var location: Location
    public var lastBaseBranch: String?

    public init(id: UUID = UUID(), name: String, location: Location, lastBaseBranch: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.lastBaseBranch = lastBaseBranch
    }

    public var path: String {
        switch location { case .local(let path): return path }
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

    public init(id: UUID = UUID(), kind: LeafKind, cwd: String, agentSessionId: String? = nil, openFile: String? = nil) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.agentSessionId = agentSessionId
        self.openFile = openFile
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

    public init(id: UUID = UUID(), title: String, root: SplitNode, focusedLeafId: UUID) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedLeafId = focusedLeafId
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

    public init(id: UUID = UUID(), projectId: UUID, name: String, mode: TaskMode = .mainFolder,
                order: Int, archived: Bool = false, tabs: [Tab] = [], activeTabId: UUID? = nil) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.mode = mode
        self.order = order
        self.archived = archived
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [HangarTask]
    public var selectedTaskId: UUID?
    public var inspectorVisible: Bool

    public init(projects: [Project] = [], tasks: [HangarTask] = [],
                selectedTaskId: UUID? = nil, inspectorVisible: Bool = false) {
        self.projects = projects
        self.tasks = tasks
        self.selectedTaskId = selectedTaskId
        self.inspectorVisible = inspectorVisible
    }

    // MARK: Projects / tasks

    @discardableResult
    public mutating func addProject(name: String, path: String) -> UUID {
        let project = Project(name: name, location: .local(path: path))
        projects.append(project)
        return project.id
    }

    /// New tasks are `.mainFolder`; the worktree flow sets `mode` afterwards.
    @discardableResult
    public mutating func addTask(projectId: UUID, name: String) -> UUID {
        let order = (tasks.filter { $0.projectId == projectId }.map(\.order).max() ?? -1) + 1
        let task = HangarTask(projectId: projectId, name: name, order: order)
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
        visible.insert(visible.remove(at: from), at: min(max(index, 0), visible.count - 1))
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
    public mutating func addTab(taskId: UUID, kind: LeafKind) -> UUID {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else {
            assertionFailure("addTab: unknown task")
            return UUID()
        }
        let leaf = Leaf(kind: kind, cwd: cwd(for: tasks[i]))
        let tab = Tab(title: kind.rawValue, root: .leaf(leaf), focusedLeafId: leaf.id)
        tasks[i].tabs.append(tab)
        tasks[i].activeTabId = tab.id
        return tab.id
    }

    public mutating func closeTab(taskId: UUID, tabId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }),
              let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tasks[i].tabs.remove(at: t)
        guard tasks[i].activeTabId == tabId else { return }
        let tabs = tasks[i].tabs
        tasks[i].activeTabId = tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
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
        let newLeaf = Leaf(kind: kind, cwd: cwd(for: tasks[i]))
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
}
