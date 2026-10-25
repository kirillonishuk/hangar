import ControlServer
import Foundation
import Testing
@testable import HangarUI
import Usage
import Workspace

@MainActor @Suite struct LimitsTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_499_280)  // Tue 2026-10-20 15:28 MSK

    private func makeApp(limitNotifications: Bool = true) -> AppState {
        var config = HangarConfig()
        config.limitNotifications = limitNotifications
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-limits-\(UUID())")
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.codexRead = nil
        app.beep = {}
        return app
    }

    private func claudeUsage(_ app: AppState, _ percent: Double) {
        app.handle(.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: percent, resetsAt: nil)])))
    }

    private var moscow: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    @Test func windowTitles() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(limitWindowTitle(.session, agent: .claude) == "5 часов")
        #expect(limitWindowTitle(.session, agent: .codex) == "5 часов")
        #expect(limitWindowTitle(.weekly, agent: .claude) == "Неделя · все модели")
        #expect(limitWindowTitle(.weekly, agent: .codex) == "Неделя")
        #expect(limitWindowTitle(.weeklyModel("opus"), agent: .claude) == "Неделя · Opus")
        #expect(limitWindowTitle(.weeklyModel("opus"), agent: .codex) == "Неделя · Opus")
        L10n.language = .en
        #expect(limitWindowTitle(.session, agent: .claude) == "5-hour")
        #expect(limitWindowTitle(.session, agent: .codex) == "5-hour")
        #expect(limitWindowTitle(.weekly, agent: .claude) == "Week · all models")
        #expect(limitWindowTitle(.weekly, agent: .codex) == "Week")
        #expect(limitWindowTitle(.weeklyModel("opus"), agent: .claude) == "Week · Opus")
        #expect(limitWindowTitle(.weeklyModel("opus"), agent: .codex) == "Week · Opus")
    }

    @Test func resetLabels() {
        defer { L10n.language = .system }
        let friday = Date(timeIntervalSince1970: 1_792_736_400)  // Fri 2026-10-23 09:20 MSK
        L10n.language = .ru
        #expect(resetLabel(t0.addingTimeInterval(72 * 60), now: t0, calendar: moscow) == "сброс через 1 ч 12 мин · 16:40")
        #expect(resetLabel(friday.addingTimeInterval((2 * 24 + 4) * 3600), now: friday, calendar: moscow) == "сброс через 2 дн 4 ч · вс 13:20")
        #expect(resetLabel(t0.addingTimeInterval(12 * 60), now: t0, calendar: moscow) == "сброс через 12 мин · 15:40")
        L10n.language = .en
        #expect(resetLabel(t0.addingTimeInterval(72 * 60), now: t0, calendar: moscow) == "resets in 1 h 12 min · 16:40")
        #expect(resetLabel(friday.addingTimeInterval((2 * 24 + 4) * 3600), now: friday, calendar: moscow) == "resets in 2 d 4 h · Sun 13:20")
    }

    @Test func codexRefreshRules() async {
        let app = makeApp()
        var now = t0
        app.clock = { now }
        var reads = 0
        app.codexRead = {
            reads += 1
            try await Task.sleep(for: .milliseconds(20))
            return AgentUsage(windows: [UsageWindow(kind: .weekly, usedPercent: 30, resetsAt: nil, updatedAt: now)], plan: "plus", updatedAt: now)
        }
        claudeUsage(app, 10)
        await app.toggleLimitsPopover()?.value  // open: one read
        #expect(reads == 1)
        #expect(app.limitRows.map(\.agent) == [.claude, .codex])
        now = t0.addingTimeInterval(30)
        await app.refreshCodexUsage(afterTurn: true)  // onCodexTurn within a minute: skipped
        #expect(reads == 1)
        now = t0.addingTimeInterval(61)
        await app.refreshCodexUsage(afterTurn: true)
        #expect(reads == 2)
        async let a: Void = app.refreshCodexUsage(afterTurn: false)
        async let b: Void = app.refreshCodexUsage(afterTurn: false)
        _ = await (a, b)
        #expect(reads == 3)
        app.codexRead = nil
        #expect(app.limitRows.map(\.agent) == [.claude])
    }

    @Test func limitAlertsNotifyOnce() {
        defer { L10n.language = .system }
        L10n.language = .ru
        for enabled in [true, false] {
            let app = makeApp(limitNotifications: enabled)
            var notices: [AgentNotice] = []
            app.onUsageAlerts = { notices += limitNotices($0, app: app) }
            claudeUsage(app, 81)
            claudeUsage(app, 85)
            if enabled {
                #expect(notices.count == 1)
                #expect(notices.first?.id == "limit-claude")
                #expect(notices.first?.title == "claude: почти лимит (81%)")
                #expect(notices.first?.leaf == nil)
            } else {
                #expect(notices.isEmpty)
            }
        }
        L10n.language = .en
        #expect(limitNotice(UsageAlert(agent: .codex, kind: nil, level: .full, percent: nil)).title == "codex: limit reached")
        #expect(limitNotice(UsageAlert(agent: .claude, kind: .session, level: .warn, percent: 81)).title == "claude: almost at the limit (81%)")
    }

    @Test func popoverNeedsData() {
        let app = makeApp()
        var beeps = 0
        app.beep = { beeps += 1 }
        app.toggleLimitsPopover()
        #expect(app.limitsPopoverShown == false)
        #expect(beeps == 1)
        claudeUsage(app, 40)
        app.toggleLimitsPopover()
        #expect(app.limitsPopoverShown == true)
        app.toggleLimitsPopover()
        #expect(app.limitsPopoverShown == false)
        #expect(beeps == 1)
    }

    /// A click on the block right after the popover closed on mouse-down must not reopen it.
    @Test func clickRightAfterDismissDoesNotReopen() {
        let app = makeApp()
        var up: TimeInterval = 100
        app.uptime = { up }
        claudeUsage(app, 40)
        app.limitsClicked()
        #expect(app.limitsPopoverShown)
        app.setLimitsPopoverShown(false)  // transient close on mouse-down
        up += 0.1
        app.limitsClicked()  // the same click's mouse-up
        #expect(!app.limitsPopoverShown)
        up += 0.5
        app.limitsClicked()
        #expect(app.limitsPopoverShown)
        app.setLimitsPopoverShown(false)
        app.toggleLimitsPopover()  // ⌘⇧L is not debounced
        #expect(app.limitsPopoverShown)
    }

    @Test func codexLookupRetriedOnNextOpen() async {
        let app = makeApp()
        var lookups = 0
        app.findCodex = { lookups += 1; return nil }
        app.codexRead = app.lazyCodexRead()
        claudeUsage(app, 40)
        await app.toggleLimitsPopover()?.value
        #expect(lookups == 1)
        #expect(app.limitRows.map(\.agent) == [.claude])
        app.toggleLimitsPopover()  // close: no lookup
        #expect(lookups == 1)
        await app.toggleLimitsPopover()?.value
        #expect(lookups == 2)
    }

    @Test func passedResetShowsZeroAtUsageClock() {
        let app = makeApp()
        var now = t0
        app.clock = { now }
        app.handle(.usage(UsageMessage(agent: "claude", windows: [
            WireWindow(name: "five_hour", usedPercent: 90, resetsAt: t0.addingTimeInterval(60).timeIntervalSince1970)])))
        #expect(app.limitRows.first?.usage.windows.first?.usedPercent == 90)
        now = t0.addingTimeInterval(120)
        #expect(app.limitRows.first?.usage.windows.first?.usedPercent == 90)  // no ticking clock
        app.refreshUsageClock()  // app activation / popover open
        #expect(app.limitRows.first?.usage.windows.first?.usedPercent == 0)
    }

    @Test func levelColors() {
        #expect(Theme.Limit.color(forPercent: 79, limitReached: false) == Theme.Limit.ok)
        #expect(Theme.Limit.color(forPercent: 80, limitReached: false) == Theme.Limit.warn)
        #expect(Theme.Limit.color(forPercent: 95, limitReached: false) == Theme.Limit.full)
        #expect(Theme.Limit.color(forPercent: 10, limitReached: true) == Theme.Limit.full)
    }

    /// No window rows yet carry the «лимит» badge: the agent gets it under its name.
    @Test func reachedLimitWithoutWindowsBadgesTheHeader() {
        #expect(limitBadgeWithoutWindows(AgentUsage(windows: [], plan: nil, limitReached: true, updatedAt: t0)))
        #expect(!limitBadgeWithoutWindows(AgentUsage(windows: [], plan: nil, updatedAt: t0)))
        let w = UsageWindow(kind: .session, usedPercent: 100, resetsAt: nil, updatedAt: t0)
        #expect(!limitBadgeWithoutWindows(AgentUsage(windows: [w], plan: nil, limitReached: true, updatedAt: t0)))
    }

    /// StopFailure rate_limit before any statusline data: the sidebar says 100 %, not a red «0%».
    @Test func reachedLimitWithoutWindowsShowsFull() {
        #expect(limitBlockPercent(AgentUsage(windows: [], plan: nil, limitReached: true, updatedAt: t0)) == 100)
        #expect(limitBlockPercent(AgentUsage(windows: [], plan: nil, updatedAt: t0)) == 0)
        let w = UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: nil, updatedAt: t0)
        #expect(limitBlockPercent(AgentUsage(windows: [w], plan: nil, updatedAt: t0)) == 40)
    }
}
