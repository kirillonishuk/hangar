import Exec
import SwiftUI

/// «Подключиться к хосту…» (#NN-ssh-shell): a host (typed, or from the ssh config drop-down) → a plain ssh shell tab.
/// Nothing is checked here: ssh itself asks for a password or reports the error in the tab.
struct ConnectHostSheet: View {
    let configHosts: [String]
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    @State private var host = ""
    @FocusState private var focused: Bool

    private var valid: String? { validSSHHost(host.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.connectHostTitle)
                .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                .foregroundStyle(Theme.ui.sheetText)
                .padding(.top, Theme.sheetHeaderTop)
                .padding(.bottom, Theme.sheetHeaderBottom)
            VStack(spacing: 0) {
                CardRow(label: L10n.hostLabel, first: true) {
                    TextField("", text: $host, prompt: Text(L10n.hostPlaceholder).foregroundStyle(Theme.ui.text3))
                        .modifier(CardField())
                        .focused($focused)
                        .onSubmit(connect)
                    if !configHosts.isEmpty { HostMenu(hosts: configHosts) { host = $0 } }
                }
            }
            .sheetCard()
            .padding(.top, Theme.sheetNameTop)
            Text(L10n.plainSSHHint)
                .font(.system(size: Theme.fontSize.tab))
                .foregroundStyle(Theme.ui.text3)
                .padding(.top, Theme.sheetMessageTop)
            footer.padding(.vertical, Theme.sheetFooterPaddingV)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .lineLimit(1)
        .background(Theme.ui.sheet)
        .onAppear { focused = true }
    }

    private var footer: some View {
        HStack(spacing: Theme.sheetButtonGap) {
            Text(L10n.escCancel).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
            Spacer(minLength: 0)
            Button(L10n.cancel, action: onCancel)
                .buttonStyle(SheetButton(primary: false))
                .keyboardShortcut(.cancelAction)
            Button(L10n.connect, action: connect)
                .buttonStyle(SheetButton(primary: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(valid == nil)
                .opacity(valid == nil ? Theme.disabledButtonOpacity : 1)
        }
    }

    private func connect() {
        if let valid { onConnect(valid) }
    }
}
