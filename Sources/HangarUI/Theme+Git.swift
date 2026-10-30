import AppKit
import SwiftUI

/// Git tab tokens (redesign-v1.html §4 and the token table §9); Theme.swift holds the rest.
extension Theme {
    enum GitTab {
        /// Graph rails by colour index (modulo): the theme's three lanes, then the git «M» colour.
        static var lanes: [Color] { let p = Theme.palette; return [p.lane1, p.lane2, p.lane3, p.gitM].map(Theme.ui.of) }
        static func lane(_ index: Int) -> Color { let lanes = lanes; return lanes[((index % lanes.count) + lanes.count) % lanes.count] }

        /// Side padding of the segment, search field, chips and headers (`Metric.inspectorPadding`).
        static let padding: CGFloat = Theme.inspectorSegmentPaddingH
        /// Tree rows (branches, commit files): height, highlight inset from the edges, radius, one level's indent.
        static let treeRow: CGFloat = 24
        static let rowInset: CGFloat = 6
        static let rowRadius: CGFloat = 6
        static let treeIndent: CGFloat = 16
        static let chevronSlot: CGFloat = 16
        static let chevron: CGFloat = 12
        static let rowIcon: CGFloat = 14
        static let rowGap: CGFloat = 6
        /// The branch block: open up to this many rows, then it scrolls.
        static let branchesMaxRows = 6
        static let sectionHeight: CGFloat = 28
        static let sectionButton: CGFloat = 24
        static let sectionIcon: CGFloat = 13

        /// Log: row height, graph column, lane spacing and the first lane's x, dot radius and its `bg1` ring, merge ring.
        static let logRow: CGFloat = 28
        static let laneStep: CGFloat = 12
        static let laneX0: CGFloat = 10
        static let dot: CGFloat = 4
        static let dotRing: CGFloat = 2
        static let mergeRing: CGFloat = 3.5
        static let rail: CGFloat = 1.5
        /// Wider histories are clipped to this many lanes (the column stays readable at 300 pt).
        static let maxLanes = 8
        /// Ref chips shown in a row, then «+k»; all refs are in the tooltip.
        static let maxRefs = 2
        /// A log row's chips: widest, narrowest when the row is tight, gap; the subject always keeps `subjectMin`.
        static let refMaxWidth: CGFloat = 104
        static let refMinWidth: CGFloat = 44
        static let refGap: CGFloat = 4
        static let subjectMin: CGFloat = 72
        /// The `⇅` of a branch whose remote twin is at the same commit.
        static let refMarkGap: CGFloat = 3

        /// Ref pill: height, side padding, radius; own branch `accent` 14 %, remote `text2` 14 %, others their lane 16 %.
        static let refHeight: CGFloat = 18
        static let refPaddingH: CGFloat = 5
        static let refRadius: CGFloat = 4

        /// Small glyphs (back chevron, tick); the search field itself is `Theme.Input`.
        static let searchIcon: CGFloat = 14

        /// Filter chips: height, paddings 8 / 6, radius, gap; active = `accent` 14 % with an `accent` 25 % border.
        static let chipHeight: CGFloat = 24
        static let chipLeading: CGFloat = 8
        static let chipTrailing: CGFloat = 6
        static let chipRadius: CGFloat = 6
        static let chipGap: CGFloat = 6
        static let chipIcon: CGFloat = 12
        static let chipMaxWidth: CGFloat = 132
        /// The Branch chip keeps one width: setting another filter must not move it (the others truncate instead).
        static let branchChipWidth: CGFloat = 112
        static let chipsMargin: CGFloat = 8

        /// Filter popovers: as the «⋯» menu (width, padding, item height, radius, separator margins).
        static let popoverWidth: CGFloat = 224
        static let popoverPadding: CGFloat = 6
        static let menuItem: CGFloat = 30
        static let menuItemRadius: CGFloat = 6
        static let menuCheck: CGFloat = 16
        static let popoverListMax = 8

        /// Details under the log: the divider's grip, default share, the least either side keeps.
        static let gripWidth: CGFloat = 28
        static let gripHeight: CGFloat = 4
        static let dividerHit: CGFloat = 8
        static let detailsShare: CGFloat = 0.4
        static let minPane: CGFloat = 112
        /// Below this panel height the details replace the log (a window under ~640 pt).
        static let compactHeight: CGFloat = 540
        static let detailsHeader: CGFloat = 32
        static let subjectFont: CGFloat = 13.5
        static let subjectFontLarge: CGFloat = 14.5
        static let bodyFont: CGFloat = 13
        static let metaFont: CGFloat = 12
        static let metaPaddingV: CGFloat = 8
        static let filesHeader: CGFloat = 28
        static let fileIndent: CGFloat = 22
        static let mono: CGFloat = 12
        /// The A / M / D letter column of a commit file.
        static let badgeWidth: CGFloat = 14
        /// Notices (offline, errors, empty): top and side padding.
        static let noticePaddingV: CGFloat = 8
        static let blockGap: CGFloat = 8
    }

    /// Search tab (#91): fields are `Theme.Input` (#93), toggles inside the query field, file groups.
    enum SearchTab {
        /// Aa / .* / ab toggles: box, radius, label size; on = `accent` 14 % with an `accent` 25 % border (as filter chips).
        static let toggle: CGFloat = 20
        static let toggleRadius: CGFloat = 4
        static let toggleFont: CGFloat = 11.5
        static let toggleGap: CGFloat = 2
        /// The accent dot on «…» while an include / exclude glob is set.
        static let filterDot: CGFloat = 6
        static let gap: CGFloat = 6
        /// A file group's header and its lines' indent (under the file name, past the chevron and icon).
        static let fileRow: CGFloat = 24
        static let hitIndent: CGFloat = 36
        static let hitPaddingV: CGFloat = 3
        static let mono: CGFloat = 12
    }
}
