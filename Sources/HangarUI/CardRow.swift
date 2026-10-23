import SwiftUI

/// One row of a sheet card (new-task-v4 `.r`): fixed-width one-line label `text2`, the value after it.
/// Used by every sheet card and the settings window (DESIGN.md: one card of rows, labels never wrap).
struct CardRow<Value: View>: View {
    let label: String
    var mono = false
    /// Report rows (read-only text): tighter, so the whole server fits the sheet.
    var compact = false
    var labelWidth = Theme.cardLabelWidth
    var first = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: Theme.cardRowGap) {
            Text(verbatim: label)
                .font(.system(size: Theme.fontSize.sheetRow, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: Theme.pickGap) { value }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, compact ? Theme.reportRowPaddingV : Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

/// Text field inside a card row: no field chrome (the card is the frame), `sheetRow` size.
struct CardField: ViewModifier {
    var mono = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: Theme.fontSize.sheetRow, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.ui.sheetText)
    }
}

extension View {
    /// The card around `CardRow`s.
    func sheetCard() -> some View {
        overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.lineSheet, lineWidth: 1))
    }
}
