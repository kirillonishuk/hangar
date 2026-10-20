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
    enum Segment { case files, changes }
    enum ModeChoice { case base, uncommitted }

    var segment: Segment = .files
    /// The task's folder; for git — the repository top level once loaded (paths are relative to it).
    private(set) var root: String?
    private(set) var isGit = true
    private(set) var tree = FileTree()
    var expanded: Set<String> = []
    private(set) var badges: [String: FileChange] = [:]
    private(set) var changes: ChangeSet?
    private(set) var statusTruncated = false
    private(set) var filesTruncated = false
    private(set) var error: String?
    private(set) var diff: DiffState = .none
    /// Requested; the effective one is `changes?.mode` (a missing base shows uncommitted).
    private(set) var modeChoice: ModeChoice = .base
    /// Git-ignored entries of the last tree load (the watcher drops their events).
    @ObservationIgnored let ignored = IgnoredPaths()
    /// The running load or its queued rerun; nil when idle (tests await it).
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    private struct Context: Equatable {
        var taskId: UUID?
        var root: String?
        var mode: ModeChoice
    }

    @ObservationIgnored private let git: @Sendable (String) -> Git
    @ObservationIgnored private var context = Context(taskId: nil, root: nil, mode: .base)
    @ObservationIgnored private var baseBranch: @Sendable () async -> String? = { nil }
    /// Top level found by a load of this context; nil = not known to be git yet.
    @ObservationIgnored private var top: String?
    /// Path of the open diff (relative to the top level).
    @ObservationIgnored private var diffPath: String?
    /// Bumped by every start and cancel: a load applies only while it is the current one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running: RefreshParts = []
    @ObservationIgnored private var pending: RefreshParts = []
    /// No load of this context has finished yet (auto-expansion runs once).
    @ObservationIgnored private var firstLoad = true

    init(git: @escaping @Sendable (String) -> Git = { Git(repo: $0) }) {
        self.git = git
    }

    func show(taskId: UUID?, root: String?, baseBranch: @escaping @Sendable () async -> String?) {
        self.baseBranch = baseBranch
        let next = Context(taskId: taskId, root: root, mode: modeChoice)
        guard next != context else { refresh(.all); return }
        context = next
        cancel()
        self.root = root
        isGit = true
        top = nil
        tree = FileTree()
        ignored.paths = []
        expanded = []
        badges = [:]
        filesTruncated = false
        firstLoad = true
        resetChanges()
        diffPath = nil
        diff = .none
        if root != nil { start(.all) }
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

    /// Path relative to the top level; nil closes the diff.
    func loadDiff(path: String?) {
        diffPath = path
        guard path != nil else { diff = .none; return }
        diff = .loading
        refresh(.diff)
    }

    private func resetChanges() {
        changes = nil
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
        let input = LoadInput(root: context.root!, mode: context.mode, top: top,
                              known: changes, diffPath: diffPath, expanded: expanded, firstLoad: firstLoad)
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
        var mode: ModeChoice
        /// Top level from an earlier load of this context (skips the probes).
        var top: String?
        var known: ChangeSet?
        var diffPath: String?
        var expanded: Set<String>
        var firstLoad: Bool
    }

    private struct LoadResult: Sendable {
        var isGit = true
        var top: String?
        var tree: FileTree?
        var filesTruncated = false
        var paths = 0
        var ignored: Set<String>?
        var status: StatusResult?
        var changes: ChangeSet?
        var diff: DiffState?
        var diffPath: String?
        /// A diff was asked for, but there are no changes to look it up in (not a repository, or status failed).
        var diffUnavailable = false
        var error: String?
    }

    /// Off the main thread: git through the injected runner, the plain folder through FileManager.
    private nonisolated static func load(_ parts: RefreshParts, _ input: LoadInput, git makeGit: @Sendable (String) -> Git,
                                         baseBranch: @Sendable () async -> String?) async -> LoadResult {
        var r = LoadResult()
        r.diffPath = input.diffPath
        let git = makeGit(input.root)
        if input.top == nil, await !git.isRepository() {
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
            if let top = input.top { r.top = top } else { r.top = try await git.toplevel() }
            if parts.contains(.tree) {
                let listing = try await git.listFiles()
                r.tree = FileTree(paths: listing.paths, dirLinks: listing.dirLinks)
                r.filesTruncated = listing.truncated
                r.paths = listing.paths.count
                if let rel = try? await git.ignoredPaths(), let top = r.top {
                    let base = realPath(top)
                    r.ignored = Set(rel.map { base + "/" + ($0.hasSuffix("/") ? String($0.dropLast()) : $0) })
                }
            }
            var changes = input.known
            if parts.contains(.status) {
                let status = try await git.status()
                r.status = status
                var mode = DiffMode.uncommitted
                var missing = false
                if input.mode == .base {
                    if let b = await baseBranch() { mode = .base(b) } else { missing = true }
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
        } catch {
            r.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if input.diffPath != nil, parts.contains(.diff) || parts.contains(.status) { r.diff = .failed(r.error!); r.diffUnavailable = false }
        }
        return r
    }

    private func apply(_ r: LoadResult, parts: RefreshParts) {
        error = r.error
        if r.diffUnavailable, r.diffPath == diffPath { diff = .failed(L10n.diffUnavailable) }
        if !r.isGit {
            isGit = false
            segment = .files
            if let tree = r.tree { self.tree = tree }
            return
        }
        if let top = r.top { self.top = top; root = top }
        if let tree = r.tree {
            self.tree = tree
            filesTruncated = r.filesTruncated
        }
        if let paths = r.ignored { ignored.paths = paths }
        if let status = r.status {
            var b: [String: FileChange] = [:]
            for e in status.entries { b[e.path] = e.change }
            badges = b
            statusTruncated = status.truncated
        }
        if let changes = r.changes { self.changes = changes }
        // A diff of a path closed or replaced meanwhile is stale (its own `.diff` rerun is queued).
        if let diff = r.diff, r.diffPath == diffPath { self.diff = diff }
        if firstLoad, r.tree != nil, let changes = r.changes {
            firstLoad = false
            expanded.formUnion(autoExpanded(for: changes.files.map(\.path), fileCount: r.paths))
        }
    }
}
