import AppKit

public enum Shortcut: Equatable, CaseIterable {
    case newTask, newTab, closeTab, splitRight, splitDown, tab(Int), prevTask, nextTask, toggleInspector, toggleSidebar, addProject

    public static var allCases: [Shortcut] {
        [.newTask, .newTab, .closeTab, .splitRight, .splitDown] + (1...9).map { .tab($0) }
            + [.prevTask, .nextTask, .toggleInspector, .toggleSidebar, .addProject]
    }
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
    case (.command, 29): return .toggleSidebar  // 0
    case (.command, _):
        return digitKeyCodes.firstIndex(of: keyCode).map { .tab($0 + 1) }
    default: return nil
    }
}
