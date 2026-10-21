import Darwin
import Foundation
import Testing
import AgentStatus
@testable import ControlServer

/// `/bin/sh` always; `/bin/dash` too when the system has it (macOS does).
private let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

private func firstExecutable(_ paths: [String]) -> String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

/// Each client alone on PATH, next to the few tools the script needs.
private let clients: [(name: String, path: String)] = [
    ("python3", firstExecutable(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])),
    ("socat", firstExecutable(["/opt/homebrew/bin/socat", "/usr/local/bin/socat", "/usr/bin/socat"])),
    ("nc", firstExecutable(["/usr/bin/nc"])),
].compactMap { c in c.1.map { (c.0, $0) } }

private struct Run {
    var code: Int32
    var out: String
    var err: String
    var seconds: Double
}

/// Script, per-client PATH dirs and the server socket, all under one /tmp dir.
private final class Remote {
    let dir = SocketDir()
    let inbox = Inbox()
    var script: String { dir.dir + "/hangar-remote" }
    let tab = UUID(), leaf = UUID()

    init() throws {
        try hangarRemoteScript.write(toFile: script, atomically: true, encoding: .utf8)
        for c in clients {
            let bin = dir.dir + "/bin-" + c.name
            mkdir(bin, 0o700)
            let tools = ["sh": "/bin/sh", "head": "/usr/bin/head", "tr": "/usr/bin/tr", "wc": "/usr/bin/wc", "cat": "/bin/cat", c.name: c.path]
            for (name, target) in tools { symlink(target, bin + "/" + name) }
        }
    }

    func path(_ client: String = clients[0].name) -> String { dir.dir + "/bin-" + client }

    func leafEnv(_ client: String = clients[0].name) -> [String: String] {
        ["HANGAR_TAB_ID": tab.uuidString, "HANGAR_LEAF_ID": leaf.uuidString, "HANGAR_SOCKET": dir.path, "PATH": path(client)]
    }

    func start(onRequest: @escaping @MainActor (Int, ControlCall) async -> ControlResponse = { id, _ in .ok(id, [String: String]()) })
        throws -> ControlServer {
        let inbox = inbox
        let server = ControlServer(path: dir.path, remote: true, handler: { inbox.messages.append($0) }, onRequest: onRequest)
        try server.start()
        return server
    }

    func run(_ args: [String], shell: String = "/bin/sh", env: [String: String], stdin: String = "") throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = [script] + args
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: dir.dir)
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        let started = Date()
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(code: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self),
                   seconds: Date().timeIntervalSince(started))
    }
}

private func hook(_ tab: UUID, _ leaf: UUID, kind: String = "stop", len: Int, extra: String = "") -> String {
    #"{"v":1,"type":"hook","tab":"\#(tab.uuidString)","leaf":"\#(leaf.uuidString)","kind":"\#(kind)"\#(extra),"len":\#(len)}"# + "\n"
}

/// Lets late (wrongly accepted) messages reach the main actor before a "nothing arrived" check.
private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

@Suite struct RemoteSocketTests {
    @Test func hookDelivered() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        #expect(clients.contains { $0.name == "python3" } && clients.contains { $0.name == "nc" })
        var n = 0
        for shell in shells {
            for c in clients {
                let run = try r.run(["event", "session-start"], shell: shell, env: r.leafEnv(c.name),
                                    stdin: #"{"session_id":"abc","source":"startup"}"#)
                #expect(run.code == 0 && run.out.isEmpty && run.err.isEmpty, "\(shell) \(c.name): \(run.err)")
                n += 1
                let got = await r.inbox.wait(count: n)
                guard got.count == n, case let .event(m) = got[n - 1] else {
                    Issue.record("\(shell) \(c.name): no event")
                    return
                }
                #expect(m == EventMessage(tab: r.tab, leaf: r.leaf, kind: .sessionStart, session: "abc", source: "startup"))
            }
        }
    }

    @Test func sessionFlagIsSanitized() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let run = try r.run(["event", "stop", "--session", "a b;c$(x)"], env: r.leafEnv(), stdin: "{}")
        #expect(run.code == 0)
        let got = await r.inbox.wait(count: 1)
        guard case let .event(m)? = got.first else { Issue.record("no event"); return }
        #expect(m.session == "abcx")
    }

    @Test func remoteSocketRejectsRequests() async throws {
        let r = try Remote()
        let calls = CallCount()
        let server = try r.start { id, _ in
            calls.n += 1
            return .ok(id, [String: String]())
        }
        defer { server.stop() }
        let c1 = try RawClient(r.dir.path)
        c1.send(#"{"v":1,"id":1,"method":"tabs.send","params":{"tab":"\#(UUID().uuidString)","text":"rm -rf ~\n"}}"# + "\n")
        let reply = c1.readToEOF()
        #expect(reply.eof)
        #expect(reply.replies == [#"{"id":1,"error":{"code":"unknown-method","message":"not available over ssh"}}"#])

        let event = ControlMessage.event(EventMessage(tab: r.tab, leaf: r.leaf, kind: .stop))
        let usage = ControlMessage.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 1, resetsAt: nil)]))
        for m in [event, usage] {
            let c = try RawClient(r.dir.path)
            c.send(m.encoded())
            let rr = c.readToEOF()
            #expect(rr.eof && rr.replies == [#"{"ok":false,"error":"unknown-type"}"#])
        }
        await settle()
        #expect(await calls.n == 0)
        #expect(await r.inbox.messages.isEmpty)
    }

    @Test func oneMessagePerConnection() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let c = try RawClient(r.dir.path)
        c.send(hook(r.tab, r.leaf, len: 2) + "{}" + hook(r.tab, r.leaf, kind: "prompt", len: 2) + "{}")
        let reply = c.readToEOF()
        #expect(reply.eof && reply.replies == [#"{"ok":true}"#])
        await settle()
        let got = await r.inbox.messages
        #expect(got.count == 1)
        if case let .event(m)? = got.first { #expect(m.kind == .stop) }
    }

    @Test func payloadArrivesInPieces() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let c = try RawClient(r.dir.path)
        let payload = #"{"session_id":"s9"}"#
        let all = hook(r.tab, r.leaf, len: payload.utf8.count) + payload
        for ch in all { c.send(String(ch)) }
        #expect(c.readToEOF().replies == [#"{"ok":true}"#])
        let got = await r.inbox.wait(count: 1)
        guard case let .event(m)? = got.first else { Issue.record("no event"); return }
        #expect(m.session == "s9")
    }

    @Test func badPayloadStillCounts() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let cut = #"{"session_id":"#
        let c1 = try RawClient(r.dir.path)
        c1.send(hook(r.tab, r.leaf, len: cut.utf8.count) + cut)
        #expect(c1.readToEOF().replies == [#"{"ok":true}"#])
        let got = await r.inbox.wait(count: 1)
        guard case let .event(m)? = got.first else { Issue.record("no event"); return }
        #expect(m.kind == .stop && m.session == nil)

        let c2 = try RawClient(r.dir.path)
        c2.send(hook(r.tab, r.leaf, len: 300_000))
        let big = c2.readToEOF()
        #expect(big.eof && big.replies == [#"{"ok":false,"error":"too-large"}"#])

        let c3 = try RawClient(r.dir.path)
        c3.send(String(repeating: "x", count: 5000))
        #expect(c3.readToEOF().eof)
        await settle()
        #expect(await r.inbox.messages.count == 1)
    }

    @Test func noHangarEnvIsSilent() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        for shell in shells {
            let run = try r.run(["event", "stop"], shell: shell, env: ["PATH": r.path()], stdin: "{}")
            #expect(run.code == 0 && run.out.isEmpty && run.err.isEmpty)
            var env = r.leafEnv()
            env["HANGAR_SOCKET"] = r.dir.dir + "/missing.sock"
            let missing = try r.run(["event", "stop"], shell: shell, env: env, stdin: "{}")
            #expect(missing.code == 0 && missing.out.isEmpty && missing.err.isEmpty && missing.seconds < 3)
            env = r.leafEnv()
            env["HANGAR_LEAF_ID"] = "not-a-uuid"
            let bad = try r.run(["event", "stop"], shell: shell, env: env, stdin: "{}")
            #expect(bad.code == 0 && bad.out.isEmpty && bad.err.isEmpty)
            let badKind = try r.run(["event", "boom"], shell: shell, env: r.leafEnv(), stdin: "{}")
            #expect(badKind.code == 0 && badKind.out.isEmpty && badKind.err.isEmpty)
        }
        await settle()
        #expect(await r.inbox.messages.isEmpty)
    }

    @Test func statuslineChains() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1760000000}}}"# + "\n"
        var n = 0
        for shell in shells {
            let run = try r.run(["statusline", "--then", "cat; echo X"], shell: shell, env: r.leafEnv(), stdin: input)
            #expect(run.code == 0 && run.out == input + "X\n", "\(shell): \(run.out) \(run.err)")
            n += 1
            let got = await r.inbox.wait(count: n)
            guard got.count == n, case let .usage(u) = got[n - 1] else { Issue.record("\(shell): no usage"); return }
            #expect(u == UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000)]))
            let three = try r.run(["statusline", "--then", "exit 3"], shell: shell, env: r.leafEnv(), stdin: input)
            #expect(three.code == 3)
            n += 1
            _ = await r.inbox.wait(count: n)
            let plain = try r.run(["statusline"], shell: shell, env: ["PATH": r.path()], stdin: input)
            #expect(plain.code == 0 && plain.out.isEmpty)
        }
    }

    @Test func codexNotifyArgPayload() async throws {
        let r = try Remote()
        let server = try r.start()
        defer { server.stop() }
        let json = #"{"type":"agent-turn-complete","thread-id":"t1"}"#
        var n = 0
        for shell in shells {
            let rec = r.dir.dir + "/rec-" + (shell as NSString).lastPathComponent
            let run = try r.run(["event", "codex-notify", "--then", "/bin/sh", "-c", #"printf '%s\n' "$@" > "$0""#, rec, "hi", json],
                                shell: shell, env: r.leafEnv())
            #expect(run.code == 0 && run.out.isEmpty && run.err.isEmpty)
            n += 1
            let got = await r.inbox.wait(count: n)
            guard got.count == n, case let .event(m) = got[n - 1] else { Issue.record("\(shell): no event"); return }
            #expect(m.kind == .codexNotify && m.session == "t1")
            let deadline = Date().addingTimeInterval(5)
            var text = ""
            while Date() < deadline {
                text = (try? String(contentsOfFile: rec, encoding: .utf8)) ?? ""
                if text.hasSuffix("}\n") { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(text == "hi\n" + json + "\n")
        }
    }

    @Test func scriptParsesAsPOSIX() throws {
        let lines = hangarRemoteScript.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "#!/bin/sh" && lines[1] == "# hangar-remote \(hangarRemoteVersion)" && hangarRemoteVersion == 1)
        let r = try Remote()
        for shell in shells {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-n", r.script]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(shell)")
            let v = try r.run(["version"], shell: shell, env: ["PATH": r.path()])
            #expect(v.code == 0 && v.out == "1\n")
        }
    }

    @Test func decodeValidates() {
        let tab = UUID(), leaf = UUID()
        func decode(_ header: String, _ payload: String = "") -> Result<ControlMessage, ProtocolError> {
            RemoteMessage.decode(header: Data(header.utf8), payload: Data(payload.utf8))
        }
        let ok = decode(hook(tab, leaf, kind: "notification", len: 0, extra: #","session":"s-1""#),
                        #"{"notification_type":"permission_prompt","message":"\#(String(repeating: "m", count: 900))"}"#)
        guard case let .success(.event(m)) = ok else { Issue.record("\(ok)"); return }
        #expect(m.session == "s-1" && m.notificationType == "permission_prompt" && m.message?.count == 500)
        #expect(decode(#"{"v":2,"type":"hook","len":0}"#) == .failure(.badVersion))
        #expect(decode(#"{"v":1,"type":"hook","tab":"x","leaf":"\#(leaf.uuidString)","kind":"stop","len":0}"#) == .failure(.badField))
        #expect(decode(hook(tab, leaf, kind: "boom", len: 0)) == .failure(.badField))
        #expect(decode(hook(tab, leaf, kind: "codex-notify", len: 0), #"{"type":"other"}"#) == .failure(.badField))
        #expect(decode(hook(tab, leaf, len: 0, extra: #","session":"bad id!""#), #"{"session_id":"good"}"#)
                    == .success(.event(EventMessage(tab: tab, leaf: leaf, kind: .stop, session: "good"))))
        #expect(decode(#"{"v":1,"type":"statusline","len":0}"#, "{}") == .failure(.badField))
        #expect(decode(#"{"v":1,"type":"event","len":0}"#) == .failure(.unknownType))
        #expect(decode("nope") == .failure(.badJSON))
    }
}

@MainActor private final class CallCount {
    var n = 0
}
