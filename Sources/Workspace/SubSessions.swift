import Foundation

/// Sub-sessions (spec sub-sessions §2): a chat spawned by another chat's agent, kept under it in the sidebar.
extension WorkspaceState {
    /// Open children of `parent`, in their `order`.
    public func subSessions(of parent: UUID) -> [HangarTask] {
        tasks.filter { $0.parentTaskId == parent && !$0.archived }.sorted { $0.order < $1.order }
    }

    /// Shown under its parent: the parent exists and is open (else it stands at the top level).
    public func hasLiveParent(_ task: HangarTask) -> Bool {
        guard let parent = task.parentTaskId else { return false }
        return tasks.contains { $0.id == parent && !$0.archived }
    }

    /// A sub-session in the parent's project (main folder or `mode`), or for a chat without a project a new such chat.
    /// One `kind` tab; the selection is not changed. nil — no such parent.
    public mutating func addSubSession(parent: UUID, name: String, kind: LeafKind, mode: TaskMode = .mainFolder,
                                       at date: Date = Date()) -> (task: UUID, tab: UUID)? {
        guard let p = tasks.first(where: { $0.id == parent }) else { return nil }
        let selected = selectedTaskId
        let task: UUID
        if isFreeChatTask(p) {
            task = addFreeChatTask(name: name, autoNamed: false, at: date)
            selectedTaskId = selected
        } else {
            task = addTask(projectId: p.projectId, name: name, mode: mode)
        }
        guard let i = tasks.firstIndex(where: { $0.id == task }) else { return nil }
        tasks[i].parentTaskId = parent
        return (task, addTab(taskId: task, kind: kind))
    }

    public mutating func setSubsCollapsed(taskId: UUID, _ collapsed: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[i].subsCollapsed = collapsed
    }

    /// `tops` with their open, unpinned sub-sessions (recursively) right after each, as (task, depth). A child whose parent
    /// is among `tops` moves under it; one whose parent is not listed (archived, pinned elsewhere) stays at the top level.
    public func withSubSessions(_ tops: [HangarTask], expandedOnly: Bool = true) -> [(task: HangarTask, depth: Int)] {
        let listed = Set(tops.map(\.id))
        let nested = Set(tops.filter { t in !t.pinned && t.parentTaskId.map(listed.contains) == true }.map(\.id))
        var out: [(HangarTask, Int)] = []
        var seen = Set<UUID>()
        func add(_ t: HangarTask, _ depth: Int) {
            guard seen.insert(t.id).inserted else { return }
            out.append((t, depth))
            if expandedOnly && t.subsCollapsed { return }
            // An asleep chat without a project is archived but still listed: it stays under its parent too.
            let children = tasks.filter { $0.parentTaskId == t.id && !$0.pinned && (!$0.archived || listed.contains($0.id)) }
            for child in children.sorted(by: { $0.order < $1.order }) { add(child, depth + 1) }
        }
        for t in tops where !nested.contains(t.id) { add(t, 0) }
        return out
    }
}
