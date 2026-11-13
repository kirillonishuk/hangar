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
    /// The last failure was the folder (the host answered): the path field is marked, not the host one.
    @ObservationIgnored private var failedOnPath = false
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

    /// The host to dial: a pasted `ssh user@host` counts as `user@host`.
    var trimmedHost: String { sshHostInput(host) ?? host.trimmingCharacters(in: .whitespaces) }
    /// Typed but not a host: red before any connect, with what it takes.
    var hostMalformed: Bool { sshHostInput(host) == nil && !host.trimmingCharacters(in: .whitespaces).isEmpty }
    private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }

    private var failed: Bool { if case .failed = phase { true } else { false } }
    var hostInvalid: Bool { hostMalformed || failed && !failedOnPath }
    var pathInvalid: Bool { failed && failedOnPath }

    var canConnect: Bool { phase != .connecting && validSSHHost(trimmedHost) != nil && !trimmedPath.isEmpty }
    /// Missing tools on the server never block adding.
    var canAdd: Bool { foundPath != nil }
    var foundPath: String? { if case .found(let p) = phase { p } else { nil } }

    func connect() async {
        let h = trimmedHost, p = trimmedPath
        guard canConnect else { return }
        phase = .connecting
        failedOnPath = false
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
            failedOnPath = true
            phase = .failed(L10n.remotePathMissing, mono: false)
            return
        }
        let s = ServerCheckModel(host: h, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: h))
        server = s
        phase = .found(real)
        await s.show()
    }

    /// The host answers now (this sheet connected it, or a project uses it): «Путь» can suggest its folders (HD-164).
    var canSuggestFolders: Bool {
        phase != .connecting && validSSHHost(trimmedHost) != nil && remote.hosts[trimmedHost]?.state == .connected
    }

    /// The server's folders for «Путь» as typed, one level: those of its last folder that start with the rest; nil when
    /// that folder can't be listed.
    func folderSuggestions() async -> [String]? {
        let h = trimmedHost
        guard canSuggestFolders, let home = remote.hosts[h]?.home else { return nil }
        let (dir, prefix) = remotePathCompletion(path)
        guard let listing = try? await listRemoteFolder(remote.runner(h), path: remoteFullPath(dir, home: home),
                                                        limit: Self.folderLimit) else { return nil }
        return remoteFolderSuggestions(listing, dir: dir, prefix: prefix)
    }

    /// Entries read for one level of suggestions: a menu, not a file browser.
    static let folderLimit = 500

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
    guard let r = try? await runner.run(["pwd", "-P"], remoteFullPath(path, home: home)), r.status == 0, let real = lastLine(r.stdout), real.hasPrefix("/") else { return nil }
    return real
}

/// `~` and a relative path are the server's home.
func remoteFullPath(_ path: String, home: String) -> String {
    path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path.hasPrefix("/") ? path : home + "/" + path
}

/// «Путь» as typed → the folder to list and the start of the name being typed (HD-164): `~/src/ap` → (`~/src/`, `ap`);
/// a bare name is under the home (`""`), `~` is the home itself.
func remotePathCompletion(_ typed: String) -> (dir: String, prefix: String) {
    let t = typed.trimmingCharacters(in: .whitespaces)
    if t == "~" { return ("~/", "") }
    guard let slash = t.lastIndex(of: "/") else { return ("", t) }
    return (String(t[...slash]), String(t[t.index(after: slash)...]))
}

/// The listing's folders starting with `prefix` (case-insensitive; hidden ones only once a `.` is typed) as values for
/// «Путь»: `dir` + name + `/`, so the next pick goes one level deeper.
func remoteFolderSuggestions(_ listing: RemoteListing, dir: String, prefix: String) -> [String] {
    let lower = prefix.lowercased()
    return listing.entries
        .filter { $0.isDir && (prefix.hasPrefix(".") || !$0.name.hasPrefix(".")) && $0.name.lowercased().hasPrefix(lower) }
        .map { dir + $0.name + "/" }
}

/// The ▾ menu of «Путь»: the suggested folders by name, or why there are none.
@MainActor func remoteFolderMenu(_ found: [String]?, pick: @escaping (String) -> Void) -> [PopoverMenuEntry] {
    guard let found, !found.isEmpty else {
        return [.item(PopoverMenuItem(title: found == nil ? L10n.remoteFoldersFailed : L10n.remoteFoldersNone, enabled: false) {})]
    }
    return found.map { path in
        let name = (path.dropLast() as Substring).split(separator: "/").last.map(String.init) ?? path
        return .item(PopoverMenuItem(title: name + "/", mono: true, file: (name, true)) { pick(path) })
    }
}

/// Sheet (520): title, the fields (Сервер with the ssh-config drop-down, Путь mono with the server's folders), the connection state,
/// then the embedded server report. One primary button: «Подключиться», then «Добавить».
struct RemoteProjectSheet: View {
    @Bindable var model: RemoteProjectModel
    /// The window's content height: the sheet stays inside it.
    let windowHeight: CGFloat
    let onAdd: (_ host: String, _ path: String) -> Void
    let onCancel: () -> Void

    @FocusState private var focus: Field?
    private enum Field { case host, path }
    @State private var chrome = SheetChrome()
    @State private var pathAnchor = MenuAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.remoteProjectTitle)

            SheetFields { fields }
            status
            if let server = model.server {
                ServerCheckView(model: server, embedded: true, maxHeight: chrome.budget(windowHeight))
                    .measuredPart($chrome)
                    .padding(.top, Theme.sheetGap)
            }
            footer
        }
        .measuredSheet($chrome)
        .sheetFrame()
        .onAppear { focus = .host }
    }

    @ViewBuilder private var fields: some View {
        Group {
            SheetField(label: L10n.hostLabel, note: model.hostMalformed ? L10n.hostInvalid : nil, failed: true) {
                HStack(spacing: Theme.pickGap) {
                    TextField("", text: $model.host)
                        .focused($focus, equals: .host)
                        .onSubmit { focus = .path }
                        .inputField(focused: focus == .host, invalid: model.hostInvalid,
                                    placeholder: model.host.isEmpty ? L10n.hostPlaceholder : nil)
                    if !model.configHosts.isEmpty {
                        HostMenu(hosts: model.configHosts) { h in model.host = h; focus = .path }
                    }
                }
            }
            SheetField(label: L10n.pathLabel) {
                HStack(spacing: Theme.pickGap) {
                    TextField("", text: $model.path)
                        .focused($focus, equals: .path)
                        .onSubmit(primary)
                        // ↓ as in a path completer: the folders of what is typed.
                        .onKeyPress(.downArrow) {
                            guard model.canSuggestFolders else { return .ignored }
                            showFolders(again: false)
                            return .handled
                        }
                        .inputField(focused: focus == .path, mono: true, invalid: model.pathInvalid,
                                    placeholder: model.path.isEmpty ? L10n.remotePathPlaceholder : nil)
                    IconButton(icon: .chevronDown, help: model.canSuggestFolders ? L10n.remoteFoldersHelp : L10n.remoteFoldersNeedConnect) {
                        showFolders(again: false)
                    }
                    .disabled(!model.canSuggestFolders)
                }
                .background(MenuAnchorView(anchor: pathAnchor))
            }
        }
        .disabled(model.phase == .connecting)
    }

    /// The server's folders under «Путь»; a pick goes one level deeper and opens the next level (when it has folders).
    private func showFolders(again: Bool) {
        Task {
            let found = await model.folderSuggestions()
            if again, found?.isEmpty != false { return }
            PopoverMenu.show(remoteFolderMenu(found) { path in
                model.path = path
                focus = .path
                showFolders(again: true)
            }, below: pathAnchor.view)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: Theme.pickGap) {
                ProgressView().controlSize(.small)
                Text(L10n.hostConnecting).foregroundStyle(Theme.ui.text3)
            }
            .font(Theme.Typography.secondary.font())
            .padding(.top, Theme.sheetMessageTop)
        case .failed(let text, let mono):
            Text(verbatim: text)
                .font((mono ? Theme.Typography.mono : Theme.Typography.secondary).font())
                .foregroundStyle(Theme.ui.failed)
                .lineLimit(Theme.errorMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, Theme.sheetMessageTop)
        default:
            // Why «Отмена» and Esc are off: a running install may sit at a sudo prompt.
            if installing {
                Text(verbatim: L10n.installCancelLocked)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.sheetMessageTop)
            }
        }
    }

    private var installing: Bool { model.server?.phase == .installing }

    private var footer: some View {
        // Esc goes to the install terminal while it runs (as in «Сервер»).
        SheetFooter {
            // A running install (maybe at a sudo prompt) is not killed by a stray click.
            Button(L10n.cancel, action: onCancel)
                .buttonStyle(.hangar(.secondary))
                .disabled(installing)
                .help(installing ? L10n.installCancelLocked : "")
                // Esc belongs to the install terminal while it runs.
                .keyboardShortcut(installing ? nil : .cancelAction)
            let enabled = model.canAdd || model.canConnect
            Button(action: primary) {
                // The label keeps its width under the spinner: no jump.
                Text(model.canAdd ? L10n.add : L10n.connect).opacity(model.phase == .connecting ? 0 : 1)
                    .overlay { if model.phase == .connecting { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(.hangar(.primary, busy: model.phase == .connecting))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!enabled)
        }
    }

    private func primary() {
        if let path = model.foundPath {
            onAdd(model.trimmedHost, path)
        } else if model.canConnect {
            Task { await model.connect() }
        }
    }
}

/// ▾ after the host field: `Host` names of the ssh config; hover fill + hand like the sheets' other icon buttons.
struct HostMenu: View {
    let hosts: [String]
    let pick: (String) -> Void

    var body: some View {
        PopoverMenuButton(icon: .chevronDown, help: L10n.hostsMenuHelp) {
            hosts.map { h in .item(PopoverMenuItem(title: h, icon: .sshHost) { pick(h) }) }
        }
    }
}
