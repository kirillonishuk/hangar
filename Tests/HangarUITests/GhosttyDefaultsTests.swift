import AppKit
import GhosttyBridge
import Testing
@testable import HangarUI

/// Hangar's Ghostty defaults load before the user's config (their values win): padding and the accent cursor,
/// so the caret no longer follows the system accent colour.
@MainActor @Suite struct GhosttyDefaultsTests {
    @Test func defaultsHoldPaddingAndCursor() {
        #expect(GhosttyApp.defaultsConfig(padding: (x: 12, y: 8), cursor: "61afef")
                == "window-padding-x = 12\nwindow-padding-y = 8\ncursor-color = 61afef\n")
        #expect(GhosttyApp.defaultsConfig(padding: nil, cursor: "61afef") == "cursor-color = 61afef\n")
        #expect(GhosttyApp.defaultsConfig(padding: nil, cursor: nil).isEmpty)
    }

    /// Parallel instances (the real app and a debug copy) must not share a file.
    @Test func configFileNameIsPerProcess() {
        #expect(GhosttyApp.configFileName("defaults", pid: 42) == "hangar-ghostty-defaults-42.conf")
        #expect(GhosttyApp.configFileName("defaults", pid: 42) != GhosttyApp.configFileName("defaults", pid: 43))
        #expect(GhosttyApp.configFileName("overrides", pid: 42) != GhosttyApp.configFileName("defaults", pid: 42))
    }

    @Test func cursorIsTheAccent() throws {
        let hex = try #require(Int(Theme.terminalCursorHex, radix: 16))
        let c = try #require(Theme.accent.usingColorSpace(.sRGB))
        let rgb = Int((c.redComponent * 255).rounded()) << 16 | Int((c.greenComponent * 255).rounded()) << 8 | Int((c.blueComponent * 255).rounded())
        #expect(rgb == hex)
    }
}
