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

    /// A sub-session in the parent's project, by default in the parent's own folder (its worktree or the main folder, #131),
    /// or in `mode` (a new worktree); for a chat without a project a new such chat (the same shared folder).
    /// One `kind` tab; the selection is not changed. nil — no such parent.
    public mutating func addSubSession(parent: UUID, name: String, kind: LeafKind, mode: TaskMode? = nil,
                                       at date: Date = Date()) -> (task: UUID, tab: UUID)? {
        guard let p = tasks.first(where: { $0.id == parent }) else { return nil }
        let selected = selectedTaskId
        let task: UUID
        if isFreeChatTask(p) {
            task = addFreeChatTask(name: name, autoNamed: false, at: date)
            selectedTaskId = selected
        } else {
            task = addTask(projectId: p.projectId, name: name, mode: mode ?? p.mode)
        }
        guard let i = tasks.firstIndex(where: { $0.id == task }) else { return nil }
        tasks[i].parentTaskId = parent
        return (task, addTab(taskId: task, kind: kind))
    }

    /// Other sessions working in `task`'s worktree folder (a sub-chat shares its parent's, #131): the same machine and the
    /// same folder, any project (one repo added twice, or this worktree added as a project of its own, whose main-folder
    /// sessions work there too). `openOnly`: archived ones are left out. Empty for a main-folder session.
    public func worktreeSharers(of task: HangarTask, openOnly: Bool) -> [HangarTask] {
        guard case .worktree(let path, _, _) = task.mode else { return [] }
        let host = projects.first { $0.id == task.projectId }?.host, key = worktreeKey(path)
        return tasks.filter { t in
            guard t.id != task.id, !(openOnly && t.archived), let project = projects.first(where: { $0.id == t.projectId }),
                  project.host == host else { return false }
            switch t.mode {
            case .worktree(let other, _, _): return worktreeKey(other) == key
            case .mainFolder: return worktreeKey(project.path) == key
            }
        }
    }

    /// Other sessions of `task`'s project keeping its worktree branch (open, or archived and waiting to check it out again).
    public func branchKeepers(of task: HangarTask) -> [HangarTask] {
        guard case .worktree(_, let branch, _) = task.mode else { return [] }
        return tasks.filter { t in
            guard t.id != task.id, t.projectId == task.projectId, case .worktree(_, branch, _) = t.mode else { return false }
            return true
        }
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

/// A folder path compared as a place: `.`/`..`, repeated and trailing slashes dropped, case folded (APFS ignores case by
/// default; folding on a case-sensitive server only ever keeps a folder that could have gone).
public func worktreeKey(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
        if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return ("/" + parts.joined(separator: "/")).lowercased()
}
