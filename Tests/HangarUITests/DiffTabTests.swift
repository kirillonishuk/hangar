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
        let repo = try TempRepo()
        try repo.commit(file: "b.txt", on: "main")
        try repo.commit(file: "c.txt", on: "main")
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

    @Test func clickReplacesDiffTab() async throws {
        let (app, repo, t) = try await makeApp()
        defer { cleanup(repo) }
        let tabs = app.state.tasks.first { $0.id == t }!.tabs.count
        app.openDiff(path: "a.txt")
        app.openDiff(path: "b.txt")
        #expect(app.diffTabs.count == 1)
        #expect(app.diffTabs[t] == DiffTab(path: "b.txt", active: true, selectedRow: nil))
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
        // Ids are unique (stable keys for the lazy list).
        let r = rows("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+b\n@@ -9,1 +9,1 @@\n-z\n+z\n")
        #expect(Set(r.map(\.id)).count == r.count)
    }
}
