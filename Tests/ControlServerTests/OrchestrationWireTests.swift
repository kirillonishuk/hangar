import Foundation
import Testing
@testable import ControlServer

/// `sessions_note` and `tabs_wait` over the CLI, MCP and the socket.
@Suite struct OrchestrationWireTests {
    let caller = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    @Test func cliGrammar() {
        let me = caller.lowercased()
        let table: [([String], CLIParse)] = [
            (["sessions", "note", "Task", "3/7"], .call(.tasksNote(task: me, note: "Task 3/7"), json: false)),
            (["sessions", "note", "", "--session", "s1"], .call(.tasksNote(task: "s1", note: nil), json: false)),
            (["tabs", "wait", "--tab", "ab12"], .call(.tabsWait(tab: "ab12", for: .any, timeout: ControlMethod.waitDefaultSeconds), json: false)),
            (["tabs", "wait", "--tab", "ab12", "--for", "idle", "--timeout", "30", "--json"], .call(.tabsWait(tab: "ab12", for: .idle, timeout: 30), json: true)),
        ]
        for (args, expected) in table { #expect(parseCLI(args, cwd: "/tmp", callerLeaf: me) == expected, "\(args)") }
        for args in [["sessions", "note"], ["tabs", "wait"], ["tabs", "wait", "--tab", "a", "--for", "done"], ["tabs", "wait", "--tab", "a", "--timeout", "0"],
                     ["sessions", "note", String(repeating: "x", count: 1025)]] {
            guard case .usage = parseCLI(args, cwd: "/tmp", callerLeaf: me) else { Issue.record("accepted \(args)"); continue }
        }
        guard case .usage = parseCLI(["sessions", "note", "x"], cwd: "/tmp") else { Issue.record("no caller"); return }
        #expect(requestTimeout(.tabsWait(tab: "a", for: .any, timeout: 100)) == 115)
    }

    /// Untrusted text: one line, no control or invisible characters, capped.
    @Test func noteSanitising() {
        #expect(ControlCall.noteText("  Task\n3/7\t·\u{1B}[1;31m round\u{202E} 2\u{1B}]0;title\u{07}  ") == "Task 3/7 · round 2")
        #expect(ControlCall.noteText(" \n\t ") == nil)
        #expect(ControlCall.noteText("") == nil)
        let long = ControlCall.noteText(String(repeating: "я", count: 300))
        #expect(long?.count == ControlMethod.maxNoteChars && long?.hasSuffix("…") == true)
    }

    @Test func socketValidation() {
        func decode(_ method: String, _ json: String) -> Result<ControlCall, ControlError> {
            ControlCall.decode(method: method, params: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
        }
        #expect(decode("tasks.note", #"{"note":"a\nb","task":"t"}"#) == .success(.tasksNote(task: "t", note: "a b")))
        #expect(decode("tasks.note", #"{"note":""}"#) == .success(.tasksNote(task: nil, note: nil)))
        #expect(decode("tabs.wait", #"{"tab":"x","for":"waiting","timeout":5}"#) == .success(.tabsWait(tab: "x", for: .waiting, timeout: 5)))
        for (m, bad) in [("tasks.note", "{}"), ("tasks.note", #"{"note":1}"#), ("tasks.note", "{\"note\":\"\(String(repeating: "x", count: 1025))\"}"),
                         ("tabs.wait", "{}"), ("tabs.wait", #"{"tab":"x","for":"done"}"#), ("tabs.wait", #"{"tab":"x","timeout":0}"#)] {
            guard case .failure = decode(m, bad) else { Issue.record("accepted \(m) \(bad)"); continue }
        }
    }

    @Test func mcpFillsCallerAndTimeout() {
        var calls: [ControlCall] = []
        func run(client: String?, _ name: String, _ args: String, caller: String? = nil) -> ControlCall? {
            var s = MCPSession(callerLeaf: caller ?? self.caller) { calls.append($0); return .success(Data("{}".utf8)) }
            if let client {
                _ = s.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"\#(client)"}}}"#.utf8))
            }
            _ = s.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#.utf8))
            return calls.popLast()
        }
        let me = caller.lowercased()
        #expect(run(client: "claude-code", "sessions_note", #"{"note":"Round 2"}"#) == .tasksNote(task: me, note: "Round 2"))
        #expect(run(client: "claude-code", "sessions_note", #"{"note":"x","session":"other"}"#) == .tasksNote(task: "other", note: "x"))
        #expect(run(client: "claude-code", "tabs_wait", #"{"tab":"t"}"#) == .tabsWait(tab: "t", for: .any, timeout: 110))
        #expect(run(client: "codex-mcp-client", "tabs_wait", #"{"tab":"t","for":"idle"}"#) == .tabsWait(tab: "t", for: .idle, timeout: 50))
    }

    @Test func humanOutput() throws {
        let r = TabWaitResult(tab: UUID(), leaf: UUID(), status: "done", message: "ok\nfine")
        #expect(formatHuman(.tabsWait(tab: "t", for: .any, timeout: 1), result: try JSONEncoder().encode(r)) == "done\n    ok\n    fine")
        #expect(formatHuman(.tasksNote(task: nil, note: nil), result: try JSONEncoder().encode(NoteResult(task: UUID(), note: nil))) == "note cleared")
    }
}
