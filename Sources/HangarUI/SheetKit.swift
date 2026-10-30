import AppKit
import SwiftUI

/// The parts every settings-like screen shares (the settings window and the sheets): header, sections of cards,
/// switch, status pill, footer, and the sheet frame itself (DESIGN.md «Лист», «Окно настроек»).

/// Sheet title (`sheetTitle` semibold) with an optional `text3` subtitle (the project, the host).
struct SheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.sheetButtonGap) {
            Text(verbatim: title)
                .font(Theme.Typography.title.font(.semibold))
                .foregroundStyle(Theme.ui.text0)
            if let subtitle {
                Text(verbatim: subtitle).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text3)
                    .lineLimit(1).truncationMode(.middle)
                    .help(subtitle)
            }
        }
        .padding(.top, Theme.sheetHeaderTop)
        .padding(.bottom, Theme.sheetHeaderBottom)
    }
}

/// Footer: a `text3` hint on the left, the buttons on the right (cancel first, the primary last).
struct SheetFooter<Buttons: View>: View {
    var hint: String = L10n.escCancel
    /// Hidden but kept (no jump), e.g. while Esc belongs to an install terminal.
    var hintHidden = false
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: Theme.sheetButtonGap) {
            Text(verbatim: hint).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                .lineLimit(1).truncationMode(.middle)
                .opacity(hintHidden ? 0 : 1)
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, Theme.sheetFooterPaddingV)
    }
}

/// A section: an optional group header (`caption` 600 `text3`, 12 / 12 / 4, §3.18), then its card of rows (full width),
/// or bare content.
struct CardSection<Content: View>: View {
    var title: String?
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(verbatim: title)
                    .font(Theme.Typography.caption.font(.semibold))
                    .foregroundStyle(Theme.ui.text3)
                    .padding(.horizontal, Theme.Space.s3)
                    .padding(.top, Theme.Space.s3)
                    .padding(.bottom, Theme.Space.s1)
            }
            if card {
                VStack(spacing: 0) { content }
                    .frame(maxWidth: .infinity)
                    .sheetCard()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status pill: a word in its colour on that colour at 15 % (green done, amber to-do, red only for errors).
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.secondary.font())
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Theme.pillPaddingH)
            .frame(height: Theme.pillHeight)
            .background(Capsule().fill(color.opacity(Theme.Opacity.fill)))
            .fixedSize()
    }
}

extension View {
    /// The sheet frame: side paddings, one width for every sheet, `bg2` background, one-line rows.
    func sheetFrame(width: CGFloat = Theme.sheetWidth) -> some View {
        padding(.horizontal, Theme.sheetPaddingH)
            .frame(width: width)
            .font(Theme.Typography.body.font())
            .lineLimit(1)
            .background(Theme.ui.bg2)
    }
}

/// Confirmations and notices in the sheet style (instead of a system alert): the question, what it means, an
/// optional switch (e.g. «also delete the branch»), «Отмена» and the primary button (destructive by default).
/// `other` adds a middle button («Не сохранять»); `onCancel == nil` makes a notice with one «OK» (↩ or Esc).
struct ConfirmSheet: View {
    let message: String
    var info = ""
    var button = L10n.ok
    var destructive = true
    var checkbox: String?
    var other: String?
    var onOther: () -> Void = {}
    let onConfirm: (_ checked: Bool) -> Void
    var onCancel: (() -> Void)?
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: message)
            if !info.isEmpty {
                Text(verbatim: info)
                    .foregroundStyle(Theme.ui.text2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.sheetNameTop)
            }
            if let checkbox {
                Checkbox(checkbox, isOn: $checked)
                    .padding(.top, Theme.sheetGap)
            }
            SheetFooter {
                if let onCancel {
                    Button(L10n.cancel, action: onCancel)
                        .buttonStyle(.hangar(.secondary))
                        .keyboardShortcut(.cancelAction)
                    if let other {
                        Button(other, action: onOther)
                            .buttonStyle(.hangar(.secondary))
                    }
                    Button(button) { onConfirm(checked) }
                        .buttonStyle(.hangar(destructive ? .destructive : .primary))
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button(button) { onConfirm(false) }
                        .buttonStyle(.hangar(.primary))
                        .keyboardShortcut(.defaultAction)
                        // A notice: Esc closes it too (the invisible button only carries the shortcut).
                        .background {
                            Button("") { onConfirm(false) }.keyboardShortcut(.cancelAction)
                                .opacity(0).accessibilityHidden(true)
                        }
                }
            }
            .padding(.top, Theme.sheetGap)
        }
        .sheetFrame(width: Theme.confirmSheetWidth)
    }
}

extension NSWindow {
    /// Shows `content` as a Hangar sheet on this window (queued after a sheet already up). Its buttons call
    /// `end(response)`; `done` then runs exactly once, also when the sheet is ended from outside (`.stop`).
    @discardableResult
    func beginHangarSheet<V: View>(_ content: (_ end: @escaping (NSApplication.ModalResponse) -> Void) -> V,
                                   done: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: Theme.sheetPlaceholderHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.bg2
        sheet.appearance = appearance
        let end: (NSApplication.ModalResponse) -> Void = { [weak self, weak sheet] response in
            guard let self, let sheet, sheet.sheetParent === self else { return }
            self.endSheet(sheet, returnCode: response)
        }
        let host = NSHostingController(rootView: content(end))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        beginSheet(sheet) { response in MainActor.assumeIsolated { done(response) } }
        return sheet
    }
}
