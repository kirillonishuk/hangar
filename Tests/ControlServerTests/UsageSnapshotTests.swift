import Foundation
import Testing
import ControlServer

@Suite struct UsageSnapshotTests {
    let now = Date().timeIntervalSince1970.rounded()

    private func w(_ name: String, _ p: Double?, _ r: Double?) -> WireWindow { WireWindow(name: name, usedPercent: p, resetsAt: r) }

    /// #137: a later window wins, within one window (reset jitter ≤ 90 s) the higher percent; passed known windows go.
    @Test func freshestPerWindow() {
        let r = now + 3600
        // An idle chat's stale tick never lowers the known figure; a busier one raises it.
        #expect(freshestWindows([w("five_hour", 13, r)], [w("five_hour", 7, r + 30)], now: now) == [w("five_hour", 13, r)])
        #expect(freshestWindows([w("five_hour", 7, r)], [w("five_hour", 13, r - 30)], now: now) == [w("five_hour", 13, r - 30)])
        // A new window (reset hours later) wins even with a lower percent; a stale tick from the old window loses.
        #expect(freshestWindows([w("five_hour", 90, r)], [w("five_hour", 2, r + 5 * 3600)], now: now) == [w("five_hour", 2, r + 5 * 3600)])
        #expect(freshestWindows([w("five_hour", 2, r + 5 * 3600)], [w("five_hour", 90, r)], now: now) == [w("five_hour", 2, r + 5 * 3600)])
        // Union, sorted; a known window whose reset passed is dropped, the tick's own kept as it came.
        #expect(freshestWindows([w("seven_day", 40, r), w("seven_day_opus", 5, now - 1)], [w("five_hour", 1, now - 10)], now: now)
                == [w("five_hour", 1, now - 10), w("seven_day", 40, r)])
        // Unknown percent loses to a known one; no reset: compared by percent.
        #expect(freshestWindows([w("five_hour", 20, nil)], [w("five_hour", nil, r)], now: now) == [w("five_hour", 20, nil)])
        #expect(freshestWindows([], [], now: now).isEmpty)
    }

    @Test func snapshotAndReply() {
        let s = UsageSnapshot()
        let r = now + 3600
        _ = s.merge([w("five_hour", 13, r)], now: now)
        let merged = s.merge([w("five_hour", 7, r), w("seven_day", 50, r + 86_400)], now: now)
        #expect(merged == [w("five_hour", 13, r), w("seven_day", 50, r + 86_400)])
        #expect(s.merge([], now: now) == merged)
        #expect(usageReplyWindows(Data(usageReply(merged).utf8)) == merged)
        // An older app's reply, garbage or a bad window name: nothing taken.
        #expect(usageReplyWindows(Data(#"{"ok":true}"#.utf8)).isEmpty)
        #expect(usageReplyWindows(Data("nope".utf8)).isEmpty)
        #expect(usageReplyWindows(Data(#"{"ok":true,"windows":[{"name":"Bad Name","usedPercent":5}]}"#.utf8)).isEmpty)
    }
}
