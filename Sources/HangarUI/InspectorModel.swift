import Foundation
import Git
import Observation

enum DiffState: Equatable {
    case none, loading, loaded(FileDiff), notChanged, failed(String)
}

struct RefreshParts: OptionSet, Sendable {
    let rawValue: Int
    /// Badges, changes and the open diff.
    static let status = RefreshParts(rawValue: 1)
    /// `ls-files` (git) or the listed directories (plain folder).
    static let tree = RefreshParts(rawValue: 2)
    /// Only the open diff, against the loaded changes.
    static let diff = RefreshParts(rawValue: 4)
    static let all: RefreshParts = [.status, .tree]
}

/// Files and Changes of the visible task (decision #44). One load per context (task, root, mode) at a time:
/// a refresh during a load queues exactly one rerun; only a context change cancels; stale results are dropped.
@MainActor @Observable final class InspectorModel {
    enum Segment { case files, changes, git, search }
    enum ModeChoice { case base, uncommitted }

    var segment: Segment = .files
    /// The task's folder; every path of the inspector is relative to it.
    private(set) var root: String?
    private(set) var isGit = true
    private(set) var tree = FileTree()
    /// A listing of this root has been applied (an empty tree before it means «loading», not «empty»).
    private(set) var treeLoaded = false
    var expanded: Set<String> = []
    private(set) var badges: [String: FileChange] = [:]
    private(set) var changes: ChangeSet?
    private(set) var statusTruncated = false
    private(set) var filesTruncated = false
    private(set) var error: String?
    /// A remote folder that is not a repository: no tree (the server's disk is listed only through git).
    private(set) var remoteNoGit = false
    /// The remote task's host is not connected: a calm notice; what was loaded stays until the next load.
    private(set) var offline = false
    /// The listing failed: shown in Files only (Changes still load).
    private(set) var filesError: String?
    private(set) var diff: DiffState = .none
    /// The task's base branch from the last status load (also in uncommitted mode, for the hint); nil if unknown.
    private(set) var baseName: String?
    /// Path of the open diff (relative to the root); its Changes row is selected.
    private(set) var diffPath: String?
    /// Requested; the effective one is `changes?.mode` (a missing base shows uncommitted).
    private(set) var modeChoice: ModeChoice = .base
    /// A load of the open diff was applied (the diff tab drops a selection that is gone).
    @ObservationIgnored var onDiffApplied: (() -> Void)?
    /// A load of the task's changes starts (show, refresh, mode switch): the sidebar badge reloads with it.
    @ObservationIgnored var onStatusLoad: ((UUID) -> Void)?
    /// Git-ignored entries of the last tree load (the watcher drops their events).
    @ObservationIgnored let ignored = IgnoredPaths()
    /// The running load or its queued rerun; nil when idle (tests await it).
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    /// Files' calm notice for a loaded, empty listing: a plain folder is empty, a repository folder lists nothing.
    var emptyFilesNotice: String? {
        guard treeLoaded, !remoteNoGit, filesError == nil, error == nil, (tree.children(of: "") ?? []).isEmpty else { return nil }
        return isGit ? L10n.noGitFiles : L10n.folderEmpty
    }

    private struct Context: Equatable {
        var taskId: UUID?
        var root: String?
        var mode: ModeChoice
    }

    @ObservationIgnored private var git: @Sendable (String) -> Git = { Git(repo: $0) }
    /// Untracked files' line counts (Changes «+N») with the size:mtime they were taken at; this context only.
    @ObservationIgnored private var untrackedCache: [String: UntrackedLines] = [:]
    @ObservationIgnored private var counting: Task<Void, Never>?
    /// Untracked files counted per refresh (one process for all; the rest stay without «+N»).
    static let untrackedCountLimit = 500
    @ObservationIgnored private var remote = false
    @ObservationIgnored private var context = Context(taskId: nil, root: nil, mode: .base)
    /// The task whose data is loaded (kept while the inspector is hidden, so another selected task must not use it).
    var shownTaskId: UUID? { context.taskId }
    @ObservationIgnored private var baseBranch: @Sendable () async -> String? = { nil }
    /// `baseBranch()` once asked (`.some(nil)`: there is none); asked again on every `show` and `baseChanged`.
    @ObservationIgnored private var knownBase: String??
    /// Top level and the folder's prefix under it, found by a load of this context; nil = not known to be git yet.
    @ObservationIgnored private var top: (top: String, prefix: String)?
    /// Bumped by every start and cancel: a load applies only while it is the current one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running: RefreshParts = []
    @ObservationIgnored private var pending: RefreshParts = []
    /// No load of this context has finished yet (auto-expansion runs once).
    @ObservationIgnored private var firstLoad = true

    /// `git`: git at a path on the task's machine; `remote`: that machine is an ssh host (no FileManager on its paths).
    func show(taskId: UUID?, root: String?, git: @escaping @Sendable (String) -> Git = { Git(repo: $0) }, remote: Bool = false,
              baseBranch: @escaping @Sendable () async -> String?) {
        self.baseBranch = baseBranch
        self.git = git
        self.remote = remote
        knownBase = nil  // one `baseBranch()` per show: settings may have changed it
        let next = Context(taskId: taskId, root: root, mode: modeChoice)
        guard next != context else { refresh(.all); return }
        context = next
        cancel()
        self.root = root
        isGit = true
        remoteNoGit = false
        offline = false
        top = nil
        tree = FileTree()
        treeLoaded = false
        ignored.paths = []
        expanded = []
        badges = [:]
        filesTruncated = false
        firstLoad = true
        baseName = nil
        filesError = nil
        resetChanges()
        diffPath = nil
        diff = .none
        if root != nil { start(.all) }
    }

    /// The project's base branch setting changed: ask `baseBranch()` again and reload the changes.
    func baseChanged() {
        knownBase = nil
        refresh(.status)
    }

    /// A same-context change: runs now, or once after the current load.
    func refresh(_ parts: RefreshParts) {
        guard context.root != nil, !parts.isEmpty else { return }
        if loading != nil { pending.formUnion(parts) } else { start(parts) }
    }

    /// ⌥B: base ↔ uncommitted; cancels the load, keeps the tree.
    func toggleMode() {
        modeChoice = modeChoice == .base ? .uncommitted : .base
        context.mode = modeChoice
        let unfinished = cancel()
        resetChanges()
        if diffPath != nil { diff = .loading }
        if context.root != nil { start(unfinished.union(.status)) }
    }

    func expand(_ dir: String) {
        expanded.insert(dir)
        if !isGit, tree.children(of: dir) == nil { refresh(.tree) }
    }

    func collapse(_ dir: String) { expanded.remove(dir) }

    /// Path relative to the root; nil closes the diff.
    func loadDiff(path: String?) {
        diffPath = path
        guard path != nil else { diff = .none; return }
        diff = .loading
        refresh(.diff)
    }

    private func resetChanges() {
        changes = nil
        counting?.cancel()
        untrackedCache = [:]
        statusTruncated = false
        error = nil
    }

    /// Returns the parts that did not finish.
    @discardableResult private func cancel() -> RefreshParts {
        let unfinished = running.union(pending)
        loading?.cancel()
        loading = nil
        generation += 1
        running = []
        pending = []
        return unfinished
    }

    private func start(_ parts: RefreshParts) {
        generation += 1
        let gen = generation
        running = parts
        if parts.contains(.status), let id = context.taskId { onStatusLoad?(id) }
        let input = LoadInput(root: context.root!, remote: remote, mode: context.mode, top: top,
                              known: changes, base: knownBase, diffPath: diffPath, expanded: expanded, firstLoad: firstLoad)
        let git = self.git, baseBranch = self.baseBranch
        loading = Task { [weak self] in
            let result = await Self.load(parts, input, git: git, baseBranch: baseBranch)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.apply(result, parts: parts)
            let again = self.pending
            self.pending = []
            if again.isEmpty {
                self.running = []
                self.loading = nil
            } else {
                self.start(again)
            }
        }
    }

    private struct LoadInput: Sendable {
        var root: String
        var remote: Bool
        var mode: ModeChoice
        /// Top level and prefix from an earlier load of this context (skips the probes).
        var top: (top: String, prefix: String)?
        var known: ChangeSet?
        var base: String??
        var diffPath: String?
        var expanded: Set<String>
        var firstLoad: Bool
    }

    private struct LoadResult: Sendable {
        var isGit = true
        var remoteNoGit = false
        var offline = false
        var top: (top: String, prefix: String)?
        var tree: FileTree?
        var filesTruncated = false
        var paths = 0
        var ignored: Set<String>?
        var status: StatusResult?
        var baseName: String?
        var changes: ChangeSet?
        var filesError: String?
        var diff: DiffState?
        var diffPath: String?
        /// A diff was asked for, but there are no changes to look it up in (not a repository, or status failed).
        var diffUnavailable = false
        var error: String?
    }

    /// Off the main thread: git through the injected runner, a local plain folder through FileManager.
    private nonisolated static func load(_ parts: RefreshParts, _ input: LoadInput, git makeGit: @Sendable (String) -> Git,
                                         baseBranch: @Sendable () async -> String?) async -> LoadResult {
        var r = LoadResult()
        r.diffPath = input.diffPath
        let git = makeGit(input.root)
        if input.top == nil, !input.remote, (try? await git.isRepository()) != true {
            r.isGit = false
            r.diffUnavailable = input.diffPath != nil && (parts.contains(.diff) || parts.contains(.status))
            guard parts.contains(.tree) else { return r }
            var tree = FileTree()
            let base = URL(fileURLWithPath: input.root)
            tree.setChildren(listDirectory(base), of: "")
            for dir in input.expanded.sorted() where tree.children(of: (dir as NSString).deletingLastPathComponent) != nil {
                tree.setChildren(listDirectory(base.appendingPathComponent(dir)), of: dir)
            }
            r.tree = tree
            return r
        }
        do {
            // A project in a subfolder (`prefix` "apps/web/"): git runs in it and covers only it (#44).
            let top: String, prefix: String
            if let known = input.top {
                (top, prefix) = known
            } else if input.remote {
                // One call answers both "git?" and "reachable?"; a git failure here means not a repository.
                do { (top, prefix) = try await git.location() } catch where !Self.isOffline(error) {
                    r.isGit = false
                    r.remoteNoGit = true
                    r.tree = FileTree()
                    r.diffUnavailable = input.diffPath != nil && (parts.contains(.diff) || parts.contains(.status))
                    return r
                }
            } else {
                (top, prefix) = try await git.location()
            }
            r.top = (top, prefix)
            if parts.contains(.tree) {
                // A failed listing shows in Files only; the changes still load.
                do {
                    let listing = try await git.listFiles()
                    r.tree = FileTree(paths: listing.paths, dirLinks: listing.dirLinks)
                    r.filesTruncated = listing.truncated
                    r.paths = listing.paths.count
                    // Only the local watcher uses them (and `realPath` is this Mac's disk).
                    if !input.remote, let rel = try? await git.ignoredPaths() {
                        let base = realPath(top)
                        r.ignored = Set(rel.map { base + "/" + ($0.hasSuffix("/") ? String($0.dropLast()) : $0) })
                    }
                } catch where !(input.remote && Self.isOffline(error)) {
                    r.filesError = Self.message(error)
                }
            }
            var changes = input.known
            if parts.contains(.status) {
                let status = try await git.status(prefix: prefix)
                r.status = status
                var mode = DiffMode.uncommitted
                var missing = false
                let base: String?
                if let known = input.base { base = known } else { base = await baseBranch() }
                r.baseName = base
                if input.mode == .base {
                    if let base { mode = .base(base) } else { missing = true }
                }
                var set = try await git.changedFiles(mode, status: status)
                if missing { set.baseMissing = true }
                r.changes = set
                changes = set
            }
            if parts.contains(.status) || parts.contains(.diff), let path = input.diffPath {
                if let changes, let file = changes.files.first(where: { $0.path == path }) {
                    r.diff = .loaded(try await git.diff(file: file, from: changes.from))
                } else if changes != nil {
                    r.diff = .notChanged
                } else {
                    r.diffUnavailable = true
                }
            }
        } catch where input.remote && Self.isOffline(error) {
            r.offline = true
            r.diffUnavailable = input.diffPath != nil && (parts.contains(.diff) || parts.contains(.status))
        } catch {
            r.error = Self.message(error)
            if input.diffPath != nil, parts.contains(.diff) || parts.contains(.status) { r.diff = .failed(r.error!); r.diffUnavailable = false }
        }
        return r
    }

    /// The host, not git: not connected, or ssh's own failure (255) mid-call.
    private nonisolated static func isOffline(_ error: Error) -> Bool {
        error is RemoteHostError || (error as? GitError)?.status == 255
    }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func apply(_ r: LoadResult, parts: RefreshParts) {
        error = r.error
        if parts.contains(.tree), r.error == nil { filesError = r.filesError }
        if r.diffUnavailable, r.diffPath == diffPath { diff = .failed(L10n.diffUnavailable) }
        offline = r.offline
        if r.offline { return }
        remoteNoGit = r.remoteNoGit
        if !r.isGit {
            isGit = false
            if segment != .search { segment = .files }
            if let tree = r.tree { self.tree = tree; treeLoaded = true }
            return
        }
        if let top = r.top { self.top = top }
        if let tree = r.tree {
            self.tree = tree
            treeLoaded = true
            filesTruncated = r.filesTruncated
        }
        if let paths = r.ignored { ignored.paths = paths }
        if let status = r.status {
            var b: [String: FileChange] = [:]
            for e in status.entries { b[e.path] = e.change }
            badges = b
            statusTruncated = status.truncated
            baseName = r.baseName
            knownBase = .some(r.baseName)
        }
        if let changes = r.changes {
            self.changes = withUntrackedCounts(changes)
            countUntracked()
        }
        // A diff of a path closed or replaced meanwhile is stale (its own `.diff` rerun is queued).
        if let diff = r.diff, r.diffPath == diffPath {
            self.diff = diff
            onDiffApplied?()
        }
        if firstLoad, r.tree != nil, let changes = r.changes {
            firstLoad = false
            expanded.formUnion(autoExpanded(for: changes.files.map(\.path), fileCount: r.paths))
        }
    }

    // MARK: Untracked counts

    /// The list shows at once with what the cache knows; one process then counts the untracked files (re-reading only
    /// those whose size or mtime changed) and fills in their «+N».
    private func countUntracked() {
        guard let set = changes, let root = context.root else { return }
        let paths = Array(set.files.lazy.filter { $0.change == .untracked }.map(\.path).prefix(Self.untrackedCountLimit))
        guard !paths.isEmpty else { return }
        counting?.cancel()
        let git = self.git(root), known = untrackedCache, ctx = context
        counting = Task { [weak self] in
            let counts = await git.untrackedLines(paths, known: known)
            guard let self, !Task.isCancelled, self.context == ctx, let current = self.changes else { return }
            self.untrackedCache.merge(counts) { $1 }
            let filled = self.withUntrackedCounts(current)
            if filled != current { self.changes = filled }
        }
    }

    private func withUntrackedCounts(_ set: ChangeSet) -> ChangeSet {
        var set = set
        for i in set.files.indices where set.files[i].change == .untracked {
            set.files[i].added = untrackedCache[set.files[i].path]?.lines
        }
        return set
    }
}