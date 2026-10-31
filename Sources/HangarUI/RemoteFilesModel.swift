import Exec
import Foundation
import Observation

/// The inspector's Files of «<host> · терминал» (spec 2026-10-31-remote-files-design, #124): the folder the focused
/// leaf's shell reported last (OSC 7), listed through that leaf's ssh master; uploads go there one at a time.
/// Loads only while shown; a prompt (new folder or the same) reloads after a short debounce. No timers, no polling.
@MainActor @Observable final class RemoteFilesModel {
    /// The leaf whose folder is shown (the focused host-terminal leaf of the selected chat, inspector on screen).
    struct Shown: Equatable {
        var leaf: UUID
        var link: RemoteShellLink
    }

    struct Conflict: Equatable {
        var name: String
        var dir: String
        var isFolder: Bool
        /// More taken names wait in this batch («Для всех»).
        var more: Int
    }

    struct UploadStatus: Equatable {
        var index: Int, count: Int
        var name: String
        var sent: Int64, total: Int64
        var waiting: Bool
        var percent: Int { total > 0 ? Int(min(100, sent * 100 / total)) : 0 }
    }

    /// The root shown when the shell never reported a folder: the server's home (commands start there).
    static let home = "."

    private(set) var shown: Shown?
    /// Last folder per host-terminal leaf, in memory only.
    private(set) var cwds: [UUID: String] = [:]
    private(set) var listing: RemoteListing?
    /// The folder `listing` belongs to.
    private(set) var listedPath: String?
    private(set) var loading = false
    private(set) var error: RemoteFileError?
    /// The master is down: the last listing stays, dimmed.
    private(set) var offline = false
    private(set) var expanded: Set<String> = []
    private(set) var children: [String: RemoteListing] = [:]
    /// The folder a drag hovers (the list's root or a folder row).
    var dropTarget: String?
    private(set) var upload: UploadStatus?
    var conflict: Conflict?
    /// Messages of the last batch's failures; the line stays until dismissed.
    private(set) var uploadErrors: [String] = []
    private(set) var batchDone = 0
    private(set) var batchCount = 0

    /// The folder shown: the leaf's last reported one, or the home when none came.
    var path: String? { shown.map { cwds[$0.leaf] ?? Self.home } }
    var cwdKnown: Bool { shown.map { cwds[$0.leaf] != nil } ?? false }

    @ObservationIgnored private var links: [UUID: RemoteShellLink] = [:]
    /// The leaf the inspector asked for, launched or not yet.
    @ObservationIgnored private var wanted: UUID?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadLeaf: UUID?
    @ObservationIgnored private var queued: [(leaf: UUID, urls: [URL], dir: String)] = []
    @ObservationIgnored private var conflictAnswer: CheckedContinuation<(replace: Bool, forAll: Bool)?, Never>?
    @ObservationIgnored var debounce: Duration = .milliseconds(300)
    @ObservationIgnored var lister: @Sendable (RemoteShellLink, String) async throws -> RemoteListing = { try await listRemoteFolder($0, path: $1) }
    @ObservationIgnored var uploader: @Sendable (RemoteShellLink, UploadSource, String, Bool, @escaping @Sendable (Int64) -> Void) async throws -> Void = {
        try await uploadToRemote($0, source: $1, dir: $2, replace: $3, progress: $4)
    }
    @ObservationIgnored var stopMaster: (RemoteShellLink) -> Void = stopRemoteMaster
    @ObservationIgnored var removeLeftover: @Sendable (RemoteShellLink, String, String) async -> Void = { await removeUploadLeftover($0, dir: $1, name: $2) }
    @ObservationIgnored var isUp: (RemoteShellLink) -> Bool = { $0.isUp }

    /// A host-terminal leaf was launched with this master (the inspector may already be waiting for it).
    func register(_ leaf: UUID, link: RemoteShellLink) {
        links[leaf] = link
        if wanted == leaf, shown?.leaf != leaf { follow(leaf) }
    }
    func link(of leaf: UUID) -> RemoteShellLink? { links[leaf] }

    /// A relaunch without a panel (no usable master): the leaf's old link and folder go.
    func unregister(_ leaf: UUID) {
        guard links[leaf] != nil else { return }
        links[leaf] = nil
        cwds[leaf] = nil
        if shown?.leaf == leaf { shown = nil; reset() }
    }

    /// The inspector shows this leaf now (nil: something else or nothing — loads stop).
    func follow(_ leaf: UUID?) {
        wanted = leaf
        let next = leaf.flatMap { l in links[l].map { Shown(leaf: l, link: $0) } }
        guard next != shown else { return }
        let samePath = next.map { cwds[$0.leaf] ?? Self.home } == listedPath && next?.link == shown?.link
        // Another leaf (or none): the last batch's failures were about that one's folder.
        if next?.leaf != shown?.leaf, uploadTask == nil { uploadErrors = [] }
        shown = next
        loadTask?.cancel()
        debounceTask?.cancel()
        dropTarget = nil
        guard next != nil else { return }
        if !samePath { reset() }
        reload()
    }

    /// OSC 7 of a leaf: kept when valid; the shown leaf reloads (every prompt — a command may have changed the files).
    func pwd(_ leaf: UUID, _ raw: String) {
        guard links[leaf] != nil, let path = validRemoteCwd(raw) else { return }
        let changed = cwds[leaf] != path
        cwds[leaf] = path
        guard shown?.leaf == leaf else { return }
        if changed { reset() }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// The leaf's title changed while nothing is listed (logged in, shell without the folder hook): try once.
    func titleChanged(_ leaf: UUID) {
        guard shown?.leaf == leaf, offline || listing == nil, let shown, isUp(shown.link) else { return }
        reload()
    }

    /// Leaves still alive: the rest forget their folder, stop their upload and end their master.
    func retain(_ live: Set<UUID>) {
        for (leaf, link) in links where !live.contains(leaf) {
            links[leaf] = nil
            cwds[leaf] = nil
            queued.removeAll { $0.leaf == leaf }
            if uploadLeaf == leaf { cancelCurrentUpload() }  // other leaves' batches stay queued
            if shown?.leaf == leaf { follow(nil) }
            stopMaster(link)
        }
    }

    private func reset() {
        listing = nil
        listedPath = nil
        error = nil
        expanded = []
        children = [:]
    }

    /// Lists the shown folder (and its open subfolders) again.
    func reload() {
        guard let shown, let path else { return }
        loadTask?.cancel()
        guard isUp(shown.link) else {
            offline = true
            loading = false
            return
        }
        loading = listing == nil || listedPath != path
        let lister = self.lister, open = expanded
        loadTask = Task { [weak self] in
            do {
                let root = try await lister(shown.link, path)
                var subs: [String: RemoteListing] = [:]
                for dir in open { subs[dir] = try? await lister(shown.link, dir) }
                guard !Task.isCancelled, let self, self.shown == shown, self.path == path else { return }
                self.listing = root
                self.listedPath = path
                self.children = subs
                self.expanded = Set(subs.keys)
                self.error = nil
                self.offline = false
                self.loading = false
            } catch {
                guard !Task.isCancelled, let self, self.shown == shown else { return }
                self.loading = false
                if error as? RemoteFileError == .offline {
                    self.offline = true
                } else {
                    self.offline = false
                    self.listing = nil
                    self.listedPath = path
                    self.error = error as? RemoteFileError ?? .failed(String(describing: error))
                }
            }
        }
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
            children[dir] = nil
            return
        }
        guard let shown else { return }
        expanded.insert(dir)
        let lister = self.lister
        Task { [weak self] in
            let sub = try? await lister(shown.link, dir)
            guard let self, self.shown == shown, self.expanded.contains(dir) else { return }
            if let sub { self.children[dir] = sub } else { self.expanded.remove(dir) }
        }
    }

    // MARK: Upload

    var canUpload: Bool { shown != nil && !offline && listing != nil }

    /// Files and folders from Finder into `dir` (nil: the shown folder): one at a time; taken names are asked about.
    func upload(_ urls: [URL], into dir: String? = nil) {
        guard let shown, let dir = dir ?? path, !urls.isEmpty else { return }
        start(urls, into: dir, leaf: shown.leaf, link: shown.link)
    }

    /// One batch of `leaf`'s master; a drop during an upload is the next batch (its own conflict answers), kept for its
    /// leaf even when the inspector moves on.
    private func start(_ urls: [URL], into dir: String, leaf: UUID, link: RemoteShellLink) {
        if uploadTask != nil {
            queued.append((leaf, urls, dir))
            return
        }
        uploadErrors = []
        uploadLeaf = leaf
        batchCount = urls.count
        batchDone = 0
        let lister = self.lister, uploader = self.uploader
        uploadTask = Task { [weak self] in
            // Off the main actor: a folder's files are counted for the progress (node_modules has many).
            let checked = await Task.detached { urls.map { url in (url, UploadSource(url)) } }.value
            guard let self else { return }
            let sources = checked.compactMap(\.1)
            for (url, source) in checked where source == nil {
                let name = url.resolvingSymlinksInPath().lastPathComponent
                self.uploadErrors.append(name.utf8.count > uploadNameLimit ? L10n.uploadNameTooLong(name) : L10n.uploadUnreadable(name))
            }
            self.batchCount = sources.count
            await self.runBatch(sources, into: dir, link: link, leaf: leaf, lister: lister, uploader: uploader)
        }
    }

    private func runBatch(_ sources: [UploadSource], into dir: String, link: RemoteShellLink, leaf: UUID,
                          lister: @Sendable (RemoteShellLink, String) async throws -> RemoteListing,
                          uploader: @Sendable (RemoteShellLink, UploadSource, String, Bool, @escaping @Sendable (Int64) -> Void) async throws -> Void) async {
        let taken = Set(((try? await lister(link, dir))?.entries ?? []).map(\.name))
        var forAll: Bool?
        batch: for (i, source) in sources.enumerated() {
            guard !Task.isCancelled else { break }
            var ask = taken.contains(source.name)
            while true {
                var replace = false
                if ask {
                    if let all = forAll {
                        replace = all
                    } else {
                        upload = UploadStatus(index: i + 1, count: sources.count, name: source.name, sent: 0, total: source.bytes, waiting: true)
                        let more = sources[(i + 1)...].filter { taken.contains($0.name) }.count
                        // Esc (or a cancel) stops the whole batch.
                        guard let answer = await self.ask(Conflict(name: source.name, dir: dir, isFolder: source.isFolder, more: more))
                        else { break batch }
                        replace = answer.replace
                        if answer.forAll { forAll = answer.replace }
                    }
                    if !replace { break }
                }
                upload = UploadStatus(index: i + 1, count: sources.count, name: source.name, sent: 0, total: source.bytes, waiting: false)
                do {
                    let total = source.bytes, name = source.name
                    try await uploader(link, source, dir, replace) { sent in
                        Task { @MainActor [weak self] in self?.progress(name: name, sent: min(sent, total)) }
                    }
                    batchDone += 1
                } catch RemoteFileError.exists(_) where !ask {
                    ask = true  // appeared meanwhile: asked like any taken name
                    continue
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        // A new task: this one is cancelled, and the leftover must go even so.
                        let remove = removeLeftover, name = source.name
                        await Task { await remove(link, dir, name) }.value
                    } else {
                        uploadErrors.append(Self.message(error, name: source.name))
                    }
                }
                break
            }
        }
        upload = nil
        uploadTask = nil
        uploadLeaf = nil
        if shown?.leaf == leaf { reload() }
        // The next batch whose leaf is still open.
        queued.removeAll { links[$0.leaf] == nil }
        if !queued.isEmpty, let link = links[queued[0].leaf] {
            let next = queued.removeFirst()
            start(next.urls, into: next.dir, leaf: next.leaf, link: link)
        }
    }

    /// Progress of the running upload; redrawn only when the shown percent changes.
    private func progress(name: String, sent: Int64) {
        guard var u = upload, u.name == name, !u.waiting else { return }
        let before = u.percent
        u.sent = sent
        if u.percent != before { upload = u }
    }

    private func ask(_ c: Conflict) async -> (replace: Bool, forAll: Bool)? {
        conflict = c
        return await withCheckedContinuation { conflictAnswer = $0 }
    }

    /// The conflict prompt's answer; nil (Esc) stops the batch.
    func answer(replace: Bool?, forAll: Bool) {
        let c = conflictAnswer
        conflictAnswer = nil
        conflict = nil
        c?.resume(returning: replace.map { ($0, forAll) })
    }

    func cancelUploads() {
        queued = []
        cancelCurrentUpload()
    }

    private func cancelCurrentUpload() {
        uploadTask?.cancel()
        if conflictAnswer != nil { answer(replace: nil, forAll: false) }
    }

    func dismissErrors() { uploadErrors = [] }

    static func message(_ error: Error, name: String) -> String {
        switch error as? RemoteFileError {
        case .offline?: L10n.uploadOffline(name)
        case .noAccess(let dir)?: L10n.uploadNoAccess(name, display(dir))
        case .kindClash?: L10n.uploadKindClash(name)
        case .noTar?: L10n.uploadNoTar(name)
        case .incomplete?: L10n.uploadIncomplete(name)
        case .missing(let dir)?: L10n.uploadNoAccess(name, display(dir))
        case .exists?: L10n.uploadFailed(name, "")
        case .failed(let why)?: L10n.uploadFailed(name, why)
        case nil: L10n.uploadFailed(name, String(describing: error))
        }
    }

    /// How a server folder reads in the UI: the unknown root is `~`, a subfolder of it `~/x`.
    static func display(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
