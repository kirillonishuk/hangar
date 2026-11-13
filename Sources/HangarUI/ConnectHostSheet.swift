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
            SheetFields {
                SheetField(label: L10n.hostLabel, note: invalid ? L10n.hostInvalid : L10n.plainSSHHint, failed: invalid) {
                    HStack(spacing: Theme.pickGap) {
                        TextField("", text: $host)
                            .focused($focused)
                            .onSubmit(connect)
                            .inputField(focused: focused, invalid: invalid, placeholder: host.isEmpty ? L10n.hostPlaceholder : nil)
                        if !configHosts.isEmpty { HostMenu(hosts: configHosts) { host = $0 } }
                    }
                }
            }
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
