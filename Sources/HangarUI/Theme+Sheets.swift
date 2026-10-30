import SwiftUI

/// Sheet and settings-window tokens (DESIGN.md «Лист», «Окно настроек»); the rest of `Theme` lives in Theme.swift.
extension Theme {
    /// Confirmations (archive, delete, remove): narrower; their switch label takes most of the row.
    public static let confirmSheetWidth: CGFloat = 480
    public static let cardLabelWide: CGFloat = 300
    /// Card row content height = a field's: a segment, a picker, a `SheetButton` or a field fits, so every row is as tall.
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
    /// Branch picker row: name → meta.
    public static let dropdownItemGap: CGFloat = 8
    /// `SheetButton` and sheet icon menus on hover (the `FilledRowStyle` approach: lighter fill).
    public static let sheetButtonHoverBrightness: Double = 0.06
}

extension Theme {
    /// Settings window (System Settings style): a category list on the left, the page on the right; resizable.
    public static let settingsSize = NSSize(width: 970, height: 600)
    public static let settingsMinSize = NSSize(width: 680, height: 440)
    public static let settingsSidebarWidth: CGFloat = 190
    public static let settingsSidebarPadding: CGFloat = 10
    public static let settingsNavRowHeight: CGFloat = 30
    public static let settingsNavRadius: CGFloat = 6
    public static let settingsNavGap: CGFloat = 2
    /// The page: margins, its title, gaps between sections and under a section header.
    public static let settingsPagePadding: CGFloat = 24
    public static let settingsSectionGap: CGFloat = 20
    /// Settings' status line preview (#105): one terminal row, faint text at half the foreground as Ghostty draws it.
    public static let statuslinePreviewHeight: CGFloat = 30
    public static let statuslinePreviewPaddingH: CGFloat = 10
    public static let statuslineBarHeavy: CGFloat = 2
    /// Where a dragged part's chip lands (#110).
    public static let statuslineDropLine: CGFloat = 2
    /// A preview line wider than the card fades out over its last points instead of being cut.
    public static let statuslinePreviewFade: CGFloat = 16
    public static let settingsHeaderGap: CGFloat = 8
    /// The label column is measured from the longest label of the language (+ slack); never wider than the max.
    public static let settingsLabelSlack: CGFloat = 1
    public static let settingsLabelMax: CGFloat = 220
    /// Switch (themes-v1.html `.sw`): 30×18, 2 inset around the knob.
    public static let switchWidth: CGFloat = 30
    public static let switchHeight: CGFloat = 18
    public static let switchInset: CGFloat = 2
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
