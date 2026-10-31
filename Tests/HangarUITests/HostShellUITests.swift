import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// «<host> · терминал» in the app (#64): plain `ssh -t` shells, never the host's master, check or tmux.
/// On the RemoteHostsTests harness (fake ssh only); Ghostty is not started, so a launch only builds its spec.
@MainActor @Suite struct HostShellUITests {
    typealias Harness = RemoteHostsTests.Harness

    private func leaves(_ h: Harness, _ task: UUID) -> [Leaf] {
        h.app.state.tasks.first { $0.id == task }?.tabs.flatMap(\.root.leaves) ?? []
    }

    @Test func plainShellNeverTouchesTheHost() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let o = try #require(h.app.openHostShell("box"))
        #expect(h.app.state.selectedTaskId == o.task)
        let leaf = try #require(leaves(h, o.task).first)
        #expect(h.app.remoteLeafHost(leaf.id) == nil)
        #expect(h.app.hostShellHost(ofLeaf: leaf.id) == "box")
        let (spec, _) = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil))
        #expect(spec == sshShellSpec(host: "box", sshPath: h.app.sshPath,
                                     plan: HostShellPlan(hook: true, controlPath: h.app.sshPaths.shellControlPath(leaf.id), ownMaster: true)))
        #expect(h.app.remoteFiles.link(of: leaf.id) == RemoteShellLink(host: "box", controlPath: h.app.sshPaths.shellControlPath(leaf.id), sshPath: h.app.sshPath))
        // No host master, no server check: the host stays unknown to `RemoteHosts`.
        #expect(h.app.remote.hosts["box"] == nil)
        // Only `ssh -G` (the user's config, no connection) ran.
        #expect(FakeSSH.calls(h.log).allSatisfy { $0.first == "-G" })
        #expect(Action.list(for: .task(o.task), app: h.app).isEmpty)
        #expect(!Action.archive.isEnabled(for: .task(o.task), app: h.app))
    }

    /// The inspector follows the focused leaf of a host's terminal (#124): Search runs through that leaf's master in the
    /// folder its shell reported; a project chat gets the usual target again.
    @Test func inspectorFollowsTheHostShellLeaf() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        var local: UUID?
        h.app.perform { s in
            let p = s.addProject(name: "local", path: NSTemporaryDirectory())
            local = s.addTask(projectId: p, name: "t")
        }
        let project = try #require(local)
        h.app.select(taskId: project)
        #expect(h.app.hostShellFocusedLeaf == nil)
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        #expect(h.app.hostShellFocusedLeaf == leaf.id)
        _ = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil))
        h.app.remoteFiles.isUp = { _ in false }
        h.app.remoteFiles.follow(h.app.hostShellFocusedLeaf)
        h.app.remoteFiles.pwd(leaf.id, "/var/www/app")
        let target = try #require(h.app.searchTarget)
        #expect(target.root == "/var/www/app" && target.host == "box" && target.link?.controlPath == h.app.sshPaths.shellControlPath(leaf.id))
        // Closing the terminal ends its master and forgets the folder.
        var stopped: [RemoteShellLink] = []
        h.app.remoteFiles.stopMaster = { stopped.append($0) }
        h.app.closeHostShell("box")
        #expect(stopped.map(\.controlPath) == [h.app.sshPaths.shellControlPath(leaf.id)])
        #expect(h.app.remoteFiles.link(of: leaf.id) == nil && h.app.remoteFiles.shown == nil)
    }

    /// Never worse than #64's plain login (#124): a RemoteCommand host, a user's own master, an unsafe socket folder
    /// and a login shell that can't run the hook all fall back.
    @Test func launchFollowsTheUsersSSHConfig() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        func spec() throws -> LaunchSpec { try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil)).0 }

        h.app.sshResolve = { _, _ in ["remotecommand": "tmux attach", "controlmaster": "false"] }
        let own = h.app.sshPaths.shellControlPath(leaf.id)
        #expect(try spec() == sshShellSpec(host: "box", sshPath: h.app.sshPath, plan: HostShellPlan(hook: false, controlPath: own, ownMaster: true)))

        h.app.sshResolve = { _, _ in ["controlmaster": "auto", "controlpath": "/Users/me/.ssh/cm-box", "controlpersist": "600"] }
        #expect(try spec() == sshShellSpec(host: "box", sshPath: h.app.sshPath,
                                           plan: HostShellPlan(hook: true, controlPath: "/Users/me/.ssh/cm-box", ownMaster: false)))
        #expect(!(try spec().command.contains("ControlMaster=auto")))
        #expect(h.app.remoteFiles.link(of: leaf.id)?.owned == false && h.app.remoteFiles.link(of: leaf.id)?.exitArgv == nil)

        h.app.sshResolve = { _, _ in nil }  // ssh -G failed: exactly #64
        #expect(try spec() == sshShellSpec(host: "box", sshPath: h.app.sshPath))
        #expect(h.app.remoteFiles.link(of: leaf.id) == nil)
    }

    /// Someone else's (or a symlinked) socket folder: no `-S` at all, a plain tab without the files panel.
    @Test func unsafeSocketFolderMeansAPlainTab() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let dir = h.app.sshPaths.dir
        try #require(dir.hasPrefix(h.root))  // never a shared /tmp/hangar-<uid>
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: h.root + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: h.root + "/elsewhere")
        h.app.sshResolve = { _, _ in [:] }
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        let spec = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil)).0
        #expect(spec == sshShellSpec(host: "box", sshPath: h.app.sshPath))
        #expect(h.app.remoteFiles.link(of: leaf.id) == nil)
    }

    /// A hooked login that dies right away, nothing typed (key login on tcsh, rbash, an appliance): the tab logs in
    /// again plain at once; the second such failure on the host marks it for good.
    @Test func failedHookFallsBackToPlain() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.app.sshResolve = { _, _ in [:] }
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        _ = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil))
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 255, typed: false))  // wrong password / lost connection
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 0, typed: false))
        #expect(h.app.hostShellHookFailed(leaf: leaf.id, code: 1, typed: false))
        #expect(h.app.state.hostShells.first?.noHook == false)  // one ambiguous exit is not persisted
        let plain = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil)).0
        #expect(!plain.command.contains("kitty-shell-cwd") && plain.command.contains("ControlMaster=auto"))
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 1, typed: false))  // no loop
        // Another tab of the host fails the same way: now the host is marked, persisted.
        h.app.addTab(.shell)
        let tab2 = try #require(h.app.state.tasks.first { $0.id == o.task }?.tabs.last)
        let leaf2 = try #require(tab2.root.leaves.first)
        #expect(leaf2.id != leaf.id)
        _ = try h.app.spec(for: leaf2, tabId: tab2.id, context: .created(prompt: nil))
        #expect(h.app.hostShellHookFailed(leaf: leaf2.id, code: 127, typed: false))
        let saved = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(h.app.state))
        #expect(saved.hostShells.first?.noHook == true)
        h.app.closeHostShell("box")
        _ = try #require(h.app.openHostShell("box"))
        #expect(h.app.state.hostShells.first?.noHook == false)
    }

    /// Normal exits are not the hook's failure: Ctrl-C at the password prompt (a signal), and the user's own `exit`
    /// after a failed command in a shell that never reports a folder (ksh, dash, bash with its own PROMPT_COMMAND).
    @Test func normalExitsNeverReLogIn() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.app.sshResolve = { _, _ in [:] }
        var now = Date()
        h.app.hookClock = { now }
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        func launch() throws { _ = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil)) }
        try launch()
        for code: Int32 in [-1, 130, 129, 143] {
            #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: code, typed: true))
        }
        // `exit` long after the launch: not the hook.
        now += 600
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 1, typed: true))
        // A quick `false; exit` right after a typed password: no re-login (↩ is the user's), the leaf's next login is
        // plain — the same for a shell that never reports a folder — and nothing is persisted.
        try launch()
        now += 5
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 1, typed: true))
        #expect(h.app.state.hostShells.first?.noHook == false)
        let next = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil)).0
        #expect(!next.command.contains("kitty-shell-cwd"))
    }

    /// Once the shell reported its folder the hook works: a later error exit is the user's command, not the hook.
    @Test func errorAfterAPromptIsNotTheHook() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.app.sshResolve = { _, _ in [:] }
        let o = try #require(h.app.openHostShell("box"))
        let leaf = try #require(leaves(h, o.task).first)
        _ = try h.app.spec(for: leaf, tabId: o.tab, context: .created(prompt: nil))
        h.app.remoteFiles.pwd(leaf.id, "/root")
        #expect(!h.app.hostShellHookFailed(leaf: leaf.id, code: 1, typed: false))
    }

    @Test func invalidHostRefused() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        for bad in ["-oProxyCommand=touch x", "", "a b"] { #expect(h.app.openHostShell(bad) == nil) }
        #expect(h.app.state.hostShells.isEmpty)
    }

    @Test func closingTheLastTabForgetsTheHostTask() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let o = try #require(h.app.openHostShell("box"))
        h.app.perform { $0.closeTab(taskId: o.task, tabId: o.tab) }
        #expect(h.app.state.hostShellTask(host: "box") == nil)
        #expect(FakeSSH.calls(h.log).isEmpty)  // no kill-session: nothing ran in tmux
        _ = try #require(h.app.openHostShell("box"))
        h.app.closeHostShell("box")
        #expect(h.app.state.hostShells.isEmpty)
    }

    @Test func sidebarListsConfigHosts() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let config = h.root + "/ssh_config"
        try "Host alpha dev\nHost *\n  User me\nHost beta\n".write(toFile: config, atomically: true, encoding: .utf8)
        h.app.sshConfigPath = config
        #expect(h.app.sidebarHosts == ["dev", "other"])  // not read until the app asks (launch, activation)
        h.app.reloadConfigHosts()
        _ = h.app.openHostShell("typed")
        #expect(h.app.sidebarHosts == ["dev", "other", "typed", "alpha", "beta"])
        #expect(h.app.sshHosts == ["dev", "other"])  // project hosts keep their own rows and menu
        try "Host gamma\n".write(toFile: config, atomically: true, encoding: .utf8)
        h.app.reloadConfigHosts()
        #expect(h.app.sidebarHosts == ["dev", "other", "typed", "gamma"])
    }

    @Test func restoredAfterRelaunch() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let o = try #require(h.app.openHostShell("box"))
        let saved = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(h.app.state))
        let dir = URL(fileURLWithPath: h.root + "/state2")
        let app = AppState(state: saved, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: h.root + "/h2.sock")
        app.keepAwake = .inert()
        app.sshPath = h.ssh
        let leaf = try #require(app.state.tasks.first { $0.id == o.task }?.tabs.first?.root.leaves.first)
        #expect(app.isRestored(leafId: leaf.id))
        #expect(try app.spec(for: leaf, tabId: o.tab, context: app.launchContext(for: leaf.id)).0 == sshShellSpec(
            host: "box", sshPath: h.ssh, plan: HostShellPlan(hook: true, controlPath: app.sshPaths.shellControlPath(leaf.id), ownMaster: true)))
    }

    @Test func controlOpensATab() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        guard case .success(let data) = await h.app.respond(3, .sshOpen(host: "box")).body else { Issue.record("failed"); return }
        let r = try JSONDecoder().decode(TabResult.self, from: data)
        #expect(h.app.state.hostShellTask(host: "box")?.id == r.task)
        #expect(r.tab.kind == .shell)
        guard case .failure(let e) = await h.app.respond(4, .sshOpen(host: "-oProxyCommand=x")).body else { Issue.record("accepted"); return }
        #expect(e.code == .badParams)
    }
}
