import Foundation
import Testing
@testable import Workspace

@Suite struct ConfigTests {
    @Test func defaultsWhenEmpty() throws {
        let c = try HangarConfig.parse("")
        #expect(c == HangarConfig())
        #expect(c.defaultAgent == .claude)
        #expect(c.agentCommands == [.claude: "claude", .codex: "codex"])
    }

    @Test func parsesSubset() throws {
        let c = try HangarConfig.parse("""
        # comment
        default_agent = "codex"

        editor = "nvim"   # trailing comment
        [agents]
        claude = "claude --model opus"
        """)
        #expect(c.defaultAgent == .codex)
        #expect(c.agentCommands[.claude] == "claude --model opus")
        #expect(c.agentCommands[.codex] == "codex")
    }

    /// The Helix-era `editor` key (#81) is ignored, so an old config still loads.
    @Test func legacyEditorKeyIgnored() throws {
        #expect(try HangarConfig.parse(#"editor = "hx""#) == HangarConfig())
    }

    @Test func rejectsUnknownAgent() {
        #expect(throws: (any Error).self) { try HangarConfig.parse(#"default_agent = "gpt""#) }
    }

    @Test func missingFileNoWarning() {
        let r = HangarConfig.load(from: URL(fileURLWithPath: "/nonexistent/hangar/config.toml"))
        #expect(r.config == HangarConfig())
        #expect(r.warning == nil)
    }

    @Test func invalidFileYieldsWarning() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangar-\(UUID()).toml")
        try "editor = hx\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = HangarConfig.load(from: url)
        #expect(r.config == HangarConfig())
        #expect(r.warning?.contains("line 1") == true)
        #expect(r.warning?.contains(url.lastPathComponent) == true)
    }

    @Test func parseErrorsCarryLines() {
        #expect(throws: HangarConfig.ParseError.syntax(line: 2, reason: "unterminated string")) {
            try HangarConfig.parse("editor = \"hx\"\neditor = \"nv")
        }
        #expect(throws: (any Error).self) { try HangarConfig.parse("[agents]\nfoo = \"x\"") }
        #expect("\(HangarConfig.ParseError.syntax(line: 3, reason: "x"))".isEmpty == false)
        #expect(HangarConfig.ParseError.syntax(line: 3, reason: "x").description.contains("line 3"))
    }

    @Test func terminalBackgroundDefaultsToHangar() throws {
        #expect(try HangarConfig.parse("").terminalBackground == .hangar)
        #expect(try HangarConfig.parse(#"terminal_background = "ghostty""#).terminalBackground == .ghostty)
        #expect(try HangarConfig.parse(#"terminal_background = "hangar""#).terminalBackground == .hangar)
        // The old «theme» meant the Ghostty theme's background: it migrates to «ghostty», not to the Hangar theme.
        #expect(try HangarConfig.parse(#"terminal_background = "theme""#).terminalBackground == .ghostty)
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse(#"terminal_background = "blue""#) }
    }

    /// App theme (themes-v1.html): Dark+ by default, for new and existing configs alike.
    @Test func themeFromConfig() throws {
        #expect(try HangarConfig.parse("").theme == .darkPlus)
        #expect(try HangarConfig.parse("language = \"en\"\nterminal_background = \"hangar\"").theme == .darkPlus)
        #expect(try HangarConfig.parse(#"theme = "dark-plus""#).theme == .darkPlus)
        #expect(try HangarConfig.parse(#"theme = "graphite""#).theme == .graphite)
        #expect(try HangarConfig.parse(#"theme = "navy""#).theme == .navy)
        #expect(AppTheme.allCases.map(\.rawValue) == ["dark-plus", "graphite", "navy"])
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse(#"theme = "dark-modern""#) }
    }

    @Test func languageFromConfig() throws {
        #expect(try HangarConfig.parse(#"language = "en""#).language == .en)
        #expect(try HangarConfig.parse(#"language = "ru""#).language == .ru)
        #expect(try HangarConfig.parse(#"language = "system""#).language == .system)
        #expect(try HangarConfig.parse("").language == .system)
        #expect(throws: HangarConfig.ParseError.syntax(line: 2, reason: #"language must be "system", "ru" or "en""#)) {
            try HangarConfig.parse("# c\nlanguage = \"de\"")
        }
    }

    @Test func externalEditorFromConfig() throws {
        #expect(try HangarConfig.parse("").externalEditor == nil)
        #expect(try HangarConfig.parse(#"external_editor = "zed""#).externalEditor == "zed")
        #expect(try HangarConfig.parse(#"external_editor = """#).externalEditor == nil)
    }

    @Test func configWriterChangesOnlyOneKey() throws {
        let text = """
        # Hangar config
        default_agent = "codex"   # mine
        language = "ru"  # ui language
        editor = "nvim"

        [agents]
        claude = "claude --model opus"

        """
        let changed = HangarConfig.updating(text, key: "language", value: "en")
        var expected = text.components(separatedBy: "\n")
        expected[2] = #"language = "en"  # ui language"#
        #expect(changed == expected.joined(separator: "\n"))
        #expect(try HangarConfig.parse(changed).language == .en)

        // Missing key: appended to the end of the root section, before the first [section].
        let added = HangarConfig.updating(text, key: "terminal_background", value: "theme")
        var lines = text.components(separatedBy: "\n")
        lines.insert(#"terminal_background = "theme""#, at: 4)
        #expect(added == lines.joined(separator: "\n"))

        // Values are escaped; a key under [agents] with the same name is not the root key.
        let tricky = "[agents]\nclaude = \"x\"\n"
        #expect(HangarConfig.updating(tricky, key: "editor", value: #"a"b"#) == "editor = \"a\\\"b\"\n[agents]\nclaude = \"x\"\n")
        #expect(HangarConfig.updating("", key: "language", value: "en") == "language = \"en\"\n")
        #expect(HangarConfig.updating("editor = \"hx\"", key: "language", value: "en") == "editor = \"hx\"\nlanguage = \"en\"")
    }

    @Test func configSaveCreatesOrEditsFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try HangarConfig.save(key: "language", value: "en", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "language = \"en\"\n")
        try "# keep\neditor = \"hx\"\n".write(to: url, atomically: true, encoding: .utf8)
        try HangarConfig.save(key: "editor", value: "nvim", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# keep\neditor = \"nvim\"\n")
    }

    @Test func crlfPreserved() {
        let text = "# c\r\neditor = \"hx\"\r\n\r\n[agents]\r\nclaude = \"x\"\r\n"
        #expect(HangarConfig.updating(text, key: "editor", value: "nvim")
            == "# c\r\neditor = \"nvim\"\r\n\r\n[agents]\r\nclaude = \"x\"\r\n")
        #expect(HangarConfig.updating(text, key: "language", value: "en")
            == "# c\r\neditor = \"hx\"\r\nlanguage = \"en\"\r\n\r\n[agents]\r\nclaude = \"x\"\r\n")
        // Last line without a terminator gets the file's ending before the appended key.
        #expect(HangarConfig.updating("# c\r\neditor = \"hx\"", key: "language", value: "en")
            == "# c\r\neditor = \"hx\"\r\nlanguage = \"en\"")
    }

    @Test func hashInsideQuotesKept() {
        #expect(HangarConfig.updating(#"editor = "a#b"  # mine"#, key: "editor", value: "nvim") == #"editor = "nvim"  # mine"#)
        #expect(HangarConfig.updating(#"editor = "a#b""#, key: "editor", value: "nvim") == #"editor = "nvim""#)
        #expect(HangarConfig.updating("editor = 'a#b'  # mine", key: "editor", value: "nvim") == #"editor = "nvim"  # mine"#)
    }

    @Test func commentKeptForUnquotedValue() {
        #expect(HangarConfig.updating("editor = hx   # mine", key: "editor", value: "nvim") == #"editor = "nvim"   # mine"#)
        #expect(HangarConfig.updating("editor = hx", key: "editor", value: "nvim") == #"editor = "nvim""#)
    }

    @Test func permissionsPreserved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try "editor = \"hx\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try HangarConfig.save(key: "language", value: "en", to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "editor = \"hx\"\nlanguage = \"en\"\n")
    }

    @Test func notificationBools() throws {
        #expect(try HangarConfig.parse("notifications = false").notifications == false)
        #expect(try HangarConfig.parse("limit_notifications = false").limitNotifications == false)
        let d = try HangarConfig.parse("")
        #expect(d.notifications && d.limitNotifications)
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse(#"notifications = "no""#) }
        #expect(HangarConfig.updating("", key: "notifications", literal: "false") == "notifications = false\n")
        #expect(HangarConfig.updating("notifications = true  # mine", key: "notifications", literal: "false")
            == "notifications = false  # mine")
    }

    @Test func keepAwakeFlag() throws {
        #expect(try HangarConfig.parse("").keepAwake)
        #expect(try HangarConfig.parse("keep_awake = false").keepAwake == false)
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse(#"keep_awake = "no""#) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-keep-\(UUID()).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "language = \"en\"\nnotifications = false\n".write(to: url, atomically: true, encoding: .utf8)
        try HangarConfig.save(key: "keep_awake", literal: "false", to: url)
        let c = try HangarConfig.parse(String(contentsOf: url, encoding: .utf8))
        #expect(!c.keepAwake && c.language == .en && !c.notifications)
    }

    @Test func dockBadgeFlag() throws {
        #expect(try HangarConfig.parse("").dockBadge)
        #expect(try HangarConfig.parse("dock_badge = false").dockBadge == false)
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse(#"dock_badge = "no""#) }
    }

    /// Settings → Editor: the syntax palette (VS Code Dark+ by default) and the rainbow indents / TODO highlights.
    @Test func editorAppearanceKeys() throws {
        let d = HangarConfig()
        #expect(d.editorPalette == .darkPlus && d.editorRainbowIndent && d.editorTodoHighlight)
        let c = try HangarConfig.parse("editor_palette = \"hangar\"\neditor_rainbow_indent = false\neditor_todo_highlight = false")
        #expect(c.editorPalette == .hangar && !c.editorRainbowIndent && !c.editorTodoHighlight)
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse("editor_palette = \"monokai\"") }
        #expect(throws: HangarConfig.ParseError.self) { try HangarConfig.parse("editor_rainbow_indent = \"yes\"") }
    }
}
