import AppKit
import Testing
@testable import HangarUI

/// The hotkey policy of the Monaco editor and diff (DESIGN.md «Редактор: клавиши», #80), by keyCode.
@Suite struct EditorKeysTests {
    private let cmd: NSEvent.ModifierFlags = .command
    private let optCmd: NSEvent.ModifierFlags = [.option, .command]

    @Test func editingKeysGoToMonaco() {
        for focus in [WebFocus.editor, .diff] {
            #expect(editorKeyRoute(keyCode: 2, modifiers: cmd, focus: focus) == .monaco)      // ⌘D next occurrence
            #expect(editorKeyRoute(keyCode: 3, modifiers: cmd, focus: focus) == .monaco)      // ⌘F find
            #expect(editorKeyRoute(keyCode: 3, modifiers: optCmd, focus: focus) == .monaco)   // ⌥⌘F replace
        }
        // Keys Hangar never binds pass through on their own (⌘/, ⌥↑, ⇧⌘K, ⌘[, ⌘Z, F12…).
        let free: [(UInt16, NSEvent.ModifierFlags)] = [(44, cmd), (126, .option), (125, [.shift, .option]), (40, [.shift, .command]),
                                                       (33, cmd), (30, cmd), (6, cmd), (6, [.shift, .command]), (111, []), (111, .shift)]
        for (code, mods) in free {
            #expect(editorKeyRoute(keyCode: code, modifiers: mods, focus: .editor) == nil)
            #expect(shortcut(keyCode: code, modifiers: mods) == nil, "Hangar must not bind \(code) \(mods)")
        }
    }

    /// A file is a Hangar tab (#83): ⌘W is Hangar's close (it asks for unsaved), ⌥⌘←/→ Hangar's split focus.
    @Test func fileTabsUseHangarKeys() {
        #expect(editorKeyRoute(keyCode: 13, modifiers: cmd, focus: .editor) == nil)       // ⌘W
        #expect(shortcut(keyCode: 13, modifiers: cmd) == .closeTab)
        #expect(editorKeyRoute(keyCode: 123, modifiers: optCmd, focus: .editor) == nil)   // ⌥⌘←
        #expect(editorKeyRoute(keyCode: 124, modifiers: optCmd, focus: .editor) == nil)   // ⌥⌘→
        // In the diff ⌘W closes the diff tab (diffKeyRoute), ⌥⌘↑/↓ step through its files.
        #expect(editorKeyRoute(keyCode: 13, modifiers: cmd, focus: .diff) == nil)
        #expect(editorKeyRoute(keyCode: 126, modifiers: optCmd, focus: .diff) == .prevDiffFile)
        #expect(editorKeyRoute(keyCode: 125, modifiers: optCmd, focus: .diff) == .nextDiffFile)
        #expect(editorKeyRoute(keyCode: 126, modifiers: optCmd, focus: .editor) == nil)  // focus split, Hangar's
    }

    /// Hangar-global keys are never Monaco's, whatever has focus.
    @Test func hangarGlobalsStayHangars() {
        let globals: [(UInt16, NSEvent.ModifierFlags, Shortcut)] = [
            (35, cmd, .quickOpen), (35, [.shift, .command], .commandPalette), (38, cmd, .toggleDrawer), (17, cmd, .newTab),
            (18, cmd, .tab(1)), (25, cmd, .tab(9)), (48, .control, .nextTab), (48, [.control, .shift], .prevTab), (16, cmd, .sessions),
            (18, optCmd, .inspectorFiles), (19, optCmd, .inspectorChanges), (20, optCmd, .inspectorGit), (34, optCmd, .toggleInspector),
            (29, cmd, .toggleSidebar), (45, cmd, .newTask), (43, cmd, .settings), (2, [.shift, .command], .splitDown),
        ]
        for (code, mods, sc) in globals {
            for focus in [WebFocus.editor, .diff, .none] {
                #expect(editorKeyRoute(keyCode: code, modifiers: mods, focus: focus) == nil)
            }
            #expect(shortcut(keyCode: code, modifiers: mods) == sc)
        }
    }

    /// Physical keys: the Russian layout (or caps lock / fn noise) changes nothing.
    @Test func matchesByKeyCode() {
        #expect(editorKeyRoute(keyCode: 2, modifiers: [.command, .capsLock], focus: .editor) == .monaco)
        #expect(editorKeyRoute(keyCode: 3, modifiers: [.command, .function, .numericPad], focus: .editor) == .monaco)
        #expect(editorKeyRoute(keyCode: 2, modifiers: cmd, focus: .none) == nil)  // outside the editor ⌘D splits
        #expect(shortcut(keyCode: 2, modifiers: cmd) == .splitRight)
    }

    /// ⌃- / ⌃⇧- (back / forward over jumps) and F12 / ⇧F12 reach Monaco: Hangar has no shortcut on them (#82).
    @Test func navigationKeysAreMonacos() {
        for mods: NSEvent.ModifierFlags in [.control, [.control, .shift]] {
            #expect(shortcut(keyCode: 27, modifiers: mods) == nil)
            #expect(editorKeyRoute(keyCode: 27, modifiers: mods, focus: .editor) == nil)
        }
        for mods: NSEvent.ModifierFlags in [[], .shift] { #expect(shortcut(keyCode: 111, modifiers: mods) == nil) }
    }

    @Test func diffKeysOutsideTheWebView() {
        #expect(diffKeyRoute(keyCode: 126, modifiers: [], diffActive: true, editingText: false, webFocused: false) == .up)
        #expect(diffKeyRoute(keyCode: 126, modifiers: [], diffActive: true, editingText: false, webFocused: true) == nil)
        #expect(diffKeyRoute(keyCode: 36, modifiers: [], diffActive: true, editingText: false, webFocused: true) == nil)
        #expect(diffKeyRoute(keyCode: 13, modifiers: cmd, diffActive: true, editingText: false, webFocused: true) == .close)
        #expect(diffKeyRoute(keyCode: 11, modifiers: .option, diffActive: true, editingText: false, webFocused: true) == .toggleMode)
    }
}
