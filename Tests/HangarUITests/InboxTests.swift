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

    /// The toolbar bell's number (the Dock's): permission + question + failed; done and limit don't count.
    @Test func bellCount() {
        #expect(attentionCount([item(.permission)]) == 1)
        #expect(attentionCount([item(.question), item(.failed)]) == 2)
        #expect(attentionCount([item(.done)]) == 0)
        #expect(attentionCount([item(.limit), item(.done)]) == 0)
        #expect(attentionCount([]) == 0)
    }

    /// «проект › чат · агент»; a text that only repeats the agent's name gives way to the notice's title.
    @Test func inboxRowLines() {
        let a = inboxLines(subtitle: "acme › fix", body: "Write: rm -rf build", agent: "claude", title: "Claude просит разрешение")
        #expect(a.place == "acme › fix · claude" && a.text == "Write: rm -rf build")
        #expect(inboxLines(subtitle: "acme › fix", body: "claude", agent: "claude", title: "Claude: ошибка").text == "Claude: ошибка")
        #expect(inboxLines(subtitle: "acme › fix", body: " ", agent: "", title: "T") == (place: "acme › fix", text: "T"))
    }

    @Test func reasonIconsDiffer() {
        let reasons: [AttentionReason] = [.permission, .question, .failed, .limit, .done]
        #expect(Set(reasons.map { "\(inboxIcon($0))" }).count == reasons.count)  // permission and question look different
        #expect(inboxIcon(.limit) == .limits)
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

    @Test func emptyInboxStillOpens() {
        // «Никто не ждёт» is an answer, not a beep.
        let app = makeApp()
        app.toggleInbox()
        #expect(app.inboxShown)
    }
}
