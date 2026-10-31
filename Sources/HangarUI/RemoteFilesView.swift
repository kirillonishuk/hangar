import AppKit
import Exec
import SwiftUI
import UniformTypeIdentifiers

/// Files of «<host> · терминал» (mockup `remote-files.html`): the path bar with «Обновить» and «Загрузить файлы», the
/// folder's list (drop files on it or on a folder row), the upload block at the bottom.
struct RemoteFilesView: View {
    let app: AppState
    private var model: RemoteFilesModel { app.remoteFiles }
    /// A drag is over the list (maybe over one of its folder rows); what lights up is `model.dropTarget`.
    @State private var listTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if model.offline, let host = model.shown?.link.host { offlineNotice(host) }
            if !model.cwdKnown, model.listing != nil, !model.offline { remark(L10n.remoteFilesUnknownFolder) }
            if model.listing?.truncated == true { remark(L10n.filesTruncated(RemoteListing.limit)) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(model.offline ? Theme.Opacity.inactive : 1)
                .background(Self.dropFill(model.dropTarget != nil && model.dropTarget == model.path))
                .overlay(alignment: .bottom) { dropHint }
                .overlay(alignment: .bottom) { conflictCard }
                .onDrop(of: [.fileURL], isTargeted: Binding(get: { listTargeted }, set: { on in
                    listTargeted = on && model.canUpload
                    if listTargeted, model.dropTarget == nil { model.dropTarget = model.path } else if !on, model.dropTarget == model.path { model.dropTarget = nil }
                })) { providers in
                    drop(providers, into: model.path)
                }
            footer
        }
    }

    private var pathBar: some View {
        let path = model.path.map(RemoteFilesModel.display) ?? ""
        return HStack(spacing: Theme.inlineGap) {
            IconView(icon: .project, size: Theme.Icon.inline)
            Text(verbatim: path)
                .font(Theme.Typography.mono.font())
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
            IconButton(icon: .refresh, help: L10n.remoteFilesRefresh) { model.reload() }
                .disabled(model.shown == nil)
            IconButton(icon: .add, help: model.offline ? (model.shown.map { L10n.hostOffline($0.link.host) } ?? "") : L10n.remoteFilesUpload) { choose() }
                .disabled(!model.canUpload)
                .opacity(model.canUpload ? 1 : Theme.Opacity.inactive)
        }
        .padding(.leading, Theme.rowPaddingH)
        .padding(.trailing, Theme.Space.s2)
        .frame(height: Theme.Height.barPane)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if let listing = model.listing {
            if listing.entries.isEmpty {
                VStack(spacing: Theme.Space.s3) {
                    Text(verbatim: L10n.remoteFilesEmpty)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(Theme.ui.text2)
                        .multilineTextAlignment(.center)
                    Button(L10n.remoteFilesUpload) { choose() }
                        .buttonStyle(.hangar())
                        .disabled(!model.canUpload)
                }
                .padding(.horizontal, Theme.Space.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows(listing, in: model.listedPath ?? RemoteFilesModel.home, depth: 0), id: \.path) { row in
                            RemoteFileRow(row: row, expanded: model.expanded.contains(row.path), targeted: model.dropTarget == row.path) {
                                model.toggle(row.path)
                            }
                            .modifier(FolderDrop(enabled: row.entry.isDir, path: row.path, model: model, listTargeted: listTargeted) {
                                drop($0, into: row.path)
                            })
                        }
                    }
                    .padding(.vertical, Theme.fileRowPaddingV)
                    // Room for the drop hint under the last row.
                    .padding(.bottom, dropHintShown ? Theme.Height.barPane + Theme.Space.s2 : 0)
                }
            }
        } else if let error = model.error {
            EmptyNote(text: Self.text(error))
        } else if model.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private struct Row {
        var entry: RemoteEntry
        var path: String
        var depth: Int
    }

    private func rows(_ listing: RemoteListing, in dir: String, depth: Int) -> [Row] {
        listing.entries.flatMap { entry -> [Row] in
            let path = dir == "/" ? "/" + entry.name : dir + "/" + entry.name
            var out = [Row(entry: entry, path: path, depth: depth)]
            if entry.isDir, model.expanded.contains(path), let sub = model.children[path] {
                out += rows(sub, in: path, depth: depth + 1)
            }
            return out
        }
    }

    private struct RemoteFileRow: View {
        let row: Row
        let expanded: Bool
        let targeted: Bool
        let toggle: () -> Void

        var body: some View {
            HoverRow(action: row.entry.isDir ? toggle : nil) { _ in
                HStack(spacing: Theme.railInset) {
                    if row.entry.isDir {
                        IconView(icon: expanded ? .chevronDown : .chevronRight, size: Theme.Icon.inline)
                    } else {
                        Color.clear.frame(width: Theme.Icon.inline, height: Theme.Icon.inline)
                    }
                    FileIconView(name: row.entry.name, isDir: row.entry.isDir, expanded: expanded)
                    Text(row.entry.name)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(targeted ? Theme.ui.text0 : Theme.ui.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Theme.rowPaddingH + CGFloat(row.depth) * Theme.treeIndent)
                .padding(.trailing, Theme.rowPaddingH)
                .padding(.vertical, Theme.fileRowPaddingV)
            }
            .background(RemoteFilesView.dropFill(targeted).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control)))
            .help(RemoteFilesModel.display(row.path))
        }
    }

    /// Drop on a folder row: into that folder (the row lights up instead of the list).
    private struct FolderDrop: ViewModifier {
        let enabled: Bool
        let path: String
        let model: RemoteFilesModel
        let listTargeted: Bool
        let perform: ([NSItemProvider]) -> Bool

        func body(content: Content) -> some View {
            if enabled {
                content.onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropTarget == path }, set: { on in
                    if on, model.canUpload { model.dropTarget = path } else if model.dropTarget == path { model.dropTarget = listTargeted ? model.path : nil }
                })) { perform($0) }
            } else {
                content
            }
        }
    }

    /// The highlight of a drop target (§2.8 roles): `accent` .15 fill and a 1 pt `accent` edge.
    static func dropFill(_ on: Bool) -> some View {
        Rectangle().fill(on ? Theme.ui.accent.opacity(Theme.Opacity.fill) : .clear)
            .overlay(Rectangle().strokeBorder(on ? Theme.ui.accent : .clear, lineWidth: 1))
    }

    private var dropHintShown: Bool { model.canUpload && model.dropTarget != nil }

    @ViewBuilder private var dropHint: some View {
        if dropHintShown, let dir = model.dropTarget {
            HStack(spacing: Theme.inlineGap) {
                IconView(icon: .add, size: Theme.Icon.inline)
                Text(verbatim: L10n.remoteFilesDropInto)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text1)
                Text(verbatim: RemoteFilesModel.display(dir))
                    .font(Theme.Typography.monoSmall.font())
                    .foregroundStyle(Theme.ui.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s2)
            .frame(height: Theme.Height.controlSmall)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.ui.bg2))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.ui.line2))
            .padding(Theme.Space.s2)
            .allowsHitTesting(false)
        }
    }

    private func offlineNotice(_ host: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s2) {
            IconView(icon: .sshHost, size: Theme.Icon.row)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: L10n.hostOffline(host))
                    .font(Theme.Typography.body.font())
                    .foregroundStyle(Theme.ui.text1)
                Text(verbatim: L10n.remoteFilesLogIn)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s3)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    private func remark(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.Typography.secondary.font())
            .foregroundStyle(Theme.ui.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.top, Theme.Space.s1)
    }

    // MARK: Upload block and conflict prompt

    @ViewBuilder private var footer: some View {
        if let u = model.upload {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s2) {
                    Text(verbatim: L10n.remoteFilesUploading(u.index, u.count))
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(Theme.ui.text1)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(u.percent) %")
                        .font(Theme.Typography.monoSmall.font())
                        .foregroundStyle(Theme.ui.text3)
                    IconButton(icon: .close, help: L10n.remoteFilesCancel) { model.cancelUploads() }
                }
                .frame(height: Theme.Height.barPane)
                LimitBar(percent: Double(u.percent), height: Theme.Limit.blockBar)
                    .padding(.trailing, Theme.Space.s1)
                Text(verbatim: u.waiting ? L10n.remoteFilesWaiting(u.name)
                     : L10n.remoteFilesProgress(u.name, Self.bytes(u.sent), Self.bytes(u.total)))
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, Theme.Space.s2)
            }
            .modifier(FooterBox())
        } else if !model.uploadErrors.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s1) {
                HStack(spacing: Theme.Space.s2) {
                    Text(verbatim: L10n.remoteFilesUploaded(model.batchDone, model.batchCount))
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(Theme.ui.text1)
                    Spacer(minLength: 0)
                    IconButton(icon: .close, help: L10n.remoteFilesDismiss) { model.dismissErrors() }
                }
                .frame(height: Theme.Height.barPane)
                ForEach(Array(model.uploadErrors.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .top, spacing: Theme.inlineGap) {
                        IconView(icon: .alert, size: Theme.Icon.row, tint: Theme.ui.failed)
                        Text(verbatim: text)
                            .font(Theme.Typography.secondary.font())
                            .foregroundStyle(Theme.ui.failedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .modifier(FooterBox())
        }
    }

    private struct FooterBox: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.leading, Theme.rowPaddingH)
                .padding(.trailing, Theme.Space.s2)
                .padding(.bottom, Theme.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        }
    }

    @ViewBuilder private var conflictCard: some View {
        if let c = model.conflict {
            ConflictCard(conflict: c) { replace, forAll in model.answer(replace: replace, forAll: forAll) }
                .padding(Theme.Space.s3)
        }
    }

    private struct ConflictCard: View {
        let conflict: RemoteFilesModel.Conflict
        let answer: (Bool?, Bool) -> Void
        @State private var forAll = false

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                (Text(verbatim: conflict.name).font(Theme.Typography.body.font(.semibold)).foregroundColor(Theme.ui.text0)
                 + Text(verbatim: " " + L10n.remoteFilesExistsIn + " ").font(Theme.Typography.body.font()).foregroundColor(Theme.ui.text1)
                 + Text(verbatim: RemoteFilesModel.display(conflict.dir)).font(Theme.Typography.mono.font()).foregroundColor(Theme.ui.text2))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s2) {
                    if conflict.more > 0 { Checkbox(L10n.remoteFilesForAll(conflict.more + 1), isOn: $forAll) }
                    Spacer(minLength: 0)
                    Button(L10n.remoteFilesSkip) { answer(false, forAll) }
                        .buttonStyle(.hangar(.secondary, .small))
                        .keyboardShortcut(.cancelAction)
                    Button(conflict.isFolder ? L10n.remoteFilesMerge : L10n.remoteFilesReplace) { answer(true, forAll) }
                        .buttonStyle(.hangar(.primary, .small))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Theme.Space.s3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.popover).fill(Theme.ui.bg2))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover).strokeBorder(Theme.ui.line2))
            .shadow(color: .black.opacity(Theme.toastShadow.opacity), radius: Theme.toastShadow.radius, y: Theme.toastShadow.y)
        }
    }

    // MARK: Actions

    private func choose() {
        guard model.canUpload else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.remoteFilesUploadButton
        let dir = model.path
        let done: (NSApplication.ModalResponse) -> Void = { [model] response in
            guard response == .OK else { return }
            model.upload(panel.urls, into: dir)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    private func drop(_ providers: [NSItemProvider], into dir: String?) -> Bool {
        listTargeted = false
        model.dropTarget = nil
        guard model.canUpload, let dir else { return false }
        let found = URLCollector()
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { found.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [model] in
            MainActor.assumeIsolated { model.upload(found.urls, into: dir) }
        }
        return true
    }

    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        func add(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func text(_ error: RemoteFileError) -> String {
        switch error {
        case .noAccess(let dir): L10n.remoteFilesNoAccess(RemoteFilesModel.display(dir))
        case .missing(let dir): L10n.remoteFilesMissing(RemoteFilesModel.display(dir))
        case .failed(let why): L10n.remoteFilesFailed(why)
        case .offline, .exists, .kindClash, .noTar, .incomplete: L10n.remoteFilesFailed("")
        }
    }
}

extension L10n {
    static var remoteFilesUpload: String { s(.remoteFilesUpload) }
    static var remoteFilesUploadButton: String { s(.remoteFilesUploadButton) }
    static var remoteFilesRefresh: String { s(.remoteFilesRefresh) }
    static var remoteFilesEmpty: String { s(.remoteFilesEmpty) }
    static var remoteFilesDropInto: String { s(.remoteFilesDropInto) }
    static func remoteFilesUploading(_ i: Int, _ n: Int) -> String { f(.remoteFilesUploading, i, n) }
    static func remoteFilesUploaded(_ i: Int, _ n: Int) -> String { f(.remoteFilesUploaded, i, n) }
    static func remoteFilesProgress(_ name: String, _ sent: String, _ total: String) -> String { f(.remoteFilesProgress, name, sent, total) }
    static func remoteFilesWaiting(_ name: String) -> String { f(.remoteFilesWaiting, name) }
    static var remoteFilesExistsIn: String { s(.remoteFilesExistsIn) }
    static func remoteFilesForAll(_ n: Int) -> String { f(.remoteFilesForAll, n) }
    static var remoteFilesSkip: String { s(.remoteFilesSkip) }
    static var remoteFilesReplace: String { s(.remoteFilesReplace) }
    static var remoteFilesMerge: String { s(.remoteFilesMerge) }
    static var remoteFilesCancel: String { s(.remoteFilesCancel) }
    static var remoteFilesDismiss: String { s(.remoteFilesDismiss) }
    static var remoteFilesLogIn: String { s(.remoteFilesLogIn) }
    static var remoteFilesUnknownFolder: String { s(.remoteFilesUnknownFolder) }
    static func remoteFilesNoAccess(_ dir: String) -> String { f(.remoteFilesNoAccess, dir) }
    static func remoteFilesMissing(_ dir: String) -> String { f(.remoteFilesMissing, dir) }
    static func remoteFilesFailed(_ why: String) -> String { f(.remoteFilesFailed, why) }
    static func uploadUnreadable(_ n: Int) -> String { f(.uploadUnreadable, n) }
    static func uploadOffline(_ name: String) -> String { f(.uploadOffline, name) }
    static func uploadNoAccess(_ name: String, _ dir: String) -> String { f(.uploadNoAccess, name, dir) }
    static func uploadKindClash(_ name: String) -> String { f(.uploadKindClash, name) }
    static func uploadNoTar(_ name: String) -> String { f(.uploadNoTar, name) }
    static func uploadIncomplete(_ name: String) -> String { f(.uploadIncomplete, name) }
    static func uploadFailed(_ name: String, _ why: String) -> String { f(.uploadFailed, name, why) }
}
