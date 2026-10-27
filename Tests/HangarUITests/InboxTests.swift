import AgentStatus
import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct InboxTests {
    private func item(_ reason: AttentionReason, since: Date = Date(timeIntervalSince1970: 1000)) -> AttentionItem {
        AttentionItem(leafId: UUID(), taskId: UUID(), projectId: UUID(), host: nil, agent: "claude",
                      attention: Attention(reason: reason, since: since, requestKey: UUID()))
    }

    private func makeApp() -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-inbox-\(UUID())")
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.codexRead = nil
        app.beep = {}
        return app
    }

    @Test func bellCountAndTint() {
        #expect(inboxBell([item(.permission)]) == (count: 1, tint: BellTint.accent))
        #expect(inboxBell([item(.question), item(.failed)]) == (count: 2, tint: BellTint.accent))
        #expect(inboxBell([item(.failed)]) == (count: 1, tint: BellTint.failed))
        #expect(inboxBell([item(.done)]) == (count: 0, tint: BellTint.muted))
        #expect(inboxBell([item(.limit), item(.done)]) == (count: 0, tint: BellTint.muted))
        #expect(inboxBell([]) == (count: 0, tint: BellTint.muted))
    }

    @Test func waitingTimeText() {
        defer { L10n.language = .system }
        let now = Date(timeIntervalSince1970: 100_000)
        L10n.language = .ru
        #expect(waitingTime(since: now.addingTimeInterval(-20), now: now) == "< 1 мин")
        #expect(waitingTime(since: now.addingTimeInterval(-190), now: now) == "3 мин")
        #expect(waitingTime(since: now.addingTimeInterval(-7300), now: now) == "2 ч")
        #expect(waitingTime(since: now.addingTimeInterval(5), now: now) == "< 1 мин")  // a clock behind `since`
        L10n.language = .en
        #expect(waitingTime(since: now.addingTimeInterval(-20), now: now) == "< 1 min")
        #expect(waitingTime(since: now.addingTimeInterval(-190), now: now) == "3 min")
        #expect(waitingTime(since: now.addingTimeInterval(-7300), now: now) == "2 h")
    }

    @Test func inboxToggleIgnoresClosingClick() {
        let app = makeApp()
        var up: TimeInterval = 100
        app.uptime = { up }
        app.clock = { Date(timeIntervalSince1970: 5000) }
        app.inboxClicked()
        #expect(app.inboxShown)
        #expect(app.inboxClock == Date(timeIntervalSince1970: 5000))  // taken on open
        app.setInboxShown(false)  // transient close on mouse-down
        up += 0.1
        app.inboxClicked()  // the same click's mouse-up
        #expect(!app.inboxShown)
        up += 0.5
        app.inboxClicked()
        #expect(app.inboxShown)
        app.inboxClicked()
        #expect(!app.inboxShown)
    }

    @Test func statusCounterOpensInbox() {
        let app = makeApp()
        app.uptime = { 100 }
        let before = app.state.attentionOnly
        app.inboxClicked()  // WindowStatusBar's «ждут» button action
        #expect(app.inboxShown)
        #expect(app.state.attentionOnly == before)
    }

    @Test func emptyInboxStillOpens() {
        // «Никто не ждёт» is an answer, not a beep.
        let app = makeApp()
        app.toggleInbox()
        #expect(app.inboxShown)
    }
}
