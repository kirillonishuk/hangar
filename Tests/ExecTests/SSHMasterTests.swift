import Foundation
import Testing
@testable import Exec

@Suite struct SSHMasterTests {
    private struct Fake {
        let dir: String, ssh: String, log: String, home: String, cp: String
        func flag(_ name: String, _ text: String = "") throws {
            try text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        func master() -> SSHMaster { SSHMaster(host: "dev", controlPath: cp, sshPath: ssh) }
        func masterPid() -> pid_t? {
            (try? String(contentsOfFile: dir + "/master.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        /// Live processes running this fake (its path is unique per test).
        func liveFakes() async -> Int {
            let r = try? await Runner.local.run(["pgrep", "-f", ssh], "/")
            return (r?.stdout ?? "").split(separator: "\n").count
        }
    }

    private func fake() async throws -> (Fake, () -> Void) {
        let root = NSTemporaryDirectory() + "hangar-sshm-\(UUID().uuidString)"
        let s = try FakeSSH.make(dir: root + "/fake")
        // The first exec of a fresh script is slow on macOS (security scan); time bounds below are about our code.
        _ = try await Runner.local.run([s.path, "-O", "check", "--", "dev"], "/")
        try? FileManager.default.removeItem(atPath: s.log)
        return (Fake(dir: root + "/fake", ssh: s.path, log: s.log, home: s.home, cp: root + "/cm"), { Self.cleanup(root) })
    }

    /// A one-off ssh stand-in (ignores its argv) for stdout/stderr shapes the shared fake cannot produce.
    private func script(_ body: String) async throws -> (SSHMaster, String, () -> Void) {
        let root = NSTemporaryDirectory() + "hangar-sshm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = root + "/ssh"
        try ("#!/bin/sh\n[ \"$1\" = warm ] && exit 0\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        _ = try await Runner.local.run([path, "warm"], "/")
        return (SSHMaster(host: "dev", controlPath: root + "/cm", sshPath: path), root, { Self.cleanup(root) })
    }

    /// Runs in `defer`, so also when a test fails early: SIGKILLs every process started from the fake's folder
    /// (masters, TERM-proof loops), then removes it.
    private static func cleanup(_ root: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-f", root]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Test-only wait for an async side effect (the code under test never polls).
    private func waitUntil(_ seconds: Double, _ cond: () async -> Bool) async -> Bool {
        let clock = SuspendingClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SSHFailure] = []
        func add(_ f: SSHFailure) { lock.lock(); items.append(f); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var first: SSHFailure? { lock.lock(); defer { lock.unlock() }; return items.first }
    }

    @Test func connectReturnsHome() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        let m = f.master()
        defer { m.exit() }
        #expect(await m.connect(timeout: 5) == .success(f.home))
        let call = try #require(FakeSSH.calls(f.log).first)
        #expect(call.contains("-M"))
        #expect(call.contains("ControlPersist=no"))
        #expect(call.contains("BatchMode=yes"))
        #expect(!call.contains("-f"))
        let dd = try #require(call.firstIndex(of: "--"))
        #expect(call[dd + 1] == "dev")
        #expect(zip(call, call.dropFirst()).contains { $0 == ("-S", f.cp) })
    }

    @Test func authFailureClassified() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        try f.flag("fail", "auth")
        let m = f.master()
        let lost = Counter()
        m.onExit = { lost.add($0) }
        // A long connect timeout: the failure must come from ssh's exit, not the deadline. SuspendingClock: load and sleep safe.
        let clock = SuspendingClock(), start = clock.now
        #expect(await m.connect(timeout: 600) == .failure(.auth("Permission denied (publickey).")))
        #expect(clock.now - start < .seconds(20))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lost.count == 0)
    }

    @Test func connectTimeout() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        try f.flag("hang")
        let m = f.master()
        // The fake hangs 300 s, so finishing well before that proves the deadline fired.
        let clock = SuspendingClock(), start = clock.now
        #expect(await m.connect(timeout: 0.5) == .failure(.unreachable("timed out")))
        #expect(clock.now - start < .seconds(20))
        #expect(await waitUntil(20) { await f.liveFakes() == 0 })
    }

    @Test func deathFiresOnExitOnce() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        let m = f.master()
        let lost = Counter()
        m.onExit = { lost.add($0) }
        #expect(await m.connect(timeout: 5) == .success(f.home))
        let pid = try #require(f.masterPid())
        kill(pid, SIGKILL)
        #expect(await waitUntil(2) { lost.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(lost.count == 1)

        let m2 = f.master()
        let lost2 = Counter()
        m2.onExit = { lost2.add($0) }
        #expect(await m2.connect(timeout: 5) == .success(f.home))
        m2.exit()
        #expect(await waitUntil(2) { FakeSSH.calls(f.log).contains { zip($0, $0.dropFirst()).contains { $0 == ("-O", "exit") } } })
        #expect(await waitUntil(3) { await f.liveFakes() == 0 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(lost2.count == 0)
    }

    @Test func forwardLinksSocket() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        let m = f.master()
        defer { m.exit() }
        guard case .success(let home) = await m.connect(timeout: 5) else { Issue.record("connect"); return }
        let remote = home + "/.hangar/hangar.sock", local = f.dir + "/x.sock"
        try FileManager.default.createDirectory(atPath: home + "/.hangar", withIntermediateDirectories: true)
        try "stale".write(toFile: remote, atomically: true, encoding: .utf8)
        #expect(await m.forward(remote: remote, local: local))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home + "/.hangar/run", isDirectory: &isDir) && isDir.boolValue)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: remote)) == local)
        let calls = FakeSSH.calls(f.log)
        let rm = try #require(calls.firstIndex { $0.contains { $0.contains("rm -f") } })
        let fwd = try #require(calls.firstIndex { zip($0, $0.dropFirst()).contains { $0 == ("-O", "forward") } })
        #expect(rm < fwd)
        #expect(calls[fwd].contains(remote + ":" + local))
    }

    @Test func probeTimesOut() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        let m = f.master()
        defer { m.exit() }
        #expect(await m.connect(timeout: 5) == .success(f.home))
        #expect(await m.probe(timeout: 30))  // returns at once; generous for a loaded run
        try f.flag("hang")
        let clock = SuspendingClock(), start = clock.now
        #expect(await !m.probe(timeout: 0.3))
        #expect(clock.now - start < .seconds(20))  // the fake hangs 300 s
    }

    /// `exit()` while `connect` still waits for the old master to go: the new child must not be left running.
    @Test func exitDuringReconnectStopsNewChild() async throws {
        // A master that ignores SIGTERM, so the old one takes ~2 s (the SIGKILL escalation) to go.
        let (m, root, cleanup) = try await script("""
        case " $* " in *" -O "*) exit 0 ;; esac
        echo $$ >> "$(dirname "$0")/pids"
        trap '' TERM
        printf 'HANGAR-READY /h\\n'
        i=0; while [ $i -lt 300 ]; do sleep 1; i=$((i + 1)); done
        """)
        defer { cleanup() }
        #expect(await m.connect(timeout: 30) == .success("/h"))
        let again = Task { await m.connect(timeout: 30) }
        try await Task.sleep(nanoseconds: 500_000_000)  // inside the wait for the old master
        m.exit()
        guard case .failure = await again.value else { Issue.record("reconnect after exit() succeeded"); return }
        let pids = ((try? String(contentsOfFile: root + "/pids", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        #expect(await waitUntil(20) { pids.allSatisfy { kill($0, 0) != 0 } })
    }

    @Test func readyLineValidated() {
        #expect(readyHome("HANGAR-READY /home/u") == "/home/u")
        #expect(readyHome("HANGAR-READY /home/a b/привет") == "/home/a b/привет")
        for bad in ["HANGAR-READY relative", "HANGAR-READY ", "HANGAR-READY /a\u{1b}[2J", "HANGAR-READY /a\rb",
                    "HANGAR-READY /" + String(repeating: "a", count: 1024), "hello", "XHANGAR-READY /a"] {
            #expect(readyHome(Substring(bad)) == nil, "\(bad)")
        }
    }

    @Test func failureClassified() {
        #expect(sshFailure(status: 255, stderr: "Host key verification failed.\n") == .auth("Host key verification failed."))
        #expect(sshFailure(status: 255, stderr: "Enter passphrase for key:\n") == .auth("Enter passphrase for key:"))
        #expect(sshFailure(status: 255, stderr: "ssh: Could not resolve hostname x: nodename\n\n") == .unreachable("ssh: Could not resolve hostname x: nodename"))
        #expect(sshFailure(status: 255, stderr: "ssh: connect to host x port 22: No route to host") == .unreachable("ssh: connect to host x port 22: No route to host"))
        #expect(sshFailure(status: 255, stderr: "warn\nConnection to x closed by remote host.\n") == .exited(255, "Connection to x closed by remote host."))
        if case .exited(_, let s) = sshFailure(status: 1, stderr: String(repeating: "z", count: 500)) { #expect(s.count == 300) }
        else { Issue.record("not exited") }
    }

    @Test func markerSplitAndNoiseBeforeIt() async throws {
        let (m, _, cleanup) = try await script("""
        echo 'Welcome to box'; echo 'rc: HANGAR-READY /no'; echo '  HANGAR-READY /indented'
        printf 'HANGAR-REA'; sleep 0.2; printf 'DY /srv/u\\n'; exec cat >/dev/null
        """)
        defer { cleanup(); m.exit() }
        #expect(await m.connect(timeout: 5) == .success("/srv/u"))
    }

    @Test func preReadyStderrDoesNotClassifyLaterDrop() async throws {
        let (m, _, cleanup) = try await script("""
        echo 'Banner: never type your passphrase here' >&2
        echo 'bash: /etc/profile.d/x.sh: Permission denied' >&2
        printf 'HANGAR-READY /h\\n'; sleep 0.3
        echo 'client_loop: send disconnect: Broken pipe' >&2; exit 255
        """)
        defer { cleanup() }
        let lost = Counter()
        m.onExit = { lost.add($0) }
        #expect(await m.connect(timeout: 5) == .success("/h"))
        #expect(await waitUntil(3) { lost.count == 1 })
        #expect(lost.first == .unreachable("client_loop: send disconnect: Broken pipe"))
    }

    @Test func reconnectWaitsForOldMaster() async throws {
        // Ignores SIGTERM: only the SIGKILL fallback ends it.
        let (m, root, cleanup) = try await script("""
        if [ -f "$(dirname "$0")/second" ]; then printf 'HANGAR-READY /two\\n'; exec cat >/dev/null; fi
        trap '' TERM; echo $$ > "$(dirname "$0")/old.pid"
        printf 'HANGAR-READY /one\\n'; i=0; while [ $i -lt 3000 ]; do sleep 0.1; i=$((i + 1)); done
        """)
        defer { cleanup(); m.exit() }
        #expect(await m.connect(timeout: 5) == .success("/one"))
        let old = try #require(pid_t((try String(contentsOfFile: root + "/old.pid", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        try "".write(toFile: root + "/second", atomically: true, encoding: .utf8)
        let clock = SuspendingClock(), start = clock.now
        #expect(await m.connect(timeout: 10) == .success("/two"))
        #expect(clock.now - start < .seconds(20))  // waits for the old master, bounded by its 3 s SIGKILL wait
        #expect(kill(old, 0) != 0)
    }

    @Test func diagnosticsNotSubstrings() {
        #expect(sshFailure(status: 255, stderr: "kirill@box: Permission denied (publickey).\n") == .auth("kirill@box: Permission denied (publickey)."))
        #expect(sshFailure(status: 255, stderr: "bash: /x: Permission denied\nConnection to x closed.\n") == .exited(255, "Connection to x closed."))
        #expect(sshFailure(status: 255, stderr: "motd: the build timed out\nx\n") == .exited(255, "x"))
        #expect(sshFailure(status: 255, stderr: "Timeout, server box not responding.\n") == .unreachable("Timeout, server box not responding."))
    }

    /// Real OpenSSH stderr lines, plus look-alikes from other programs.
    @Test func openSSHLines() {
        let table: [(String, SSHFailure)] = [
            ("kirill@box: Permission denied (publickey).", .auth("kirill@box: Permission denied (publickey).")),
            ("deploy@10.0.0.5: Permission denied (publickey,password,keyboard-interactive).",
             .auth("deploy@10.0.0.5: Permission denied (publickey,password,keyboard-interactive).")),
            ("Permission denied (publickey,gssapi-keyex,gssapi-with-mic).", .auth("Permission denied (publickey,gssapi-keyex,gssapi-with-mic).")),
            ("Error: Permission denied (os error 13)", .exited(255, "Error: Permission denied (os error 13)")),
            ("cat: x: Permission denied (publickey). extra", .exited(255, "cat: x: Permission denied (publickey). extra")),
            ("ssh: connect to host box port 22: Network is unreachable", .unreachable("ssh: connect to host box port 22: Network is unreachable")),
            ("ssh: connect to host box port 22: Connection refused", .unreachable("ssh: connect to host box port 22: Connection refused")),
            ("ssh: connect to host box port 22: Operation timed out", .unreachable("ssh: connect to host box port 22: Operation timed out")),
            ("Connection closed by 10.0.0.5 port 22", .unreachable("Connection closed by 10.0.0.5 port 22")),
            ("Connection reset by 10.0.0.5 port 22", .unreachable("Connection reset by 10.0.0.5 port 22")),
            ("kex_exchange_identification: read: Connection reset by peer", .unreachable("kex_exchange_identification: read: Connection reset by peer")),
            ("kex_exchange_identification: Connection closed by remote host", .unreachable("kex_exchange_identification: Connection closed by remote host")),
            ("packet_write_wait: Connection to 10.0.0.5 port 22: Broken pipe", .unreachable("packet_write_wait: Connection to 10.0.0.5 port 22: Broken pipe")),
            ("client_loop: send disconnect: Broken pipe", .unreachable("client_loop: send disconnect: Broken pipe")),
            ("Connection to box closed by remote host.", .exited(255, "Connection to box closed by remote host.")),
        ]
        for (line, want) in table {
            #expect(sshFailure(status: 255, stderr: line + "\n") == want, "\(line)")
        }
    }
}
