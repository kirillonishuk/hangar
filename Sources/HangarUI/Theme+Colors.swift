import AgentStatus
import AppKit
import GhosttyBridge
import Observation
import os
import SwiftUI
import Workspace

extension Notification.Name {
    /// Posted after `Theme.current` changes: AppKit views that set colours once re-apply them.
    static let hangarThemeDidChange = Notification.Name("HangarThemeDidChange")
}

extension NSObject {
    /// AppKit objects that set colours once (layers, labels, windows) re-run `selector` after a theme switch;
    /// selector observers go away with the object.
    func observeTheme(_ selector: Selector) {
        NotificationCenter.default.addObserver(self, selector: selector, name: .hangarThemeDidChange, object: nil)
    }
}

/// Colour roles of the active theme (`ThemePalette`). They are computed: reading one inside a SwiftUI
/// body observes the theme, so switching it redraws the UI live (as `L10n.language`); AppKit listens to
/// `hangarThemeDidChange`.
extension Theme {
    /// Observable holder of the chosen theme (a static stored property can't be observed).
    @Observable final class Selection: @unchecked Sendable {
        var theme: AppTheme = .darkPlus
    }
    // Written on the main thread only (launch, Settings).
    nonisolated(unsafe) static let store = Selection()
    // Locked: tests (and SwiftUI off-main rendering) read tokens from several threads.
    private static let cache = OSAllocatedUnfairLock(initialState: [Hex: NSColor]())

    /// Set from config at launch and from Settings.
    public static var current: AppTheme {
        get { store.theme }
        set {
            guard newValue != store.theme else { return }
            store.theme = newValue
            NotificationCenter.default.post(name: .hangarThemeDidChange, object: nil)
        }
    }

    public static var palette: ThemePalette { ThemePalette.of(current) }

    /// One NSColor per value, so equal tokens compare equal and nothing is rebuilt on every draw.
    static func ns(_ hex: Hex) -> NSColor {
        cache.withLock { cache in
            if let c = cache[hex] { return c }
            let c = NSColor(srgbRed: CGFloat(hex.r) / 255, green: CGFloat(hex.g) / 255, blue: CGFloat(hex.b) / 255, alpha: hex.alpha)
            cache[hex] = c
            return c
        }
    }

    /// `a` moved toward `b` by `t` (0…1): the few colours derived from roles (button hover, rail tiles).
    static func mix(_ a: Hex, _ b: Hex, _ t: Double) -> Hex {
        func ch(_ x: Int, _ y: Int) -> UInt32 { UInt32((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
        return Hex(ch(a.r, b.r) << 16 | ch(a.g, b.g) << 8 | ch(a.b, b.b))
    }

    // NSColor: the roles of spec §2.7 (`ThemePalette`), plus the few colours derived from them.
    /// Content: terminal, editor, History.
    public static var bg0: NSColor { ns(palette.bg0) }
    /// Chrome: toolbar, both sidebars, tabs, pane headers, cards.
    public static var bg1: NSColor { ns(palette.bg1) }
    /// Popovers, menus, sheets, toasts.
    public static var bg2: NSColor { ns(palette.bg2) }
    public static var field: NSColor { ns(palette.field) }
    public static var hover: NSColor { ns(palette.hover) }
    /// Pressed; the active tab and segment; a toggled-on icon button.
    public static var hover2: NSColor { ns(palette.hover2) }
    /// The selected row while its list is out of focus.
    public static var selected: NSColor { ns(palette.selected) }
    /// The selected row in focus (the sidebar's chat, Settings navigation); the menu item under the pointer.
    public static var selectedFocus: NSColor { ns(palette.selectedFocus) }
    /// Separators.
    public static var line: NSColor { ns(palette.line) }
    /// Borders of controls, popovers, sheets.
    public static var line2: NSColor { ns(palette.line2) }
    public static var text0: NSColor { ns(palette.text0) }
    public static var text1: NSColor { ns(palette.text1) }
    public static var text2: NSColor { ns(palette.text2) }
    public static var text3: NSColor { ns(palette.text3) }
    public static var accent: NSColor { ns(palette.accent) }
    /// Accent as text (links, hashes, chips): lighter than `accent` for AA.
    public static var accentText: NSColor { ns(palette.accentText) }
    /// Text and icons on `accent` and `selectedFocus`.
    public static var onAccent: NSColor { ns(palette.onAccent) }
    public static var working: NSColor { ns(palette.working) }
    public static var waiting: NSColor { ns(palette.waiting) }
    public static var done: NSColor { ns(palette.done) }
    public static var failed: NSColor { ns(palette.failed) }
    public static var failedText: NSColor { ns(palette.failedText) }
    public static var idle: NSColor { ns(palette.idle) }
    public static var gitA: NSColor { ns(palette.gitA) }
    public static var gitM: NSColor { ns(palette.gitM) }
    public static var gitD: NSColor { ns(palette.gitD) }
    /// The regular button under the pointer: `hover2` lighter by 6 % (spec §3.8).
    public static var buttonHover: NSColor { ns(buttonHover(palette)) }
    static func buttonHover(_ p: ThemePalette) -> Hex { mix(p.hover2, p.text0, 0.06) }
    /// Rail monogram tiles (icons-sidebar.html `.mono`); the selected one takes a little of the accent.
    public static var railTileSelected: NSColor { ns(mix(palette.selected, palette.accent, 0.2)) }
    public static var railTileSelectedBorder: NSColor { ns(mix(palette.selected, palette.accent, 0.4)) }
    /// Dims what a drop won't take, the same in every theme (dark terminals need a real darkening).
    public static var paneDropScrim: NSColor { NSColor.black.withAlphaComponent(Opacity.scrim) }
    public static var claudeBrand: NSColor { ns(palette.claude) }

    /// Terminal colours handed to Ghostty: `bg0`, `text1`, the `accentText` cursor (always over the user's Ghostty
    /// config, #109) and the theme's ANSI palette.
    public static func terminalColors(of p: ThemePalette = Theme.palette) -> TerminalColors {
        TerminalColors(background: p.bg0.bare, foreground: p.text1.bare, palette: p.ansi.map { Hex($0).bare }, cursor: p.accentText.bare)
    }

    // SwiftUI
    public enum ui {
        static func of(_ hex: Hex) -> Color { Color(nsColor: Theme.ns(hex)) }

        public static var bg0: Color { of(Theme.palette.bg0) }
        public static var bg1: Color { of(Theme.palette.bg1) }
        public static var bg2: Color { of(Theme.palette.bg2) }
        public static var field: Color { of(Theme.palette.field) }
        public static var hover: Color { of(Theme.palette.hover) }
        public static var hover2: Color { of(Theme.palette.hover2) }
        public static var selected: Color { of(Theme.palette.selected) }
        public static var selectedFocus: Color { of(Theme.palette.selectedFocus) }
        public static var line: Color { of(Theme.palette.line) }
        public static var line2: Color { of(Theme.palette.line2) }
        public static var text0: Color { of(Theme.palette.text0) }
        public static var text1: Color { of(Theme.palette.text1) }
        public static var text2: Color { of(Theme.palette.text2) }
        public static var text3: Color { of(Theme.palette.text3) }
        public static var accent: Color { of(Theme.palette.accent) }
        public static var accentText: Color { of(Theme.palette.accentText) }
        public static var onAccent: Color { of(Theme.palette.onAccent) }
        public static var working: Color { of(Theme.palette.working) }
        public static var waiting: Color { of(Theme.palette.waiting) }
        public static var done: Color { of(Theme.palette.done) }
        public static var failed: Color { of(Theme.palette.failed) }
        public static var failedText: Color { of(Theme.palette.failedText) }
        public static var idle: Color { of(Theme.palette.idle) }
        public static var gitA: Color { of(Theme.palette.gitA) }
        public static var gitM: Color { of(Theme.palette.gitM) }
        public static var gitD: Color { of(Theme.palette.gitD) }
        public static var buttonHover: Color { Color(nsColor: Theme.buttonHover) }
        public static var railTileSelected: Color { Color(nsColor: Theme.railTileSelected) }
        public static var railTileSelectedBorder: Color { Color(nsColor: Theme.railTileSelectedBorder) }

        public static func status(_ state: AgentState) -> Color {
            switch state {
            case .working: working
            case .waiting: waiting
            case .done: done
            case .failed: failed
            case .idle: idle
            case .limit: waiting  // amber: the agent waits for its limit, nothing is broken
            }
        }
    }
}
