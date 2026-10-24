import Foundation
import Testing
@testable import ControlServer

private final class FakeApp {
    var calls: [ControlCall] = []
    var reply: Result<Data, ControlError> = .success(Data("{}".utf8))
}

private func session(_ app: FakeApp) -> MCPSession {
    MCPSession { call in
        app.calls.append(call)
        return app.reply
    }
}

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    #expect(!data.contains(0x0A))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func line(_ s: String) -> Data { Data(s.utf8) }

private func call(_ name: String, _ arguments: String, id: Int = 5) -> Data {
    line(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
}

private func toolResult(_ r: [String: Any]) -> (text: String?, isError: Bool?) {
    let result = r["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    #expect(content?.first?["type"] as? String == "text")
    return (content?.first?["text"] as? String, result?["isError"] as? Bool)
}

@Suite struct MCPTests {
    @Test func initializeHandshake() throws {
        let app = FakeApp()
        var s = session(app)
        let r = try object(s.handle(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)))
        #expect(r["jsonrpc"] as? String == "2.0")
        #expect(r["id"] as? Int == 1)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] is [String: Any])
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "hangar")
        #expect((result["serverInfo"] as? [String: Any])?["version"] is String)

        let old = try object(s.handle(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)))
        #expect((old["result"] as? [String: Any])?["protocolVersion"] as? String == "2024-11-05")
        let future = try object(s.handle(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{}}}"#)))
        #expect((future["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")

        #expect(s.handle(line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)) == nil)
        #expect(s.handle(line(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)) == line(#"{"jsonrpc":"2.0","id":2,"result":{}}"#))
        #expect(app.calls.isEmpty)
    }

    @Test func toolsListMatchesMethods() throws {
        var s = session(FakeApp())
        let r = try object(s.handle(line(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)))
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["projects_list", "projects_add", "tasks_list", "tasks_create", "tabs_open", "tabs_send", "tabs_read", "tasks_archive", "ssh_open"])
        var byName: [String: [String: Any]] = [:]
        for t in tools {
            let schema = try #require(t["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            #expect(schema["properties"] is [String: Any])
            #expect(schema["required"] is [String])
            #expect(t["description"] is String)
            byName[t["name"] as! String] = schema
        }
        #expect(byName["tasks_archive"]?["required"] as? [String] == ["task", "yes"])
        #expect(byName["projects_list"]?["required"] as? [String] == [])
        #expect(byName["projects_add"]?["required"] as? [String] == ["path"])
        let host = (byName["projects_add"]?["properties"] as? [String: Any])?["host"] as? [String: Any]
        #expect(host?["type"] as? String == "string")
        let send = byName["tabs_send"]?["properties"] as? [String: Any]
        let keys = send?["keys"] as? [String: Any]
        #expect(keys?["type"] as? String == "array")
        #expect(keys?["maxItems"] as? Int == 32)
        #expect((keys?["items"] as? [String: Any])?["enum"] as? [String] == SendKey.allCases.map(\.rawValue))
        #expect((send?["text"] as? [String: Any])?["maxLength"] as? Int == ControlMethod.maxText)
        for tool in ["tabs_send", "tabs_read"] {
            let tab = (byName[tool]?["properties"] as? [String: Any])?["tab"] as? [String: Any]
            #expect((tab?["description"] as? String)?.contains("drawer") == true, "\(tool)")
        }
        let lines = (byName["tabs_read"]?["properties"] as? [String: Any])?["lines"] as? [String: Any]
        #expect(lines?["type"] as? String == "integer")
        #expect(lines?["minimum"] as? Int == 1)
        #expect(lines?["maximum"] as? Int == 5000)
        let kind = (byName["tabs_open"]?["properties"] as? [String: Any])?["kind"] as? [String: Any]
        #expect(kind?["enum"] as? [String] == TabKind.allCases.map(\.rawValue))
        let yes = (byName["tasks_archive"]?["properties"] as? [String: Any])?["yes"] as? [String: Any]
        #expect(yes?["type"] as? String == "boolean")
        let force = (byName["tasks_archive"]?["properties"] as? [String: Any])?["force"] as? [String: Any]
        #expect(force?["type"] as? String == "boolean")
    }

    @Test func toolsCallSuccess() throws {
        let app = FakeApp()
        app.reply = .success(Data(#"{"tasks":[]}"#.utf8))
        var s = session(app)
        let r = try object(s.handle(call("tasks_list", "{}")))
        #expect(r["id"] as? Int == 5)
        let (text, isError) = toolResult(r)
        #expect(text == #"{"tasks":[]}"#)
        #expect(isError == false)
        #expect(app.calls == [.tasksList(project: nil)])
        // `arguments` may be omitted entirely.
        _ = try object(s.handle(line(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"projects_list"}}"#)))
        #expect(app.calls.last == .projectsList)
    }

    @Test func toolsCallErrors() throws {
        let app = FakeApp()
        var s = session(app)
        let noYes = toolResult(try object(s.handle(call("tasks_archive", #"{"task":"t"}"#))))
        #expect(noYes.isError == true)
        #expect(noYes.text?.contains("yes: true") == true)
        #expect(app.calls.isEmpty)

        let badLines = toolResult(try object(s.handle(call("tabs_read", #"{"tab":"x","lines":"5"}"#))))
        #expect(badLines.isError == true)
        let extra = toolResult(try object(s.handle(call("tasks_list", #"{"frob":1}"#))))
        #expect(extra.isError == true)
        #expect(app.calls.isEmpty)

        app.reply = .failure(ControlError(code: .notRunning, message: "Hangar is not running"))
        let down = toolResult(try object(s.handle(call("projects_list", "{}"))))
        #expect(down.isError == true)
        #expect(down.text == "Hangar is not running")
        #expect(app.calls == [.projectsList])

        let unknown = try object(s.handle(call("tabs_close", #"{"tab":"x"}"#)))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(unknown["result"] == nil)
        let notObject = try object(s.handle(call("tasks_list", "[1]")))
        #expect((notObject["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(app.calls.count == 1)
    }

    @Test func protocolErrors() throws {
        var s = session(FakeApp())
        let parse = try object(s.handle(line("not json")))
        #expect(parse["jsonrpc"] as? String == "2.0")
        #expect(parse["id"] is NSNull)
        #expect((parse["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect((parse["error"] as? [String: Any])?["message"] is String)

        let batch = try object(s.handle(line(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)))
        #expect((batch["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(batch["id"] is NSNull)
        let scalar = try object(s.handle(line("42")))
        #expect((scalar["error"] as? [String: Any])?["code"] as? Int == -32600)
        let noMethod = try object(s.handle(line(#"{"jsonrpc":"2.0","id":9}"#)))
        #expect((noMethod["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(noMethod["id"] as? Int == 9)

        let unknown = try object(s.handle(line(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(unknown["id"] as? Int == 4)
        // Unknown notifications are ignored.
        #expect(s.handle(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#)) == nil)

        let stringID = try object(s.handle(line(#"{"jsonrpc":"2.0","id":"a1","method":"ping"}"#)))
        #expect(stringID["id"] as? String == "a1")

        let huge = line(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":""# + String(repeating: "a", count: maxMCPLine) + #""}}"#)
        let tooLarge = try object(s.handle(huge))
        #expect((tooLarge["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(tooLarge["id"] is NSNull)
    }

    /// The CLI lives at X.app/Contents/Helpers/hangar; its version is the app's.
    @Test func appVersionFromEnclosingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("X.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let exe = contents.appendingPathComponent("Helpers/hangar")
        try Data().write(to: exe)
        #expect(MCPSession.appVersion(executable: exe) == "dev")  // no Info.plist
        try (["CFBundleShortVersionString": "1.2.3"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        #expect(MCPSession.appVersion(executable: exe) == "1.2.3")
        // Through a symlink on PATH, as an installed CLI is.
        let link = root.appendingPathComponent("hangar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
        #expect(MCPSession.appVersion(executable: link) == "1.2.3")
        #expect(MCPSession.appVersion(executable: root.appendingPathComponent("bin/hangar")) == "dev")
    }
}
