import AppKit
import GhosttyBridge
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
