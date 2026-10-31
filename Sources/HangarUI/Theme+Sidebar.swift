import AppKit
import SwiftUI

/// Sidebar and popover-menu tokens of redesign v1 (redesign-v1.html §2, §3, §9); Theme.swift holds the rest.
extension Theme {
    /// Row highlight (hover, selection) inset from the sidebar edges and its radius (§3.3: inset 8, `radius.control`).
    public static let rowInset: CGFloat = Space.s2
    public static let rowRadius: CGFloat = Radius.control
    /// A chat row (§3.3): the dot 32 in from the highlight's edge (centre x 44), its name 8 after the dot.
    public static let chatIndent: CGFloat = rowInset + Space.s8 + Icon.statusDot / 2 - gutterMarkerX
    public static let chatTextX: CGFloat = gutterMarkerX + Icon.statusDot / 2 + Space.s2
    /// The branch at a chat row's end: `mono` 11 up to this wide, truncated at its end.
    public static let rowBranchMax: CGFloat = 92
    public static let rowStatusGap: CGFloat = Space.s1
    /// Project row: its actions end 4 before the highlight's edge (12 from the sidebar's).
    public static let projectRowTrailing: CGFloat = Space.s3
    /// Session row: name and badge end 8 inside the highlight (16 from the sidebar's edge); the actions overhang it by 4.
    public static let sessionRowTrailing: CGFloat = Space.s4
    /// Inline row actions (`control.small` icon buttons) overhang the row's edge by this much.
    public static let rowActionsOverhang: CGFloat = Space.s1
    /// Section header (§3.3, `bar.pane` high): 8 above, text at x 20, buttons 12 from the edge and 4 apart; filter ring 1.5.
    public static let sectionHeaderTop: CGFloat = Space.s2
    public static let sectionHeaderX: CGFloat = Space.s5
    public static let sectionHeaderTrailing: CGFloat = Space.s3
    public static let sectionActionGap: CGFloat = Space.s1
    public static let sectionFilterRing: CGFloat = 1.5
    /// Footer (§3.3): 44 high, icon buttons 28 at 12 from the edges, 4 apart; in the rail they stack, 8 above and below.
    public static let sidebarFooterHeight: CGFloat = 44

    /// `PopoverMenu` (spec §3.12): 256 wide (a branch list 320), padding 6, items `row.list` 24; a long list scrolls
    /// past 12 items.
    public static let menuWidth: CGFloat = 256
    public static let menuWidthWide: CGFloat = 320
    public static let menuPadding: CGFloat = 6
    public static let menuListMaxRows = 12
    /// The menu opens this far below its button (left edges aligned).
    public static let menuAnchorGap: CGFloat = Space.s1
}
