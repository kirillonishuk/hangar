import SwiftUI
import Update

/// «Доступна версия X» (#86): the release notes, the download / install state, «Пропустить версию» · «Позже» · «Обновить».
struct UpdateSheet: View {
    let model: UpdateModel
    let onClose: () -> Void

    private var busy: Bool {
        switch model.phase {
        case .downloading, .preparing: true
        default: false
        }
    }

    var body: some View {
        let offer = model.offer
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.updateSheetTitle(offer?.version ?? "—"), subtitle: model.current.map(L10n.updateCurrent))
            notes(offer?.notes ?? "")
            status(offer)
                .frame(maxWidth: .infinity, minHeight: Theme.updateStatusHeight, maxHeight: Theme.updateStatusHeight, alignment: .leading)
                .padding(.top, Theme.sheetMessageTop)
            SheetFooter(hint: "") {
                Button(L10n.updateSkip) { model.skip(); onClose() }
                    .buttonStyle(SheetButton(primary: false))
                    .disabled(busy || model.phase == .ready)
                Button(L10n.updateLater) { model.later(); onClose() }
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(model.phase == .ready ? L10n.updateRestart : L10n.updateInstall) { model.install() }
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || offer == nil)
            }
            .padding(.top, Theme.sheetGap)
        }
        .sheetFrame()
    }

    /// The notes box (as the integration diff): wraps and scrolls.
    private func notes(_ text: String) -> some View {
        let lines = ReleaseFeed.noteLines(text)
        let content = VStack(alignment: .leading, spacing: Theme.updateNotesLineGap) {
            if lines.isEmpty { Text(verbatim: L10n.updateNoNotes).foregroundStyle(Theme.ui.text3) }
            ForEach(lines.indices, id: \.self) { i in
                Text(inline(lines[i].text))
                    .font(.system(size: Theme.fontSize.sheetRow, weight: lines[i].heading ? .semibold : .regular))
                    .foregroundStyle(lines[i].heading ? Theme.ui.text0 : Theme.ui.text2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.updateNotesPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One fixed height (a long changelog scrolls): the sheet never resizes with the notes.
        return ScrollView(.vertical) { content }
            .frame(height: Theme.updateNotesHeight)
        .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
        .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.line2, lineWidth: 1))
    }

    /// Bold, code and links of a line; plain text if it isn't valid Markdown.
    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }

    @ViewBuilder private func status(_ offer: UpdateOffer?) -> some View {
        switch model.phase {
        case .downloading(let p):
            HStack(spacing: Theme.sheetButtonGap) {
                ProgressLine(value: p ?? 0)
                Text(verbatim: p.map { L10n.updateDownloading(Int($0 * 100)) } ?? L10n.updateDownloadingPlain)
                    .foregroundStyle(Theme.ui.text2)
                    .monospacedDigit()
                    .fixedSize()
            }
        case .preparing: message(L10n.updatePreparing, Theme.ui.text2)
        case .ready: message(L10n.updateReady, Theme.ui.done)
        case .otherInstance: message(L10n.updateOtherInstance, Theme.ui.waiting)
        case .manual: message(L10n.updateManual(tildePath(model.bundle.deletingLastPathComponent().path)), Theme.ui.waiting)
        case .failed(let why): message(L10n.updateFailed(why), Theme.ui.failedText)
        default:
            if let error = model.installError {
                message(L10n.updateInstallFailed(error), Theme.ui.failedText)
            } else {
                HStack(spacing: Theme.sheetButtonGap) {
                    message(L10n.updateQuitHint, Theme.ui.text3)
                    Spacer(minLength: 0)
                    if let page = offer?.page {
                        Link(L10n.updateOpenPage, destination: page)
                            .foregroundStyle(Theme.ui.accentText)
                            .pointingHand()
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func message(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).foregroundStyle(color).lineLimit(1).truncationMode(.middle).help(text)
    }
}

/// A thin determinate bar: `line2` track, `accent` fill.
private struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ui.line2)
                Capsule().fill(Theme.ui.accent).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: Theme.updateProgressHeight)
    }
}
