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

    /// Dark+ and Hangar take the app theme's editor chrome; Hangar's syntax is the diff's muted one (#53).
    @Test(arguments: AppTheme.allCases) func themeUsesHangarTokens(_ app: AppTheme) throws {
        let p = ThemePalette.of(app)
        for palette in [EditorPalette.darkPlus, .hangar] {
            let t = EditorTheme(palette: palette, customBase: .darkModern, custom: [:], app: app)
            let theme = try #require(MonacoTheme.json(t)["colors"] as? [String: String])
            #expect(theme["editor.background"] == p.bg0.css)
            #expect(theme["editorCursor.foreground"] == p.accentText.css)
            #expect(theme["editorLineNumber.foreground"] == p.edGutter.css)
            #expect(theme["editorLineNumber.activeForeground"] == p.edGutterActive.css)
            #expect(theme["editor.lineHighlightBackground"] == p.edLine.css)
            #expect(theme["editor.selectionBackground"] == p.edSel.css)
            #expect(theme["editorIndentGuide.background1"] == p.edIndent.css)
            #expect(theme["editorBracketHighlight.foreground1"] == "#ffd700")
        }
        // Translucent diff tints keep their alpha (`#rrggbbaa`).
        let dark = EditorTheme(palette: .darkPlus, customBase: .darkModern, custom: [:], app: .darkPlus)
        let colors = try #require(MonacoTheme.json(dark)["colors"] as? [String: String])
        #expect(colors["diffEditor.insertedLineBackground"] == "#9bb95533")
        // The syntax doesn't depend on the app theme.
        func rules(_ app: AppTheme) -> [[String: String]]? {
            MonacoTheme.json(EditorTheme(palette: .darkPlus, customBase: .darkModern, custom: [:], app: app))["rules"] as? [[String: String]]
        }
        #expect(rules(.navy) == rules(.graphite))
        #expect(MonacoTheme.css(.of(.graphite))["--primary-text"] == "#ffffff")
    }

    @Test func hangarSyntaxRules() throws {
        let t = EditorTheme(palette: .hangar, customBase: .darkModern, custom: [:], app: .navy)
        let rules = try #require(MonacoTheme.json(t)["rules"] as? [[String: String]])
        #expect(rules.contains { $0["token"] == "keyword" && $0["foreground"] == "b79bd9" })
        #expect(rules.contains { $0["token"] == "comment" && $0["foreground"] == "75819a" && $0["fontStyle"] == "italic" })
    }

    /// VS Code Dark+ (#84): Monarch tokens and tsserver's semantic types in Dark+'s colors.
    @Test func darkPlusColors() throws {
        let t = EditorTheme(palette: .darkPlus, customBase: .darkModern, custom: [:], app: .navy)
        let rules = try #require(MonacoTheme.json(t)["rules"] as? [[String: String]])
        func color(_ token: String) -> String? { rules.first { $0["token"] == token }?["foreground"] }
        #expect(color("keyword") == "569cd6" && color("keyword.control") == "c586c0")
        #expect(color("identifier") == "9cdcfe" && color("variable") == "9cdcfe" && color("parameter") == "9cdcfe")
        #expect(color("type.identifier") == "4ec9b0" && color("class") == "4ec9b0" && color("interface") == "4ec9b0")
        #expect(color("function") == "dcdcaa" && color("member") == "dcdcaa")
        #expect(color("string") == "ce9178" && color("number") == "b5cea8" && color("comment") == "6a9955")
        #expect(color("constant") == "4fc1ff" && color("delimiter") == "d4d4d4")
        #expect(color("tag") == "569cd6" && color("attribute.name") == "9cdcfe")
    }

    @Test func bundledMonacoIsThere() throws {
        let dir = try #require(L10n.resources?.url(forResource: "Monaco", withExtension: nil))
        for file in ["vs/loader.js", "vs/editor/editor.main.js", "vs/editor/editor.main.css", "hangar/index.html", "hangar/hangar.js", "LICENSE.txt"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), "\(file)")
        }
    }

    /// JSON is tokenized by the json mode (no Monarch grammar): switching its tokens off left .json files plain white.
    @Test func jsonKeepsItsTokenizerAndExtraExtensionsAreMapped() throws {
        let dir = try #require(L10n.resources?.url(forResource: "Monaco", withExtension: nil))
        let js = try String(contentsOf: dir.appendingPathComponent("hangar/hangar.js"), encoding: .utf8)
        #expect(js.contains("Object.assign({}, off, { tokens: true })") && js.contains("jsonDefaults.setModeConfiguration(jsonOn)"))
        for ext in ["'.jsonc'", "'.json5'", "'.toml'", "'.zshrc'", "'.mjs'"] { #expect(js.contains(ext), "\(ext)") }
        let vs = dir.appendingPathComponent("vs")
        #expect(FileManager.default.fileExists(atPath: vs.appendingPathComponent("jsonMode-w7Q_ZLTt.js").path))
    }
}
