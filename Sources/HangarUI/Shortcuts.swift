import AppKit

public enum Shortcut: Equatable, CaseIterable {
    case newTask, newTab, closeTab, splitRight, splitDown, tab(Int), prevTask, nextTask, toggleInspector, toggleSidebar, addProject, settings
    case rename, archiveTask, toggleDrawer, limits, prevTab, nextTab, focusSplit(SplitDirection)

    public static var allCases: [Shortcut] {
        [.newTask, .newTab, .closeTab, .splitRight, .splitDown] + (1...9).map { .tab($0) }
            + [.prevTask, .nextTask, .toggleInspector, .toggleSidebar, .addProject, .settings, .rename, .archiveTask, .toggleDrawer, .limits]
            + [.prevTab, .nextTab] + [SplitDirection.left, .right, .up, .down].map { .focusSplit($0) }
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
    switch (mods, keyCode) {
    case (.command, 45): return .newTask       // N
    case ([.command, .shift], 45): return .addProject
    case (.command, 17): return .newTab        // T
    case (.command, 13): return .closeTab      // W
    case (.command, 2): return .splitRight     // D
    case ([.command, .shift], 2): return .splitDown
    case ([.command, .shift], 33): return .prevTask   // [
    case ([.command, .shift], 30): return .nextTask   // ]
    case ([.command, .option], 34): return .toggleInspector  // I
    case (.command, 29), (.command, 11): return .toggleSidebar  // 0, B (Pane habit)
    case ([.command, .option], 123): return .focusSplit(.left)  // ← (⌘ + arrows alone stay with the terminal)
    case ([.command, .option], 124): return .focusSplit(.right)  // →
    case ([.command, .option], 126): return .focusSplit(.up)  // ↑ (no pane above: previous task)
    case ([.command, .option], 125): return .focusSplit(.down)  // ↓ (no pane below: next task)
    case (.control, 48): return .nextTab  // ⌃Tab
    case ([.control, .shift], 48): return .prevTab  // ⌃⇧Tab
    case ([.command, .shift], 13): return .archiveTask  // W
    case ([.command, .shift], 37): return .limits  // L
    case ([], 120): return .rename  // F2
    case (.control, 50): return .toggleDrawer  // ⌃` (physical key left of 1)
    case (.command, 43): return .settings  // ,
    case (.command, _):
        return digitKeyCodes.firstIndex(of: keyCode).map { .tab($0 + 1) }
    default: return nil
    }
}
