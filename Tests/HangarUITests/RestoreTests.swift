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

    /// One task with the given leaves as separate tabs.
    private func state(_ leaves: [Leaf]) -> (WorkspaceState, [UUID]) {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        s.addTask(projectId: p, name: "t")
        s.tasks[0].tabs = leaves.map { Tab(title: $0.kind.rawValue, root: .leaf($0), focusedLeafId: $0.id) }
        return (s, leaves.map(\.id))
    }

    private func app(_ s: WorkspaceState) -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-restore-\(UUID())")
        return AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                        configURL: dir.appendingPathComponent("c.toml"))
    }

    private func launch(_ app: AppState, tab i: Int, _ context: LaunchContext) throws -> (LaunchSpec, LaunchMode) {
        let tab = app.state.tasks[0].tabs[i]
        return try app.spec(for: tab.root.leaves[0], tabId: tab.id, context: context)
    }

    private func storedId(_ app: AppState, tab i: Int) -> String? { app.state.tasks[0].tabs[i].root.leaves[0].agentSessionId }

    /// #119: two chats in one folder without ids never pick a conversation by recency (`--continue` took the folder's
    /// latest one: another tab's or a terminal's). Each starts its own conversation under an id stored at once.
    @Test func noIdNeverRestoresByRecency() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp"), Leaf(kind: .claude, cwd: "/tmp")])
        let app = app(s)
        let first = try launch(app, tab: 0, .restored), second = try launch(app, tab: 1, .restored)
        for (spec, mode) in [first, second] {
            #expect(!mode.restoring)
            #expect(!spec.command.contains("--continue") && !spec.command.contains("--resume"))
        }
        let a = try #require(storedId(app, tab: 0)), b = try #require(storedId(app, tab: 1))
        #expect(a != b && UUID(uuidString: a) != nil && UUID(uuidString: b) != nil)
        #expect(first.0.command.contains("--session-id \(a)") && second.0.command.contains("--session-id \(b)"))
    }

    /// A known id resumes only that conversation, whatever the neighbours have; ↩ after a clean exit too.
    @Test func knownIdResumesItsOwnConversation() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp", agentSessionId: "s1"), Leaf(kind: .claude, cwd: "/tmp")])
        let app = app(s)
        let own = try launch(app, tab: 0, .restored)
        #expect(own.1.restoring && own.0.command.contains("--resume s1"))
        let clean = try launch(app, tab: 0, .relaunch(previous: own.1, exitCode: 0))
        #expect(clean.1.restoring && clean.0.command.contains("--resume s1"))
        #expect(storedId(app, tab: 0) == "s1")
        // The neighbour without an id starts its own conversation, never `s1` by recency.
        let other = try launch(app, tab: 1, .relaunch(previous: own.1, exitCode: 0))
        #expect(!other.1.restoring && !other.0.command.contains("s1") && storedId(app, tab: 1) != "s1")
    }

    /// A resumed chat that ended with an error comes back as itself on ↩: its id is never replaced.
    @Test func errorExitResumesTheSameId() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp", agentSessionId: "s1")])
        let app = app(s)
        let again = try launch(app, tab: 0, .relaunch(previous: LaunchMode(restoring: true, initialPrompt: nil), exitCode: 1))
        #expect(again.1.restoring && again.0.command.contains("--resume s1") && storedId(app, tab: 0) == "s1")
    }

    /// On this Mac the transcript decides: recorded here → resume; never written → started under the same id; recorded in
    /// another folder (claude would not find it from here) → a new id, stored, and the note.
    @Test func localTranscriptDecides() throws {
        let id = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp", agentSessionId: id)])
        let app = app(s)
        let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-cfg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cfg) }
        app.claudeSettingsURL = cfg.appendingPathComponent("settings.json")
        let start = try launch(app, tab: 0, .restored)
        #expect(!start.1.restoring && !start.1.unlinked && start.0.command.contains("--session-id \(id)") && storedId(app, tab: 0) == id)
        let folder = cfg.appendingPathComponent("projects/-tmp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"cwd":"/tmp"}"#.write(to: folder.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        let resume = try launch(app, tab: 0, .restored)
        #expect(resume.1.restoring && resume.0.command.contains("--resume \(id)"))
        try #"{"cwd":"/somewhere/else"}"#.write(to: folder.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        let foreign = try launch(app, tab: 0, .restored)
        let new = try #require(storedId(app, tab: 0))
        #expect(!foreign.1.restoring && foreign.1.unlinked && new != id && foreign.0.command.contains("--session-id \(new)"))
    }

    /// A tab saved without an id (before #119) starts anew and says where its conversation is.
    @Test func unlinkedTabSaysSo() throws {
        let (s, _) = state([Leaf(kind: .claude, cwd: "/tmp"), Leaf(kind: .claude, cwd: "/tmp", agentSessionId: "s1")])
        let app = app(s)
        #expect(try launch(app, tab: 0, .restored).1.unlinked)
        #expect(try !launch(app, tab: 1, .restored).1.unlinked)
        #expect(try !launch(app, tab: 0, .created(prompt: nil)).1.unlinked)
    }

    /// Codex has no `--session-id`: its id comes from `notify`; without one it starts anew, never `resume --last`.
    @Test func codexWithoutIdStartsFresh() throws {
        let (s, _) = state([Leaf(kind: .codex, cwd: "/tmp"), Leaf(kind: .codex, cwd: "/tmp", agentSessionId: "t1")])
        let app = app(s)
        let none = try launch(app, tab: 0, .restored), known = try launch(app, tab: 1, .restored)
        #expect(!none.1.restoring && !none.0.command.contains("resume") && storedId(app, tab: 0) == nil)
        #expect(known.1.restoring && known.0.command.contains("codex resume t1"))
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
        #expect(app.launchContext(for: ids[0]) == .restored)
        #expect(app.launchContext(for: ids[1]) == .restored)
        #expect(app.launchContext(for: UUID()) == .created(prompt: nil))
    }

    @Test func unarchiveRestoresItsLeaves() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let old = s.addTask(projectId: p, name: "old")
        s.addTask(projectId: p, name: "live")
        let a = Leaf(kind: .claude, cwd: "/a"), c = Leaf(kind: .claude, cwd: "/a", agentSessionId: "x")
        s.tasks[0].tabs = [a, c].map { Tab(title: "claude", root: .leaf($0), focusedLeafId: $0.id) }
        s.archiveTask(id: old)
        let app = app(s)
        #expect(app.launchContext(for: a.id) == .created(prompt: nil))  // archived at startup: not restored
        app.restore(taskId: old)
        #expect(app.launchContext(for: a.id) == .restored && app.launchContext(for: c.id) == .restored)
        #expect(app.isRestored(leafId: a.id))
    }

    /// The state folder of a test (or debug) store is where its socket, and so the backups, live: never the real one.
    @Test func socketFollowsTheStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-restore-\(UUID())")
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"))
        #expect(app.socketPath == dir.appendingPathComponent("hangar.sock").path)
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

    /// Closing one pane of a split (its shell exited) leaves the other filling the tab. NSSplitView in an Auto Layout
    /// window lays its panes out with constraints (`translatesAutoresizingMaskIntoConstraints = false`); a pane moved
    /// back into the tab kept that, so the next layout pass sized it 0×0 (live: claude kept running, the tab looked closed).
    @Test func paneLeavingSplitFillsTab() {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.contentView!.layoutSubtreeIfNeeded()
        let tab = FillView(frame: root.bounds)
        tab.autoresizingMask = [.width, .height]
        root.addSubview(tab)
        let split = RatioSplitView(axis: .horizontal, ratio: 0.5)
        split.frame = tab.bounds
        tab.addSubview(split)
        let kept = NSView(), closed = NSView()
        kept.wantsLayer = true
        placeLeaf(kept, in: split)
        placeLeaf(closed, in: split)
        split.adjustSubviews()
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(kept.frame.width == 400)
        // As `layoutTab` after the other pane closed: the survivor moves into the tab, the empty split goes.
        closed.removeFromSuperview()
        placeLeaf(kept, in: tab)
        split.removeFromSuperview()
        tab.needsLayout = true
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(kept.translatesAutoresizingMaskIntoConstraints)
        #expect(kept.frame == tab.bounds)
        #expect(tab.bounds.size == NSSize(width: 800, height: 600))
    }
}
