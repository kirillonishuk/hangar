import AppKit
import Exec
import Foundation
@testable import Git
import Testing
@testable import HangarUI
import Workspace

/// The Git tab's view-model (redesign v1 §4): query building, paging, branch tree, dates, graph hiding, energy.
@MainActor @Suite struct GitPanelModelTests {
    private func settle(_ model: GitPanelModel) async {
        while let task = model.loadTask { await task.value }
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func branch(_ name: String, remote: Bool = false, head: Bool = false, ahead: Int = 0, behind: Int = 0) -> BranchInfo {
        BranchInfo(name: name, isRemote: remote, hash: String(repeating: "a", count: 40), isHead: head, upstream: nil,
                   upstreamGone: false, ahead: ahead, behind: behind, lastCommit: Date(timeIntervalSince1970: 0))
    }

    // MARK: Query

    @Test func queryBuildsLogFilters() {
        let now = date("2026-10-25T15:30:00Z")
        var q = GitQuery()
        #expect(q.scope == .head)  // the Branch chip starts on HEAD
        #expect(q.filters(now: now, calendar: utc) == LogFilters(ref: .head))
        q = GitQuery(scope: .ref("feat/x"), text: "  hover ", author: GitAuthor(name: "Ann", email: "ann@x.io"), date: .week, path: " ./src/ ")
        let f = q.filters(now: now, calendar: utc)
        #expect(f.ref == .ref("feat/x"))
        #expect(f.text == "hover")
        #expect(f.author == "<ann@x.io>")  // the email in brackets: one person, not a name prefix
        #expect(f.since == date("2026-10-19T00:00:00Z"))  // today and the 6 days before
        #expect(f.until == nil)
        #expect(f.path == "src")
        #expect(GitQuery(date: .today).filters(now: now, calendar: utc).since == date("2026-10-25T00:00:00Z"))
        #expect(GitQuery(date: .month).filters(now: now, calendar: utc).since == date("2026-09-26T00:00:00Z"))
        #expect(GitQuery(author: GitAuthor(name: "bot", email: "")).filters(now: now, calendar: utc).author == "bot")
        #expect(GitQuery(text: "   ", path: "  ").filters(now: now, calendar: utc) == LogFilters(ref: .head))
    }

    @Test func narrowingFiltersHideTheGraph() {
        #expect(!GitQuery().hidesGraph)
        #expect(!GitQuery(scope: .all).hidesGraph)
        #expect(!GitQuery(scope: .ref("main")).hidesGraph)  // a branch is still a whole history
        #expect(!GitQuery(text: "  ").hidesGraph)
        #expect(GitQuery(text: "fix").hidesGraph)
        #expect(GitQuery(author: GitAuthor(name: "a", email: "a@b")).hidesGraph)
        #expect(GitQuery(date: .today).hidesGraph)
        #expect(GitQuery(path: "src").hidesGraph)
        #expect(GitQuery().activeCount == 0)
        #expect(GitQuery(text: "x", author: GitAuthor(name: "a", email: ""), path: "p").activeCount == 3)
    }

    // MARK: Branch tree

    @Test func branchesGroupBySlash() {
        let tree = branchTree([branch("main"), branch("feat/b"), branch("feat/a"), branch("feat/ui/x"), branch("fix")], id: "local")
        #expect(tree.map(\.name) == ["fix", "main", "feat"])  // branches before folders, each by name
        #expect(tree[0].branch?.name == "fix" && tree[2].branch == nil)
        let feat = tree[2]
        #expect(feat.count == 3 && feat.id == "local/feat/")
        #expect(feat.children.map(\.name) == ["a", "b", "ui"])
        #expect(feat.children[2].children.map(\.name) == ["x"] && feat.children[2].children[0].branch?.name == "feat/ui/x")
        let remote = branchTree([branch("origin/main", remote: true), branch("origin/feat/a", remote: true), branch("up/main", remote: true)], id: "remote")
        #expect(remote.map(\.name) == ["origin", "up"])  // one folder per remote
        #expect(remote[0].count == 2 && remote[0].children.map(\.name) == ["main", "feat"])
    }

    @Test func branchRowsFollowExpansion() {
        let list = BranchList(head: GitHead(branch: "feat/a", hash: "abc"),
                              local: [branch("feat/a", head: true, ahead: 2, behind: 1), branch("main")],
                              remote: [branch("origin/main", remote: true)])
        var rows = branchRows(list, expanded: [])
        #expect(rows.map(\.id) == ["head", "local", "remote"])
        #expect(rows[0].title == "feat/a")
        #expect(rows[1].count == 2 && rows[2].count == 1)
        rows = branchRows(list, expanded: ["local", "local/feat/"])
        #expect(rows.map(\.title) == ["feat/a", "Local", "main", "feat", "a", "Remote"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 2, 0])
        #expect(rows[4].branch?.ahead == 2 && rows[4].branch?.behind == 1)
        #expect(rows[3].expanded && !rows[5].expanded)
        // Detached: HEAD shows the short hash.
        let detached = BranchList(head: GitHead(branch: nil, hash: "0123456789abcdef"), local: [], remote: [])
        #expect(branchRows(detached, expanded: []).first?.title == "0123456")
        #expect(branchRows(detached, expanded: []).map(\.id) == ["head"])  // empty sections are not shown
    }

    // MARK: Dates

    /// ↑/↓ from the search field: the next / previous commit, stopping at the ends; from none, the first.
    @Test func arrowsStepThroughTheLog() {
        let hashes = ["a", "b", "c"]
        #expect(gitLogStep(hashes, from: nil, by: 1) == "a")
        #expect(gitLogStep(hashes, from: nil, by: -1) == "a")
        #expect(gitLogStep(hashes, from: "a", by: 1) == "b")
        #expect(gitLogStep(hashes, from: "c", by: 1) == "c")
        #expect(gitLogStep(hashes, from: "a", by: -1) == "a")
        #expect(gitLogStep(hashes, from: "gone", by: 1) == "a")
        #expect(gitLogStep([], from: nil, by: 1) == nil)
    }

    @Test func relativeDates() {
        defer { L10n.language = .system }
        let now = date("2026-10-25T15:30:00Z")
        L10n.language = .ru
        #expect(gitShortDate(date("2026-10-25T09:05:00Z"), now: now, calendar: utc) == "09:05")
        #expect(gitShortDate(date("2026-10-24T23:59:00Z"), now: now, calendar: utc) == "вчера")
        #expect(gitShortDate(date("2026-10-23T12:00:00Z"), now: now, calendar: utc) == "23 окт")
        #expect(gitShortDate(date("2025-03-02T12:00:00Z"), now: now, calendar: utc) == "2 марта 2025")  // ICU: March has no shorter form
        #expect(gitLongDate(date("2026-10-25T16:03:00Z"), now: now, calendar: utc) == "сегодня 16:03")
        #expect(gitLongDate(date("2026-10-24T16:03:00Z"), now: now, calendar: utc) == "вчера 16:03")
        #expect(gitLongDate(date("2026-10-23T16:03:00Z"), now: now, calendar: utc) == "23 окт 16:03")
        L10n.language = .en
        #expect(gitShortDate(date("2026-10-24T08:00:00Z"), now: now, calendar: utc) == "yesterday")
        #expect(gitShortDate(date("2026-10-23T12:00:00Z"), now: now, calendar: utc) == "Oct 23")
        #expect(gitLongDate(date("2026-10-25T16:03:00Z"), now: now, calendar: utc) == "today 16:03")
    }

    // MARK: Commit files

    @Test func commitFilesGroupByFolder() {
        let files = [ChangedFile(path: "Sources/Git/b.swift", change: .modified, added: 4, deleted: 8),
                     ChangedFile(path: "README.md", change: .modified, added: 1, deleted: 0),
                     ChangedFile(path: "Sources/Git/a.swift", change: .added, added: 40, deleted: 21),
                     ChangedFile(path: "img.png", change: .added),
                     ChangedFile(path: "Sources/UI/v.swift", change: .deleted, added: 0, deleted: 3)]
        let groups = commitFileGroups(files)
        #expect(groups.map(\.dir) == ["", "Sources/Git", "Sources/UI"])  // top-level files first, unfoldered
        #expect(groups[0].files.map(\.path) == ["img.png", "README.md"])
        #expect(groups[1].files.map(\.path) == ["Sources/Git/a.swift", "Sources/Git/b.swift"])
        #expect(groups[1].added == 44 && groups[1].deleted == 29)
        #expect(commitFileTotals(files) == (added: 45, deleted: 32))
    }

    // MARK: Refresh triggers

    @Test func refsMovesAreSeen() {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let git = "/r/.git"
        #expect(refsMoved([("/r/.git/HEAD", modified)], gitDir: git, commonDir: nil))
        #expect(refsMoved([("/r/.git/refs/heads/main", modified)], gitDir: git, commonDir: nil))
        #expect(refsMoved([("/r/main/.git/packed-refs", modified)], gitDir: "/r/main/.git/worktrees/wt", commonDir: "/r/main/.git"))
        #expect(!refsMoved([("/r/.git/refs/heads/main.lock", modified)], gitDir: git, commonDir: nil))
        #expect(!refsMoved([("/r/.git/index", modified), ("/r/a.txt", modified)], gitDir: git, commonDir: nil))
        #expect(!refsMoved([("/r/.git/HEAD", modified)], gitDir: nil, commonDir: nil))
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(refsMoved([("/r", dropped)], gitDir: git, commonDir: nil))  // a rescan may hide anything
    }

    // MARK: Loading

    /// `n` commits on main after the fixture's first one; returns their hashes, newest first.
    private func history(_ t: TempRepo, _ n: Int) async throws {
        for i in 0..<n { try await t.commit(file: "f\(i).txt", on: "main") }
    }

    /// A hash-prefix search puts the hash's commit first on page 1 on top of the message matches: the next page must
    /// still start after the matches git returned, not after the rows shown (none may be skipped).
    @Test func hashHitDoesNotSkipAMatchOnTheNextPage() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        let prefix = String(try await t.git("rev-parse", "HEAD", in: t.repo).trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        for i in 0..<4 { try await t.commit(file: "\(prefix)-\(i).txt", on: "main") }  // 4 messages contain the prefix
        let model = GitPanelModel(pageSize: 2, textDebounce: .zero)
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0) }, remote: false)
        model.tabShown = true
        model.setOnScreen(true)
        await settle(model)
        model.query.text = prefix
        await settle(model)
        #expect(model.commits.count == 3 && model.hasMore)  // the hash's commit + 2 matches
        while model.hasMore {
            model.loadMore()
            await settle(model)
        }
        #expect(model.commits.count == 5)
        #expect(Set(model.commits.map(\.hash)).count == 5)
    }

    @Test func pagesThroughHistory() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        try await history(t, 4)  // 5 commits
        let model = GitPanelModel(pageSize: 2)
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0) }, remote: false)
        model.tabShown = true
        model.setOnScreen(true)
        await settle(model)
        #expect(model.commits.count == 2 && model.hasMore)
        #expect(model.graph.count == 2)
        #expect(model.branches?.head.branch == "main")
        model.loadMore()
        await settle(model)
        #expect(model.commits.count == 4 && model.hasMore)
        model.loadMore()
        await settle(model)
        #expect(model.commits.count == 5 && !model.hasMore && model.graph.count == 5)
        #expect(Set(model.commits.map(\.hash)).count == 5)
        model.loadMore()  // nothing more: no load
        #expect(model.loadTask == nil)
        // A refresh keeps what was paged in (the list does not jump back to one page).
        try await t.commit(file: "late.txt", on: "main")
        model.refresh()
        await settle(model)
        #expect(model.commits.count == 5 && model.commits[0].subject == "c late.txt" && model.hasMore)
    }

    @Test func filtersReloadAndHideTheGraph() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        try await history(t, 3)
        let model = GitPanelModel(textDebounce: .zero)
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0) }, remote: false)
        model.tabShown = true
        model.setOnScreen(true)
        await settle(model)
        #expect(model.commits.count == 4 && model.showsGraph && model.graph.count == 4)
        model.query.text = "f1"
        await settle(model)
        #expect(model.commits.map(\.subject) == ["c f1.txt"])
        #expect(!model.showsGraph && model.graph.isEmpty)
        model.query = GitQuery(path: "f2.txt")
        await settle(model)
        #expect(model.commits.map(\.subject) == ["c f2.txt"])
        // Chips set one after another, without waiting: the last query wins, still without lanes.
        model.query.author = model.authors.first?.author
        model.query.date = .month
        model.query.path = "f2.txt"
        await settle(model)
        #expect(model.commits.map(\.subject) == ["c f2.txt"] && !model.showsGraph && model.graph.isEmpty)
        model.query = GitQuery()
        await settle(model)
        #expect(model.commits.count == 4 && model.showsGraph)
        // Clicking a branch filters the log to it.
        try await t.git("branch", "side", "HEAD~2", in: t.repo)
        model.refresh()
        await settle(model)
        model.query.scope = .ref("side")
        await settle(model)
        #expect(model.commits.count == 2)
        #expect(model.authors.first?.author.name == "Test")
    }

    /// Energy: nothing runs while the Git tab is not visible; showing it loads what changed meanwhile.
    @Test func loadsOnlyWhileVisible() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        let model = GitPanelModel()
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0) }, remote: false)
        #expect(model.loadTask == nil)
        model.tabShown = true
        #expect(model.loadTask == nil)  // the inspector (or the window) is hidden
        model.setOnScreen(true)
        await settle(model)
        #expect(model.commits.count == 1)
        model.tabShown = false
        try await t.commit(file: "b.txt", on: "main")
        model.refresh()
        #expect(model.loadTask == nil)
        model.tabShown = true
        await settle(model)
        #expect(model.commits.count == 2)
    }

    /// Another session cancels the load in flight; its result never lands in the new one.
    @Test func sessionChangeCancelsLoads() async throws {
        let a = try await TempRepo.offMain(), b = try await TempRepo.offMain()
        defer { a.cleanup(); b.cleanup() }
        try await history(a, 3)
        let slow = Runner { args, cwd in
            try await Task.sleep(for: .milliseconds(300))
            return try await Runner.local.run(args, cwd)
        }
        let model = GitPanelModel()
        model.tabShown = true
        model.setOnScreen(true)
        model.show(taskId: UUID(), root: a.repo, git: { Git(repo: $0, runner: slow) }, remote: false)
        let first = try #require(model.loadTask)
        model.show(taskId: UUID(), root: b.repo, git: { Git(repo: $0) }, remote: false)
        #expect(model.commits.isEmpty)
        await first.value
        await settle(model)
        #expect(model.commits.count == 1 && model.root == b.repo)
    }

    @Test func selectingLoadsDetailsAndFileDiff() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        try await history(t, 1)
        let model = GitPanelModel()
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0) }, remote: false)
        model.tabShown = true
        model.setOnScreen(true)
        await settle(model)
        let top = try #require(model.commits.first)
        model.select(top.hash)
        await settle(model)
        #expect(model.details?.commit.hash == top.hash && model.details?.files.map(\.path) == ["f0.txt"])
        model.loadDiff(hash: top.hash, path: "f0.txt", origPath: nil)
        #expect(model.diffState(hash: top.hash, path: "f0.txt") == .loading)
        await settle(model)
        guard case .loaded(.text(let hunks, _, _)) = model.diffState(hash: top.hash, path: "f0.txt") else {
            Issue.record("no diff"); return
        }
        #expect(hunks.count == 1)
        #expect(model.diffState(hash: top.hash, path: "other") == nil)
        model.select(nil)
        #expect(model.details == nil)
    }

    /// A remote host that drops: the calm «not connected» state, what was loaded stays.
    @Test func offlineHostKeepsTheList() async throws {
        let t = try await TempRepo.offMain()
        defer { t.cleanup() }
        final class Flag: @unchecked Sendable { var down = false }
        let flag = Flag()
        let runner = Runner { args, cwd in
            if flag.down { throw RemoteHostError.notConnected("srv") }
            return try await Runner.local.run(args, cwd)
        }
        let model = GitPanelModel()
        model.show(taskId: UUID(), root: t.repo, git: { Git(repo: $0, runner: runner) }, remote: true)
        model.tabShown = true
        model.setOnScreen(true)
        await settle(model)
        #expect(model.commits.count == 1 && !model.offline)
        flag.down = true
        model.refresh()
        await settle(model)
        #expect(model.offline && model.commits.count == 1 && model.error == nil)
        flag.down = false
        model.refresh()
        await settle(model)
        #expect(!model.offline)
    }
}

extension GitPanelModelTests {
    @Test func pathChipPicksFromTheFilesTree() {
        let tree = FileTree(paths: ["README.md", "Sources/Git/Log.swift", "Sources/UI/View.swift", "docs/git.md"])
        #expect(gitPathCandidates(tree, query: "", limit: 10).map(\.path) == ["docs", "Sources", "README.md"])
        #expect(gitPathCandidates(tree, query: "git", limit: 10).map(\.path) == ["docs/git.md", "Sources/Git", "Sources/Git/Log.swift"])
        #expect(gitPathCandidates(tree, query: "swift", limit: 1).map(\.path) == ["Sources/Git/Log.swift"])
    }
}
