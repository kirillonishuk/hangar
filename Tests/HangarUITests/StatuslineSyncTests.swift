import Foundation
import Integration
import Testing
import TestSupport
import Workspace
@testable import HangarUI

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"

/// #105: Hangar's line in projects with their own; temp folders only, never the user's real files.
@MainActor @Suite struct StatuslineSyncTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-statusline-\(UUID())")

    private func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func ls(_ path: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() }

    /// A project with its own line, one without, the agent's settings running Hangar's line; sync on.
    private func world() throws -> (app: AppState, own: String, plain: String, claude: String) {
        let own = dir.path + "/own", plain = dir.path + "/plain"
        try write(#"{"statusLine": {"type": "command", "command": "project-line"}, "model": "opus"}"#, own + "/.claude/settings.json")
        try write(#"{"env": {"A": "1"}}"#, own + "/.claude/settings.local.json")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let claude = dir.path + "/claude/settings.json"
        try write(#"{"statusLine": {"type": "command", "command": "\#(cli) statusline --then 'echo mine'"}}"#, claude)
        var state = WorkspaceState()
        _ = state.addProject(name: "own", path: own)
        _ = state.addProject(name: "plain", path: plain)
        let app = AppState(state: state, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"),
                           socketPath: dir.path + "/state/hangar.sock")
        app.claudeSettingsURL = URL(fileURLWithPath: claude)
        app.findAgentDirs = nil
        return (app, own, plain, claude)
    }

    @Test func launchSyncAddsAndModeRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (app, own, plain, claude) = try world()

        // Off (tests, before the launcher turns it on): nothing is read or written.
        await app.syncProjectStatuslines(host: nil)
        #expect(read(own + "/.claude/settings.local.json") == #"{"env": {"A": "1"}}"#)

        app.statuslineSync = true
        await app.syncProjectStatuslines(host: nil)
        let local = try #require(read(own + "/.claude/settings.local.json"))
        #expect(local.contains("\(cli) statusline --project --then project-line") && local.contains(#""A": "1""#))
        #expect(app.statuslineNotes.map(\.name) == ["own"])
        #expect(!FileManager.default.fileExists(atPath: plain + "/.claude"))
        // The backup is in Hangar's state folder, not in the repo.
        #expect(ls(own + "/.claude") == ["settings.json", "settings.local.json"])
        let folder = backupFolder(root: dir.path + "/state/backups", for: own + "/.claude/settings.local.json")
        #expect(ls(folder).filter { $0.contains(".hangar-backup-") }.count == 1)
        await app.syncProjectStatuslines(host: nil)  // idempotent
        #expect(read(own + "/.claude/settings.local.json") == local)

        // «Ваша»: exactly Hangar's key goes.
        try app.setConfig("statusline", "user") { $0.statusline = .user }
        await app.syncProjectStatuslines(host: nil)
        #expect(read(own + "/.claude/settings.local.json").map { !$0.contains("statusLine") && $0.contains(#""A": "1""#) } == true)
        #expect(app.statuslineNotes.isEmpty)

        // The agent's own settings without Hangar's line: Hangar has no CLI to put in, nothing is written.
        try app.setConfig("statusline", "hangar") { $0.statusline = .hangar }
        try write(#"{"statusLine": {"type": "command", "command": "echo mine"}}"#, claude)
        await app.syncProjectStatuslines(host: nil)
        #expect(read(own + "/.claude/settings.local.json")?.contains("statusLine") == false)
    }

    /// Hangar → «Ваша» → Hangar → «Ваша» in a row: the queued syncs end with no override.
    @Test func fastToggleEndsWithTheLastChoice() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (app, own, _, _) = try world()
        app.statuslineSync = true
        try app.setStatuslineMode(.hangar)
        try app.setStatuslineMode(.user)
        try app.setStatuslineMode(.hangar)
        try app.setStatuslineMode(.user)
        await app.statuslineQueue?.value
        #expect(read(own + "/.claude/settings.local.json").map { !$0.contains("statusLine") && $0.contains(#""A": "1""#) } == true)
        #expect(app.statuslineNotes.isEmpty)
        try app.setStatuslineMode(.hangar)
        await app.statuslineQueue?.value
        #expect(read(own + "/.claude/settings.local.json")?.contains("--project") == true)
    }

    /// Removing a project and uninstalling take Hangar's override out; a file Hangar created goes.
    @Test func revertOnProjectRemovalAndUninstall() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (app, own, _, _) = try world()
        try FileManager.default.removeItem(atPath: own + "/.claude/settings.local.json")
        app.statuslineSync = true
        await app.syncProjectStatuslines(host: nil)
        #expect(read(own + "/.claude/settings.local.json")?.contains("--project-new") == true)

        await app.revertProjectStatuslines(host: nil)  // as before an uninstall
        #expect(!FileManager.default.fileExists(atPath: own + "/.claude/settings.local.json"))
        #expect(app.statuslineNotes.isEmpty)

        await app.syncProjectStatuslines(host: nil)
        let id = try #require(app.state.projects.first { $0.name == "own" }?.id)
        app.revertProjectStatuslines(projectId: id)
        app.perform { $0.removeProject(id: id) }
        await app.statuslineQueue?.value
        #expect(!FileManager.default.fileExists(atPath: own + "/.claude/settings.local.json"))
    }

    @Test func noteWarnsWhenNotIgnoredAndOnFailure() async throws {
        let shared = #"{"statusLine": {"type": "command", "command": "project-line"}}"#
        var files = [".../p/.claude/settings.json": shared, ".../p/.claude/settings.local.json": "{}"]
        let dir = StatuslineDir(path: ".../p", name: "p")
        func sync(ignored: Bool?, fail: IntegrationError? = nil) async -> StatuslineNote? {
            await syncStatuslineDir(dir, host: "devbox", cli: "/home/me/.hangar/bin/hangar-remote", hangar: { true },
                                    read: { files[$0] },
                                    change: { path, _, change in
                                        if let fail { throw fail }
                                        if case .write(let t) = change { files[path] = t } else { files[path] = nil }
                                    },
                                    ignored: { _ in ignored })
        }
        #expect(await sync(ignored: false, fail: .changedOnDisk)?.problem == .failed(L10n.fileChanged))
        #expect(await sync(ignored: false, fail: .readOnly)?.problem == .failed(L10n.fileReadOnly))
        #expect(await sync(ignored: false) == StatuslineNote(host: "devbox", path: ".../p", name: "p", problem: .notIgnored))
        #expect(files[".../p/.claude/settings.local.json"]?.contains("hangar-remote statusline --project --then project-line") == true)
        #expect(await sync(ignored: true)?.problem == nil)
        #expect(await sync(ignored: nil)?.problem == nil)
    }

    /// The server's write and remove scripts, run by a local sh: backups in the folder (newest five), read-only refused.
    @Test func remoteScriptsBackUpOutsideAndRefuseReadOnly() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.path + "/repo/.claude/settings.local.json", backups = dir.path + "/home/.hangar/backups/abc"
        try write("0", file)
        func sh(_ script: String, _ args: [String], _ input: String) async -> Int32 {
            await onThread {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh"] + args
                let inp = Pipe()
                p.standardInput = inp
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? inp.fileHandleForWriting.close()
                p.waitUntilExit()
                return p.terminationStatus
            }
        }
        for i in 1...7 {
            #expect(await sh(remoteFileWriteScript, [file, "1", "2026010\(i)-000000", backups], "\(i - 1)\(i)") == 0)
        }
        #expect(read(file) == "7")
        #expect(ls(dir.path + "/repo/.claude") == ["settings.local.json"])
        #expect(ls(backups).filter { $0.contains(".hangar-backup-") }.count == keptBackups)
        #expect(read(backups + "/source") == file)
        #expect(await sh(remoteFileWriteScript, [file, "1", "x", backups], "9z") == 3)
        #expect(await sh(remoteFileRemoveScript, [file, "1", "y", backups], "9") == 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file)
        #expect(await sh(remoteFileWriteScript, [file, "1", "z", backups], "7z") == 4)
        #expect(await sh(remoteFileRemoveScript, [file, "1", "z", backups], "7") == 4)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(await sh(remoteFileRemoveScript, [file, "1", "z", backups], "7") == 0)
        #expect(!FileManager.default.fileExists(atPath: file))
        // Without a folder the integration writes keep their backup next to the file, as before.
        try write("a", file)
        #expect(await sh(remoteFileWriteScript, [file, "1", "t"], "ab") == 0)
        #expect(ls(dir.path + "/repo/.claude") == ["settings.local.json", "settings.local.json.hangar-backup-t"])
    }

    @Test func rendererFollowsConfigFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try write("statusline = \"hangar\"\nlanguage = \"en\"\nstatusline_segments = [\"model\"]\n", url.path)
        let render = statuslineRenderer(configURL: url)
        #expect(render(Data(#"{"model":{"display_name":"Opus 4.7"}}"#.utf8)) == "Opus 4.7")
        try write("statusline = \"user\"\n", url.path)
        #expect(render(Data(#"{"model":{"display_name":"Opus 4.7"}}"#.utf8)) == nil)
    }

    @Test func previewSplitsBars() {
        #expect(statuslinePieces("a \u{1B}[33m━━\u{1B}[0m\u{1B}[2m───\u{1B}[0m 80%") == [
            .text("a ", .normal), .bar(cells: 2, heavy: true, .yellow), .bar(cells: 3, heavy: false, .dim), .text(" 80%", .normal),
        ])
    }
}
