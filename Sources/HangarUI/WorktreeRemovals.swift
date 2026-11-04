import Exec
import Foundation
import Git
import Observation
import Workspace

/// Worktree folders being removed (#132): each shows over the chat area while its folder goes (the risk check, the
/// rename aside, the background delete); a failure stays with «Повторить» until it succeeds or is dismissed.
@MainActor @Observable final class WorktreeRemovals {
    struct Item: Identifiable, Equatable {
        let id: UUID
        /// The chat's name, or the folder's for a leftover found at launch.
        let name: String
        /// Where the folder is now (the tombstone once moved aside): «Показать в Finder».
        var path: String
        /// On this Mac: Finder can show it.
        let local: Bool
        var failure: String?
        /// Visible only after `delay`, so a quick removal never flashes; a failure shows at once.
        var shown = false
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var retries: [UUID: @MainActor () -> Void] = [:]
    /// Folders between the last check and the end of their rename aside (host + `worktreeKey`): a restore or delete waits.
    @ObservationIgnored private var moving: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private let delay: TimeInterval
    /// Runs the show item after the delay (tests run it by hand).
    @ObservationIgnored private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    init(delay: TimeInterval = 0.4,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.delay = delay
        self.schedule = schedule
    }

    var visible: [Item] { items.filter(\.shown) }

    func begin(name: String, path: String, local: Bool) -> UUID {
        let id = UUID()
        items.append(Item(id: id, name: name, path: path, local: local))
        schedule(delay, DispatchWorkItem { [weak self] in self?.update(id) { $0.shown = true } })
        return id
    }

    func moved(_ id: UUID, to tomb: String) { update(id) { $0.path = tomb } }

    func finish(_ id: UUID) {
        items.removeAll { $0.id == id }
        retries[id] = nil
    }

    func fail(_ id: UUID, _ message: String, retry: @escaping @MainActor () -> Void) {
        retries[id] = retry
        update(id) { $0.failure = message; $0.shown = true }
    }

    /// Back to «Удаление…» and runs the step that failed again.
    func retry(_ id: UUID) {
        guard let again = retries.removeValue(forKey: id) else { return }
        update(id) { $0.failure = nil }
        again()
    }

    /// «×» on a failure: forgotten here; a tombstone left behind goes at the next launch.
    func dismiss(_ id: UUID) {
        guard items.first(where: { $0.id == id })?.failure != nil else { return }
        finish(id)
    }

    func startMoving(_ key: String) {
        if moving[key] == nil { moving[key] = [] }
    }

    func doneMoving(_ key: String) {
        moving.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    func isMoving(_ key: String) -> Bool { moving[key] != nil }

    /// Returns once `key` is not being moved aside (at once when it isn't).
    func untilMoved(_ key: String) async {
        guard moving[key] != nil else { return }
        await withCheckedContinuation { moving[key, default: []].append($0) }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}

/// The key `WorktreeRemovals` tracks a folder by: its machine and its place.
func removalKey(host: String?, path: String) -> String { (host ?? "") + ":" + worktreeKey(path) }

extension AppState {
    /// Moves a checked worktree folder aside and deletes it in the background, shown under `item` (begun here when nil).
    /// nil: the folder left its path; otherwise why it is still there, and the item shows that with «Повторить» (`retry`).
    @discardableResult
    func removeWorktree(_ path: String, name: String, host: String?, git: Git, runner: Runner, item: UUID? = nil,
                        retry: @escaping @MainActor () -> Void) async -> String? {
        let id = item ?? worktreeRemovals.begin(name: name, path: path, local: runner.isLocal)
        let key = removalKey(host: host, path: path)
        worktreeRemovals.startMoving(key)
        let tomb: String
        do {
            tomb = try await moveWorktreeAside(path, git: git, runner: runner)
        } catch {
            worktreeRemovals.doneMoving(key)
            worktreeRemovals.fail(id, error.localizedDescription, retry: retry)
            return error.localizedDescription
        }
        worktreeRemovals.doneMoving(key)
        worktreeRemovals.moved(id, to: tomb)
        Task { await deleteTombstoneTracked(tomb, item: id, runner: runner) }
        return nil
    }

    /// The background half: done → the item goes; failed → it stays with «Повторить» (delete again).
    func deleteTombstoneTracked(_ tomb: String, item id: UUID, runner: Runner) async {
        do {
            try await deleteTombstone(tomb, runner: runner)
            worktreeRemovals.finish(id)
        } catch {
            worktreeRemovals.fail(id, error.localizedDescription) { [weak self] in
                Task { await self?.deleteTombstoneTracked(tomb, item: id, runner: runner) }
            }
        }
    }
}
