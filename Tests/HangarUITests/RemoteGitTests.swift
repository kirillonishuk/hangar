import AppKit
import ControlServer
import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// Git, inspector, worktrees and deletion of remote projects (#47), on the RemoteHostsTests harness (fake ssh only).
/// The project's path `<root>/mac/app` is a real repo on this Mac (a decoy); the fake ssh maps it to the "server"
/// repo `<root>/server/app`. Anything that reads the Mac's copy shows the decoy's data, anything that writes it
/// changes the decoy's snapshot.
@MainActor @Suite struct RemoteGitTests {
    typealias Harness = RemoteHostsTests.Harness

    struct Setup {
        let mac: String, server: String
        let project: UUID, task: UUID
    }

    private func waitUntil(_ seconds: Double = 30, _ cond: () -> Bool) async -> Bool {
        let clock = SuspendingClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    nonisolated private static func git(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "commit.gpgsign=false", "-c", "user.name=T", "-c", "user.email=t@example.com"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "git \(args)", code: Int(p.terminationStatus)) }
    }

    /// Server: `main` with a.txt + .gitignore (`.env`), branch `old`; a.txt modified, new.txt untracked.
    /// Mac decoy: another repo at the project path, plus `app.worktrees/fix-login` and `app.worktrees/old` folders.
    private func setUp(_ h: Harness, connect: Bool = true) async throws -> Setup {
        let mac = h.root + "/mac/app", server = h.root + "/server/app"
        try await RemoteHostsTests.offMain {
            let fm = FileManager.default
            for d in [mac, server, mac + ".worktrees/fix-login", mac + ".worktrees/old"] {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            }
            try Self.git(["init", "-q", "-b", "main"], in: mac)
            try "decoy".write(toFile: mac + "/local.txt", atomically: true, encoding: .utf8)
            try Self.git(["add", "."], in: mac)
            try Self.git(["commit", "-q", "-m", "decoy"], in: mac)
            try Self.git(["init", "-q", "-b", "main"], in: server)
            try "one\n".write(toFile: server + "/a.txt", atomically: true, encoding: .utf8)
            try ".env\n".write(toFile: server + "/.gitignore", atomically: true, encoding: .utf8)
            try Self.git(["add", "."], in: server)
            try Self.git(["commit", "-q", "-m", "init"], in: server)
            try Self.git(["branch", "old"], in: server)
            try "one\ntwo\n".write(toFile: server + "/a.txt", atomically: true, encoding: .utf8)
            try "new\n".write(toFile: server + "/new.txt", atomically: true, encoding: .utf8)
            // The fake ssh maps the Mac path to the server one in every argument (the remote command line included).
            let inner = h.ssh + "-inner"
            try fm.moveItem(atPath: h.ssh, toPath: inner)
            let wrapper = """
            #!/bin/sh
            for a; do shift; set -- "$@" "$(printf '%s' "$a" | sed 's#\(mac)#\(server)#g')"; done
            exec \(shellQuote(inner)) "$@"
            """
            try wrapper.write(toFile: h.ssh, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.ssh)
        }
        var project = UUID(), task = UUID()
        h.app.perform { s in
            project = s.addRemoteProject(name: "app", host: "dev", path: mac)
            task = s.addTask(projectId: project, name: "app")
        }
        if connect { #expect(await h.remote.connect("dev") == .connected) }
        return Setup(mac: mac, server: server, project: project, task: task)
    }

    /// Every file and folder under the decoy with its mtime and size.
    nonisolated private static func snapshot(_ dir: String) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        for rel in (fm.subpaths(atPath: dir) ?? []) + [""] {
            let a = (try? fm.attributesOfItem(atPath: dir + "/" + rel)) ?? [:]
            out[rel] = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(a[.size] ?? 0)"
        }
        return out
    }

    private func gitCalls(_ h: Harness) -> Int {
        FakeSSH.calls(h.log).filter { ($0.last ?? "").contains(" git ") }.count
    }

    private func log(_ h: Harness) -> String { FakeSSH.calls(h.log).compactMap(\.last).joined(separator: "\n") }

    private func watch(_ h: Harness, select task: UUID) -> (InspectorWatch, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let watch = InspectorWatch(app: h.app, window: window)
        watch.windowVisible = { true }
        h.app.perform { $0.inspectorVisible = true }
        h.app.select(taskId: task)
        watch.update()
        return (watch, window)
    }

    private func settle(_ h: Harness) async {
        while let t = h.app.inspector.loading { await t.value }
    }

    @Test func inspectorLoadsOverSSH() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h)
        let before = Self.snapshot(h.root + "/mac")
        let (watch, _) = watch(h, select: s.task)
        await settle(h)
        let m = h.app.inspector
        #expect(m.isGit)
        #expect(m.error == nil)
        #expect(visibleRows(m.tree, expanded: m.expanded).map(\.id).sorted() == [".gitignore", "a.txt", "new.txt"])
        #expect(m.changes?.files.map(\.path).sorted() == ["a.txt", "new.txt"])
        m.loadDiff(path: "a.txt")
        await settle(h)
        guard case .loaded(.text(let hunks, _, _)) = m.diff else { Issue.record("diff \(m.diff)"); return }
        #expect(!hunks.isEmpty)
        #expect(log(h).contains(" status"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(watch.watcher == nil)
        #expect(Self.snapshot(h.root + "/mac") == before)
    }

    @Test func remoteRefreshTriggers() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h)
        let leaf = UUID()
        h.app.perform { st in
            let i = st.tasks.firstIndex { $0.id == s.task }!
            st.tasks[i].tabs = [Tab(title: "", root: .leaf(Leaf(id: leaf, kind: .claude, cwd: s.mac)), focusedLeafId: leaf)]
        }
        let (watch, window) = watch(h, select: s.task)
        await settle(h)
        var n = gitCalls(h)
        #expect(n > 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle(h)
        #expect(gitCalls(h) > n)
        n = gitCalls(h)
        h.app.onLeafDone?(leaf)
        await settle(h)
        #expect(gitCalls(h) > n)
        n = gitCalls(h)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(gitCalls(h) == n)
        #expect(watch.watcher == nil)
    }

    @Test func remoteWorktreeCreate() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h)
        let before = Self.snapshot(h.root + "/mac")
        let project = h.app.project(s.project)!
        let model = NewTaskModel(project: project, git: h.app.git(for: project), taskBranches: [])
        await model.load()
        #expect(model.availability == .ready)
        #expect(model.base == "main")
        model.worktree = true
        model.name = "Fix login"
        // The decoy's `app.worktrees/fix-login` exists on this Mac only: the server's folder is free.
        #expect(model.branch == "fix-login")
        let mode = await model.create(skipFetch: false)
        #expect(mode == .worktree(path: s.mac + ".worktrees/fix-login", branch: "fix-login", base: "main"))
        #expect(FileManager.default.fileExists(atPath: s.server + ".worktrees/fix-login/a.txt"))
        #expect(log(h).contains(" worktree add "))
        #expect(log(h).contains("date -r"))
        #expect(Self.snapshot(h.root + "/mac") == before)
    }

    private final class Calls {
        var confirms: [String] = [], errors: [String] = []
    }

    private func deletion(_ h: Harness, _ s: Setup, branch: String, answer: Bool) -> (UUID, Calls, ActionContext) {
        let path = s.mac + ".worktrees/" + branch
        var id = UUID()
        h.app.perform { st in
            id = st.addTask(projectId: s.project, name: branch, mode: .worktree(path: path, branch: branch, base: "main"))
            st.archiveTask(id: id)
        }
        let calls = Calls()
        var ctx = ActionContext(app: h.app)
        ctx.confirmWithCheckbox = { _, _, _, _, then in then(true) }
        ctx.confirm = { m, _, _, then in calls.confirms.append(m); if answer { then() } }
        ctx.showError = { calls.errors.append($0 + ": " + $1) }
        return (id, calls, ctx)
    }

    @Test func remoteDeleteChecksServer() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h)
        let before = Self.snapshot(h.root + "/mac")
        // `old` has a folder on this Mac, none on the server: the server's answer counts (prune, branch -d).
        let (gone, calls, ctx) = deletion(h, s, branch: "old", answer: true)
        Action.deletePermanently.perform(.task(gone), ctx)
        #expect(await waitUntil { !h.app.state.tasks.contains { $0.id == gone } })
        #expect(await waitUntil { log(h).contains(" branch -d ") })
        #expect(calls.confirms.isEmpty)
        #expect(log(h).contains(" worktree prune"))
        #expect(Self.snapshot(h.root + "/mac") == before)

        // A server worktree holding only an ignored .env: asked first; declined keeps everything.
        try await RemoteHostsTests.offMain {
            try Self.git(["worktree", "add", "-q", "-b", "keep", s.server + ".worktrees/keep", "main"], in: s.server)
            try "SECRET=1".write(toFile: s.server + ".worktrees/keep/.env", atomically: true, encoding: .utf8)
        }
        let (keep, kept, no) = deletion(h, s, branch: "keep", answer: false)
        Action.deletePermanently.perform(.task(keep), no)
        #expect(await waitUntil { kept.confirms.count == 1 })
        #expect(kept.confirms == [L10n.worktreeIgnored])
        #expect(FileManager.default.fileExists(atPath: s.server + ".worktrees/keep/.env"))
        #expect(h.app.state.tasks.contains { $0.id == keep })

        h.app.perform { $0.deleteTask(id: keep) }
        let (again, yes, ok) = deletion(h, s, branch: "keep", answer: true)
        Action.deletePermanently.perform(.task(again), ok)
        #expect(await waitUntil { !h.app.state.tasks.contains { $0.id == again } })
        #expect(yes.confirms == [L10n.worktreeIgnored])
        #expect(!FileManager.default.fileExists(atPath: s.server + ".worktrees/keep"))
    }

    @Test func disconnectedIsCalm() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h, connect: false)
        // Deleting with the host down: refused (the server's worktree can't be checked), the task stays.
        let (id, calls, ctx) = deletion(h, s, branch: "old", answer: true)
        Action.deletePermanently.perform(.task(id), ctx)
        #expect(await waitUntil { calls.errors.count == 1 })
        #expect(h.app.state.tasks.contains { $0.id == id })
        #expect(calls.confirms.isEmpty)

        // The inspector: one calm notice, no git error, nothing run.
        let (_, _) = watch(h, select: s.task)
        await settle(h)
        #expect(h.app.inspector.offline)
        #expect(h.app.inspector.error == nil)
        #expect(!h.app.inspector.remoteNoGit)
        #expect(gitCalls(h) == 0)
        // Back online: the notice's load runs again.
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await waitUntil { !h.app.inspector.offline && h.app.inspector.changes != nil })
    }

    @Test func remoteNoGitShowsNotice() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let s = try await setUp(h)
        try FileManager.default.removeItem(atPath: s.server + "/.git")
        _ = watch(h, select: s.task)
        await settle(h)
        let m = h.app.inspector
        #expect(!m.isGit)
        #expect(m.remoteNoGit)
        #expect(m.tree.children(of: "")?.isEmpty ?? true)
    }

    @Test func remoteActionsDisabled() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let dev = h.app.state.projects.first { $0.host == "dev" }!
        let task = h.app.state.tasks.first { $0.projectId == dev.id }!
        for target in [ActionTarget.task(task.id), .project(dev.id)] {
            #expect(!Action.revealInFinder.isEnabled(for: target, app: h.app))
            #expect(!Action.openInEditor.isEnabled(for: target, app: h.app))
            #expect(Action.copyPath.isEnabled(for: target, app: h.app))
            var ctx = ActionContext(app: h.app)
            ctx.pasteboard = NSPasteboard(name: .init("hangar-test-\(UUID())"))
            Action.copyPath.perform(target, ctx)
            #expect(ctx.pasteboard.string(forType: .string) == "dev:/srv/app")
        }
        // /srv/app is not on this Mac: the host's state decides, not the disk.
        #expect(Action.newTask.isEnabled(for: .project(dev.id), app: h.app))
        #expect(h.app.isAvailable(dev))
        try h.flag("fail", "auth")
        _ = await h.remote.connect("dev")
        #expect(!h.app.isAvailable(dev))
        #expect(!Action.newTask.isEnabled(for: .project(dev.id), app: h.app))
        let r = await h.app.respond(1, .projectsList)
        guard case .success(let data) = r.body else { Issue.record("projects.list failed"); return }
        let info = try JSONDecoder().decode(ProjectsResult.self, from: data).projects.first { $0.id == dev.id }
        #expect(info?.host == "dev")
        #expect(info?.exists == false)
    }
}
