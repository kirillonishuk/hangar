import AppKit
import SwiftUI

/// Sidebar and popover-menu tokens of redesign v1 (redesign-v1.html §2, §3, §9); Theme.swift holds the rest.
extension Theme {
    /// Row highlight (hover, selection) inset from the sidebar edges and its radius; the marker stays at x 20.
    public static let rowInset: CGFloat = 8
    public static let rowRadius: CGFloat = 8
    /// Two-line session row: name line 20 + status line 16, 4 above and below.
    public static let sessionRowHeight: CGFloat = 44
    public static let sessionNameLine: CGFloat = 20
    public static let sessionStatusLine: CGFloat = 16
    public static let sessionRowPaddingV: CGFloat = 4
    /// Status line: 12 `text2`; the worktree ⎇ before it 12 `text3`, 4 from the text.
    public static let rowStatusFont: CGFloat = 12
    public static let rowStatusIcon: CGFloat = 12
    public static let rowStatusGap: CGFloat = 4
    /// `+N −M` badge: 20 high, mono 12, 0×6 padding, radius 6, `line2` border, `bg` at 35 %; numbers 6 apart.
    public static let diffBadgeHeight: CGFloat = 20
    public static let diffBadgeFont: CGFloat = 12
    public static let diffBadgePaddingH: CGFloat = 6
    public static let diffBadgeRadius: CGFloat = 6
    public static let diffBadgeGap: CGFloat = 6
    public static let diffBadgeFillOpacity = 0.35
    /// Gap between the name and the badge slot.
    public static let rowSlotGap: CGFloat = 6
    /// Inline row action: 24×24, icon 16, radius 6, no gap between actions; fades 120 ms (`hoverFade`).
    public static let rowActionSize: CGFloat = 24
    public static let rowActionRadius: CGFloat = 6
    /// Project row: its actions end 4 before the highlight's edge (12 from the sidebar's).
    public static let projectRowTrailing: CGFloat = 12
    /// Session row: name and badge end 8 inside the highlight (16 from the sidebar's edge); the actions overhang it by 4.
    public static let sessionRowTrailing: CGFloat = 16
    public static let rowActionsOverhang: CGFloat = 4
    /// Section header (`.sec`): 28 high, 8 above, text at x 20, buttons 12 from the edge and 2 apart; filter ring 1.5.
    public static let sectionHeaderHeight: CGFloat = 28
    public static let sectionHeaderTop: CGFloat = 8
    public static let sectionHeaderX: CGFloat = 20
    public static let sectionHeaderTrailing: CGFloat = 12
    public static let sectionActionGap: CGFloat = 2
    public static let sectionFilterRing: CGFloat = 1.5
    /// Host row's state and the nav rows' counters/keys end 10 inside the highlight.
    public static let rowEndTrailing: CGFloat = 18
    /// «+ Новая сессия»: 8 above, 4 below. Bottom group: 6 above, 8 below.
    public static let newTaskTop: CGFloat = 8
    public static let newTaskBottom: CGFloat = 4
    public static let bottomBarTop: CGFloat = 6
    public static let bottomBarBottom: CGFloat = 8

    /// Custom «⋯» menu: 256 wide, radius 10, padding 6; items 30 (8 left / 10 right, radius 6, icon 16 + 10).
    public static let menuWidth: CGFloat = 256
    public static let menuRadius: CGFloat = 10
    public static let menuPadding: CGFloat = 6
    public static let menuItemHeight: CGFloat = 30
    public static let menuItemPaddingLeading: CGFloat = 8
    public static let menuItemPaddingTrailing: CGFloat = 10
    public static let menuItemRadius: CGFloat = 6
    public static let menuIconGap: CGFloat = 10
    public static let menuFont: CGFloat = 13
    public static let menuShortcutFont: CGFloat = 12
    /// Separator: 1 `lineSheet`, 6 above/below, 2 at the sides. Header: 28, 12 `text3`.
    public static let menuSeparatorPaddingV: CGFloat = 6
    public static let menuSeparatorPaddingH: CGFloat = 2
    public static let menuHeaderHeight: CGFloat = 28
    /// The menu opens this far below its button (left edges aligned).
    public static let menuAnchorGap: CGFloat = 4
}

extension Theme.ui {
    private static func c(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
    /// Inline action under the pointer: white at 7 %.
    public static let rowActionHover = Color.white.opacity(0.07)
    /// Badge border (`line2`) and fill (`bg` at 35 %).
    public static let line2 = c(0x2b3446)
    public static let diffBadgeFill = bg.opacity(Theme.diffBadgeFillOpacity)
    /// Destructive menu item text/icon (= `failed` text), its key at 60 %, its hover (`failed` at 14 %).
    public static let danger = c(0xff6b61)
    public static let dangerShortcut = c(0xff6b61, 0.6)
    public static let dangerHover = c(0xff453a, 0.14)
    /// «ошибка» in a session's status line.
    public static let failedText = c(0xff6b61)
}
