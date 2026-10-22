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
        return (Fake(dir: root + "/fake", ssh: s.path, log: s.log, home: s.home, cp: root + "/cm"),
                { try? FileManager.default.removeItem(atPath: root) })
    }

    /// A one-off ssh stand-in (ignores its argv) for stdout/stderr shapes the shared fake cannot produce.
    private func script(_ body: String) async throws -> (SSHMaster, String, () -> Void) {
        let root = NSTemporaryDirectory() + "hangar-sshm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = root + "/ssh"
        try ("#!/bin/sh\n[ \"$1\" = warm ] && exit 0\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        _ = try await Runner.local.run([path, "warm"], "/")
        return (SSHMaster(host: "dev", controlPath: root + "/cm", sshPath: path), root,
                { try? FileManager.default.removeItem(atPath: root) })
    }

    /// Test-only wait for an async side effect (the code under test never polls).
    private func waitUntil(_ seconds: Double, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
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
        let start = Date()
        #expect(await m.connect(timeout: 5) == .failure(.auth("Permission denied (publickey).")))
        #expect(Date().timeIntervalSince(start) < 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lost.count == 0)
    }

    @Test func connectTimeout() async throws {
        let (f, cleanup) = try await fake(); defer { cleanup() }
        try f.flag("hang")
        let m = f.master()
        let start = Date()
        #expect(await m.connect(timeout: 0.5) == .failure(.unreachable("timed out")))
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(await waitUntil(3) { await f.liveFakes() == 0 })
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
        #expect(await m.probe(timeout: 5))
        try f.flag("hang")
        let start = Date()
        #expect(await !m.probe(timeout: 0.3))
        #expect(Date().timeIntervalSince(start) < 1)
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
        printf 'HANGAR-READY /one\\n'; while :; do sleep 0.1; done
        """)
        defer { cleanup(); m.exit() }
        #expect(await m.connect(timeout: 5) == .success("/one"))
        let old = try #require(pid_t((try String(contentsOfFile: root + "/old.pid", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        try "".write(toFile: root + "/second", atomically: true, encoding: .utf8)
        let start = Date()
        #expect(await m.connect(timeout: 10) == .success("/two"))
        #expect(Date().timeIntervalSince(start) < 6)
        #expect(kill(old, 0) != 0)
    }

    @Test func diagnosticsNotSubstrings() {
        #expect(sshFailure(status: 255, stderr: "kirill@box: Permission denied (publickey).\n") == .auth("kirill@box: Permission denied (publickey)."))
        #expect(sshFailure(status: 255, stderr: "bash: /x: Permission denied\nConnection to x closed.\n") == .exited(255, "Connection to x closed."))
        #expect(sshFailure(status: 255, stderr: "motd: the build timed out\nx\n") == .exited(255, "x"))
        #expect(sshFailure(status: 255, stderr: "Timeout, server box not responding.\n") == .unreachable("Timeout, server box not responding."))
    }
}
