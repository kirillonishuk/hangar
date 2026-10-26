import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// «Copy into new worktrees» + setup command (decision #58), on real temp repos.
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
                       location: Location? = nil, root: String? = nil) -> NewTaskModel {
        let location = location ?? .local(path: t.repo)
        let project = Project(name: "p", location: location, worktreeByDefault: true, worktreeRoot: root,
                              worktreeCopy: copy, setupCommand: command)
        return NewTaskModel(project: project, git: git ?? Git(repo: project.path), taskBranches: [])
    }

    /// A JS monorepo like the user's (pnpm + turbo): tracked lockfile, nested gitignored env files, a root
    /// `node_modules/.pnpm` store and per-app `node_modules` of relative symlinks into it.
    private func monorepo(lockfile: String) async throws -> TempRepo {
        try await TempRepo.offMain {
            let t = try TempRepo()
            let fm = FileManager.default
            func write(_ text: String, _ rel: String) throws {
                let path = t.repo + "/" + rel
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }
            try write("node_modules\n.env\n.env.local\ndist\n.turbo\n", ".gitignore")
            try write("lock", lockfile)
            try write("{}", "apps/saas/package.json")
            try write("{}", "apps/cms/package.json")
            try t.git("add", ".", in: t.repo)
            try t.git("commit", "-q", "-m", "monorepo", in: t.repo)
            try t.git("push", "-q", "origin", "main", in: t.repo)
            try write("ROOT=1", ".env")
            try write("SAAS=1", "apps/saas/.env")
            try write("CMS=1", "apps/cms/.env.local")
            try write("NO", "dist/.env")
            try write("NO", ".turbo/.env")
            try write("module.exports = 'pkg'", "node_modules/.pnpm/pkg@1.0.0/node_modules/pkg/index.js")
            try write("NO", "node_modules/pkg-env/.env")
            try fm.createDirectory(atPath: t.repo + "/apps/saas/node_modules", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: t.repo + "/node_modules/pkg", withDestinationPath: ".pnpm/pkg@1.0.0/node_modules/pkg")
            try fm.createSymbolicLink(atPath: t.repo + "/apps/saas/node_modules/pkg",
                                      withDestinationPath: "../../../node_modules/.pnpm/pkg@1.0.0/node_modules/pkg")
            return t
        }
    }

    private func create(_ m: NewTaskModel, _ name: String, runSetup: Bool? = nil, base: String? = nil) async throws -> String {
        await m.load()
        if let runSetup { m.runSetup = runSetup }
        if let base { m.base = base }
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
        // Recursive name patterns skip node_modules / dist / .turbo / .git; `**/` is the same as no slash.
        let nested = ["apps/saas/.env", "apps/cms/.env.local", "node_modules/x/.env", "dist/.env", "apps/a/.turbo/.env", ".git/.env"]
        #expect(matchIgnored([".env*"], nested) == ["apps/saas/.env", "apps/cms/.env.local"])
        #expect(matchIgnored(["**/.env*"], nested) == ["apps/saas/.env", "apps/cms/.env.local"])
        #expect(matchIgnored(["apps/*/.env*"], nested) == ["apps/saas/.env", "apps/cms/.env.local"])
        #expect(matchIgnored(["node_modules/x/.env"], nested) == ["node_modules/x/.env"])  // named explicitly
    }

    @Test func defaultsFollowThePackageManager() {
        let pnpm = WorktreeDefaults(lockfiles: ["pnpm-lock.yaml", "package-lock.json"])
        #expect(pnpm.command == "pnpm install --frozen-lockfile --prefer-offline" && !pnpm.copy.contains("node_modules"))
        #expect(pnpm.copy.contains(".env*"))
        #expect(WorktreeDefaults(lockfiles: ["yarn.lock"]).command == "yarn install --frozen-lockfile")
        #expect(WorktreeDefaults(lockfiles: ["yarn.lock", ".yarnrc.yml"]).command == "yarn install --immutable")
        #expect(WorktreeDefaults(lockfiles: ["bun.lockb"]).command == "bun install --frozen-lockfile")
        #expect(WorktreeDefaults(lockfiles: ["bun.lock"]).command == "bun install --frozen-lockfile")
        let npm = WorktreeDefaults(lockfiles: ["package-lock.json"])
        #expect(npm.command == nil && npm.copy.contains("node_modules"))
        #expect(WorktreeDefaults(lockfiles: []) == npm)
    }

    @Test func pnpmMonorepoGetsEnvFilesAndInstall() async throws {
        let t = try await monorepo(lockfile: "pnpm-lock.yaml")
        defer { t.cleanup() }
        #expect(try await Git(repo: t.repo).lockfiles() == ["pnpm-lock.yaml"])
        let m = model(t, copy: nil)
        let wt = try await create(m, "pn")
        #expect(try String(contentsOfFile: wt + "/.env", encoding: .utf8) == "ROOT=1")
        #expect(try String(contentsOfFile: wt + "/apps/saas/.env", encoding: .utf8) == "SAAS=1")
        #expect(try String(contentsOfFile: wt + "/apps/cms/.env.local", encoding: .utf8) == "CMS=1")
        #expect(!exists(wt + "/node_modules") && !exists(wt + "/apps/saas/node_modules"))  // pnpm reinstalls from its store
        #expect(!exists(wt + "/dist") && !exists(wt + "/.turbo"))
        // The lockfile's command is only a suggestion: off until the user turns it on (then it is saved to the project).
        #expect(m.setupCommand == "pnpm install --frozen-lockfile --prefer-offline" && !m.runSetup)
        #expect(m.setupScript == nil && m.commandToSave == nil)
        let on = model(t, copy: nil)
        _ = try await create(on, "pn-on", runSetup: true)
        #expect(on.setupScript == "pnpm install --frozen-lockfile --prefer-offline")
        #expect(on.commandToSave == "pnpm install --frozen-lockfile --prefer-offline")
        // A saved command runs by default and is not saved again; an own empty command suggests nothing.
        let saved = model(t, copy: nil, command: "pnpm i")
        _ = try await create(saved, "pn-saved")
        #expect(saved.runSetup && saved.setupScript == "pnpm i" && saved.commandToSave == nil)
        let none = model(t, copy: nil, command: "")
        _ = try await create(none, "pn2")
        #expect(none.setupCommand == nil && none.setupScript == nil)
    }

    @Test func subfolderProjectCopiesFromTheRepoTop() async throws {
        let t = try await monorepo(lockfile: "pnpm-lock.yaml")
        defer { t.cleanup() }
        let m = model(t, copy: nil, location: .local(path: t.repo + "/apps/saas"), root: t.root + "/wt")
        let wt = try await create(m, "sub", runSetup: true)
        // The worktree is a whole checkout: the setup tab opens at its top, where the lockfile is.
        #expect(exists(wt + "/pnpm-lock.yaml"))
        #expect(exists(wt + "/.env") && exists(wt + "/apps/saas/.env") && exists(wt + "/apps/cms/.env.local"))
        #expect(!exists(wt + "/apps/saas/apps"))
        #expect(m.setupScript == "pnpm install --frozen-lockfile --prefer-offline")
    }

    @Test func npmClonesNodeModulesKeepingRelativeLinks() async throws {
        let t = try await monorepo(lockfile: "package-lock.json")
        defer { t.cleanup() }
        let m = model(t, copy: nil)
        let wt = try await create(m, "npm")
        #expect(m.setupScript == nil)
        let fm = FileManager.default
        for link in ["/node_modules/pkg", "/apps/saas/node_modules/pkg"] {
            let dest = try fm.destinationOfSymbolicLink(atPath: wt + link)
            #expect(!dest.hasPrefix("/"))  // still relative: resolves inside the clone, not into the main checkout
            #expect(try String(contentsOfFile: wt + link + "/index.js", encoding: .utf8) == "module.exports = 'pkg'")
            let resolved = URL(fileURLWithPath: wt + link + "/index.js").resolvingSymlinksInPath().path
            #expect(resolved.hasSuffix("/npm/node_modules/.pnpm/pkg@1.0.0/node_modules/pkg/index.js"))
        }
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

    /// The base branch tracks `cfg` as a symlink out of the project, the main checkout has a real `cfg/.env`:
    /// the copy must not write through the worktree's symlink.
    @Test func symlinkedDestinationIsRefused() async throws {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            let fm = FileManager.default
            try ".env\n".write(toFile: t.repo + "/.gitignore", atomically: true, encoding: .utf8)
            try t.git("add", ".gitignore", in: t.repo)
            try t.git("commit", "-q", "-m", "ignore", in: t.repo)
            try t.git("checkout", "-q", "-b", "evil", in: t.repo)
            try fm.createDirectory(atPath: t.base + "/outside", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: t.repo + "/cfg", withDestinationPath: t.base + "/outside")
            try t.git("add", "cfg", in: t.repo)
            try t.git("commit", "-q", "-m", "link", in: t.repo)
            try t.git("checkout", "-q", "main", in: t.repo)
            try fm.createDirectory(atPath: t.repo + "/cfg", withIntermediateDirectories: true)
            try "SECRET=1".write(toFile: t.repo + "/cfg/.env", atomically: true, encoding: .utf8)
            return t
        }
        defer { t.cleanup() }
        let m = model(t, copy: [".env*"])
        let wt = try await create(m, "s", base: "evil")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: wt + "/cfg") == t.base + "/outside")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.base + "/outside").isEmpty)
        #expect(m.setupScript?.contains("cfg/.env") == true)  // reported as a failed copy
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
        let cmd = agentCommand(for: leaf, agent: { $0.rawValue }, shell: "'/bin/zsh'", restoring: false,
                               initialPrompt: "npm install")
        #expect(cmd == "npm install\n'/bin/zsh' -l -i")
        #expect(agentCommand(for: leaf, agent: { $0.rawValue }, shell: "'/bin/zsh'", restoring: true,
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
