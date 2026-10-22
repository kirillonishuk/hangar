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

    @Test func sessionStartSourceOnWire() {
        let m = ControlMessage.event(EventMessage(tab: UUID(), leaf: UUID(), kind: .sessionStart, session: "s1", source: "clear"))
        #expect(String(decoding: m.encoded(), as: UTF8.self).contains(#""source":"clear""#))
        #expect(ControlMessage.decode(m.encoded().dropLast()) == .success(m))
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
        #expect(ControlMessage.decode(ev(#","source":"\#(String(repeating: "s", count: 65))""#)) == .failure(.badField))
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

    @Test func resetsAtClampedTo30Days() {
        let far = Date().timeIntervalSince1970 + 365 * 86_400
        let r = ControlMessage.decode(line(#"{"v":1,"type":"usage","agent":"claude","windows":[{"name":"w","resetsAt":\#(far)}]}"#))
        guard case let .success(.usage(u)) = r, let got = u.windows.first?.resetsAt else { Issue.record("\(r)"); return }
        let cap = Date().timeIntervalSince1970 + 30 * 86_400
        #expect(got <= cap && got > cap - 60)
    }

    // MARK: requests

    private func decode(_ method: String, _ json: String) -> Result<ControlCall, ControlError> {
        let params = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return ControlCall.decode(method: method, params: params)
    }

    private func badParams(_ method: String, _ json: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .failure(e) = decode(method, json) else {
            Issue.record("accepted \(method) \(json.prefix(80))", sourceLocation: sourceLocation); return
        }
        #expect(e.code == .badParams, sourceLocation: sourceLocation)
    }

    @Test func requestRoundTrip() {
        let calls: [ControlCall] = [
            .projectsList, .projectsAdd(path: "/tmp/p"), .tasksList(project: nil), .tasksList(project: "app"),
            .tasksCreate(project: "app", name: "Fix", worktree: false, base: nil, prompt: nil),
            .tasksCreate(project: "app", name: "Fix", worktree: true, base: "main", prompt: "go"),
            .tabsOpen(task: "t1", kind: .shell, prompt: nil), .tabsOpen(task: "t1", kind: .claude, prompt: "hi"),
            .tabsSend(tab: "ab12", text: "ls", keys: [.enter, .ctrlC]), .tabsSend(tab: "ab12", text: nil, keys: [.up]),
            .tabsRead(tab: "ab12", lines: 100), .tasksArchive(task: "t1"),
        ]
        #expect(Set(calls.map(\.method)) == Set(ControlMethod.allCases))
        for call in calls {
            let params = (try? JSONSerialization.jsonObject(with: call.paramsJSON())) as? [String: Any]
            #expect(params != nil)
            #expect(ControlCall.decode(method: call.method.rawValue, params: params ?? [:]) == .success(call))
        }
        for call in calls {
            let wire = ControlMessage.request(ControlRequest(id: 42, call: .success(call))).encoded()
            #expect(ControlMessage.decode(wire.dropLast()) == .success(.request(ControlRequest(id: 42, call: .success(call)))))
        }
        let parsed = ControlMessage.decode(line(#"{"v":1,"id":7,"method":"tasks.list","params":{}}"#))
        #expect(parsed == .success(.request(ControlRequest(id: 7, call: .success(.tasksList(project: nil))))))
        #expect(ControlMethod.tabsSend.toolName == "tabs_send")
    }

    @Test func unknownMethodKeepsId() {
        let parsed = ControlMessage.decode(line(#"{"v":1,"id":7,"method":"tabs.close","params":{}}"#))
        guard case let .success(.request(r)) = parsed, case let .failure(e) = r.call else { Issue.record("not a request failure"); return }
        #expect(r.id == 7 && e.code == .unknownMethod)
    }

    @Test func paramsValidated() {
        let big = String(repeating: "a", count: 32_769)
        badParams("tasks.archive", #"{"task":"t","yes":true,"force":1}"#)
        badParams("tasks.create", #"{"project":"p"}"#)
        badParams("tabs.read", #"{"tab":"t","lines":"5"}"#)
        badParams("tabs.read", #"{"tab":"t","lines":0}"#)
        badParams("tabs.read", #"{"tab":"t","lines":5001}"#)
        badParams("tabs.send", #"{"tab":"t","text":"a\u0000b"}"#)
        badParams("tabs.send", #"{"tab":"t","text":"\#(big)"}"#)
        badParams("tabs.open", #"{"task":"t","kind":"diff"}"#)
        badParams("tabs.send", #"{"tab":"t","keys":["f13"]}"#)
        badParams("tabs.send", #"{"tab":"t","keys":[\#(Array(repeating: "\"enter\"", count: 33).joined(separator: ","))]}"#)
        badParams("tasks.create", #"{"project":"p","name":"  "}"#)
        badParams("tasks.create", #"{"project":"p","name":"a\nb"}"#)
        badParams("projects.add", #"{"path":"rel/dir"}"#)
        badParams("tasks.create", #"{"project":"p","name":"n","base":"main"}"#)
        badParams("tasks.create", #"{"project":"p","name":"n","worktree":false,"base":"main"}"#)
        badParams("tabs.open", #"{"task":"t","kind":"shell","prompt":"x"}"#)
        badParams("tabs.send", #"{"tab":"t"}"#)
        badParams("tabs.send", #"{"tab":"t","keys":[]}"#)
        badParams("tasks.create", #"{"project":"p","name":true}"#)
        badParams("tasks.create", #"{"project":"p","name":"n","worktree":1}"#)
        badParams("projects.list", #"{"x":1}"#)
        #expect(decode("tabs.read", #"{"tab":"t"}"#) == .success(.tabsRead(tab: "t", lines: 100)))
        #expect(decode("tasks.create", #"{"project":"p","name":" n "}"#) == .success(.tasksCreate(project: "p", name: "n", worktree: false, base: nil, prompt: nil)))
    }

    @Test func archiveNeedsYes() {
        for json in [#"{"task":"t"}"#, #"{"task":"t","yes":false}"#] {
            guard case let .failure(e) = decode("tasks.archive", json) else { Issue.record("accepted"); continue }
            #expect(e.code == .confirmRequired)
        }
        #expect(decode("tasks.archive", #"{"task":"t","yes":true}"#) == .success(.tasksArchive(task: "t")))
        #expect(String(decoding: ControlCall.tasksArchive(task: "t").paramsJSON(), as: UTF8.self).contains(#""yes":true"#))
    }

    @Test func missingIdIsBadRequest() {
        for l in [#"{"v":1,"method":"projects.list","params":{}}"#, #"{"v":1,"id":"7","method":"projects.list"}"#,
                  #"{"v":1,"id":-1,"method":"projects.list"}"#, #"{"v":1,"id":1.5,"method":"projects.list"}"#,
                  #"{"v":1,"id":9007199254740993,"method":"projects.list"}"#] {
            #expect(ControlMessage.decode(line(l)) == .failure(.badRequest))
        }
        #expect(ControlMessage.decode(line(#"{"v":2,"id":1,"method":"projects.list"}"#)) == .failure(.badVersion))
        #expect(ControlMessage.decode(line(#"{"v":1,"id":1,"method":"projects.list","params":[]}"#)) == .failure(.badRequest))
    }

    @Test func responseEncoding() {
        let u = UUID(uuidString: tab)!
        let ok = String(decoding: ControlResponse.ok(3, ArchiveResult(task: u, archived: true)).encoded(), as: UTF8.self)
        #expect(ok.hasSuffix("\n") && ok.dropLast().contains("\n") == false)
        #expect(ok.hasPrefix(#"{"id":3,"result":{"#) && ok.contains(#""archived":true"#) && ok.contains(tab))
        let err = ControlResponse(id: 3, body: .failure(ControlError(code: .notFound, message: #"no task "x""#)))
        #expect(String(decoding: err.encoded(), as: UTF8.self) == #"{"id":3,"error":{"code":"not-found","message":"no task \"x\""}}"# + "\n")
        let nilId = ControlResponse(id: nil, body: .failure(ControlError(code: .badRequest, message: "m")))
        #expect(String(decoding: nilId.encoded(), as: UTF8.self).hasPrefix(#"{"id":null,"error":"#))
    }

    @Test func strictVersionAndShapes() {
        for v in ["true", "1.0", #""1""#] {
            #expect(ControlMessage.decode(line(#"{"v":\#(v),"id":1,"method":"projects.list"}"#)) == .failure(.badVersion))
        }
    }

    @Test func pastedTextLosesControlCharacters() {
        // ESC would end the bracketed paste early ("\u{1B}[201~"); keys go through `keys`.
        #expect(decode("tabs.send", #"{"tab":"t","text":"a\u001b[201~b\u0003c\td\ne\rf"}"#)
                == .success(.tabsSend(tab: "t", text: "a[201~bc\td\ne\rf", keys: [])))
        badParams("tabs.send", #"{"tab":"t","text":"\u001b"}"#)
        #expect(decode("tabs.send", #"{"tab":"t","text":"\u001b","keys":["enter"]}"#) == .success(.tabsSend(tab: "t", text: nil, keys: [.enter])))
    }

    @Test func nameRejectsInvisibleSeparators() {
        for c in ["\\u2028", "\\u2029", "\\u202e", "\\u202a", "\\u2066", "\\u2069"] {
            badParams("tasks.create", #"{"project":"p","name":"a\#(c)b"}"#)
        }
    }

    @Test func moreValidation() {
        badParams("tasks.list", #"{"project":""}"#)
        badParams("projects.add", #"{"path":"/a\u0000b"}"#)
        badParams("tasks.list", #"{"project":"a\u0000b"}"#)
        badParams("tasks.create", #"{"project":"p","name":"n","prompt":"a\u0000b"}"#)
        badParams("tasks.list", #"{"project":{"a":1}}"#)
        badParams("tasks.list", #"{"project":["a"]}"#)
        badParams("tabs.open", #"{"task":"t","kind":5}"#)
        badParams("tabs.read", #"{"tab":"t","lines":1.5}"#)
        badParams("tabs.read", #"{"tab":"t","lines":99999999999999999999}"#)
        badParams("tabs.send", #"{"tab":"t","keys":[1]}"#)
        badParams("tabs.send", #"{"tab":"t","keys":"enter"}"#)
        #expect(decode("tabs.read", #"{"tab":"t","lines":null}"#) == .success(.tabsRead(tab: "t", lines: 100)))
        #expect(decode("tasks.list", #"{"project":null}"#) == .success(.tasksList(project: nil)))
    }
}
