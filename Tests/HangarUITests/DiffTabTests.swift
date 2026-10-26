import AppKit
import Foundation
@testable import Git
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct DiffTabTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-diff-\(UUID())")

    /// A selected task on a temp repo with three changed files (a.txt, b.txt, c.txt); the inspector has loaded it.
    private func makeApp() async throws -> (AppState, TempRepo, task: UUID) {
        let repo = try await TempRepo.offMain()
        try await repo.commit(file: "b.txt", on: "main")
        try await repo.commit(file: "c.txt", on: "main")
        for f in ["a.txt", "b.txt", "c.txt"] { try "changed\n".write(toFile: repo.repo + "/" + f, atomically: true, encoding: .utf8) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: repo.repo)
        let t = s.addTask(projectId: p, name: "a")
        _ = s.addTab(taskId: t, kind: .shell)
        _ = s.addTab(taskId: t, kind: .shell)
        s.select(taskId: t)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.inspector.show(taskId: t, root: repo.repo, baseBranch: { nil })
        await settle(app.inspector)
        return (app, repo, t)
    }

    private func settle(_ model: InspectorModel) async {
        while let task = model.loading { await task.value }
    }

    private func cleanup(_ repo: TempRepo) {
        repo.cleanup()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The tab context menu follows the keyboard rule: no split of a tab hidden behind the diff.
    @Test func menuSplitIgnoredWhileDiffShown() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        func leaves() -> Int { app.state.tasks.first { $0.id == t }!.tabs.flatMap(\.root.leaves).count }
        let tab = app.state.tasks.first { $0.id == t }!.tabs[0].id
        let before = leaves()
        app.openDiff(path: "a.txt")
        #expect(!Action.splitRight.isEnabled(for: .tab(task: t, tab: tab), app: app))
        Action.splitRight.perform(.tab(task: t, tab: tab), ActionContext(app: app))
        Action.splitDown.perform(.tab(task: t, tab: tab), ActionContext(app: app))
        #expect(leaves() == before)
        app.deactivateDiff()
        Action.splitRight.perform(.tab(task: t, tab: tab), ActionContext(app: app))
        #expect(leaves() == before + 1)
    }

    @Test func clickReplacesDiffTab() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        let tabs = app.state.tasks.first { $0.id == t }!.tabs.count
        app.openDiff(path: "a.txt")
        app.openDiff(path: "b.txt")
        #expect(app.diffTabs.count == 1)
        #expect(app.diffTabs[t] == DiffTab(path: "b.txt", active: true, selectedRowId: nil))
        #expect(app.activeDiff?.path == "b.txt")
        #expect(app.inspector.diffPath == "b.txt")
        #expect(app.state.tasks.first { $0.id == t }!.tabs.count == tabs)
        await settle(app.inspector)
        if case .loaded = app.inspector.diff {} else { Issue.record("diff not loaded: \(app.inspector.diff)") }
    }

    @Test func notPersisted() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        let before = app.state.tasks.first { $0.id == t }!.activeTabId
        app.openDiff(path: "b.txt")
        let json = String(decoding: try JSONEncoder().encode(app.state), as: UTF8.self)
        #expect(!json.contains("b.txt"))
        #expect(app.state.tasks.first { $0.id == t }!.activeTabId == before)
    }

    @Test func neighbourWithoutWrap() async throws {
        let (app, repo, _) = try await makeApp()
        defer { cleanup(repo) }
        let files = app.inspector.changes!.files.map(\.path)
        #expect(files.count == 3)
        app.openDiff(path: files[0])
        app.diffNeighbour(-1)
        #expect(app.activeDiff?.path == files[0])
        app.diffNeighbour(1)
        #expect(app.activeDiff?.path == files[1])
        app.openDiff(path: files[2])
        app.diffNeighbour(1)
        #expect(app.activeDiff?.path == files[2])
    }

    @Test func tabActivationDeactivatesDiff() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        app.openDiff(path: "a.txt")
        app.activate(tabNumber: 1)
        #expect(app.activeDiff == nil)
        #expect(app.diffTabs[t]?.path == "a.txt")
        app.activateDiff()  // a click on the diff tab
        #expect(app.activeDiff?.path == "a.txt")
        app.activate(tabId: app.state.tasks.first { $0.id == t }!.tabs[1].id)
        #expect(app.activeDiff == nil)
        app.activateDiff()
        app.closeDiff()
        #expect(app.activeDiff == nil)
        #expect(app.diffTabs[t] == nil)
        #expect(app.inspector.diffPath == nil)
    }

    @Test func archiveDropsDiffTab() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        app.openDiff(path: "a.txt")
        app.archive(taskId: t)
        #expect(app.diffTabs.isEmpty)
    }

    private func rowIndex(_ app: AppState, _ match: (DiffLine) -> Bool) -> Int? {
        app.activeDiffContent.rows.firstIndex { if case .line(let l) = $0 { match(l) } else { false } }
    }

    @Test func selectionFollowsLineAcrossReloads() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        // A task branch: base main has a.txt's first version, the branch commits another, the worktree a third.
        try await repo.git("checkout", "-q", "-b", "task", in: repo.repo)
        try "committed\n".write(toFile: repo.repo + "/a.txt", atomically: true, encoding: .utf8)
        try await repo.git("commit", "-q", "-am", "task", in: repo.repo)
        try "one\ntwo\n".write(toFile: repo.repo + "/a.txt", atomically: true, encoding: .utf8)
        app.inspector.show(taskId: UUID(), root: repo.repo, baseBranch: { nil })  // another context, then back
        app.inspector.show(taskId: t, root: repo.repo, baseBranch: { "main" })
        await settle(app.inspector)
        app.openDiff(path: "a.txt")
        await settle(app.inspector)
        let two = try #require(rowIndex(app) { $0.kind == .added && $0.text == "two" })
        app.selectDiffRow(two)
        #expect(app.activeDiffSelection == two)
        // A line inserted above: the same line stays selected at its new row.
        try "top\none\ntwo\n".write(toFile: repo.repo + "/a.txt", atomically: true, encoding: .utf8)
        app.inspector.refresh(.status)
        await settle(app.inspector)
        let moved = try #require(rowIndex(app) { $0.kind == .added && $0.text == "two" })
        #expect(moved == two + 1)
        #expect(app.activeDiffSelection == moved)
        // ⌥B: the selected deleted line of the base version is gone → no selection.
        let deleted = try #require(rowIndex(app) { $0.kind == .deleted })
        app.selectDiffRow(deleted)
        app.inspector.toggleMode()
        await settle(app.inspector)
        #expect(app.activeDiffContent.rows.contains { if case .line(let l) = $0 { l.text == "committed" } else { false } })
        #expect(app.activeDiffSelection == nil)
        #expect(app.activeDiff?.selectedRowId == nil)
    }

    /// A subfolder project: the diff tab's path is relative to the subfolder, ↩ opens the file under it.
    @Test func subfolderDiffOpensInEditor() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        try FileManager.default.createDirectory(atPath: repo.repo + "/sub", withIntermediateDirectories: true)
        try "one\n".write(toFile: repo.repo + "/sub/s.txt", atomically: true, encoding: .utf8)
        try await repo.git("add", "sub", in: repo.repo); try await repo.git("commit", "-q", "-m", "s", in: repo.repo)
        try "one\ntwo\n".write(toFile: repo.repo + "/sub/s.txt", atomically: true, encoding: .utf8)
        app.inspector.show(taskId: t, root: repo.repo + "/sub", baseBranch: { nil })
        await settle(app.inspector)
        #expect(app.inspector.changes?.files.map(\.path) == ["s.txt"])
        app.openDiff(path: "s.txt")
        await settle(app.inspector)
        let two = try #require(rowIndex(app) { $0.kind == .added && $0.text == "two" })
        app.selectDiffRow(two)
        var opened: (String, Int?)?
        app.onOpenInEditor = { path, line, _ in opened = (path, line) }
        app.openActiveDiffInEditor()
        #expect(opened?.0 == repo.repo + "/sub/s.txt")
        #expect(opened?.1 == 2)
    }

    @Test func diffKeyRouting() {
        #expect(diffKeyRoute(keyCode: 126, modifiers: [], diffActive: false, editingText: false) == nil)
        #expect(diffKeyRoute(keyCode: 126, modifiers: [], diffActive: true, editingText: false) == .up)
        #expect(diffKeyRoute(keyCode: 125, modifiers: [.numericPad, .function], diffActive: true, editingText: false) == .down)
        #expect(diffKeyRoute(keyCode: 36, modifiers: [], diffActive: true, editingText: false) == .enter)
        #expect(diffKeyRoute(keyCode: 11, modifiers: .option, diffActive: false, editingText: false) == nil)
        #expect(diffKeyRoute(keyCode: 11, modifiers: .option, diffActive: true, editingText: true) == nil)
        #expect(diffKeyRoute(keyCode: 11, modifiers: .option, diffActive: true, editingText: false) == .toggleMode)
        #expect(diffKeyRoute(keyCode: 11, modifiers: [], diffActive: true, editingText: false) == nil)  // plain b
        #expect(diffKeyRoute(keyCode: 13, modifiers: .command, diffActive: true, editingText: false) == .close)
        #expect(diffKeyRoute(keyCode: 13, modifiers: .command, diffActive: false, editingText: false) == nil)
        #expect(diffKeyRoute(keyCode: 126, modifiers: .command, diffActive: true, editingText: false) == nil)
    }

    private func rows(_ diff: String, origPath: String? = nil) -> [DiffRow] {
        diffRows(.loaded(parseUnifiedDiff(diff)), origPath: origPath)
    }

    @Test func openTargetRules() {
        let r = rows("""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -10,3 +10,3 @@ ctx
         keep
        -old
        +new
         tail
        """)
        // hunk, keep(10), -old, +new(11), tail(12)
        #expect(r.count == 5)
        #expect(openTarget(rows: r, selected: 3) == 11)  // the added line itself
        #expect(openTarget(rows: r, selected: 2) == 11)  // deleted → next non-deleted line
        #expect(openTarget(rows: r, selected: 4) == 12)
        #expect(openTarget(rows: r, selected: 0) == 10)  // hunk header → newStart
        #expect(openTarget(rows: r, selected: nil) == 11)  // first added line
        let onlyDeleted = rows("""
        diff --git a/f b/f
        deleted file mode 100644
        --- a/f
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -x
        -y
        """)
        #expect(openTarget(rows: onlyDeleted, selected: nil) == nil)
        #expect(openTarget(rows: onlyDeleted, selected: 1) == nil)
        #expect(openTarget(rows: diffRows(.loaded(.binary), origPath: nil), selected: nil) == nil)
        // Deletions only in the middle of a file: newStart of the hunk.
        let midDelete = rows("""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -5,1 +4,0 @@
        -gone
        """)
        #expect(openTarget(rows: midDelete, selected: nil) == 4)
    }

    @Test func rowsForStates() {
        #expect(diffRows(.loaded(.binary), origPath: nil) == [.notice(L10n.diffBinary)])
        #expect(diffRows(.loaded(.tooLarge(lines: 25_000)), origPath: nil) == [.notice(L10n.diffTooLarge(25_000))])
        #expect(diffRows(.loaded(.notAFile), origPath: nil) == [.notice(L10n.diffNotAFile)])
        #expect(diffRows(.notChanged, origPath: nil) == [.notice(L10n.diffNotChanged)])
        #expect(diffRows(.failed("boom"), origPath: nil) == [.notice(L10n.gitFailed("boom"))])
        #expect(diffRows(.loading, origPath: nil) == [])
        // Mode change only when both are known and differ; a new file's mode is not a change.
        let mode = rows("diff --git a/f b/f\nold mode 100644\nnew mode 100755\n", origPath: "old name")
        #expect(mode == [.meta(L10n.diffRenamedFrom("old name")), .meta(L10n.diffModeChange("100644", "100755"))])
        let added = rows("diff --git a/f b/f\nnew file mode 100644\n--- /dev/null\n+++ b/f\n@@ -0,0 +1 @@\n+x\n")
        #expect(added.count == 2)
        #expect(!added.contains { if case .meta = $0 { true } else { false } })
        // Item ids are unique (stable keys for the lazy list), also for repeated identical lines.
        let diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+b\n@@ -9,2 +9,2 @@\n-b\n+b\n a\n"
        let items = DiffContentCache().content(.loaded(parseUnifiedDiff(diff)), origPath: nil).items
        #expect(items.count == 8)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    /// The row selected in `before` (by index) found again in `after` by its id, as after a refresh.
    private func follow(_ before: String, _ index: Int, _ after: String) -> Int? {
        let head = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
        let cache = DiffContentCache()
        let id = cache.content(.loaded(parseUnifiedDiff(head + before)), origPath: nil).items[index].id
        return cache.content(.loaded(parseUnifiedDiff(head + after)), origPath: nil).indexById[id]
    }

    @Test func selectionStaysOnIdenticalLineWhenLinesInsertedAbove() {
        // The second added `}`; another `}` is inserted at the top of the same hunk.
        #expect(follow("@@ -1,1 +1,5 @@\n+x\n+}\n+y\n+}\n end\n", 4,
                       "@@ -1,1 +1,6 @@\n+}\n+x\n+}\n+y\n+}\n end\n") == 5)
        // The last context `}`; a new hunk with a context `}` appears above.
        let hunk = "@@ -10,3 +10,3 @@\n }\n-a\n+b\n }\n"
        let shifted = "@@ -1,2 +1,3 @@\n x\n+y\n }\n@@ -10,3 +11,3 @@\n }\n-a\n+b\n }\n"
        #expect(follow(hunk, 4, shifted) == 8)
        #expect(follow(hunk, 1, shifted) == 5)
        // The hunk header itself (its new start moved).
        #expect(follow(hunk, 0, shifted) == 4)
    }
}

extension DiffTabTests {
    /// The Git tab's file click: the same diff tab, that commit's diff (not the working tree), ↑/↓ through its files.
    @Test func commitFileOpensInTheDiffTab() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        app.openDiff(path: "a.txt")
        let gp = app.gitPanel
        gp.show(taskId: t, root: repo.repo, git: { Git(repo: $0) }, remote: false)
        gp.tabShown = true
        gp.setOnScreen(true)
        while let task = gp.loadTask { await task.value }
        let hash = try #require(gp.commits.first?.hash)  // "c c.txt"
        gp.select(hash)
        while let task = gp.loadTask { await task.value }
        let file = try #require(gp.details?.files.first)
        app.openCommitDiff(hash: hash, file: file)
        #expect(app.diffTabs.count == 1 && app.activeDiff?.commit == hash && app.activeDiff?.path == "c.txt")
        #expect(app.inspector.diffPath == nil)  // the Changes row is no longer selected
        while let task = gp.loadTask { await task.value }
        let lines = app.activeDiffContent.rows.compactMap { row -> DiffLine? in if case .line(let l) = row { l } else { nil } }
        #expect(lines.count == 1 && lines[0].kind == .added && lines[0].text != "changed")  // the commit, not the edit
        app.diffNeighbour(1)
        #expect(app.activeDiff?.path == "c.txt")  // one file only
        app.openDiff(path: "b.txt")
        #expect(app.activeDiff?.commit == nil && app.inspector.diffPath == "b.txt")
    }
}
