import Foundation
import Testing
@testable import HangarUI

/// JS → Swift messages are untrusted: only well-formed, bounded ones decode (#80).
@Suite struct EditorBridgeTests {
    private func msg(_ json: String) -> BridgeMessage? { BridgeMessage.decode(json) }

    @Test func decodesEachKind() {
        #expect(msg(#"{"type":"ready"}"#) == .ready)
        #expect(msg(#"{"type":"clipboard","action":"paste"}"#) == .clipboard(.paste))
        #expect(msg(#"{"type":"clipboard","action":"selectAll"}"#) == nil)
        #expect(msg(#"{"type":"changed","file":"/r/a.ts","dirty":true}"#) == .changed(file: "/r/a.ts", dirty: true))
        #expect(msg(#"{"type":"save","file":"/r/a.ts","text":"x\ny"}"#) == .save(file: "/r/a.ts", text: "x\ny"))
        #expect(msg(#"{"type":"cursor","file":"/r/a.ts","line":3,"column":7}"#) == .cursor(file: "/r/a.ts", line: 3, column: 7))
        // The tab strip is Hangar's (#83): the page no longer activates or closes files itself.
        #expect(msg(#"{"type":"activate","file":"/r/a.ts"}"#) == nil)
        #expect(msg(#"{"type":"close","file":"/r/a.ts"}"#) == nil)
        #expect(msg(#"{"type":"openAt","line":12,"column":1}"#) == .openAt(line: 12, column: 1))
        #expect(msg(#"{"type":"conflict","file":"/r/a.ts","keepMine":true}"#) == .conflict(file: "/r/a.ts", keepMine: true))
        #expect(msg(#"{"type":"inline","on":true}"#) == .inline(true))
        #expect(msg(#"{"type":"minimap","on":false}"#) == nil)  // the status bar's switch now
        #expect(msg(#"{"type":"request","id":4,"kind":"definition","file":"/r/a.ts","line":2,"column":5}"#)
                == .request(ProviderRequest(id: 4, kind: .definition, file: "/r/a.ts", line: 2, column: 5)))
        #expect(msg(#"{"type":"focus"}"#) == .focus)
        #expect(msg(#"{"type":"openFile","file":"/r/b.ts","line":8,"column":2}"#) == .openFile(file: "/r/b.ts", line: 8, column: 2))
    }

    @Test func rejectsMalformed() {
        let bad = [
            "", "null", "[]", "42", #"{"type":"nope"}"#, #"{"file":"/a"}"#,
            #"{"type":"save","file":"/a"}"#,                         // no text
            #"{"type":"save","file":"/a","text":5}"#,                // wrong type
            #"{"type":"cursor","file":"/a","line":"3","column":1}"#,
            #"{"type":"cursor","file":"/a","line":0,"column":1}"#,   // 1-based
            #"{"type":"cursor","file":"/a","line":1,"column":99999999999}"#,
            #"{"type":"cursor","file":"relative/a","line":1,"column":1}"#,  // paths are absolute
            #"{"type":"cursor","file":"","line":1,"column":1}"#,
            #"{"type":"cursor","file":"/a\u0000b","line":1,"column":1}"#,
            #"{"type":"request","id":-1,"kind":"definition","file":"/a","line":1,"column":1}"#,
            #"{"type":"request","id":1,"kind":"rm -rf","file":"/a","line":1,"column":1}"#,
        ]
        for json in bad { #expect(msg(json) == nil, "\(json)") }
        #expect(BridgeMessage.decode(42 as Any) == nil)          // not a string body
        #expect(BridgeMessage.decode(["type": "ready"] as Any) == nil)
    }

    @Test func boundsSizes() {
        let longPath = "/" + String(repeating: "a", count: 5000)
        #expect(msg(#"{"type":"cursor","file":"\#(longPath)","line":1,"column":1}"#) == nil)
        let big = String(repeating: "x", count: EditorLimits.refuseBytes + 1)
        #expect(msg(#"{"type":"save","file":"/a","text":"\#(big)"}"#) == nil)
        let ok = String(repeating: "y", count: 1000)
        #expect(msg(#"{"type":"save","file":"/a","text":"\#(ok)"}"#) == .save(file: "/a", text: ok))
    }

    /// Swift → JS commands are JSON objects with a `type`.
    @Test func commandsEncode() throws {
        let cmd = EditorCommand.open(EditorOpen(path: "/r/a.tsx", text: "let a", readOnly: false,
                                               notice: nil, line: 2, column: 3))
        let obj = try #require(cmd.json as? [String: Any])
        #expect(obj["type"] as? String == "open")
        #expect(obj["path"] as? String == "/r/a.tsx")
        #expect(obj["line"] as? Int == 2)
        let resolve = EditorCommand.resolve(id: 3, result: .locations([EditorLocation(path: "/r/b.ts", line: 1, column: 2)], previews: ["/r/b.ts": "x"])).json as? [String: Any]
        #expect(resolve?["type"] as? String == "resolve")
        #expect((resolve?["result"] as? [String: Any])?["kind"] as? String == "locations")
        let result = resolve?["result"] as? [String: Any]
        #expect((result?["previews"] as? [String: String])?["/r/b.ts"] == "x")
        let status = EditorCommand.language(path: "/r/a.ts", LanguageStatus(text: "TS 5.6", tooltip: "t", level: .ready)).json as? [String: Any]
        #expect((status?["status"] as? [String: Any])?["level"] as? String == "ready")
    }

    /// M2 (#82): incremental edits, the language restart, completion details by name.
    @Test func languageMessages() {
        #expect(msg(#"{"type":"edit","file":"/r/a.ts","changes":[{"line":1,"column":2,"endLine":1,"endColumn":4,"text":"ab"}]}"#)
                == .edit(file: "/r/a.ts", [EditorEdit(line: 1, column: 2, endLine: 1, endColumn: 4, text: "ab")]))
        #expect(msg(#"{"type":"edit","file":"/r/a.ts","changes":[{"line":1,"column":2,"endLine":1,"endColumn":4}]}"#) == nil)
        #expect(msg(#"{"type":"edit","file":"/r/a.ts","changes":"x"}"#) == nil)
        #expect(msg(#"{"type":"edit","file":"/r/a.ts","changes":[{"line":0,"column":2,"endLine":1,"endColumn":4,"text":""}]}"#) == nil)
        #expect(msg(#"{"type":"restartLanguage","file":"/r/a.ts"}"#) == .restartLanguage(file: "/r/a.ts"))
        #expect(msg(#"{"type":"request","id":5,"kind":"details","file":"/r/a.ts","line":1,"column":1,"name":"foo"}"#)
                == .request(ProviderRequest(id: 5, kind: .details, file: "/r/a.ts", line: 1, column: 1, name: "foo")))
        #expect(msg(#"{"type":"request","id":5,"kind":"details","file":"/r/a.ts","line":1,"column":1}"#) == nil)  // details need a name
        let long = String(repeating: "n", count: 600)
        #expect(msg(#"{"type":"request","id":5,"kind":"details","file":"/r/a.ts","line":1,"column":1,"name":"\#(long)"}"#) == nil)
    }

    /// Rename and format through tsserver: the format request carries the editor's indentation.
    @Test func renameAndFormat() {
        #expect(msg(#"{"type":"request","id":7,"kind":"rename","file":"/r/a.ts","line":2,"column":3}"#)
                == .request(ProviderRequest(id: 7, kind: .rename, file: "/r/a.ts", line: 2, column: 3)))
        #expect(msg(#"{"type":"request","id":8,"kind":"format","file":"/r/a.ts","line":1,"column":1,"tabSize":2,"insertSpaces":false}"#)
                == .request(ProviderRequest(id: 8, kind: .format, file: "/r/a.ts", line: 1, column: 1, tabSize: 2, insertSpaces: false)))
        #expect(msg(#"{"type":"request","id":8,"kind":"format","file":"/r/a.ts","line":1,"column":1,"tabSize":99,"insertSpaces":true}"#) == nil)
        #expect(msg(#"{"type":"request","id":8,"kind":"format","file":"/r/a.ts","line":1,"column":1,"tabSize":"2","insertSpaces":true}"#) == nil)
        let edits = EditorCommand.resolve(id: 8, result: .edits([EditorEdit(line: 1, column: 1, endLine: 1, endColumn: 3, text: "  ")])).json as? [String: Any]
        let r = edits?["result"] as? [String: Any]
        #expect(r?["kind"] as? String == "edits")
        #expect(((r?["items"] as? [[String: Any]])?.first)?["text"] as? String == "  ")
        let rename = (EditorCommand.resolve(id: 7, result: .renames([EditorRename(line: 2, column: 5, endLine: 2, endColumn: 8, prefix: "x: ", suffix: "")])).json
            as? [String: Any])?["result"] as? [String: Any]
        #expect(rename?["kind"] as? String == "renames")
        #expect(((rename?["items"] as? [[String: Any]])?.first)?["prefix"] as? String == "x: ")
        let rejected = (EditorCommand.resolve(id: 7, result: .rejected("no")).json as? [String: Any])?["result"] as? [String: Any]
        #expect(rejected?["kind"] as? String == "rejected" && rejected?["reason"] as? String == "no")
    }

    /// One shared page for every file tab (#83): messages name their tab (`doc`, a UUID), commands carry it back.
    @Test func docsRouteMessagesAndCommands() throws {
        let id = UUID()
        let e = try #require(BridgeMessage.envelope(#"{"type":"changed","doc":"\#(id.uuidString)","file":"/r/a.ts","dirty":true}"#))
        #expect(e.doc == id && e.message == .changed(file: "/r/a.ts", dirty: true))
        #expect(BridgeMessage.envelope(#"{"type":"ready"}"#)?.doc == nil)
        #expect(BridgeMessage.envelope(#"{"type":"focus","doc":"nope"}"#) == nil)   // a doc must be a UUID
        #expect(BridgeMessage.envelope(#"{"type":"focus","doc":5}"#) == nil)
        let cmd = try #require(EditorCommand.saved(path: "/r/a.ts").json(doc: id) as? [String: Any])
        #expect(cmd["doc"] as? String == id.uuidString && cmd["type"] as? String == "saved")
        #expect((EditorCommand.focus.json(doc: nil) as? [String: Any])?["doc"] == nil)
    }
}
