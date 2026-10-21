import Darwin
import Foundation
import Testing
import AgentStatus
import ControlServer

private final class BundleToken {}

/// The `hangar` binary is built next to the test bundle (the test target depends on it).
private let binary: URL = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("hangar")

private final class TempDir {
    let path: String
    var socket: String { path + "/s.sock" }
    init() {
        path = "/tmp/hg-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        mkdir(path, 0o700)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@MainActor private final class Inbox {
    var messages: [ControlMessage] = []
    /// Returns as soon as `n` arrive; the generous default only matters under a loaded parallel test run.
    func wait(count n: Int, seconds: Double = 10) async -> [ControlMessage] {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while messages.count < n && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return messages
    }
}

@MainActor private final class CallLog { var calls: [ControlCall] = [] }

private struct Result { var status: Int32; var out: Data; var err: Data; var seconds: Double }

private func run(_ args: [String], env: [String: String], stdin: Data?) throws -> Result {
    let p = Process()
    p.executableURL = binary
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin"].merging(env) { $1 }
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    let outData = LockedData(), errData = LockedData()
    out.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
    err.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
    let start = ContinuousClock.now
    try p.run()
    DispatchQueue.global().async {
        if let stdin { try? inp.fileHandleForWriting.write(contentsOf: stdin) }
        try? inp.fileHandleForWriting.close()
    }
    p.waitUntilExit()
    let elapsed = ContinuousClock.now - start
    Thread.sleep(forTimeInterval: 0.05)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    return Result(status: p.terminationStatus, out: outData.value, err: errData.value,
                  seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

/// The fake app answers on the main actor, so the blocking `waitUntilExit` must not run there.
private func runOffMain(_ args: [String], socket: String) async throws -> Result {
    try await Task.detached { try run(args, env: ["HANGAR_SOCKET": socket], stdin: nil) }.value
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private let statusFixture = Data("""
{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1760000000},\
"seven_day":{"used_percentage":10,"resets_at":1760500000},\
"seven_day_opus":{"used_percentage":3.5,"resets_at":1760600000},"note":"text"}}
""".utf8)

@Suite struct HangarCLITests {
    let tab = UUID(), leaf = UUID()
    fileprivate func env(_ dir: TempDir) -> [String: String] {
        ["HANGAR_TAB_ID": tab.uuidString, "HANGAR_LEAF_ID": leaf.uuidString, "HANGAR_SOCKET": dir.socket]
    }

    @MainActor fileprivate func server(_ dir: TempDir, _ inbox: Inbox) throws -> ControlServer {
        let s = ControlServer(path: dir.socket) { inbox.messages.append($0) }
        try s.start()
        return s
    }

    @Test @MainActor func eventForwardsHookPayload() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let r = try run(["event", "stop"], env: env(dir), stdin: Data(#"{"session_id":"s1"}"#.utf8))
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        #expect(await inbox.wait(count: 1) == [.event(EventMessage(tab: tab, leaf: leaf, kind: .stop, session: "s1"))])
    }

    @Test @MainActor func eventNeverPrintsAndExitsZero() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let e = env(dir)
        let huge = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        var noTab = e; noTab["HANGAR_TAB_ID"] = nil
        var noSocket = e; noSocket["HANGAR_SOCKET"] = dir.path + "/missing.sock"
        let table: [(args: [String], env: [String: String], stdin: Data?)] = [
            (["event", "stop"], e, Data("not json".utf8)),
            (["event", "stop"], e, huge),
            (["event", "stop"], e, Data()),
            (["event", "stop"], e, nil),
            (["event", "boom"], e, Data("{}".utf8)),
            (["event", "stop"], noTab, Data("{}".utf8)),
            (["event", "stop"], noSocket, Data("{}".utf8)),
            (["event"], e, Data("{}".utf8)),
        ]
        for row in table {
            let r = try run(row.args, env: row.env, stdin: row.stdin)
            #expect(r.status == 0, "\(row.args)")
            #expect(r.out.isEmpty && r.err.isEmpty, "\(row.args)")
            // Never hangs: the ~1 s stdin budget plus process spawn under a loaded parallel test run.
            #expect(r.seconds < 3, "\(row.args) took \(r.seconds)")
        }
        // Only the four deliverable rows reach the server.
        #expect(await inbox.wait(count: 4).count == 4)
        try await Task.sleep(for: .milliseconds(200))
        #expect(inbox.messages.count == 4)
        for case let .event(m) in inbox.messages { #expect(m.kind == .stop) }
    }

    @Test @MainActor func codexNotifyChainsOriginal() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let payload = #"{"type":"agent-turn-complete","thread-id":"t1","last-assistant-message":"ok"}"#
        let out = dir.path + "/out"
        let r = try run(["event", "codex-notify", "--then", "/bin/sh", "-c", #"printf %s "$1" > "# + out, "sh", payload],
                        env: env(dir), stdin: nil)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let deadline = ContinuousClock.now + .seconds(10)  // polls; exits as soon as the chained command wrote
        var got = ""
        while ContinuousClock.now < deadline {
            got = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            if got == payload { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(got == payload)
        #expect(await inbox.wait(count: 1) == [.event(EventMessage(tab: tab, leaf: leaf, kind: .codexNotify, session: "t1", message: "ok"))])
    }

    @Test @MainActor func statuslineSendsWindowsAndRunsOriginal() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let r = try run(["statusline", "--then", "cat"], env: env(dir), stdin: statusFixture)
        #expect(r.status == 0)
        #expect(r.out == statusFixture)
        #expect(await inbox.wait(count: 1) == [.usage(UsageMessage(agent: "claude", windows: [
            WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000),
            WireWindow(name: "seven_day", usedPercent: 10, resetsAt: 1_760_500_000),
            WireWindow(name: "seven_day_opus", usedPercent: 3.5, resetsAt: 1_760_600_000),
        ]))])
        let failing = try run(["statusline", "--then", "exit 3"], env: env(dir), stdin: statusFixture)
        #expect(failing.status == 3)
    }

    @Test @MainActor func statuslineWithoutDataOrSocket() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let r = try run(["statusline"], env: env(dir), stdin: Data(#"{"model":{}}"#.utf8))
        #expect(r.status == 0 && r.out.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(inbox.messages.isEmpty)

        var e = env(dir); e["HANGAR_SOCKET"] = dir.path + "/missing.sock"
        let r2 = try run(["statusline", "--then", "echo hi"], env: e, stdin: statusFixture)
        #expect(r2.status == 0 && String(decoding: r2.out, as: UTF8.self) == "hi\n")
    }

    @MainActor fileprivate func fakeApp(_ dir: TempDir, _ calls: CallLog, reply: @escaping @MainActor (Int, ControlCall) -> ControlResponse) throws -> ControlServer {
        let s = ControlServer(path: dir.socket, handler: { _ in }, onRequest: { id, call in
            calls.calls.append(call)
            return reply(id, call)
        })
        try s.start()
        return s
    }

    @Test @MainActor func cliJSONOutput() async throws {
        let dir = TempDir(), calls = CallLog()
        let expected = TasksResult(tasks: [TaskInfo(id: UUID(), name: "N", project: UUID(), projectName: "web", status: "idle", mode: "worktree",
                                                    path: "/w", branch: "b", base: "main", tabs: [
                                                        TabInfo(id: UUID(), kind: .claude, title: "Claude", status: "idle",
                                                                leaves: [LeafInfo(id: UUID(), kind: .claude, status: "idle")]),
                                                    ])])
        let s = try fakeApp(dir, calls) { id, _ in .ok(id, expected) }
        defer { s.stop() }
        let r = try await runOffMain(["tasks", "list", "--json"], socket: dir.socket)
        #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
        #expect(try JSONDecoder().decode(TasksResult.self, from: r.out) == expected)
        #expect(String(decoding: r.out, as: UTF8.self).contains("\n  "))  // pretty-printed
        #expect(calls.calls == [.tasksList(project: nil)])
    }

    @Test func cliNotRunning() throws {
        let dir = TempDir()
        let r = try run(["projects", "list"], env: ["HANGAR_SOCKET": dir.socket], stdin: nil)
        #expect(r.status == 1)
        #expect(String(decoding: r.err, as: UTF8.self).contains("Hangar is not running"))
        #expect(r.out.isEmpty)
        // Fails on connect, not after the 10 s request timeout; spawn under a loaded parallel run alone can take ~2 s.
        #expect(r.seconds < 5)
    }

    @Test @MainActor func cliArchiveWithoutYes() async throws {
        let dir = TempDir(), calls = CallLog()
        let s = try fakeApp(dir, calls) { id, _ in .ok(id, ArchiveResult(task: UUID(), archived: true)) }
        defer { s.stop() }
        let r = try await runOffMain(["tasks", "archive", "--task", "t"], socket: dir.socket)
        #expect(r.status == 2)
        #expect(String(decoding: r.err, as: UTF8.self).contains("--yes"))
        let bad = try await runOffMain(["tasks", "list", "--frob"], socket: dir.socket)
        #expect(bad.status == 2 && !bad.err.isEmpty && bad.out.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.calls.isEmpty)
    }

    @Test @MainActor func cliAppError() async throws {
        let dir = TempDir(), calls = CallLog()
        let s = try fakeApp(dir, calls) { id, _ in ControlResponse(id: id, body: .failure(ControlError(code: .notFound, message: "no task \"x\""))) }
        defer { s.stop() }
        let r = try await runOffMain(["tabs", "open", "--task", "x", "--kind", "shell"], socket: dir.socket)
        #expect(r.status == 1)
        #expect(String(decoding: r.err, as: UTF8.self) == "hangar: no task \"x\"\n")
        #expect(r.out.isEmpty)
        let j = try await runOffMain(["tabs", "open", "--task", "x", "--kind", "shell", "--json"], socket: dir.socket)
        #expect(j.status == 1 && j.out.isEmpty)
        let object = try JSONSerialization.jsonObject(with: j.err) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "not-found")
        #expect(error?["message"] as? String == "no task \"x\"")
        #expect(calls.calls == [.tabsOpen(task: "x", kind: .shell, prompt: nil), .tabsOpen(task: "x", kind: .shell, prompt: nil)])
    }

    @Test func unknownSubcommandIsUsage() throws {
        for args in [["frobnicate"], []] {
            let r = try run(args, env: [:], stdin: nil)
            #expect(r.status == 2, "\(args)")
            #expect(!r.err.isEmpty && r.out.isEmpty, "\(args)")
        }
    }

    @Test func usageErrorAsJSON() throws {
        let dir = TempDir()
        let r = try run(["tasks", "list", "--frob", "--json"], env: ["HANGAR_SOCKET": dir.socket], stdin: nil)
        #expect(r.status == 2 && r.out.isEmpty)
        let error = (try JSONSerialization.jsonObject(with: r.err) as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "bad-params")
        #expect(error?["message"] as? String == "unknown flag \"--frob\"")
        // `--json` as the value of --task is not json mode.
        let plain = try run(["tasks", "archive", "--task", "--json"], env: ["HANGAR_SOCKET": dir.socket], stdin: nil)
        #expect(plain.status == 2)
        #expect(String(decoding: plain.err, as: UTF8.self) == "hangar: refusing to archive without --yes\n")
    }

    @Test func slowStdinDoesNotBlockEvent() throws {
        let dir = TempDir()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["event", "stop"]
        p.environment = ["PATH": "/usr/bin:/bin", "HANGAR_TAB_ID": UUID().uuidString, "HANGAR_LEAF_ID": UUID().uuidString, "HANGAR_SOCKET": dir.socket]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp  // the writer stays silent and open, like `(sleep 10; echo x) | hangar`
        let start = ContinuousClock.now
        try p.run()
        p.waitUntilExit()
        let elapsed = ContinuousClock.now - start
        try? inp.fileHandleForWriting.close()
        #expect(p.terminationStatus == 0)
        // The writer never writes nor closes until after exit: anything under 6 s proves `event` didn't wait for stdin.
        #expect(elapsed < .seconds(6))
        #expect(out.fileHandleForReading.availableData.isEmpty)
    }
}
