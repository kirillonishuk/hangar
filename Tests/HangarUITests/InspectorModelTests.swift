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
        let repo = try TempRepo()
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

    @Test func toggleModeReloads() async throws {
        let repo = try TempRepo()
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
        let repo = try TempRepo()
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
        let a = try TempRepo(), b = try TempRepo()
        defer { a.cleanup(); b.cleanup() }
        try write("x", a.repo + "/only-a.txt")
        try write("x", b.repo + "/only-b.txt")
        let model = InspectorModel(git: { Git(repo: $0, runner: Self.slow) })
        model.show(taskId: UUID(), root: a.repo, baseBranch: { "main" })
        model.show(taskId: UUID(), root: b.repo, baseBranch: { "main" })
        let topB = try b.git("rev-parse", "--show-toplevel", in: b.repo)
        func noA() -> Bool {
            model.changes?.files.contains { $0.path == "only-a.txt" } != true
                && model.tree.children(of: "")?.contains { $0.name == "only-a.txt" } != true
                && model.badges["only-a.txt"] == nil && (model.root == b.repo || model.root == topB)
        }
        let deadline = Date().addingTimeInterval(60)
        while model.loading != nil, Date() < deadline {
            #expect(noA())
            await Task.yield()
        }
        #expect(model.loading == nil)
        #expect(noA())
        #expect(model.changes?.files.contains { $0.path == "only-b.txt" } == true)
    }

    @Test func burstCoalescesWithoutStarvation() async throws {
        let repo = try TempRepo()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let statusCalls = OSAllocatedUnfairLock(initialState: 0)
        let counting = Runner { args, cwd in
            // The ignored-paths probe of the tree load is not a status refresh.
            if args.contains("status"), !args.contains("--ignored=matching") { statusCalls.withLock { $0 += 1 } }
            return try await Self.slow.run(args, cwd)
        }
        let model = InspectorModel(git: { Git(repo: $0, runner: counting) })
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        for _ in 0..<10 {
            #expect(model.loading != nil)
            model.refresh(.status)
            try await Task.sleep(for: .milliseconds(50))
        }
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
        let repo = try TempRepo()
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
        let repo = try TempRepo()
        defer { repo.cleanup() }
        try write("changed", repo.repo + "/a.txt")
        let failing = Runner { args, cwd in
            if args.contains("ls-files") { return RunResult(status: 128, stdout: "", stderr: "boom") }
            return try await Runner.local.run(args, cwd)
        }
        let model = InspectorModel(git: { Git(repo: $0, runner: failing) })
        model.show(taskId: UUID(), root: repo.repo, baseBranch: { "main" })
        await settle(model)
        #expect(model.changes?.files.map(\.path) == ["a.txt"])
        #expect(model.error == nil)
        #expect(model.filesError?.contains("boom") == true)
    }

    @Test func baseBranchAskedOncePerContext() async throws {
        let repo = try TempRepo()
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
        let repo = try TempRepo()
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
        let repo = try TempRepo()
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
