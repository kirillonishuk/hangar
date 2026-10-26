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
                .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                .foregroundStyle(Theme.ui.sheetText)
            if let subtitle {
                Text(verbatim: subtitle).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
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
            Text(verbatim: hint).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                .lineLimit(1).truncationMode(.middle)
                .opacity(hintHidden ? 0 : 1)
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, Theme.sheetFooterPaddingV)
    }
}

/// A section: an optional header on the card's left edge, then its card of rows (full width), or bare content.
struct CardSection<Content: View>: View {
    var title: String?
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.settingsHeaderGap) {
            if let title {
                Text(verbatim: title)
                    .font(.system(size: Theme.fontSize.tab, weight: .semibold))
                    .foregroundStyle(Theme.ui.text2)
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

/// On/off switch (themes-v1.html `.sw`): `primary` track when on, `control` when off; the whole switch is the button.
struct CardSwitch: View {
    let on: Bool
    let toggle: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    init(on: Bool, toggle: @escaping (Bool) -> Void) {
        self.on = on
        self.toggle = toggle
    }

    init(isOn: Binding<Bool>) {
        self.init(on: isOn.wrappedValue) { isOn.wrappedValue = $0 }
    }

    var body: some View {
        let knob = Theme.switchHeight - 2 * Theme.switchInset
        Button { toggle(!on) } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.ui.primary : Theme.ui.control)
                Circle().fill(on ? Theme.ui.primaryText : Theme.ui.text2)
                    .frame(width: knob, height: knob)
                    .padding(.horizontal, Theme.switchInset)
            }
            .frame(width: Theme.switchWidth, height: Theme.switchHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : Theme.disabledButtonOpacity)
        .pointingHand(enabled)
        .animation(Motion.ease(Theme.selectionFade), value: on)
        .accessibilityValue(on ? L10n.toggleOn : L10n.toggleOff)
    }
}

/// Status pill: a word in its colour on that colour at 15 % (green done, amber to-do, red only for errors).
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: Theme.fontSize.tab))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Theme.pillPaddingH)
            .frame(height: Theme.pillHeight)
            .background(Capsule().fill(color.opacity(Theme.pillFillOpacity)))
            .fixedSize()
    }
}

extension View {
    /// The sheet frame: side paddings, one width for every sheet, `sheet` background, one-line rows.
    func sheetFrame(width: CGFloat = Theme.sheetWidth) -> some View {
        padding(.horizontal, Theme.sheetPaddingH)
            .frame(width: width)
            .font(.system(size: Theme.fontSize.sheetRow))
            .lineLimit(1)
            .background(Theme.ui.sheet)
    }
}

/// Archive / delete / remove confirmations in the sheet style (instead of a system alert): the question, what it
/// means, an optional switch (e.g. «also delete the branch»), «Отмена» and the destructive button.
struct ConfirmSheet: View {
    let message: String
    let info: String
    let button: String
    var checkbox: String?
    let onConfirm: (_ checked: Bool) -> Void
    let onCancel: () -> Void
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: message)
            Text(verbatim: info)
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.sheetNameTop)
            if let checkbox {
                CardSection {
                    CardRow(label: checkbox, labelWidth: Theme.cardLabelWide, first: true) {
                        Spacer(minLength: 0)
                        CardSwitch(isOn: $checked)
                    }
                }
                .padding(.top, Theme.sheetGap)
            }
            SheetFooter {
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(button) { onConfirm(checked) }
                    .buttonStyle(SheetButton(primary: true, destructive: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, Theme.sheetGap)
        }
        .sheetFrame(width: Theme.confirmSheetWidth)
    }
}
