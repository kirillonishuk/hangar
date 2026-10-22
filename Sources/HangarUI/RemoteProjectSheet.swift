import Exec
import Foundation
import Observation
import SwiftUI

/// «Удалённый проект»: host + path → connect → `pwd -P` on the server → the server report in the same sheet.
@MainActor @Observable final class RemoteProjectModel {
    enum Phase: Equatable {
        case editing, connecting
        /// `mono`: ssh's own text.
        case failed(String, mono: Bool)
        /// The folder exists on the server: its real path.
        case found(String)
    }

    var host = "" { didSet { if host != oldValue { hostChanged() } } }
    var path = "" { didSet { if path != oldValue, phase != .connecting { phase = .editing; server = nil } } }
    private(set) var phase: Phase = .editing
    private(set) var server: ServerCheckModel?
    /// `Host` names of the user's ssh config, for the drop-down.
    let configHosts: [String]

    @ObservationIgnored private let remote: RemoteHosts
    /// Lets a host go that this sheet connected and no project uses.
    @ObservationIgnored private let release: (String) -> Void
    @ObservationIgnored private var connectedHost: String?

    init(remote: RemoteHosts, configHosts: [String], release: @escaping (String) -> Void) {
        self.remote = remote
        self.configHosts = configHosts
        self.release = release
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }

    var canConnect: Bool { phase != .connecting && validSSHHost(trimmedHost) != nil && !trimmedPath.isEmpty }
    /// Missing tools on the server never block adding.
    var canAdd: Bool { foundPath != nil }
    var foundPath: String? { if case .found(let p) = phase { p } else { nil } }

    func connect() async {
        let h = trimmedHost, p = trimmedPath
        guard canConnect else { return }
        phase = .connecting
        server = nil
        connectedHost = h
        let state = await remote.connect(h)
        guard h == trimmedHost, p == trimmedPath else { return }  // edited meanwhile: that edit reset the phase
        guard state == .connected, let home = remote.hosts[h]?.home else {
            let f = hostFailure(h, remote.hosts[h])
            phase = .failed(f.text, mono: f.mono)
            return
        }
        let real = await remoteRealPath(p, home: home, runner: remote.runner(h))
        guard h == trimmedHost, p == trimmedPath else { return }
        guard let real else {
            phase = .failed(L10n.remotePathMissing, mono: false)
            return
        }
        let s = ServerCheckModel(host: h, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: h))
        server = s
        phase = .found(real)
        await s.show()
    }

    /// The sheet closes without adding.
    func cancel() {
        if let h = connectedHost { release(h) }
        connectedHost = nil
    }

    private func hostChanged() {
        phase = .editing
        server = nil
        cancel()
    }
}

/// The folder's real path on the server (`pwd -P`), nil if it is not there. `~` is the server's home; a relative path
/// is taken from there too. Shared by the sheet and `projects.add --host`.
func remoteRealPath(_ path: String, home: String, runner: Runner) async -> String? {
    let full = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path.hasPrefix("/") ? path : home + "/" + path
    guard let r = try? await runner.run(["pwd", "-P"], full), r.status == 0, let real = lastLine(r.stdout), real.hasPrefix("/") else { return nil }
    return real
}

/// Sheet (580, new-task-v4): title, one card (Хост with the ssh-config drop-down, Путь mono), the connection state,
/// then the embedded server report. One primary button: «Подключиться», then «Добавить».
struct RemoteProjectSheet: View {
    @Bindable var model: RemoteProjectModel
    /// The window's content height: the sheet stays inside it.
    let windowHeight: CGFloat
    let onAdd: (_ host: String, _ path: String) -> Void
    let onCancel: () -> Void

    @FocusState private var focus: Field?
    private enum Field { case host, path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.remoteProjectTitle)
                .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                .foregroundStyle(Theme.ui.sheetText)
                .padding(.top, Theme.sheetHeaderTop)
                .padding(.bottom, Theme.sheetHeaderBottom)

            card.padding(.top, Theme.sheetNameTop)
            status
            if let server = model.server {
                ServerCheckView(model: server, embedded: true, maxHeight: windowHeight - Theme.remoteSheetChrome)
                    .padding(.top, Theme.sheetGap)
            }
            footer.padding(.vertical, Theme.sheetFooterPaddingV)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .lineLimit(1)
        .background(Theme.ui.sheet)
        .onAppear { focus = .host }
    }

    private var card: some View {
        VStack(spacing: 0) {
            CardRow(label: L10n.hostLabel, first: true) {
                TextField("", text: $model.host, prompt: Text(L10n.hostPlaceholder).foregroundStyle(Theme.ui.text3))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.ui.sheetText)
                    .focused($focus, equals: .host)
                    .onSubmit { focus = .path }
                if !model.configHosts.isEmpty {
                    Menu {
                        ForEach(model.configHosts, id: \.self) { h in Button(h) { model.host = h; focus = .path } }
                    } label: { Image(nsImage: Icon.chevronDown.image).renderingMode(.template) }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .pointingHand()
                }
            }
            CardRow(label: L10n.pathLabel) {
                TextField("", text: $model.path)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                    .foregroundStyle(Theme.ui.sheetText)
                    .focused($focus, equals: .path)
                    .onSubmit(primary)
            }
        }
        .disabled(model.phase == .connecting)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.lineSheet, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: Theme.pickGap) {
                ProgressView().controlSize(.small)
                Text(L10n.hostConnecting).foregroundStyle(Theme.ui.text3)
            }
            .font(.system(size: Theme.fontSize.tab))
            .padding(.top, Theme.statusDot)
        case .failed(let text, let mono):
            Text(verbatim: text)
                .font(.system(size: Theme.fontSize.tab, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.ui.failed)
                .lineLimit(Theme.errorMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, Theme.statusDot)
        default: EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.statusDot) {
            Text(L10n.escCancel).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
            Spacer(minLength: 0)
            // A running install (maybe at a sudo prompt) is not killed by a stray click.
            Button(L10n.cancel, action: onCancel)
                .buttonStyle(SheetButton(primary: false))
                .disabled(model.server?.phase == .installing)
                .opacity(model.server?.phase == .installing ? Theme.disabledButtonOpacity : 1)
                // Esc belongs to the install terminal while it runs.
                .keyboardShortcut(model.server?.phase == .installing ? nil : .cancelAction)
            let enabled = model.canAdd || model.canConnect
            Button(action: primary) {
                // The label keeps its width under the spinner: no jump.
                Text(model.canAdd ? L10n.add : L10n.connect).opacity(model.phase == .connecting ? 0 : 1)
                    .overlay { if model.phase == .connecting { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(SheetButton(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!enabled)
            .opacity(enabled || model.phase == .connecting ? 1 : Theme.disabledButtonOpacity)
        }
    }

    private func primary() {
        if let path = model.foundPath {
            onAdd(model.host.trimmingCharacters(in: .whitespaces), path)
        } else if model.canConnect {
            Task { await model.connect() }
        }
    }
}
