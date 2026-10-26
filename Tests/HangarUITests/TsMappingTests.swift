import Foundation
import Testing
import Exec
@testable import HangarUI

/// tsserver answers → editor results; paths from answers only inside the project or node_modules (#NN-tsserver).
@Suite struct TsMappingTests {
    private let roots = ["/w/app"]
    private func span(_ file: String, _ l: Int, _ o: Int, _ el: Int, _ eo: Int) -> [String: Any] {
        ["file": file, "start": ["line": l, "offset": o], "end": ["line": el, "offset": eo]]
    }

    @Test func scriptKinds() {
        #expect(TsMap.scriptKind("/a/b.ts") == "TS")
        #expect(TsMap.scriptKind("/a/b.d.ts") == "TS")
        #expect(TsMap.scriptKind("/a/b.mts") == "TS")
        #expect(TsMap.scriptKind("/a/B.TSX") == "TSX")
        #expect(TsMap.scriptKind("/a/b.cjs") == "JS")
        #expect(TsMap.scriptKind("/a/b.jsx") == "JSX")
        #expect(TsMap.scriptKind("/a/b.json") == nil)
        #expect(TsMap.scriptKind("/a/ts") == nil)
    }

    @Test func pathRules() {
        #expect(TsMap.allowed("/w/app/src/a.ts", roots: roots))
        #expect(TsMap.allowed("/w/app/node_modules/@types/react/index.d.ts", roots: roots))
        #expect(TsMap.allowed("/usr/local/lib/node_modules/typescript/lib/lib.dom.d.ts", roots: roots))
        #expect(TsMap.allowed("/w/application/a.ts", roots: roots) == false)   // a sibling with the same prefix
        #expect(TsMap.allowed("/etc/passwd", roots: roots) == false)
        #expect(TsMap.allowed("/w/app/../../etc/passwd", roots: roots) == false)
        #expect(TsMap.allowed("relative/a.ts", roots: roots) == false)
        #expect(TsMap.allowed("/w/app/a\u{0}.ts", roots: roots) == false)
        #expect(TsMap.allowed("/w/app/" + String(repeating: "a", count: 5000), roots: roots) == false)
        #expect(TsMap.isDependency("/w/app/node_modules/x/index.d.ts"))
        #expect(TsMap.isDependency("/w/app/src/node_modules_like.ts") == false)
    }

    @Test func definitionsKeepAllowedPathsWithRanges() {
        let body: [String: Any] = ["definitions": [
            span("/w/app/src/b.ts", 3, 17, 3, 22),
            span("/w/app/node_modules/lib/index.d.ts", 1, 1, 1, 4),
            span("/etc/hosts", 1, 1, 1, 2),
            ["file": "/w/app/x.ts", "start": ["line": "1", "offset": 1]],   // malformed
        ], "textSpan": ["start": ["line": 1, "offset": 1], "end": ["line": 1, "offset": 2]]]
        #expect(TsMap.definition(body, roots: roots) == [
            EditorLocation(path: "/w/app/src/b.ts", line: 3, column: 17, endLine: 3, endColumn: 22),
            EditorLocation(path: "/w/app/node_modules/lib/index.d.ts", line: 1, column: 1, endLine: 1, endColumn: 4),
        ])
        #expect(TsMap.definition(nil, roots: roots).isEmpty)
        #expect(TsMap.definition(["definitions": "x"], roots: roots).isEmpty)
    }

    @Test func references() {
        let body: [String: Any] = ["refs": [span("/w/app/a.ts", 1, 10, 1, 13), span("/w/app/b.ts", 4, 2, 4, 5),
                                            span("/w/app/b.ts", 4, 2, 4, 5)], "symbolName": "foo"]
        #expect(TsMap.references(body, roots: roots).map(\.path) == ["/w/app/a.ts", "/w/app/b.ts"])  // duplicates go
    }

    @Test func hoverMarkdown() {
        let body: [String: Any] = ["kind": "function", "displayString": "function foo(a: number): string",
                                   "documentation": "Makes a foo.",
                                   "tags": [["name": "param", "text": "a the count"], ["name": "deprecated"]]]
        let md = TsMap.hover(body)
        #expect(md == "```typescript\nfunction foo(a: number): string\n```\n\nMakes a foo.\n\n*@param* a the count\n\n*@deprecated*")
        // TS 5 sends documentation and tag text as display parts.
        let parts: [String: Any] = ["displayString": "const x: 1", "documentation": [["text": "A "], ["text": "doc"]],
                                    "tags": [["name": "see", "text": [["text": "y"]]]]]
        #expect(TsMap.hover(parts) == "```typescript\nconst x: 1\n```\n\nA doc\n\n*@see* y")
        #expect(TsMap.hover(["displayString": ""]) == nil)
        #expect(TsMap.hover("x") == nil)
    }

    @Test func completions() {
        let body: [String: Any] = ["isGlobalCompletion": false, "entries": [
            ["name": "length", "kind": "property", "sortText": "11"],
            ["name": "at", "kind": "method", "sortText": "11", "insertText": "at()"],
            ["kind": "method"],                                     // no name
        ]]
        #expect(TsMap.completions(body) == [
            EditorCompletion(label: "length", detail: nil, insertText: "length", kind: "property", sortText: "11"),
            EditorCompletion(label: "at", detail: nil, insertText: "at()", kind: "method", sortText: "11"),
        ])
        #expect(TsMap.completions(nil).isEmpty)
    }

    @Test func completionDetails() {
        let body: [Any] = [["name": "foo", "kind": "function", "displayParts": [["text": "function "], ["text": "foo(): void"]],
                            "documentation": [["text": "Docs."]]]]
        #expect(TsMap.details(body) == "```typescript\nfunction foo(): void\n```\n\nDocs.")
        #expect(TsMap.details([]) == nil)
    }

    @Test func diagnostics() throws {
        let body: [String: Any] = ["file": "/w/app/a.ts", "diagnostics": [
            ["start": ["line": 2, "offset": 7], "end": ["line": 2, "offset": 10], "text": "Type 'string' is not assignable", "category": "error", "code": 2322],
            ["start": ["line": 1, "offset": 1], "end": ["line": 1, "offset": 1], "text": "unused", "category": "suggestion"],
            ["start": ["line": 5, "offset": 3], "end": ["line": 4, "offset": 1], "text": "backwards", "category": "warning"],
            ["start": ["line": 1, "offset": 1], "text": "no end", "category": "error"],
        ]]
        let (file, list) = try #require(TsMap.diagnostics(body))
        #expect(file == "/w/app/a.ts")
        #expect(list == [
            EditorDiagnostic(line: 2, column: 7, endLine: 2, endColumn: 10, severity: .error, message: "Type 'string' is not assignable (TS2322)"),
            EditorDiagnostic(line: 1, column: 1, endLine: 1, endColumn: 1, severity: .hint, message: "unused"),
            EditorDiagnostic(line: 5, column: 3, endLine: 5, endColumn: 3, severity: .warning, message: "backwards"),
        ])
        #expect(TsMap.diagnostics(["file": 3]) == nil)
    }

    @Test func changeArguments() {
        let edit = EditorEdit(line: 2, column: 3, endLine: 2, endColumn: 5, text: "xy")
        let args = TsMap.change(file: "/w/app/a.ts", edit)
        #expect(args["file"] as? String == "/w/app/a.ts")
        #expect(args["line"] as? Int == 2)
        #expect(args["offset"] as? Int == 3)
        #expect(args["endLine"] as? Int == 2)
        #expect(args["endOffset"] as? Int == 5)
        #expect(args["insertString"] as? String == "xy")
    }

    @Test func lookupOutputIsValidated() {
        let ok = "zsh noise\nHANGAR-TS\t/w/app/node_modules/typescript/lib/tsserver.js\t5.6.3\t/usr/local/bin/node\n"
        #expect(TsMap.parseLookup(ok) == TsMap.Lookup(tsserver: "/w/app/node_modules/typescript/lib/tsserver.js",
                                                         version: "5.6.3", node: "/usr/local/bin/node"))
        #expect(TsMap.parseLookup("HANGAR-TS\t\t\t\n") == nil)
        #expect(TsMap.parseLookup("HANGAR-TS\trelative/tsserver.js\t5\t/n\n") == nil)
        #expect(TsMap.parseLookup("HANGAR-TS\t/x/tsserver.js\t5.6; rm\t/n\n")?.version == "")       // odd version: blank
        #expect(TsMap.parseLookup("HANGAR-TS\t/x/tsserver.js\t5.6\trelative-node\n")?.node == "")  // not a path: none
    }

    /// The lookup script itself: walks up from the file's folder, stops at the root.
    @Test func lookupScriptWalksUpToTheRoot() async throws {
        let base = NSTemporaryDirectory() + "hg-tslookup-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fm = FileManager.default
        let lib = base + "/repo/node_modules/typescript/lib"
        try fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/repo/packages/web/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside/node_modules/typescript/lib", withIntermediateDirectories: true)
        try "".write(toFile: lib + "/tsserver.js", atomically: true, encoding: .utf8)
        try "".write(toFile: base + "/outside/node_modules/typescript/lib/tsserver.js", atomically: true, encoding: .utf8)
        try #"{ "name": "typescript", "version": "5.4.2", "x": 1 }"#.write(toFile: lib + "/../package.json", atomically: true, encoding: .utf8)
        func run(_ dir: String, _ root: String) async throws -> TsMap.Lookup? {
            let r = try await Runner.local.run(["sh", "-c", TsMap.lookupScript, "sh", dir, root], "/")
            return TsMap.parseLookup(r.stdout)
        }
        let found = try await run(base + "/repo/packages/web/src", base + "/repo")
        #expect(found?.tsserver == lib + "/tsserver.js")
        #expect(found?.version == "5.4.2")
        // The root's own parent is never searched.
        #expect(try await run(base + "/repo/packages/web/src", base + "/repo/packages") == nil)
    }
}
