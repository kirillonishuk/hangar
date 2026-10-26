import Foundation
import Testing
import Workspace
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

    /// Both syntax palettes take the app theme's editor chrome (themes-v1.html); Hangar's syntax is the diff's muted one (#53).
    @Test(arguments: AppTheme.allCases) func themeUsesHangarTokens(_ app: AppTheme) throws {
        let p = ThemePalette.of(app)
        for palette in HangarConfig.EditorPalette.allCases {
            let theme = try #require(MonacoTheme.json(palette, theme: p)["colors"] as? [String: String])
            #expect(theme["editor.background"] == p.editorBg.css)
            #expect(theme["editorCursor.foreground"] == p.accent.css)
            #expect(theme["editorLineNumber.foreground"] == p.edGutter.css)
            #expect(theme["editorLineNumber.activeForeground"] == p.edGutterActive.css)
            #expect(theme["editor.lineHighlightBackground"] == p.edLine.css)
            #expect(theme["editor.selectionBackground"] == p.edSel.css)
            #expect(theme["editorIndentGuide.background1"] == p.edIndent.css)
            #expect(theme["editorBracketHighlight.foreground1"] == "#FFD700")
        }
        // Translucent diff tints keep their alpha (`#rrggbbaa`).
        let colors = try #require(MonacoTheme.json(.darkPlus, theme: .of(.darkPlus))["colors"] as? [String: String])
        #expect(colors["diffEditor.insertedLineBackground"] == "#9bb95533")
        // The syntax doesn't depend on the app theme.
        let a = try #require(MonacoTheme.json(.darkPlus, theme: .of(.navy))["rules"] as? [[String: String]])
        let b = try #require(MonacoTheme.json(.darkPlus, theme: .of(.graphite))["rules"] as? [[String: String]])
        #expect(a == b)
        #expect(MonacoTheme.css(.of(.graphite))["--primary-text"] == "#1c1b19")
    }

    @Test func hangarSyntaxRules() throws {
        let rules = try #require(MonacoTheme.json(.hangar)["rules"] as? [[String: String]])
        #expect(rules.contains { $0["token"] == "keyword" && $0["foreground"] == "b79bd9" })
        #expect(rules.contains { $0["token"] == "comment" && $0["foreground"] == "75819a" })
    }

    /// VS Code Dark+ (#84): Monarch tokens and tsserver's semantic types in Dark+'s colors.
    @Test func darkPlusColors() throws {
        let rules = try #require(MonacoTheme.json(.darkPlus)["rules"] as? [[String: String]])
        func color(_ token: String) -> String? { rules.first { $0["token"] == token }?["foreground"] }
        #expect(color("keyword") == "569CD6" && color("keyword.control") == "C586C0")
        #expect(color("identifier") == "9CDCFE" && color("variable") == "9CDCFE" && color("parameter") == "9CDCFE")
        #expect(color("type.identifier") == "4EC9B0" && color("class") == "4EC9B0" && color("interface") == "4EC9B0")
        #expect(color("function") == "DCDCAA" && color("member") == "DCDCAA")
        #expect(color("string") == "CE9178" && color("number") == "B5CEA8" && color("comment") == "6A9955")
        #expect(color("constant") == "4FC1FF" && color("delimiter") == "D4D4D4")
        #expect(color("tag") == "569CD6" && color("attribute.name") == "9CDCFE")
    }

    @Test func bundledMonacoIsThere() throws {
        let dir = try #require(L10n.resources?.url(forResource: "Monaco", withExtension: nil))
        for file in ["vs/loader.js", "vs/editor/editor.main.js", "vs/editor/editor.main.css", "hangar/index.html", "hangar/hangar.js", "LICENSE.txt"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), "\(file)")
        }
    }
}
