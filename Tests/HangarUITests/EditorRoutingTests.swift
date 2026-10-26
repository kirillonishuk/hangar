@testable import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Every «open file» (Files, Changes, diff ↩, palette, links, Go to Definition) lands in the task's Monaco editor tab.
@MainActor @Suite struct EditorRoutingTests {
    private func makeApp(_ build: (inout WorkspaceState) -> Void) -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-editor-route-\(UUID().uuidString)")
        var s = WorkspaceState()
        build(&s)
        return (AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml")), dir)
    }

    /// The Hangar tab of an editor reads «Editor» (the file tabs live inside it); its tooltip holds the active file's
    /// path from the session folder. A terminal title never renames it.
    @Test func editorTabTitledEditor() {
        var ids = (t: UUID(), tab: UUID(), plain: UUID())
        let (app, dir) = makeApp { s in
            let p = s.addProject(name: "app", path: "/r/app")
            ids.t = s.addTask(projectId: p, name: "a")
            ids.tab = s.addTab(taskId: ids.t, kind: .editor, openFile: "/r/app/Sources/Model.swift", openLine: 3)
            ids.plain = s.addTab(taskId: ids.t, kind: .editor)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = { (id: UUID) in app.state.tasks[0].tabs.first { $0.id == id }! }
        #expect(app.tabLabel(tab(ids.tab)) == L10n.editor)
        #expect(app.tabHelpTitle(tab(ids.tab), taskId: ids.t) == "Sources/Model.swift")
        app.leafTitles[tab(ids.tab).focusedLeafId] = "zsh"
        #expect(app.tabLabel(tab(ids.tab)) == L10n.editor)
        let leafId = tab(ids.tab).focusedLeafId
        app.perform { $0.openEditorFile(leafId: leafId, path: "/r/app/README.md", line: nil, column: nil) }
        #expect(app.tabHelpTitle(tab(ids.tab), taskId: ids.t) == "README.md")
        #expect(app.tabLabel(tab(ids.plain)) == L10n.editor)
        #expect(app.tabHelpTitle(tab(ids.plain), taskId: ids.t) == L10n.editor)
    }

    /// No editor tab yet: a new one on the file and line, shown. Then every open goes to that tab (also from another
    /// active tab), adds the file once and moves its cursor.
    @Test func openInEditorRoutesToTheEditorTab() {
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
        #expect(task.tabs.count == 2)
        let editorTab = task.tabs[1]
        let leaf = editorTab.root.leaves[0]
        #expect(leaf.kind == .editor && task.activeTabId == editorTab.id)
        #expect(leaf.editorFiles == [EditorFile(path: "/r/app/a.ts", line: 4, column: 1)])

        app.activate(tabId: ids.claude)
        app.openInEditor(path: "/r/app/b.ts", line: nil)
        app.openInEditor(path: "/r/app/a.ts", line: 9, column: 2)
        task = app.state.tasks[0]
        #expect(task.tabs.count == 2 && task.activeTabId == editorTab.id)
        let files = task.tabs[1].root.leaves[0]
        #expect(files.editorFiles == [EditorFile(path: "/r/app/a.ts", line: 9, column: 2), EditorFile(path: "/r/app/b.ts", line: 1, column: 1)])
        #expect(files.openFile == "/r/app/a.ts")
        // The page of an existing tab is told too (a new tab loads its files from the model).
        #expect(pages == ["/r/app/b.ts", "/r/app/a.ts"])
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

    private func leaf(_ kind: LeafKind) -> Leaf { Leaf(kind: kind, cwd: "/r") }

    private func task(_ tabs: [Tab], active: Int?) -> HangarTask {
        HangarTask(projectId: UUID(), name: "t", order: 0, tabs: tabs, activeTabId: active.map { tabs[$0].id })
    }

    private func split(_ a: Leaf, _ b: Leaf, focus: Leaf) -> Tab {
        Tab(title: "s", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)), focusedLeafId: focus.id)
    }

    private func single(_ l: Leaf) -> Tab { Tab(title: l.kind.rawValue, root: .leaf(l), focusedLeafId: l.id) }

    private func target(_ t: HangarTask) -> [UUID]? { editorTarget(task: t).map { [$0.tab, $0.leaf] } }

    @Test func targetPrefersFocusedEditor() {
        let shell = leaf(.shell), ed = leaf(.editor), other = leaf(.editor), ed2 = leaf(.editor)
        // [shell │ editor] focused on the editor + a separate editor tab.
        let focused = split(shell, ed, focus: ed), separate = single(other)
        #expect(target(task([separate, focused], active: 1)) == [focused.id, ed.id])
        // Focus on the shell: the first editor leaf of the active tab.
        let two = Tab(title: "s", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(shell),
                                               second: .split(axis: .vertical, ratio: 0.5, first: .leaf(ed), second: .leaf(ed2))),
                      focusedLeafId: shell.id)
        #expect(target(task([separate, two], active: 1)) == [two.id, ed.id])
        var twoFocused = two; twoFocused.focusedLeafId = ed2.id
        #expect(target(task([separate, twoFocused], active: 1)) == [two.id, ed2.id])
        // The active tab has no editor: the first editor leaf in tab order; also with no active tab.
        let claudeTab = single(leaf(.claude))
        #expect(target(task([claudeTab, separate, focused], active: 0)) == [separate.id, other.id])
        #expect(target(task([claudeTab, separate], active: nil)) == [separate.id, other.id])
        #expect(target(task([claudeTab], active: 0)) == nil)
        #expect(target(task([], active: nil)) == nil)
    }

    /// A launch that met a missing folder is retried by ↩ (and by opening a file) once the folder is back,
    /// with the context it had. No Ghostty in tests: a launch only builds its spec.
    @Test func missingFolderLeafRelaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-missing-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let previous = LaunchMode(restoring: false, initialPrompt: nil)
        for first in [LaunchContext.restored(inResumeSet: true), .relaunch(previous: previous, exitCode: 1)] {
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
