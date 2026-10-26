import AppKit
import SwiftUI

/// «Сессии» view tokens (redesign-v1 §5 and §9: `historyHeader / historyRow`, `searchField`, `rowRadius`).
extension Theme {
    public static let historyHeaderHeight: CGFloat = 48
    public static let historyRowHeight: CGFloat = 36
    /// Group and day headings: 32 high, the label sits 6 above the bottom.
    public static let historyGroupHeight: CGFloat = 32
    public static let historyGroupBottom: CGFloat = 6
    /// Header and group text inset from the view's edges.
    public static let historyPaddingH: CGFloat = 20
    /// The row highlight's inset from the edges, its corner radius and inner padding.
    public static let historyRowInset: CGFloat = 12
    public static let historyRowRadius: CGFloat = 8
    public static let historyRowPaddingH: CGFloat = 8
    public static let historyRowGap: CGFloat = 10
    public static let historyListBottom: CGFloat = 8
    /// Fixed columns: message count and time (they fade out under the hover actions).
    public static let historyCountWidth: CGFloat = 72
    public static let historyTimeWidth: CGFloat = 84
    public static let historyHeaderGap: CGFloat = 12
    public static let historyTitleSize: CGFloat = 15
    public static let historyCountsGap: CGFloat = 8

    /// Hover action: 24 high, radius 6, `hoverStrong`; the icon-only one (delete) is square.
    public static let historyActionHeight: CGFloat = 24
    public static let historyActionPaddingH: CGFloat = 10
    public static let historyActionRadius: CGFloat = 6
    public static let historyActionIcon: CGFloat = 12
    public static let historyActionGap: CGFloat = 6

    /// Search field width (its look is `Theme.Input`).
    public static let historySearchWidth: CGFloat = 260

    /// Agent segment (Все / Claude / Codex): 28 high, radius 7 outside and 5 inside, 2 pt padding.
    public static let historySegmentWidth: CGFloat = 220
    public static let historySegmentRadius: CGFloat = 7
    public static let historySegmentItemRadius: CGFloat = 5
    public static let historySegmentPadding: CGFloat = 2

    /// The closed session's layout glyph: a 10×12 box per tab (14 wide when split), 1.25 stroke, radius 2.
    public static let historyLayoutBox = CGSize(width: 10, height: 12)
    public static let historyLayoutSplitWidth: CGFloat = 14
    public static let historyLayoutStroke: CGFloat = 1.25
    public static let historyLayoutRadius: CGFloat = 2
    public static let historyLayoutGap: CGFloat = 2
    /// At most this many boxes; more tabs still count in the text.
    public static let historyLayoutMax = 6

    /// `+N −M` badge (`Metric.diffBadge`): 20 high, mono 12, 0×6, radius 6, `line2` border, `bg` at 35 %.
    public static let historyBadgeHeight: CGFloat = 20
    public static let historyBadgePaddingH: CGFloat = 6
    public static let historyBadgeRadius: CGFloat = 6
    public static let historyBadgeGap: CGFloat = 6
    public static let historyBadgeFill: Double = 0.35
    /// `line2` of the token table (= `control`).
    public static var historyBadgeBorder: Color { ui.control }
}
