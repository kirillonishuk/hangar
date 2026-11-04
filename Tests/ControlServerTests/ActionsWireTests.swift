import Foundation
import Testing
@testable import ControlServer

/// `actions list|run` over the CLI, MCP and the socket (#131).
@Suite struct ActionsWireTests {
    let me = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test func cliGrammar() {
        let table: [([String], CLIParse)] = [
            (["actions", "list"], .call(.actionsList(task: me), json: false)),
            (["actions", "list", "--session", "web", "--json"], .call(.actionsList(task: "web"), json: true)),
            (["actions", "run", "--name", "Dev server"], .call(.actionsRun(task: me, name: "Dev server"), json: false)),
            (["actions", "run", "--session", "s", "--name", "Test"], .call(.actionsRun(task: "s", name: "Test"), json: false)),
            (["actions", "run"], .usage("missing --name")),
            (["actions", "run", "--name", "x", "extra"], .usage("unexpected argument \"extra\"")),
            (["actions", "stop", "--name", "x"], .usage("unknown command \"actions stop\"")),
        ]
        for (args, expected) in table { #expect(parseCLI(args, cwd: "/tmp", callerLeaf: me) == expected, "\(args)") }
        // Outside a Hangar terminal the session must be named.
        #expect(parseCLI(["actions", "list"], cwd: "/tmp") == .usage("not inside a Hangar chat: pass --session"))
        #expect(parseCLI(["actions", "run", "--name", "x"], cwd: "/tmp") == .usage("not inside a Hangar chat: pass --session"))
    }

    @Test func socketValidation() {
        func decode(_ method: String, _ json: String) -> Result<ControlCall, ControlError> {
            ControlCall.decode(method: method, params: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
        }
        #expect(decode("actions.run", #"{"task":"t","name":" Lint "}"#) == .success(.actionsRun(task: "t", name: "Lint")))
        for bad in [#"{"task":"t"}"#, #"{"task":"t","name":"  "}"#, #"{"task":"t","name":3}"#, #"{"name":"x"}"#, #"{"task":"t","name":"x","yes":true}"#] {
            guard case .failure(let e) = decode("actions.run", bad) else { Issue.record("accepted \(bad)"); continue }
            #expect(e.code == .badParams, "\(bad)")
        }
        guard case .failure = decode("actions.list", "{}") else { Issue.record("list without a session"); return }
    }

    /// `hangar mcp` fills in the calling chat; `session` is the listed name of the session parameter.
    @Test func mcpFillsCaller() throws {
        var calls: [ControlCall] = []
        var s = MCPSession(callerLeaf: me.uppercased()) { calls.append($0); return .success(Data("{}".utf8)) }
        func call(_ name: String, _ args: String) {
            _ = s.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#.utf8))
        }
        call("actions_list", "{}")
        call("actions_run", #"{"name":"Dev"}"#)
        call("actions_run", #"{"session":"web","name":"Dev"}"#)
        #expect(calls == [.actionsList(task: me), .actionsRun(task: me, name: "Dev"), .actionsRun(task: "web", name: "Dev")])
    }

    @Test func humanOutput() throws {
        let tab = UUID()
        let list = ActionsResult(task: UUID(), actions: [
            ActionInfo(name: "Dev", command: "pnpm dev", source: "settings", restart: true, approved: true, runningTab: tab),
            ActionInfo(name: "Lint", command: "pnpm lint", source: "repo", restart: true, approved: false, runningTab: nil),
        ], error: "bad entry")
        let text = formatHuman(.actionsList(task: "t"), result: try JSONEncoder().encode(list))
        #expect(text == "Dev  pnpm dev  running in tab \(tab.uuidString.lowercased().prefix(8))\nLint  pnpm lint  (repo, not approved yet)\nwarning: bad entry")
        #expect(formatHuman(.actionsList(task: "t"), result: try JSONEncoder().encode(ActionsResult(task: UUID(), actions: [], error: nil))) == "no actions")
    }
}
