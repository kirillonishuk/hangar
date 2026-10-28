import Foundation
import Integration
import Testing
import Workspace
@testable import HangarUI

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"

/// #103: Hangar's line in projects with their own; temp folders only, never the user's real files.
@MainActor @Suite struct StatuslineSyncTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-statusline-\(UUID())")

    private func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    @Test func launchSyncAddsAndModeRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
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
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.claudeSettingsURL = URL(fileURLWithPath: claude)
        app.findAgentDirs = nil

        // Off (tests, before the launcher turns it on): nothing is read or written.
        await app.syncProjectStatuslines(host: nil)
        #expect(read(own + "/.claude/settings.local.json") == #"{"env": {"A": "1"}}"#)

        app.statuslineSync = true
        await app.syncProjectStatuslines(host: nil)
        let local = try #require(read(own + "/.claude/settings.local.json"))
        #expect(local.contains("\(cli) statusline --project --then project-line") && local.contains(#""A": "1""#))
        #expect(app.statuslineNotes.map(\.name) == ["own"])
        #expect(!FileManager.default.fileExists(atPath: plain + "/.claude"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: own + "/.claude").filter { $0.contains(".hangar-backup-") }
        #expect(backups.count == 1)
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

    @Test func noteWarnsWhenNotIgnoredAndOnFailure() async throws {
        let shared = #"{"statusLine": {"type": "command", "command": "project-line"}}"#
        var files = [".../p/.claude/settings.json": shared]
        let dir = StatuslineDir(path: ".../p", name: "p")
        func sync(ignored: Bool?, failWrite: Bool = false) async -> StatuslineNote? {
            await syncStatuslineDir(dir, host: "devbox", cli: "/home/me/.hangar/bin/hangar-remote", hangar: true,
                                    read: { files[$0] },
                                    write: { path, _, updated in
                                        if failWrite { throw IntegrationError.changedOnDisk }
                                        files[path] = updated
                                    },
                                    ignored: { _ in ignored })
        }
        #expect(await sync(ignored: false, failWrite: true)?.problem == .failed(L10n.fileChanged))
        #expect(await sync(ignored: false) == StatuslineNote(host: "devbox", path: ".../p", name: "p", problem: .notIgnored))
        #expect(files[".../p/.claude/settings.local.json"]?.contains("hangar-remote statusline --project --then project-line") == true)
        #expect(await sync(ignored: true)?.problem == nil)
        #expect(await sync(ignored: nil)?.problem == nil)
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
