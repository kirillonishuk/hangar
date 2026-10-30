@testable import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Every «open file» (Files, Changes, diff ↩, palette, links, Go to Definition) lands in that file's own tab (#83).
@MainActor @Suite struct EditorRoutingTests {
    private func makeApp(_ build: (inout WorkspaceState) -> Void) -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-editor-route-\(UUID().uuidString)")
        var s = WorkspaceState()
        build(&s)
        return (AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml")), dir)
    }

    /// A file tab is titled by its file (#83); its tooltip holds the path from the session folder. A terminal title
    /// never renames it; an editor tab without a file reads «Editor».
    @Test func fileTabTitledByItsFile() {
        var ids = (t: UUID(), tab: UUID(), plain: UUID())
        let (app, dir) = makeApp { s in
            let p = s.addProject(name: "app", path: "/r/app")
            ids.t = s.addTask(projectId: p, name: "a")
            ids.tab = s.addTab(taskId: ids.t, kind: .editor, openFile: "/r/app/Sources/Model.swift", openLine: 3)
            ids.plain = s.addTab(taskId: ids.t, kind: .editor)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = { (id: UUID) in app.state.tasks[0].tabs.first { $0.id == id }! }
        #expect(app.tabLabel(tab(ids.tab)) == "Model.swift")
        #expect(app.tabHelpTitle(tab(ids.tab), taskId: ids.t) == "Sources/Model.swift")
        app.leafTitles[tab(ids.tab).focusedLeafId] = "zsh"
        #expect(app.tabLabel(tab(ids.tab)) == "Model.swift")
        #expect(app.tabLabel(tab(ids.plain)) == L10n.editor)
        #expect(app.tabHelpTitle(tab(ids.plain), taskId: ids.t) == L10n.editor)
    }

    /// Each visible editor pane of the tab gets its own Monaco page (≤ 2): its current one if free, else a free one.
    @Test func assignPagesKeepsAndSplits() {
        let a = UUID(), b = UUID()
        #expect(assignPages(visible: [(a, 0), (b, 0)], count: 2) == [a: 0, b: 1])
        #expect(assignPages(visible: [(a, 1), (b, nil)], count: 2) == [a: 1, b: 0])
        #expect(assignPages(visible: [(a, nil)], count: 2) == [a: 0])
        #expect(assignPages(visible: [(a, 1), (b, 1)], count: 2) == [a: 1, b: 0])
        // Over the cap (a model can't hold more): the rest keep what they have.
        let c = UUID()
        #expect(assignPages(visible: [(a, 0), (b, 1), (c, 0)], count: 2) == [a: 0, b: 1])
    }

    /// Every open makes or focuses the file's own tab; a one-click open (Files) previews in one reused tab, and an
    /// edit pins it. An existing tab's page is told to move the cursor (a new tab loads from the model).
    @Test func openInEditorOpensFileTabs() {
        var ids = (t: UUID(), claude: UUID())
        let (app, dir) = makeApp { s in
            let p = s.addProject(name: "app", path: "/r/app")
            ids.t = s.addTask(projectId: p, name: "a")
            ids.claude = s.addTab(taskId: ids.t, kind: .claude)
            s.select(taskId: ids.t)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        var pages: [String] = []
        app.onOpenInEditor = { _, path, _, _ in pages.append(path) }
        app.openInEditor(path: "/r/app/a.ts", line: 4)
        var task = app.state.tasks[0]
        #expect(task.tabs.count == 2 && task.activeTabId == task.tabs[1].id)
        #expect(task.tabs[1].root.leaves[0].editorFiles == [EditorFile(path: "/r/app/a.ts", line: 4, column: 1)])

        app.activate(tabId: ids.claude)
        app.openInEditor(path: "/r/app/b.ts", line: nil, preview: true)
        app.openInEditor(path: "/r/app/c.ts", line: nil, preview: true)
        task = app.state.tasks[0]
        #expect(task.tabs.map { $0.root.leaves[0].openFile } == [nil, "/r/app/c.ts", "/r/app/a.ts"])
        #expect(task.tabs[1].preview)
        app.editorDirtyChanged(leafId: task.tabs[1].root.leaves[0].id, dirty: true)
        #expect(app.state.tasks[0].tabs[1].preview == false)
        #expect(app.editorDirty.contains(task.tabs[1].root.leaves[0].id))

        app.openInEditor(path: "/r/app/a.ts", line: 9, column: 2)
        task = app.state.tasks[0]
        #expect(task.activeTabId == task.tabs[2].id)
        #expect(task.tabs[2].root.leaves[0].editorFiles == [EditorFile(path: "/r/app/a.ts", line: 9, column: 2)])
        #expect(pages == ["/r/app/a.ts", "/r/app/b.ts", "/r/app/c.ts", "/r/app/a.ts"])
    }

    @Test func openInEditorNeedsASelectedTask() {
        let (app, dir) = makeApp { s in
            let p = s.addProject(name: "app", path: "/r/app")
            _ = s.addTask(projectId: p, name: "a")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        app.openInEditor(path: "/r/app/a.ts", line: 1)
        #expect(app.state.tasks[0].tabs.isEmpty)
    }

    /// A launch that met a missing folder is retried by ↩ (and by opening a file) once the folder is back,
    /// with the context it had. No Ghostty in tests: a launch only builds its spec.
    @Test func missingFolderLeafRelaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-missing-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let previous = LaunchMode(restoring: false, initialPrompt: nil)
        for first in [LaunchContext.restored, .relaunch(previous: previous, exitCode: 1)] {
            var contexts: [LaunchContext] = []
            var keeps: [Bool] = []
            let view = LeafView(leafId: UUID())
            view.onRelaunch = { keeps.append($0) }
            view.start(first) { ctx in
                contexts.append(ctx)
                guard FileManager.default.fileExists(atPath: dir) else { throw LaunchError.missingCwd(dir) }
                return (LaunchSpec(command: "true", cwd: dir, env: [:]), previous)
            }
            #expect(view.needsRelaunch)
            #expect(view.controlState == .failed)
            view.relaunch(focus: false)  // still missing: tried again, still waiting for ↩
            #expect(contexts == [first, first])
            #expect(view.needsRelaunch)
            #expect(keeps.isEmpty)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            view.relaunch(focus: false)
            #expect(contexts == [first, first, first])
            // A relaunch after an exit resets the status like any ↩; a launch that never ran keeps it.
            if case .relaunch = first { #expect(keeps == [false]) } else { #expect(keeps == [true]) }
            try FileManager.default.removeItem(atPath: dir)
        }
    }
}
