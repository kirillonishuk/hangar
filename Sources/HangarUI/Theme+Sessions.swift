import AppKit
import SwiftUI

/// «Сессии» view tokens (sessions-v2.html variant A, #107).
extension Theme {
    /// Header (title, scope segment, search) 52; the chips' bar under it 36.
    public static let historyHeaderHeight: CGFloat = 52
    public static let historyFilterHeight: CGFloat = 36
    public static let historyHeaderGap: CGFloat = 14
    /// Header and chip bar insets: 20 on the left, 16 on the right.
    public static let historyPaddingH: CGFloat = 20
    public static let historyPaddingTrailing: CGFloat = 16
    public static let historyChipGap: CGFloat = 6
    /// The `line` between the agent and the state chips: 1×16, 6 aside.
    public static let historyChipSeparator = CGSize(width: 1, height: 16)
    public static let historySearchWidth: CGFloat = 280

    /// Hosts shown as items; more go into «Ещё ▾».
    public static let historyScopeMaxHosts = 3

    /// Group heading 34 high, the label 6 above the bottom; chevron 13, host icon 12.
    public static let historyGroupHeight: CGFloat = 34
    public static let historyGroupBottom: CGFloat = 6
    public static let historyGroupGap: CGFloat = 7
    public static let historyGroupIcon: CGFloat = 13
    public static let historyHostIcon: CGFloat = 12
    /// A group shows this many rows until «Показать ещё N».
    public static let sessionsGroupLimit = 5
    /// «Показать ещё N»: 30 high, its text under the row titles.
    public static let historyMoreHeight: CGFloat = 30
    public static let historyMoreLeading: CGFloat = 46

    /// Rows: 34 high, inset 8, padding 12, radius 7, gap 10; agent icon 16.
    public static let historyRowHeight: CGFloat = 34
    public static let historyRowInset: CGFloat = 8
    public static let historyRowPaddingH: CGFloat = 12
    public static let historyRowRadius: CGFloat = 7
    public static let historyRowGap: CGFloat = 10
    public static let historyRowIcon: CGFloat = 16
    public static let historyListBottom: CGFloat = 10
    /// Fixed columns: where (folder / ⎇ + branch) 210, state 96, time 64 — state and time hide under the hover actions.
    public static let historyWhereWidth: CGFloat = 210
    public static let historyStateWidth: CGFloat = 96
    public static let historyTimeWidth: CGFloat = 64
    public static let historyColumnIcon: CGFloat = 13
    public static let historyStateIcon: CGFloat = 12
    public static let historyColumnGap: CGFloat = 6
    public static let historyActionGap: CGFloat = 6

    /// Centered states (offline, empty, nothing found): 12 apart, hint at most 420 wide.
    public static let historyCenterGap: CGFloat = 12
    public static let historyCenterHintWidth: CGFloat = 420
}

/// «Продолжить» of an empty session and a chooser pane: up to 5 rows of 32, 440 wide; the last scan keeps the 50 newest.
extension Theme {
    public static let continueRows = 5
    public static let continueKept = 50
    public static let continueRowHeight: CGFloat = 32
    public static let continueWidth: CGFloat = 440
}
