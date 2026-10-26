import AppKit

/// Where the keyboard is: Monaco's editor tab, the Monaco diff tab, or neither.
enum WebFocus: Equatable { case none, editor, diff }

/// What the key monitor does with a key while Monaco has focus (DESIGN.md «Редактор: клавиши», #80).
enum EditorKey: Equatable {
    /// Hand the event to the web view untouched (it would otherwise be a Hangar shortcut).
    case monaco
    /// ⌥⌘↑ / ⌥⌘↓ in the diff: the previous / next changed file.
    case prevDiffFile, nextDiffFile
}

/// Only the keys Hangar and Monaco both want are decided here; nil = the usual routing (Hangar's global shortcuts,
/// everything else reaches the web view). By keyCode, so the Russian layout works.
func editorKeyRoute(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, focus: WebFocus) -> EditorKey? {
    guard focus != .none else { return nil }
    let mods = modifiers.intersection([.command, .shift, .option, .control])
    switch (keyCode, mods) {
    case (2, .command): return .monaco                 // ⌘D: next occurrence (Hangar splits with ⇧⌘D / the menu)
    case (3, .command), (3, [.option, .command]): return .monaco  // ⌘F / ⌥⌘F: find / replace
    case (126, [.option, .command]) where focus == .diff: return .prevDiffFile
    case (125, [.option, .command]) where focus == .diff: return .nextDiffFile
    default: return nil
    }
}
