import AgentStatus
import Foundation
import Testing
@testable import ControlServer

/// `sessions_spawn` / `sessions_wait` over the CLI, MCP and the socket, and Stop's `background_tasks` (#128).
@Suite struct SubSessionsWireTests {
    let tab = UUID(), leaf = UUID()
    let caller = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    @Test func cliGrammar() {
        let me = caller.lowercased()
        let table: [([String], CLIParse)] = [
            (["sessions", "spawn", "--name", "Release", "--prompt", "ship 1.2"],
             .call(.tasksSpawn(parent: me, name: "Release", prompt: "ship 1.2", agent: nil, worktree: false, base: nil), json: false)),
            (["sessions", "spawn", "--name", "R", "--prompt", "p", "--agent", "codex", "--worktree", "--base", "main", "--parent", "chat", "--json"],
             .call(.tasksSpawn(parent: "chat", name: "R", prompt: "p", agent: .codex, worktree: true, base: "main"), json: true)),
            (["sessions", "wait"], .call(.tasksWait(sessions: [], parent: me, timeout: ControlMethod.waitDefaultSeconds), json: false)),
            (["sessions", "wait", "a1", "b2", "--timeout", "30"], .call(.tasksWait(sessions: ["a1", "b2"], parent: me, timeout: 30), json: false)),
        ]
        for (args, expected) in table { #expect(parseCLI(args, cwd: "/tmp", callerLeaf: me) == expected, "\(args)") }
        let usage: [[String]] = [
            ["sessions", "spawn", "--name", "R"],
            ["sessions", "spawn", "--name", "R", "--prompt", "p", "--agent", "shell"],
            ["sessions", "spawn", "--name", "R", "--prompt", "p", "--base", "main"],
            ["sessions", "spawn", "--name", "R", "--prompt", "p", "--notify-only"],  // gone (#131): nothing reaches the parent anyway
            ["sessions", "wait", "--timeout", "0"],
        ]
        for args in usage {
            guard case .usage = parseCLI(args, cwd: "/tmp", callerLeaf: me) else { Issue.record("accepted \(args)"); continue }
        }
        // Outside a Hangar terminal there is no caller.
        guard case .usage = parseCLI(["sessions", "spawn", "--name", "R", "--prompt", "p"], cwd: "/tmp") else { Issue.record("no parent"); return }
        guard case .usage = parseCLI(["sessions", "wait"], cwd: "/tmp") else { Issue.record("no parent"); return }
        #expect(requestTimeout(.tasksWait(sessions: [], parent: nil, timeout: 100)) == 115)
        #expect(requestTimeout(.tasksSpawn(parent: nil, name: "n", prompt: "p", agent: nil, worktree: true, base: nil)) == 300)
    }

    @Test func socketValidation() {
        func decode(_ method: String, _ json: String) -> Result<ControlCall, ControlError> {
            ControlCall.decode(method: method, params: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
        }
        #expect(decode("tasks.spawn", #"{"name":" R ","prompt":"go","parent":"p"}"#)
                == .success(.tasksSpawn(parent: "p", name: "R", prompt: "go", agent: nil, worktree: false, base: nil)))
        for bad in [#"{"name":"R"}"#, #"{"name":"R","prompt":"   "}"#, #"{"name":"R","prompt":"p","agent":"shell"}"#,
                    #"{"name":"R","prompt":"p","base":"main"}"#, #"{"name":"a\u0007","prompt":"p"}"#] {
            guard case .failure(let e) = decode("tasks.spawn", bad) else { Issue.record("accepted \(bad)"); continue }
            #expect(e.code == .badParams)
        }
        // `deliver` is gone (#131): a sub-session never sends anything to its parent.
        guard case .failure = decode("tasks.spawn", #"{"name":"R","prompt":"go","deliver":"notify"}"#) else { Issue.record("deliver"); return }
        #expect(decode("tasks.wait", #"{"sessions":["a","b"],"timeout":5}"#) == .success(.tasksWait(sessions: ["a", "b"], parent: nil, timeout: 5)))
        for bad in [#"{"sessions":"a"}"#, #"{"sessions":[1]}"#, #"{"sessions":[""]}"#, #"{"timeout":0}"#, #"{"timeout":3601}"#,
                    "{\"sessions\":[" + Array(repeating: "\"a\"", count: 17).joined(separator: ",") + "]}"] {
            guard case .failure = decode("tasks.wait", bad) else { Issue.record("accepted \(bad)"); continue }
        }
    }

    /// `hangar mcp` fills in the caller (HANGAR_LEAF_ID) and a wait default under the client's own tool timeout.
    @Test func mcpFillsCallerAndTimeout() throws {
        var calls: [ControlCall] = []
        func run(client: String?, _ name: String, _ args: String) -> ControlCall? {
            var s = MCPSession(callerLeaf: caller) { calls.append($0); return .success(Data("{}".utf8)) }
            if let client {
                _ = s.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"\#(client)"}}}"#.utf8))
            }
            _ = s.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#.utf8))
            return calls.popLast()
        }
        let me = caller.lowercased()
        #expect(run(client: "claude-code", "sessions_spawn", #"{"name":"R","prompt":"p"}"#)
                == .tasksSpawn(parent: me, name: "R", prompt: "p", agent: nil, worktree: false, base: nil))
        #expect(run(client: "claude-code", "sessions_spawn", #"{"name":"R","prompt":"p","parent":"x"}"#)
                == .tasksSpawn(parent: "x", name: "R", prompt: "p", agent: nil, worktree: false, base: nil))
        #expect(run(client: "claude-code", "sessions_wait", "{}") == .tasksWait(sessions: [], parent: me, timeout: 110))
        #expect(run(client: "codex-mcp-client", "sessions_wait", "{}") == .tasksWait(sessions: [], parent: me, timeout: 50))
        #expect(run(client: nil, "sessions_wait", #"{"sessions":["s"],"timeout":7}"#) == .tasksWait(sessions: ["s"], parent: me, timeout: 7))
    }

    @Test func mcpSchema() throws {
        var s = MCPSession { _ in .success(Data("{}".utf8)) }
        let handled = s.handle(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8))
        let reply = try #require(handled)
        let tools = try #require(((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let wait = try #require(tools.first { $0["name"] as? String == "sessions_wait" })
        let props = (wait["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        #expect((props?["sessions"] as? [String: Any])?["type"] as? String == "array")
        let spawn = try #require(tools.first { $0["name"] as? String == "sessions_spawn" })
        #expect(((spawn["inputSchema"] as? [String: Any])?["required"] as? [String]).map(Set.init) == ["name", "prompt"])
        #expect(((spawn["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["deliver"] == nil)
    }

    @Test func stopCarriesRunningBackgroundTasks() {
        let payload = Data(#"{"last_assistant_message":"waiting","background_tasks":[{"id":"1","type":"shell","status":"running"},{"id":"2","status":"completed"}]}"#.utf8)
        let stop = eventMessage(kind: "stop", tab: tab, leaf: leaf, args: [], payload: payload)
        #expect(stop?.background == 1)
        #expect(eventMessage(kind: "stop", tab: tab, leaf: leaf, args: [], payload: Data("{}".utf8))?.background == nil)
        #expect(eventMessage(kind: "notification", tab: tab, leaf: leaf, args: [], payload: payload)?.background == nil)
        // Survives the wire; an out-of-range count from a hostile writer is dropped.
        let wire = ControlMessage.event(stop!).encoded()
        guard case .success(.event(let back)) = ControlMessage.decode(wire.dropLast()) else { Issue.record("decode"); return }
        #expect(back.background == 1)
        var bad = stop!
        bad.background = 1000
        guard case .success(.event(let clipped)) = ControlMessage.decode(ControlMessage.event(bad).encoded().dropLast()) else { Issue.record("decode"); return }
        #expect(clipped.background == nil)
    }

    @Test func humanOutput() {
        let id = UUID()
        let wait = WaitResult(sessions: [SubSessionInfo(id: id, name: "Release", status: "done", link: "hangar://task/x", agent: .claude, message: "a\nb")])
        let data = try! JSONEncoder().encode(wait)
        let text = formatHuman(.tasksWait(sessions: [], parent: nil, timeout: 1), result: data)
        #expect(text == "\(id.uuidString.lowercased().prefix(8))  done  Release  hangar://task/x\n    a\n    b")
    }
}
