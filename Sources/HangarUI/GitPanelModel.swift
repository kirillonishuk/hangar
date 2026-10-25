import Foundation
import Git
import Observation

/// The Git tab of the visible session (redesign v1 §4): branches, the log in pages, the selected commit and the
/// diff of one of its files. Read-only. Loads only while the tab is on screen; a refresh meanwhile is remembered
/// and runs when it is shown. Another session cancels everything in flight; stale results are dropped.
@MainActor @Observable final class GitPanelModel {
    struct CommitDiff: Equatable {
        var hash: String
        var path: String
        var state: DiffState
    }

    struct AuthorCount: Equatable {
        var author: GitAuthor
        var count: Int
    }

    let pageSize: Int
    @ObservationIgnored private let textDebounce: Duration

    init(pageSize: Int = Git.defaultLogLimit, textDebounce: Duration = .milliseconds(250)) {
        self.pageSize = pageSize
        self.textDebounce = textDebounce
    }

    // MARK: State

    var query = GitQuery() {
        didSet { if query != oldValue { queryChanged(debounce: query.text != oldValue.text) } }
    }
    private(set) var root: String?
    private(set) var branches: BranchList?
    private(set) var commits: [Commit] = []
    /// Lanes for `commits`; empty while narrowing filters hide the graph.
    private(set) var graph: [GraphRow] = []
    private(set) var showsGraph = true
    private(set) var hasMore = false
    /// The first page of this session and query arrived.
    private(set) var loaded = false
    /// When the list was loaded: row dates are relative to it (no clock ticking in the background).
    private(set) var loadedAt = Date()
    private(set) var error: String?
    /// The session's host is not connected: a calm notice, what was loaded stays.
    private(set) var offline = false
    private(set) var fetching = false
    private(set) var selected: String?
    private(set) var details: CommitDetails?
    private(set) var detailsError: String?
    private(set) var commitDiff: CommitDiff?
    /// Authors of the history loaded without an author filter, most commits first (the Author chip's list).
    private(set) var authors: [AuthorCount] = []
    /// The branch block: collapsed to the HEAD line by default.
    var branchesOpen = false
    var expanded: Set<String> = ["local"]

    /// The Git segment is the inspector's current one (the view's appear / disappear).
    var tabShown = false { didSet { if tabShown != oldValue { visibilityChanged() } } }
    /// The inspector and its window are on screen with a session (`InspectorWatch`).
    private(set) var onScreen = false
    var visible: Bool { tabShown && onScreen }

    /// Something still loading (tests await it); nil when idle.
    var loadTask: Task<Void, Never>? { logTask ?? detailsTask ?? diffTask ?? fetchTask }

    // MARK: Internals

    @ObservationIgnored private var git: @Sendable (String) -> Git = { Git(repo: $0) }
    @ObservationIgnored private var remote = false
    @ObservationIgnored private var taskId: UUID?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Bumped by every log start and by a session change: only the current load applies.
    @ObservationIgnored private var generation = 0
    /// A refresh came while hidden (or while a load ran): load again when possible.
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var authorCounts: [GitAuthor: Int] = [:]

    // MARK: Inputs

    /// `git`: git at a path on the session's machine (the host runner for a remote project).
    func show(taskId: UUID?, root: String?, git: @escaping @Sendable (String) -> Git, remote: Bool) {
        self.git = git
        self.remote = remote
        guard taskId != self.taskId || root != self.root else { refresh(); return }
        cancelAll()
        self.root = nil  // the query reset below must not start a load of the old session
        query = GitQuery()
        self.taskId = taskId
        self.root = root
        branches = nil
        commits = []
        graph = []
        hasMore = false
        loaded = false
        error = nil
        offline = false
        fetching = false
        selected = nil
        details = nil
        detailsError = nil
        commitDiff = nil
        authorCounts = [:]
        authors = []
        dirty = root != nil
        if visible { startLog(branches: true, keep: false) }
    }

    func setOnScreen(_ on: Bool) {
        guard on != onScreen else { return }
        onScreen = on
        visibilityChanged()
    }

    /// HEAD or refs moved, the window came back, an agent finished: reload branches and the log as far as paged.
    func refresh() {
        guard root != nil else { return }
        dirty = true
        if visible, logTask == nil { startLog(branches: true, keep: true) }
    }

    func loadMore() {
        guard visible, hasMore, logTask == nil, let root else { return }
        let gen = generation, skip = commits.count, limit = pageSize
        let filters = query.filters(now: Date()), git = self.git(root), remote = self.remote
        logTask = Task { [weak self] in
            let r = await Self.load(git: git, remote: remote, filters: filters, limit: limit, skip: skip, branches: false)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.logTask = nil
            self.applyPage(r, append: true)
            if self.dirty { self.startLog(branches: true, keep: true) }
        }
    }

    func select(_ hash: String?) {
        guard hash != selected else { return }
        detailsTask?.cancel()
        detailsTask = nil
        selected = hash
        details = nil
        detailsError = nil
        guard let hash, let root else { return }
        let git = self.git(root), remote = self.remote
        detailsTask = Task { [weak self] in
            let result: Result<CommitDetails, Error>
            do { result = .success(try await git.commit(hash: hash)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.selected == hash else { return }
            self.detailsTask = nil
            switch result {
            case .success(let d): self.details = d
            case .failure(let e):
                if remote, Self.isOffline(e) { self.offline = true } else { self.detailsError = Self.message(e) }
            }
        }
    }

    /// A file of the selected commit, for the diff tab.
    func loadDiff(hash: String, path: String, origPath: String?) {
        diffTask?.cancel()
        diffTask = nil
        commitDiff = CommitDiff(hash: hash, path: path, state: .loading)
        guard let root else { commitDiff?.state = .failed(L10n.diffUnavailable); return }
        let git = self.git(root), remote = self.remote
        diffTask = Task { [weak self] in
            let state: DiffState
            do { state = .loaded(try await git.commitFileDiff(hash: hash, path: path, origPath: origPath)) } catch {
                state = .failed(remote && Self.isOffline(error) ? L10n.diffUnavailable : Self.message(error))
            }
            guard let self, !Task.isCancelled, self.commitDiff?.hash == hash, self.commitDiff?.path == path else { return }
            self.diffTask = nil
            self.commitDiff?.state = state
        }
    }

    /// The loaded state of that file's diff; nil when another one (or none) is loaded.
    func diffState(hash: String, path: String) -> DiffState? {
        guard let d = commitDiff, d.hash == hash, d.path == path else { return nil }
        return d.state
    }

    /// «Обновить ветки»: `git fetch` of every remote the branch list knows, then a reload. The only network call.
    func fetch() {
        guard fetchTask == nil, let root, let remotes = branches?.remote else { return }
        let names = Set(remotes.compactMap { $0.name.split(separator: "/").first.map(String.init) }).sorted()
        guard !names.isEmpty else { return }
        fetching = true
        let git = self.git(root)
        fetchTask = Task { [weak self] in
            var failure: String?
            for name in names {
                do { try await git.fetch(remote: name) } catch { failure = Self.message(error) }
            }
            guard let self, !Task.isCancelled else { return }
            self.fetchTask = nil
            self.fetching = false
            if let failure { self.error = failure }
            self.refresh()
        }
    }

    // MARK: Loading

    private func visibilityChanged() {
        if visible, dirty, logTask == nil, root != nil { startLog(branches: true, keep: true) }
    }

    private func queryChanged(debounce: Bool) {
        guard root != nil else { return }
        logTask?.cancel()
        logTask = nil
        generation += 1
        dirty = true
        if visible { startLog(branches: branches == nil, keep: false, debounce: debounce) }
    }

    private func cancelAll() {
        for t in [logTask, detailsTask, diffTask, fetchTask] { t?.cancel() }
        logTask = nil; detailsTask = nil; diffTask = nil; fetchTask = nil
        generation += 1
    }

    /// `keep`: as many commits as are shown (a refresh must not cut the list back to one page).
    private func startLog(branches withBranches: Bool, keep: Bool, debounce: Bool = false) {
        guard let root else { return }
        logTask?.cancel()
        dirty = false
        generation += 1
        let gen = generation
        let limit = keep ? min(max(pageSize, commits.count), 10_000) : pageSize
        let filters = query.filters(now: Date()), git = self.git(root), remote = self.remote, wait = debounce ? textDebounce : .zero
        logTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            let r = await Self.load(git: git, remote: remote, filters: filters, limit: limit, skip: 0, branches: withBranches)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.logTask = nil
            self.applyPage(r, append: false)
            if self.dirty { self.startLog(branches: true, keep: true) }
        }
    }

    private struct LoadResult: Sendable {
        var branches: BranchList?
        var page: LogPage?
        var offline = false
        var error: String?
    }

    private nonisolated static func load(git: Git, remote: Bool, filters: LogFilters, limit: Int, skip: Int, branches: Bool) async -> LoadResult {
        var r = LoadResult()
        do {
            if branches { r.branches = try await git.branches() }
            r.page = try await git.log(limit: limit, skip: skip, filters: filters)
        } catch where remote && isOffline(error) {
            r.offline = true
        } catch {
            r.error = message(error)
        }
        return r
    }

    private func applyPage(_ r: LoadResult, append: Bool) {
        offline = r.offline
        if r.offline { return }
        error = r.error
        if let b = r.branches { branches = b }
        guard let page = r.page else { return }
        if append {
            // A commit shown twice (history rewritten between pages) would break the lanes and the list ids.
            let known = Set(commits.map(\.hash))
            commits += page.commits.filter { !known.contains($0.hash) }
        } else {
            commits = page.commits
            loadedAt = Date()
        }
        hasMore = page.hasMore
        loaded = true
        showsGraph = !query.hidesGraph
        graph = showsGraph ? layoutGraph(commits: commits) : []
        if query.author == nil, query.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if !append { authorCounts = [:] }
            for c in page.commits { authorCounts[GitAuthor(name: c.authorName, email: c.authorEmail), default: 0] += 1 }
            authors = authorCounts.map { AuthorCount(author: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.author.name < $1.author.name }
        }
    }

    /// The host, not git: not connected, or ssh's own failure (255) mid-call (as the inspector).
    private nonisolated static func isOffline(_ error: Error) -> Bool {
        error is RemoteHostError || (error as? GitError)?.status == 255
    }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
