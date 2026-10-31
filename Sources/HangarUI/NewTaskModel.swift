import Exec
import Foundation
import Git
import Observation
import Workspace

/// Logic of the «Новый чат» sheet: name, where to work (project folder / separate copy), base branch, background fetch, branch validation, worktree creation.
/// git runs only on open (`load`), on ↻ (`refresh`) and before create; no timers.
@MainActor @Observable final class NewTaskModel {
    enum Availability: Equatable { case loading, notRepository, noCommits, ready, hostOffline(String) }
    enum FetchState: Equatable { case idle, running, done, failed(String), cancelled, noRemote }

    var name = "" {
        didSet { if !branchEdited { suggestBranch() } }
    }
    /// The first message for the agent; names the chat (and its branch) while «Название» is empty.
    var message = "" {
        didSet { if !branchEdited, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { suggestBranch() } }
    }
    /// «Задание для …» unfolded (folded by default: the prompt can be written later, in the tab).
    var promptOpen = false
    /// What the chat will be called (decision #116); «Чат N» against the project's chats now (another window may add one).
    var chatName: String { HangarUI.chatName(name: name, message: message, existing: chatNames()) }
    /// The chat gets «Чат N» and waits for its agent's first prompt for a name (#116).
    var chatNameIsAuto: Bool { isNumberedChatName(name: name, message: message) }
    /// The project folder's HEAD, for «В папке проекта»; nil until loaded or outside git.
    private(set) var head: Head?
    /// Follows the slug of `name` until the user edits it; clearing it makes it follow again.
    var branch = "" {
        didSet { if !suggesting { branchEdited = !branch.isEmpty; if !branchEdited { clearBranchError() } } }
    }
    /// The «из названия» hint; redrawn through `branch`, which every change of it accompanies.
    var branchFollowsName: Bool { !branchEdited }
    var worktree: Bool
    var base: String?
    private(set) var branches: [Branch] = []
    private(set) var defaultBase: String?
    private(set) var availability = Availability.loading
    private(set) var fetch = FetchState.idle
    private(set) var lastFetch: Date?
    private(set) var branchError: String?
    /// git's stderr of a failed `worktree add`.
    private(set) var createError: String?
    private(set) var creating = false
    /// The entry being copied into the new worktree («Копирую node_modules…»).
    private(set) var progress: String?
    /// For the new worktree's shell tab after a create: failed copies, then the setup command if `runSetup`; nil = no tab.
    private(set) var setupScript: String?
    /// The «После создания» row: the project's saved command, else (no own one) the lockfile's suggestion; nil = no row content.
    private(set) var setupCommand: String?
    /// Only a saved command runs by default; a suggestion runs (and is saved to the project) once the user turns it on.
    var runSetup: Bool
    /// `setupCommand` is the lockfile's suggestion, not the project's own.
    var setupSuggested: Bool { project.setupCommand == nil && setupCommand != nil }
    /// After a create that ran a suggestion: save it to the project (the user's opt-in).
    private(set) var commandToSave: String?
    let taskBranches: Set<String>

    @ObservationIgnored private let chatNames: @MainActor () -> [String]
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

    /// What the sheet knows before it opens (#122): no block that appears and then goes away, no folder line that grows.
    struct Probe: Equatable {
        var availability: Availability
        var head: Head?
    }

    /// `known`: what `probe` answered, so the sheet's first frame already shows or leaves out «Где работать» and the
    /// folder's branch.
    init(project: Project, git: Git, taskBranches: Set<String>, known: Probe? = nil,
         chatNames: @escaping @MainActor () -> [String] = { [] }) {
        self.project = project
        self.chatNames = chatNames
        self.git = git
        self.taskBranches = taskBranches
        worktree = project.worktreeByDefault
        // A repository loads its branches as before (`.loading`); the rest is final until `load` says otherwise.
        head = known?.head
        if let known = known?.availability, known != .ready, known != .loading {
            availability = known
            worktree = false
        }
        let saved = project.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        setupCommand = saved.isEmpty ? nil : saved
        runSetup = !saved.isEmpty
    }

    var canCreate: Bool {
        guard !creating else { return false }
        return !worktree || (availability == .ready && base != nil && branchError == nil)
    }

    /// The quick part of `load`: not a repository, no commits, host offline, or `.ready` (a repository with commits);
    /// with the folder's HEAD.
    static func probe(_ git: Git) async -> Probe {
        do {
            guard try await git.isRepository() else { return Probe(availability: .notRepository) }
        } catch RemoteHostError.notConnected(let host) {
            return Probe(availability: .hostOffline(host))
        } catch {
            return Probe(availability: .notRepository)
        }
        let head = try? await git.head()
        return Probe(availability: await git.hasCommits() ? .ready : .noCommits, head: head)
    }

    func load() async {
        let isRepository: Bool
        do { isRepository = try await git.isRepository() } catch RemoteHostError.notConnected(let host) {
            availability = .hostOffline(host)
            worktree = false
            return
        } catch { isRepository = false }
        guard isRepository else {
            availability = .notRepository
            worktree = false
            return
        }
        head = try? await git.head()
        guard await git.hasCommits() else {
            availability = .noCommits
            worktree = false
            return
        }
        branches = (try? await git.listBranches()) ?? []
        defaultBase = try? await git.defaultBranch()
        remotes = (try? await git.remotes()) ?? []
        lastFetch = await git.lastFetch()
        if let last = project.lastBaseBranch, branches.contains(where: { $0.name == last }) {
            base = last
        } else {
            base = defaultBase
        }
        if project.setupCommand == nil { setupCommand = WorktreeDefaults(lockfiles: (try? await git.lockfiles()) ?? []).command }
        availability = .ready
        if !branchEdited { suggestBranch() }
        // The sheet closed while loading: its fetch would outlive it (`runFetch`'s task doesn't inherit cancellation).
        guard !Task.isCancelled else { return }
        await refresh()
    }

    /// Fetches the base's remote, then rereads branches. Returns at once if a fetch is already running or create is
    /// in progress (create fetches on its own).
    func refresh() async {
        guard !creating else { return }
        await runFetch()
    }

    private func runFetch() async {
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

    /// Releases waiters at once; the cancelled git (its whole process group) is killed by Runner.
    func cancelFetch() {
        guard fetch == .running else { return }
        fetchTask?.cancel()
        fetchTask = nil
        fetchId = nil
        fetch = .cancelled
        resumeFetchWaiters()
    }

    func validateBranch() async {
        let checked = branch
        let problem = await branchProblem(checked)
        guard branch == checked else { return }  // edited meanwhile: a newer validation owns the result
        branchError = problem
    }

    /// The field was cleared (it follows the name again): nothing to complain about.
    private func clearBranchError() { branchError = nil }

    /// nil keeps the sheet open: fetch failed/cancelled (offer «Create without fetch»), bad branch, or git error.
    func create(skipFetch: Bool) async -> TaskMode? {
        guard canCreate else { return nil }
        guard worktree else { return .mainFolder }
        creating = true
        defer { creating = false }
        createError = nil
        setupScript = nil
        commandToSave = nil
        if !skipFetch, !fetchedThisOpen {
            if fetch == .running { await fetchSettled() } else { await runFetch() }
            switch fetch {
            case .failed, .cancelled: return nil
            default: break
            }
        }
        // Captured once: the fields stay editable while git runs.
        let branch = branch
        guard let base else { return nil }
        branchError = await branchProblem(branch)
        guard branchError == nil else { return nil }
        let path = worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: branch)
        do {
            try await git.addWorktree(path: path, newBranch: branch, base: base)
        } catch {
            createError = (error as? GitError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // A project without its own list gets its package manager's (from the lockfiles at the top).
        var copy = project.worktreeCopy
        if copy == nil { copy = WorktreeDefaults(lockfiles: (try? await git.lockfiles()) ?? []).copy }
        let failures = await copyIgnored(copy ?? [], into: path)
        let command = runSetup ? setupCommand : nil
        setupScript = worktreeSetupScript(failures: failures, command: command)
        if project.setupCommand == nil { commandToSave = command }
        return .worktree(path: path, branch: branch, base: base)
    }

    /// Copies the ignored items `patterns` select from the main checkout's top into the new worktree (a whole
    /// checkout, so the same relative place); a failure never undoes the worktree, it is reported.
    private func copyIgnored(_ patterns: [String], into path: String) async -> [String] {
        guard !patterns.isEmpty else { return [] }
        defer { progress = nil }
        var failures: [String] = []
        do {
            let top = try await git.toplevel()
            for entry in matchIgnored(patterns, try await git.ignoredEntries()) {
                progress = entry
                do { try await git.copyIgnored(entry, from: top, into: path) } catch {
                    failures.append(entry + ": " + ((error as? GitError)?.errorDescription ?? error.localizedDescription))
                }
            }
        } catch {
            failures.append((error as? GitError)?.errorDescription ?? error.localizedDescription)
        }
        return failures
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

    private func branchProblem(_ branch: String) async -> String? {
        if branch.isEmpty { return L10n.branchRequired }
        if await !git.isValidBranchName(branch) { return L10n.branchInvalid }
        if branches.contains(where: { !$0.isRemote && $0.name == branch }) { return L10n.branchExists(branch) }
        return nil
    }

    /// `name` itself if it has `/`, is a branch name and doesn't start with a remote (`feat/JS-1`, decision #48), else its slug; if that branch (local, or
    /// remote of the same name; case-insensitive, as refs on macOS' disk) or its worktree folder exists, `-2`, `-3`, …
    private func suggestBranch() {
        let trimmed = chatName
        var suggestion = ""
        if !trimmed.isEmpty {
            let taken = Set(branches.map { b in
                guard b.isRemote, let r = remotes.first(where: { b.name.hasPrefix($0 + "/") }) else { return b.name.lowercased() }
                return String(b.name.dropFirst(r.count + 1)).lowercased()
            })
            // `origin/x` as a local branch would be ambiguous with the remote-tracking one; `release/1.2` next to
            // `release` (or `a` next to `a/b`) can't exist at all: a ref is either a file or a folder.
            let lower = trimmed.lowercased()
            let verbatim = trimmed.contains("/") && isBranchName(trimmed)
                && !remotes.contains(String(trimmed.prefix { $0 != "/" }))
                && !taken.contains { lower.hasPrefix($0 + "/") || $0.hasPrefix(lower + "/") }
            let slug = verbatim ? trimmed : branchSlug(trimmed)
            suggestion = slug
            var n = 1
            // A remote folder can't be stat'ed here (and runs on every keystroke): `worktree add` reports a taken one.
            while taken.contains(suggestion.lowercased()) || project.host == nil && FileManager.default.fileExists(
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

/// What the new worktree's shell tab runs first: each failed copy printed to stderr, then the setup command.
/// nil = nothing to run (no tab). Newlines, not `;`: a command ending in a `#` comment would swallow what follows.
@MainActor func worktreeSetupScript(failures: [String], command: String?) -> String? {
    let command = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let lines = failures.map { "printf '%s\\n' " + shellQuote(L10n.copyFailed($0)) + " >&2" } + (command.isEmpty ? [] : [command])
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}
