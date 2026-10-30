import Foundation
import Testing
@testable import Workspace

@Suite struct ModelTests {
    private func makeState() -> (WorkspaceState, UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        return (s, p)
    }

    @Test func addTaskAppendsInOrder() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        #expect(s.tasks.map(\.order) == [0, 1])
        #expect(s.tasks(in: p).map(\.id) == [a, b])
    }

    @Test func taskNamesAreNotIdentifiers() {
        var (s, p) = makeState()
        let ids = ["fix auth", "исправить/логин", "fix auth"].map { s.addTask(projectId: p, name: $0) }
        #expect(Set(ids).count == 3)
        #expect(s.tasks.count == 3)
    }

    @Test func newTaskCwdIsProjectPath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .claude)
        guard case .leaf(let leaf) = s.tasks[0].tabs[0].root else { Issue.record("not a leaf"); return }
        #expect(leaf.cwd == "/repo/app")
        #expect(leaf.kind == .claude)
        #expect(s.tasks[0].tabs[0].title == "claude")
        #expect(s.tasks[0].activeTabId == s.tasks[0].tabs[0].id)
    }

    @Test func worktreeCwdIsWorktreePath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.tasks[0].mode = .worktree(path: "/wt/t", branch: "t", base: "main")
        s.addTab(taskId: t, kind: .shell)
        #expect(s.tasks[0].tabs[0].root.leaves[0].cwd == "/wt/t")
    }

    /// Restore without the removed worktree: main-folder task, leaves (drawer too) move from the worktree to the project.
    @Test func detachWorktreeMovesLeaves() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t", mode: .worktree(path: "/wt/t", branch: "t", base: "main"))
        s.addTab(taskId: t, kind: .shell)
        s.toggleDrawer(taskId: t)
        s.tasks[0].tabs[0].root = .leaf(Leaf(kind: .shell, cwd: "/wt/t/sub"))
        s.detachWorktree(taskId: t)
        #expect(s.tasks[0].mode == .mainFolder)
        #expect(s.tasks[0].tabs[0].root.leaves[0].cwd == "/repo/app/sub")
        #expect(s.tasks[0].drawer.leaf?.cwd == "/repo/app")
    }

    @Test func closeLastLeafClosesTab() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        let first = s.tasks[0].tabs[0].root.leaves[0].id
        let second = s.split(taskId: t, tabId: tab, leafId: first, axis: .horizontal, kind: .shell)
        #expect(s.tasks[0].tabs[0].root.leaves.count == 2)
        #expect(s.tasks[0].tabs[0].focusedLeafId == second)
        guard case .split(.horizontal, 0.5, _, _) = s.tasks[0].tabs[0].root else { Issue.record("not a split"); return }

        s.closeLeaf(taskId: t, tabId: tab, leafId: second)
        guard case .leaf(let rest) = s.tasks[0].tabs[0].root else { Issue.record("not a leaf"); return }
        #expect(rest.id == first)
        #expect(s.tasks[0].tabs[0].focusedLeafId == first)

        s.closeLeaf(taskId: t, tabId: tab, leafId: first)
        #expect(s.tasks[0].tabs.isEmpty)
        #expect(s.tasks[0].activeTabId == nil)
    }

    @Test func closeLastLeafActivatesNeighborTab() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .shell)
        let leaf = s.tasks[0].tabs[1].root.leaves[0].id
        s.closeLeaf(taskId: t, tabId: b, leafId: leaf)
        #expect(s.tasks[0].activeTabId == a)
    }

    @Test func closeActiveTabSelectsNeighbor() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .codex)
        let c = s.addTab(taskId: t, kind: .shell)
        s.tasks[0].activeTabId = b
        s.closeTab(taskId: t, tabId: b)
        #expect(s.tasks[0].activeTabId == c)
        s.closeTab(taskId: t, tabId: c)
        #expect(s.tasks[0].activeTabId == a)
    }

    @Test func closeInactiveTabKeepsActive() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .codex)
        s.closeTab(taskId: t, tabId: a)
        #expect(s.tasks[0].activeTabId == b)
    }

    @Test func moveTaskRenumbers() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        let c = s.addTask(projectId: p, name: "c")
        s.moveTask(id: c, to: 0)
        #expect(s.tasks(in: p).map(\.id) == [c, a, b])
        #expect(s.tasks(in: p).map(\.order) == [0, 1, 2])
    }

    @Test func moveTaskIgnoresArchivedSiblings() {
        var (s, p) = makeState()
        let x = s.addTask(projectId: p, name: "X")
        s.addTask(projectId: p, name: "A")
        s.addTask(projectId: p, name: "B")
        s.addTask(projectId: p, name: "C")
        s.archiveTask(id: x)
        let a = s.tasks(in: p)[0].id
        s.moveTask(id: a, to: 1)
        #expect(s.tasks(in: p).map(\.name) == ["B", "A", "C"])
        #expect(s.tasks.first { $0.id == x }?.order == 0)
        #expect(s.tasks.map(\.order).sorted() == [0, 1, 2, 3])
    }

    @Test func moveTaskToEnd() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "A")
        s.addTask(projectId: p, name: "B")
        s.addTask(projectId: p, name: "C")
        s.moveTask(id: a, to: 2)
        #expect(s.tasks(in: p).map(\.name) == ["B", "C", "A"])
        s.moveTask(id: a, to: 0)
        s.moveTask(id: a, to: 99)
        #expect(s.tasks(in: p).map(\.name) == ["B", "C", "A"])
    }

    @Test func archivedTasksHidden() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        s.select(taskId: a)
        s.archiveTask(id: a)
        #expect(s.tasks(in: p).map(\.id) == [b])
        #expect(s.selectedTaskId == nil)
        #expect(s.tasks.count == 2)
    }

    @Test func roundTripCodable() throws {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        let l1 = s.tasks[0].tabs[0].root.leaves[0].id
        let l2 = s.split(taskId: t, tabId: tab, leafId: l1, axis: .horizontal, kind: .codex)
        let l3 = s.split(taskId: t, tabId: tab, leafId: l2, axis: .vertical, kind: .editor)
        s.split(taskId: t, tabId: tab, leafId: l3, axis: .vertical, kind: .shell)
        s.tasks[0].mode = .worktree(path: "/wt", branch: "b", base: "main")
        s.projects[0].lastBaseBranch = "main"
        s.select(taskId: t)
        s.inspectorVisible = true
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == s)
        #expect(Set(s.tasks[0].tabs[0].root.leaves.map(\.kind)) == [.claude, .codex, .editor, .shell])
    }

    @Test func oldStateWithoutSidebarFieldsDecodes() throws {
        let json = #"{"projects":[],"tasks":[],"inspectorVisible":true}"#
        let s = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(s.sidebarWidth == 256)
        #expect(s.sidebarCollapsed == false)
        #expect(s.inspectorVisible == true)
        var changed = s
        changed.sidebarWidth = 260
        changed.sidebarCollapsed = true
        let data = try JSONEncoder().encode(changed)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == changed)
    }

    @Test func attentionFilterPersists() throws {
        let json = #"{"projects":[],"tasks":[],"inspectorVisible":false}"#
        var s = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(s.attentionOnly == false)
        s.attentionOnly = true
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s)).attentionOnly == true)
    }

    @Test func oldStateWithoutInspectorWidthLoads() throws {
        let json = #"{"projects":[],"tasks":[],"inspectorVisible":true}"#
        var s = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(s.inspectorWidth == 320)
        s.inspectorWidth = 380
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s)).inspectorWidth == 380)
    }

    @Test func remoteLocationRoundTrip() throws {
        let p = Project(name: "app", location: .ssh(host: "dev", path: "/srv/app"))
        let data = try JSONEncoder().encode(p)
        #expect(String(decoding: data, as: UTF8.self).contains(#""ssh":{"#))
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back == p)
        #expect(back.host == "dev")
        #expect(back.path == "/srv/app")
    }

    @Test func oldLocalStillDecodes() throws {
        let id = UUID().uuidString
        let json = #"{"projects":[{"id":"\#(id)","name":"a","location":{"local":{"path":"/a"}}}],"tasks":[],"inspectorVisible":true}"#
        let s = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(s.projects.first?.location == .local(path: "/a"))
        #expect(s.projects.first?.host == nil)
        #expect(s.projects.first?.path == "/a")
    }

    @Test func addRemoteProjectDedupes() {
        var s = WorkspaceState()
        let a = s.addRemoteProject(name: "app", host: "dev", path: "/srv/app")
        let b = s.addRemoteProject(name: "app2", host: "dev", path: "/srv/app")
        let c = s.addRemoteProject(name: "app", host: "prod", path: "/srv/app")
        #expect(a == b)
        #expect(a != c)
        #expect(s.projects.count == 2)
        #expect(s.projects.first { $0.id == c }?.location == .ssh(host: "prod", path: "/srv/app"))
    }

    @Test func setPathKeepsHost() {
        var s = WorkspaceState()
        let p = s.addRemoteProject(name: "app", host: "dev", path: "/srv/app")
        s.updateProject(id: p, name: "app", path: "/srv/new", baseBranch: nil, worktreeRoot: nil)
        #expect(s.projects.first?.location == .ssh(host: "dev", path: "/srv/new"))
    }

    @Test func addEditorTabWithFile() throws {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .editor, openFile: "/r/a b.txt", openLine: 7)
        #expect(s.tasks[0].activeTabId == tab)
        let first = s.tasks[0].tabs[0].root.leaves[0]
        #expect(first.openFile == "/r/a b.txt" && first.editorFiles == [EditorFile(path: "/r/a b.txt", line: 7, column: 1)])
        #expect(try JSONDecoder().decode(Leaf.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test func setRatioAddressesSplitByPath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        let l1 = s.tasks[0].tabs[0].root.leaves[0].id
        let l2 = s.split(taskId: t, tabId: tab, leafId: l1, axis: .horizontal, kind: .shell)
        s.split(taskId: t, tabId: tab, leafId: l2, axis: .vertical, kind: .shell)
        s.setRatio(taskId: t, tabId: tab, path: [1], ratio: 0.3)
        s.setRatio(taskId: t, tabId: tab, path: [], ratio: 0.7)
        guard case .split(_, let outer, _, let second) = s.tasks[0].tabs[0].root,
              case .split(let axis, let inner, _, _) = second else { Issue.record("shape"); return }
        #expect(outer == 0.7)
        #expect(inner == 0.3)
        #expect(axis == .vertical)
        // Paths into a leaf are ignored and ratios are clamped.
        s.setRatio(taskId: t, tabId: tab, path: [0, 1], ratio: 0.9)
        s.setRatio(taskId: t, tabId: tab, path: [], ratio: 5)
        guard case .split(_, let clamped, _, _) = s.tasks[0].tabs[0].root else { return }
        #expect(clamped == 0.95)
        #expect(s.tasks[0].tabs[0].root.leaves.count == 3)
    }

    @Test func oldTasksAndProjectsDecodeWithDefaults() throws {
        let p = UUID(), t = UUID()
        let json = """
        {"projects":[{"id":"\(p)","name":"app","location":{"local":{"path":"/repo"}}}],
         "tasks":[{"id":"\(t)","projectId":"\(p)","name":"t","mode":{"mainFolder":{}},"order":0,"archived":false,"tabs":[]}],
         "inspectorVisible":false}
        """
        let s = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(s.projects[0].collapsed == false)
        #expect(s.tasks[0].pinned == false)
        var changed = s
        changed.setPinned(taskId: t, true)
        changed.setProjectCollapsed(id: p, true)
        let data = try JSONEncoder().encode(changed)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == changed)
    }

    @Test func pinCollapseRenameRestore() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.setPinned(taskId: t, true)
        #expect(s.tasks[0].pinned)
        s.setPinned(taskId: t, false)
        #expect(!s.tasks[0].pinned)
        s.setProjectCollapsed(id: p, true)
        #expect(s.projects[0].collapsed)
        s.renameTask(id: t, name: "  fix auth ")
        #expect(s.tasks[0].name == "fix auth")
        s.renameTask(id: t, name: "   ")
        #expect(s.tasks[0].name == "fix auth")
        s.renameProject(id: p, name: "shop")
        #expect(s.projects[0].name == "shop")
        s.renameProject(id: p, name: "")
        #expect(s.projects[0].name == "shop")
        s.archiveTask(id: t)
        #expect(s.tasks(in: p).isEmpty)
        s.restoreTask(id: t)
        #expect(s.tasks(in: p).map(\.id) == [t])
    }

    // MARK: Task 6b

    @Test func renameRejectsBlank() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .shell)
        s.renameTask(id: t, name: "  ")
        s.renameProject(id: p, name: "\n ")
        s.renameTab(taskId: t, tabId: tab, title: " \t")
        #expect(s.tasks[0].name == "t")
        #expect(s.projects[0].name == "app")
        #expect(s.tasks[0].tabs[0].customTitle == nil)
        s.updateProject(id: p, name: "  ", path: "/repo/app", baseBranch: nil, worktreeRoot: nil)
        #expect(s.projects[0].name == "app")
    }

    @Test func renameTabSetsCustomTitle() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .shell)
        s.renameTab(taskId: t, tabId: tab, title: "  server ")
        #expect(s.tasks[0].tabs[0].customTitle == "server")
        #expect(s.tasks[0].tabs[0].label(auto: "zsh") == "server")
        s.tasks[0].tabs[0].customTitle = nil
        #expect(s.tasks[0].tabs[0].label(auto: "zsh") == "zsh")
    }

    @Test func deleteOnlyArchived() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        s.deleteTask(id: a)
        #expect(s.tasks.map(\.id) == [a, b])
        s.select(taskId: b)
        s.archiveTask(id: b)
        s.deleteTask(id: b)
        #expect(s.tasks.map(\.id) == [a])
    }

    @Test func removeProjectRemovesItsTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-rm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = WorkspaceState()
        let p1 = s.addProject(name: "one", path: dir.path)
        let p2 = s.addProject(name: "two", path: "/repo/two")
        let a = s.addTask(projectId: p1, name: "a")
        let b = s.addTask(projectId: p1, name: "b")
        s.archiveTask(id: b)
        let c = s.addTask(projectId: p2, name: "c")
        s.select(taskId: a)
        s.removeProject(id: p1)
        #expect(s.projects.map(\.id) == [p2])
        #expect(s.tasks.map(\.id) == [c])
        #expect(s.selectedTaskId == nil)
        // Never touches the disk.
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func moveProjectReorders() {
        var s = WorkspaceState()
        let a = s.addProject(name: "a", path: "/a")
        let b = s.addProject(name: "b", path: "/b")
        let c = s.addProject(name: "c", path: "/c")
        s.moveProject(id: a, to: 2)
        #expect(s.projects.map(\.id) == [b, c, a])
        s.moveProject(id: a, to: 0)
        #expect(s.projects.map(\.id) == [a, b, c])
        s.moveProject(id: c, to: 99)
        #expect(s.projects.map(\.id) == [a, b, c])
        s.moveProject(id: c, to: -5)
        #expect(s.projects.map(\.id) == [c, a, b])
    }

    @Test func updateProjectMovesMainFolderLeaves() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .shell)
        let w = s.addTask(projectId: p, name: "w")
        s.tasks[1].mode = .worktree(path: "/wt", branch: "b", base: "main")
        s.addTab(taskId: w, kind: .shell)
        s.updateProject(id: p, name: " shop ", path: "/repo/shop", baseBranch: nil, worktreeRoot: "/other")
        #expect(s.projects[0].worktreeRoot == "/other")
        #expect(s.tasks[1].mode == .worktree(path: "/wt", branch: "b", base: "main"))
        #expect(s.projects[0].name == "shop")
        #expect(s.projects[0].path == "/repo/shop")
        #expect(s.tasks[0].tabs[0].root.leaves[0].cwd == "/repo/shop")
        #expect(s.tasks[1].tabs[0].root.leaves[0].cwd == "/wt")
    }

    @Test func updateProjectMovesDrawerLeaf() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let w = s.addTask(projectId: p, name: "w")
        s.tasks[1].mode = .worktree(path: "/wt", branch: "b", base: "main")
        s.toggleDrawer(taskId: t)
        s.toggleDrawer(taskId: w)
        s.updateProject(id: p, name: "app", path: "/repo/shop", baseBranch: nil, worktreeRoot: nil)
        #expect(s.tasks[0].drawer.leaf?.cwd == "/repo/shop")
        #expect(s.tasks[1].drawer.leaf?.cwd == "/wt")
    }

    @Test func oldStateWithoutCustomTitleDecodes() throws {
        let leaf = UUID(), tab = UUID()
        let json = """
        {"id":"\(tab)","title":"shell","focusedLeafId":"\(leaf)",
         "root":{"leaf":{"_0":{"id":"\(leaf)","kind":"shell","cwd":"/repo"}}}}
        """
        let decoded = try JSONDecoder().decode(Tab.self, from: Data(json.utf8))
        #expect(decoded.customTitle == nil)
        #expect(decoded.title == "shell")
        var changed = decoded
        changed.customTitle = "server"
        let data = try JSONEncoder().encode(changed)
        #expect(try JSONDecoder().decode(Tab.self, from: data) == changed)
    }

    @Test func setFocusedLeafFollowsRealFocus() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .shell)
        let a = s.tasks[0].tabs[0].root.leaves[0].id
        let b = s.split(taskId: t, tabId: tab, leafId: a, axis: .horizontal, kind: .shell)
        #expect(s.tasks[0].tabs[0].focusedLeafId == b)
        s.setFocusedLeaf(taskId: t, tabId: tab, leafId: a)
        #expect(s.tasks[0].tabs[0].focusedLeafId == a)
        s.setFocusedLeaf(taskId: t, tabId: tab, leafId: UUID())  // not in this tab: ignored
        #expect(s.tasks[0].tabs[0].focusedLeafId == a)
    }

    @Test func toggleDrawerCreatesShellOnce() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        #expect(s.tasks[0].drawer.leaf == nil && !s.tasks[0].drawer.visible)
        s.toggleDrawer(taskId: t)
        let leaf = s.tasks[0].drawer.leaf
        #expect(leaf?.kind == .shell && s.tasks[0].drawer.visible)
        s.toggleDrawer(taskId: t)
        #expect(!s.tasks[0].drawer.visible && s.tasks[0].drawer.leaf == leaf)
        s.toggleDrawer(taskId: t)
        #expect(s.tasks[0].drawer.visible && s.tasks[0].drawer.leaf?.id == leaf?.id)
    }

    @Test func drawerHeightClampedMin() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        #expect(s.tasks[0].drawer.height == 220)
        s.setDrawerHeight(taskId: t, 50)
        #expect(s.tasks[0].drawer.height == 120)
        s.setDrawerHeight(taskId: t, 300)
        #expect(s.tasks[0].drawer.height == 300)
    }

    @Test func oldStateWithoutDrawerDecodes() throws {
        var (s, p) = makeState()
        s.addTask(projectId: p, name: "t")
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        #expect(tasks[0]["drawer"] != nil)
        tasks[0]["drawer"] = nil  // a state.json written before the drawer existed
        root["tasks"] = tasks
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        #expect(!json.contains("drawer"))
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(decoded.tasks[0].drawer == Drawer())
        s.toggleDrawer(taskId: s.tasks[0].id)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func drawerLeafCwdIsTaskCwd() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        s.tasks[1].mode = .worktree(path: "/wt/b", branch: "b", base: "main")
        s.toggleDrawer(taskId: a)
        s.toggleDrawer(taskId: b)
        #expect(s.tasks[0].drawer.leaf?.cwd == "/repo/app")
        #expect(s.tasks[1].drawer.leaf?.cwd == "/wt/b")
    }

    @Test func closeDrawerLeafHidesAndForgetsShell() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.toggleDrawer(taskId: t)
        let first = s.tasks[0].drawer.leaf?.id
        s.closeDrawerLeaf(taskId: t)
        #expect(s.tasks[0].drawer.leaf == nil && !s.tasks[0].drawer.visible)
        s.toggleDrawer(taskId: t)
        #expect(s.tasks[0].drawer.leaf != nil && s.tasks[0].drawer.leaf?.id != first)
    }

    @Test func worktreeTaskLeavesUseWorktreePath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "x", mode: .worktree(path: "/w/x", branch: "x", base: "origin/main"))
        let tab = s.addTab(taskId: t, kind: .claude)
        let leaf = s.tasks[0].tabs[0].focusedLeafId
        let second = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: .shell)
        s.toggleDrawer(taskId: t)
        #expect(s.tasks[0].tabs[0].root.leaves.map(\.cwd) == ["/w/x", "/w/x"])
        #expect(s.tasks[0].tabs[0].root.leaf(id: second)?.cwd == "/w/x")
        #expect(s.tasks[0].drawer.leaf?.cwd == "/w/x")
        #expect(s.tasks[0].branch == "x")
        s.addTask(projectId: p, name: "m")
        #expect(s.tasks[1].branch == nil)
    }

    @Test func oldProjectWithoutWorktreeKeysDecodes() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","name":"a","location":{"local":{"path":"/r"}}}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(p.worktreeByDefault == false && p.worktreeRoot == nil)
        #expect(p.worktreeCopy == nil && p.setupCommand == nil)
        var s = WorkspaceState(projects: [p])
        s.projects[0].worktreeRoot = "/wt"
        s.projects[0].worktreeByDefault = true
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func updateProjectSetsBaseAndRoot() {
        var (s, p) = makeState()
        s.updateProject(id: p, name: "app", path: "/repo/app", baseBranch: "origin/dev", worktreeRoot: "/wt")
        #expect(s.projects[0].lastBaseBranch == "origin/dev" && s.projects[0].worktreeRoot == "/wt")
        s.updateProject(id: p, name: "app", path: "/repo/app", baseBranch: "origin/dev", worktreeRoot: "")
        #expect(s.projects[0].lastBaseBranch == "origin/dev" && s.projects[0].worktreeRoot == nil)
        s.updateProject(id: p, name: "app", path: "/repo/app", baseBranch: nil, worktreeRoot: nil)
        #expect(s.projects[0].lastBaseBranch == nil)
    }

    @Test func updateProjectKeepsWorktreeCwds() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "x", mode: .worktree(path: "/repo/app", branch: "x", base: "main"))
        s.addTab(taskId: t, kind: .shell)
        s.toggleDrawer(taskId: t)
        s.updateProject(id: p, name: "app", path: "/repo/shop", baseBranch: nil, worktreeRoot: nil)
        #expect(s.tasks[0].tabs[0].root.leaves[0].cwd == "/repo/app")
        #expect(s.tasks[0].drawer.leaf?.cwd == "/repo/app")
    }

    @Test func rememberNewTaskChoice() {
        var (s, p) = makeState()
        s.projects[0].lastBaseBranch = "origin/main"
        s.rememberNewTaskChoice(projectId: p, worktree: true, base: nil)
        #expect(s.projects[0].worktreeByDefault && s.projects[0].lastBaseBranch == "origin/main")
        s.rememberNewTaskChoice(projectId: p, worktree: false, base: "origin/dev")
        #expect(!s.projects[0].worktreeByDefault && s.projects[0].lastBaseBranch == "origin/dev")
    }
    @Test func setAgentSessionId() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "x")
        s.addTab(taskId: t, kind: .claude)
        s.toggleDrawer(taskId: t)
        let tabLeaf = s.tasks[0].tabs[0].root.leaves[0].id
        let drawerLeaf = s.tasks[0].drawer.leaf!.id
        s.setAgentSessionId(leafId: tabLeaf, "s1")
        s.setAgentSessionId(leafId: drawerLeaf, "s2")
        #expect(s.tasks[0].tabs[0].root.leaves[0].agentSessionId == "s1")
        #expect(s.tasks[0].drawer.leaf?.agentSessionId == "s2")
        let before = s
        s.setAgentSessionId(leafId: UUID(), "s3")
        #expect(s == before)
    }

    @Test func worktreeSetupIsStoredTrimmed() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "a", path: "/r")
        s.setWorktreeSetup(id: p, copy: [" .env* ", "", "node_modules"], command: "  npm i ")
        #expect(s.projects[0].worktreeCopy == [".env*", "node_modules"])
        #expect(s.projects[0].setupCommand == "npm i")
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s)) == s)
        s.setWorktreeSetup(id: p, copy: [], command: " ")
        #expect(s.projects[0].worktreeCopy == [])     // empty = copy nothing
        #expect(s.projects[0].setupCommand == "")     // blank = no command (nil would be the default one)
        s.setWorktreeSetup(id: p, copy: nil, command: nil)
        #expect(s.projects[0].worktreeCopy == nil && s.projects[0].setupCommand == nil)
    }

    @Test func oldStateDecodesWithDefaults() throws {
        var (s, p) = makeState()
        _ = s.addTask(projectId: p, name: "a")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        var projects = obj["projects"] as! [[String: Any]]
        projects[0].removeValue(forKey: "notifications")
        var tasks = obj["tasks"] as! [[String: Any]]
        tasks[0].removeValue(forKey: "muted")
        obj["projects"] = projects
        obj["tasks"] = tasks
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.projects[0].notifications == .all)
        #expect(back.tasks[0].muted == false)
    }

    @Test func notificationFieldsRoundTrip() throws {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "a")
        s.setProjectNotifications(projectId: p, .urgent)
        s.setMuted(taskId: t, true)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back.projects[0].notifications == .urgent)
        #expect(back.tasks[0].muted)
        #expect(back == s)
    }
}
