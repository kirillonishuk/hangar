import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// RemoteHosts against the fake ssh only (never a real host); `schedule` stores bodies, the test runs them.
@MainActor @Suite struct RemoteHostsTests {
    /// Blocking work (spawning, `waitUntilExit`) on a GCD thread: a blocked main actor stalls every other suite.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result { try work() }) } }
    }

    /// Runs and waits for a process off main; stdin (if any) is in the pipe before launch.
    nonisolated static func run(_ path: String, _ args: [String], env: [String: String]? = nil, stdin: String? = nil) async throws {
        try await offMain {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let env { p.environment = env }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if let stdin {
                let input = Pipe()
                // A child exiting before it reads stdin must not SIGPIPE the test process.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))  // small: fits the pipe buffer
                try input.fileHandleForWriting.close()
                p.standardInput = input
            } else {
                p.standardInput = FileHandle.nullDevice
            }
            try p.run()
            p.waitUntilExit()
        }
    }

    @MainActor final class Harness {
        let root: String, ssh: String, log: String, home: String, fakeDir: String, bin: String
        let app: AppState
        var active = true
        var scheduled: [(delay: Duration, body: @MainActor () -> Void)] = []
        var connected: [String] = [], lost: [String] = [], unreachable: [String] = []
        private var seen: [String: HostState] = [:]

        init() async throws {
            // Short root: the master and host sockets must fit sun_path without the shared /tmp/hangar-<uid> fallback.
            let root = "/tmp/hr-" + UUID().uuidString.prefix(8)
            self.root = root
            fakeDir = root + "/fake"
            bin = root + "/bin"
            ssh = root + "/ssh-wrapper"
            let (fakeDir, bin, ssh) = (fakeDir, bin, ssh)
            let f = try await RemoteHostsTests.offMain { () -> (path: String, log: String, home: String) in
                let f = try FakeSSH.make(dir: fakeDir)
                try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
                // A "login shell" that skips /etc/profile (path_helper would put Homebrew first) and a system PATH:
                // the server check never starts a tool of this Mac outside /usr/bin, /bin and the test's own bin.
                // `<root>/shell`, if present, names another login shell (the csh test).
                let login = bin + "/login-sh"
                try "#!/bin/sh\nshift 3\nexec /bin/sh -c \"$1\"\n".write(toFile: login, atomically: true, encoding: .utf8)
                try "#!/bin/sh\nexit 0\n".write(toFile: bin + "/tcsh", atomically: true, encoding: .utf8)
                let wrapper = "#!/bin/sh\nSHELL=\(shellQuote(login))\n[ -f \(shellQuote(root + "/shell")) ] && SHELL=$(cat \(shellQuote(root + "/shell")))\n"
                    + "export SHELL PATH=\(shellQuote(bin)):/usr/bin:/bin\nexec \(shellQuote(f.path)) \"$@\"\n"
                try wrapper.write(toFile: ssh, atomically: true, encoding: .utf8)
                for x in [login, bin + "/tcsh", ssh] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: x) }
                return f
            }
            log = f.log; home = f.home
            // The first exec of a fresh script is slow on macOS (security scan).
            try await RemoteHostsTests.run(ssh, ["-O", "check", "--", "dev"])
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
            let wiredConnected = app.remote.onConnected
            app.remote.onConnected = { [weak self] in self?.connected.append($0); wiredConnected?($0) }
            // A loss = a host leaving `.connected` for anything but a user/quit `.disconnected`.
            let wiredChange = app.remote.onChange
            app.remote.onChange = { [weak self] host in
                if let self {
                    let now = remote.hosts[host]?.state
                    if seen[host] == .connected, let now, now != .connected, now != .disconnected { lost.append(host) }
                    seen[host] = now
                }
                wiredChange?(host)
            }
            // Under parallel load the check (a dozen processes) can take far longer than in the app.
            app.remote.checkTimeout = 120
            let wired = app.remote.onUnreachable
            app.remote.onUnreachable = { [weak self] in self?.unreachable.append($0); wired?($0) }
        }

        var remote: RemoteHosts { app.remote }
        func state(_ host: String = "dev") -> HostState? { remote.hosts[host]?.state }

        func cleanup() {
            remote.stopAll()
            // A hanging fake tool records its pid: no stray process outlives the test.
            if let pid = pid("tool.pid") { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: root)
        }

        func flag(_ name: String, _ text: String = "") throws {
            try text.write(toFile: fakeDir + "/" + name, atomically: true, encoding: .utf8)
        }

        /// A pid written by a fake (relative to the fake dir, or absolute).
        func pid(_ file: String) -> pid_t? {
            let path = file.hasPrefix("/") ? file : (file == "tool.pid" ? root + "/" + file : fakeDir + "/" + file)
            return (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

        /// A `git` (the check's first tool) whose `--version` hangs, so the check does; its pid → `<root>/tool.pid`.
        func hangingGit() async throws {
            let git = bin + "/git"
            try "#!/bin/sh\n[ \"$1\" = warm ] && exit 0\necho $$ > \(shellQuote(root + "/tool.pid"))\nexec sleep 300\n"
                .write(toFile: git, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git)
            // The first exec of a fresh script is slow on macOS (security scan): it would outlast the check deadline.
            try await RemoteHostsTests.run(git, ["warm"])
        }

        /// The only leaf of the project named `name`.
        func leaf(_ name: String) -> (tab: UUID, leaf: UUID) {
            let p = app.state.projects.first { $0.name == name }!
            let tab = app.state.tasks.first { $0.projectId == p.id }!.tabs[0]
            return (tab.id, tab.root.leaves[0].id)
        }

        func masterCalls() -> Int { FakeSSH.calls(log).filter { $0.contains("-M") }.count }

        func killMaster() {
            if let pid = pid("master.pid") { kill(pid, SIGKILL) }
        }

        /// Runs `hangar-remote` as a process on the "server" would: the leaf's env, the forwarded socket.
        func hangarRemote(_ args: [String], leaf: (tab: UUID, leaf: UUID), stdin: String) async throws {
            let script = root + "/hangar-remote"
            if !FileManager.default.fileExists(atPath: script) {
                try hangarRemoteScript.write(toFile: script, atomically: true, encoding: .utf8)
            }
            try await RemoteHostsTests.run("/bin/sh", [script] + args,
                                           env: ["HANGAR_TAB_ID": leaf.tab.uuidString, "HANGAR_LEAF_ID": leaf.leaf.uuidString,
                                                 "HANGAR_SOCKET": home + "/.hangar/hangar.sock", "PATH": "/usr/bin:/bin"],
                                           stdin: stdin)
        }
    }

    /// Test-only wait for an async side effect (the code under test never polls); SuspendingClock survives Mac sleep.
    private func waitUntil(_ seconds: Double = 30, _ cond: () -> Bool) async -> Bool {
        let clock = SuspendingClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
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
        try await h.hangarRemote(["event", "prompt"], leaf: local, stdin: "{}")
        try await h.hangarRemote(["event", "prompt"], leaf: other, stdin: "{}")
        try await h.hangarRemote(["event", "prompt"], leaf: dev, stdin: "{}")
        #expect(await waitUntil { h.app.state(ofLeaf: dev.leaf) == .working })
        #expect(h.app.state(ofLeaf: local.leaf) == .idle)
        #expect(h.app.state(ofLeaf: other.leaf) == .idle)

        let resets = Int(Date().timeIntervalSince1970) + 3600
        try await h.hangarRemote(["statusline"], leaf: dev, stdin: #"{"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":\#(resets)}}}"#)
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
        #expect(await waitUntil { h.lost == ["dev"] })  // the fake hangs 300 s
        #expect(h.state() == .reconnecting(attempt: 1))
    }

    @Test func stopAllExitsMasters() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await h.remote.connect("other") == .connected)
        let masters = try ["dev", "other"].map { try #require(h.pid("master-\($0).pid")) }
        #expect(masters.allSatisfy(h.alive))
        let paths = SSHPaths(stateDir: h.root)
        #expect(FileManager.default.fileExists(atPath: paths.hostSocket("dev")))
        h.remote.stopAll()
        #expect(await waitUntil { !masters.contains(where: h.alive) })
        // The `-O exit` helpers run after the masters got SIGTERM. Concurrent fake calls may interleave their log
        // lines, so count the `exit` lines instead of parsing calls.
        #expect(await waitUntil {
            ((try? String(contentsOfFile: h.log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "exit" }.count == 2
        })
        #expect(!FileManager.default.fileExists(atPath: paths.hostSocket("dev")))
        #expect(!FileManager.default.fileExists(atPath: paths.hostSocket("other")))
        #expect(h.state() == .disconnected && h.state("other") == .disconnected)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.lost.isEmpty)
    }

    /// Task 9 removes a host whose last project went away: master gone, entries dropped, safe to repeat.
    @Test func removeDropsHost() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let master = try #require(h.pid("master-dev.pid"))
        h.remote.remove("dev")
        #expect(h.remote.hosts["dev"] == nil)
        #expect(!FileManager.default.fileExists(atPath: SSHPaths(stateDir: h.root).hostSocket("dev")))
        #expect(await waitUntil { !h.alive(master) })
        h.remote.remove("dev")
        h.remote.remove("never-seen")
        #expect(h.remote.hosts.isEmpty)
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
        try await h.hangingGit()
        h.remote.checkTimeout = 10  // reaches the tool under load, far below the 300 s hang
        // Without the deadline the check would wait for the fake's 300 s and the host would connect.
        #expect(await h.remote.connect("dev") == .unreachable("server check timed out"))
        #expect(h.connected.isEmpty)
        // The kill reaches the hanging tool too (SIGKILL escalation after 2 s).
        let tool = try #require(h.pid("tool.pid"))
        #expect(await waitUntil { !h.alive(tool) })
    }

    /// The UI's connect right after activation must join the activation attempt, not start a second one.
    @Test func activationAttemptSharedWithConnect() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.active = false
        #expect(await h.remote.connect("dev") == .connected)
        h.killMaster()
        #expect(await waitUntil { h.lost == ["dev"] })
        h.active = true
        h.remote.appBecameActive()
        #expect(await h.remote.connect("dev") == .connected)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(h.masterCalls() == 2)
        #expect(h.state() == .connected)
        #expect(h.unreachable.isEmpty)
        #expect(h.connected == ["dev", "dev"])
    }

    /// An attempt started and cancelled in the same main-actor turn (before its body runs) must not connect.
    @Test func disconnectBeforeAttemptBodyRuns() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.active = false
        #expect(await h.remote.connect("dev") == .connected)
        h.killMaster()
        #expect(await waitUntil { h.lost == ["dev"] })
        h.active = true
        h.remote.appBecameActive()  // starts the attempt synchronously
        h.remote.disconnect("dev")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(h.state() == .disconnected)
        #expect(h.masterCalls() == 1)
        #expect(h.connected == ["dev"])
    }

    /// remove, then the host comes back at once: the old `-O exit` must not stop the new master.
    @Test func removeThenReconnectKeepsNewMaster() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        h.remote.remove("dev")
        #expect(await h.remote.connect("dev") == .connected)
        let master = try #require(h.pid("master-dev.pid"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(h.alive(master))
        #expect(try await h.remote.runner("dev").run(["true"], "").status == 0)
    }

    /// Disconnect while the check runs: the old attempt stops; a connect right away starts fresh, and the old
    /// attempt finishing later must not touch the new master.
    @Test func disconnectDuringConnect() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await h.hangingGit()
        h.remote.checkTimeout = 10  // the old attempt ends when it fires
        let first = Task { await h.remote.connect("dev") }
        #expect(await waitUntil { h.pid("tool.pid") != nil })
        h.remote.disconnect("dev")
        #expect(h.state() == .disconnected)
        try FileManager.default.removeItem(atPath: h.bin + "/git")
        #expect(await h.remote.connect("dev") == .connected)
        let master = try #require(h.pid("master-dev.pid"))
        _ = await first.value  // the old check times out and returns
        #expect(h.state() == .connected)
        #expect(h.alive(master))
        #expect(h.connected == ["dev"])
        #expect(h.unreachable.isEmpty)
        #expect(try await h.remote.runner("dev").run(["true"], "").status == 0)
    }

    @Test func unsupportedShellNoRetry() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let shellFile = h.root + "/shell"
        try (h.bin + "/tcsh").write(toFile: shellFile, atomically: true, encoding: .utf8)
        #expect(await h.remote.connect("dev") == .unreachable("unsupported login shell: \(h.bin)/tcsh"))
        #expect(h.scheduled.isEmpty)

        try FileManager.default.removeItem(atPath: shellFile)
        #expect(await h.remote.connect("dev") == .connected)
        try (h.bin + "/tcsh").write(toFile: shellFile, atomically: true, encoding: .utf8)
        h.killMaster()
        #expect(await waitUntil { h.scheduled.count == 1 })
        guard h.scheduled.count == 1 else { return }
        h.scheduled[0].body()
        #expect(await waitUntil { h.state() == .unreachable("unsupported login shell: \(h.bin)/tcsh") })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(h.scheduled.count == 1)
    }
}
