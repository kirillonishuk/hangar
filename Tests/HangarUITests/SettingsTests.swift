import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct SettingsTests {
    /// Unwritable: `configURL` under a regular file, so every config write fails.
    private func app(writable: Bool) throws -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-settings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        let configURL = writable ? dir.appendingPathComponent("c.toml") : blocker.appendingPathComponent("c.toml")
        return AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: HangarConfig(),
                        configURL: configURL, socketPath: "/tmp/hg-test/hangar.sock")
    }

    @Test func secondPresentKeepsDraft() throws {
        let settings = SettingsWindowController(app: try app(writable: true))
        settings.present(over: nil)
        settings.model.externalEditor = "zed"
        settings.present(over: nil)
        #expect(settings.model.externalEditor == "zed")
        settings.window?.orderOut(nil)
    }

    @Test func failedSaveOnCloseKeepsWindowOpenWithError() throws {
        let settings = SettingsWindowController(app: try app(writable: false))
        let window = try #require(settings.window)
        settings.present(over: nil)
        settings.model.externalEditor = "zed"
        #expect(!settings.windowShouldClose(window))
        #expect(settings.model.error != nil)
        #expect(settings.model.externalEditor == "zed")
        // The user has seen the error: a second close is not blocked.
        #expect(settings.windowShouldClose(window))
        window.orderOut(nil)
    }

    @Test func successfulSaveOnCloseCloses() throws {
        let app = try app(writable: true)
        let settings = SettingsWindowController(app: app)
        let window = try #require(settings.window)
        settings.present(over: nil)
        settings.model.externalEditor = "zed"
        #expect(settings.windowShouldClose(window))
        #expect(app.config.externalEditor == "zed")
        #expect(settings.model.error == nil)
        window.orderOut(nil)
    }

    /// A configured `/…/bin/hx` next to the `hx` preset: two identical «hx» labels hid which one is chosen.
    @Test func editorLabelsTellACustomPathFromAPreset() {
        let presets = ["hx", "nvim"]
        #expect(editorLabel("hx", presets: presets) == "hx")
        #expect(editorLabel("/opt/bin/zed", presets: presets) == "zed")
        #expect(editorLabel("/tmp/qa/bin/hx", presets: presets) == "/tmp/qa/bin/hx")
        #expect(editorLabel("/Users/k/bin/nvim", presets: presets, home: "/Users/k") == "~/bin/nvim")
        #expect(editorLabel("/Users/k/very/deep/folder/with/a/long/path/bin/hx", presets: presets, home: "/Users/k") == "~/…/path/bin/hx")
    }
}
