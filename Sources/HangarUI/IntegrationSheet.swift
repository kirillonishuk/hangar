import Integration
import SwiftUI

/// Consent sheet (580): the exact diff of the file, the backup it gets, «Отмена» / «Применить».
/// Nothing is written before «Применить»; removal uses the same sheet.
struct IntegrationSheet: View {
    let plan: IntegrationPlan
    let error: String?
    let onApply: () -> Void
    let onCancel: () -> Void

    private var path: String { plan.displayPath ?? tildePath(plan.url.path) }
    /// Where the backup goes: next to the real file (a remote one: its target as resolved on the server).
    private var backupBase: String { plan.backupDisplayPath ?? tildePath(plan.resolved.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                .foregroundStyle(Theme.ui.sheetText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.sheetHeaderTop)
                .padding(.bottom, Theme.sheetGap)

            diff
                .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
                .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.control, lineWidth: 1))

            if plan.original != nil {
                // The real name gets the write time; the pattern shows where the copy goes.
                Text(verbatim: L10n.backupWillBeCreated(backupBase + ".hangar-backup-yyyyMMdd-HHmmss"))
                    .font(.system(size: Theme.fontSize.tab))
                    .foregroundStyle(Theme.ui.text3)
                    .padding(.top, Theme.sheetGap)
            }
            if let error {
                Text(verbatim: error).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.failed)
                    .padding(.top, Theme.railInset)
            }

            HStack(spacing: Theme.statusDot) {
                Text(L10n.escCancel).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: 0)
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.apply, action: onApply)
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.vertical, Theme.sheetFooterPaddingV)
            .padding(.top, Theme.sheetGap)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
    }

    /// «Изменить <path>?» with the path in mono.
    private var title: AttributedString {
        var s = AttributedString(L10n.integrationConfirmTitle(path))
        if let r = s.range(of: path) { s[r].font = .system(size: Theme.fontSize.sheetTitle, weight: .medium, design: .monospaced) }
        return s
    }

    /// Long lines wrap: everything that will be written is visible without sideways scrolling.
    private var diff: some View {
        let lines = VStack(alignment: .leading, spacing: 0) {
            ForEach(plan.diff.indices, id: \.self) { i in line(plan.diff[i]) }
        }
        .padding(.vertical, Theme.railInset)
        return ViewThatFits(in: .vertical) {
            lines
            ScrollView(.vertical) { lines }.frame(height: Theme.Diff.maxHeight)
        }
        .frame(maxHeight: Theme.Diff.maxHeight)
        .font(.system(size: Theme.Diff.sheetFont, design: .monospaced))
    }

    @ViewBuilder private func line(_ l: DiffLine) -> some View {
        switch l {
        case .same(let t): row(" ", t, marker: Theme.ui.text3, background: .clear)
        case .added(let t): row("+", t, marker: Theme.Diff.addMarker, background: Theme.Diff.add)
        case .removed(let t): row("-", t, marker: Theme.Diff.delMarker, background: Theme.Diff.del)
        case .skipped(let n): row(" ", L10n.linesUnchanged(n), marker: Theme.ui.text3, text: Theme.ui.text3, background: .clear)
        }
    }

    private func row(_ sign: String, _ value: String, marker: Color, text: Color = Theme.ui.text, background: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: sign).foregroundStyle(marker).frame(width: Theme.Diff.markerWidth, alignment: .leading)
            Text(verbatim: value).foregroundStyle(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Diff.paddingH)
        .padding(.vertical, Theme.Diff.linePaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}
