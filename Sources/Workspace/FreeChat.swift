import Foundation

/// A chat with no project: its one task runs in the shared `chatsFolder` and is kept out of `projects`, like a host's
/// terminal (#64). Open or asleep is the task's `archived`: asleep keeps its tabs and conversation ids.
public struct FreeChat: Codable, Identifiable, Equatable, Sendable {
    /// Its task's `projectId`.
    public var id: UUID
    /// Creation or the last prompt of its agent: the sidebar's order and time (never a selection, so rows don't jump).
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), lastUsedAt: Date) {
        self.id = id
        self.lastUsedAt = lastUsedAt
    }
}

extension WorkspaceState {
    public func freeChat(ofTask taskId: UUID) -> FreeChat? {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return nil }
        return freeChats.first { $0.id == task.projectId }
    }

    public func isFreeChatTask(_ task: HangarTask) -> Bool { freeChats.contains { $0.id == task.projectId } }

    /// Every chat without a project: pinned first, then the most recently used (ties by id, so the order is stable).
    public var freeChatTasks: [HangarTask] {
        let used = Dictionary(freeChats.map { ($0.id, $0.lastUsedAt) }, uniquingKeysWith: { a, _ in a })
        return tasks.filter { used[$0.projectId] != nil }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let ua = used[a.projectId]!, ub = used[b.projectId]!
            return ua != ub ? ua > ub : a.id.uuidString < b.id.uuidString
        }
    }

    /// A new chat with one `kind` tab in `chatsFolder`, selected.
    @discardableResult
    public mutating func addFreeChat(name: String, kind: LeafKind, autoNamed: Bool, at date: Date = Date()) -> (task: UUID, tab: UUID) {
        let task = addFreeChatTask(name: name, autoNamed: autoNamed, at: date)
        return (task, addTab(taskId: task, kind: kind))
    }

    /// The chat alone, selected, without tabs (History's «Продолжить» adds a resuming one).
    @discardableResult
    public mutating func addFreeChatTask(name: String, autoNamed: Bool, at date: Date = Date()) -> UUID {
        let chat = FreeChat(lastUsedAt: date)
        freeChats.append(chat)
        let task = addTask(projectId: chat.id, name: name)
        if autoNamed, let i = tasks.firstIndex(where: { $0.id == task }) { tasks[i].autoNamed = true }
        select(taskId: task)
        return task
    }

    public mutating func touchFreeChat(taskId: UUID, at date: Date = Date()) {
        guard let chat = freeChat(ofTask: taskId), let i = freeChats.firstIndex(where: { $0.id == chat.id }) else { return }
        freeChats[i].lastUsedAt = date
    }

    /// Its agents stop (the task is archived); tabs and conversation ids stay for the wake-up.
    public mutating func sleepFreeChat(taskId: UUID, at date: Date = Date()) {
        guard let task = tasks.first(where: { $0.id == taskId }), isFreeChatTask(task), !task.archived else { return }
        archiveTask(id: taskId, at: date)
    }

    public mutating func wakeFreeChat(taskId: UUID) {
        guard let task = tasks.first(where: { $0.id == taskId }), isFreeChatTask(task) else { return }
        restoreTask(id: taskId)
    }

    /// A build without chats without a project drops `freeChats` when it saves, but keeps their tasks under unknown ids.
    /// Such an orphan whose every agent ran in `chatsFolder` is a chat without a project again (asleep if it was closed);
    /// other orphans are left alone. Call once `chatsFolder` is set.
    public mutating func adoptOrphanFreeChats() {
        guard !chatsFolder.isEmpty else { return }
        let folder = chatsFolder.hasSuffix("/") ? String(chatsFolder.dropLast()) : chatsFolder
        let known = Set(projects.map(\.id)).union(freeChats.map(\.id)).union(hostShells.map(\.id))
        var adopted = Set<UUID>()
        for task in tasks where !known.contains(task.projectId) && !adopted.contains(task.projectId) {
            let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
            let cwds = leaves.map { $0.cwd.hasSuffix("/") ? String($0.cwd.dropLast()) : $0.cwd }
            guard !cwds.isEmpty, cwds.allSatisfy({ $0 == folder }),
                  tasks.filter({ $0.projectId == task.projectId }).count == 1 else { continue }
            freeChats.append(FreeChat(id: task.projectId, lastUsedAt: task.archivedAt ?? Date()))
            adopted.insert(task.projectId)
        }
    }

    /// Out of Hangar; the agent's transcript is never touched.
    public mutating func removeFreeChat(taskId: UUID) {
        guard let chat = freeChat(ofTask: taskId) else { return }
        if selectedTaskId == taskId { selectedTaskId = nil }
        tasks.removeAll { $0.projectId == chat.id }
        freeChats.removeAll { $0.id == chat.id }
    }
}
