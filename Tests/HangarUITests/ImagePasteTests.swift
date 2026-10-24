import AppKit
import Testing
@testable import HangarUI
import Workspace

@Suite struct ImagePasteTests {
    let png = URL(fileURLWithPath: "/tmp/shot.png")

    @Test func imageOnlyInAgentSendsCtrlV() {
        #expect(pasteAction(kind: .claude, types: [.png], fileURLs: []) == .ctrlV)
        #expect(pasteAction(kind: .codex, types: [.tiff], fileURLs: []) == .ctrlV)
        #expect(pasteAction(kind: .claude, types: [.fileURL], fileURLs: [png]) == .ctrlV)
    }

    @Test func textWinsOverImage() {
        #expect(pasteAction(kind: .claude, types: [.png, .string], fileURLs: []) == .text)
        // Finder copy: file URL plus the name as text → the quoted path is pasted.
        #expect(pasteAction(kind: .claude, types: [.fileURL, .string], fileURLs: [png]) == .text)
        #expect(pasteAction(kind: .claude, types: [.string], fileURLs: []) == .text)
    }

    @Test func nonImageFileOrEmpty() {
        #expect(pasteAction(kind: .claude, types: [.fileURL], fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")]) == .text)
        #expect(pasteAction(kind: .claude, types: [], fileURLs: []) == .text)
    }

    @Test func shellTooEditorNot() {
        // claude started by hand in a shell tab (or the drawer) must get the image too.
        #expect(pasteAction(kind: .shell, types: [.png], fileURLs: []) == .ctrlV)
        // Helix: ⌃V is a command there.
        #expect(pasteAction(kind: .editor, types: [.tiff], fileURLs: []) == .text)
    }
}
