import Foundation
import Testing
import TestSupport
@testable import HangarUI
import Workspace

/// Editor panes of a split on two Monaco pages: a model moving between them never leaves a stale copy behind.
@MainActor @Suite struct EditorPagesTests {
    private func opens(_ page: MonacoPage?) -> [String] {
        (page?.pending ?? []).compactMap { if case .open(let o) = $0.0 { "\((o.path as NSString).lastPathComponent):\(o.text ?? "-")" } else { nil } }
    }

    /// A session replaced by a move (or a reload) sends nothing more: no stray copy of the file on either page.
    @Test func replacedSessionSendsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-editor-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.ts").path
        try "disk".write(toFile: file, atomically: false, encoding: .utf8)
        var leafId = UUID()
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        let t = s.addTask(projectId: p, name: "a")
        let tab = s.addTab(taskId: t, kind: .editor, openFile: file)
        leafId = try #require(s.tasks[0].tabs.first { $0.id == tab }?.root.leaves.first?.id)
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        let host = EditorHost(minimap: false, appearance: EditorAppearance(app.config))
        defer { host.tearDown() }

        let pane = EditorPane(leafId: leafId, app: app, host: host)
        let page0 = host.page(0)
        let first = pane.session
        await pane.rehome(to: 1)
        #expect(pane.page == 1 && host.pages[0] == nil)  // nothing bound to page 0: released
        await first.open(path: file, line: nil, column: nil)
        #expect(opens(page0).isEmpty && opens(host.pages[1]).isEmpty)

        pane.load()  // what the new page's `.ready` does
        #expect(await waitUntil { opens(host.pages[1]) == ["a.ts:disk"] })
        let second = pane.session
        pane.load()  // a reload replaces it too
        await second.open(path: dir.appendingPathComponent("b.ts").path, line: nil, column: nil)
        #expect(await waitUntil { opens(host.pages[1]).count == 2 })
        #expect(opens(host.pages[1]) == ["a.ts:disk", "a.ts:disk"])
        pane.tearDown()
    }

    /// A dirty buffer that can't be read off its page (not ready, torn down) stays there: the move is called off instead
    /// of closing it and reloading the file from disk without the unsaved text.
    @Test func unreadableDirtyBufferStaysOnItsPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-editor-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.ts").path
        try "disk".write(toFile: file, atomically: false, encoding: .utf8)
        var s = WorkspaceState()
        let t = s.addTask(projectId: s.addProject(name: "app", path: dir.path), name: "a")
        let tab = s.addTab(taskId: t, kind: .editor, openFile: file)
        let leafId = try #require(s.tasks[0].tabs.first { $0.id == tab }?.root.leaves.first?.id)
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        let host = EditorHost(minimap: false, appearance: EditorAppearance(app.config))
        defer { host.tearDown() }
        let pane = EditorPane(leafId: leafId, app: app, host: host)
        defer { pane.tearDown() }
        pane.session.adopt(path: file, text: "unsaved", file: EditorSession.File(dirty: true), line: nil, column: nil)
        #expect(host.page(0).isReady == false)  // a fresh page: its buffer can't be read yet

        await pane.rehome(to: 1)
        #expect(pane.page == 0 && host.pages[0] != nil)
        #expect(pane.session.files[file]?.dirty == true)
    }

    /// The page already holds the doc (a pane moved back, a load racing the move): the adopted buffer replaces it.
    @Test func adoptOntoPageHoldingDocShowsAdoptedText() async throws {
        let page = MonacoPage(mode: .editor, inline: false, minimap: false, appearance: EditorAppearance(HangarConfig()))
        defer { page.tearDown() }
        try #require(await waitUntil { page.isReady })
        let doc = UUID()
        page.send(.open(EditorOpen(path: "/r/a.ts", text: "disk", readOnly: false, notice: nil, line: 1, column: 1)), doc: doc)
        page.send(.activate(path: "", line: nil, column: nil), doc: doc)
        #expect(await waitUntil { await page.text(of: doc.uuidString) == "disk" })
        page.send(.open(EditorOpen(path: "/r/a.ts", text: "edited", readOnly: false, notice: nil, line: 1, column: 1, dirty: true)), doc: doc)
        #expect(await waitUntil { await page.text(of: doc.uuidString) == "edited" })
    }
}
