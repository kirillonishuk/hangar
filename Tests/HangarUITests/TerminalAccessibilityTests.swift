@testable import GhosttyBridge
import Testing

/// A dictation app writing AXValue back sends only its inserted text to the terminal (HD-148).
@Suite struct TerminalAccessibilityTests {
    @Test func insertionAnywhereYieldsTheInsertedRun() {
        #expect(TerminalSurfaceView.insertedText(old: "$ ", new: "$ ls -la") == "ls -la")
        #expect(TerminalSurfaceView.insertedText(old: "$ \n~", new: "привет $ \n~") == "привет ")
        #expect(TerminalSurfaceView.insertedText(old: "ab", new: "aXYb") == "XY")
        #expect(TerminalSurfaceView.insertedText(old: "", new: "hi") == "hi")
        // Repeated characters at the seam still give a run of the right length.
        #expect(TerminalSurfaceView.insertedText(old: "aa", new: "aaa") == "a")
    }

    @Test func nonInsertionsSendNothing() {
        #expect(TerminalSurfaceView.insertedText(old: "abc", new: "abc") == nil)
        #expect(TerminalSurfaceView.insertedText(old: "abc", new: "ab") == nil)
        #expect(TerminalSurfaceView.insertedText(old: "abc", new: "xbcd") == nil)
        #expect(TerminalSurfaceView.insertedText(old: "abc", new: "totally different") == nil)
    }
}
