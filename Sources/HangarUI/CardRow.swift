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
                .font((mono ? Theme.Typography.mono : Theme.Typography.body).font())
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: Theme.pickGap) { value }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, compact ? Theme.reportRowPaddingV : Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

extension View {
    /// The card around `CardRow`s.
    func sheetCard() -> some View {
        overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.line2, lineWidth: 1))
    }
}
