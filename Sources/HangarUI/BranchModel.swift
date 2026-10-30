import Foundation
import Git
import Workspace

/// Live HEAD of each chat's folder (branch, or short hash when detached) for the branch button and the sidebar
/// (decision #114). Loaded when a chat first shows; reloaded on the inspector's status loads, the selected chat's
/// HEAD file events, `done` events, the window becoming key, the host connecting and after a switch — no polling.
/// One load per chat at a time; a refresh during it reruns once. A failed load keeps the last value.
@MainActor @Observable final class BranchModel {
    typealias Load = @MainActor () async -> Head?

    private(set) var heads: [UUID: Head] = [:]
    @ObservationIgnored private(set) var requested: Set<UUID> = []
    @ObservationIgnored private var loads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<UUID> = []

    /// First show: loads once.
    func request(_ id: UUID, load: @escaping Load) {
        guard requested.insert(id).inserted else { return }
        start(id, load)
    }

    /// Reloads a chat that was shown; others load when they show.
    func refresh(_ id: UUID, load: @escaping Load) {
        guard requested.contains(id) else { return }
        if loads[id] != nil { again.insert(id) } else { start(id, load) }
    }

    /// Tests: waits for the chat's load (and its rerun).
    func idle(_ id: UUID) async {
        while let task = loads[id] { await task.value }
    }

    private func start(_ id: UUID, _ load: @escaping Load) {
        loads[id] = Task { [weak self] in
            let head = await load()
            guard let self else { return }
            if let head, self.heads[id] != head { self.heads[id] = head }
            self.loads[id] = nil
            if self.again.remove(id) != nil { self.start(id, load) }
        }
    }
}

/// What the branch switcher shows for one chat (spec design-system §3.2).
struct BranchChoices: Equatable {
    var head: Head?
    /// Newest commit first.
    var local: [Branch]
    var remote: [Branch]
    /// `status --porcelain` entries: > 0 disables switching (a new branch at HEAD still works).
    var uncommitted: Int
    /// Branch → who has it checked out elsewhere: the chat's name, else the folder. Disabled in the list.
    var elsewhere: [String: String]
}

extension AppState {
    /// The chat's current branch or short hash; nil until loaded (or outside git).
    func head(of task: HangarTask) -> Head? { branchModel.heads[task.id] }

    /// The chat's branch is on screen: its HEAD loads once.
    func requestHead(_ task: HangarTask) { branchModel.request(task.id, load: headLoad(task.id)) }

    /// HEAD of this chat's folder may have moved: reloads it and every other chat in the same folder.
    func refreshHead(taskId: UUID) {
        guard let task = state.tasks.first(where: { $0.id == taskId }), let path = path(of: .task(taskId)) else { return }
        for t in state.tasks where t.projectId == task.projectId && !t.archived && self.path(of: .task(t.id)) == path {
            branchModel.refresh(t.id, load: headLoad(t.id))
        }
    }

    func refreshHead(ofLeaf leaf: UUID) {
        let task = state.tasks.first { t in t.tabs.contains { $0.root.leaf(id: leaf) != nil } || t.drawer.leaf?.id == leaf }
        if let task { refreshHead(taskId: task.id) }
    }

    /// Back to the window: any HEAD may have moved meanwhile.
    func refreshHeads() {
        for t in state.tasks where !t.archived { branchModel.refresh(t.id, load: headLoad(t.id)) }
    }

    /// The host is (re)connected: its chats' HEADs load again.
    func refreshHeads(host: String) {
        for t in state.tasks where !t.archived && project(t.projectId)?.host == host { branchModel.refresh(t.id, load: headLoad(t.id)) }
    }

    /// The switcher's lists; throws when git can't run (host not connected, not a repository).
    func branchChoices(of task: HangarTask) async throws -> BranchChoices {
        let git = try branchGit(task.id)
        async let head = git.head()
        async let all = git.listBranches()
        async let uncommitted = git.uncommittedCount()
        async let checkedOut = git.checkedOutBranches()
        let current = try await head
        var elsewhere: [String: String] = [:]
        for (branch, path) in try await checkedOut where current != .branch(branch) {
            elsewhere[branch] = chatName(at: path, projectId: task.projectId) ?? path
        }
        let branches = try await all
        return BranchChoices(head: current, local: branches.filter { !$0.isRemote }, remote: branches.filter(\.isRemote),
                             uncommitted: try await uncommitted, elsewhere: elsewhere)
    }

    /// `git switch` in the chat's folder (decision #114). nil when done, else the message for the user.
    func switchBranch(of task: HangarTask, to branch: Branch) async -> String? {
        await branchAction(task) { try await $0.switchBranch(to: branch.name, isRemote: branch.isRemote) }
    }

    /// `git switch -c <name> [<start>]` in the chat's folder. nil when done, else the message for the user.
    func createBranch(of task: HangarTask, name: String, from start: String? = nil) async -> String? {
        await branchAction(task) { try await $0.createBranch(name, from: start) }
    }

    private func branchAction(_ task: HangarTask, _ run: (Git) async throws -> Void) async -> String? {
        defer { refreshHead(taskId: task.id) }
        do {
            try await run(try branchGit(task.id))
            return nil
        } catch let e as BranchSwitchError {
            return branchMessage(e, projectId: task.projectId)
        } catch {
            return error.localizedDescription
        }
    }

    func branchMessage(_ e: BranchSwitchError, projectId: UUID) -> String {
        switch e {
        case .dirty(let n): L10n.branchDirty(L10n.fileCount(n)) + " " + L10n.branchDirtyHint
        case .checkedOutElsewhere(let branch, let path):
            chatName(at: path, projectId: projectId).map { L10n.branchCheckedOutInChat(branch, $0) } ?? L10n.branchCheckedOutAt(branch, path)
        case .invalidName: L10n.branchInvalid
        case .alreadyExists(let name): L10n.branchExists(name)
        }
    }

    /// The open chat of this project whose folder is `path` (git prints real paths; a local chat may keep a symlinked one).
    private func chatName(at path: String, projectId: UUID) -> String? {
        let local = project(projectId)?.host == nil
        let canonical: (String) -> String = { local ? realPath($0) : $0 }
        let target = canonical(path)
        return state.tasks.first { t in
            t.projectId == projectId && !t.archived && self.path(of: .task(t.id)).map(canonical) == target
        }?.name
    }

    private func branchGit(_ id: UUID) throws -> Git {
        guard let task = state.tasks.first(where: { $0.id == id }), let project = project(task.projectId),
              let path = path(of: .task(id)) else { throw CocoaError(.fileNoSuchFile) }
        return git(for: project, repo: path)
    }

    private func headLoad(_ id: UUID) -> BranchModel.Load {
        { [weak self] in
            guard let self, let task = self.state.tasks.first(where: { $0.id == id }), !task.archived,
                  let project = self.project(task.projectId), self.isAvailable(project),
                  let git = try? self.branchGit(id) else { return nil }
            return try? await git.head()
        }
    }
}
