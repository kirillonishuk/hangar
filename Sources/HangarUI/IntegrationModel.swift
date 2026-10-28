import Exec
import Foundation
import Integration
import Observation

/// The bundled `Contents/Helpers/hangar` of `bundle`; nil outside a built .app (DEBUG `swift run`):
/// hooks must never point into `.build`.
func hangarCLIPath(bundle: Bundle) -> String? {
    let path = bundle.bundleURL.appendingPathComponent("Contents/Helpers/hangar").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// A translocated (quarantined, not moved) or DMG-mounted app: hooks would point at a path that disappears.
func installBlocked(cli: String) -> Bool {
    cli.contains("/AppTranslocation/") || cli.hasPrefix("/Volumes/")
}

/// Shown in Settings for the user to run: Hangar never edits the agents' MCP configs itself.
func mcpAddCommands(cli: String) -> (claude: String, codex: String) {
    let q = shellQuote(cli)
    return ("claude mcp add --scope user hangar -- \(q) mcp", "codex mcp add hangar -- \(q) mcp")
}

enum IntegrationTarget { case claude, codex }

enum CodexAvailability: Equatable { case notFound, found(IntegrationState) }

/// What the consent sheet shows and `apply` writes: `updated` is exactly the bytes that go to disk.
struct IntegrationPlan: Equatable {
    var target: IntegrationTarget
    var install: Bool
    var url: URL
    /// `url` with symlinks followed: the file actually written, its backup goes next to it.
    var resolved: URL
    var original: String?
    var updated: String
    var diff: [DiffLine]  // collapsed
    /// `host:path` of a file on an ssh server (the sheet shows it instead of a local path); nil = this Mac.
    var displayPath: String?
    /// `host:path` of the file the remote write replaces (symlinks followed): its backup goes next to it.
    var backupDisplayPath: String?
}

/// Settings → integrations. Nothing is written except by `apply` of a plan the user confirmed in the sheet.
@MainActor @Observable final class IntegrationModel {
    private(set) var claudeSettings: URL
    private(set) var codexConfig: URL
    /// nil: no bundled helper, so nothing can be installed.
    let cli: String?
    @ObservationIgnored private let findCodex: () async -> String?
    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from the login shell; nil: the given paths are final (DEBUG overrides).
    @ObservationIgnored private var findDirs: (() async -> (claude: String?, codex: String?))?
    @ObservationIgnored private let home: URL
    /// nil: not looked up yet; once found it is not looked up again.
    @ObservationIgnored private var codexFound: Bool?
    @ObservationIgnored var now: () -> Date = Date.init

    var claude: IntegrationState = .notInstalled
    /// nil until the first lookup of the codex binary has finished.
    var codex: CodexAvailability?
    var error: String?
    /// Row the error belongs to when no sheet is shown.
    var errorTarget: IntegrationTarget?
    /// False until the agent dirs are resolved: no buttons before the paths are known.
    var pathsReady: Bool
    /// After a write: where the backup went.
    var message: String?
    /// The user's own status line command (kept in `--then`): what «Ваша» runs; nil = none.
    var userStatusline: String?
    /// Claude's user settings run Hangar's status line command (else Hangar's line cannot show).
    var statuslineIsHangar = false

    init(claudeSettings: URL, codexConfig: URL, cli: String?, findCodex: @escaping () async -> String?,
         findDirs: (() async -> (claude: String?, codex: String?))? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.claudeSettings = claudeSettings
        self.codexConfig = codexConfig
        self.cli = cli
        self.findCodex = findCodex
        self.findDirs = findDirs
        self.home = home
        pathsReady = findDirs == nil
    }

    /// Re-reads both files; resolves the agent dirs once; looks for codex (login shell) until it has been found once.
    func refresh() async {
        if let find = findDirs {
            findDirs = nil
            let dirs = await find()
            (claudeSettings, codexConfig) = integrationPaths(home: home, claudeConfigDir: dirs.claude, codexHome: dirs.codex)
            pathsReady = true
        }
        readStates()
        if codexFound != true { codexFound = await findCodex() != nil }
        readStates()
    }

    private func readStates() {
        let cli = cli ?? ""
        let claudeText = (try? readUserFile(claudeSettings)) ?? nil
        claude = claudeState(claudeText, cli: cli)
        userStatusline = userStatuslineCommand(claudeText)
        statuslineIsHangar = hangarStatuslineCLI(claudeText) != nil
        switch codexFound {
        case true?: codex = .found(codexState((try? readUserFile(codexConfig)) ?? nil, cli: cli))
        case false?: codex = .notFound
        case nil: break
        }
    }

    func plan(_ target: IntegrationTarget, install: Bool) -> IntegrationPlan? {
        guard let cli, pathsReady else { return nil }
        if install, installBlocked(cli: cli) { return fail(target, L10n.moveToApplications) }
        let url = target == .claude ? claudeSettings : codexConfig
        do {
            let original = try readUserFile(url)
            let updated: String
            switch (target, install) {
            case (.claude, true): updated = try claudeInstall(original, cli: cli)
            case (.codex, true): updated = try codexInstall(original, cli: cli)
            case (_, false):
                guard let original else { return nil }  // nothing to remove
                updated = target == .claude ? try claudeUninstall(original) : try codexUninstall(original)
            }
            error = nil
            return IntegrationPlan(target: target, install: install, url: url, resolved: (try? resolveLinks(url)) ?? url,
                                   original: original, updated: updated, diff: collapsed(lineDiff(original ?? "", updated)))
        } catch {
            return fail(target, Self.describe(error))
        }
    }

    private func fail(_ target: IntegrationTarget, _ text: String) -> IntegrationPlan? {
        error = text
        errorTarget = target
        return nil
    }

    /// «Применить»: nil = done (or the changed file can't be planned any more: error goes to the row);
    /// a plan = what the sheet shows next (a fresh diff after a change on disk, or the same one after a write error).
    func confirm(_ plan: IntegrationPlan) -> IntegrationPlan? {
        if apply(plan) { return nil }
        guard error == L10n.fileChanged else { return plan }
        guard let fresh = self.plan(plan.target, install: plan.install) else { return nil }
        error = L10n.fileChanged
        return fresh
    }

    /// Writes the confirmed plan; refuses if the file changed since the plan was made.
    func apply(_ plan: IntegrationPlan) -> Bool {
        do {
            let backup = try writeUserFile(plan.url, text: plan.updated, expected: plan.original, now: now())
            message = backup.map { L10n.backupCreated(tildePath($0.path)) }
            error = nil
            readStates()
            return true
        } catch {
            self.error = Self.describe(error)
            errorTarget = plan.target
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? IntegrationError {
        case .invalidJSON(let line)?: L10n.settingsInvalidJSON(line)
        case .notAnObject?: L10n.settingsUnsupported
        case .changedOnDisk?: L10n.fileChanged
        case .unsupportedNotify?, .invalidTOML?: L10n.codexConfigUnsupported
        case nil: L10n.integrationWriteFailed(error.localizedDescription)
        }
    }
}

func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
