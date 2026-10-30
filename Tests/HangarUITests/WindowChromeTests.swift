import AgentStatus
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Window titlebar «Проект · Сессия ⎇ ветка» and the window status bar (redesign v1 §1, §6, §7).
@MainActor @Suite struct WindowChromeTests {
    private func state() -> (WorkspaceState, project: UUID, task: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "acme-web", path: "/f")
        let t = s.addTask(projectId: p, name: "redesign-v1", mode: .worktree(path: "/f/.wt/r", branch: "feat/redesign-v1", base: "main"))
        s.selectedTaskId = t
        return (s, p, t)
    }

    // MARK: Title

    @Test func titleIsProjectSessionAndBranch() {
        let (s, _, _) = state()
        let title = windowTitle(s)
        #expect(title == WindowTitle(project: "acme-web", session: "redesign-v1", branch: "feat/redesign-v1"))
        #expect(title?.text == "acme-web · redesign-v1 ⎇ feat/redesign-v1")
    }

    @Test func mainFolderSessionHasNoBranchAndNoSelectionHasNoTitle() {
        var s = WorkspaceState()
        let p = s.addProject(name: "api", path: "/a")
        s.selectedTaskId = s.addTask(projectId: p, name: "fix")
        #expect(windowTitle(s)?.text == "api · fix")
        s.selectedTaskId = nil
        #expect(windowTitle(s) == nil)
    }

    @Test func hostTerminalTitleIsTheHost() {
        defer { L10n.language = .system }
        L10n.language = .en
        var s = WorkspaceState()
        s.selectedTaskId = s.openHostShell(host: "devbox").task
        #expect(windowTitle(s)?.text == "devbox · terminal")
    }

    // MARK: Status bar counts

    @Test func countsAgentsNotSubagents() {
        defer { L10n.language = .system }
        let c = StatusCounts([(.working, 2), (.working, 1), (.waiting, 0), (.waiting, 0), (.waiting, 0), (.failed, 0), (.done, 0), (.idle, 0)])
        #expect(c == StatusCounts(working: 2, waiting: 3, failed: 1, subagents: 3))
        // On the limit: its own count, neither working nor an error.
        #expect(StatusCounts([(.limit, 0), (.limit, 0), (.failed, 0)]) == StatusCounts(failed: 1, limited: 2))
        var line = StatusBarLine()
        line.counts = c
        L10n.language = .ru
        #expect(line.workingText == "2 работают")
        #expect(line.workingHelp == "Следующий работающий чат · 3 субагента")
        line.counts.subagents = 0
        #expect(line.workingHelp == "Следующий работающий чат")
        L10n.language = .en
        line.counts.subagents = 1
        #expect(line.workingHelp == "Next working chat · 1 subagent")
    }

    /// «ждёт внимания» counts the project's asking agents only: a failure is an error, not «ждёт» (the bell has both).
    @Test func waitingCounterLabel() {
        defer { L10n.language = .system }
        var line = StatusBarLine()
        #expect(line.waitingText == nil)
        line.counts = StatusCounts([(.waiting, 0), (.failed, 0)])
        L10n.language = .ru
        #expect(line.waitingText == "1 ждёт внимания")
        #expect(line.failedText == "1 ошибка")
        line.counts.waiting = 3
        #expect(line.waitingText == "3 ждут внимания")
        L10n.language = .en
        #expect(line.waitingText == "3 need attention")
    }

    @Test func localLineCountsTheSelectedProjectOnly() {
        defer { L10n.language = .system }
        var (s, p, t) = state()
        let tab = s.addTab(taskId: t, kind: .claude)
        let other = s.addTask(projectId: p, name: "fix-login")
        _ = s.addTab(taskId: other, kind: .claude)
        let elsewhere = s.addProject(name: "web", path: "/w")
        let far = s.addTask(projectId: elsewhere, name: "far")
        _ = s.addTab(taskId: far, kind: .claude)
        let leaf = s.tasks.first { $0.id == t }!.tabs.first { $0.id == tab }!.focusedLeafId
        let line = statusBarLine(s, summary: { $0.id == leaf ? (.working, 0) : (.idle, 0) }, language: { _ in nil })
        // «far» (another project) is not counted.
        #expect(line.counts == StatusCounts(working: 1, failed: 0))
        L10n.language = .ru
        // The project is in the title; one pane and its process are on the tab: none of them repeat here.
        #expect(line.left == ["Этот Mac"])
        #expect(line.workingText == "1 работает")
        #expect(line.failedText == nil)
        #expect(line.right == nil)
        L10n.language = .en
        #expect(line.left == ["This Mac"])
        #expect(line.workingText == "1 working")
    }

    @Test func remoteLineShowsTheHostAndSplitPanes() {
        defer { L10n.language = .system }
        var s = WorkspaceState()
        let p = s.addRemoteProject(name: "api", host: "devbox", path: "/srv/api")
        let t = s.addTask(projectId: p, name: "deploy")
        s.selectedTaskId = t
        let tab = s.addTab(taskId: t, kind: .shell)
        let task = s.tasks.first { $0.id == t }!
        let first = task.tabs[0].focusedLeafId
        let second = s.split(taskId: t, tabId: tab, leafId: first, axis: .horizontal, kind: .claude)
        let line = statusBarLine(s, summary: { $0.id == second ? (.working, 1) : (.failed, 0) }, language: { _ in nil })
        L10n.language = .ru
        #expect(line.remote)
        #expect(line.left == ["devbox"])
        #expect(line.workingText == "1 работает")
        #expect(line.counts.subagents == 1)
        #expect(line.failedText == nil)  // the shell's exit keeps just its dot
        #expect(line.right == "2 панели")
        L10n.language = .en
        #expect(line.right == "2 panes")
    }

    /// A shell's or host terminal's non-zero exit (ssh 255 on disconnect) is not an error here; an agent's failure is.
    @Test func onlyAgentFailuresAreErrors() {
        defer { L10n.language = .system }
        var s = WorkspaceState()
        s.selectedTaskId = s.openHostShell(host: "devbox").task
        #expect(statusBarLine(s, summary: { _ in (.failed, 0) }, language: { _ in nil }).counts.failed == 0)
        var (project, _, t) = state()
        _ = project.addTab(taskId: t, kind: .shell)
        let agent = project.addTab(taskId: t, kind: .claude)
        s = project
        let claude = s.tasks.first { $0.id == t }!.tabs.first { $0.id == agent }!.focusedLeafId
        let line = statusBarLine(s, summary: { _ in (.failed, 0) }, language: { _ in nil })
        #expect(line.counts.failed == 1 && line.failedLeaves == [claude])
        L10n.language = .ru
        #expect(line.failedText == "1 ошибка")
        L10n.language = .en
        #expect(line.failedText == "1 error")
    }

    @Test func noSessionLeavesOnlyThisMac() {
        defer { L10n.language = .system }
        L10n.language = .ru
        let line = statusBarLine(WorkspaceState(), summary: { _ in (.working, 0) }, language: { _ in "Swift" })
        #expect(line.left == ["Этот Mac"])
        #expect(line.counts == StatusCounts())
        #expect(line.workingText == nil && line.waitingText == nil)
        #expect(line.right == nil)
    }

    @Test func russianPlurals() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect([1, 2, 5, 21].map(L10n.workingCount) == ["1 работает", "2 работают", "5 работают", "21 работает"])
        #expect([1, 3, 5, 11].map(L10n.inboxCount) == ["1 ждёт внимания", "3 ждут внимания", "5 ждут внимания", "11 ждут внимания"])
        #expect([1, 2, 5].map(L10n.failedCount) == ["1 ошибка", "2 ошибки", "5 ошибок"])
        #expect([1, 2, 5].map(L10n.limitedCount) == ["1 на лимите", "2 на лимите", "5 на лимите"])
        L10n.language = .en
        #expect([1, 2].map(L10n.limitedCount) == ["1 at limit", "2 at limit"])
        L10n.language = .ru
        #expect([1, 2, 5].map(L10n.paneCount) == ["1 панель", "2 панели", "5 панелей"])
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

    /// The status bar's right label for an editor: the active file's language, else nothing (the tab says «Редактор»).
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
