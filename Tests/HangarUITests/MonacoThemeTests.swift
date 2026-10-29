import Foundation
import Testing
import Workspace
@testable import HangarUI

/// Editor themes (#108): VS Code Dark Modern's values, «Своя» over a base, the config changes of the color editor.
@Suite struct MonacoThemeTests {
    private func theme(_ palette: EditorPalette, base: EditorPalette = .darkModern, custom: [EditorColor: String] = [:],
                       app: AppTheme = .navy) -> EditorTheme {
        EditorTheme(palette: palette, customBase: base, custom: custom, app: app)
    }

    private func json(_ t: EditorTheme) throws -> (rules: [String: String], colors: [String: String]) {
        let j = MonacoTheme.json(t)
        let rules = try #require(j["rules"] as? [[String: String]])
        let colors = try #require(j["colors"] as? [String: String])
        return (Dictionary(rules.map { ($0["token"]!, $0["foreground"]!) }) { a, _ in a }, colors)
    }

    /// The spec's tables (§2), one by one: dark_modern.json → dark_plus.json → dark_vs.json and the color registry.
    @Test(arguments: AppTheme.allCases) func darkModernMatchesVSCode(_ app: AppTheme) throws {
        let (rules, colors) = try json(theme(.darkModern, app: app))
        let syntax: [String: String] = [
            "keyword": "569cd6", "tag": "569cd6", "metatag": "569cd6", "keyword.json": "569cd6", "keyword.control": "c586c0",
            "identifier": "9cdcfe", "variable": "9cdcfe", "parameter": "9cdcfe", "property": "9cdcfe", "attribute.name": "9cdcfe",
            "string.key.json": "9cdcfe", "type": "4ec9b0", "type.identifier": "4ec9b0", "class": "4ec9b0", "interface": "4ec9b0",
            "enum": "4ec9b0", "namespace": "4ec9b0", "typeParameter": "4ec9b0", "annotation": "4ec9b0", "function": "dcdcaa",
            "member": "dcdcaa", "predefined": "dcdcaa", "constant": "4fc1ff", "enumMember": "4fc1ff", "string": "ce9178",
            "string.value.json": "ce9178", "attribute.value": "ce9178", "string.escape": "d7ba7d", "regexp": "d16969",
            "number": "b5cea8", "comment": "6a9955", "comment.doc": "6a9955", "operator": "d4d4d4", "delimiter": "cccccc",
            "delimiter.bracket": "cccccc", "": "cccccc",
        ]
        for (token, hex) in syntax { #expect(rules[token] == hex, "\(token)") }
        let ui: [String: String] = [
            "editor.background": "#1f1f1f", "editorGutter.background": "#1f1f1f", "minimap.background": "#1f1f1f",
            "peekViewEditor.background": "#1f1f1f", "editor.foreground": "#cccccc", "editorLineNumber.foreground": "#6e7681",
            "editorLineNumber.activeForeground": "#cccccc", "editorCursor.foreground": "#aeafad",
            "editor.lineHighlightBorder": "#282828", "editor.lineHighlightBackground": "#00000000",
            "editor.selectionBackground": "#264f78", "editor.inactiveSelectionBackground": "#3a3d41",
            "editorIndentGuide.background1": "#404040", "editorIndentGuide.activeBackground1": "#707070",
            "editorWhitespace.foreground": "#e3e4e229", "editor.findMatchBackground": "#9e6a03",
            "editor.findMatchHighlightBackground": "#ea5c0055", "editorBracketMatch.background": "#0064001a",
            "editorBracketMatch.border": "#888888", "editorBracketHighlight.foreground1": "#ffd700",
            "editorBracketHighlight.foreground2": "#da70d6", "editorBracketHighlight.foreground3": "#179fff",
            "diffEditor.insertedLineBackground": "#9bb95533", "diffEditor.removedLineBackground": "#ff000033",
            "diffEditorGutter.insertedLineBackground": "#9bb95533", "diffEditorGutter.removedLineBackground": "#ff000033",
            "diffEditor.insertedTextBackground": "#9ccc2c33", "diffEditor.removedTextBackground": "#ff000033",
        ]
        for (key, hex) in ui { #expect(colors[key] == hex, "\(key)") }
        // Widgets stay Hangar's.
        #expect(colors["editorWidget.background"] == ThemePalette.of(app).sheet.css)
    }

    /// Every syntax group colors some token, every other color lands in Monaco's colors.
    @Test func everyColorIsUsed() throws {
        let marked = Dictionary(uniqueKeysWithValues: EditorColor.allCases.enumerated().map { i, c in
            (c, String(format: "#%06x", 0x101010 + i * 0x010203))
        })
        let (rules, colors) = try json(theme(.custom, custom: marked))
        for color in EditorColor.allCases {
            if color.section == .syntax {
                #expect(!color.tokens.isEmpty && color.tokens.allSatisfy { rules[$0] == EditorHex.rgb(marked[color]!) }, "\(color)")
            } else {
                #expect(colors.values.contains(marked[color]!), "\(color)")
            }
        }
    }

    @Test func customIsBasePlusChanges() throws {
        let t = theme(.custom, base: .darkModern, custom: [.string: "#d69d85", .background: "#1b1b1b"])
        #expect(t.base == .darkModern && t.changed == [.string, .background])
        let (rules, colors) = try json(t)
        #expect(rules["string"] == "d69d85" && rules["keyword"] == "569cd6")
        #expect(colors["editor.background"] == "#1b1b1b" && colors["editorCursor.foreground"] == "#aeafad")
        // A changed selection drags its inactive shade along.
        #expect(try json(theme(.custom, custom: [.selection: "#112233"])).colors["editor.inactiveSelectionBackground"] == "#11223399")
        // Built-in themes ignore «Своя»'s colors.
        #expect(try json(theme(.darkModern, custom: [.string: "#d69d85"])).rules["string"] == "ce9178")
    }

    /// On a Dark+ base, colors «Своя» didn't change follow the app theme, as the built-in does.
    @Test func customOnDarkPlusFollowsTheAppTheme() throws {
        let navy = try json(theme(.custom, base: .darkPlus, custom: [.string: "#d69d85"], app: .navy)).colors
        let dark = try json(theme(.custom, base: .darkPlus, custom: [.string: "#d69d85"], app: .darkPlus)).colors
        #expect(navy["editor.background"] == ThemePalette.navy.editorBg.css)
        #expect(navy["editor.background"] != dark["editor.background"])
        #expect(navy["editor.lineHighlightBackground"] == ThemePalette.navy.edLine.css)
    }

    @Test(arguments: [EditorPalette.darkModern, .darkPlus, .hangar], AppTheme.allCases)
    func builtInsAreReadable(_ palette: EditorPalette, _ app: AppTheme) {
        let t = theme(palette, app: app)
        func luminance(_ hex: String) -> Double {
            let c = EditorHex.components(hex)!
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        func contrast(_ a: EditorColor) -> Double {
            let x = luminance(t.hex(a)), y = luminance(t.hex(.background))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        #expect(contrast(.text) >= 4.5)
        #expect(contrast(.comment) >= 3)
    }

    // MARK: «Своя» from the color editor

    @Test func editingABuiltInCreatesCustom() {
        var c = HangarConfig()
        c.theme = .navy
        #expect(!c.customizingReplacesColors)
        let n = c.customizing(.string, "#d69d85")
        #expect(n.editorPalette == .custom && n.editorCustomBase == .darkModern && n.editorColors == [.string: "#d69d85"])
        // The base's own value is no change.
        #expect(n.customizing(.keyword, "#569cd6").editorColors == [.string: "#d69d85"])
        #expect(n.customizing(.string, "#ce9178").editorColors.isEmpty)
        // Editing «Своя» again adds to it.
        #expect(n.customizing(.number, "#ffffff").editorColors == [.string: "#d69d85", .number: "#ffffff"])
    }

    @Test func anotherBaseReplacesTheChangesAfterAsking() {
        var c = HangarConfig()
        c.editorCustomBase = .darkModern
        c.editorColors = [.string: "#d69d85"]
        c.editorPalette = .darkPlus
        #expect(c.customizingReplacesColors)
        let n = c.customizing(.number, "#ffffff")
        #expect(n.editorPalette == .custom && n.editorCustomBase == .darkPlus && n.editorColors == [.number: "#ffffff"])
        // Same base: «Своя»'s changes stay and the new one joins them.
        c.editorPalette = .darkModern
        #expect(!c.customizingReplacesColors)
        #expect(c.customizing(.number, "#ffffff").editorColors == [.string: "#d69d85", .number: "#ffffff"])
    }

    @Test func reset() {
        var c = HangarConfig()
        c.editorPalette = .custom
        c.editorColors = [.string: "#d69d85", .number: "#ffffff"]
        #expect(c.resettingColor(.string).editorColors == [.number: "#ffffff"])
        #expect(c.resettingColor(nil).editorColors.isEmpty && c.resettingColor(nil).editorPalette == .custom)
    }

    /// Only the keys that differ are written; a reset color's line leaves the file, comments stay.
    @Test func configEditWritesOnlyTheDifference() throws {
        let text = "# mine\ntheme = \"navy\"\neditor_color_number = \"#ffffff\" # bright\n"
        var old = try HangarConfig.parse(text)
        old.editorPalette = .darkPlus
        let created = old.customizing(.string, "#d69d85")
        let written = old.editorThemeEdit(to: created)(text)
        #expect(written == "# mine\ntheme = \"navy\"\neditor_palette = \"custom\"\neditor_custom_base = \"dark-plus\"\neditor_color_string = \"#d69d85\"\n")
        let parsed = try HangarConfig.parse(written)
        #expect(parsed.editorPalette == .custom && parsed.editorCustomBase == .darkPlus && parsed.editorColors == [.string: "#d69d85"])
        let reset = parsed.editorThemeEdit(to: parsed.resettingColor(.string))(written)
        #expect(reset == "# mine\ntheme = \"navy\"\neditor_palette = \"custom\"\neditor_custom_base = \"dark-plus\"\n")
        #expect(parsed.editorThemeEdit(to: parsed)(written) == written)
    }

    // MARK: Options and helpers

    @Test func appearanceCarriesTheOptions() throws {
        var c = HangarConfig()
        c.editorOptions.cursorBlinking = .blink
        c.editorOptions.bracketGuides = .none
        c.editorOptions.fontFamily = "Menlo"
        c.editorOptions.fontSize = 12
        c.editorOptions.formatOnSave = true
        let j = EditorAppearance(c).json
        let o = try #require(j["options"] as? [String: Any])
        #expect(o["cursorBlinking"] as? String == "blink" && o["fontSize"] as? Int == 12 && o["lineHeight"] as? Int == 18)
        #expect(o["fontFamily"] as? String == "\"Menlo\", ui-monospace, monospace")
        #expect((o["guides"] as? [String: Any])?["bracketPairs"] as? Bool == false)
        c.editorOptions.bracketGuides = .active
        #expect((EditorAppearance(c).json["options"] as? [String: Any]).flatMap { ($0["guides"] as? [String: Any])?["bracketPairs"] as? String } == "active")
        #expect(j["formatOnSave"] as? Bool == true && j["palette"] as? String == "editor")
        #expect((j["css"] as? [String: String])?["--bg"] == "#1f1f1f")
        let defaults = try #require(EditorAppearance(HangarConfig()).json["options"] as? [String: Any])
        #expect(defaults["fontFamily"] as? String == "ui-monospace, Menlo, monospace" && defaults["lineHeight"] as? Int == 20)
    }

    @Test func hslRoundTrip() {
        for hex in ["#569cd6", "#ce9178", "#1f1f1f", "#ffffff", "#000000", "#4ec9b0", "#da70d6"] {
            let x = EditorHex.hsl(hex)
            #expect(EditorHex.fromHSL(h: x.h, s: x.s, l: x.l) == hex)
        }
        #expect(EditorHex.with("#9bb955", alpha: 0.2) == "#9bb95533")
        #expect(EditorHex.with("#9bb95533", alpha: 1) == "#9bb955")
        #expect(abs(EditorHex.alpha("#ff000033") - 0.2) < 0.01)
    }

    /// The preview's samples parse into tokens of known groups, and the TypeScript one fits the minimum page width.
    @Test func previewSamples() {
        for sample in EditorPreviewSample.allCases {
            let lines = sample.lines
            #expect(!lines.isEmpty && lines.count <= Theme.EditorSettings.previewLines)
            #expect(lines.allSatisfy { $0.runs.allSatisfy { !$0.text.contains("«") && !$0.text.contains("»") } })
            #expect(lines.map { $0.indent + $0.runs.map(\.text.count).reduce(0, +) }.max()! <= 46)
        }
        let ts = EditorPreviewSample.typescript
        for color in EditorColor.allCases where color.section == .syntax && color != .jsonKey && color != .text {
            #expect(ts.shows(color), "\(color)")
        }
        #expect(EditorPreviewSample.json.shows(.jsonKey) && !EditorPreviewSample.typescript.shows(.diffAddedLine))
        #expect(EditorPreviewSample.diff.lines.contains { $0.change == .added } && EditorPreviewSample.diff.lines.contains { $0.change == .removed })
    }
}
