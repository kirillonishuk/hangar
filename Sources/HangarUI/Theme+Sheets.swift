import SwiftUI

/// Sheet and settings-window tokens (DESIGN.md «Лист», «Окно настроек»); the rest of `Theme` lives in Theme.swift.
extension Theme {
    /// Longest settings label in one line: «Не засыпать, пока агенты работают» at `sheetRow` is ~236.
    public static let settingsCardLabelWidth: CGFloat = 240
    /// Project settings: «Ветка по умолчанию» (~136) on one line.
    public static let projectCardLabelWidth: CGFloat = 140
    /// Card row content height: a segment, a picker or a `SheetButton` fits, so text-only rows are as tall.
    public static let cardRowMinHeight: CGFloat = 26
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

extension Theme.ui {
    /// Icon menus on the sheet background (`hover` is darker than `sheet`).
    static let sheetHover = Color(nsColor: Theme.hoverStrong)
}
