import SwiftUI

/// Sheet and settings-window tokens (DESIGN.md «Лист», «Окно настроек»); the rest of `Theme` lives in Theme.swift.
extension Theme {
    /// Longest settings label in one line: «Уведомления о лимитах» at `sheetRow` is ~158 (ru).
    public static let settingsCardLabelWidth: CGFloat = 164
    /// Project settings: «Команда после создания» (~165 at `sheetRow`, ru; en is shorter) on one line.
    public static let projectCardLabelWidth: CGFloat = 168
    /// Project settings sheet: `sheetWidth` + the wider label column, so long paths keep room.
    public static let projectSheetWidth: CGFloat = 640
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

extension Theme {
    /// ☕ row: the on/off switch and the «held» dot on the icon.
    public static let keepAwakeSwitchWidth: CGFloat = 24
    public static let keepAwakeSwitchHeight: CGFloat = 14
    public static let keepAwakeSwitchInset: CGFloat = 2
    public static let keepAwakeDot: CGFloat = 6
    public static let keepAwakeDotOffset: CGFloat = 2
}

extension Theme.ui {
    /// Icon menus on the sheet background (`hover` is darker than `sheet`).
    static let sheetHover = Color(nsColor: Theme.hoverStrong)
}
