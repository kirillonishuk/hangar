import Foundation
import Git
import Workspace

/// Live HEAD of each chat's folder (branch, or short hash when detached) for the branch button and the sidebar
/// (decision #114). Loaded when a chat first shows; reloaded on the inspector's status loads, the selected chat's
/// HEAD file events, `done` events, the host connecting and after a switch — no polling. Coming back to the window
/// reloads only the selected and on-screen chats, at most every `focusInterval`. One git call per folder
/// (host + path) at a time, shared by its chats; a refresh during it reruns once. A failed load keeps the last value.
@MainActor @Observable final class BranchModel {
    typealias Load = @MainActor () async -> Head?
    static let focusInterval: TimeInterval = 5

    private(set) var heads: [UUID: Head] = [:]
    /// Chats shown at least once: events reload only these.
    @ObservationIgnored private(set) var requested: Set<UUID> = []
    /// Chats on screen now (rows report appear / disappear): with the selected one, what a window focus reloads.
    @ObservationIgnored private(set) var shown: Set<UUID> = []
    @ObservationIgnored var lastFocusRefresh: Date?
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: [String: (ids: [UUID], load: Load)] = [:]

    /// Returns true the first time the chat shows.
    func show(_ id: UUID) -> Bool {
        shown.insert(id)
        return request(id)
    }

    /// Events reload it from now on; true the first time.
    func request(_ id: UUID) -> Bool { requested.insert(id).inserted }

    func hide(_ id: UUID) { shown.remove(id) }

    /// Loads `folder` once for all `ids`, or once more after the load in flight.
    func refresh(folder: String, ids: [UUID], load: @escaping Load) {
        guard !ids.isEmpty else { return }
        if loads[folder] != nil { again[folder] = (ids, load) } else { start(folder, ids, load) }
    }

    /// Tests: waits until nothing loads.
    func idle() async {
        while let task = loads.values.first { await task.value }
    }

    private func start(_ folder: String, _ ids: [UUID], _ load: @escaping Load) {
        loads[folder] = Task { [weak self] in
            let head = await load()
            guard let self else { return }
            if let head { for id in ids where self.heads[id] != head { self.heads[id] = head } }
            self.loads[folder] = nil
            if let next = self.again.removeValue(forKey: folder) { self.start(folder, next.ids, next.load) }
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

    /// The chat's branch is on screen: its HEAD loads the first time.
    func requestHead(_ task: HangarTask) {
        if branchModel.show(task.id) { refreshHead(taskId: task.id) }
    }

    /// The chat is selected (the toolbar's branch button): its HEAD loads now, whatever was loaded before.
    func selectedHead(_ task: HangarTask) {
        _ = branchModel.request(task.id)
        refreshHead(taskId: task.id)
    }

    /// Its row left the screen: a window focus no longer reloads it.
    func hideHead(_ task: HangarTask) { branchModel.hide(task.id) }

    /// HEAD of this chat's folder may have moved: one load for every shown chat in the same folder.
    func refreshHead(taskId: UUID) {
        guard let folder = headFolder(taskId) else { return }
        refreshHeads(folders: [folder])
    }

    func refreshHead(ofLeaf leaf: UUID) {
        let task = state.tasks.first { t in t.tabs.contains { $0.root.leaf(id: leaf) != nil } || t.drawer.leaf?.id == leaf }
        if let task { refreshHead(taskId: task.id) }
    }

    /// Back to the window: the selected and on-screen chats (a remote one only while its host is connected),
    /// once per folder, at most every `focusInterval`.
    func refreshHeadsOnFocus(now: Date = Date()) {
        if let last = branchModel.lastFocusRefresh, now.timeIntervalSince(last) < BranchModel.focusInterval { return }
        branchModel.lastFocusRefresh = now
        let ids = branchModel.shown.union(state.selectedTaskId.map { [$0] } ?? [])
        refreshHeads(folders: Set(ids.compactMap { id in
            guard let folder = headFolder(id) else { return nil }
            if let host = folder.host, remote.hosts[host]?.state != .connected { return nil }
            return folder
        }))
    }

    /// The host is (re)connected: its chats' HEADs load again.
    func refreshHeads(host: String) {
        refreshHeads(folders: Set(branchModel.requested.compactMap { id in headFolder(id).flatMap { $0.host == host ? $0 : nil } }))
    }

    private struct HeadFolder: Hashable {
        var projectId: UUID
        var host: String?
        var path: String
        var key: String { (host ?? "") + "\0" + path }
    }

    private func headFolder(_ id: UUID) -> HeadFolder? {
        guard let task = state.tasks.first(where: { $0.id == id }), !task.archived, let project = project(task.projectId),
              let path = path(of: .task(id)) else { return nil }
        return HeadFolder(projectId: project.id, host: project.host, path: path)
    }

    private func refreshHeads(folders: Set<HeadFolder>) {
        guard !folders.isEmpty else { return }
        var ids: [HeadFolder: [UUID]] = [:]
        for id in branchModel.requested { if let f = headFolder(id), folders.contains(f) { ids[f, default: []].append(id) } }
        for (folder, chats) in ids {
            branchModel.refresh(folder: folder.key, ids: chats) { [weak self] in
                guard let self, let project = self.project(folder.projectId), self.isAvailable(project) else { return nil }
                return try? await self.git(for: project, repo: folder.path).head()
            }
        }
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
        await switchBranchError(of: task, to: branch).map { branchText($0, projectId: task.projectId) }
    }

    /// `git switch -c <name> [<start>]` in the chat's folder. nil when done, else the message for the user.
    func createBranch(of task: HangarTask, name: String, from start: String? = nil) async -> String? {
        await createBranchError(of: task, name: name, from: start).map { branchText($0, projectId: task.projectId) }
    }

    /// As `switchBranch`, the refusal kept as an error (the switcher shows «uncommitted changes» its own way).
    func switchBranchError(of task: HangarTask, to branch: Branch) async -> Error? {
        await branchAction(task) { try await $0.switchBranch(to: branch.name, isRemote: branch.isRemote) }
    }

    func createBranchError(of task: HangarTask, name: String, from start: String? = nil) async -> Error? {
        await branchAction(task) { try await $0.createBranch(name, from: start) }
    }

    private func branchAction(_ task: HangarTask, _ run: (Git) async throws -> Void) async -> Error? {
        defer { refreshHead(taskId: task.id) }
        do {
            try await run(try branchGit(task.id))
        } catch {
            return error
        }
        // A remote chat has no FSEvents: its inspector reloads the files and changes of the new branch now.
        if project(task.projectId)?.host != nil, inspector.shownTaskId == task.id {
            inspector.refresh(.all)
            gitPanel.refresh()
        }
        return nil
    }

    /// A refusal's text (#114), else git's own message.
    func branchText(_ error: Error, projectId: UUID) -> String {
        (error as? BranchSwitchError).map { branchMessage($0, projectId: projectId) } ?? error.localizedDescription
    }

    func branchMessage(_ e: BranchSwitchError, projectId: UUID) -> String {
        switch e {
        case .dirty(let n): L10n.branchDirty(L10n.fileCount(n)) + " " + L10n.branchDirtyHint
        case .checkedOutElsewhere(let branch, let path):
            chatName(at: path, projectId: projectId).map { L10n.branchCheckedOutInChat(branch, $0) } ?? L10n.branchCheckedOutAt(branch, path)
        case .wouldOverwriteIgnored(let paths):
            L10n.branchIgnoredOverwrite(paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? ", …" : ""))
        case .operationInProgress(let op): L10n.branchOperationInProgress(op)
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
}
