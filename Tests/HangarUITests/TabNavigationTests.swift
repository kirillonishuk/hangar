import AppKit
import Foundation
import Testing
@testable import HangarUI

@Suite struct TabNavigationTests {
    @Test func controlTabByKeyCode() {
        #expect(shortcut(keyCode: 48, modifiers: .control) == .nextTab)  // ⌃Tab
        #expect(shortcut(keyCode: 48, modifiers: [.control, .shift]) == .prevTab)  // ⌃⇧Tab
        #expect(shortcut(keyCode: 48, modifiers: []) == nil)  // Tab itself stays with the terminal
        #expect(shortcut(keyCode: 48, modifiers: .shift) == nil)
        #expect(Shortcut.allCases.contains(.nextTab) && Shortcut.allCases.contains(.prevTab))
    }

    @Test func commandOptionArrowsFocusSplits() {
        #expect(shortcut(keyCode: 123, modifiers: [.command, .option]) == .focusSplit(.left))
        #expect(shortcut(keyCode: 124, modifiers: [.command, .option, .numericPad, .function]) == .focusSplit(.right))
        #expect(shortcut(keyCode: 126, modifiers: [.command, .option]) == .focusSplit(.up))
        #expect(shortcut(keyCode: 125, modifiers: [.command, .option]) == .focusSplit(.down))
        #expect(shortcut(keyCode: 123, modifiers: .command) == nil)  // ⌘← stays with the terminal
        // Past the edge ↑/↓ keep switching tasks (decision #39).
        #expect(SplitDirection.up.taskFallback == -1)
        #expect(SplitDirection.down.taskFallback == 1)
        #expect(SplitDirection.left.taskFallback == nil)
    }

    @Test func cycleWrapsAndIncludesDiff() {
        let a = UUID(), b = UUID()
        let slots: [TabSlot] = [.tab(a), .tab(b), .diff]
        #expect(cycled(slots, from: .tab(a), by: 1) == .tab(b))
        #expect(cycled(slots, from: .tab(b), by: 1) == .diff)
        #expect(cycled(slots, from: .diff, by: 1) == .tab(a))
        #expect(cycled(slots, from: .tab(a), by: -1) == .diff)
        #expect(cycled([.tab(a)], from: .tab(a), by: 1) == nil)  // nothing to switch to
        #expect(cycled([], from: nil, by: 1) == nil)
        #expect(cycled([.tab(a), .tab(b)], from: nil, by: 1) == .tab(a))
    }

    /// Window coordinates (y up): a | b on top, c across the bottom.
    @Test func splitNeighbourIsGeometric() {
        let a = UUID(), b = UUID(), c = UUID()
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 100, width: 100, height: 100),
            b: CGRect(x: 101, y: 100, width: 100, height: 100),
            c: CGRect(x: 0, y: 0, width: 201, height: 99),
        ]
        #expect(splitNeighbour(of: a, in: frames, toward: .right) == b)
        #expect(splitNeighbour(of: b, in: frames, toward: .left) == a)
        #expect(splitNeighbour(of: a, in: frames, toward: .down) == c)
        #expect(splitNeighbour(of: b, in: frames, toward: .down) == c)
        #expect(splitNeighbour(of: c, in: frames, toward: .up) == a)  // equal overlap: the leftmost
        #expect(splitNeighbour(of: a, in: frames, toward: .left) == nil)
        #expect(splitNeighbour(of: a, in: frames, toward: .up) == nil)
        #expect(splitNeighbour(of: UUID(), in: frames, toward: .up) == nil)
    }
}

@MainActor @Suite struct ArchiveUndoTests {
    @Test func undoRestoresOnceAndHides() {
        let undo = ArchiveUndo(delay: 60)
        let id = UUID()
        undo.show(id)
        #expect(undo.taskId == id)
        var restored: [UUID] = []
        undo.undo { restored.append($0) }
        undo.undo { restored.append($0) }
        #expect(restored == [id])
        #expect(undo.taskId == nil)
    }

    @Test func newArchiveReplacesTheToast() {
        let undo = ArchiveUndo(delay: 60)
        let a = UUID(), b = UUID()
        undo.show(a)
        undo.show(b)
        var restored: [UUID] = []
        undo.undo { restored.append($0) }
        #expect(restored == [b])
    }

    @Test func hidesByItself() async throws {
        let undo = ArchiveUndo(delay: 0.05)
        undo.show(UUID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(undo.taskId == nil)
    }

    /// A replaced toast's timer must not hide the new one early.
    @Test func oldTimerDoesNotHideNewToast() {
        var items: [DispatchWorkItem] = []
        let undo = ArchiveUndo(delay: 5) { _, item in items.append(item) }
        undo.show(UUID())
        let b = UUID()
        undo.show(b)
        if !items[0].isCancelled { items[0].perform() }
        #expect(undo.taskId == b)
        items[1].perform()
        #expect(undo.taskId == nil)
    }
}

@Suite struct FileMenuTests {
    @Test func localAndRemoteItems() {
        #expect(FileMenuItem.items(remote: false) == [.openInEditorTab, .revealInFinder, .copyPath, .copyRelativePath])
        #expect(FileMenuItem.items(remote: true) == [.openInEditorTab, .copyPath, .copyRelativePath])
    }

    @Test func copiedText() {
        #expect(FileMenuItem.copyPath.copied(root: "/r", relative: "src/a.swift", host: nil) == "/r/src/a.swift")
        #expect(FileMenuItem.copyPath.copied(root: "/r", relative: "src/a.swift", host: "dev") == "dev:/r/src/a.swift")
        #expect(FileMenuItem.copyRelativePath.copied(root: "/r", relative: "src/a.swift", host: "dev") == "src/a.swift")
        #expect(FileMenuItem.openInEditorTab.copied(root: "/r", relative: "a", host: nil) == nil)
    }
}
