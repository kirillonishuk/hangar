import AppKit
import Observation
import Update

/// In-app updates (decision #86): the GitHub release feed on launch and at most hourly on activation (no timers);
/// «Обновить» downloads and checks the DMG, then quits — `applicationWillTerminate` starts the swap helper.
@MainActor @Observable public final class UpdateModel {
    enum Phase: Equatable {
        case idle, checking, upToDate
        case checkFailed(String)
        /// 0…1, nil while the size is unknown.
        case downloading(Double?)
        case preparing
        /// Checked and mounted: the swap runs when Hangar quits.
        case ready
        /// No write access to the bundle's folder: the DMG is open in Finder.
        case manual
        /// Another copy of this bundle is running: swapping it under that copy is refused.
        case otherInstance
        case failed(String)
    }

    struct Staged: Equatable {
        var app: URL, mount: URL, dir: URL
    }

    enum Prepared: Equatable {
        case staged(Staged)
        /// The DMG was opened in Finder (no write access to the bundle's folder).
        case manual
    }

    private(set) var phase: Phase = .idle
    private(set) var record = UpdateRecord()
    /// The helper's error of the last install (shown once: the file is removed when read).
    private(set) var installError: String?
    /// CFBundleShortVersionString; nil in a bare `swift run` binary.
    let current: String?
    /// nil = checks are off: DEBUG without `HANGAR_UPDATE_FEED`, or no version to compare.
    let feed: URL?
    let bundle: URL
    @ObservationIgnored let stateDir: URL
    @ObservationIgnored var enabled: () -> Bool = { true }
    /// Opens the update sheet (set by the window controller).
    @ObservationIgnored var onShow: (() -> Void)?
    /// Ends the update sheet (set while it is shown): the quit confirmation must not queue behind it.
    @ObservationIgnored var closeSheet: (() -> Void)?
    @ObservationIgnored lazy var quit: () -> Void = { [weak self] in
        self?.closeSheet?()
        // After the button's action unwinds; the usual quit path (confirmation when agents work, state saved).
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var fetch: (URL) async throws -> Data
    /// Download, checksum, mount and app checks (tests replace it).
    @ObservationIgnored lazy var prepare: (UpdateOffer, @escaping @Sendable (Double) -> Void) async throws -> Prepared = {
        [bundle, trusted] offer, progress in
        try await Self.prepare(offer, bundle: bundle, bundleId: Bundle.main.bundleIdentifier ?? "app.hangar.Hangar",
                               trusted: trusted, progress: progress)
    }
    @ObservationIgnored var otherInstanceRunning: () -> Bool = {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
    }
    /// Feed, asset and redirect URLs allowed (GitHub over https; anything for a DEBUG test feed).
    @ObservationIgnored let trusted: @Sendable (URL) -> Bool
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private(set) var staged: Staged?

    init(stateDir: URL, current: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
         feed: URL? = UpdateModel.defaultFeed, bundle: URL = Bundle.main.bundleURL) {
        self.stateDir = stateDir
        self.current = current
        self.feed = current == nil ? nil : feed
        self.bundle = bundle
        // Only a DEBUG test feed (HANGAR_UPDATE_FEED, file:// or a local server) may point anywhere.
        let anyHost = feed != nil && feed != ReleaseFeed.github
        let trusted: @Sendable (URL) -> Bool = { anyHost || ReleaseFeed.isTrusted($0) }
        self.trusted = trusted
        let agent = "Hangar/\(current ?? "dev")"
        fetch = { try await Updater.fetch($0, userAgent: agent, trusted: trusted) }
    }

    nonisolated static var defaultFeed: URL? {
        #if DEBUG
        // Verification runs never reach GitHub nor install over a real app: only an explicit test feed.
        return ProcessInfo.processInfo.environment["HANGAR_UPDATE_FEED"].flatMap(URL.init(string:))
        #else
        return ReleaseFeed.github
        #endif
    }

    private var recordURL: URL { stateDir.appendingPathComponent("update.json") }
    var errorURL: URL { stateDir.appendingPathComponent("update-error.txt") }

    /// Newer than the running version (a stored offer of the version now running is gone).
    /// The stored one is checked again like a parsed one (strict version, trusted URLs).
    var offer: UpdateOffer? {
        guard let offer = record.offer, let current, ReleaseFeed.releaseVersion(offer.version) == offer.version,
              trusted(offer.dmg), trusted(offer.checksum), ReleaseFeed.isNewer(offer.version, than: current) else { return nil }
        return offer
    }

    /// Downloading, checking or staged: no check may replace the offer being installed.
    var installing: Bool {
        if staged != nil { return true }
        switch phase {
        case .downloading, .preparing, .ready: return true
        default: return false
        }
    }

    /// The status-bar pill: an offer that wasn't skipped, while checks are on.
    var pill: UpdateOffer? {
        guard feed != nil, enabled(), let offer, offer.version != record.skipped else { return nil }
        return offer
    }

    /// Settings → «Версия»: the sheet's «Обновить» without going through the pill (a skipped version too).
    enum SettingsButton: Equatable { case install(String), busy, restart }

    var settingsButton: SettingsButton? {
        guard feed != nil else { return nil }
        switch phase {
        case .downloading, .preparing: return .busy
        case .ready: return .restart
        default: return staged != nil ? .restart : offer.map { .install($0.version) }
        }
    }

    /// Launch: the remembered state and the last install's error, then a check whatever the last one's time
    /// (a relaunch right after a check, e.g. after an update, still sees a release published since).
    public func start() {
        record = UpdateRecord.load(from: recordURL)
        if let text = try? String(contentsOf: errorURL, encoding: .utf8) {
            installError = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: errorURL)
        }
        checkIfDue(force: true)
    }

    /// App activation (and «Проверять обновления» turned on): a check when on and ≥ 1 h since the last one.
    func checkIfDue(force: Bool = false) {
        guard feed != nil, enabled(), work == nil, !installing, force || record.checkDue(now: now()) else { return }
        check(manual: false)
    }

    /// «Проверить сейчас»: ignores the hour and un-skips the version it finds.
    func checkNow() {
        guard feed != nil, work == nil, !installing else { return }
        check(manual: true)
    }

    private func check(manual: Bool) {
        guard let feed, let current else { return }
        phase = .checking
        work = Task {
            defer { work = nil }
            do {
                let found = try ReleaseFeed.parse(try await fetch(feed), trusted: trusted)
                record.lastCheck = now()
                record.offer = found.flatMap { ReleaseFeed.isNewer($0.version, than: current) ? $0 : nil }
                if manual, record.offer?.version == record.skipped { record.skipped = nil }
                save()
                phase = record.offer == nil ? .upToDate : .idle
            } catch {
                // Offline or rate-limited: the next try is an hour away too, not on every activation.
                record.lastCheck = now()
                save()
                phase = .checkFailed(describe(error))
            }
        }
    }

    func skip() {
        guard let offer else { return }
        record.skipped = offer.version
        save()
    }

    /// «Позже» / closing the sheet: a download in progress stops (a prepared install stays for the next quit).
    func later() {
        guard phase != .ready else { return }
        work?.cancel()
    }

    /// «Обновить»: download, verify the checksum, mount, verify the app, then quit (the swap runs after we exit).
    /// Staged already (the quit was cancelled): only quits again.
    func install() {
        if staged != nil { phase = .ready; quit(); return }
        guard let offer, work == nil, !installing else { return }
        guard !otherInstanceRunning() else { phase = .otherInstance; return }
        installError = nil
        phase = .downloading(nil)
        work = Task {
            defer { work = nil }
            do {
                let prepared = try await prepare(offer) { p in Task { @MainActor [weak self] in self?.progress(p) } }
                switch prepared {
                case .manual: phase = .manual
                case .staged(let s):
                    guard !Task.isCancelled else { Self.discard(s); phase = .idle; return }
                    staged = s
                    phase = .ready
                    quit()
                }
            } catch {
                // «Позже» cancels: the download's own error is not a failure to report.
                phase = Task.isCancelled ? .idle : .failed(describe(error))
            }
        }
    }

    /// The real pipeline: a fresh temp dir with fixed names, everything removed again on failure.
    nonisolated static func prepare(_ offer: UpdateOffer, bundle: URL, bundleId: String, trusted: @escaping @Sendable (URL) -> Bool,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        guard let version = ReleaseFeed.releaseVersion(offer.version) else { throw UpdateError.wrongVersion(offer.version) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-update-\(version)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dmg = dir.appendingPathComponent("Hangar.dmg")
            let sum = dir.appendingPathComponent("Hangar.dmg.sha256")
            try await Updater.download(offer.checksum, to: sum, trusted: trusted) { _ in }
            try await Updater.download(offer.dmg, to: dmg, trusted: trusted, progress: progress)
            try Task.checkCancellation()
            try Updater.verify(dmg, checksumFile: sum)
            guard Updater.canReplace(bundle) else {
                await MainActor.run { _ = NSWorkspace.shared.open(dmg) }
                return .manual
            }
            let mount = try Updater.mount(dmg)
            do {
                let app = try Updater.findApp(in: mount)
                try Updater.verifyBundle(app, bundleId: bundleId, version: version)
                try Updater.verifySignature(app)
                return .staged(Staged(app: app, mount: mount, dir: dir))
            } catch {
                Updater.detach(mount)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    nonisolated private static func discard(_ s: Staged) {
        Task.detached {
            Updater.detach(s.mount)
            try? FileManager.default.removeItem(at: s.dir)
        }
    }

    private func progress(_ p: Double) {
        if case .downloading = phase { phase = .downloading(p) }
    }

    /// `applicationWillTerminate` (state already saved): the helper waits for our exit and swaps the bundle.
    public func launchPendingInstall() {
        guard let staged else { return }
        #if DEBUG
        // `open` would start the new copy without the isolated HANGAR_* environment.
        let exe = Bundle.main.executableURL?.path.replacingOccurrences(of: bundle.path + "/", with: "") ?? "Contents/MacOS/Hangar"
        let relaunch = Updater.Relaunch.exec(exe)
        #else
        let relaunch = Updater.Relaunch.open
        #endif
        do {
            try Updater.launchHelper(in: staged.dir, arguments: Updater.scriptArguments(
                pid: getpid(), source: staged.app, target: bundle, mount: staged.mount, errorFile: errorURL, relaunch: relaunch))
        } catch {
            uiLog.error("update helper: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        do { try record.save(to: recordURL) } catch { uiLog.error("update.json: \(error.localizedDescription, privacy: .public)") }
    }

    private func describe(_ error: Error) -> String {
        switch error as? UpdateError {
        case .http(let code)?: "HTTP \(code)"
        case .network(let text)?: text
        case .badChecksumFile?, .checksumMismatch?: L10n.updateChecksumMismatch
        case .mount(let text)?: "hdiutil: \(text)"
        case .noApp?: L10n.updateWrongApp("—")
        case .wrongBundle(let id)?: L10n.updateWrongApp(id)
        case .wrongVersion(let v)?: L10n.updateWrongApp(v)
        case .helper(let text)?: text
        case .untrusted(let url)?: L10n.updateUntrusted(url)
        case .signature?: L10n.updateBadSignature
        case nil: error.localizedDescription
        }
    }
}

extension L10n {
    static func updateAvailable(_ v: String) -> String { f(.updateAvailable, v) }
    static func updateTo(_ v: String) -> String { f(.updateTo, v) }
    static var updateAvailableHelp: String { s(.updateAvailableHelp) }
    static func updateSheetTitle(_ v: String) -> String { f(.updateSheetTitle, v) }
    static func updateCurrent(_ v: String) -> String { f(.updateCurrent, v) }
    static var updateNoNotes: String { s(.updateNoNotes) }
    static var updateInstall: String { s(.updateInstall) }
    static var updateRestart: String { s(.updateRestart) }
    static var updateLater: String { s(.updateLater) }
    static var updateSkip: String { s(.updateSkip) }
    static func updateDownloading(_ percent: Int) -> String { f(.updateDownloading, percent) }
    static var updateDownloadingPlain: String { s(.updateDownloadingPlain) }
    static var updatePreparing: String { s(.updatePreparing) }
    static var updateReady: String { s(.updateReady) }
    static var updateQuitHint: String { s(.updateQuitHint) }
    static func updateManual(_ folder: String) -> String { f(.updateManual, folder) }
    static func updateFailed(_ why: String) -> String { f(.updateFailed, why) }
    static func updateInstallFailed(_ why: String) -> String { f(.updateInstallFailed, why) }
    static var updateChecksumMismatch: String { s(.updateChecksumMismatch) }
    static func updateWrongApp(_ found: String) -> String { f(.updateWrongApp, found) }
    static var updateOpenPage: String { s(.updateOpenPage) }
    static var checkUpdatesTitle: String { s(.checkUpdatesTitle) }
    static var versionTitle: String { s(.versionTitle) }
    static var checkNow: String { s(.checkNow) }
    static var updateChecking: String { s(.updateChecking) }
    static var updateUpToDate: String { s(.updateUpToDate) }
    static func updateCheckFailed(_ why: String) -> String { f(.updateCheckFailed, why) }
    static var updateDevBuild: String { s(.updateDevBuild) }
    static var updateOtherInstance: String { s(.updateOtherInstance) }
    static func updateUntrusted(_ url: String) -> String { f(.updateUntrusted, url) }
    static var updateBadSignature: String { s(.updateBadSignature) }
}
