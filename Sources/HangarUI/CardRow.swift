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
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: Theme.cardRowGap) {
            Text(verbatim: label)
                .font((mono ? Theme.Typography.mono : Theme.Typography.body).font())
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
                .opacity(enabled ? 1 : Theme.Opacity.inactive)  // its controls dim themselves
            HStack(spacing: Theme.pickGap) { value }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, compact ? Theme.reportRowPaddingV : Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

/// A settings card row (spec §3.18): the label `body` with an optional explanation `secondary` `text3` under it on the
/// left, the control on the right; at least `cardRow` high, a `line` above every row but the first.
struct SettingsRow<Detail: View, Value: View>: View {
    let label: String
    var first = false
    @ViewBuilder var detail: Detail
    @ViewBuilder var value: Value
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: Theme.Space.s3) {
            VStack(alignment: .leading, spacing: 0) {
                // The label keeps its line; the explanation wraps and a field gives way first.
                Text(verbatim: label).foregroundStyle(Theme.ui.text1).lineLimit(1).fixedSize()
                detail
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(enabled ? 1 : Theme.Opacity.inactive)  // its controls dim themselves
            .layoutPriority(1)  // the label never truncates: a field shrinks to its minimum first
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s2) { value }
                .lineLimit(1)
        }
        .font(Theme.Typography.body.font())
        .frame(maxWidth: .infinity, minHeight: Theme.Height.cardRow - 2 * Theme.settingsRowPaddingV, alignment: .leading)
        .padding(.vertical, Theme.settingsRowPaddingV)
        .padding(.horizontal, Theme.Space.s3)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

extension SettingsRow where Detail == Text? {
    init(_ label: String, hint: String? = nil, first: Bool = false, @ViewBuilder value: () -> Value) {
        self.init(label: label, first: first, detail: { hint.map { Text(verbatim: $0) } }, value: value)
    }
}

extension EnvironmentValues {
    /// Cards inside the settings window: filled `bg1` with a `line` border (§3.18); in a sheet only outlined.
    @Entry var settingsCards = false
}

extension View {
    /// The card around `CardRow`s / `SettingsRow`s.
    func sheetCard() -> some View { modifier(CardFrame()) }
}

private struct CardFrame: ViewModifier {
    @Environment(\.settingsCards) private var settings

    func body(content: Content) -> some View {
        if settings {
            content
                .background(RoundedRectangle(cornerRadius: Theme.Radius.popover).fill(Theme.ui.bg1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover).stroke(Theme.ui.line, lineWidth: 1))
        } else {
            content.overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.line2, lineWidth: 1))
        }
    }
}
