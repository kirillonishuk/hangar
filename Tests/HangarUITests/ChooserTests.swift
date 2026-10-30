import AppKit
import Exec
import Foundation
import History
import Testing
@testable import HangarUI
import Workspace

/// ⌘D / ⇧⌘D open a chooser pane: Claude, Codex, Terminal (↩), Editor (⌘P picker), and «Продолжить» with the folder's
/// latest conversations; the empty session offers the same.
@MainActor @Suite struct ChooserTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-chooser-\(UUID())")

    /// One session in /work/shop with a claude tab; agent config dirs under the temp root (never the owner's).
    private func makeApp(_ build: (inout WorkspaceState, UUID) -> Void = { _, _ in }) -> (AppState, task: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop", path: "/work/shop")
        let t = s.addTask(projectId: p, name: "main")
        s.addTab(taskId: t, kind: .claude)
        build(&s, t)
        s.selectedTaskId = t
        let app = AppState(state: s, store: StateStore(directory: root.appendingPathComponent("state")), config: HangarConfig(),
                           configURL: root.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        app.codexRead = nil
        app.claudeSettingsURL = root.appendingPathComponent("claude/settings.json")
        app.codexConfigURL = root.appendingPathComponent("codex/config.toml")
        return (app, t)
    }

    private func firstLeaf(_ app: AppState, tab n: Int = 0) -> UUID { app.state.tasks[0].tabs[n].root.leaves[0].id }

    private func leaf(_ app: AppState, _ id: UUID) -> Leaf? { app.leaf(id: id) }

    private func conversation(_ agent: HistoryAgent, id: String, cwd: String = "/work/shop", at: Date = Date(),
                              open: Bool = false) -> Conversation {
        Conversation(id: id, agent: agent, cwd: cwd, started: nil, lastActivity: at, messageCount: 2,
                     messageCountIsEstimate: false, gitBranch: nil, title: "t-" + id, isOpen: open)
    }

    // MARK: Choices

    /// A short pane (live: a chooser under two editors) shows fewer «Продолжить» rows, a tiny one none, so the list never
    /// reaches over the pane header; a narrow one narrows the list.
    @Test func continueListFitsThePane() {
        #expect(continueFit(CGSize(width: 1000, height: 800)) == (Theme.continueRows, Theme.continueWidth))
        let short = continueFit(CGSize(width: 580, height: 260))
        #expect(short.rows > 0 && short.rows < Theme.continueRows)
        let top = 260 / 2 - Theme.Height.rowLarge / 2 - Theme.sheetGap - CGFloat(short.rows + 1) * Theme.Height.rowLarge
        #expect(top >= 0)
        #expect(continueFit(CGSize(width: 580, height: 100)).rows == 0)
        #expect(continueFit(CGSize(width: 300, height: 800)).width == 300 - 2 * Theme.sheetGap)
        #expect(continueFit(CGSize(width: 1000, height: 800), extra: 1).rows <= Theme.continueRows)
    }

    @Test func choices() {
        #expect(chooserChoices() == [.claude, .codex, .shell, .editor])
        let e1 = Leaf(kind: .editor, cwd: "/")
        var tab = Workspace.Tab(title: "t", root: .leaf(e1), focusedLeafId: e1.id)
        #expect(chooserEditorEnabled(tab))
        tab.root = SplitNode.split(axis: .horizontal, ratio: 0.5, first: tab.root, second: .leaf(Leaf(kind: .editor, cwd: "/")))
        #expect(!chooserEditorEnabled(tab))  // two editors per tab at most
    }

    @Test func splitMakesChooserExceptHostShell() throws {
        let (app, _) = makeApp()
        let first = firstLeaf(app)
        app.split(leafId: first, axis: .horizontal)
        let leaves = app.state.tasks[0].tabs[0].root.leaves
        #expect(leaves.map(\.kind) == [.claude, .choose])
        #expect(app.state.tasks[0].tabs[0].focusedLeafId == leaves[1].id)

        var s = app.state
        let host = s.openHostShell(host: "box")
        app.perform { $0 = s }
        let hostLeaf = try #require(app.state.tasks.first { $0.id == host.task }?.tabs[0].root.leaves[0].id)
        app.split(leafId: hostLeaf, axis: .vertical)
        #expect(app.state.tasks.first { $0.id == host.task }?.tabs[0].root.leaves.map(\.kind) == [.shell, .shell])
    }

    @Test func chooseKindStartsTerminalButNotEditor() {
        let (app, _) = makeApp()
        app.split(leafId: firstLeaf(app), axis: .horizontal)
        let c = app.state.tasks[0].tabs[0].root.leaves[1].id
        app.chooseKind(c, .editor)  // an editor needs a file: it goes through the picker
        #expect(leaf(app, c)?.kind == .choose)
        app.chooseKind(c, .shell)
        #expect(leaf(app, c)?.kind == .shell)
        #expect(app.location(ofLeaf: c) != nil)
    }

    @Test func chooseEditorForOpenFileFocusesIt() throws {
        let (app, task) = makeApp { s, t in _ = s.openFileTab(taskId: t, path: "/work/shop/a.ts", line: nil, column: nil, preview: false) }
        let tabs = app.state.tasks[0].tabs
        app.activate(tabId: tabs[0].id)
        app.split(leafId: firstLeaf(app), axis: .horizontal)
        let c = app.state.tasks[0].tabs[0].root.leaves[1].id
        app.chooseEditor(c, path: "/work/shop/a.ts")
        #expect(app.state.tasks.first { $0.id == task }?.activeTabId == tabs[1].id)  // the file's own tab
        #expect(leaf(app, c)?.kind == .choose)  // the chooser stays
        app.activate(tabId: tabs[0].id)
        app.chooseEditor(c, path: "/work/shop/b.ts")
        let e = try #require(leaf(app, c))
        #expect(e.kind == .editor && e.openFile == "/work/shop/b.ts")
        #expect(app.state.tasks.first { $0.id == task }?.activeTabId == tabs[0].id)
    }

    // MARK: Continue

    /// The chooser resumes the conversation in itself: the first launch already has the resume context.
    @Test func chooseConversationResumesInPane() throws {
        let (app, _) = makeApp()
        app.split(leafId: firstLeaf(app), axis: .horizontal)
        let c = app.state.tasks[0].tabs[0].root.leaves[1].id
        var firstContext: LaunchContext?
        app.didChange = { if app.leaf(id: c)?.kind == .codex, firstContext == nil { firstContext = app.launchContext(for: c) } }
        app.chooseConversation(c, conversation(.codex, id: "0190a1b2-c3d4", cwd: "/tmp"))
        let l = try #require(leaf(app, c))
        #expect(l.kind == .codex && l.cwd == "/tmp" && l.agentSessionId == "0190a1b2-c3d4")
        let context = try #require(firstContext)
        let (spec, mode) = try app.spec(for: l, tabId: app.state.tasks[0].tabs[0].id, context: context)
        #expect(mode.restoring)
        #expect(spec.command.contains("resume 0190a1b2-c3d4"))
        // An unsafe id resumes nothing.
        app.split(leafId: firstLeaf(app), axis: .horizontal)
        let c2 = try #require(app.state.tasks[0].tabs[0].root.leaves.first { $0.kind == .choose }?.id)
        app.chooseConversation(c2, conversation(.claude, id: "--evil"))
        #expect(leaf(app, c2)?.kind == .choose)
    }

    /// The empty session's «Продолжить» (and «Сессии») open a resumed tab: its first launch must resume, not start fresh.
    @Test func openConversationResumesOnFirstLaunch() throws {
        let (app, _) = makeApp()
        var contexts: [UUID: LaunchContext] = [:]
        app.didChange = {
            for l in app.state.tasks[0].tabs.flatMap(\.root.leaves) where contexts[l.id] == nil { contexts[l.id] = app.launchContext(for: l.id) }
        }
        app.openConversation(conversation(.claude, id: "abc-123", cwd: "/tmp"))
        let l = try #require(app.state.tasks[0].tabs.last?.root.leaves.first)
        #expect(l.agentSessionId == "abc-123")
        let (spec, _) = try app.spec(for: l, tabId: app.state.tasks[0].tabs.last!.id, context: try #require(contexts[l.id]))
        #expect(spec.command.contains("--resume abc-123"))
    }

    @Test func recentListsLatestNotOpenOfThisFolder() {
        let now = Date()
        let list = (0..<8).map { conversation(.claude, id: "c\($0)", at: now.addingTimeInterval(-Double($0) * 60)) }
            + [conversation(.codex, id: "running", at: now.addingTimeInterval(10)),
               conversation(.claude, id: "worktree", cwd: "/work/shop/wt/feature", at: now.addingTimeInterval(20)),
               conversation(.claude, id: "subfolder", cwd: "/work/shop/src", at: now.addingTimeInterval(5))]
        let out = recentConversations(list, inner: ["/work/shop/wt/feature"], open: ["running"])
        #expect(out.map(\.id) == ["subfolder", "c0", "c1", "c2", "c3"])
    }

    @Test func recentLoadsFromFixtureHistory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (app, task) = makeApp()
        let dir = root.appendingPathComponent("claude/projects/" + claudeProjectDirName("/work/shop"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "11111111-1111-4111-8111-111111111111"
        let line = #"{"type":"user","timestamp":"2026-10-25T10:00:00Z","cwd":"/work/shop","message":{"content":"объясни store"}}"#
        try (line + "\n").write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        #expect(app.recent(for: task).isEmpty)
        await app.loadRecent(taskId: task)
        let recent = app.recent(for: task)
        #expect(recent.map(\.id) == [id])
        #expect(recent.first?.title == "объясни store")
        #expect(app.recentFolder(of: task) == "/work/shop")
    }

    // MARK: Pane

    private func makeArea() -> (AppState, TerminalArea, NSWindow, chooser: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .choose)
        s.selectedTaskId = t
        let app = AppState(state: s, store: StateStore(directory: root.appendingPathComponent("state")), config: HangarConfig(),
                           configURL: root.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let area = TerminalArea(app: app)
        area.frame = window.contentView!.bounds
        window.contentView!.addSubview(area)
        app.didChange = { area.sync() }
        area.sync()
        return (app, area, window, app.state.tasks[0].tabs[0].root.leaves[0].id)
    }

    @Test func chooserPaneTakesKeysItself() throws {
        let (app, area, window, c) = makeArea()
        let view = try #require(area.leafViews[c])
        #expect(view.chooser != nil && view.surface == nil)
        #expect(view.keyView === view)
        #expect(window.firstResponder === view)
        var chosen: [LeafKind] = []
        view.onChoose = { chosen.append($0) }
        for code: UInt16 in [36, 76] { view.keyDown(with: try key(code, window)) }
        #expect(chosen == [.shell, .shell])  // ↩ and the keypad's Enter: Terminal
        // After a click the keyboard may sit in the chooser's SwiftUI view: ↩ still reaches the pane.
        let host = try #require(view.chooser)
        #expect(window.makeFirstResponder(host) && window.firstResponder !== view)
        window.firstResponder?.keyDown(with: try key(36, window))
        #expect(chosen.count == 3)
        window.makeFirstResponder(view)
        view.keyDown(with: try key(53, window))  // Esc closes the pane
        #expect(app.location(ofLeaf: c) == nil)
        #expect(area.leafViews[c] == nil)
    }

    private func key(_ code: UInt16, _ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
    }
}
