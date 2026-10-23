import AppKit
import Exec
import Foundation
import Git
import os
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct InspectorModelTests {
    /// Waits until no load (and no queued rerun) is left.
    private func settle(_ model: InspectorModel) async {
        while let task = model.loading { await task.value }
    }

    private nonisolated static let slow = Runner { args, cwd in
        try await Task.sleep(for: .milliseconds(300))
        return try await Runner.local.run(args, cwd)
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func loadsFilesAndChanges() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        try write("new", repo.repo + "/u.txt")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        await settle(model)
        model.loadDiff(path: "a.txt")
        #expect(model.diffPath == "a.txt")  // the Changes row of the open diff is selected
        await settle(model)
        #expect(model.isGit)
        #expect(model.error == nil)
        let names = model.tree.children(of: "")?.map(\.name) ?? []
        #expect(names.contains("a.txt") && names.contains("u.txt"))
        #expect(model.badges["a.txt"] == .modified)
        #expect(model.badges["u.txt"] == .untracked)
        #expect(model.changes?.files.count == 2)
    }

    /// A project in `sub/` of a repository: Files, Changes and diffs cover only `sub/`, paths relative to it.
    @Test func subfolderProjectShowsDiffs() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try FileManager.default.createDirectory(atPath: repo.repo + "/sub/d", withIntermediateDirectories: true)
        try write("one\n", repo.repo + "/sub/t.txt")
        try repo.git("add", "sub", in: repo.repo); try repo.git("commit", "-q", "-m", "s", in: repo.repo)
        try write("two\n", repo.repo + "/sub/t.txt")
        try write("new\n", repo.repo + "/sub/d/n.txt")
        try write("outside\n", repo.repo + "/a.txt")
        try write("outside\n", repo.repo + "/o.txt")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo + "/sub", baseBranch: { nil })
        await settle(model)
        #expect(model.root == repo.repo + "/sub")
        #expect(Set(model.changes?.files.map(\.path) ?? []) == ["t.txt", "d/n.txt"])
        #expect(model.tree.children(of: "")?.map(\.name).sorted() == ["d", "t.txt"])
        #expect(model.badges == ["t.txt": .modified, "d/n.txt": .untracked])
        for path in ["t.txt", "d/n.txt"] {
            model.loadDiff(path: path)
            await settle(model)
            guard case .loaded(.text(let hunks, _, _)) = model.diff else { Issue.record("\(path): \(model.diff)"); continue }
            #expect(!hunks.isEmpty, "\(path)")
        }
    }

    /// A worktree task of a subfolder project: the same subfolder inside the worktree.
    @Test func worktreeTaskOfSubfolderProject() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try FileManager.default.createDirectory(atPath: repo.repo + "/sub", withIntermediateDirectories: true)
        try write("one\n", repo.repo + "/sub/t.txt")
        try repo.git("add", "sub", in: repo.repo); try repo.git("commit", "-q", "-m", "s", in: repo.repo)
        let wt = repo.worktrees + "/wt"
        try FileManager.default.createDirectory(atPath: repo.worktrees, withIntermediateDirectories: true)
        try repo.git("worktree", "add", "-q", "-b", "wtb", wt, in: repo.repo)
        try write("two\n", wt + "/sub/t.txt")
        try write("outside\n", wt + "/a.txt")
        var s = WorkspaceState()
        let p = s.addProject(name: "sub", path: repo.repo + "/sub")
        let t = s.addTask(projectId: p, name: "wt", mode: .worktree(path: wt, branch: "wtb", base: "main"))
        let dir = NSTemporaryDirectory() + "hangar-sub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let app = AppState(state: s, store: StateStore(directory: URL(fileURLWithPath: dir + "/state")),
                           config: HangarConfig(), configURL: URL(fileURLWithPath: dir + "/config.toml"))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let watch = InspectorWatch(app: app, window: window)
        watch.windowVisible = { true }
        app.perform { $0.inspectorVisible = true }
        app.select(taskId: t)
        watch.update()
        await settle(app.inspector)
        #expect(app.inspector.root == wt + "/sub")
        #expect(app.inspector.changes?.files.map(\.path) == ["t.txt"])
        #expect(app.inspector.tree.children(of: "")?.map(\.name) == ["t.txt"])
        _ = window
    }

    @Test func toggleModeReloads() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try repo.git("checkout", "-q", "-b", "task", in: repo.repo)
        try repo.commit(file: "b.txt", on: "task")
        try write("changed", repo.repo + "/a.txt")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        await settle(model)
        #expect(model.changes?.files.count == 2)
        #expect(model.changes?.mode == .base("main"))
        model.toggleMode()
        #expect(model.modeChoice == .uncommitted)
        await settle(model)
        #expect(model.changes?.files.map(\.path) == ["a.txt"])
        #expect(model.changes?.mode == .uncommitted)
        // The hint offers "compare with main" while showing uncommitted.
        #expect(model.baseName == "main")
    }

    @Test func baseMissingShowsUncommitted() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "origin/gone" })
        await settle(model)
        #expect(model.changes?.baseMissing == true)
        #expect(model.changes?.mode == .uncommitted)
        #expect(model.changes?.files.map(\.path) == ["a.txt"])
    }

    @Test func contextSwitchCancelsAndDropsStale() async throws {
        let a = try await TempRepo.offMain(), b = try await TempRepo.offMain()
        defer { a.cleanup(); b.cleanup() }
        try write("x", a.repo + "/only-a.txt")
        try write("x", b.repo + "/only-b.txt")
        let model = InspectorModel()
        let git: @Sendable (String) -> Git = { Git(repo: $0, runner: Self.slow) }
        model.show(taskId: UUID(), root: a.repo, git: git, baseBranch: { "main" })
        model.show(taskId: UUID(), root: b.repo, git: git, baseBranch: { "main" })
        let topB = try b.git("rev-parse", "--show-toplevel", in: b.repo)
        func noA() -> Bool {
            model.changes?.files.contains { $0.path == "only-a.txt" } != true
                && model.tree.children(of: "")?.contains { $0.name == "only-a.txt" } != true
                && model.badges["only-a.txt"] == nil && (model.root == b.repo || model.root == topB)
        }
        // Polls without spinning the main actor (other suites' main-actor work must keep running); the
        // suspending clock ignores a system sleep in the middle of the run.
        let deadline = SuspendingClock.now + .seconds(60)
        while model.loading != nil, SuspendingClock.now < deadline {
            #expect(noA())
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.loading == nil)
        #expect(noA())
        #expect(model.changes?.files.contains { $0.path == "only-b.txt" } == true)
    }

    @Test func burstCoalescesWithoutStarvation() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let statusCalls = OSAllocatedUnfairLock(initialState: 0)
        let gate = OSAllocatedUnfairLock(initialState: false)
        let counting = Runner { args, cwd in
            // The ignored-paths probe of the tree load is not a status refresh.
            if args.contains("status"), !args.contains("--ignored=matching") {
                statusCalls.withLock { $0 += 1 }
                // Status calls hold until the burst is over: the first load is in flight for the whole burst on any machine.
                while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            }
            return try await Runner.local.run(args, cwd)
        }
        let model = InspectorModel()
        let git: @Sendable (String) -> Git = { Git(repo: $0, runner: counting) }
        model.show(taskId: UUID(), root: repo.repo, git: git, baseBranch: { "main" })
        for _ in 0..<10 {
            #expect(model.loading != nil)
            model.refresh(.status)
            try await Task.sleep(for: .milliseconds(10))
        }
        gate.withLock { $0 = true }
        await settle(model)
        #expect(statusCalls.withLock { $0 } == 2)
        #expect(model.changes?.files.map(\.path) == ["a.txt"])
    }

    @Test func nonGitFolder() async throws {
        let dir = NSTemporaryDirectory() + "hangar-plain-\(UUID().uuidString)/папка с пробелом"
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try write("a", dir + "/a.txt")
        try write("", dir + "/.DS_Store")
        try write("x", dir + "/sub/x.txt")
        let model = InspectorModel()
        model.segment = .changes
        model.show(taskId: UUID(), root: dir, baseBranch: { nil })
        await settle(model)
        #expect(model.isGit == false)
        #expect(model.segment == .files)
        #expect(model.changes == nil)
        #expect(model.tree.children(of: "")?.map(\.name) == ["sub", "a.txt"])
        #expect(model.tree.children(of: "sub") == nil)
        model.expand("sub")
        await settle(model)
        #expect(model.expanded.contains("sub"))
        #expect(model.tree.children(of: "sub")?.map(\.path) == ["sub/x.txt"])

        try FileManager.default.createDirectory(atPath: dir + "/sub/.git", withIntermediateDirectories: true)
        #expect(listDirectory(URL(fileURLWithPath: dir + "/sub")).map(\.name) == ["x.txt"])
    }

    @Test func diffWithoutChangesFailsInsteadOfLoadingForever() async throws {
        let dir = NSTemporaryDirectory() + "hangar-nogit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let model = InspectorModel()
        model.show(taskId: UUID(), root: dir, baseBranch: { nil })
        await settle(model)
        #expect(model.changes == nil)
        model.loadDiff(path: "a.txt")
        await settle(model)
        guard case .failed = model.diff else { Issue.record("diff is \(model.diff)"); return }
    }

    @Test func treeLoadCachesIgnoredPaths() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("node_modules/\n", repo.repo + "/.gitignore")
        try FileManager.default.createDirectory(atPath: repo.repo + "/node_modules/a", withIntermediateDirectories: true)
        try write("x", repo.repo + "/node_modules/a/i.js")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        await settle(model)
        #expect(model.ignored.paths == [realPath(repo.repo) + "/node_modules"])
    }

    @Test func treeFailureKeepsChanges() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let failing = Runner { args, cwd in
            if args.contains("ls-files") { return RunResult(status: 128, stdout: "", stderr: "boom") }
            return try await Runner.local.run(args, cwd)
        }
        let model = InspectorModel()
        let git: @Sendable (String) -> Git = { Git(repo: $0, runner: failing) }
        model.show(taskId: UUID(), root: repo.repo, git: git, baseBranch: { "main" })
        await settle(model)
        #expect(model.changes?.files.map(\.path) == ["a.txt"])
        #expect(model.error == nil)
        #expect(model.filesError?.contains("boom") == true)
    }

    @Test func baseBranchAskedOncePerContext() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let model = InspectorModel()
        let base: @Sendable () async -> String? = { calls.withLock { $0 += 1 }; return "main" }
        model.show(taskId: UUID(), root: repo.repo, baseBranch: base)
        await settle(model)
        model.refresh(.status); await settle(model)
        model.toggleMode(); await settle(model)
        model.toggleMode(); await settle(model)
        #expect(calls.withLock { $0 } == 1)
        model.show(taskId: UUID(), root: repo.repo, baseBranch: base)
        await settle(model)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func baseFollowsSettings() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try repo.git("branch", "dev", in: repo.repo)
        let current = OSAllocatedUnfairLock<String?>(initialState: nil)
        let base: @Sendable () async -> String? = { current.withLock { $0 } }
        let model = InspectorModel()
        let task = UUID()
        model.show(taskId: task, root: repo.repo, baseBranch: base)
        await settle(model)
        #expect(model.changes?.baseMissing == true)
        // A cached nil recovers on the next show of the same task.
        current.withLock { $0 = "main" }
        model.show(taskId: task, root: repo.repo, baseBranch: base)
        await settle(model)
        #expect(model.changes?.mode == .base("main"))
        // Project settings saved with another default base.
        current.withLock { $0 = "dev" }
        model.baseChanged()
        await settle(model)
        #expect(model.changes?.mode == .base("dev"))
    }

    @Test func directorySymlinkIsNotExpandableNorOpenable() throws {
        let dir = NSTemporaryDirectory() + "hangar-sym-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/loop", withDestinationPath: dir)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: dir + "/flink", withDestinationPath: "f.txt")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let entries = listDirectory(URL(fileURLWithPath: dir))
        func entry(_ n: String) -> FileTree.Entry? { entries.first { $0.name == n } }
        #expect(entry("real")?.isDir == true)
        #expect(entry("loop")?.isDir == false && entry("loop")?.opensInEditor == false)
        #expect(entry("link")?.isDir == false && entry("link")?.opensInEditor == false)
        #expect(entry("flink")?.opensInEditor == true)
        #expect(entry("f.txt")?.opensInEditor == true)
        var tree = FileTree()
        tree.setChildren(entries, of: "sub")
        #expect(tree.children(of: "sub")?.first { $0.name == "loop" }?.opensInEditor == false)
    }

    @Test func diffStateFollowsChanges() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let model = InspectorModel()
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        model.loadDiff(path: "a.txt")
        await settle(model)
        guard case .loaded(.text(let hunks, _, _)) = model.diff else {
            Issue.record("diff is \(model.diff)"); return
        }
        #expect(!hunks.isEmpty)
        try repo.git("checkout", "a.txt", in: repo.repo)
        model.refresh(.status)
        await settle(model)
        #expect(model.diff == .notChanged)
        model.loadDiff(path: nil)
        #expect(model.diff == DiffState.none)
    }

    @Test func baseBranchOfTask() async throws {
        let repo = try await TempRepo.offMain()
        defer { repo.cleanup() }
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: repo.repo)
        let main = s.addTask(projectId: p, name: "m")
        let app = AppState(state: s, store: StateStore(directory: URL(fileURLWithPath: repo.root + "/state")),
                           config: HangarConfig(), configURL: URL(fileURLWithPath: repo.root + "/config.toml"))
        let task = app.state.tasks.first { $0.id == main }!
        #expect(await app.baseBranch(of: task) == "origin/main")
        app.perform { $0.projects[0].lastBaseBranch = "dev" }
        #expect(await app.baseBranch(of: task) == "dev")
        var wt = task
        wt.mode = .worktree(path: repo.repo, branch: "feat", base: "release")
        #expect(await app.baseBranch(of: wt) == "release")
    }
}
