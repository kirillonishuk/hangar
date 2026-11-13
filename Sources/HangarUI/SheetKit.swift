import AppKit
import SwiftUI
import Workspace

/// The parts every settings-like screen shares (the settings window and the sheets): header, sections of cards,
/// switch, status pill, footer, and the sheet frame itself (DESIGN.md «Лист», «Окно настроек»).

/// Sheet title (`title` 600) with an optional context after it (`body` `text2`: the project, the host; or a pop-up
/// button: «Новый чат»'s project), §3.14.
struct SheetHeader<Context: View>: View {
    let title: String
    @ViewBuilder var context: Context

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.sheetButtonGap) {
            Text(verbatim: title)
                .font(Theme.Typography.title.font(.semibold))
                .foregroundStyle(Theme.ui.text0)
            context
        }
        .padding(.top, Theme.sheetHeaderTop)
        .padding(.bottom, Theme.sheetHeaderBottom)
    }
}

extension SheetHeader where Context == SheetSubtitle {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title) { SheetSubtitle(text: subtitle) }
    }
}

struct SheetSubtitle: View {
    let text: String?

    var body: some View {
        if let text {
            Text(verbatim: text).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text2)
                .lineLimit(1).truncationMode(.middle)
                .help(text)
        }
    }
}

/// Footer (§3.14): 20 under the body, a `line2` rule across the whole sheet, the buttons on the right (cancel first,
/// the primary last); no «Esc — отмена». `leading`: a progress line on the left.
struct SheetFooter<Leading: View, Buttons: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: Theme.sheetButtonGap) {
            leading
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, Theme.sheetFooterPaddingV)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.ui.line2).frame(height: 1).padding(.horizontal, -Theme.sheetPaddingH)
        }
        .padding(.top, Theme.sheetBodyBottom)
    }
}

extension SheetFooter where Leading == EmptyView {
    init(@ViewBuilder buttons: () -> Buttons) {
        self.init(leading: { EmptyView() }, buttons: buttons)
    }
}

/// The fields of a form sheet (§3.14, HD-164): 16 under the header, groups 16 apart, no card around plain fields.
struct SheetFields<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sheetFieldGap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.sheetFieldsTop)
    }
}

/// A sheet field (§3.11): the label above (`secondary` `text2`, 4 to the control), the control, then one note under it —
/// what the field is for (`text3`) or its error (`failedText`, `failed`).
struct SheetField<Content: View>: View {
    let label: String
    var note: String?
    var failed = false
    @ViewBuilder var content: Content
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            Text(verbatim: label).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text2)
                .opacity(enabled ? 1 : Theme.Opacity.inactive)  // its controls dim themselves
            content
            if let note, !note.isEmpty {
                Text(verbatim: note)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(failed ? Theme.ui.failedText : Theme.ui.text3)
                    .lineLimit(Theme.errorMaxLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// «Где работать» (§3.11 radio options, HD-164: one look in «Новый чат» and «Новый подчат»): the folder or a separate copy.
/// One Tab stop (as a text field, so without Full Keyboard Access too): the caller puts `.focused` on it; ←/↑ the folder,
/// →/↓ the copy, Space switches; VoiceOver reads it as radio buttons.
struct WhereOptions: View {
    let folderTitle: String
    let folderDetail: AttributedString
    var folderHelp = ""
    let copyDetail: String
    var copyAvailable = true
    let worktree: Bool
    /// The group has keyboard focus: the chosen card shows the ring.
    let focused: Bool
    let choose: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: Theme.Space.s2) {
            RadioOption(title: folderTitle, detail: folderDetail, selected: !worktree, focused: focused && !worktree) { pick(false) }
                .help(folderHelp)
            RadioOption(title: L10n.whereCopy, detail: AttributedString(copyDetail), selected: worktree,
                        focused: focused && worktree) { pick(true) }
                .disabled(!copyAvailable)
        }
        .fixedSize(horizontal: false, vertical: true)  // both cards as tall as the taller one
        .focusable(enabled, interactions: .edit)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .leftArrow, .upArrow, .rightArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow, .upArrow: pick(false)
            case .rightArrow, .downArrow: pick(true)
            default: pick(!worktree)
            }
            return .handled
        }
        .accessibilityRepresentation {
            Picker(L10n.whereToWork, selection: Binding(get: { worktree }, set: { pick($0) })) {
                Text(verbatim: folderTitle).tag(false)
                Text(verbatim: L10n.whereCopy).tag(true)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func pick(_ copy: Bool) {
        guard enabled, !copy || copyAvailable, copy != worktree else { return }
        choose(copy)
    }
}

/// «Агент» (HD-164): Claude or Codex, in «Новый чат» and «Новый подчат».
struct AgentSegment: View {
    let agent: LeafKind
    let choose: (LeafKind) -> Void

    var body: some View {
        Segmented(selection: agent, options: [(LeafKind.claude, "Claude"), (LeafKind.codex, "Codex")], choose: choose)
            .accessibilityLabel(L10n.subChatAgent)
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
        }
        .sheetFrame()
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
