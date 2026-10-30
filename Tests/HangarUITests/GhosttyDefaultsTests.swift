import AppKit
@testable import GhosttyBridge
import Testing
@testable import HangarUI

/// Hangar's Ghostty defaults load before the user's config (their values win): padding and the theme's ANSI palette
/// when the user's config (or Ghostty theme) sets none. Background, text and cursor load after theirs (#109).
@MainActor @Suite struct GhosttyDefaultsTests {
    @Test func defaultsHoldPadding() {
        #expect(GhosttyApp.defaultsConfig(padding: (x: 12, y: 8)) == "window-padding-x = 12\nwindow-padding-y = 8\n")
        #expect(GhosttyApp.defaultsConfig(padding: nil).isEmpty)
    }

    @Test func defaultsHoldPalette() {
        let palette = (0..<16).map { String(format: "%06x", $0) }
        let text = GhosttyApp.defaultsConfig(padding: nil, palette: palette)
        #expect(text.hasPrefix("palette = 0=#000000\npalette = 1=#000001\n"))
        #expect(text.hasSuffix("palette = 15=#00000f\n"))
        // What the user's config sets is left out, so theirs stays.
        #expect(GhosttyApp.defaultsConfig(padding: nil, palette: []).isEmpty)
    }

    /// Parallel instances (the real app and a debug copy) must not share a file.
    @Test func configFileNameIsPerProcess() {
        #expect(GhosttyApp.configFileName("defaults", pid: 42) == "hangar-ghostty-defaults-42.conf")
        #expect(GhosttyApp.configFileName("defaults", pid: 42) != GhosttyApp.configFileName("defaults", pid: 43))
        #expect(GhosttyApp.configFileName("overrides", pid: 42) != GhosttyApp.configFileName("defaults", pid: 42))
    }

    @Test func cursorIsTheAccentTextAndTextTheThemes() {
        #expect(Theme.terminalColors().cursor == String(cssHex(Theme.accentText).dropFirst()))
        #expect(Theme.terminalColors(of: .of(.navy)).foreground == "e3e7ef")
    }
}

/// The layering around the user's Ghostty config, through libghostty itself (decisions #87, #109): the app theme's
/// background beats the user's `theme` and own `background`, and a rebuilt config carries the new theme (what open
/// surfaces get on switch); the user's palette stays theirs.
@MainActor @Suite struct GhosttyLayersTests {
    private func colors(_ bg: String) -> TerminalColors {
        TerminalColors(background: bg, foreground: "e3e7ef", palette: Array(repeating: "808080", count: 16), cursor: "2a6fd6")
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
        let overrides = "background = 121826\nforeground = e3e7ef\ncursor-color = 2a6fd6\n"
        let theirs = GhosttyApp.layers(colors("121826"), padding: nil, userPalette: true)
        #expect(theirs.overrides == overrides)
        #expect(!theirs.defaults.contains("background") && !theirs.defaults.contains("palette"))
        let ours = GhosttyApp.layers(colors("121826"), padding: nil, userPalette: false)
        #expect(ours.overrides == overrides)
        #expect(!ours.defaults.contains("background") && ours.defaults.contains("palette = 0=#808080"))
    }

    @Test func userThemeAgainstHangarBackground() throws {
        #expect(GhosttyApp.initialized)
        defer { GhosttyApp.removeConfigFiles() }
        let themed = try userConfig("theme = $THEME\n")
        defer { try? FileManager.default.removeItem(at: themed.deletingLastPathComponent()) }
        #expect(GhosttyApp.userSetsPalette([themed]))
        // Every theme switch wins over the user's theme.
        #expect(GhosttyApp.resolvedColor("background", colors("121826"), userFiles: [themed]) == "121826")
        #expect(GhosttyApp.resolvedColor("background", colors("232220"), userFiles: [themed]) == "232220")
        // No background of their own: the Hangar theme's too.
        let plain = try userConfig("font-size = 13\n")
        defer { try? FileManager.default.removeItem(at: plain.deletingLastPathComponent()) }
        #expect(!GhosttyApp.userSetsPalette([plain]))
        #expect(GhosttyApp.resolvedColor("background", colors("1e1e1e"), userFiles: [plain]) == "1e1e1e")
        #expect(GhosttyApp.resolvedColor("background", colors("232220"), userFiles: [plain]) == "232220")
    }

    /// `background = …` in the user's own config (no theme) behaves like a theme's.
    @Test func userBackgroundSetDirectly() throws {
        #expect(GhosttyApp.initialized)
        defer { GhosttyApp.removeConfigFiles() }
        let direct = try userConfig("background = #203040\n")
        defer { try? FileManager.default.removeItem(at: direct.deletingLastPathComponent()) }
        #expect(!GhosttyApp.userSetsPalette([direct]))
        #expect(GhosttyApp.resolvedColor("background", colors("121826"), userFiles: [direct]) == "121826")
    }

    /// A light Ghostty theme's dark text and cursor would vanish on the app theme's dark background: ours win too.
    @Test func lightUserThemeGetsTheAppThemesText() throws {
        #expect(GhosttyApp.initialized)
        defer { GhosttyApp.removeConfigFiles() }
        let light = try userConfig("background = #fafafa\nforeground = #202020\ncursor-color = #101010\n")
        defer { try? FileManager.default.removeItem(at: light.deletingLastPathComponent()) }
        #expect(GhosttyApp.resolvedColor("background", colors("121826"), userFiles: [light]) == "121826")
        #expect(GhosttyApp.resolvedColor("foreground", colors("121826"), userFiles: [light]) == "e3e7ef")
    }
}
