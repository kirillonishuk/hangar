import AppKit
import Testing
@testable import HangarUI

@Suite struct ShortcutsTests {
    @Test func shortcutsMatchByKeyCode() {
        #expect(shortcut(keyCode: 17, modifiers: .command) == .newTab)
        #expect(shortcut(keyCode: 13, modifiers: .command) == .closeTab)
        #expect(shortcut(keyCode: 45, modifiers: .command) == .newTask)
        #expect(shortcut(keyCode: 2, modifiers: .command) == .splitRight)
        #expect(shortcut(keyCode: 2, modifiers: [.command, .shift]) == .splitDown)
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, code) in digits.enumerated() {
            #expect(shortcut(keyCode: code, modifiers: .command) == .tab(i + 1))
        }
        #expect(shortcut(keyCode: 33, modifiers: [.command, .shift]) == .prevTask)
        #expect(shortcut(keyCode: 30, modifiers: [.command, .shift]) == .nextTask)
        #expect(shortcut(keyCode: 34, modifiers: [.command, .option]) == .toggleInspector)
        #expect(shortcut(keyCode: 29, modifiers: .command) == .toggleSidebar)
        #expect(shortcut(keyCode: 43, modifiers: .command) == .settings)
        #expect(shortcut(keyCode: 45, modifiers: [.command, .shift]) == .addProject)
    }

    @Test func withoutCommandIsNil() {
        for code: UInt16 in [17, 13, 45, 2, 18, 33, 30, 34, 29] {
            #expect(shortcut(keyCode: code, modifiers: []) == nil)
            #expect(shortcut(keyCode: code, modifiers: .shift) == nil)
        }
    }

    @Test func extraModifiersDoNotMatch() {
        #expect(shortcut(keyCode: 17, modifiers: [.command, .control]) == nil)
        #expect(shortcut(keyCode: 13, modifiers: [.command, .shift]) == nil)
        #expect(shortcut(keyCode: 34, modifiers: .command) == nil)
    }

    @Test func capsLockAndDeviceBitsIgnored() {
        // 0x100 is a device-dependent bit (left ⌘) that real events carry.
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x100)
        #expect(shortcut(keyCode: 17, modifiers: raw.union(.capsLock)) == .newTab)
    }

    @Test func allCasesListsEveryShortcut() {
        #expect(Shortcut.allCases.count == 20)
    }
}

@Suite struct MonogramTests {
    @Test func monogramFromName() {
        #expect(monogram("frontend-cd") == "FC")
        #expect(monogram("fix auth") == "FA")
        #expect(monogram("shopApi") == "SA")
        #expect(monogram("исправить_логин") == "ИЛ")
        #expect(monogram("исправить логин") == "ИЛ")
        #expect(monogram("web.front") == "WF")
        #expect(monogram("refactor") == "R")
        #expect(monogram("") == "?")
        #expect(monogram("fix-auth-flow") == "FA")
        #expect(monogram("  add   metrics ") == "AM")
        #expect(monogram("API") == "A")
    }
}
