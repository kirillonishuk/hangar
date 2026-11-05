import Foundation
import Testing
@testable import HangarUI
import Usage
import Workspace

@MainActor @Suite struct LimitsRefreshTests {
    @Test func onlyCodexHasRefresh() {
        #expect(LimitsRefresh.canRefresh(.codex))
        #expect(!LimitsRefresh.canRefresh(.claude))
    }

    @Test func refreshStateTracksRead() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-limits-\(UUID())")
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        struct Boom: Error {}
        app.codexRead = { throw Boom() }
        #expect(app.codexRefresh == .idle)
        await app.refreshCodexUsage(afterTurn: false)
        #expect(app.codexRefresh == .failed)
        app.codexRead = { AgentUsage(windows: [], plan: nil, updatedAt: Date()) }
        await app.refreshCodexUsage(afterTurn: false)
        #expect(app.codexRefresh == .idle)
    }
}
