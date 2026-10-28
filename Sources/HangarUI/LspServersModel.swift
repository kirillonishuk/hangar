import Foundation
import Update

/// Settings → Editor → «Языковые серверы» (#100): where each language's server comes from, and downloads of the
/// missing ones into Hangar's folder. Computed when the page opens and after an install — no background checks.
@MainActor @Observable final class LspServersModel {
    enum Kind: Equatable {
        /// tsserver from the project's node_modules (#82): nothing to download.
        case project
        /// sourcekit-lsp comes with Xcode.
        case xcode
        case package(LspPackage)
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let language: LspLanguage?
        let kind: Kind
    }

    static let rows: [Row] = [
        Row(id: "typescript", name: "TypeScript / JavaScript", language: nil, kind: .project),
        Row(id: "python", name: "Python", language: .python, kind: .package(.pyright)),
        Row(id: "go", name: "Go", language: .go, kind: .package(.gopls)),
        Row(id: "rust", name: "Rust", language: .rust, kind: .package(.rustAnalyzer)),
        Row(id: "swift", name: "Swift", language: .swift, kind: .xcode),
    ]

    enum Source: Equatable {
        case project
        /// A folder of the login PATH or a usual install place.
        case path
        /// Hangar's folder, with the recorded version.
        case hangar(String)
        /// Xcode / Command Line Tools (`xcrun`).
        case toolchain
    }

    enum Status: Equatable {
        case checking
        case installed(Source, executable: String)
        case missing
    }

    enum Job: Equatable {
        /// Downloading (0…1) or installing (nil: no progress known).
        case running(Double?)
        case failed(String)
    }

    struct Env {
        var dir: String
        var home = NSHomeDirectory()
        /// The login shell's PATH.
        var path: () async -> String?
        /// The visible local session's root (project-local servers), if any.
        var projectRoot: () -> String?
        var toolchain: @Sendable (String) async -> String? = { _ in nil }
        var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        var feed = LspInstaller.rustFeed
        var trusted: @Sendable (URL) -> Bool = ReleaseFeed.isTrusted
        /// A server was installed or removed: the editors look again (`LspLanguages.serversChanged`).
        var changed: () -> Void = {}
    }

    let env: Env
    private(set) var statuses: [String: Status] = [:]
    var jobs: [LspPackage: Job] = [:]
    /// The user's npm / go for each package (absent: none found).
    private(set) var tools: [LspPackage: String] = [:]
    /// Installed by Hangar (the «Удалить» button).
    private(set) var owned: Set<LspPackage> = []
    private var tasks: [LspPackage: Task<Void, Never>] = [:]

    init(env: Env) { self.env = env }

    func status(_ row: Row) -> Status { statuses[row.id] ?? .checking }

    func refresh() async {
        let pathList = (await env.path() ?? "").split(separator: ":").map(String.init)
        let root = env.projectRoot()
        var next: [String: Status] = [:]
        for row in Self.rows {
            guard let language = row.language else { continue }
            // No visible session: an empty project root, so nothing project-local is taken.
            let found = await LspMap.find(language, projectRoot: root ?? "/var/empty", path: pathList, home: env.home,
                                          hangarDir: env.dir, isExecutable: env.isExecutable, toolchain: env.toolchain)
            next[row.id] = found.map { .installed(source(of: $0.executable, root: root, path: pathList), executable: $0.executable) } ?? .missing
        }
        statuses = next
        var found: [LspPackage: String] = [:]
        for package in LspPackage.allCases {
            if let name = package.tool, let tool = LspInstaller.tool(name, path: pathList, home: env.home, isExecutable: env.isExecutable) {
                found[package] = tool
            }
        }
        tools = found
        owned = Set(LspPackage.allCases.filter { LspInstaller.installed($0, in: env.dir) != nil })
    }

    /// Where a found executable comes from (the pill's «Установлен · …»).
    func source(of executable: String, root: String?, path: [String]) -> Source {
        if let root, executable.hasPrefix(root + "/") { return .project }
        if executable.hasPrefix(env.dir + "/") {
            let package = LspPackage.allCases.first { executable == env.dir + "/" + $0.relativeExecutable }
            return .hangar(package.flatMap { LspInstaller.installed($0, in: env.dir)?.version } ?? "")
        }
        let folder = (executable as NSString).deletingLastPathComponent
        let dirs = (path + LspMap.knownDirs(home: env.home)).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return dirs.contains(folder) ? .path : .toolchain
    }

    func install(_ package: LspPackage) {
        guard tasks[package] == nil else { return }
        jobs[package] = .running(nil)
        let tool = tools[package], env = env
        tasks[package] = Task {
            do {
                let path = await env.path()
                _ = try await LspInstaller.install(package, dir: env.dir, tool: tool, path: path, feed: env.feed, trusted: env.trusted) { f in
                    Task { @MainActor [weak self] in
                        if case .running = self?.jobs[package] { self?.jobs[package] = .running(f) }
                    }
                }
                jobs[package] = nil
            } catch {
                jobs[package] = Task.isCancelled ? nil : .failed(Self.message(error))
            }
            tasks[package] = nil
            env.changed()
            await refresh()
        }
    }

    func cancel(_ package: LspPackage) { tasks[package]?.cancel() }

    func remove(_ package: LspPackage) {
        do {
            try LspInstaller.remove(package, dir: env.dir)
            jobs[package] = nil
        } catch {
            jobs[package] = .failed(Self.message(error))
        }
        env.changed()
        Task { await refresh() }
    }

    static func message(_ error: Error) -> String {
        switch error {
        case LspInstallError.tool(let status, let text): text.isEmpty ? L10n.lspToolFailed(Int(status)) : text
        case LspInstallError.noAsset: L10n.lspNoAsset
        case LspInstallError.download(let text): L10n.lspDownloadFailed(text)
        case LspInstallError.notOwned: L10n.lspNotOwned
        case LspInstallError.missingExecutable: L10n.lspNoExecutable
        default: error.localizedDescription
        }
    }
}
