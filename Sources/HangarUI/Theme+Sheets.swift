import SwiftUI

/// Sheet and settings-window tokens (DESIGN.md «Лист», «Окно настроек»); the rest of `Theme` lives in Theme.swift.
extension Theme {
    /// Confirmations (archive, delete, remove): narrower; their switch label takes most of the row.
    public static let confirmSheetWidth: CGFloat = 480
    /// Card row content height = a field's: a segment, a picker, a button or a field fits, so every row is as tall.
    public static let cardRowMinHeight: CGFloat = Theme.Input.height
    /// Between footer / inline buttons, and between a title and its subtitle.
    public static let sheetButtonGap: CGFloat = 8
    /// Above the messages (errors, hints, warnings) under a card.
    public static let sheetMessageTop: CGFloat = 8
    /// Between stacked lines of one value or message block.
    public static let sheetLineGap: CGFloat = 4
    /// Install-plan command box.
    public static let planPaddingV: CGFloat = 8
    public static let planCommandGap: CGFloat = 8
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
    public static let statuslinePreviewHeight: CGFloat = 30
    public static let statuslinePreviewPaddingH: CGFloat = 10
    public static let statuslineBarHeavy: CGFloat = 2
    /// Where a dragged part's chip lands (#110).
    public static let statuslineDropLine: CGFloat = 2
    /// A preview line wider than the card fades out over its last points instead of being cut.
    public static let statuslinePreviewFade: CGFloat = 16
    public static let settingsHeaderGap: CGFloat = 8
    /// Theme tiles (themes-v1.html `.tcard`): a mini window over the name; the chosen one is outlined in `accent`.
    public static let themeTileGap: CGFloat = 12
    public static let themeTileRadius: CGFloat = 8
    public static let themeTileBorder: CGFloat = 2
    public static let themeTileStrip: CGFloat = 22
    /// Integrations (#111): the agent's logo by its title, the gap under a row's title, «Где установлено» items.
    public static let integrationTitleIcon: CGFloat = 18
    public static let integrationSubGap: CGFloat = 2
    public static let integrationWhereGap: CGFloat = 14
    public static let integrationWhereIcon: CGFloat = 14
    public static let integrationTagPaddingH: CGFloat = 6
    public static let integrationTagHeight: CGFloat = 18
    /// Integration status pill: 20 high, 8 side padding, fill of its colour at 15 %.
    public static let pillHeight: CGFloat = 20
    public static let pillPaddingH: CGFloat = 8
}
