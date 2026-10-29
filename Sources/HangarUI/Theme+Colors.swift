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

/// Colour tokens of the active theme (`ThemePalette`, themes-v1.html). They are computed: reading one inside a SwiftUI
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

    /// `a` moved toward `b` by `t` (0…1): the tokens the mockup has no row for (pressed, rail tiles).
    static func mix(_ a: Hex, _ b: Hex, _ t: Double) -> Hex {
        func ch(_ x: Int, _ y: Int) -> UInt32 { UInt32((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
        return Hex(ch(a.r, b.r) << 16 | ch(a.g, b.g) << 8 | ch(a.b, b.b))
    }

    // NSColor
    public static var bg: NSColor { ns(palette.bg) }
    public static var titlebar: NSColor { ns(palette.titlebar) }
    public static var sidebar: NSColor { ns(palette.sidebar) }
    /// Terminal and editor area (= `termBg`; the right sidebar is `inspector`).
    public static var panel: NSColor { ns(palette.termBg) }
    /// Right sidebar (Files / Git): the mockup's `panel`.
    public static var inspector: NSColor { ns(palette.panel) }
    public static var statusBar: NSColor { ns(palette.status) }
    public static var tabStrip: NSColor { ns(palette.tabStrip) }
    public static var activeSegment: NSColor { ns(palette.tabActive) }
    public static var tabInactive: NSColor { ns(palette.tabInactive) }
    public static var line: NSColor { ns(palette.line) }
    public static var bottomBar: NSColor { ns(palette.bottomBar) }
    public static var control: NSColor { ns(palette.control) }
    public static var field: NSColor { ns(palette.field) }
    public static var text: NSColor { ns(palette.tx) }
    public static var textStrong: NSColor { ns(palette.strong) }
    public static var textRow: NSColor { ns(palette.tx) }
    public static var text2: NSColor { ns(palette.tx2) }
    public static var text3: NSColor { ns(palette.tx3) }
    public static var selection: NSColor { ns(palette.selected) }
    public static var accent: NSColor { ns(palette.accent) }
    /// Dims what a drop won't take, the same in every theme (dark terminals need a real darkening).
    public static var paneDropScrim: NSColor { NSColor.black.withAlphaComponent(paneDropDimOpacity) }
    /// Accent as text (links, hashes, chips): lighter than `accent` for AA.
    public static var accentText: NSColor { ns(palette.accentText) }
    public static var primary: NSColor { ns(palette.primary) }
    /// Text on `primary` (dark in Graphite: white on amber fails AA).
    public static var primaryText: NSColor { ns(palette.primaryText) }

    public static var working: NSColor { ns(palette.working) }
    public static var waiting: NSColor { ns(palette.waiting) }
    public static var done: NSColor { ns(palette.done) }
    public static var failed: NSColor { ns(palette.failed) }
    public static var failedText: NSColor { ns(palette.failedText) }
    public static var idle: NSColor { ns(palette.idle) }

    public static var lineSheet: NSColor { ns(palette.lineSheet) }
    public static var sheetBorder: NSColor { ns(palette.winBorder) }
    public static var controlBorderStrong: NSColor { ns(palette.controlStrong) }
    public static var sheet: NSColor { ns(palette.sheet) }
    public static var sheetText: NSColor { ns(palette.strong) }
    public static var selectionText: NSColor { ns(palette.strong) }
    public static var hover: NSColor { ns(palette.hover) }
    public static var hoverStrong: NSColor { ns(palette.hoverStrong) }
    /// Pressed on `bg`: between `bg` and `hover`.
    public static var pressed: NSColor { ns(mix(palette.bg, palette.hover, 0.5)) }
    /// Sidebar (and popovers on `sheet`): hover lighter than `sidebar`, pressed darker (DESIGN.md «Состояния»).
    public static var sidebarHover: NSColor { ns(palette.sbHover) }
    public static var sidebarPressed: NSColor { ns(mix(palette.sidebar, 0x000000, 0.15)) }
    /// Popover-menu item under the pointer and its text.
    public static var menuHover: NSColor { ns(palette.menuHover) }
    public static var menuHoverText: NSColor { ns(palette.menuHoverText) }
    /// Rail task monogram tile (icons-sidebar.html `.mono`); the selected one takes a little of the accent.
    public static var railTile: NSColor { ns(palette.sbHover) }
    public static var railTileBorder: NSColor { ns(palette.controlStrong) }
    public static var railTileSelected: NSColor { ns(mix(palette.selected, palette.accent, 0.2)) }
    public static var railTileSelectedBorder: NSColor { ns(mix(palette.selected, palette.accent, 0.4)) }
    public static var button: NSColor { ns(palette.button) }
    /// Selected segment, secondary button under the pointer (controls-v2 B′): one step above `button`.
    public static var moreBg: NSColor { ns(palette.moreBg) }
    /// Inactive segment under the pointer: a touch lighter than its `field` track in every theme.
    public static var segmentHover: NSColor { ns(mix(palette.field, palette.strong, segmentHoverMix)) }
    public static var claudeBrand: NSColor { ns(palette.claude) }
    /// Terminal cursor: the accent, over the user's Ghostty config (#109) — not the system accent.
    public static var terminalCursor: NSColor { ns(palette.accent) }

    /// Terminal colours handed to Ghostty: the theme's background, text and accent cursor (always over the user's
    /// Ghostty config, #109) and its ANSI palette.
    public static func terminalColors(of p: ThemePalette = Theme.palette) -> TerminalColors {
        TerminalColors(background: p.termBg.bare, foreground: p.tx.bare, palette: p.ansi.map { Hex($0).bare }, cursor: p.accent.bare)
    }

    // SwiftUI
    public enum ui {
        public static var bg: Color { Color(nsColor: Theme.bg) }
        public static var titlebar: Color { Color(nsColor: Theme.titlebar) }
        public static var sidebar: Color { Color(nsColor: Theme.sidebar) }
        public static var panel: Color { Color(nsColor: Theme.panel) }
        public static var inspector: Color { Color(nsColor: Theme.inspector) }
        public static var statusBar: Color { Color(nsColor: Theme.statusBar) }
        public static var tabStrip: Color { Color(nsColor: Theme.tabStrip) }
        public static var activeSegment: Color { Color(nsColor: Theme.activeSegment) }
        public static var tabInactive: Color { Color(nsColor: Theme.tabInactive) }
        public static var bottomBar: Color { Color(nsColor: Theme.bottomBar) }
        public static var hoverStrong: Color { Color(nsColor: Theme.hoverStrong) }
        public static var line: Color { Color(nsColor: Theme.line) }
        public static var control: Color { Color(nsColor: Theme.control) }
        public static var field: Color { Color(nsColor: Theme.field) }
        public static var text: Color { Color(nsColor: Theme.text) }
        public static var textStrong: Color { Color(nsColor: Theme.textStrong) }
        public static var textRow: Color { Color(nsColor: Theme.textRow) }
        public static var text2: Color { Color(nsColor: Theme.text2) }
        public static var text3: Color { Color(nsColor: Theme.text3) }
        public static var selection: Color { Color(nsColor: Theme.selection) }
        public static var accent: Color { Color(nsColor: Theme.accent) }
        public static var accentText: Color { Color(nsColor: Theme.accentText) }
        public static var primary: Color { Color(nsColor: Theme.primary) }
        public static var primaryText: Color { Color(nsColor: Theme.primaryText) }
        public static var working: Color { Color(nsColor: Theme.working) }
        public static var waiting: Color { Color(nsColor: Theme.waiting) }
        public static var done: Color { Color(nsColor: Theme.done) }
        public static var failed: Color { Color(nsColor: Theme.failed) }
        public static var idle: Color { Color(nsColor: Theme.idle) }
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
        public static var lineSheet: Color { Color(nsColor: Theme.lineSheet) }
        public static var sheetBorder: Color { Color(nsColor: Theme.sheetBorder) }
        public static var sheet: Color { Color(nsColor: Theme.sheet) }
        public static var sheetText: Color { Color(nsColor: Theme.sheetText) }
        public static var selectionText: Color { Color(nsColor: Theme.selectionText) }
        public static var hover: Color { Color(nsColor: Theme.hover) }
        public static var pressed: Color { Color(nsColor: Theme.pressed) }
        public static var sidebarHover: Color { Color(nsColor: Theme.sidebarHover) }
        public static var sidebarPressed: Color { Color(nsColor: Theme.sidebarPressed) }
        public static var menuHover: Color { Color(nsColor: Theme.menuHover) }
        public static var menuHoverText: Color { Color(nsColor: Theme.menuHoverText) }
        public static var railTile: Color { Color(nsColor: Theme.railTile) }
        public static var railTileBorder: Color { Color(nsColor: Theme.railTileBorder) }
        public static var railTileSelected: Color { Color(nsColor: Theme.railTileSelected) }
        public static var railTileSelectedBorder: Color { Color(nsColor: Theme.railTileSelectedBorder) }
        public static var button: Color { Color(nsColor: Theme.button) }
        public static var moreBg: Color { Color(nsColor: Theme.moreBg) }
        public static var segmentHover: Color { Color(nsColor: Theme.segmentHover) }
        public static var controlBorderStrong: Color { Color(nsColor: Theme.controlBorderStrong) }
        static func of(_ hex: Hex) -> Color { Color(nsColor: Theme.ns(hex)) }
    }
}
