import Foundation
import Testing
@testable import HangarUI

/// A language server's stdout is untrusted (#90): framing, message kinds, server → client requests, results mapping.
@Suite struct LspProtocolTests {
    private func frame(_ json: String) -> Data { Data("Content-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8) }

    @Test func framesSplitAndConcatenated() throws {
        var f = TsFramer()
        let a = frame(#"{"jsonrpc":"2.0","id":1,"result":{"x":"é ✓"}}"#)
        let b = frame(#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"hi"}}"#)
        let c = frame(#"{"jsonrpc":"2.0","id":"7","method":"workspace/configuration","params":{"items":[{}]}}"#)
        let all = a + b + c
        var got: [[String: Any]] = []
        // Byte by byte through the first header and a multi-byte character, then the rest (two messages) in one chunk.
        for i in 0..<45 { got += f.feed(all.subdata(in: i..<(i + 1))) }
        #expect(got.isEmpty)
        got += f.feed(all.subdata(in: 45..<all.count))
        #expect(got.count == 3)
        guard case .response(1, let result, nil)? = LspMessage(got[0]) else { Issue.record("not a response"); return }
        #expect((result as? [String: Any])?["x"] as? String == "é ✓")
        guard case .notification("window/logMessage", _)? = LspMessage(got[1]) else { Issue.record("not a notification"); return }
        guard case .request(let id, "workspace/configuration", _)? = LspMessage(got[2]) else { Issue.record("not a request"); return }
        #expect(id as? String == "7")
    }

    @Test func ourFramesRoundTrip() throws {
        var f = TsFramer()
        let data = try #require(lspFrame(["jsonrpc": "2.0", "id": 3, "method": "textDocument/hover", "params": ["uri": "file:///a b/ü.py"]]))
        #expect(String(decoding: data.prefix(16), as: UTF8.self) == "Content-Length: ")
        let out = f.feed(data)
        #expect(out.count == 1)
        #expect((out[0]["params"] as? [String: Any])?["uri"] as? String == "file:///a b/ü.py")
    }

    @Test func malformedMessagesAreIgnored() {
        for json in [#"{"jsonrpc":"2.0","id":true,"result":1}"#, #"{"jsonrpc":"2.0","id":1}"#, #"{"id":1.5,"result":1}"#,
                     #"{"method":"","params":{}}"#, #"{"method":"x","id":{"a":1}}"#, #"{"result":1}"#] {
            let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            #expect(o.flatMap(LspMessage.init) == nil, "\(json)")
        }
        let error = try? JSONSerialization.jsonObject(with: Data(#"{"id":4,"error":{"code":-1,"message":"nope"}}"#.utf8)) as? [String: Any]
        guard case .response(4, nil, "nope")? = error.flatMap(LspMessage.init) else { Issue.record("error response"); return }
    }

    @Test func serverRequestsGetAnswers() {
        #expect((LspMap.reply("workspace/configuration", ["items": [[:], [:]]], folders: []) as? [Any])?.count == 2)
        #expect(LspMap.reply("client/registerCapability", nil, folders: []) is NSNull)
        #expect(LspMap.reply("workspace/applyEdit", nil, folders: []) as? [String: Bool] == ["applied": false])
        #expect(LspMap.reply("custom/whatever", nil, folders: []) == nil)
    }

    @Test func capabilities() {
        let c = LspMap.Capabilities(["capabilities": ["textDocumentSync": ["openClose": true, "change": 2], "hoverProvider": true,
                                                      "definitionProvider": ["workDoneProgress": false], "referencesProvider": false,
                                                      "completionProvider": ["resolveProvider": true], "renameProvider": ["prepareProvider": true],
                                                      "documentFormattingProvider": 1]])
        #expect(c.sync == 2 && c.hover && c.definition && !c.references && c.completion && c.resolve && c.rename && c.prepareRename)
        #expect(!c.formatting)  // a number is not a capability
        #expect(LspMap.Capabilities(["capabilities": ["textDocumentSync": 1]]).sync == 1)
        #expect(LspMap.Capabilities("junk") == LspMap.Capabilities())
    }

    // MARK: Results

    private let root = "/w/proj"

    private func loc(_ uri: String, _ l: Int, _ c: Int) -> [String: Any] {
        ["uri": uri, "range": ["start": ["line": l, "character": c], "end": ["line": l, "character": c + 3]]]
    }

    @Test func locationsAllShapesAndRefusals() {
        #expect(LspMap.locations(loc("file:///w/proj/a.py", 0, 4), roots: [root])
            == [EditorLocation(path: "/w/proj/a.py", line: 1, column: 5, endLine: 1, endColumn: 8)])
        let link: [String: Any] = ["targetUri": "file:///w/proj/b%20c.py", "targetRange": ["start": ["line": 0, "character": 0], "end": ["line": 9, "character": 0]],
                                   "targetSelectionRange": ["start": ["line": 2, "character": 1], "end": ["line": 2, "character": 2]]]
        let list = LspMap.locations([loc("file:///etc/passwd", 0, 0), loc("file:///w/proj/../x", 0, 0), loc("https://x/w/proj/a", 0, 0),
                                     ["uri": "file:///w/proj/a.py", "range": ["start": ["line": -1, "character": 0], "end": ["line": 0, "character": 0]]],
                                     link, loc("file:///w/proj/a.py", 0, 4), loc("file:///w/proj/a.py", 0, 4),
                                     loc("file:///home/u/go/pkg/mod/x/y.go", 3, 0)], roots: [root])
        #expect(list == [EditorLocation(path: "/w/proj/b c.py", line: 3, column: 2, endLine: 3, endColumn: 3),
                         EditorLocation(path: "/w/proj/a.py", line: 1, column: 5, endLine: 1, endColumn: 8),
                         EditorLocation(path: "/home/u/go/pkg/mod/x/y.go", line: 4, column: 1, endLine: 4, endColumn: 4)])
        #expect(LspMap.locations(nil, roots: [root]).isEmpty)
    }

    @Test func symlinkOutOfTheProjectIsRefused() throws {
        let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg-lsp-link-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/proj/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/secret", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        try "k".write(toFile: base + "/secret/id_rsa", atomically: true, encoding: .utf8)
        try "x".write(toFile: base + "/proj/src/a.py", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: base + "/proj/link", withDestinationPath: base + "/secret")
        try fm.createSymbolicLink(atPath: base + "/proj/node_modules", withDestinationPath: base + "/secret")
        #expect(LspMap.allowed(base + "/proj/src/a.py", roots: [base + "/proj"]))
        #expect(!LspMap.allowed(base + "/proj/link/id_rsa", roots: [base + "/proj"]))
        // A dependency-looking name that is really a link out is refused too.
        #expect(!LspMap.allowed(base + "/proj/node_modules/id_rsa", roots: [base + "/proj"]))
        // Roots are compared resolved: a root given through a symlink still matches.
        try fm.createSymbolicLink(atPath: base + "/alias", withDestinationPath: base + "/proj")
        #expect(LspMap.allowed(base + "/proj/src/a.py", roots: [base + "/alias"]))
    }

    @Test func completionRanges() {
        func r(_ l: Int, _ c: Int, _ el: Int, _ ec: Int) -> [String: Any] {
            ["start": ["line": l, "character": c], "end": ["line": el, "character": ec]]
        }
        // Asked at line 3, column 7 (1-based) → LSP line 2, character 6.
        #expect(LspMap.completionRange(["range": r(2, 4, 2, 6), "newText": "x"], line: 3, column: 7)
            == EditorCompletion.Range(start: 5, end: 7, replaceEnd: 7))
        #expect(LspMap.completionRange(["insert": r(2, 4, 2, 6), "replace": r(2, 4, 2, 9), "newText": "x"], line: 3, column: 7)
            == EditorCompletion.Range(start: 5, end: 7, replaceEnd: 10))
        #expect(LspMap.completionRange(["range": r(1, 0, 2, 6)], line: 3, column: 7) == nil)   // two lines
        #expect(LspMap.completionRange(["range": r(2, 7, 2, 9)], line: 3, column: 7) == nil)   // after the cursor
        #expect(LspMap.completionRange(["insert": r(2, 4, 2, 6), "replace": r(2, 3, 2, 9)], line: 3, column: 7) == nil)
        #expect(LspMap.completionRange(nil, line: 3, column: 7) == nil)
        let (list, _) = LspMap.completions([["label": "foo", "textEdit": ["range": r(0, 2, 0, 4), "newText": "foo"]],
                                            ["label": "bar"]], line: 1, column: 5)
        #expect(list.map(\.range) == [EditorCompletion.Range(start: 3, end: 5, replaceEnd: 5), nil])
    }

    @Test func hoverShapes() {
        #expect(LspMap.hover(["contents": ["kind": "markdown", "value": "**x**"]]) == "**x**")
        #expect(LspMap.hover(["contents": ["kind": "plaintext", "value": "a ``` b"]]) == "```\na `\u{200B}`` b\n```")
        #expect(LspMap.hover(["contents": [["language": "python", "value": "def f()"], "doc"]]) == "```python\ndef f()\n```\n\n---\n\ndoc")
        #expect(LspMap.hover(["contents": ["language": "x\n```js", "value": "v"]]) == "```\nv\n```")
        #expect(LspMap.hover(["contents": 5]) == nil)
        #expect(LspMap.hover(nil) == nil)
    }

    @Test func completionsAndDetails() {
        let (list, raw) = LspMap.completions(["isIncomplete": false, "items": [
            ["label": "append", "kind": 2, "detail": "(x) -> None", "sortText": "a"],
            ["label": "fmt", "insertText": "fmt($1)", "insertTextFormat": 2, "kind": 9],
            ["label": "edited", "textEdit": ["newText": "edited()", "range": [:]]],
            ["label": "append"], ["label": ""], ["kind": 3],
        ]])
        #expect(list.map(\.label) == ["append", "fmt", "edited"])
        #expect(list.map(\.insertText) == ["append", "fmt($1)", "edited()"])
        #expect(list.map(\.snippet) == [false, true, false])
        #expect(list.map(\.kind) == ["method", "module", nil])
        #expect(raw.count == 3)
        #expect(LspMap.details(raw["append"], language: "python") == "```python\n(x) -> None\n```")
        #expect(LspMap.details(["documentation": ["kind": "markdown", "value": "Docs"]], language: "go") == "Docs")
    }

    @Test func snippetsKeepTabStopsOnly() {
        #expect(LspMap.snippet("f(${1:a: Int}, $2)$0") == "f(${1:a: Int}, $2)$0")
        #expect(LspMap.snippet("x$CLIPBOARD ${TM_FILENAME} $") == "x\\$CLIPBOARD \\${TM_FILENAME} \\$")
        #expect(LspMap.snippet("${1:${CLIPBOARD}}") == "${1:\\${CLIPBOARD}}")
        #expect(LspMap.snippet("a\\$b") == "a\\$b")
    }

    @Test func diagnostics() throws {
        let (file, list) = try #require(LspMap.diagnostics(["uri": "file:///w/proj/a.go", "diagnostics": [
            ["range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]], "severity": 2, "message": "unused",
             "source": "go vet", "code": "U1000"],
            ["range": ["start": ["line": 3, "character": 0], "end": ["line": 2, "character": 0]], "message": "backwards"],
            ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "message": "plain", "code": 7],
        ]]))
        #expect(file == "/w/proj/a.go")
        #expect(list == [EditorDiagnostic(line: 2, column: 3, endLine: 2, endColumn: 6, severity: .warning, message: "unused (go vet U1000)"),
                         EditorDiagnostic(line: 1, column: 1, endLine: 1, endColumn: 2, severity: .error, message: "plain (7)")])
        #expect(LspMap.diagnostics(["uri": "untitled:1", "diagnostics": []]) == nil)
    }

    @MainActor @Test func renameSameFileOnly() {
        let edit: [String: Any] = ["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 7]], "newText": "self.new"]
        #expect(LspMap.rename(["changes": ["file:///w/proj/a.py": [edit]]], file: "/w/proj/a.py", newName: "new")
            == .renames([EditorRename(line: 1, column: 5, endLine: 1, endColumn: 8, prefix: "self.", suffix: "")]))
        #expect(LspMap.rename(["documentChanges": [["textDocument": ["uri": "file:///w/proj/a.py", "version": 1], "edits": [edit]]]],
                              file: "/w/proj/a.py", newName: "new") != nil)
        #expect(LspMap.rename(["changes": ["file:///w/proj/a.py": [edit], "file:///w/proj/b.py": [edit]]], file: "/w/proj/a.py", newName: "new")
            == .rejected(L10n.editorRenameOtherFiles))
        #expect(LspMap.rename(["documentChanges": [["kind": "rename", "oldUri": "file:///a", "newUri": "file:///b"]]], file: "/w/proj/a.py",
                              newName: "new") == .rejected(L10n.editorRenameOtherFiles))
        #expect(LspMap.rename(["changes": ["file:///w/proj/a.py": [edit]]], file: "/w/proj/a.py", newName: "other") == .rejected(L10n.editorRenameRefused))
        #expect(LspMap.rename(nil, file: "/w/proj/a.py", newName: "x") == nil)
    }

    @Test func formattingEdits() {
        #expect(LspMap.edits([["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 2]], "newText": "  "],
                              ["range": [:], "newText": "x"], ["newText": 3]])
            == [EditorEdit(line: 1, column: 1, endLine: 1, endColumn: 3, text: "  ")])
    }

    // MARK: Discovery

    @Test func languages() {
        #expect(LspLanguage.of("/a/b.py")?.id == "python")
        #expect(LspLanguage.of("/a/b.PYI")?.id == "python")
        #expect(LspLanguage.of("/a/Package.swift")?.id == "swift")
        #expect(LspLanguage.of("/a/main.go")?.id == "go")
        #expect(LspLanguage.of("/a/lib.rs")?.id == "rust")
        #expect(LspLanguage.of("/a/x.ts") == nil)
        #expect(LspLanguage.of("/a/Makefile") == nil)
    }

    @Test func findOrder() async {
        let home = "/Users/u"
        func find(_ lang: LspLanguage, _ present: Set<String>, path: [String] = ["/usr/bin", "/opt/x/bin"],
                  toolchain: String? = nil) async -> LspFound? {
            await LspMap.find(lang, projectRoot: "/w/p", path: path, home: home, isExecutable: { present.contains($0) },
                              toolchain: { _ in toolchain })
        }
        // Toolchain servers are never taken from the project folder; pylsp not from node_modules/.bin.
        #expect(await find(.go, ["/w/p/.venv/bin/gopls", "/w/p/node_modules/.bin/gopls"]) == nil)
        #expect(await find(.swift, ["/w/p/node_modules/.bin/sourcekit-lsp"]) == nil)
        #expect(await find(.python, ["/w/p/node_modules/.bin/pylsp"]) == nil)
        #expect(await find(.python, ["/w/p/node_modules/.bin/pyright-langserver"])
            == LspFound(executable: "/w/p/node_modules/.bin/pyright-langserver", args: ["--stdio"]))
        // Project-local beats PATH, even for a later candidate.
        #expect(await find(.python, ["/opt/x/bin/pyright-langserver", "/w/p/.venv/bin/pylsp"])
            == LspFound(executable: "/w/p/.venv/bin/pylsp", args: []))
        #expect(await find(.python, ["/opt/x/bin/pyright-langserver", "/opt/x/bin/pylsp"])
            == LspFound(executable: "/opt/x/bin/pyright-langserver", args: ["--stdio"]))
        // /usr/bin shims are never used; the toolchain (xcrun) is.
        #expect(await find(.swift, ["/usr/bin/sourcekit-lsp"]) == nil)
        #expect(await find(.swift, ["/usr/bin/sourcekit-lsp", "/X/usr/bin/sourcekit-lsp"], toolchain: "/X/usr/bin/sourcekit-lsp")
            == LspFound(executable: "/X/usr/bin/sourcekit-lsp", args: []))
        #expect(await find(.go, ["/Users/u/go/bin/gopls"]) == LspFound(executable: "/Users/u/go/bin/gopls", args: []))
        #expect(await find(.rust, ["/Users/u/.cargo/bin/rust-analyzer"], path: ["relative/bin"])
            == LspFound(executable: "/Users/u/.cargo/bin/rust-analyzer", args: []))
        #expect(await find(.rust, []) == nil)
    }

    @Test func projectRootAndPath() {
        let present: Set<String> = ["/w/s/svc/go.mod", "/w/s/go.work"]
        #expect(LspMap.projectRoot(file: "/w/s/svc/cmd/main.go", sessionRoot: "/w/s", markers: LspLanguage.go.markers) { present.contains($0) } == "/w/s/svc")
        #expect(LspMap.projectRoot(file: "/w/s/x.go", sessionRoot: "/w/s/", markers: LspLanguage.go.markers) { present.contains($0) } == "/w/s")
        #expect(LspMap.projectRoot(file: "/w/s/a/b.rs", sessionRoot: "/w/s", markers: ["Cargo.toml"]) { _ in false } == "/w/s")
        #expect(LspMap.projectRoot(file: "/elsewhere/b.rs", sessionRoot: "/w/s", markers: ["Cargo.toml"]) { _ in true } == "/w/s")
        #expect(LspMap.parsePath("motd noise\nHANGAR-PATH=/a/bin:/b:rel:\n") == ["/a/bin", "/b"])
        #expect(LspMap.parsePath("nothing") == [])
        #expect(LspMap.path("file:///a/b%20c.py") == "/a/b c.py")
        #expect(LspMap.path("file://host/a") == nil)
        #expect(LspMap.uri("/a/b c.py") == "file:///a/b%20c.py")
        #expect(LspMap.isDependency("/v/lib/python3.12/site-packages/x.py"))
        #expect(!LspMap.isDependency("/w/s/pkg/x.go"))
        #expect(LspMap.isDependency("/h/.cargo/registry/src/x/lib.rs"))
        #expect(LspMap.isDependency("/h/.cargo/git/checkouts/x/lib.rs"))
        #expect(!LspMap.isDependency("/h/.cargo/credentials.toml"))
    }
}
