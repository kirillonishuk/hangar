import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct RestoreTests {
    @Test func loadAlertTexts() {
        defer { L10n.language = .system }
        let url = URL(fileURLWithPath: "/tmp/x/state.json")
        L10n.language = .ru
        #expect(loadAlert(for: .empty) == nil)
        #expect(loadAlert(for: .loaded(WorkspaceState())) == nil)
        #expect(loadAlert(for: .recoveredFromCorrupt(backup: URL(fileURLWithPath: "/tmp/x/state.json.bak")))
            == "Состояние повреждено, копия: /tmp/x/state.json.bak")
        #expect(loadAlert(for: .unreadable(url))
            == "Файл состояния не читается: /tmp/x/state.json. Hangar работает без сохранения.")
        L10n.language = .en
        #expect(loadAlert(for: .unreadable(url))?.contains("/tmp/x/state.json") == true)
        #expect(loadAlert(for: .unreadable(url))?.contains("Файл") == false)
    }

    @Test func drawerLeafIsRestoredToo() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .claude)
        s.toggleDrawer(taskId: t)
        let tabLeaf = s.tasks[0].tabs[0].root.leaves[0].id
        let drawerLeaf = s.tasks[0].drawer.leaf!.id
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-restore-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"))
        #expect(app.isRestored(leafId: tabLeaf))
        #expect(app.isRestored(leafId: drawerLeaf))
        #expect(!app.isRestored(leafId: UUID()))
    }

    /// One task in "/a" (and optionally "/b") with the given extra leaves as separate tabs.
    private func state(_ leaves: [Leaf]) -> (WorkspaceState, [UUID]) {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        s.addTask(projectId: p, name: "t")
        s.tasks[0].tabs = leaves.map { Tab(title: $0.kind.rawValue, root: .leaf($0), focusedLeafId: $0.id) }
        return (s, leaves.map(\.id))
    }

    @Test func twoClaudeSameCwdOnlyFirstContinues() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/a")])
        let set = resumeSet(for: s)
        #expect(set.contains(ids[0]))
        #expect(!set.contains(ids[1]))
    }

    @Test func differentCwdsBothContinue() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/b")])
        #expect(resumeSet(for: s) == Set(ids))
    }

    @Test func sessionIdAlwaysResumes() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/a", agentSessionId: "x"),
                              Leaf(kind: .claude, cwd: "/a", agentSessionId: "y")])
        let set = resumeSet(for: s)
        #expect(set.contains(ids[1]) && set.contains(ids[2]) && set.contains(ids[0]))
    }

    @Test func codexSameRule() {
        let (s, ids) = state([Leaf(kind: .codex, cwd: "/a"), Leaf(kind: .codex, cwd: "/a"),
                              Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .shell, cwd: "/a"), Leaf(kind: .shell, cwd: "/a")])
        let set = resumeSet(for: s)
        #expect(set.contains(ids[0]) && !set.contains(ids[1]))  // claude in the same cwd is a separate (kind, cwd) key
        #expect(set.contains(ids[2]))
        #expect(set.contains(ids[3]) && set.contains(ids[4]))
    }

    @Test func archivedTaskDoesNotTakeContinueSlot() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let old = s.addTask(projectId: p, name: "old")
        s.addTask(projectId: p, name: "live")
        let a = Leaf(kind: .claude, cwd: "/a"), b = Leaf(kind: .claude, cwd: "/a")
        s.tasks[0].tabs = [Tab(title: "claude", root: .leaf(a), focusedLeafId: a.id)]
        s.tasks[1].tabs = [Tab(title: "claude", root: .leaf(b), focusedLeafId: b.id)]
        s.archiveTask(id: old)
        let set = resumeSet(for: s)
        #expect(set.contains(b.id))
        #expect(!set.contains(a.id))
    }

    private func app(_ s: WorkspaceState) -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-restore-\(UUID())")
        return AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                        configURL: dir.appendingPathComponent("c.toml"))
    }

    @Test func createdUsesPromptOnce() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let app = app(s)
        app.createTask(projectId: p, name: "t", firstMessage: "  fix bug \n")
        let leaf = app.state.tasks[0].tabs[0].root.leaves[0].id
        #expect(app.launchContext(for: leaf) == .created(prompt: "fix bug"))
        #expect(app.launchContext(for: leaf) == .created(prompt: nil))
    }

    @Test func restoredLeavesGetRestoredContext() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/a")])
        let app = app(s)
        #expect(app.launchContext(for: ids[0]) == .restored(inResumeSet: true))
        #expect(app.launchContext(for: ids[1]) == .restored(inResumeSet: false))
        #expect(app.launchContext(for: UUID()) == .created(prompt: nil))
    }

    @Test func unarchiveResumesAgents() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let old = s.addTask(projectId: p, name: "old")
        s.addTask(projectId: p, name: "live")
        let a = Leaf(kind: .claude, cwd: "/a"), b = Leaf(kind: .claude, cwd: "/a")
        let c = Leaf(kind: .claude, cwd: "/a", agentSessionId: "x"), live = Leaf(kind: .claude, cwd: "/a")
        s.tasks[0].tabs = [a, b, c].map { Tab(title: "claude", root: .leaf($0), focusedLeafId: $0.id) }
        s.tasks[1].tabs = [Tab(title: "claude", root: .leaf(live), focusedLeafId: live.id)]
        s.archiveTask(id: old)
        let app = app(s)
        #expect(app.launchContext(for: a.id) == .created(prompt: nil))  // archived at startup: not restored
        app.restore(taskId: old)
        #expect(app.launchContext(for: a.id) == .restored(inResumeSet: true))
        #expect(app.launchContext(for: b.id) == .restored(inResumeSet: false))
        #expect(app.launchContext(for: c.id) == .restored(inResumeSet: true))
        #expect(app.launchContext(for: live.id) == .restored(inResumeSet: true))
    }
}
