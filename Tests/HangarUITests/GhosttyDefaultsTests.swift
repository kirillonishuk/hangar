import AppKit
@testable import GhosttyBridge
import Testing
@testable import HangarUI

/// Hangar's Ghostty defaults load before the user's config (their values win): padding, the accent cursor, and the
/// theme's background and ANSI palette when the user's config (or Ghostty theme) sets none.
@MainActor @Suite struct GhosttyDefaultsTests {
    @Test func defaultsHoldPaddingAndCursor() {
        #expect(GhosttyApp.defaultsConfig(padding: (x: 12, y: 8), cursor: "61afef")
                == "window-padding-x = 12\nwindow-padding-y = 8\ncursor-color = 61afef\n")
        #expect(GhosttyApp.defaultsConfig(padding: nil, cursor: "61afef") == "cursor-color = 61afef\n")
        #expect(GhosttyApp.defaultsConfig(padding: nil, cursor: nil).isEmpty)
    }

    @Test func defaultsHoldBackgroundAndPalette() {
        let palette = (0..<16).map { String(format: "%06x", $0) }
        let text = GhosttyApp.defaultsConfig(padding: nil, cursor: nil, background: "1e1e1e", palette: palette)
        #expect(text.hasPrefix("background = 1e1e1e\npalette = 0=#000000\npalette = 1=#000001\n"))
        #expect(text.hasSuffix("palette = 15=#00000f\n"))
        // What the user's config sets is left out, so theirs stays.
        #expect(GhosttyApp.defaultsConfig(padding: nil, cursor: nil, background: nil, palette: []).isEmpty)
    }

    /// Parallel instances (the real app and a debug copy) must not share a file.
    @Test func configFileNameIsPerProcess() {
        #expect(GhosttyApp.configFileName("defaults", pid: 42) == "hangar-ghostty-defaults-42.conf")
        #expect(GhosttyApp.configFileName("defaults", pid: 42) != GhosttyApp.configFileName("defaults", pid: 43))
        #expect(GhosttyApp.configFileName("overrides", pid: 42) != GhosttyApp.configFileName("defaults", pid: 42))
    }

    @Test func cursorIsTheAccent() {
        #expect(Theme.terminalColors(force: false).cursor == String(cssHex(Theme.accent).dropFirst()))
    }
}

/// The layering around the user's Ghostty config, through libghostty itself (decision #87): «как тема» beats the
/// user's `theme`, «из Ghostty» keeps it, and a rebuilt config carries the new theme (what open surfaces get on switch).
@MainActor @Suite struct GhosttyLayersTests {
    private func colors(_ bg: String, force: Bool) -> TerminalColors {
        TerminalColors(background: bg, palette: Array(repeating: "808080", count: 16), cursor: "2a6fd6", forceBackground: force)
    }

    private func userConfig(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-ghostty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let theme = dir.appendingPathComponent("theme"), config = dir.appendingPathComponent("config")
        try "background = #5a1040\npalette = 1=#ff3060\n".write(to: theme, atomically: true, encoding: .utf8)
        try text.replacingOccurrences(of: "$THEME", with: theme.path).write(to: config, atomically: true, encoding: .utf8)
        return config
    }

    @Test func pureLayers() {
        let forced = GhosttyApp.layers(colors("121826", force: true), padding: nil, userBackground: true, userPalette: true)
        #expect(forced.overrides == "background = 121826\n")
        #expect(!forced.defaults.contains("background"))
        let kept = GhosttyApp.layers(colors("121826", force: false), padding: nil, userBackground: true, userPalette: false)
        #expect(kept.overrides == nil)
        #expect(!kept.defaults.contains("background") && kept.defaults.contains("palette = 0=#808080"))
        let unset = GhosttyApp.layers(colors("121826", force: false), padding: nil, userBackground: false, userPalette: false)
        #expect(unset.defaults.contains("background = 121826"))
    }

    @Test func userThemeAgainstHangarBackground() throws {
        #expect(GhosttyApp.initialized)
        let themed = try userConfig("theme = $THEME\n")
        #expect(GhosttyApp.userSets([themed]) == (background: true, palette: true))
        // «как тема»: every theme switch wins over the user's theme.
        #expect(GhosttyApp.resolvedBackground(colors("121826", force: true), userFiles: [themed]) == "121826")
        #expect(GhosttyApp.resolvedBackground(colors("232220", force: true), userFiles: [themed]) == "232220")
        // «из Ghostty»: the user's theme stays.
        #expect(GhosttyApp.resolvedBackground(colors("121826", force: false), userFiles: [themed]) == "5a1040")
        // No background of their own: the Hangar theme's, in both modes.
        let plain = try userConfig("font-size = 13\n")
        #expect(GhosttyApp.userSets([plain]) == (background: false, palette: false))
        #expect(GhosttyApp.resolvedBackground(colors("1e1e1e", force: false), userFiles: [plain]) == "1e1e1e")
        #expect(GhosttyApp.resolvedBackground(colors("232220", force: false), userFiles: [plain]) == "232220")
        GhosttyApp.removeConfigFiles()
    }
}
