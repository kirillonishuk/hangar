import AppKit
import Exec
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

    /// ↩ after a clean exit relaunches with `--continue`: without a session id only the folder's first leaf may.
    @Test func relaunchSecondClaudeSameCwdStartsFresh() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp"), Leaf(kind: .claude, cwd: "/tmp")])
        let app = app(s)
        let previous = LaunchMode(restoring: false, initialPrompt: nil)
        let tabs = app.state.tasks[0].tabs
        let second = try app.spec(for: tabs[1].root.leaves[0], tabId: tabs[1].id, context: .relaunch(previous: previous, exitCode: 0))
        #expect(!second.1.restoring)
        let first = try app.spec(for: tabs[0].root.leaves[0], tabId: tabs[0].id, context: .relaunch(previous: previous, exitCode: 0))
        #expect(first.1.restoring)
    }

    /// "/a/" and "/a" are one folder: one `--continue` slot.
    @Test func trailingSlashIsSameCwd() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a/"), Leaf(kind: .claude, cwd: "/a")])
        let set = resumeSet(for: s)
        #expect(set.contains(ids[0]) && !set.contains(ids[1]))
    }

    @Test func differentCwdsBothContinue() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/b")])
        #expect(resumeSet(for: s) == Set(ids))
    }

    /// `--continue` picks the latest chat of a cwd on one machine: the same path on another host is another chat.
    @Test func samePathOnDifferentHostsBothContinue() {
        var s = WorkspaceState()
        let a = s.addRemoteProject(name: "a", host: "dev1", path: "/srv/app")
        let b = s.addRemoteProject(name: "b", host: "dev2", path: "/srv/app")
        let l = s.addProject(name: "l", path: "/srv/app")
        var ids: [UUID] = []
        for p in [a, b, l] {
            let t = s.addTask(projectId: p, name: "t")
            let leaf = Leaf(kind: .claude, cwd: "/srv/app")
            s.tasks[s.tasks.firstIndex { $0.id == t }!].tabs = [Tab(title: "claude", root: .leaf(leaf), focusedLeafId: leaf.id)]
            ids.append(leaf.id)
        }
        #expect(resumeSet(for: s) == Set(ids))
    }

    /// #89: `--continue` next to a leaf with a known id would most likely attach to that leaf's conversation.
    @Test func sessionIdAlwaysResumesAndTakesTheContinueSlot() {
        let (s, ids) = state([Leaf(kind: .claude, cwd: "/a"), Leaf(kind: .claude, cwd: "/a", agentSessionId: "x"),
                              Leaf(kind: .claude, cwd: "/a/", agentSessionId: "y"), Leaf(kind: .claude, cwd: "/b"),
                              Leaf(kind: .codex, cwd: "/a")])
        let set = resumeSet(for: s)
        #expect(set.contains(ids[1]) && set.contains(ids[2]))
        #expect(!set.contains(ids[0]))
        #expect(set.contains(ids[3]) && set.contains(ids[4]))  // another folder, another agent: their own slots
    }

    /// The slot is per folder across sessions: a leaf with an id in another live session blocks it too.
    @Test func sessionIdInAnotherTaskBlocksContinue() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        s.addTask(projectId: p, name: "one")
        s.addTask(projectId: p, name: "two")
        let a = Leaf(kind: .claude, cwd: "/a"), b = Leaf(kind: .claude, cwd: "/a", agentSessionId: "x")
        s.tasks[0].tabs = [Tab(title: "claude", root: .leaf(a), focusedLeafId: a.id)]
        s.tasks[1].tabs = [Tab(title: "claude", root: .leaf(b), focusedLeafId: b.id)]
        #expect(resumeSet(for: s) == [b.id])
    }

    /// Two leaves without ids: the first continues; once its hooks give it an id, ↩ on the second still starts fresh
    /// (before #89 the second became "first without an id" and `--continue`d the first one's conversation).
    @Test func relaunchAfterNeighbourGotIdStartsFresh() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp"), Leaf(kind: .claude, cwd: "/tmp")])
        let app = app(s)
        let tabs = app.state.tasks[0].tabs
        app.perform { $0.setAgentSessionId(leafId: tabs[0].root.leaves[0].id, "s1") }
        let previous = LaunchMode(restoring: true, initialPrompt: nil)
        let second = try app.spec(for: tabs[1].root.leaves[0], tabId: tabs[1].id, context: .relaunch(previous: previous, exitCode: 0))
        #expect(!second.1.restoring)
        #expect(!second.0.command.contains("--continue"))
        let first = try app.spec(for: tabs[0].root.leaves[0], tabId: tabs[0].id, context: .relaunch(previous: previous, exitCode: 0))
        #expect(first.1.restoring && first.0.command.contains("--resume s1"))
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
        app.createTask(projectId: p, name: "t", firstMessage: "  fix bug \n", mode: .mainFolder)
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
        #expect(app.launchContext(for: a.id) == .restored(inResumeSet: false))  // c's known id takes the folder's slot (#89)
        #expect(app.launchContext(for: b.id) == .restored(inResumeSet: false))
        #expect(app.launchContext(for: c.id) == .restored(inResumeSet: true))
        #expect(app.launchContext(for: live.id) == .restored(inResumeSet: true))
    }

    /// A restored (or freshly split) tree keeps its saved ratios: NSSplitView's own layout pass must not
    /// collapse a pane to 0 (live: a nested split showed one pane, a restored 0.39 split showed 0 / all).
    @Test func nestedSplitKeepsRatiosThroughLayout() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 801, height: 401), styleMask: [.titled], backing: .buffered, defer: true)
        let outer = RatioSplitView(axis: .horizontal, ratio: 0.25)
        let inner = RatioSplitView(axis: .vertical, ratio: 0.75)
        outer.frame = window.contentView!.bounds
        window.contentView!.addSubview(outer)
        let a = NSView(), b = NSView(), c = NSView()
        outer.addSubview(a)
        outer.addSubview(inner)
        inner.addSubview(b)
        inner.addSubview(c)
        outer.adjustSubviews()
        inner.adjustSubviews()
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(a.frame.width == 200)
        #expect(inner.frame.width == 600)
        #expect(b.frame.height == 300)
        #expect(c.frame.height == 100)
        // A window resize keeps the proportions.
        window.setContentSize(NSSize(width: 401, height: 201))
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(a.frame.width == 100)
        #expect(b.frame.height == 150)
    }

    /// Fast task switches restart the drawer animation of the tab area; autoresizing a split through interrupted
    /// animations drifted its height (live: a hidden split tab came back 1305 pt tall in a 1085 pt area, or 220 pt).
    @Test func tabSplitFillsTabThroughInterruptedAnimations() {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        window.contentView!.addSubview(root)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        root.addSubview(content)
        let tab = FillView(frame: content.bounds)
        tab.autoresizingMask = [.width, .height]
        content.addSubview(tab)
        let split = RatioSplitView(axis: .horizontal, ratio: 0.5)
        split.frame = tab.bounds
        tab.addSubview(split)
        split.addSubview(NSView())
        split.addSubview(NSView())
        for i in 0..<20 {
            let h: CGFloat = i % 2 == 0 ? 380 : 500
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                content.animator().frame = NSRect(x: 0, y: 500 - h, width: 800, height: h)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(content.frame.height == 500)
        #expect(split.frame == tab.bounds)
    }
}
