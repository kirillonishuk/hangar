import Foundation
import Testing
import AgentStatus
@testable import ControlServer

private func line(_ s: String) -> Data { Data(s.utf8) }

private let tab = "6F1C2A9E-1B2C-4D5E-8F90-0A1B2C3D4E5F"
private let leaf = "11111111-2222-4333-8444-555555555555"

@Suite struct ProtocolTests {
    @Test func roundTrip() throws {
        let event = ControlMessage.event(EventMessage(
            tab: UUID(), leaf: UUID(), kind: .notification,
            session: "0199a1b2-c3d4", notificationType: "permission_prompt", message: "Claude needs your permission"))
        let usage = ControlMessage.usage(UsageMessage(agent: "claude", windows: [
            WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000),
            WireWindow(name: "seven_day", usedPercent: nil, resetsAt: nil),
        ]))
        for m in [event, usage] {
            let data = m.encoded()
            #expect(data.last == 0x0A)
            #expect(data.dropLast().contains(0x0A) == false)
            #expect(ControlMessage.decode(data.dropLast()) == .success(m))
        }
        let minimal = ControlMessage.event(EventMessage(tab: UUID(), leaf: UUID(), kind: .stop))
        #expect(ControlMessage.decode(minimal.encoded()) == .success(minimal))
        let json = String(decoding: minimal.encoded(), as: UTF8.self)
        #expect(json.contains("\"v\":1") && json.contains("\"type\":\"event\"") && !json.contains("session"))
    }

    @Test func wireFormatFromSpec() {
        let ev = ControlMessage.decode(line(#"{"v":1,"type":"event","tab":"\#(tab)","leaf":"\#(leaf)","kind":"stop","session":"abc"}"#))
        #expect(ev == .success(.event(EventMessage(tab: UUID(uuidString: tab)!, leaf: UUID(uuidString: leaf)!, kind: .stop, session: "abc"))))
        let us = ControlMessage.decode(line(#"{"v":1,"type":"usage","agent":"claude","windows":[{"name":"five_hour","usedPercent":42.5,"resetsAt":1760000000}]}"#))
        #expect(us == .success(.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 42.5, resetsAt: 1_760_000_000)]))))
    }

    @Test func validation() {
        func ev(_ extra: String, tab t: String = tab, kind: String = "stop") -> Data {
            line(#"{"v":1,"type":"event","tab":"\#(t)","leaf":"\#(leaf)","kind":"\#(kind)"\#(extra)}"#)
        }
        func us(agent: String = "claude", windows: String) -> Data {
            line(#"{"v":1,"type":"usage","agent":"\#(agent)","windows":\#(windows)}"#)
        }
        #expect(ControlMessage.decode(line("x")) == .failure(.badJSON))
        #expect(ControlMessage.decode(line("[1]")) == .failure(.badJSON))
        #expect(ControlMessage.decode(line(#"{"v":2,"type":"event"}"#)) == .failure(.badVersion))
        #expect(ControlMessage.decode(line(#"{"type":"event"}"#)) == .failure(.badVersion))
        #expect(ControlMessage.decode(line(#"{"v":1,"type":"tabs"}"#)) == .failure(.unknownType))
        #expect(ControlMessage.decode(ev("", tab: "nope")) == .failure(.badField))
        #expect(ControlMessage.decode(ev("", kind: "boom")) == .failure(.badField))
        #expect(ControlMessage.decode(ev(#","notificationType":"\#(String(repeating: "n", count: 65))""#)) == .failure(.badField))
        #expect(ControlMessage.decode(us(agent: "gpt", windows: "[]")) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":"five_hour","usedPercent":"NaN"}]"#)) == .failure(.badField))
        let nine = "[" + Array(repeating: #"{"name":"w"}"#, count: 9).joined(separator: ",") + "]"
        #expect(ControlMessage.decode(us(windows: nine)) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":"Five-Hour"}]"#)) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":""}]"#)) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":"\#(String(repeating: "a", count: 65))"}]"#)) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":"w","resetsAt":0}]"#)) == .failure(.badField))
        #expect(ControlMessage.decode(us(windows: #"[{"name":"w","resetsAt":8589934592}]"#)) == .failure(.badField))
        #expect(ControlMessage.decode(Data(repeating: 0x20, count: ControlServer.maxLine + 1)) == .failure(.tooLarge))

        #expect(ControlMessage.decode(us(windows: #"[{"name":"five_hour","usedPercent":140}]"#))
            == .success(.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 100, resetsAt: nil)]))))
        #expect(ControlMessage.decode(us(agent: "codex", windows: #"[{"name":"primary","usedPercent":-3}]"#))
            == .success(.usage(UsageMessage(agent: "codex", windows: [WireWindow(name: "primary", usedPercent: 0, resetsAt: nil)]))))
        guard case let .success(.event(m)) = ControlMessage.decode(ev(#","message":"\#(String(repeating: "m", count: 2000))""#)) else {
            Issue.record("long message rejected"); return
        }
        #expect(m.message?.count == 500)
        guard case let .success(.event(bad)) = ControlMessage.decode(ev(#","session":"x; rm -rf ~""#)) else {
            Issue.record("bad session rejected whole message"); return
        }
        #expect(bad.session == nil)
    }
}
