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
        static let treeRow: CGFloat = Height.rowList
        static let rowInset: CGFloat = Space.s2
        static let rowRadius: CGFloat = Radius.control
        static let treeIndent: CGFloat = Space.s4
        static let chevronSlot: CGFloat = Icon.toolbar
        static let chevron: CGFloat = Icon.inline
        static let rowIcon: CGFloat = Icon.row
        static let rowGap: CGFloat = Space.iconGap
        /// The branch block: open up to this many rows, then it scrolls.
        static let branchesMaxRows = 6
        static let sectionHeight: CGFloat = Height.barPane
        static let sectionButton: CGFloat = Height.controlSmall
        static let sectionIcon: CGFloat = Icon.row

        /// Log: row height, graph column, lane spacing and the first lane's x, dot radius and its `bg1` ring, merge ring.
        static let logRow: CGFloat = Height.rowList
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
        /// A log row's chips: widest (`origin/release/2.0` whole), narrowest when the row is tight, gap; the subject
        /// goes first and gives way down to `subjectMin`.
        static let refMaxWidth: CGFloat = 160
        static let refMinWidth: CGFloat = 44
        static let refGap: CGFloat = Space.s1
        static let subjectMin: CGFloat = 72
        /// The `⇅` of a branch whose remote twin is at the same commit.
        static let refMarkGap: CGFloat = 3

        /// Ref pill: height, side padding, radius; own branch `accent` 14 %, remote `text2` 14 %, others their lane 16 %.
        static let refHeight: CGFloat = Badge.height
        static let refPaddingH: CGFloat = Badge.paddingH
        static let refRadius: CGFloat = Radius.control

        /// Small glyphs (back chevron, tick); the search field itself is `Theme.Input`.
        static let searchIcon: CGFloat = Icon.row

        static let chipLeading: CGFloat = Space.s2
        static let chipGap: CGFloat = Space.iconGap
        static let chipIcon: CGFloat = Icon.inline
        static let chipMaxWidth: CGFloat = 132
        /// The Branch chip keeps one width: setting another filter must not move it (the others truncate instead).
        static let branchChipWidth: CGFloat = 112
        static let chipsMargin: CGFloat = Space.s2

        /// Path picks in the Path filter menu.
        static let popoverListMax = 8

        /// Details under the log: the divider's grip, default share, the least either side keeps.
        static let gripWidth: CGFloat = 28
        static let gripHeight: CGFloat = 4
        static let dividerHit: CGFloat = 8
        static let detailsShare: CGFloat = 0.4
        static let minPane: CGFloat = 112
        /// Below this panel height the details replace the log (a window under ~640 pt).
        static let compactHeight: CGFloat = 540
        static let detailsHeader: CGFloat = Height.barPane
        static let metaPaddingV: CGFloat = Space.s2
        static let filesHeader: CGFloat = Height.barPane
        static let fileIndent: CGFloat = 22
        /// The A / M / D letter column of a commit file.
        static let badgeWidth: CGFloat = 14
        /// Notices (offline, errors, empty): top and side padding.
        static let noticePaddingV: CGFloat = Space.s2
        static let blockGap: CGFloat = Space.s2
    }

    /// Search tab (#91): fields are `Theme.Input` (#93), toggles inside the query field, file groups.
    enum SearchTab {
        static let toggle: CGFloat = Height.controlSmall
        static let toggleGap: CGFloat = Space.s1
        /// The accent dot on «…» while an include / exclude glob is set.
        static let filterDot: CGFloat = Icon.tabDot
        static let gap: CGFloat = Space.iconGap
        /// A file group's header and its lines' indent (under the file name, past the chevron and icon).
        static let fileRow: CGFloat = Height.rowList
        static let hitIndent: CGFloat = 36
        static let hitPaddingV: CGFloat = Space.s1
    }
}
