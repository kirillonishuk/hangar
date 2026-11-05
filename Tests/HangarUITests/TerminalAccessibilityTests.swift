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

    @Test func largeScrollbackStaysCorrect() {
        let old = String(repeating: "line of scrollback text 🙂\n", count: 100_000)  // ~2.5 MB; no timing assert: CI runners stall
        #expect(TerminalSurfaceView.insertedText(old: old + "$ ", new: old + "$ hello") == "hello")
        #expect(TerminalSurfaceView.insertedText(old: old, new: "привет" + old) == "привет")
    }

    @Test func insertionInsideSurrogatePairsStaysWhole() {
        #expect(TerminalSurfaceView.insertedText(old: "a🙂b", new: "a🙂🙂b") == "🙂")
    }

    @Test func secondWriteFromTheSameBaseIsNotDuplicated() {
        // Without dropping the cache, "hello" then "hello" written over the same base "" would both diff to "hello"; the second
        // write's base is the screen after the first (what the setter's cache reset guarantees), so it is an insertion at the end.
        #expect(TerminalSurfaceView.insertedText(old: "hel", new: "hello") == "lo")
        #expect(TerminalSurfaceView.insertedText(old: "hello", new: "hello") == nil)
    }
}
