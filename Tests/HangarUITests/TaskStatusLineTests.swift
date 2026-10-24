import AgentStatus
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct TaskStatusLineTests {
    private func file(_ path: String, _ added: Int?, _ deleted: Int?) -> ChangedFile {
        ChangedFile(path: path, change: .modified, added: added, deleted: deleted)
    }

    @Test func fullLineInRussianAndEnglish() {
        defer { L10n.language = .system }
        let files = [file("a", 30, 10), file("b", 8, 2)]
        L10n.language = .ru
        let ru = TaskStatusLine(branch: "refactor-db", files: files, host: nil, offline: false, agent: (.codex, .working))
        #expect(ru.branch == "⎇ refactor-db")
        #expect(ru.changes == "+38 −12 · 2 файла")
        #expect(ru.host == nil)
        #expect(ru.agent == "codex · работает")
        L10n.language = .en
        let en = TaskStatusLine(branch: "fix-auth", files: files, host: nil, offline: false, agent: (.claude, .waiting))
        #expect(en.changes == "+38 −12 · 2 files")
        #expect(en.agent == "claude · waiting for you")
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

    @Test func binaryAndUntrackedCountAsZeroLines() {
        defer { L10n.language = .system }
        L10n.language = .en
        let line = TaskStatusLine(branch: nil, files: [file("img.png", nil, nil), file("x", 3, nil)], host: nil, offline: false, agent: nil)
        #expect(line.changes == "+3 −0 · 2 files")
        #expect(line.branch == nil)
        #expect(line.agent == nil)
    }

    @Test func noChangesOrNotLoadedHidesTheCounts() {
        #expect(TaskStatusLine(branch: "b", files: [], host: nil, offline: false, agent: nil).changes == nil)
        #expect(TaskStatusLine(branch: "b", files: nil, host: nil, offline: false, agent: nil).changes == nil)
    }

    @Test func remoteHostShownAndOfflineDropsStaleCounts() {
        defer { L10n.language = .system }
        L10n.language = .en
        let files = [file("a", 1, 1)]
        let online = TaskStatusLine(branch: "b", files: files, host: "dev", offline: false, agent: nil)
        #expect(online.host == "dev")
        #expect(online.changes == "+1 −1 · 1 file")
        let offline = TaskStatusLine(branch: "b", files: files, host: "dev", offline: true, agent: (.claude, .working))
        #expect(offline.host == L10n.hostOffline("dev"))
        #expect(offline.changes == nil)
        #expect(offline.branch == "⎇ b")
        #expect(offline.agent == "claude · working")
    }

    @Test func agentPrefersTheActiveTabsFocusedAgent() {
        let claude = Leaf(kind: .claude, cwd: "/")
        let codex = Leaf(kind: .codex, cwd: "/")
        let shell = Leaf(kind: .shell, cwd: "/")
        let agentsTab = Tab(title: "a", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(claude), second: .leaf(codex)),
                            focusedLeafId: codex.id)
        let shellTab = Tab(title: "s", root: .leaf(shell), focusedLeafId: shell.id)
        var task = HangarTask(projectId: UUID(), name: "t", order: 0, tabs: [shellTab, agentsTab], activeTabId: agentsTab.id)
        #expect(statusAgentLeaf(of: task)?.id == codex.id)
        task.tabs[1].focusedLeafId = claude.id
        #expect(statusAgentLeaf(of: task)?.id == claude.id)
        // A shell has focus: no agent part (not some other tab's «claude · idle»).
        task.activeTabId = shellTab.id
        #expect(statusAgentLeaf(of: task) == nil)
        task.tabs = [shellTab]
        #expect(statusAgentLeaf(of: task) == nil)
    }

    @Test func shellPaneNextToAnAgentHidesTheAgent() {
        let claude = Leaf(kind: .claude, cwd: "/")
        let shell = Leaf(kind: .shell, cwd: "/")
        let tab = Tab(title: "a", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(claude), second: .leaf(shell)),
                      focusedLeafId: shell.id)
        var task = HangarTask(projectId: UUID(), name: "t", order: 0, tabs: [tab], activeTabId: tab.id)
        #expect(statusAgentLeaf(of: task) == nil)
        task.tabs[0].focusedLeafId = claude.id
        #expect(statusAgentLeaf(of: task)?.id == claude.id)
        task.activeTabId = nil
        #expect(statusAgentLeaf(of: task) == nil)
    }
}
