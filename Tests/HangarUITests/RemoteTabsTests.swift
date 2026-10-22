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
            call.contains { $0.contains("kill-session") && $0.contains("=hangar-\(id.uuidString.lowercased())") }
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
        #expect(quitDecision(creating: false, working: h.app.quitWorkingCount, confirmed: false, asking: false, systemShutdown: false) == .ask(1))
    }
}
