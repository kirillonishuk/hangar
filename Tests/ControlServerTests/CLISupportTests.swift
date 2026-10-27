import Foundation
import Testing
import AgentStatus
@testable import ControlServer

@Suite struct CLISupportTests {
    let tab = UUID(), leaf = UUID()
    var env: [String: String] { ["HANGAR_TAB_ID": tab.uuidString, "HANGAR_LEAF_ID": leaf.uuidString] }

    static let statusFixture = Data("""
    {"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1760000000},\
    "seven_day":{"used_percentage":10,"resets_at":1760500000},\
    "seven_day_opus":{"used_percentage":3.5,"resets_at":1760600000},"note":"text"}}
    """.utf8)

    @Test func statuslineWindowsFixture() {
        #expect(statuslineWindows(Self.statusFixture) == [
            WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000),
            WireWindow(name: "seven_day", usedPercent: 10, resetsAt: 1_760_500_000),
            WireWindow(name: "seven_day_opus", usedPercent: 3.5, resetsAt: 1_760_600_000),
        ])
    }

    @Test func statuslineBeforeFirstResponse() {
        #expect(statuslineWindows(Data(#"{"model":{"id":"x"}}"#.utf8)) == [])
        #expect(statuslineWindows(Data("garbage".utf8)) == [])
        #expect(statuslineWindows(Data()) == [])
    }

    @Test func statuslineKeepsOnlyWireValidWindows() {
        let data = Data(#"{"rate_limits":{"Bad-Name":{"used_percentage":1},"empty":{},"ok":{"used_percentage":5}}}"#.utf8)
        #expect(statuslineWindows(data) == [WireWindow(name: "ok", usedPercent: 5, resetsAt: nil)])
    }

    @Test func permissionRequestPayloadCarriesToolAndCommand() {
        let payload = Data(#"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"}}"#.utf8)
        let m = eventMessage(kind: "permission-request", tab: tab, leaf: leaf, args: [], payload: payload)
        #expect(m?.kind == .permissionRequest && m?.tool == "Bash" && m?.command == "rm -rf node_modules" && m?.session == "s1")
        let notBash = Data(#"{"tool_name":"mcp__x__y","tool_input":{"command":42}}"#.utf8)
        let n = eventMessage(kind: "permission-request", tab: tab, leaf: leaf, args: [], payload: notBash)
        #expect(n?.tool == "mcp__x__y" && n?.command == nil)
        let tooled = eventMessage(kind: "tool", tab: tab, leaf: leaf, args: [], payload: Data(#"{"tool_input":"x"}"#.utf8))
        #expect(tooled?.tool == nil && tooled?.command == nil)
    }

    @Test func stopTextComesFromLastAssistantMessage() {
        let stop = eventMessage(kind: "stop", tab: tab, leaf: leaf, args: [], payload: Data(#"{"last_assistant_message":"Готово"}"#.utf8))
        #expect(stop?.message == "Готово")
        let both = eventMessage(kind: "notification", tab: tab, leaf: leaf, args: [],
                                payload: Data(#"{"message":"M","last_assistant_message":"L"}"#.utf8))
        #expect(both?.message == "M")
    }

    @Test func stopFailureCarriesErrorType() {
        let m = eventMessage(kind: "stop-failure", tab: tab, leaf: leaf, args: [],
                             payload: Data(#"{"error":"overloaded","last_assistant_message":"API Error"}"#.utf8))
        #expect(m?.kind == .stopFailure && m?.error == "overloaded" && m?.message == "API Error")
    }

    @Test func hookDetailFieldsAreBounded() {
        func decoded(_ json: String) -> EventMessage? {
            guard case let .success(.event(m)) = ControlMessage.decode(Data(json.utf8)) else { return nil }
            return m
        }
        let base = #"{"v":1,"type":"event","tab":"\#(tab.uuidString)","leaf":"\#(leaf.uuidString)","kind":"permission-request""#
        let long = String(repeating: "x", count: 65), ok = String(repeating: "x", count: 64)
        #expect(decoded(base + #","tool":"\#(ok)","error":"\#(ok)"}"#)?.tool == ok)
        let over = decoded(base + #","tool":"\#(long)","error":"\#(long)","command":"\#(String(repeating: "c", count: 900))"}"#)
        #expect(over != nil && over?.tool == nil && over?.error == nil && over?.command?.count == 500)
    }

    @Test func hugePayloadsAreBoundedAtTheSource() {
        let big = String(repeating: "я", count: 100_000)
        for (kind, json) in [("stop", #"{"last_assistant_message":"\#(big)"}"#),
                             ("permission-request", #"{"tool_name":"Bash","tool_input":{"command":"\#(big)"}}"#)] {
            guard let m = eventMessage(kind: kind, tab: tab, leaf: leaf, args: [], payload: Data(json.utf8)) else { Issue.record("nil"); continue }
            let line = ControlMessage.event(m).encoded()
            #expect(line.count < ControlServer.maxLine / 4)
            #expect(ControlMessage.decode(line.dropLast()) == .success(.event(m)))
            #expect((m.message ?? m.command)?.count == 500)
        }
    }

    @Test func eventFields() {
        let stdin = Data("""
        {"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt",\
        "message":"Claude needs your permission to use Bash","cwd":"/x","transcript_path":"/t"}
        """.utf8)
        let m = eventMessage(kind: "notification", args: [], env: env, stdin: stdin)
        #expect(m == EventMessage(tab: tab, leaf: leaf, kind: .notification, session: "s1",
                                  notificationType: "permission_prompt", message: "Claude needs your permission to use Bash"))
        let over = eventMessage(kind: "notification", args: ["--session", "s2"], env: env, stdin: stdin)
        #expect(over?.session == "s2")
    }

    @Test func sessionStartSource() {
        let stdin = Data(#"{"session_id":"s1","hook_event_name":"SessionStart","source":"clear"}"#.utf8)
        let m = eventMessage(kind: "session-start", args: [], env: env, stdin: stdin)
        #expect(m == EventMessage(tab: tab, leaf: leaf, kind: .sessionStart, session: "s1", source: "clear"))
    }

    @Test func eventEdgeCases() {
        #expect(eventMessage(kind: "boom", args: [], env: env, stdin: nil) == nil)
        #expect(eventMessage(kind: "stop", args: [], env: ["HANGAR_TAB_ID": tab.uuidString], stdin: nil) == nil)
        #expect(eventMessage(kind: "stop", args: [], env: ["HANGAR_TAB_ID": "x", "HANGAR_LEAF_ID": leaf.uuidString], stdin: nil) == nil)
        let bare = eventMessage(kind: "stop", args: [], env: env, stdin: Data("not json".utf8))
        #expect(bare == EventMessage(tab: tab, leaf: leaf, kind: .stop))
        let bad = eventMessage(kind: "stop", args: ["--session", "bad id!"], env: env, stdin: nil)
        #expect(bad?.session == nil)
    }

    static let codexPayload = #"{"type":"agent-turn-complete","thread-id":"t1","turn-id":"u1","cwd":"/x","input-messages":["hi"],"last-assistant-message":"ok"}"#

    @Test func codexPayloadFromArgv() {
        let m = eventMessage(kind: "codex-notify", args: [Self.codexPayload], env: env, stdin: nil)
        #expect(m == EventMessage(tab: tab, leaf: leaf, kind: .codexNotify, session: "t1", message: "ok"))
        let other = #"{"type":"other","thread-id":"t1"}"#
        #expect(eventMessage(kind: "codex-notify", args: [other], env: env, stdin: nil) == nil)
    }

    @Test func chainedArgvBetweenThenAndPayload() {
        #expect(chainedArgv(["--then", "/bin/echo", "a", Self.codexPayload]) == ["/bin/echo", "a"])
        #expect(chainedArgv([Self.codexPayload]) == nil)
        #expect(chainedArgv(["--then", Self.codexPayload]) == nil)
    }
}
