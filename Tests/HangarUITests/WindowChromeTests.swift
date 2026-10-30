import AgentStatus
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// The window toolbar (design system §3.1): the chat's title over its project, where its parts go; the editor header's language.
@MainActor @Suite struct WindowChromeTests {
    private func state() -> (WorkspaceState, project: UUID, task: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "acme-web", path: "/f")
        let t = s.addTask(projectId: p, name: "redesign-v1", mode: .worktree(path: "/f/.wt/r", branch: "feat/redesign-v1", base: "main"))
        s.selectedTaskId = t
        return (s, p, t)
    }

    // MARK: Title

    @Test func titleIsTheChatOverItsProject() {
        let (s, _, _) = state()
        #expect(windowTitle(s) == WindowTitle(title: "redesign-v1", subtitle: "acme-web"))
    }

    @Test func noSelectionHasNoTitle() {
        var (s, _, _) = state()
        s.selectedTaskId = nil
        #expect(windowTitle(s) == nil)
    }

    /// A remote chat's project is «devbox · api» (what the status bar's machine said).
    @Test func remoteChatSubtitleHasTheServer() {
        var s = WorkspaceState()
        let p = s.addRemoteProject(name: "api", host: "devbox", path: "/srv/api")
        s.selectedTaskId = s.addTask(projectId: p, name: "deploy")
        #expect(windowTitle(s) == WindowTitle(title: "deploy", subtitle: "devbox · api"))
    }

    @Test func hostTerminalTitleIsTheHost() {
        defer { L10n.language = .system }
        L10n.language = .en
        var s = WorkspaceState()
        s.selectedTaskId = s.openHostShell(host: "devbox").task
        #expect(windowTitle(s) == WindowTitle(title: "devbox · terminal"))
    }

    // MARK: Layout

    /// Expanded: the toggle 16 inside the sidebar's edge, the title 16 after the column's; collapsed to the rail,
    /// both move clear of the traffic lights; full screen (no lights): the toggle stays in the rail.
    @Test func toolbarPartsClearTheSidebarAndTheLights() {
        #expect(toolbarLayout(contentX: 257, lightsMaxX: 79) == (toggleX: 213, titleX: 273))
        #expect(toolbarLayout(contentX: 45, lightsMaxX: 79) == (toggleX: 91, titleX: 135))
        #expect(toolbarLayout(contentX: 45, lightsMaxX: nil) == (toggleX: 8, titleX: 61))
    }

    @Test func fileCountPlurals() {
        defer { L10n.language = .system }
        L10n.language = .ru
        let ru = [1: "1 файл", 2: "2 файла", 4: "4 файла", 5: "5 файлов", 11: "11 файлов", 12: "12 файлов",
                  21: "21 файл", 22: "22 файла", 111: "111 файлов"]
        for (n, text) in ru { #expect(L10n.fileCount(n) == text) }
        L10n.language = .en
        #expect(L10n.fileCount(1) == "1 file")
        #expect(L10n.fileCount(3) == "3 files")
    }

    @Test func nextWorkingWrapsAfterTheCurrent() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(nextWorking([a, b, c], working: [a, c], after: a) == c)
        #expect(nextWorking([a, b, c], working: [a, c], after: c) == a)
        #expect(nextWorking([a, b, c], working: [b], after: nil) == b)
        #expect(nextWorking([a, b, c], working: [], after: a) == nil)
    }

    /// The editor header's language when no language server reports: TS/JS and the LSP languages, else nothing.
    @Test func editorProcessLabel() {
        defer { L10n.language = .system }
        L10n.language = .ru
        func leaf(_ file: String?) -> Leaf { Leaf(kind: .editor, cwd: "/w", openFile: file) }
        #expect(editorStatusLabel(leaf("/w/src/a.ts")) == "TypeScript")
        #expect(editorStatusLabel(leaf("/w/src/App.tsx")) == "TypeScript")
        #expect(editorStatusLabel(leaf("/w/src/a.mjs")) == "JavaScript")
        #expect(editorStatusLabel(leaf("/w/README.md")) == nil)
        #expect(editorStatusLabel(leaf(nil)) == nil)
    }
}
