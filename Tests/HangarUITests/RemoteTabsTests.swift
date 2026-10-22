import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Remote tabs in the UI layer (#47), on the RemoteHostsTests harness (fake ssh only). Surfaces are never created
/// for real here: Ghostty is not started in tests, so a launch only builds its spec.
@MainActor @Suite struct RemoteTabsTests {
    typealias Harness = RemoteHostsTests.Harness

    private func waitUntil(_ seconds: Double = 30, _ cond: () -> Bool) async -> Bool {
        let clock = SuspendingClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    private func leaf(_ h: Harness, _ id: UUID) -> Leaf {
        h.app.state.tasks.flatMap(\.tabs).flatMap(\.root.leaves).first { $0.id == id }!
    }

    /// Records every launch context and the mode the app computed for it.
    final class Launches {
        var contexts: [LaunchContext] = []
        var modes: [LaunchMode] = []
    }

    private func start(_ view: LeafView, _ h: Harness, leaf: Leaf, tab: UUID, context: LaunchContext, into log: Launches) {
        view.start(context) { [app = h.app] ctx in
            log.contexts.append(ctx)
            let r = try app.spec(for: leaf, tabId: tab, context: ctx)
            log.modes.append(r.1)
            return r
        }
    }

    @Test func notConnectedThenStarts() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        var connectedHosts: [String] = []
        h.app.onHostConnected = { connectedHosts.append($0) }
        let dev = h.leaf("dev")
        let view = LeafView(leafId: dev.leaf)
        view.host = "dev"
        let log = Launches()
        start(view, h, leaf: leaf(h, dev.leaf), tab: dev.tab, context: .created(prompt: "hi"), into: log)
        #expect(log.modes.isEmpty)
        #expect(view.isWaitingForHost)
        // `spec` started the connection itself.
        #expect(await waitUntil { h.state() == .connected })
        #expect(connectedHosts == ["dev"])

        hostConnected(host: "dev", leaves: [view])
        #expect(!view.isWaitingForHost)
        #expect(log.contexts == [.created(prompt: "hi"), .created(prompt: "hi")])
        #expect(log.modes == [LaunchMode(restoring: false, initialPrompt: "hi")])
    }

    @Test func exit255IsDetached() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        for (name, host) in [("dev", "dev"), ("local", nil)] as [(String, String?)] {
            let l = h.leaf(name)
            h.app.handle(.event(EventMessage(tab: l.tab, leaf: l.leaf, kind: .prompt)))
            #expect(h.app.state(ofLeaf: l.leaf) == .working)
            let view = LeafView(leafId: l.leaf)
            view.host = host
            view.onExit = { [app = h.app] in app.signal(.exited(code: $0), leaf: l.leaf) }
            start(view, h, leaf: leaf(h, l.leaf), tab: l.tab, context: .created(prompt: nil), into: Launches())
            view.childExited(255)
            if host != nil {
                #expect(view.isDetached)
                #expect(view.needsRelaunch)
                #expect(h.app.state(ofLeaf: l.leaf) == .working)
                #expect(h.app.location(ofLeaf: l.leaf) != nil)
            } else {
                #expect(!view.isDetached)
                #expect(h.app.state(ofLeaf: l.leaf) == .failed)
            }
        }
    }

    @Test func reattachNeverResendsPrompt() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let project = h.app.state.projects.first { $0.name == "dev" }!
        let created = h.app.createTask(projectId: project.id, name: "t", firstMessage: "fix it", mode: .mainFolder)
        let task = h.app.state.tasks.first { $0.id == created.task }!
        let l = task.tabs[0].root.leaves[0]
        let view = LeafView(leafId: l.id)
        view.host = "dev"
        let log = Launches()
        start(view, h, leaf: l, tab: created.tab, context: h.app.launchContext(for: l.id), into: log)
        #expect(log.modes == [LaunchMode(restoring: false, initialPrompt: "fix it")])
        h.app.handle(.event(EventMessage(tab: created.tab, leaf: l.id, kind: .prompt)))
        view.childExited(255)
        hostConnected(host: "dev", leaves: [view])
        #expect(log.contexts.last == .reattach(previous: LaunchMode(restoring: false, initialPrompt: "fix it")))
        #expect(log.modes.last == LaunchMode(restoring: true, initialPrompt: nil))
        #expect(!view.isDetached)
        // The status survives the reconnect (no `.relaunched` reset).
        #expect(h.app.state(ofLeaf: l.id) == .working)
    }

    private func kills(_ h: Harness, _ id: UUID) -> Int {
        FakeSSH.calls(h.log).filter { call in
            call.contains { $0.contains("hangar kill-session") && $0.contains("=hangar-\(id.uuidString.lowercased())") }
        }.count
    }

    @Test func closingLeafKillsSession() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let dev = h.leaf("dev")
        let task = h.app.location(ofLeaf: dev.leaf)!.task
        h.app.perform { $0.addTab(taskId: task, kind: .shell) }
        let shell = h.app.state.tasks.first { $0.id == task }!.tabs[1].root.leaves[0].id
        h.app.closeLeaf(shell)
        #expect(await waitUntil { kills(h, shell) == 1 })
        #expect(kills(h, dev.leaf) == 0)
        h.app.archive(taskId: task)
        #expect(await waitUntil { kills(h, dev.leaf) == 1 })
        // A local leaf has no session.
        let local = h.leaf("local")
        h.app.closeLeaf(local.leaf)
        // Quitting keeps the sessions.
        h.app.restore(taskId: task)
        h.remote.stopAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(kills(h, dev.leaf) == 1)
        #expect(kills(h, local.leaf) == 0)
    }

    @Test func quitIgnoresTmuxLeaves() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let tmux = h.bin + "/tmux"
        try "#!/bin/sh\necho 'tmux 3.4'\n".write(toFile: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux)
        try await RemoteHostsTests.run(tmux, ["-V"])
        #expect(await h.remote.connect("dev") == .connected)
        #expect(h.remote.hosts["dev"]?.report?.tmux == true)
        let dev = h.leaf("dev"), local = h.leaf("local")
        h.app.handle(.event(EventMessage(tab: dev.tab, leaf: dev.leaf, kind: .prompt)))
        #expect(h.app.workingLeafCount == 1)
        #expect(h.app.quitWorkingCount == 0)
        h.app.handle(.event(EventMessage(tab: local.tab, leaf: local.leaf, kind: .prompt)))
        #expect(h.app.quitWorkingCount == 1)
        #expect(quitDecision(creating: false, working: h.app.quitWorkingCount, confirmed: false, asking: false, forced: false) == .ask(1))
    }

    @Test func killsWaitForTheHost() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        h.remote.disconnect("dev")
        let dev = h.leaf("dev")
        let task = h.app.location(ofLeaf: dev.leaf)!.task
        h.app.archive(taskId: task)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(kills(h, dev.leaf) == 0)
        // The queue goes out once the host is back (and only once).
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await waitUntil { kills(h, dev.leaf) == 1 })
        h.remote.disconnect("dev")
        #expect(await h.remote.connect("dev") == .connected)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(kills(h, dev.leaf) == 1)
    }

    @Test func lastProjectRemovesHost() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        // The fake's `-O exit` kills the last master started: "other" goes offline before "dev" connects.
        #expect(await h.remote.connect("other") == .connected)
        h.remote.disconnect("other")
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(h.remote.hosts["other"]?.state == .disconnected)
        #expect(await h.remote.connect("dev") == .connected)
        let dev = h.leaf("dev")
        let project = h.app.state.projects.first { $0.name == "dev" }!
        h.app.perform { $0.removeProject(id: project.id) }
        // Sessions first, then the host goes (the kill needs the master).
        #expect(await waitUntil { kills(h, dev.leaf) == 1 && h.remote.hosts["dev"] == nil })
        // An offline host goes at once.
        let other = h.app.state.projects.first { $0.name == "other" }!
        h.app.perform { $0.removeProject(id: other.id) }
        #expect(h.remote.hosts["other"] == nil)
    }

    @Test func gaveUpLeafOffersReconnect() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try h.flag("fail", "refused")
        let dev = h.leaf("dev")
        let view = LeafView(leafId: dev.leaf)
        view.host = "dev"
        view.reconnectText = { [app = h.app] in app.hostReconnectText("dev") }
        var reconnects = 0
        view.onReconnect = { reconnects += 1 }
        h.app.onHostChange = { _ in view.refreshText() }  // as TerminalArea does
        start(view, h, leaf: leaf(h, dev.leaf), tab: dev.tab, context: .created(prompt: nil), into: Launches())
        #expect(view.isWaitingForHost)
        #expect(await waitUntil { if case .unreachable = h.state() { true } else { false } })
        #expect(view.canReconnect)
        #expect(view.barString == L10n.hostGaveUp("dev"))
        view.activateBar()
        #expect(reconnects == 1)
        // Reconnecting: the bar says so again.
        try FileManager.default.removeItem(atPath: h.fakeDir + "/fail")
        h.app.reconnect(host: "dev")
        #expect(await waitUntil { h.state() == .connected })
        #expect(!view.canReconnect)
    }

    @Test func pausedHostLeafIsCalm() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        h.active = false
        h.killMaster()
        #expect(await waitUntil { h.remote.hosts["dev"]?.retryPaused == true })
        let dev = h.leaf("dev")
        let view = LeafView(leafId: dev.leaf)
        h.app.wireHost(view)
        // The launch meets the paused host: no «connecting…», the calm text with the reconnect action.
        start(view, h, leaf: leaf(h, dev.leaf), tab: dev.tab, context: .created(prompt: nil), into: Launches())
        #expect(view.isWaitingForHost)
        #expect(view.canReconnect)
        #expect(view.barString == L10n.hostPausedBar("dev"))
    }

    @Test func reconnectAction() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let dev = h.app.location(ofLeaf: h.leaf("dev").leaf)!.task
        let local = h.app.location(ofLeaf: h.leaf("local").leaf)!.task
        #expect(Action.list(for: .task(dev), app: h.app).contains(.reconnect))
        #expect(!Action.list(for: .task(local), app: h.app).contains(.reconnect))
        #expect(Action.reconnect.isEnabled(for: .task(dev), app: h.app))
        #expect(await h.remote.connect("dev") == .connected)
        #expect(!Action.reconnect.isEnabled(for: .task(dev), app: h.app))
    }
}
