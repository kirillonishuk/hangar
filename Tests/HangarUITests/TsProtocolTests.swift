import Foundation
import Testing
@testable import HangarUI

/// tsserver's stdout is untrusted: framing, size limits, JSON validation, unknown messages ignored (#NN-tsserver).
@Suite struct TsProtocolTests {
    private func frame(_ json: String) -> Data {
        // As tsserver writes it: the length counts the trailing newline.
        Data("Content-Length: \(json.utf8.count + 1)\r\n\r\n\(json)\n".utf8)
    }

    @Test func oneMessage() {
        var f = TsFramer()
        let out = f.feed(frame(#"{"seq":0,"type":"event","event":"typingsInstallerPid"}"#))
        #expect(out.count == 1)
        #expect(out.first?["event"] as? String == "typingsInstallerPid")
    }

    @Test func messageSplitAcrossChunksAndSeveralInOne() {
        var f = TsFramer()
        let a = frame(#"{"type":"response","request_seq":1,"success":true,"body":{"x":"é ✓"}}"#)
        let b = frame(#"{"type":"response","request_seq":2,"success":false}"#)
        let all = a + b
        var got: [[String: Any]] = []
        // Byte by byte through the header and a multi-byte character.
        for i in 0..<20 { got += f.feed(all.subdata(in: i..<(i + 1))) }
        got += f.feed(all.subdata(in: 20..<all.count))
        #expect(got.count == 2)
        #expect((got[0]["body"] as? [String: Any])?["x"] as? String == "é ✓")
        #expect(got[1]["request_seq"] as? Int == 2)
    }

    @Test func oversizedMessageIsSkippedAndTheNextOneStillParses() {
        var f = TsFramer(maxMessage: 64)
        let big = "{\"pad\":\"" + String(repeating: "a", count: 500) + "\"}"
        let out = f.feed(frame(big) + frame(#"{"seq":3,"type":"event","event":"ok"}"#))
        #expect(out.count == 1)
        #expect(out.first?["event"] as? String == "ok")
    }

    @Test func garbageAndInvalidJSONAreDropped() {
        var f = TsFramer()
        var data = Data("node: warning something\r\n\r\n".utf8)          // a header block without Content-Length
        data += Data("Content-Length: 5\r\n\r\nnope\n".utf8)              // not JSON
        data += Data("Content-Length: 3\r\n\r\n[]\n".utf8)                // JSON, not an object
        data += Data("Content-Length: abc\r\n\r\n".utf8)                  // bad length
        data += frame(#"{"type":"event","event":"fine"}"#)
        let out = f.feed(data)
        #expect(out.count == 1)
        #expect(out.first?["event"] as? String == "fine")
    }

    @Test func endlessHeaderIsCut() {
        var f = TsFramer()
        _ = f.feed(Data(String(repeating: "x", count: 10_000).utf8))
        let out = f.feed(frame(#"{"type":"event","event":"after"}"#))
        #expect(out.count == 1)
        #expect(f.buffered < 2048)
    }

    @Test func classifiesResponsesAndEvents() {
        #expect(TsMessage(["type": "response", "request_seq": 4, "success": true, "body": ["a": 1]])
                == .response(requestSeq: 4, success: true))
        #expect(TsMessage(["type": "event", "event": "semanticDiag", "body": ["file": "/a.ts"]]) == .event("semanticDiag"))
        #expect(TsMessage(["type": "response", "request_seq": "4", "success": true]) == nil)
        #expect(TsMessage(["type": "event"]) == nil)
        #expect(TsMessage(["type": "request", "seq": 1]) == nil)
    }

    @Test func requestIsOneJSONLine() throws {
        let line = try #require(tsRequestLine(seq: 7, command: "quickinfo", arguments: ["file": "/r/a\nb.ts", "line": 1]))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["seq"] as? Int == 7)
        #expect(object["type"] as? String == "request")
        #expect(object["command"] as? String == "quickinfo")
        #expect((object["arguments"] as? [String: Any])?["file"] as? String == "/r/a\nb.ts")
    }
}
