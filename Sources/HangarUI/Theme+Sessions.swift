import AppKit
import SwiftUI

/// «История» view (spec §3.17 on the v2 list of #107): sizes are design-system tokens.
extension Theme {
    /// Header (title, scope segment, search) 52; the chips' bar under it 36.
    public static let historyHeaderHeight: CGFloat = Height.barToolbar
    public static let historyFilterHeight: CGFloat = Height.barTabs
    public static let historyHeaderGap: CGFloat = Space.s3
    /// Header and chip bar insets: 20 on the left, 16 on the right.
    public static let historyPaddingH: CGFloat = Space.s5
    public static let historyPaddingTrailing: CGFloat = Space.s4
    public static let historyChipGap: CGFloat = Space.iconGap
    /// The `line` between the agent and the state chips: 1×16, 6 aside.
    public static let historyChipSeparator = CGSize(width: 1, height: Icon.toolbar)
    public static let historySearchWidth: CGFloat = 260

    /// Hosts shown as items; more go into «Ещё ▾».
    public static let historyScopeMaxHosts = 3

    /// Group heading 28 (`caption` 600 `text3`): chevron and host icon 12.
    public static let historyGroupHeight: CGFloat = Height.barPane
    /// A group shows this many rows until «Показать ещё N».
    public static let sessionsGroupLimit = 5
    /// «Показать ещё N»: a list row, its text under the row titles.
    public static let historyMoreHeight: CGFloat = Height.rowList
    public static let historyMoreLeading: CGFloat = historyRowInset + historyRowPaddingH + Icon.toolbar + historyRowGap

    /// Rows `row.large` 32, inset 8 + padding 12 (the text lines up with the group heading); agent icon 16.
    public static let historyRowHeight: CGFloat = Height.rowLarge
    public static let historyRowInset: CGFloat = Space.s2
    public static let historyRowPaddingH: CGFloat = Space.s3
    public static let historyRowGap: CGFloat = Space.s2
    public static let historyListBottom: CGFloat = Space.s2
    /// Fixed columns: where (folder / ⎇ + branch) 210, state 96, time 64 — state and time hide under the hover actions.
    public static let historyWhereWidth: CGFloat = 210
    public static let historyStateWidth: CGFloat = 96
    public static let historyTimeWidth: CGFloat = 64
    public static let historyColumnGap: CGFloat = Space.iconGap

    /// Centered states (offline, empty, nothing found): 12 apart, at most 420 wide.
    public static let historyCenterGap: CGFloat = Space.s3
    public static let historyCenterHintWidth: CGFloat = 420
}

/// «Продолжить» of an empty session and a chooser pane: up to 5 rows of 32, 440 wide; the last scan keeps the 50 newest.
extension Theme {
    public static let continueRows = 5
    public static let continueKept = 50
    public static let continueWidth: CGFloat = 440
}
