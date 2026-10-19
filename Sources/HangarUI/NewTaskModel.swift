import Foundation
import Git
import Observation
import Workspace

/// Logic of the new-task sheet: worktree toggle, base branch, background fetch, branch validation, worktree creation.
/// git runs only on open (`load`), on ↻ (`refresh`) and before create; no timers.
@MainActor @Observable final class NewTaskModel {
    enum Availability: Equatable { case loading, notRepository, noCommits, ready }
    enum FetchState: Equatable { case idle, running, done, failed(String), cancelled, noRemote }

    var name = "" {
        didSet { if !branchEdited { suggestBranch() } }
    }
    /// Follows the slug of `name` until the user edits it; clearing it makes it follow again.
    var branch = "" {
        didSet { if !suggesting { branchEdited = !branch.isEmpty } }
    }
    var worktree: Bool
    var base: String?
    private(set) var branches: [Branch] = []
    private(set) var defaultBase: String?
    private(set) var currentBranch: String?
    private(set) var availability = Availability.loading
    private(set) var fetch = FetchState.idle
    private(set) var lastFetch: Date?
    private(set) var branchError: String?
    /// git's stderr of a failed `worktree add`.
    private(set) var createError: String?
    private(set) var creating = false
    let taskBranches: Set<String>

    @ObservationIgnored private let project: Project
    @ObservationIgnored private let git: Git
    @ObservationIgnored private var remotes: [String] = []
    @ObservationIgnored private var branchEdited = false
    @ObservationIgnored private var suggesting = false
    /// A fetch finished `.done` since the sheet opened: create doesn't fetch again.
    @ObservationIgnored private var fetchedThisOpen = false
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Identifies the current fetch; a cancelled one finishing later is ignored.
    @ObservationIgnored private var fetchId: UUID?
    @ObservationIgnored private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    init(project: Project, git: Git, taskBranches: Set<String>) {
        self.project = project
        self.git = git
        self.taskBranches = taskBranches
        worktree = project.worktreeByDefault
    }

    var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !creating else { return false }
        return !worktree || (availability == .ready && base != nil && branchError == nil)
    }

    func load() async {
        availability = .loading
        guard await git.isRepository() else {
            availability = .notRepository
            worktree = false
            return
        }
        guard await git.hasCommits() else {
            availability = .noCommits
            return
        }
        branches = (try? await git.listBranches()) ?? []
        defaultBase = try? await git.defaultBranch()
        currentBranch = try? await git.currentBranch()
        remotes = (try? await git.remotes()) ?? []
        lastFetch = await git.lastFetch()
        if let last = project.lastBaseBranch, branches.contains(where: { $0.name == last }) {
            base = last
        } else {
            base = defaultBase
        }
        availability = .ready
        if !branchEdited { suggestBranch() }
        await refresh()
    }

    /// Fetches the base's remote, then rereads branches. Returns at once if a fetch is already running.
    func refresh() async {
        guard availability == .ready, fetch != .running else { return }
        guard let remote = remoteOfBase() else {
            fetch = .noRemote
            return
        }
        fetch = .running
        let id = UUID()
        fetchId = id
        fetchTask = Task { [git] in
            var failure: String?
            do { try await git.fetch(remote: remote) } catch {
                failure = (error as? GitError)?.errorDescription ?? error.localizedDescription
            }
            await self.fetchFinished(id, failure: failure)
        }
        await fetchSettled()
    }

    /// Doesn't wait for git: a killed fetch's helpers (ssh, remote-ext) may hold its pipes open for a while.
    func cancelFetch() {
        guard fetch == .running else { return }
        fetchTask?.cancel()
        fetchTask = nil
        fetchId = nil
        fetch = .cancelled
        resumeFetchWaiters()
    }

    func validateBranch() async {
        branchError = await branchProblem()
    }

    /// nil keeps the sheet open: fetch failed/cancelled (offer «Create without fetch»), bad branch, or git error.
    func create(skipFetch: Bool) async -> TaskMode? {
        guard canCreate else { return nil }
        guard worktree else { return .mainFolder }
        creating = true
        defer { creating = false }
        createError = nil
        if !skipFetch, !fetchedThisOpen {
            if fetch == .running { await fetchSettled() } else { await refresh() }
            switch fetch {
            case .failed, .cancelled: return nil
            default: break
            }
        }
        await validateBranch()
        guard branchError == nil, let base else { return nil }
        let path = worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: branch)
        do {
            try await git.addWorktree(path: path, newBranch: branch, base: base)
        } catch {
            createError = (error as? GitError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        return .worktree(path: path, branch: branch, base: base)
    }

    // MARK: Private

    private func fetchFinished(_ id: UUID, failure: String?) async {
        guard fetchId == id else { return }
        if let failure {
            fetch = .failed(failure)
        } else {
            branches = (try? await git.listBranches()) ?? branches
            lastFetch = await git.lastFetch()
            guard fetchId == id else { return }
            fetchedThisOpen = true
            fetch = .done
            if !branchEdited { suggestBranch() }
        }
        fetchTask = nil
        fetchId = nil
        resumeFetchWaiters()
    }

    private func fetchSettled() async {
        guard fetch == .running else { return }
        await withCheckedContinuation { fetchWaiters.append($0) }
    }

    private func resumeFetchWaiters() {
        let waiters = fetchWaiters
        fetchWaiters = []
        for w in waiters { w.resume() }
    }

    /// `origin/x` → `origin`; a local base → `origin` if the repo has it; otherwise nil (nothing to fetch).
    private func remoteOfBase() -> String? {
        guard let base else { return nil }
        if let r = remotes.first(where: { base.hasPrefix($0 + "/") }) { return r }
        return remotes.contains("origin") ? "origin" : nil
    }

    private func branchProblem() async -> String? {
        if branch.isEmpty { return L10n.branchRequired }
        if await !git.isValidBranchName(branch) { return L10n.branchInvalid }
        if branches.contains(where: { !$0.isRemote && $0.name == branch }) { return L10n.branchExists(branch) }
        return nil
    }

    /// Slug of `name`; if that branch (local, or remote of the same name) or its worktree folder exists, `-2`, `-3`, …
    private func suggestBranch() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var suggestion = ""
        if !trimmed.isEmpty {
            let slug = branchSlug(trimmed)
            let taken = Set(branches.map { b in
                guard b.isRemote, let r = remotes.first(where: { b.name.hasPrefix($0 + "/") }) else { return b.name }
                return String(b.name.dropFirst(r.count + 1))
            })
            suggestion = slug
            var n = 1
            while taken.contains(suggestion) || FileManager.default.fileExists(
                atPath: worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: suggestion)) {
                n += 1
                suggestion = "\(slug)-\(n)"
            }
        }
        suggesting = true
        branch = suggestion
        suggesting = false
        branchError = nil
    }
}
