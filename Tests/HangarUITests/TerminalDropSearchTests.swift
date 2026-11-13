import AppKit
@testable import GhosttyBridge
@testable import HangarUI
import Testing

/// Drops and ⌘V insert the same text; the find bar's counter (HD-159).
@MainActor @Suite struct TerminalDropSearchTests {
    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("hangar-test-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    @Test func filesBecomeEscapedPathsJoinedBySpaces() {
        let pb = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a b/Снимок (1).png") as NSURL, URL(fileURLWithPath: "/tmp/x$y") as NSURL]) }
        defer { pb.releaseGlobally() }
        #expect(TerminalSurfaceView.pasteText(pb) == #"/tmp/a\ b/Снимок\ \(1\).png /tmp/x\$y"#)
    }

    @Test func textStaysAsIsAndWebURLsUnescaped() {
        let text = pasteboard { $0.setString("echo 'hi' && ls", forType: .string) }
        defer { text.releaseGlobally() }
        #expect(TerminalSurfaceView.pasteText(text) == "echo 'hi' && ls")
        let web = pasteboard { $0.writeObjects([URL(string: "https://example.com/a?b=1")! as NSURL]) }
        defer { web.releaseGlobally() }
        #expect(TerminalSurfaceView.pasteText(web) == "https://example.com/a?b=1")
        let empty = pasteboard { _ in }
        defer { empty.releaseGlobally() }
        #expect(TerminalSurfaceView.pasteText(empty) == nil)
    }

    @Test func findCounter() {
        #expect(terminalFindCounter(needle: "", selected: 1, total: 5) == nil)
        #expect(terminalFindCounter(needle: "ab", selected: nil, total: nil) == nil)
        #expect(terminalFindCounter(needle: "ab", selected: nil, total: 0) == L10n.terminalFindNone)
        #expect(terminalFindCounter(needle: "ab", selected: nil, total: 12) == L10n.terminalFindCounter("–", 12))
        #expect(terminalFindCounter(needle: "ab", selected: 2, total: 12) == L10n.terminalFindCounter("3", 12))
        #expect(L10n.terminalFindCounter("3", 12).contains("3") && L10n.terminalFindCounter("3", 12).contains("12"))
    }
}
