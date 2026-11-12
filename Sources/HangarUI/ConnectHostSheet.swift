import Exec
import SwiftUI

/// «Подключиться к хосту…» (HD-064): a host (typed, or from the ssh config drop-down) → a plain ssh shell tab.
/// Nothing is checked here: ssh itself asks for a password or reports the error in the tab.
struct ConnectHostSheet: View {
    let configHosts: [String]
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    @State private var host = ""
    @FocusState private var focused: Bool

    private var valid: String? { sshHostInput(host) }
    /// Typed but not a host (a space, a whole ssh command): the field is red and says what it takes.
    private var invalid: Bool { valid == nil && !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.connectHostTitle)
            CardSection {
                CardRow(label: L10n.hostLabel, first: true, note: invalid ? L10n.hostInvalid : nil, failed: true) {
                    TextField("", text: $host)
                        .focused($focused)
                        .onSubmit(connect)
                        .inputField(focused: focused, invalid: invalid, placeholder: host.isEmpty ? L10n.hostPlaceholder : nil)
                    if !configHosts.isEmpty { HostMenu(hosts: configHosts) { host = $0 } }
                }
            }
            .padding(.top, Theme.sheetNameTop)
            Text(L10n.plainSSHHint)
                .font(Theme.Typography.secondary.font())
                .foregroundStyle(Theme.ui.text3)
                .padding(.top, Theme.sheetMessageTop)
            footer
        }
        .sheetFrame()
        .onAppear { focused = true }
    }

    private var footer: some View {
        SheetFooter {
            Button(L10n.cancel, action: onCancel)
                .buttonStyle(.hangar(.secondary))
                .keyboardShortcut(.cancelAction)
            Button(L10n.connect, action: connect)
                .buttonStyle(.hangar(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(valid == nil)
        }
    }

    private func connect() {
        if let valid { onConnect(valid) }
    }
}
