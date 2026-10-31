import Foundation
import Testing
@testable import Workspace

/// Chats without a project: one task per `FreeChat`, in the shared `chatsFolder`, outside `projects`.
@Suite struct FreeChatTests {
    private func state() -> WorkspaceState {
        var s = WorkspaceState()
        s.chatsFolder = "/state/Chats"
        return s
    }

    @Test func addCreatesSelectedTaskInChatsFolder() throws {
        var s = state()
        let c = s.addFreeChat(name: "Чат 1", kind: .claude, autoNamed: true, at: Date(timeIntervalSince1970: 10))
        let task = try #require(s.tasks.first { $0.id == c.task })
        #expect(s.projects.isEmpty)
        #expect(s.freeChats.map(\.id) == [task.projectId])
        #expect(s.selectedTaskId == c.task && task.activeTabId == c.tab)
        #expect(task.autoNamed)
        let leaf = try #require(task.tabs.first?.root.leaves.first)
        #expect(leaf.kind == .claude && leaf.cwd == "/state/Chats")
        #expect(s.isFreeChatTask(task) && s.freeChat(ofTask: c.task)?.lastUsedAt == Date(timeIntervalSince1970: 10))
        #expect(s.tasks(in: task.projectId).count == 1)
        // A shell tab added later runs there too.
        let shell = s.addTab(taskId: c.task, kind: .shell)
        #expect(s.tasks.first { $0.id == c.task }?.tabs.first { $0.id == shell }?.root.leaves.first?.cwd == "/state/Chats")
    }

    @Test func orderIsPinnedThenLastUsed() {
        var s = state()
        let a = s.addFreeChat(name: "a", kind: .claude, autoNamed: false, at: Date(timeIntervalSince1970: 1))
        let b = s.addFreeChat(name: "b", kind: .claude, autoNamed: false, at: Date(timeIntervalSince1970: 2))
        let c = s.addFreeChat(name: "c", kind: .codex, autoNamed: false, at: Date(timeIntervalSince1970: 3))
        #expect(s.freeChatTasks.map(\.name) == ["c", "b", "a"])
        s.touchFreeChat(taskId: a.task, at: Date(timeIntervalSince1970: 4))
        #expect(s.freeChatTasks.map(\.name) == ["a", "c", "b"])
        s.setPinned(taskId: b.task, true)
        #expect(s.freeChatTasks.map(\.name) == ["b", "a", "c"])
        _ = c
    }

    @Test func sleepKeepsTabsAndConversationAndWakeReopens() throws {
        var s = state()
        let c = s.addFreeChat(name: "x", kind: .claude, autoNamed: false)
        let leaf = try #require(s.tasks.first?.tabs.first?.root.leaves.first)
        s.setAgentSessionId(leafId: leaf.id, "11111111-2222-3333-4444-555555555555")
        s.sleepFreeChat(taskId: c.task, at: Date(timeIntervalSince1970: 5))
        var task = try #require(s.tasks.first { $0.id == c.task })
        #expect(task.archived && task.archivedAt == Date(timeIntervalSince1970: 5))
        #expect(task.tabs.first?.root.leaves.first?.agentSessionId == "11111111-2222-3333-4444-555555555555")
        #expect(s.selectedTaskId == nil)
        s.wakeFreeChat(taskId: c.task)
        task = try #require(s.tasks.first { $0.id == c.task })
        #expect(!task.archived && task.archivedAt == nil && task.tabs.count == 1)
    }

    @Test func closingLastTabSleepsOtherTabsClose() throws {
        var s = state()
        let c = s.addFreeChat(name: "x", kind: .claude, autoNamed: false)
        let shell = s.addTab(taskId: c.task, kind: .shell)
        s.closeTab(taskId: c.task, tabId: shell)
        #expect(s.tasks.first { $0.id == c.task }?.tabs.count == 1)
        #expect(s.tasks.first { $0.id == c.task }?.archived == false)
        let leaf = try #require(s.tasks.first?.tabs.first?.root.leaves.first)
        s.closeLeaf(taskId: c.task, tabId: c.tab, leafId: leaf.id)
        let task = try #require(s.tasks.first { $0.id == c.task })
        #expect(task.archived && task.tabs.count == 1)
    }

    @Test func projectTasksCloseTabsAsBefore() {
        var s = state()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        s.closeTab(taskId: t, tabId: tab)
        #expect(s.tasks.first?.tabs.isEmpty == true && s.tasks.first?.archived == false)
        #expect(s.cwd(for: s.tasks[0]) == "/repo")
    }

    @Test func removeDropsChatAndTaskOnly() {
        var s = state()
        let a = s.addFreeChat(name: "a", kind: .claude, autoNamed: false)
        let b = s.addFreeChat(name: "b", kind: .claude, autoNamed: false)
        s.removeFreeChat(taskId: b.task)
        #expect(s.freeChats.count == 1 && s.tasks.map(\.id) == [a.task])
        #expect(s.selectedTaskId == nil)
    }

    @Test func roundTripKeepsChatsNotFolder() throws {
        var s = state()
        s.addFreeChat(name: "a", kind: .claude, autoNamed: true, at: Date(timeIntervalSince1970: 7))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(back.freeChats == s.freeChats)
        #expect(back.chatsFolder == "")
        #expect(!String(decoding: data, as: UTF8.self).contains("chatsFolder"))
        // Older files have no key.
        let old = #"{"projects":[],"tasks":[],"inspectorVisible":false}"#
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: Data(old.utf8)).freeChats.isEmpty)
    }

    /// An older build saves without `freeChats`; the next load makes those tasks chats without a project again.
    @Test func downgradeRoundTripReadoptsOrphans() throws {
        var s = state()
        let open = s.addFreeChat(name: "open", kind: .claude, autoNamed: false).task
        let asleep = s.addFreeChat(name: "asleep", kind: .codex, autoNamed: false).task
        s.sleepFreeChat(taskId: asleep)
        // Another orphan (not in the chats folder) stays as it is.
        let ghost = UUID()
        let leaf = Leaf(kind: .shell, cwd: "/elsewhere")
        var other = HangarTask(projectId: ghost, name: "other", order: 99)
        other.tabs = [Tab(title: "zsh", root: .leaf(leaf), focusedLeafId: leaf.id)]
        s.tasks.append(other)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json.removeValue(forKey: "freeChats")
        var back = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.freeChats.isEmpty)
        back.chatsFolder = "/state/Chats/"  // a trailing slash still matches
        back.adoptOrphanFreeChats()
        #expect(Set(back.freeChatTasks.map(\.id)) == [open, asleep])
        #expect(back.tasks.first { $0.id == open }?.archived == false && back.tasks.first { $0.id == asleep }?.archived == true)
        #expect(!back.freeChats.contains { $0.id == ghost })
        back.adoptOrphanFreeChats()  // idempotent
        #expect(back.freeChats.count == 2)
    }
}
