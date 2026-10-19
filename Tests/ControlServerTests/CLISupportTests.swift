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
