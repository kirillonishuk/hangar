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

    @Test func toggleDrawerShortcut() {
        #expect(shortcut(keyCode: 50, modifiers: .control) == .toggleDrawer)  // ⌃` by keyCode: any layout
        #expect(shortcut(keyCode: 50, modifiers: []) == nil)
        #expect(shortcut(keyCode: 50, modifiers: [.control, .shift]) == nil)
        #expect(Action.toggleDrawer.shortcut == .toggleDrawer)
    }

    @Test func limits() {
        #expect(shortcut(keyCode: 37, modifiers: [.command, .shift]) == .limits)  // L by keyCode: any layout
        #expect(shortcut(keyCode: 37, modifiers: .command) == nil)
        #expect(Shortcut.allCases.contains(.limits))
    }

    @Test func withoutCommandIsNil() {
        for code: UInt16 in [17, 13, 45, 2, 18, 33, 30, 34, 29] {
            #expect(shortcut(keyCode: code, modifiers: []) == nil)
            #expect(shortcut(keyCode: code, modifiers: .shift) == nil)
        }
    }

    @Test func extraModifiersDoNotMatch() {
        #expect(shortcut(keyCode: 17, modifiers: [.command, .control]) == nil)
        #expect(shortcut(keyCode: 13, modifiers: [.command, .option]) == nil)
        #expect(shortcut(keyCode: 120, modifiers: .command) == nil)
        #expect(shortcut(keyCode: 34, modifiers: .command) == nil)
    }

    @Test func capsLockAndDeviceBitsIgnored() {
        // 0x100 is a device-dependent bit (left ⌘) that real events carry.
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x100)
        #expect(shortcut(keyCode: 17, modifiers: raw.union(.capsLock)) == .newTab)
    }

    @Test func allCasesListsEveryShortcut() {
        #expect(Shortcut.allCases.count == 34)
    }

    /// ⌥⌘1/2 inspector segments, ⌥⌘R reveal, ⌥⌘C copy path: by keyCode, so the Russian layout works too.
    @Test func inspectorRevealAndCopyKeys() {
        #expect(shortcut(keyCode: 18, modifiers: [.command, .option]) == .inspectorFiles)
        #expect(shortcut(keyCode: 19, modifiers: [.command, .option]) == .inspectorChanges)
        #expect(shortcut(keyCode: 15, modifiers: [.command, .option]) == .revealInFinder)
        #expect(shortcut(keyCode: 8, modifiers: [.command, .option]) == .copyPath)
        // ⌘1/⌘2 stay tabs; ⌥⌘3…9 are free.
        #expect(shortcut(keyCode: 18, modifiers: .command) == .tab(1))
        #expect(shortcut(keyCode: 19, modifiers: .command) == .tab(2))
        #expect(shortcut(keyCode: 20, modifiers: [.command, .option]) == nil)
        #expect(shortcut(keyCode: 15, modifiers: .command) == nil)
        #expect(shortcut(keyCode: 8, modifiers: .command) == nil)  // ⌘C is the terminal's copy
        #expect(Action.revealInFinder.shortcut == .revealInFinder)
        #expect(Action.copyPath.shortcut == .copyPath)
    }

    /// ⌘B: the silent Pane-habit alias of ⌘0 (decision #39); labels show ⌘0 only.
    @Test func sidebarAlias() {
        #expect(shortcut(keyCode: 11, modifiers: .command) == .toggleSidebar)
        #expect(Shortcut.toggleSidebar.label == "⌘0")
    }

    @Test func labelsUseMacModifierOrder() {
        #expect(Shortcut.toggleInspector.label == "⌥⌘I")
        #expect(Shortcut.limits.label == "⇧⌘L")
        #expect(Shortcut.addProject.label == "⇧⌘N")
        #expect(Shortcut.tab(1).label == "⌘1")
        #expect(Shortcut.toggleDrawer.label == "⌃`")
        #expect(Shortcut.rename.label == "F2")
        #expect(Shortcut.prevTab.label == "⌃⇧Tab")
        #expect(Shortcut.focusSplit(.left).label == "⌥⌘←")
        #expect(Shortcut.revealInFinder.label == "⌥⌘R")
        #expect(Shortcut.settings.label == "⌘,")
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        for sc in Shortcut.allCases {
            let mods = sc.label.prefix { order.contains($0) }
            #expect(sc.label.count > mods.count, "\(sc): no key")
            let ranks = mods.compactMap { order.firstIndex(of: $0) }
            #expect(ranks == ranks.sorted() && Set(ranks).count == ranks.count, "\(sc): \(sc.label)")
        }
    }

    /// Every key in `shortcut(keyCode:)` round-trips: the label is built from the same table the matcher reads.
    @Test func everyShortcutMatchesItsOwnKey() {
        for sc in Shortcut.allCases { #expect(shortcut(keyCode: sc.key.code, modifiers: sc.key.mods) == sc, "\(sc)") }
    }

    @Test @MainActor func tooltipFormat() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.help("Инспектор", .toggleInspector) == "Инспектор — ⌥⌘I")
        #expect(L10n.help(L10n.inspectorHelp, .toggleInspector) == "Инспектор — ⌥⌘I")
        #expect(L10n.help(L10n.newTabHelp, .newTab) == "Новая вкладка — ⌘T")
        #expect(L10n.help(L10n.addProject, .addProject) == "Добавить проект — ⇧⌘N")
        #expect(L10n.help("Закрепить", nil) == "Закрепить")
        L10n.language = .en
        #expect(L10n.help(L10n.limitsHelp, .limits) == "Subscription limits — ⇧⌘L")
        #expect(L10n.help(L10n.drawerHelp, .toggleDrawer) == "Terminal — ⌃`")
        #expect(L10n.help("claude", .tab(1)) == "claude — ⌘1")
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
