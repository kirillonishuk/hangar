import Foundation
import Testing
@testable import Workspace

/// Settings → Editor (#108): the editor theme, «Своя» colors and the editor options in config.toml.
@Suite struct EditorConfigTests {
    @Test func defaults() {
        let c = HangarConfig()
        #expect(c.editorPalette == .darkModern)
        #expect(c.editorCustomBase == .darkModern)
        #expect(c.editorColors.isEmpty)
        let o = c.editorOptions
        #expect(o.fontFamily == nil && o.fontSize == 13 && o.lineHeight == 0 && !o.ligatures)
        #expect(o.tabSize == 4 && o.detectIndentation && !o.wordWrap)
        #expect(o.lineHighlight == .all && o.cursorStyle == .line && o.cursorBlinking == .solid && o.whitespace == .selection)
        #expect(o.bracketColors && o.bracketGuides == .active && o.indentGuides && !o.formatOnSave)
        #expect(o.resolvedLineHeight == 20)  // «авто» = round(1.5 × 13)
    }

    @Test func palettes() throws {
        #expect(try HangarConfig.parse(#"editor_palette = "dark-modern""#).editorPalette == .darkModern)
        #expect(try HangarConfig.parse(#"editor_palette = "dark-plus""#).editorPalette == .darkPlus)
        #expect(try HangarConfig.parse(#"editor_palette = "custom""#).editorPalette == .custom)
        #expect(try HangarConfig.parse(#"editor_custom_base = "hangar""#).editorCustomBase == .hangar)
        // «Своя» is based on a built-in theme, never on itself.
        #expect(throws: HangarConfig.ParseError.syntax(line: 1, reason: #"editor_custom_base must be "dark-modern", "dark-plus" or "hangar""#)) {
            try HangarConfig.parse(#"editor_custom_base = "custom""#)
        }
    }

    @Test func colors() throws {
        let c = try HangarConfig.parse("""
        editor_color_string = "#D69D85"
        editor_color_background = "#1b1"
        editor_color_selection = "#264f7880"   # with alpha
        """)
        #expect(c.editorColors == [.string: "#d69d85", .background: "#11bb11", .selection: "#264f7880"])
        #expect(EditorColor(rawValue: "json_key") == .jsonKey)
        #expect(EditorColor.diffRemovedText.configKey == "editor_color_diff_removed_text")
        #expect(EditorColor.allCases.count == 32)
    }

    @Test func badColorsNameTheLine() {
        #expect(throws: HangarConfig.ParseError.unknownKey(line: 2, key: "editor_color_sparkle")) {
            try HangarConfig.parse("# c\neditor_color_sparkle = \"#ffffff\"")
        }
        for bad in ["red", "#12", "#12345", "#gggggg", "#1234567", ""] {
            #expect(throws: HangarConfig.ParseError.syntax(line: 1, reason: "editor_color_string must be #rgb, #rrggbb or #rrggbbaa")) {
                try HangarConfig.parse("editor_color_string = \"\(bad)\"")
            }
        }
    }

    @Test func options() throws {
        let c = try HangarConfig.parse("""
        editor_font_family = "Menlo"
        editor_font_size = "12"
        editor_line_height = 18
        editor_ligatures = true
        editor_tab_size = "2"
        editor_detect_indentation = false
        editor_word_wrap = "on"
        editor_line_highlight = "line"
        editor_cursor_style = "block"
        editor_cursor_blinking = "blink"
        editor_whitespace = "none"
        editor_bracket_colors = false
        editor_bracket_guides = "all"
        editor_indent_guides = false
        editor_format_on_save = true
        """)
        let o = c.editorOptions
        #expect(o.fontFamily == "Menlo" && o.fontSize == 12 && o.lineHeight == 18 && o.ligatures)
        #expect(o.tabSize == 2 && !o.detectIndentation && o.wordWrap)
        #expect(o.lineHighlight == .line && o.cursorStyle == .block && o.cursorBlinking == .blink && o.whitespace == .none)
        #expect(!o.bracketColors && o.bracketGuides == .all && !o.indentGuides && o.formatOnSave)
        #expect(o.resolvedLineHeight == 18)
        #expect(try HangarConfig.parse(#"editor_font_size = "12""#).editorOptions.resolvedLineHeight == 18)
        #expect(try HangarConfig.parse(#"editor_font_family = """#).editorOptions.fontFamily == nil)
    }

    @Test func optionsOutOfRange() {
        for line in [#"editor_font_size = "8""#, #"editor_font_size = "25""#, #"editor_line_height = "9""#, #"editor_line_height = "41""#,
                     #"editor_tab_size = "0""#, #"editor_font_size = "x""#, #"editor_cursor_style = "bar""#, #"editor_word_wrap = "yes""#,
                     #"editor_font_family = "Menlo\"; color: red""#, "editor_format_on_save = \"true\""] {
            #expect(throws: HangarConfig.ParseError.self, "\(line)") { try HangarConfig.parse(line) }
        }
    }

    @Test func hexNormalization() {
        #expect(HangarConfig.normalizedHex("#ABC") == "#aabbcc")
        #expect(HangarConfig.normalizedHex("#aabbccdd") == "#aabbccdd")
        #expect(HangarConfig.normalizedHex(" #aabbcc") == nil)
        #expect(HangarConfig.normalizedHex("aabbcc") == nil)
    }

    // MARK: ConfigWriter.remove

    @Test func removeTouchesOnlyThatKey() {
        let text = """
        # Hangar
        theme = "navy"   # mine
        editor_color_string = "#d69d85"  # warm
        editor_color_background = "#1b1b1b"

        [agents]
        editor_color_string = "keep: not a root key"
        """
        #expect(HangarConfig.removing(text, key: "editor_color_string") == """
        # Hangar
        theme = "navy"   # mine
        editor_color_background = "#1b1b1b"

        [agents]
        editor_color_string = "keep: not a root key"
        """)
        #expect(HangarConfig.removing(text, key: "editor_color_number") == text)
        #expect(HangarConfig.removing("a = \"1\"\r\nb = \"2\"\r\n", key: "a") == "b = \"2\"\r\n")
        #expect(HangarConfig.removing("a = \"1\"", key: "a") == "")
        // A commented-out line with the same name stays.
        #expect(HangarConfig.removing("# a = \"0\"\na = \"1\"\n", key: "a") == "# a = \"0\"\n")
    }

    @Test func removeFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-cfg-\(UUID().uuidString) ё")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try HangarConfig.remove(key: "editor_color_string", from: url)  // no file: nothing to do, nothing created
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try "editor_palette = \"custom\"\neditor_color_string = \"#d69d85\"\n".write(to: url, atomically: true, encoding: .utf8)
        try HangarConfig.remove(key: "editor_color_string", from: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "editor_palette = \"custom\"\n")
        // Several keys in one write (a theme becoming «Своя»).
        try HangarConfig.save(to: url) {
            var t = HangarConfig.updating($0, key: "editor_custom_base", value: "dark-plus")
            t = HangarConfig.updating(t, key: "editor_color_number", value: "#ffffff")
            return HangarConfig.removing(t, key: "editor_palette")
        }
        let c = try HangarConfig.parse(String(contentsOf: url, encoding: .utf8))
        #expect(c.editorPalette == .darkModern && c.editorCustomBase == .darkPlus && c.editorColors == [.number: "#ffffff"])
    }
}
