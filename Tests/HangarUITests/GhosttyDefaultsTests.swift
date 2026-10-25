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

    @Test func cursorIsTheAccent() throws {
        let hex = try #require(Int(Theme.terminalCursorHex, radix: 16))
        let c = try #require(Theme.accent.usingColorSpace(.sRGB))
        let rgb = Int((c.redComponent * 255).rounded()) << 16 | Int((c.greenComponent * 255).rounded()) << 8 | Int((c.blueComponent * 255).rounded())
        #expect(rgb == hex)
    }
}
