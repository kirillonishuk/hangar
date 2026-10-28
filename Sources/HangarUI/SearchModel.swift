import Exec
import Foundation
import Git
import Observation

/// Where a search runs: the inspector's root, on this Mac or on an ssh host.
struct SearchTarget: Equatable, Sendable {
    var root: String
    var host: String?
    /// A remote plain folder (not a repository) gets `git grep --no-index`; a local root is probed per search.
    var remoteGit = true
}

/// One search process: argv for `Process` (never a shell) and how to read its output.
struct SearchLaunch: Equatable, Sendable {
    var executable: String
    var args: [String]
    var cwd: String
    var engine: SearchEngine
    var gitColumn = true
    /// An ssh child: stdin is held open, so the remote side (`remoteWatchdogArgv`) ends with the session.
    var remote = false
}

enum SearchStatus: Equatable {
    case idle, running, done
    case failed(String)
    /// The remote host is not connected.
    case offline(String)
}

/// The inspector's Search tab (decision #91): one search at a time — a new query, toggle or root terminates the running
/// process; typing is debounced. Results stream in grouped by file, capped (`SearchLimits`). Idle: no timers, no process.
@MainActor @Observable final class SearchModel {
    var text = "" { didSet { if text != oldValue { schedule() } } }
    var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule(debounce: false) } } }
    var regex = false { didSet { if regex != oldValue { schedule(debounce: false) } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { schedule(debounce: false) } } }
    var include = "" { didSet { if include != oldValue { schedule() } } }
    var exclude = "" { didSet { if exclude != oldValue { schedule() } } }
    private(set) var results = SearchResults()
    private(set) var status = SearchStatus.idle
    /// The engine of the last search (shown next to the count).
    private(set) var engine: SearchEngine?
    private(set) var target: SearchTarget?
    /// Files folded by a click on their header.
    var collapsed: Set<String> = []
    /// Sessions (search roots) whose include / exclude fields are open; this run only, never saved.
    private var filtersOpen: Set<String> = []
    /// The include / exclude fields are shown for the current root.
    var filtersShown: Bool {
        get { target.map { filtersOpen.contains(Self.key($0)) } ?? false }
        set {
            guard let target else { return }
            if newValue { filtersOpen.insert(Self.key(target)) } else { filtersOpen.remove(Self.key(target)) }
        }
    }
    /// Either glob field narrows the search (the toggle shows a dot, even while they are hidden).
    var filtersActive: Bool { !searchGlobs(include).isEmpty || !searchGlobs(exclude).isEmpty }
    /// ⇧⌘F: the field takes focus (and selects its text).
    var focusRequest = 0
    /// The last request the field has served.
    @ObservationIgnored var focusServed = 0

    /// Builds the process for a query; nil = the target's host is not connected. `gitColumn: false` retries old git.
    @ObservationIgnored var launcher: (SearchQuery, SearchTarget, _ gitColumn: Bool) async -> SearchLaunch? = { _, _, _ in nil }
    /// The root the inspector shows now (`AppState.searchTarget`); nil in tests that set the target directly.
    @ObservationIgnored var currentTarget: (() -> SearchTarget?)?
    @ObservationIgnored var debounceDelay: Duration = .milliseconds(250)
    /// The running search (tests await it); nil when idle.
    @ObservationIgnored private(set) var running: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// A search was stopped by `cancel` before it finished.
    @ObservationIgnored private var interrupted = false
    /// The login shell's `rg` once looked up (`.some(nil)`: it has none).
    @ObservationIgnored private var loginRipgrep: String??

    private static func key(_ target: SearchTarget) -> String { (target.host ?? "") + ":" + target.root }

    /// `!glob` in the include field means exclude (as rg reads it): moved there, so git grep (whose pathspecs have no
    /// `!`) agrees; a `!` typed in the exclude field is redundant and dropped.
    var query: SearchQuery {
        let inc = searchGlobs(include), exc = searchGlobs(exclude)
        let unbang = { (g: String) in g.hasPrefix("!") ? String(g.dropFirst()) : g }
        return SearchQuery(text: text, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord,
                           include: inc.filter { !$0.hasPrefix("!") },
                           exclude: (exc + inc.filter { $0.hasPrefix("!") }).map(unbang).filter { !$0.isEmpty })
    }

    /// The Search tab is on screen for this root: a new root is searched right away.
    func setTarget(_ target: SearchTarget?) {
        guard target != self.target || interrupted else { return }
        if target != self.target { collapsed = [] }
        self.target = target
        run()
    }

    /// The tab is left, the session changes away or the app quits: the running search stops (its process is
    /// terminated); shown again, it runs afresh.
    func cancel() {
        debounce?.cancel()
        debounce = nil
        guard running != nil else { return }
        running?.cancel()
        running = nil
        generation += 1
        interrupted = true
        status = .idle
    }

    func toggle(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }

    private func schedule(debounce: Bool = true) {
        self.debounce?.cancel()
        guard debounce else { run(); return }
        let delay = debounceDelay
        self.debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    /// Cancels the running search (its process is terminated) and starts the current query.
    func run() {
        debounce?.cancel()
        debounce = nil
        running?.cancel()
        running = nil
        interrupted = false
        generation += 1
        let gen = generation
        results = SearchResults()
        let q = query
        // The view's onAppear can run before the inspector has loaded the root: ask again at every start.
        if let current = currentTarget?(), current != target { target = current; collapsed = [] }
        guard let target, !q.text.isEmpty else { status = .idle; engine = nil; return }
        status = .running
        let launcher = self.launcher
        running = Task { [weak self] in
            var column = true
            while true {
                guard let launch = await launcher(q, target, column) else {
                    self?.finish(gen, nil, .offline(target.host ?? ""))
                    return
                }
                guard !Task.isCancelled, let self, gen == self.generation else { return }
                self.engine = launch.engine
                let stream = SearchStream(SearchParser(engine: launch.engine, query: q, gitColumn: launch.gitColumn))
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                let result: RunResult
                do {
                    result = try await streamProcess(launch.executable, launch.args, cwd: launch.cwd, env: env,
                                                     holdStdin: launch.remote) { [weak self] data in
                        let (more, snapshot) = stream.feed(data)
                        if let snapshot { Task { @MainActor in self?.apply(gen, snapshot) } }
                        return more
                    }
                } catch {
                    if !Task.isCancelled { self.finish(gen, nil, .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")) }
                    return
                }
                guard !Task.isCancelled else { return }
                // git before 2.19 has no --column (usage error 129): once more without it.
                if launch.engine == .gitGrep, launch.gitColumn, result.status == 129, result.stderr.contains("column") {
                    column = false
                    continue
                }
                // Off the main actor: the reader may still hold the parser's lock for a moment.
                let final = await Task.detached { stream.finish() }.value
                self.finish(gen, final, searchOutcome(launch.engine, result, results: final, host: target.host))
                return
            }
        }
    }

    private func apply(_ gen: Int, _ snapshot: SearchResults) {
        guard gen == generation, status == .running, snapshot.lines >= results.lines else { return }
        results = snapshot
    }

    private func finish(_ gen: Int, _ final: SearchResults?, _ status: SearchStatus) {
        guard gen == generation else { return }
        if let final { results = final }
        self.status = status
        running = nil
    }

    /// `rg` from the login shell's PATH (looked up once), else Homebrew's; nil: search with git grep.
    func ripgrep(shell: String) async -> String? {
        let fallbacks = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        if loginRipgrep == nil {
            let found: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    // A constant command line: nothing user-typed reaches the shell.
                    guard let r = try? await Runner.local.run([posixShell(shell), "-l", "-i", "-c", "command -v rg"], NSHomeDirectory()) else { return nil }
                    return r.stdout.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            loginRipgrep = .some(found)
        }
        return ([loginRipgrep ?? nil].compactMap { $0 } + fallbacks).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A search that fails with `reason` (git is only a CLT stub: running it would pop the install dialog).
func failingSearchLaunch(_ reason: String) -> SearchLaunch {
    SearchLaunch(executable: "/bin/sh", args: ["-c", #"printf '%s\n' "$1" >&2; exit 127"#, "sh", reason], cwd: "/", engine: .gitGrep)
}

/// How a finished process reads: rg and git grep exit 1 for «nothing found»; a process stopped at the cap is done.
/// Exit 1 with no hits and the shell's own error (a remote `cd` into a folder that is gone: `sh: …`, `cd: …`) is a
/// failure, not «nothing found»; any other stderr with exit 1 (a git warning) is still «nothing found».
func searchOutcome(_ engine: SearchEngine, _ r: RunResult, results: SearchResults, host: String?) -> SearchStatus {
    let first = r.stderr.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let shellError = ["sh:", "cd:", "/bin/sh:"].contains { first.hasPrefix($0) }
    if r.status == 0 || results.truncated || (r.status == 1 && (!shellError || results.lines > 0)) { return .done }
    if let host, r.status == 255 { return .offline(host) }
    // rg exits 2 on any error, also an unreadable file next to real matches.
    if engine == .ripgrep, r.status == 2, results.lines > 0 { return .done }
    let line = r.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"
    return .failed(String(line.prefix(300)))
}

/// The parser behind the pipe reader (one thread at a time feeds it; the lock covers `finish` from the task).
private final class SearchStream: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: SearchParser

    init(_ parser: SearchParser) { self.parser = parser }

    /// More output wanted; the results when this chunk added lines.
    func feed(_ data: Data) -> (Bool, SearchResults?) {
        lock.lock(); defer { lock.unlock() }
        let before = parser.results.lines, wasTruncated = parser.results.truncated, skipped = parser.results.skippedLines
        let more = parser.feed(data)
        let changed = parser.results.lines != before || parser.results.truncated != wasTruncated || parser.results.skippedLines != skipped
        return (more, changed ? parser.results : nil)
    }

    func finish() -> SearchResults {
        lock.lock(); defer { lock.unlock() }
        parser.finish()
        return parser.results
    }
}

extension AppState {
    /// The process for a search: local — rg if there is one, else git grep (`--no-index` outside a repository);
    /// remote — git grep on the host through its ssh master (rg isn't assumed there), streamed like a local process.
    func searchLaunch(_ q: SearchQuery, _ target: SearchTarget, gitColumn: Bool) async -> SearchLaunch? {
        if let host = target.host {
            guard let t = remote.target(host),
                  let args = sshStreamArgs(host: host, controlPath: t.controlPath, path: remote.hosts[host]?.report?.path, cwd: target.root,
                                           argv: remoteWatchdogArgv(gitGrepArgs(q, noIndex: !target.remoteGit, column: gitColumn))) else { return nil }
            return SearchLaunch(executable: t.sshPath, args: args, cwd: "/", engine: .gitGrep, gitColumn: gitColumn, remote: true)
        }
        if let rg = await search.ripgrep(shell: userShell) {
            return SearchLaunch(executable: rg, args: ripgrepArgs(q), cwd: target.root, engine: .ripgrep)
        }
        if let missing = localDeveloperToolMissing("git") { return failingSearchLaunch(missing) }
        let repo = (try? await Git(repo: target.root).isRepository()) == true
        return SearchLaunch(executable: "/usr/bin/env", args: gitGrepArgs(q, noIndex: !repo, column: gitColumn), cwd: target.root,
                            engine: .gitGrep, gitColumn: gitColumn)
    }

    /// The Search tab's root: the inspector's, while it shows the selected session.
    var searchTarget: SearchTarget? {
        guard let task = selectedTask, inspector.shownTaskId == task.id, let root = inspector.root else { return nil }
        return SearchTarget(root: root, host: project(task.projectId)?.host, remoteGit: !inspector.remoteNoGit)
    }

    /// App quit: a running search's process is terminated.
    public func stopSearch() { search.cancel() }

    /// ⇧⌘F (and ⌥⌘4): the inspector on Search, its field focused.
    func showSearch() {
        guard selectedTask != nil else { return }
        showInspector(.search)
        search.focusRequest += 1
    }
}
