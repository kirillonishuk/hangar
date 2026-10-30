import SwiftUI

/// Sheet and settings-window tokens (DESIGN.md «Лист», «Окно настроек»); the rest of `Theme` lives in Theme.swift.
extension Theme {
    /// Card row content height = a field's: a segment, a picker, a button or a field fits, so every row is as tall.
    public static let cardRowMinHeight: CGFloat = Theme.Input.height
    /// Between footer / inline buttons, and between a title and its subtitle.
    public static let sheetButtonGap: CGFloat = Space.s2
    /// Above the messages (errors, hints, warnings) under a card.
    public static let sheetMessageTop: CGFloat = Space.s2
    /// Between stacked lines of one value or message block.
    public static let sheetLineGap: CGFloat = Space.s1
    /// Install-plan command box.
    public static let planPaddingV: CGFloat = Space.s2
    public static let planCommandGap: CGFloat = Space.s2
}

extension Theme {
    /// Settings window (spec §3.18): the category list (216, `bg1`) on the left, the page on the right; resizable (#109).
    public static let settingsSize = NSSize(width: 970, height: 600)
    public static let settingsMinSize = NSSize(width: 680, height: 440)
    public static let settingsSidebarWidth: CGFloat = 216
    /// The page: its 52 header (`title`, the traffic lights' bar), then the cards with margins 20 / 24.
    public static let settingsHeaderHeight: CGFloat = Height.barToolbar
    public static let settingsPagePaddingV: CGFloat = Space.s5
    public static let settingsPagePaddingH: CGFloat = Space.s6
    /// A text field in a card row is at most this wide.
    public static let settingsFieldWidth: CGFloat = 260
    /// Between cards; a group header above a card adds its own 12 / 4.
    public static let settingsSectionGap: CGFloat = Space.s3
    /// A card row: `cardRow` = `controlRegular` + 6 / 6.
    public static let settingsRowPaddingV: CGFloat = (Height.cardRow - Height.controlRegular) / 2
    /// Settings' status line preview (#105): one terminal row, faint text at half the foreground as Ghostty draws it.
    public static let statuslinePreviewHeight: CGFloat = Height.controlRegular
    public static let statuslinePreviewPaddingH: CGFloat = Space.s3
    public static let statuslineBarHeavy: CGFloat = 2
    /// Where a dragged part's chip lands (#110).
    public static let statuslineDropLine: CGFloat = 2
    /// A preview line wider than the card fades out over its last points instead of being cut.
    public static let statuslinePreviewFade: CGFloat = Space.s8
    public static let settingsHeaderGap: CGFloat = Space.s2
    /// Theme tiles (themes-v1.html `.tcard`): a mini window over the name; the chosen one is outlined in `accent`.
    public static let themeTileGap: CGFloat = Space.s3
    public static let themeTileRadius: CGFloat = Radius.popover
    public static let themeTileBorder: CGFloat = 2
    public static let themeTileStrip: CGFloat = 22
    /// Integrations (#111): the agent's logo by its title, the gap under a row's title, «Где установлено» items.
    public static let integrationTitleIcon: CGFloat = Icon.toolbar
    public static let integrationSubGap: CGFloat = 2
    public static let integrationWhereGap: CGFloat = Space.s3
    public static let integrationWhereIcon: CGFloat = Icon.row
    public static let integrationTagPaddingH: CGFloat = Badge.paddingH
    public static let integrationTagHeight: CGFloat = Badge.height
    /// Integration status pill (§3.13): `control.small` high, 8 side padding, fill of its colour at 15 %.
    public static let pillHeight: CGFloat = Height.controlSmall
    public static let pillPaddingH: CGFloat = Space.s2
}
