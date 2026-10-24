import AppKit

public enum Shortcut: Equatable, CaseIterable {
    case newTask, newTab, closeTab, splitRight, splitDown, tab(Int), prevTask, nextTask, toggleInspector, toggleSidebar, addProject, settings
    case rename, archiveTask, toggleDrawer, limits, prevTab, nextTab, focusSplit(SplitDirection)
    case inspectorFiles, inspectorChanges, revealInFinder, copyPath
    case attentionFilter

    public static var allCases: [Shortcut] {
        [.newTask, .newTab, .closeTab, .splitRight, .splitDown] + (1...9).map { .tab($0) }
            + [.prevTask, .nextTask, .toggleInspector, .toggleSidebar, .addProject, .settings, .rename, .archiveTask, .toggleDrawer, .limits]
            + [.prevTab, .nextTab] + [SplitDirection.left, .right, .up, .down].map { .focusSplit($0) }
            + [.inspectorFiles, .inspectorChanges, .revealInFinder, .copyPath]
            + [.attentionFilter]
    }

    /// The physical key (ANSI keyCode, so any layout works), its modifiers and the symbol shown in labels.
    /// One table for matching and labels, so a tooltip can't show a key that does something else.
    var key: (mods: NSEvent.ModifierFlags, code: UInt16, symbol: String) {
        switch self {
        case .newTask: (.command, 45, "N")
        case .addProject: ([.command, .shift], 45, "N")
        case .newTab: (.command, 17, "T")
        case .closeTab: (.command, 13, "W")
        case .archiveTask: ([.command, .shift], 13, "W")
        case .splitRight: (.command, 2, "D")
        case .splitDown: ([.command, .shift], 2, "D")
        case .tab(let n): (.command, digitKeyCodes.indices.contains(n - 1) ? digitKeyCodes[n - 1] : .max, "\(n)")
        case .prevTask: ([.command, .shift], 33, "[")
        case .nextTask: ([.command, .shift], 30, "]")
        case .toggleInspector: ([.command, .option], 34, "I")
        case .toggleSidebar: (.command, 29, "0")
        case .settings: (.command, 43, ",")
        case .rename: ([], 120, "F2")
        case .toggleDrawer: (.control, 50, "`")  // physical key left of 1
        case .limits: ([.command, .shift], 37, "L")
        case .prevTab: ([.control, .shift], 48, "Tab")
        case .nextTab: (.control, 48, "Tab")
        // ⌘ + arrows alone stay with the terminal.
        case .focusSplit(.left): ([.command, .option], 123, "←")
        case .focusSplit(.right): ([.command, .option], 124, "→")
        case .focusSplit(.up): ([.command, .option], 126, "↑")
        case .focusSplit(.down): ([.command, .option], 125, "↓")
        case .inspectorFiles: ([.command, .option], 18, "1")
        case .inspectorChanges: ([.command, .option], 19, "2")
        case .revealInFinder: ([.command, .option], 15, "R")
        case .copyPath: ([.command, .option], 8, "C")
        case .attentionFilter: ([.command, .option], 3, "F")
        }
    }

    /// «⌥⌘I»: modifiers in the macOS menu order ⌃⌥⇧⌘, then the key.
    var label: String {
        let (mods, _, symbol) = key
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { mods.contains($0.0) }.map(\.1).joined() + symbol
    }
}

/// ⌘⌥ + arrow: focus the split pane on that side.
public enum SplitDirection: Equatable, Sendable {
    case left, right, up, down

    /// ⌘⌥↑/↓ switched tasks before splits had a key (decision #39): with no pane on that side they still do.
    var taskFallback: Int? {
        switch self {
        case .up: -1
        case .down: 1
        case .left, .right: nil
        }
    }
}

/// What ⌃Tab steps through: the task's tabs, then its diff tab (if open).
enum TabSlot: Equatable { case tab(UUID), diff }

/// The slot `offset` steps from `current`, wrapping; nil when there is nowhere else to go.
func cycled(_ slots: [TabSlot], from current: TabSlot?, by offset: Int) -> TabSlot? {
    guard let i = current.flatMap(slots.firstIndex(of:)) else { return slots.first }
    guard slots.count > 1 else { return nil }
    return slots[((i + offset) % slots.count + slots.count) % slots.count]
}

/// ANSI keyCodes of the digit row 1…9 (physical keys, so any layout works).
private let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

/// Matches physical keys (keyCode), not characters, so shortcuts work in the Russian layout.
public func shortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Shortcut? {
    let mods = modifiers.intersection([.command, .shift, .option, .control])
    // ⌘B: silent alias of ⌘0, a Pane habit (decision #39); labels show ⌘0 only.
    if mods == .command, keyCode == 11 { return .toggleSidebar }
    return Shortcut.allCases.first { $0.key.mods == mods && $0.key.code == keyCode }
}
