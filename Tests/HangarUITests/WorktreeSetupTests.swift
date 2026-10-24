import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// «Copy into new worktrees» + setup command (decision #NN-worktree-setup), on real temp repos.
@MainActor @Suite struct WorktreeSetupTests {
    /// Repo with a committed `.gitignore` and typical ignored items next to tracked / untracked-not-ignored ones.
    private func repo() async throws -> TempRepo {
        try await TempRepo.offMain {
            let t = try TempRepo()
            let fm = FileManager.default
            try ".env\n.env.local\nnode_modules/\nlinked\nbuild/\n".write(toFile: t.repo + "/.gitignore", atomically: true, encoding: .utf8)
            try "EXAMPLE=1".write(toFile: t.repo + "/.env.example", atomically: true, encoding: .utf8)
            try t.git("add", ".gitignore", ".env.example", in: t.repo)
            try t.git("commit", "-q", "-m", "ignore", in: t.repo)
            try t.git("push", "-q", "origin", "main", in: t.repo)
            try "SECRET=1".write(toFile: t.repo + "/.env", atomically: true, encoding: .utf8)
            try "LOCAL=1".write(toFile: t.repo + "/.env.local", atomically: true, encoding: .utf8)
            try "untracked".write(toFile: t.repo + "/.envrc", atomically: true, encoding: .utf8)
            try fm.createDirectory(atPath: t.repo + "/node_modules/pkg", withIntermediateDirectories: true)
            try "module.exports = 1".write(toFile: t.repo + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
            try fm.createDirectory(atPath: t.repo + "/build", withIntermediateDirectories: true)
            try "x".write(toFile: t.repo + "/build/out.js", atomically: true, encoding: .utf8)
            // Outside the project: reachable only through `..`, an absolute path or the ignored symlink `linked`.
            try fm.createDirectory(atPath: t.base + "/outside", withIntermediateDirectories: true)
            try "TOP SECRET".write(toFile: t.base + "/outside/secret", atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: t.repo + "/linked", withDestinationPath: t.base + "/outside")
            return t
        }
    }

    private func model(_ t: TempRepo, copy: [String]?, command: String? = nil, git: Git? = nil,
                       location: Location? = nil) -> NewTaskModel {
        let project = Project(name: "p", location: location ?? .local(path: t.repo), worktreeByDefault: true,
                              worktreeCopy: copy, setupCommand: command)
        return NewTaskModel(project: project, git: git ?? Git(repo: t.repo), taskBranches: [])
    }

    private func create(_ m: NewTaskModel, _ name: String) async throws -> String {
        await m.load()
        m.name = name
        guard case .worktree(let path, _, _)? = await m.create(skipFetch: false) else {
            Issue.record("worktree not created: \(m.createError ?? "-")")
            throw CancellationError()
        }
        return path
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    @Test func patternMatching() {
        let entries = [".env", ".env.local", "node_modules", "apps/web/node_modules", "apps/web/.env", "vendor/bundle", "build"]
        #expect(matchIgnored([".env*"], entries) == [".env", ".env.local", "apps/web/.env"])
        #expect(matchIgnored(["node_modules"], entries) == ["node_modules", "apps/web/node_modules"])
        #expect(matchIgnored(["/node_modules"], entries) == ["node_modules"])
        #expect(matchIgnored(["apps/*/node_modules/"], entries) == ["apps/web/node_modules"])
        #expect(matchIgnored(["vendor/bundle"], entries) == ["vendor/bundle"])
        #expect(matchIgnored(["../x", "/etc/hosts", "..", "", "  "], entries + ["../x"]).isEmpty)
        #expect(matchIgnored(["node_modules", "*"], ["node_modules"]) == ["node_modules"])  // no duplicates
    }

    @Test func defaultListCopiesIgnoredOnly() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, copy: nil)
        let wt = try await create(m, "a")
        #expect(try String(contentsOfFile: wt + "/.env", encoding: .utf8) == "SECRET=1")
        #expect(exists(wt + "/.env.local"))
        #expect(exists(wt + "/node_modules/pkg/index.js"))
        #expect(exists(wt + "/.env.example"))  // tracked: checked out by git
        #expect(!exists(wt + "/.envrc"))       // untracked but not ignored
        #expect(!exists(wt + "/build"))        // ignored but not in the list
        #expect(m.setupScript == nil)
        #expect(m.progress == nil)
        // A clone, not a link: changing the copy leaves the original alone.
        try "CHANGED".write(toFile: wt + "/.env", atomically: false, encoding: .utf8)
        #expect(try String(contentsOfFile: t.repo + "/.env", encoding: .utf8) == "SECRET=1")
        let attrs = try FileManager.default.attributesOfItem(atPath: wt + "/node_modules")
        #expect(attrs[.type] as? FileAttributeType == .typeDirectory)
    }

    @Test func globsAndMissingPaths() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, copy: [".env.l*", ".venv", "vendor/bundle", "build/"])
        let wt = try await create(m, "b")
        #expect(exists(wt + "/.env.local"))
        #expect(!exists(wt + "/.env"))
        #expect(exists(wt + "/build/out.js"))
        #expect(!exists(wt + "/.venv") && !exists(wt + "/vendor"))
        #expect(m.setupScript == nil)  // missing paths are skipped silently
    }

    @Test func nothingOutsideTheProject() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, copy: ["../outside", t.base + "/outside", "linked", "../outside/secret"])
        let wt = try await create(m, "c")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: wt + "/linked")
        #expect(link == t.base + "/outside")  // the user's own symlink stays a symlink; its target is not copied
        let parent = (wt as NSString).deletingLastPathComponent
        #expect(!exists(parent + "/outside"))
        #expect(!exists(wt + "/outside") && !exists(wt + "/secret"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.base + "/outside") == ["secret"])
    }

    @Test func setupCommandIsQueued() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, copy: [], command: "  npm install  ")
        let wt = try await create(m, "d")
        #expect(m.setupScript == "npm install")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-setup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: t.repo)
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.keepAwake = .inert()
        app.codexRead = nil
        let created = app.createTask(projectId: p, name: "d", firstMessage: "", mode: .worktree(path: wt, branch: "d", base: "origin/main"),
                                     setup: m.setupScript)
        let task = try #require(app.state.tasks.first { $0.id == created.task })
        #expect(task.tabs.count == 2)
        #expect(task.activeTabId == created.tab)  // the agent tab stays in front
        let shell = try #require(task.tabs.last?.root.leaves.first)
        #expect(shell.kind == .shell && shell.cwd == wt)
        #expect(app.launchContext(for: shell.id) == .created(prompt: "npm install"))
        // No setup: one agent tab, as before.
        let plain = app.createTask(projectId: p, name: "e", firstMessage: "", mode: .mainFolder, setup: nil)
        #expect(app.state.tasks.first { $0.id == plain.task }?.tabs.count == 1)
    }

    @Test func shellRunsSetupThenStaysInteractive() {
        let leaf = Leaf(kind: .shell, cwd: "/w")
        let cmd = agentCommand(for: leaf, agent: { $0.rawValue }, editor: "hx", shell: "'/bin/zsh'", restoring: false,
                               initialPrompt: "npm install")
        #expect(cmd == "npm install\n'/bin/zsh' -l -i")
        #expect(agentCommand(for: leaf, agent: { $0.rawValue }, editor: "hx", shell: "'/bin/zsh'", restoring: true,
                             initialPrompt: nil) == "'/bin/zsh' -l -i")
    }

    @Test func failuresArePrintedInTheSetupTab() {
        #expect(worktreeSetupScript(failures: [], command: nil) == nil)
        #expect(worktreeSetupScript(failures: [], command: "  ") == nil)
        let s = worktreeSetupScript(failures: ["node_modules: it's broken"], command: "npm i")
        #expect(s == "printf '%s\\n' " + shellQuote(L10n.copyFailed("node_modules: it's broken")) + " >&2\nnpm i")
    }

    @Test func remoteCopyUsesHostRunner() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let git = Git(repo: t.repo, runner: .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path))
        let m = model(t, copy: [".env", "node_modules"], command: "pnpm i", git: git, location: .ssh(host: "dev", path: t.repo))
        let wt = try await create(m, "r")
        #expect(exists(wt + "/.env") && exists(wt + "/node_modules/pkg/index.js"))
        #expect(m.setupScript == "pnpm i")
        let log = try String(contentsOfFile: ssh.log, encoding: .utf8)
        #expect(log.contains("--reflink=auto"))
        #expect(!log.contains("cp -cpR"))
    }
}
