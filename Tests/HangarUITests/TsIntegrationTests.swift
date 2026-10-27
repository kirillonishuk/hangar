import Foundation
import Testing
@testable import HangarUI
import TestSupport

/// A real tsserver over a two-file import chain. Nothing is installed: it runs only when a typescript package is
/// already on disk (HANGAR_TEST_TYPESCRIPT=<…/node_modules/typescript>, or a global one) and node is found;
/// the temp project links to it read-only.
@MainActor @Suite struct TsIntegrationTests {
    nonisolated static let typescript: String? = {
        let candidates = [ProcessInfo.processInfo.environment["HANGAR_TEST_TYPESCRIPT"],
                          "/usr/local/lib/node_modules/typescript", "/opt/homebrew/lib/node_modules/typescript"]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0 + "/lib/tsserver.js") }
    }()
    nonisolated static let node: String? = TsInstall.fallbackNodes.first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: typescript != nil && node != nil, "no typescript package or node on this Mac (set HANGAR_TEST_TYPESCRIPT)"))
    func definitionAndReferencesAcrossAnImport() async throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg-tsint-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/node_modules", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/node_modules/typescript", withDestinationPath: Self.typescript!)
        try #"{ "compilerOptions": { "strict": true, "target": "es2020", "module": "esnext" }, "include": ["src"] }"#
            .write(toFile: root + "/tsconfig.json", atomically: true, encoding: .utf8)
        let b = "export class Greeter {\n  greet(name: string): string { return \"hi \" + name }\n}\n"
        let a = "import { Greeter } from \"./b\";\nexport const msg = new Greeter().greet(\"x\");\nconst n: number = \"s\";\n"
        try b.write(toFile: root + "/src/b.ts", atomically: true, encoding: .utf8)
        try a.write(toFile: root + "/src/a.ts", atomically: true, encoding: .utf8)

        let node = Self.node!
        let langs = Languages(lookup: { _, dir, root in await TsInstall.localLookup(dir: dir, root: root) { node } },
                              launch: { _, i in i.localLaunch(locale: "en") }, grace: .seconds(30), debounce: .milliseconds(50))
        var markers: [EditorDiagnostic] = []
        let owner = Languages.Owner(id: UUID(), root: root, send: { if case .markers(_, let m) = $0 { markers = m } }, text: { _ in a })
        langs.opened(root + "/src/a.ts", text: a, host: nil, owner: owner)
        defer { langs.stopAll() }

        // `Greeter` on line 2 (column 24) → its class in b.ts.
        var def: ProviderResult?
        for _ in 0..<60 where def == nil {
            def = await langs.request(ProviderRequest(id: 1, kind: .definition, file: root + "/src/a.ts", line: 2, column: 24), host: nil) { _ in nil }
            if def == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        guard case .locations(let defs, _)? = def else { Issue.record("no definition: \(String(describing: def))"); return }
        #expect(defs.first?.path == root + "/src/b.ts")
        #expect(defs.first?.line == 1)

        // References of `greet` (a.ts line 2, column 37): the method in b.ts and the call; b.ts comes with a preview.
        let refs = await langs.request(ProviderRequest(id: 2, kind: .references, file: root + "/src/a.ts", line: 2, column: 37), host: nil) { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard case .locations(let list, let previews)? = refs else { Issue.record("no references"); return }
        #expect(Set(list.map(\.path)) == [root + "/src/a.ts", root + "/src/b.ts"])
        #expect(previews[root + "/src/b.ts"] == b)

        let hover = await langs.request(ProviderRequest(id: 3, kind: .hover, file: root + "/src/a.ts", line: 2, column: 37), host: nil) { _ in nil }
        guard case .hover(let md)? = hover else { Issue.record("no hover"); return }
        #expect(md.contains("greet(name: string): string"))

        // The type error on line 3 arrives as a marker.
        #expect(await waitUntil { markers.contains { $0.line == 3 && $0.severity == .error } })

        // Rename: a local (`n`, line 3) → spans in a.ts; the exported class reaches b.ts → refused, nothing partial.
        let local = await langs.request(ProviderRequest(id: 4, kind: .rename, file: root + "/src/a.ts", line: 3, column: 7), host: nil) { _ in nil }
        #expect(local == .renames([EditorRename(line: 3, column: 7, endLine: 3, endColumn: 8, prefix: "", suffix: "")]))
        let shared = await langs.request(ProviderRequest(id: 5, kind: .rename, file: root + "/src/a.ts", line: 1, column: 10), host: nil) { _ in nil }
        #expect(shared == .rejected(L10n.editorRenameOtherFiles))

        // Semantic colors: `new Greeter` (offset 54) is a class (type 0), `msg` a readonly declared variable (7, 1|8).
        let sem = await langs.request(ProviderRequest(id: 7, kind: .semantic, file: root + "/src/a.ts", line: 1, column: 1,
                                                      length: a.utf16.count), host: nil) { _ in nil }
        guard case .semantic(let spans)? = sem else { Issue.record("no semantic spans"); return }
        let quads = stride(from: 0, to: spans.count, by: 4).map { Array(spans[$0..<$0 + 4]) }
        #expect(quads.contains { $0 == [54, 7, 0, 0] } && quads.contains { $0 == [44, 3, 7, 9] })

        // Format the whole file, its end as the position, with the editor's indentation.
        let c = "function f(){\nreturn  1\n}\n"
        langs.opened(root + "/src/c.ts", text: c, host: nil, owner: owner)
        var fmt: ProviderResult?
        for _ in 0..<60 where fmt == nil {  // c.ts attaches to the running server asynchronously
            fmt = await langs.request(ProviderRequest(id: 6, kind: .format, file: root + "/src/c.ts", line: 4, column: 1,
                                                      tabSize: 2, insertSpaces: true), host: nil) { _ in nil }
            if fmt == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard case .edits(let edits)? = fmt else { Issue.record("no format edits: \(String(describing: fmt))"); return }
        #expect(edits.contains { $0.line == 2 && $0.column == 1 && $0.text == "  " })
    }
}
