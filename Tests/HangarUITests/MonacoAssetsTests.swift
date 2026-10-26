import Foundation
import Testing
@testable import HangarUI

/// The custom scheme serves only bundled files; the theme comes from Theme tokens (#80).
@Suite struct MonacoAssetsTests {
    private let root = "/b/Monaco"

    @Test func resolvesOnlyInsideTheRoot() {
        func path(_ s: String) -> String? { monacoResourcePath(URL(string: s)!, root: root) }
        #expect(path("hangar-editor://app/vs/loader.js") == "/b/Monaco/vs/loader.js")
        #expect(path("hangar-editor://app/hangar/index.html") == "/b/Monaco/hangar/index.html")
        #expect(path("hangar-editor://app/../../etc/passwd") == nil)
        #expect(path("hangar-editor://app/vs/%2e%2e/%2e%2e/etc/passwd") == nil)
        #expect(path("hangar-editor://evil/vs/loader.js") == nil)
        #expect(path("https://app/vs/loader.js") == nil)
        #expect(path("hangar-editor://app/") == nil)
    }

    @Test func mimeTypes() {
        #expect(monacoMimeType("a.js") == "text/javascript")
        #expect(monacoMimeType("a.css") == "text/css")
        #expect(monacoMimeType("a.html") == "text/html")
        #expect(monacoMimeType("a.ttf") == "font/ttf")
        #expect(monacoMimeType("a.bin") == "application/octet-stream")
    }

    @Test func themeUsesHangarTokens() throws {
        let theme = try #require(MonacoTheme.json["colors"] as? [String: String])
        #expect(theme["editor.background"] == "#121826")
        #expect(theme["editorCursor.foreground"] == "#61afef")
        let rules = try #require(MonacoTheme.json["rules"] as? [[String: String]])
        #expect(rules.contains { $0["token"] == "keyword" && $0["foreground"] == "b79bd9" })
        #expect(rules.contains { $0["token"] == "comment" && $0["foreground"] == "75819a" })
    }

    @Test func bundledMonacoIsThere() throws {
        let dir = try #require(L10n.resources?.url(forResource: "Monaco", withExtension: nil))
        for file in ["vs/loader.js", "vs/editor/editor.main.js", "vs/editor/editor.main.css", "hangar/index.html", "hangar/hangar.js", "LICENSE.txt"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), "\(file)")
        }
    }
}
