import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// RemoteHosts against the fake ssh only (never a real host); `schedule` stores bodies, the test runs them.
@MainActor @Suite struct RemoteHostsTests {
    @MainActor final class Harness {
        let root: String, ssh: String, log: String, home: String, fakeDir: String
        let app: AppState
        var active = true
        var scheduled: [(delay: Duration, body: @MainActor () -> Void)] = []
        var connected: [String] = [], lost: [String] = []

        init() async throws {
            // Short root: the master and host sockets must fit sun_path without the shared /tmp/hangar-<uid> fallback.
            root = "/tmp/hr-" + UUID().uuidString.prefix(8)
            fakeDir = root + "/fake"
            let f = try FakeSSH.make(dir: fakeDir)
            log = f.log; home = f.home
            let bin = root + "/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            // A "login shell" that skips /etc/profile (path_helper would put Homebrew first) and a system PATH:
            // the server check never starts a tool of this Mac outside /usr/bin, /bin and the test's own bin.
            let login = bin + "/login-sh"
            try "#!/bin/sh\nshift 3\nexec /bin/sh -c \"$1\"\n".write(toFile: login, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: login)
            ssh = root + "/ssh-wrapper"
            try "#!/bin/sh\nexport SHELL=\(shellQuote(login)) PATH=\(shellQuote(bin)):/usr/bin:/bin\nexec \(shellQuote(f.path)) \"$@\"\n"
                .write(toFile: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
            // The first exec of a fresh script is slow on macOS (security scan).
            let warm = Process()
            warm.executableURL = URL(fileURLWithPath: ssh)
            warm.arguments = ["-O", "check", "--", "dev"]
            try warm.run()
            warm.waitUntilExit()
            try? FileManager.default.removeItem(atPath: log)

            var s = WorkspaceState()
            for (name, host) in [("local", nil), ("dev", "dev"), ("other", "other")] as [(String, String?)] {
                let p = host.map { s.addRemoteProject(name: name, host: $0, path: "/srv/app") } ?? s.addProject(name: name, path: "/tmp")
                let t = s.addTask(projectId: p, name: name)
                s.addTab(taskId: t, kind: .claude)
            }
            let dir = URL(fileURLWithPath: root + "/state")
            app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: root + "/hangar.sock")
            app.codexRead = nil
            app.keepAwake = .inert()
            app.remote = app.makeRemoteHosts(paths: SSHPaths(stateDir: root), sshPath: ssh,
                                             schedule: { [weak self] d, body in self?.scheduled.append((d, body)); return {} },
                                             isActive: { [weak self] in self?.active ?? false })
            app.remote.onConnected = { [weak self] in self?.connected.append($0) }
            app.remote.onLost = { [weak self] in self?.lost.append($0) }
        }

        var remote: RemoteHosts { app.remote }
        func state(_ host: String = "dev") -> HostState? { remote.hosts[host]?.state }

        func cleanup() {
            remote.stopAll()
            try? FileManager.default.removeItem(atPath: root)
        }

        func flag(_ name: String, _ text: String = "") throws {
            try text.write(toFile: fakeDir + "/" + name, atomically: true, encoding: .utf8)
        }

        /// The only leaf of the project named `name`.
        func leaf(_ name: String) -> (tab: UUID, leaf: UUID) {
            let p = app.state.projects.first { $0.name == name }!
            let tab = app.state.tasks.first { $0.projectId == p.id }!.tabs[0]
            return (tab.id, tab.root.leaves[0].id)
        }

        func masterCalls() -> Int { FakeSSH.calls(log).filter { $0.contains("-M") }.count }

        func killMaster() {
            let pid = (try? String(contentsOfFile: fakeDir + "/master.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let pid { kill(pid, SIGKILL) }
        }

        /// Runs `hangar-remote` as a process on the "server" would: the leaf's env, the forwarded socket.
        func hangarRemote(_ args: [String], leaf: (tab: UUID, leaf: UUID), stdin: String) throws {
            let script = root + "/hangar-remote"
            if !FileManager.default.fileExists(atPath: script) {
                try hangarRemoteScript.write(toFile: script, atomically: true, encoding: .utf8)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script] + args
            p.environment = ["HANGAR_TAB_ID": leaf.tab.uuidString, "HANGAR_LEAF_ID": leaf.leaf.uuidString,
                             "HANGAR_SOCKET": home + "/.hangar/hangar.sock", "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            // A child exiting before it reads stdin must not SIGPIPE the test process.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try p.run()
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
        }
    }

    /// Test-only wait for an async side effect (the code under test never polls).
    private func waitUntil(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    @Test func connectSequence() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        async let a = h.remote.connect("dev")
        async let b = h.remote.connect("dev")
        let (sa, sb) = await (a, b)
        #expect(sa == .connected && sb == .connected)
        let info = try #require(h.remote.hosts["dev"])
        #expect(info.home == h.home)
        #expect(info.report != nil)
        #expect(info.forwarding)
        let hostSocket = SSHPaths(stateDir: h.root).hostSocket("dev")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: h.home + "/.hangar/hangar.sock")) == hostSocket)
        #expect(h.connected == ["dev"])
        #expect(h.masterCalls() == 1)
        let t = try #require(h.remote.target("dev"))
        #expect(t.home == h.home && t.controlPath == SSHPaths(stateDir: h.root).controlPath("dev") && t.sshPath == h.ssh)
    }

    @Test func eventForForeignLeafIgnored() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let local = h.leaf("local"), other = h.leaf("other"), dev = h.leaf("dev")
        try h.hangarRemote(["event", "prompt"], leaf: local, stdin: "{}")
        try h.hangarRemote(["event", "prompt"], leaf: other, stdin: "{}")
        try h.hangarRemote(["event", "prompt"], leaf: dev, stdin: "{}")
        #expect(await waitUntil { h.app.state(ofLeaf: dev.leaf) == .working })
        #expect(h.app.state(ofLeaf: local.leaf) == .idle)
        #expect(h.app.state(ofLeaf: other.leaf) == .idle)

        let resets = Int(Date().timeIntervalSince1970) + 3600
        try h.hangarRemote(["statusline"], leaf: dev, stdin: #"{"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":\#(resets)}}}"#)
        #expect(await waitUntil { h.app.usage.view(.claude, now: Date()) != nil })
    }

    @Test func lossKeepsStatusesThenReconnects() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let dev = h.leaf("dev")
        h.app.handle(.event(EventMessage(tab: dev.tab, leaf: dev.leaf, kind: .prompt)))
        h.killMaster()
        #expect(await waitUntil { h.lost == ["dev"] })
        #expect(h.app.state(ofLeaf: dev.leaf) == .working)
        #expect(h.state() == .reconnecting(attempt: 1))
        #expect(h.scheduled.map(\.delay) == [.seconds(2)])
        guard h.scheduled.count == 1 else { return }
        h.scheduled[0].body()
        #expect(await waitUntil { h.state() == .connected })
        #expect(h.connected == ["dev", "dev"])
        #expect(h.app.state(ofLeaf: dev.leaf) == .working)
    }

    @Test func noBackoffWhileInactiveIdle() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.active = false
        #expect(await h.remote.connect("dev") == .connected)
        h.killMaster()
        #expect(await waitUntil { h.lost == ["dev"] })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.scheduled.isEmpty)
        #expect(h.masterCalls() == 1)
        h.active = true
        h.remote.appBecameActive()
        #expect(await waitUntil { h.state() == .connected })
        #expect(h.masterCalls() == 2)
        #expect(h.scheduled.isEmpty)
    }

    @Test func givesUpAfterTenAttempts() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let dev = h.leaf("dev")
        h.app.handle(.event(EventMessage(tab: dev.tab, leaf: dev.leaf, kind: .prompt)))
        try h.flag("fail", "refused")
        h.killMaster()
        for i in 0..<10 {
            #expect(await waitUntil { h.scheduled.count == i + 1 }, "attempt \(i + 1)")
            guard h.scheduled.count == i + 1 else { return }
            h.scheduled[i].body()
        }
        #expect(await waitUntil { if case .unreachable = h.state() { true } else { false } })
        #expect(h.scheduled.map(\.delay) == [2, 4, 8, 16, 32, 60, 60, 60, 60, 60].map { Duration.seconds($0) })
        #expect(h.masterCalls() == 11)
        #expect(h.app.state(ofLeaf: dev.leaf) == .idle)
    }

    @Test func authFailureNoRetry() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try h.flag("fail", "auth")
        guard case .unreachable = await h.remote.connect("dev") else { Issue.record("not unreachable"); return }
        #expect(h.remote.hosts["dev"]?.authFailed == true)
        #expect(h.scheduled.isEmpty)

        // A reconnect that meets an auth failure stops too.
        try FileManager.default.removeItem(atPath: h.fakeDir + "/fail")
        #expect(await h.remote.connect("dev") == .connected)
        #expect(h.remote.hosts["dev"]?.authFailed == false)
        try h.flag("fail", "auth")
        h.killMaster()
        #expect(await waitUntil { h.scheduled.count == 1 })
        guard h.scheduled.count == 1 else { return }
        h.scheduled[0].body()
        #expect(await waitUntil { h.remote.hosts["dev"]?.authFailed == true })
        guard case .unreachable = h.state() else { Issue.record("not unreachable"); return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.scheduled.count == 1)
    }

    @Test func wakeProbeDropsDeadLink() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        h.remote.probeTimeout = 0.3
        try h.flag("hang")
        defer { try? FileManager.default.removeItem(atPath: h.fakeDir + "/hang") }
        h.remote.didWake()
        #expect(await waitUntil(5) { h.lost == ["dev"] })
        #expect(h.state() == .reconnecting(attempt: 1))
    }

    @Test func stopAllExitsMasters() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await h.remote.connect("other") == .connected)
        let paths = SSHPaths(stateDir: h.root)
        #expect(FileManager.default.fileExists(atPath: paths.hostSocket("dev")))
        h.remote.stopAll()
        // Two concurrent fake calls may interleave their log lines, so count the `exit` lines instead of parsing calls.
        #expect(await waitUntil {
            let lines = ((try? String(contentsOfFile: h.log, encoding: .utf8)) ?? "").split(separator: "\n")
            return lines.filter { $0 == "exit" }.count == 2 && lines.contains("other")
        })
        #expect(!FileManager.default.fileExists(atPath: paths.hostSocket("dev")))
        #expect(!FileManager.default.fileExists(atPath: paths.hostSocket("other")))
        #expect(h.state() == .disconnected && h.state("other") == .disconnected)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.lost.isEmpty)
    }

    @Test func runnerFailsFastWhileDisconnected() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        await #expect(throws: RemoteHostError.notConnected("dev")) { try await h.remote.runner("dev").run(["true"], "") }
        #expect(FakeSSH.calls(h.log).isEmpty)
        #expect(await h.remote.connect("dev") == .connected)
        #expect(try await h.remote.runner("dev").run(["true"], "").status == 0)
    }

    @Test func hangingCheckTimesOut() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let tmux = h.root + "/bin/tmux"
        try "#!/bin/sh\nexec sleep 30\n".write(toFile: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux)
        h.remote.checkTimeout = 0.5
        // Without the deadline the check would finish after the fake's 30 s and the host would connect.
        #expect(await h.remote.connect("dev") == .unreachable("server check timed out"))
        #expect(h.connected.isEmpty)
    }
}
