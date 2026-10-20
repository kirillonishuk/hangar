import Foundation
import Integration
import Testing
@testable import HangarUI

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"

private let withStatus = #"""
{
  "statusLine": {
    "type": "command",
    "command": "my-status"
  }
}

"""#

/// Temp copies only: the user's real ~/.claude and ~/.codex are never touched.
@MainActor @Suite struct IntegrationModelTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-integration-\(UUID())")
    var claudeURL: URL { dir.appendingPathComponent("claude/settings.json") }
    var codexURL: URL { dir.appendingPathComponent("codex/config.toml") }

    private func model(codex: String? = nil, cli: String? = cli) -> IntegrationModel {
        IntegrationModel(claudeSettings: claudeURL, codexConfig: codexURL, cli: cli, findCodex: { codex })
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func backups(_ url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".hangar-backup-") }
    }

    @Test func installFlowWritesBackupAndHooks() async throws {
        try write(withStatus, claudeURL)
        let m = model()
        await m.refresh()
        #expect(m.claude == .notInstalled)
        let plan = try #require(m.plan(.claude, install: true))
        #expect(plan.original == withStatus)
        #expect(plan.updated == (try claudeInstall(withStatus, cli: cli)))
        #expect(plan.diff.contains { if case .added(let l) = $0 { l.contains("statusline --then") } else { false } })
        #expect(m.apply(plan))
        #expect(try read(claudeURL) == (try claudeInstall(withStatus, cli: cli)))
        let copies = backups(claudeURL)
        #expect(copies.count == 1)
        #expect(try read(claudeURL.deletingLastPathComponent().appendingPathComponent(copies[0])) == withStatus)
        #expect(m.message?.contains(copies[0]) == true)
        #expect(m.claude == .installed)
        #expect(m.error == nil)
    }

    @Test func uninstallFlowRestores() async throws {
        try write(withStatus, claudeURL)
        let m = model()
        #expect(m.apply(try #require(m.plan(.claude, install: true))))
        let removal = try #require(m.plan(.claude, install: false))
        #expect(removal.diff.contains { if case .removed = $0 { true } else { false } })
        #expect(m.apply(removal))
        #expect(try read(claudeURL) == withStatus)
        #expect(m.claude == .notInstalled)
    }

    @Test func missingSettingsCreated() async throws {
        let m = model()
        let plan = try #require(m.plan(.claude, install: true))
        #expect(plan.original == nil)
        #expect(m.apply(plan))
        #expect(try read(claudeURL) == plan.updated)
        #expect(backups(claudeURL).isEmpty)
        #expect(m.message == nil)
        #expect(m.claude == .installed)
    }

    @Test func changedOnDiskRefused() async throws {
        try write(withStatus, claudeURL)
        let m = model()
        let plan = try #require(m.plan(.claude, install: true))
        let edited = withStatus + " "
        try write(edited, claudeURL)
        #expect(!m.apply(plan))
        #expect(m.error == L10n.fileChanged)
        #expect(try read(claudeURL) == edited)
        #expect(backups(claudeURL).isEmpty)
    }

    @Test func invalidJSONShowsError() async throws {
        try write("{,}", claudeURL)
        let m = model()
        #expect(m.plan(.claude, install: true) == nil)
        #expect(m.error == L10n.settingsInvalidJSON(1))
        #expect(try read(claudeURL) == "{,}")
    }

    @Test func unsupportedCodexNotifyShowsError() async throws {
        try write("notify.cmd = \"x\"\n", codexURL)
        let m = model(codex: "/opt/bin/codex")
        #expect(m.plan(.codex, install: true) == nil)
        #expect(m.error == L10n.codexConfigUnsupported)
    }

    @Test func codexNotFound() async throws {
        let missing = model()
        await missing.refresh()
        #expect(missing.codex == .notFound)

        // verify: проверить, когда codex будет установлен
        let found = model(codex: "/opt/bin/codex")
        await found.refresh()
        #expect(found.codex == .found(.notInstalled))
        let plan = try #require(found.plan(.codex, install: true))
        #expect(found.apply(plan))
        #expect(try read(codexURL) == (try codexInstall(nil, cli: cli)))
        #expect(found.codex == .found(.installed))
    }

    /// No bundled helper (DEBUG `swift run`): nothing can be planned, so nothing is ever written.
    @Test func noHelperNoPlan() async throws {
        let m = model(cli: nil)
        await m.refresh()
        #expect(m.plan(.claude, install: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: claudeURL.path))
    }

    @Test func cliPathPrefersHelpers() throws {
        let app = dir.appendingPathComponent("X.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let bare = try #require(Bundle(path: app.path))
        #expect(hangarCLIPath(bundle: bare) == nil)
        let helper = helpers.appendingPathComponent("hangar")
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let bundle = try #require(Bundle(path: app.path))
        #expect(hangarCLIPath(bundle: bundle) == helper.path)
    }

    @Test func translocatedAppCannotInstallButCanRemove() async throws {
        for blocked in ["/private/var/folders/ab/T/AppTranslocation/1234/d/Hangar.app/Contents/Helpers/hangar",
                        "/Volumes/Hangar/Hangar.app/Contents/Helpers/hangar"] {
            #expect(installBlocked(cli: blocked))
            let m = model(cli: blocked)
            #expect(m.plan(.claude, install: true) == nil)
            #expect(m.error == L10n.moveToApplications)
            #expect(m.errorTarget == .claude)
            #expect(!FileManager.default.fileExists(atPath: claudeURL.path))
        }
        #expect(!installBlocked(cli: cli))
        // Installed from /Applications earlier, now run from a DMG: removal still works.
        try write(withStatus, claudeURL)
        #expect(model().apply(try #require(model().plan(.claude, install: true))))
        let dmg = model(cli: "/Volumes/Hangar/Hangar.app/Contents/Helpers/hangar")
        let removal = try #require(dmg.plan(.claude, install: false))
        #expect(dmg.apply(removal))
        #expect(try read(claudeURL) == withStatus)
    }

    @Test func resolvedDirsDecidePaths() async throws {
        let custom = dir.appendingPathComponent("custom-claude")
        let m = IntegrationModel(claudeSettings: claudeURL, codexConfig: codexURL, cli: cli, findCodex: { nil },
                                 findDirs: { (custom.path, nil) }, home: dir)
        #expect(!m.pathsReady)
        await m.refresh()
        #expect(m.pathsReady)
        #expect(m.claudeSettings == custom.appendingPathComponent("settings.json"))
        #expect(m.codexConfig == dir.appendingPathComponent(".codex/config.toml"))
        let plan = try #require(m.plan(.claude, install: true))
        #expect(plan.url == custom.appendingPathComponent("settings.json"))
    }

    @Test func backupGoesNextToSymlinkTarget() async throws {
        let real = dir.appendingPathComponent("dotfiles/settings.json")
        try write(withStatus, real)
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeURL, withDestinationURL: real)
        let plan = try #require(model().plan(.claude, install: true))
        #expect(plan.resolved.resolvingSymlinksInPath() == real.resolvingSymlinksInPath())
        #expect(plan.url == claudeURL)
    }

    /// Apply refused (file changed) and the new contents can't be planned: no sheet, the error goes to the row.
    @Test func changedToInvalidClosesSheet() async throws {
        try write(withStatus, claudeURL)
        let m = model()
        let plan = try #require(m.plan(.claude, install: true))
        try write("{,}", claudeURL)
        #expect(m.confirm(plan) == nil)
        #expect(m.error == L10n.settingsInvalidJSON(1))
        #expect(m.errorTarget == .claude)
        #expect(try read(claudeURL) == "{,}")
    }

    @Test func changedOnDiskGivesFreshPlan() async throws {
        try write(withStatus, claudeURL)
        let m = model()
        let plan = try #require(m.plan(.claude, install: true))
        try write(withStatus + " ", claudeURL)
        let fresh = try #require(m.confirm(plan))
        #expect(fresh.original == withStatus + " ")
        #expect(m.error == L10n.fileChanged)
        #expect(m.confirm(fresh) == nil)
        #expect(m.error == nil)
        #expect(m.claude == .installed)
    }
}
