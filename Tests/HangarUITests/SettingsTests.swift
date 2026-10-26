import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace
import Integration

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

    /// Red is for a failure: a missing or outdated integration is amber, an installed one calm.
    @Test func integrationStatusTones() {
        #expect(integrationStatusColor(.notInstalled) == Theme.ui.waiting)
        #expect(integrationStatusColor(.outdated) == Theme.ui.waiting)
        #expect(integrationStatusColor(.installed) == Theme.ui.text2)
        #expect(integrationStatusColor(.installedStatuslineByUser) == Theme.ui.text2)
    }
}
