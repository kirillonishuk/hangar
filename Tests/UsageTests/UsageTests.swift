import Foundation
import Testing
import ControlServer
@testable import Usage

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private func win(_ p: Double, resets: Double? = 1_760_005_000, kind: WindowKind = .session) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: p, resetsAt: resets.map(Date.init(timeIntervalSince1970:)), updatedAt: now)
}

@Test func claudeWindowMapping() {
    let wire = [
        WireWindow(name: "five_hour", usedPercent: 86, resetsAt: 1_760_001_000),
        WireWindow(name: "seven_day", usedPercent: 41, resetsAt: 1_760_100_000),
        WireWindow(name: "seven_day_opus", usedPercent: 63, resetsAt: 1_760_100_001),
        WireWindow(name: "extra_x", usedPercent: 5, resetsAt: nil),
        WireWindow(name: "seven_day", usedPercent: nil, resetsAt: 1),
    ]
    let w = claudeWindows(wire, now: now)
    #expect(w.map(\.kind) == [.session, .weekly, .weeklyModel("opus")])
    #expect(w.map(\.usedPercent) == [86, 41, 63])
    #expect(w[0].resetsAt == Date(timeIntervalSince1970: 1_760_001_000))
}

@Test func levels() {
    #expect(level(percent: 79.9, limitReached: false) == .ok)
    #expect(level(percent: 80, limitReached: false) == .warn)
    #expect(level(percent: 94.9, limitReached: false) == .warn)
    #expect(level(percent: 95, limitReached: false) == .full)
    #expect(level(percent: 10, limitReached: true) == .full)
}

@Test func staleWindowResetsToZero() {
    var b = UsageBoard()
    _ = b.update(.claude, windows: [win(90, resets: now.timeIntervalSince1970 - 1)], plan: nil, now: now)
    #expect(b.view(.claude, now: now)?.windows[0].usedPercent == 0)
    #expect(b.level(.claude, now: now) == .ok)
}

@Test func alertsOncePerWindowPeriod() {
    var b = UsageBoard()
    func u(_ p: Double, _ r: Double = 1_760_005_000) -> [UsageAlert] {
        b.update(.claude, windows: [win(p, resets: r)], plan: nil, now: now)
    }
    func check(_ got: [UsageAlert], _ want: [UsageAlert]) { #expect(got == want) }
    check(u(79), [])
    check(u(81), [UsageAlert(agent: .claude, kind: .session, level: .warn, percent: 81)])
    check(u(85), [])
    check(u(79), [])
    check(u(81), [])
    check(u(96), [UsageAlert(agent: .claude, kind: .session, level: .full, percent: 96)])
    check(u(81, 1_760_900_000), [UsageAlert(agent: .claude, kind: .session, level: .warn, percent: 81)])
}

@Test func limitReachedMarksAndClears() {
    var b = UsageBoard()
    _ = b.update(.codex, windows: [win(50, resets: 1_760_005_000), win(60, resets: 1_760_900_000, kind: .weekly)], plan: "plus", now: now)
    let a1 = b.markLimitReached(.codex, now: now)
    #expect(a1 == [UsageAlert(agent: .codex, kind: nil, level: .full, percent: nil)])
    #expect(b.level(.codex, now: now) == .full)
    #expect(b.view(.codex, now: now)?.limitResetsAt == Date(timeIntervalSince1970: 1_760_900_000))
    let a2 = b.markLimitReached(.codex, now: now)
    #expect(a2 == [])
    _ = b.update(.codex, windows: [win(10)], plan: nil, now: now)
    #expect(b.view(.codex, now: now)?.limitReached == false)
    #expect(b.view(.codex, now: now)?.plan == "plus")

    _ = b.markLimitReached(.codex, now: now)
    let later = Date(timeIntervalSince1970: 1_760_900_001)
    #expect(b.view(.codex, now: later)?.limitReached == false)
    #expect(b.level(.codex, now: later) == .ok)
}

@Test func tickWithoutAWindowKeepsTheLastKnownOne() {
    var b = UsageBoard()
    _ = b.update(.claude, windows: [win(6), win(25, resets: 1_760_900_000, kind: .weekly),
                                    win(40, resets: 1_759_000_000, kind: .weeklyModel("opus"))], plan: nil, now: now)
    _ = b.update(.claude, windows: [win(26, resets: 1_760_900_000, kind: .weekly)], plan: nil, now: now)
    let w = b.view(.claude, now: now)?.windows ?? []
    #expect(w.map(\.kind) == [.weekly, .session])  // the passed per-model window is gone
    #expect(w.map(\.usedPercent) == [26, 6])
    // Its reset passed and still no figure: the 5-hour row stays, at 0.
    #expect(b.view(.claude, now: Date(timeIntervalSince1970: 1_760_005_001))?.windows.last?.usedPercent == 0)
}

@Test func noDataHidesAgent() {
    let b = UsageBoard()
    #expect(b.view(.codex, now: now) == nil)
    #expect(b.level(.codex, now: now) == nil)
}

@Test func limitReachedAlertsAgainAfterReset() {
    var b = UsageBoard()
    _ = b.update(.codex, windows: [win(50, resets: 1_760_005_000)], plan: nil, now: now)
    let a1 = b.markLimitReached(.codex, now: now)
    #expect(a1.count == 1)
    let later = Date(timeIntervalSince1970: 1_760_005_001)
    let a2 = b.markLimitReached(.codex, now: later)
    #expect(a2 == [UsageAlert(agent: .codex, kind: nil, level: .full, percent: nil)])
}

@Test func oneNotificationPerLimitEvent() {
    var b = UsageBoard()
    let a = b.update(.codex, windows: [win(97)], plan: nil, now: now)
    #expect(a.count == 1)
    let m = b.markLimitReached(.codex, now: now)
    #expect(m == [])
    // reverse order: mark first, then the window crosses 95
    var c = UsageBoard()
    _ = c.update(.claude, windows: [win(50)], plan: nil, now: now)
    let m2 = c.markLimitReached(.claude, now: now)
    #expect(m2.count == 1)
    let a2 = c.update(.claude, windows: [win(97)], plan: nil, now: now)
    #expect(a2 == [])
}

/// `resets_at` jitters by a second or so between statusline ticks: the same window must not alert again.
@Test func alertKeyIgnoresResetJitter() {
    var b = UsageBoard()
    func u(_ p: Double, _ r: Double) -> [UsageAlert] { b.update(.claude, windows: [win(p, resets: r)], plan: nil, now: now) }
    #expect(u(81, 1_760_005_200) == [UsageAlert(agent: .claude, kind: .session, level: .warn, percent: 81)])
    #expect(u(82, 1_760_005_201) == [])
    #expect(u(82, 1_760_005_199.4) == [])
    #expect(u(83, 1_760_005_229) == [])
}
