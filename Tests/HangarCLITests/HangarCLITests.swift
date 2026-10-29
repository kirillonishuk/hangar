import Darwin
import Foundation
import Testing
import AgentStatus
import ControlServer
import TestSupport

private final class BundleToken {}

/// The `hangar` binary is built next to the test bundle (the test target depends on it).
private let binary: URL = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("hangar")

private final class TempDir {
    let path: String
    var socket: String { path + "/s.sock" }
    init() {
        path = "/tmp/hg-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        mkdir(path, 0o700)
        // The user's own line (the chained command) unless a test asks for Hangar's; never the real config file.
        try? #"statusline = "user""#.write(toFile: path + "/config.toml", atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@MainActor private final class Inbox {
    var messages: [ControlMessage] = []
    /// Returns as soon as `n` arrive (messages are delivered on the main actor).
    func wait(count n: Int) async -> [ControlMessage] {
        _ = await waitUntil { messages.count >= n }
        return messages
    }
}

@MainActor private final class CallLog { var calls: [ControlCall] = [] }

private struct Result { var status: Int32; var out: Data; var err: Data; var seconds: Double }

private func run(_ args: [String], env: [String: String], stdin: Data?) throws -> Result {
    let p = Process()
    p.executableURL = binary
    p.arguments = args
    // The fake apps answer on the main actor, which other suites hold for longer than the CLI's 10 s default.
    p.environment = ["PATH": "/usr/bin:/bin", "HANGAR_MIN_TIMEOUT": "\(offMainBound)"].merging(env) { $1 }
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    // A CLI that exits without reading all of stdin (e.g. the 2 MB event) must give EPIPE, not kill the test run.
    _ = fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let outData = LockedData(), errData = LockedData()
    out.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
    err.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
    // The CLI reads stdin with a ~1 s budget (a hook must never hang). A payload written by a background writer after
    // launch can miss that budget under load, so one that fits the pipe buffer is in the pipe before the CLI starts.
    let prefill = (stdin?.count ?? 0) <= 16_384
    if prefill {
        if let stdin { try inp.fileHandleForWriting.write(contentsOf: stdin) }
        try inp.fileHandleForWriting.close()
    }
    let start = SuspendingClock.now
    try p.run()
    if !prefill {
        Thread {
            if let stdin { try? inp.fileHandleForWriting.write(contentsOf: stdin) }
            try? inp.fileHandleForWriting.close()
        }.start()
    }
    p.waitUntilExit()
    let elapsed = SuspendingClock.now - start
    // Wait for EOF on both pipes, not a fixed 50 ms that loses output under load. Bounded: a child spawned by a
    // parallel test at the same moment can inherit the write ends and hold them open.
    let deadline = SuspendingClock.now + .seconds(5)
    while !(outData.eof && errData.eof), SuspendingClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    return Result(status: p.terminationStatus, out: outData.value, err: errData.value,
                  seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

/// The fake apps of all tests here answer on the main actor (the CLI gives up after `offMainBound`), so the blocking
/// `waitUntilExit` must never run there — not even in tests that need no answer. Nor on the cooperative pool (one
/// thread per core): a few CLIs waiting for a busy main actor would stall every async test in the run. Nor on GCD's
/// global queue: its thread limit fills with other suites' blocking waits and a queued CLI run starts seconds late.
private func runOffMain(_ args: [String], env: [String: String], stdin: Data?) async throws -> Result {
    try await onThread { Swift.Result { try run(args, env: env, stdin: stdin) } }.get()
}

private func runOffMain(_ args: [String], socket: String) async throws -> Result {
    try await runOffMain(args, env: ["HANGAR_SOCKET": socket], stdin: nil)
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    /// An empty read is EOF.
    func append(_ d: Data) { lock.lock(); if d.isEmpty { ended = true } else { data.append(d) }; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    var eof: Bool { lock.lock(); defer { lock.unlock() }; return ended }
}

private let statusFixture = Data("""
{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1760000000},\
"seven_day":{"used_percentage":10,"resets_at":1760500000},\
"seven_day_opus":{"used_percentage":3.5,"resets_at":1760600000},"note":"text"}}
""".utf8)

@Suite struct HangarCLITests {
    let tab = UUID(), leaf = UUID()
    fileprivate func env(_ dir: TempDir) -> [String: String] {
        ["HANGAR_TAB_ID": tab.uuidString, "HANGAR_LEAF_ID": leaf.uuidString, "HANGAR_SOCKET": dir.socket,
         "HANGAR_CONFIG": dir.path + "/config.toml"]
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
        let r = try await runOffMain(["event", "stop"], env: env(dir), stdin: Data(#"{"session_id":"s1"}"#.utf8))
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
            let r = try await runOffMain(row.args, env: row.env, stdin: row.stdin)
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
        let r = try await runOffMain(["event", "codex-notify", "--then", "/bin/sh", "-c", #"printf %s "$1" > "# + out, "sh", payload],
                        env: env(dir), stdin: nil)
        #expect(r.status == 0 && r.out.isEmpty && r.err.isEmpty)
        let deadline = SuspendingClock.now + .seconds(30)  // polls; exits as soon as the chained command wrote
        var got = ""
        while SuspendingClock.now < deadline {
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
        let r = try await runOffMain(["statusline", "--then", "cat"], env: env(dir), stdin: statusFixture)
        #expect(r.status == 0)
        #expect(r.out == statusFixture)
        #expect(await inbox.wait(count: 1) == [.usage(UsageMessage(agent: "claude", windows: [
            WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000),
            WireWindow(name: "seven_day", usedPercent: 10, resetsAt: 1_760_500_000),
            WireWindow(name: "seven_day_opus", usedPercent: 3.5, resetsAt: 1_760_600_000),
        ]))])
        let failing = try await runOffMain(["statusline", "--then", "exit 3"], env: env(dir), stdin: statusFixture)
        #expect(failing.status == 3)
    }

    @Test @MainActor func statuslineWithoutDataOrSocket() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let r = try await runOffMain(["statusline"], env: env(dir), stdin: Data(#"{"model":{}}"#.utf8))
        #expect(r.status == 0 && r.out.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(inbox.messages.isEmpty)

        var e = env(dir); e["HANGAR_SOCKET"] = dir.path + "/missing.sock"
        let r2 = try await runOffMain(["statusline", "--then", "echo hi"], env: e, stdin: statusFixture)
        #expect(r2.status == 0 && String(decoding: r2.out, as: UTF8.self) == "hi\n")
    }

    /// #105: Hangar's line from the CLI itself (config read on each run), usage still forwarded, the chained command not run.
    @Test @MainActor func statuslineRendersHangarLine() async throws {
        let dir = TempDir(), inbox = Inbox()
        let s = try server(dir, inbox)
        defer { s.stop() }
        let config = dir.path + "/config.toml"
        func visible(_ d: Data) -> String {
            String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        try "statusline = \"hangar\"\nlanguage = \"en\"\n".write(toFile: config, atomically: true, encoding: .utf8)
        let reset = Int(Date().timeIntervalSince1970) + 107 * 60 + 30
        let payload = Data(#"{"model":{"id":"claude-opus-4-7[1m]","display_name":"Opus 4.7 (1M context)"},"context_window":{"used_percentage":12,"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":96,"resets_at":\#(reset)},"seven_day":{"used_percentage":18,"resets_at":\#(reset + 86_400)}},"cost":{"total_cost_usd":0.04}}"#.utf8)
        let r = try await runOffMain(["statusline", "--then", "echo own"], env: env(dir), stdin: payload)
        #expect(r.status == 0)
        #expect(visible(r.out) == "Opus 4.7 1M │ ctx ━─────── 12% │ 5h ━━━━━━━━ 96% 1h48m │ wk 18%\n")
        #expect(String(decoding: r.out, as: UTF8.self).contains("\u{1B}[31m96%"))
        #expect(await inbox.wait(count: 1).count == 1)

        // Before the first reply: no rate limits → only what is known. English in a Russian Hangar too (#110).
        try "statusline = \"hangar\"\nlanguage = \"ru\"\n".write(toFile: config, atomically: true, encoding: .utf8)
        let early = try await runOffMain(["statusline", "--then", "echo own"], env: env(dir),
                                         stdin: Data(#"{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":3}}"#.utf8))
        #expect(visible(early.out) == "Sonnet 4.6 │ ctx ━─────── 3%\n")

        // The segments in the config's order (#110).
        try "language = \"ru\"\nstatusline_segments = [\"week\", \"5h\", \"model\"]\n".write(toFile: config, atomically: true, encoding: .utf8)
        let ordered = try await runOffMain(["statusline", "--then", "echo own"], env: env(dir), stdin: payload)
        #expect(visible(ordered.out) == "wk 18% │ 5h ━━━━━━━━ 96% 1h48m │ Opus 4.7 1M\n")

        // An unreadable config is the defaults (Hangar's line); no data at all prints nothing.
        try "statusline = 5".write(toFile: config, atomically: true, encoding: .utf8)
        let empty = try await runOffMain(["statusline", "--then", "echo own"], env: env(dir), stdin: Data("{}".utf8))
        #expect(empty.status == 0 && empty.out.isEmpty)
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
        let r = try await runOffMain(["sessions", "list", "--json"], socket: dir.socket)
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

    /// `hangar doctor` (#61): the app's checks plus the CLI's lines; a fail → exit 1, warnings alone → 0.
    @Test @MainActor func doctorReportsAndExitCodes() async throws {
        let dir = TempDir(), calls = CallLog()
        let warn = DoctorCheck(name: "codex", level: .warn, detail: "`codex` not found", fix: "Install codex")
        let s = try fakeApp(dir, calls) { id, _ in .ok(id, DoctorResult(appVersion: "dev", checks: [warn])) }
        defer { s.stop() }
        let r = try await runOffMain(["doctor"], socket: dir.socket)
        #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
        let text = String(decoding: r.out, as: UTF8.self)
        #expect(text.contains("ok    app") && text.contains("warn  codex") && text.contains("fix: Install codex"))
        #expect(calls.calls == [.doctor])
        let json = try await runOffMain(["doctor", "--json"], socket: dir.socket)
        #expect(try JSONDecoder().decode(DoctorReport.self, from: json.out).checks.last == warn)

        let down = TempDir()
        let r2 = try run(["doctor", "--json"], env: ["HANGAR_SOCKET": down.socket], stdin: nil)
        #expect(r2.status == 1)
        let report = try JSONDecoder().decode(DoctorReport.self, from: r2.out)
        #expect(!report.ok && report.checks.first?.name == "app" && report.checks.first?.level == .fail)
    }

    @Test @MainActor func cliArchiveWithoutYes() async throws {
        let dir = TempDir(), calls = CallLog()
        let s = try fakeApp(dir, calls) { id, _ in .ok(id, ArchiveResult(task: UUID(), archived: true)) }
        defer { s.stop() }
        let r = try await runOffMain(["sessions", "archive", "--session", "t"], socket: dir.socket)
        #expect(r.status == 2)
        #expect(String(decoding: r.err, as: UTF8.self).contains("--yes"))
        let bad = try await runOffMain(["sessions", "list", "--frob"], socket: dir.socket)
        #expect(bad.status == 2 && !bad.err.isEmpty && bad.out.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.calls.isEmpty)
    }

    @Test @MainActor func cliAppError() async throws {
        let dir = TempDir(), calls = CallLog()
        let s = try fakeApp(dir, calls) { id, _ in ControlResponse(id: id, body: .failure(ControlError(code: .notFound, message: "no session \"x\""))) }
        defer { s.stop() }
        let r = try await runOffMain(["tabs", "open", "--session", "x", "--kind", "shell"], socket: dir.socket)
        #expect(r.status == 1)
        #expect(String(decoding: r.err, as: UTF8.self) == "hangar: no session \"x\"\n")
        #expect(r.out.isEmpty)
        let j = try await runOffMain(["tabs", "open", "--session", "x", "--kind", "shell", "--json"], socket: dir.socket)
        #expect(j.status == 1 && j.out.isEmpty)
        let object = try JSONSerialization.jsonObject(with: j.err) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "not-found")
        #expect(error?["message"] as? String == "no session \"x\"")
        #expect(calls.calls == [.tabsOpen(task: "x", kind: .shell, prompt: nil), .tabsOpen(task: "x", kind: .shell, prompt: nil)])
    }

    /// The server's own validation (`bad-params`, `confirm-required`) is a usage error too: exit 2, like the CLI's.
    @Test @MainActor func cliServerUsageErrorsExitTwo() async throws {
        for code in [ControlErrorCode.badParams, .confirmRequired] {
            let dir = TempDir(), calls = CallLog()
            let s = try fakeApp(dir, calls) { id, _ in ControlResponse(id: id, body: .failure(ControlError(code: code, message: "nope"))) }
            defer { s.stop() }
            let r = try await runOffMain(["tasks", "list"], socket: dir.socket)
            #expect(r.status == 2, "\(code)")
            #expect(String(decoding: r.err, as: UTF8.self) == "hangar: nope\n")
        }
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
        // `--json` as the value of --session is not json mode.
        let plain = try run(["sessions", "archive", "--session", "--json"], env: ["HANGAR_SOCKET": dir.socket], stdin: nil)
        #expect(plain.status == 2)
        #expect(String(decoding: plain.err, as: UTF8.self) == "hangar: refusing to archive without --yes\n")
    }

    @Test @MainActor func mcpOverStdio() async throws {
        let dir = TempDir(), calls = CallLog()
        let s = try fakeApp(dir, calls) { id, _ in .ok(id, TasksResult(tasks: [])) }
        defer { s.stop() }
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sessions_list","arguments":{}}}"#,
        ].joined(separator: "\n") + "\n"
        let socket = dir.socket
        let r = try await runOffMain(["mcp"], env: ["HANGAR_SOCKET": socket], stdin: Data(input.utf8))
        #expect(r.status == 0)
        #expect(r.err.isEmpty, "\(String(decoding: r.err, as: UTF8.self))")
        let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4 && lines.last == "")  // exactly 3 lines, each ends with \n
        let objects = lines.dropLast().compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(objects.count == 3)
        #expect(objects.map { $0["jsonrpc"] as? String } == ["2.0", "2.0", "2.0"])
        #expect(objects.map { $0["id"] as? Int } == [1, 2, 3])
        let result = objects.last?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
        #expect(calls.calls == [.tasksList(project: nil)])
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
        let start = SuspendingClock.now
        try p.run()
        p.waitUntilExit()
        let elapsed = SuspendingClock.now - start
        try? inp.fileHandleForWriting.close()
        #expect(p.terminationStatus == 0)
        // The writer never writes nor closes until after exit: anything under 6 s proves `event` didn't wait for stdin.
        #expect(elapsed < .seconds(6))
        #expect(out.fileHandleForReading.availableData.isEmpty)
    }
}
