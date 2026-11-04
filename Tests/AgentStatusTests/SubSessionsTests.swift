import Foundation
import Testing
@testable import AgentStatus

@Suite struct SubSessionsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func stopped(background: Int?, at: Date, message: String? = "ok") -> SubSessionWatch {
        var w = SubSessionWatch(created: t0)
        w.hook(state: .working, background: nil, message: nil, isStop: false, now: t0)
        w.hook(state: .done, background: background, message: message, isStop: true, now: at)
        return w
    }

    @Test func freshSubSessionIsRunningUntilItsFirstTurn() {
        let w = SubSessionWatch(created: t0)
        #expect(subSessionStatus(w, state: .idle, detached: nil, screenBusy: false, now: t0 + 600) == .running)
    }

    @Test func doneOnlyAfterTheQuietPeriod() {
        let w = stopped(background: 0, at: t0 + 10)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 12) == .running)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 15) == .done)
        #expect(w.lastMessage == "ok")
    }

    @Test func busyScreenOrToolShellsKeepItRunning() {
        let w = stopped(background: nil, at: t0)
        #expect(subSessionStatus(w, state: .done, detached: nil, screenBusy: true, now: t0 + 60) == .running)
        #expect(subSessionStatus(w, state: .done, detached: 1, screenBusy: false, now: t0 + 60) == .running)
        #expect(subSessionStatus(w, state: .done, detached: nil, screenBusy: false, now: t0 + 60) == .done)
    }

    /// The owner's release example: Stop while a background shell waits; the wake-up turn's Stop has none left.
    @Test func backgroundTasksHoldDoneUntilTheFinalStop() {
        var w = stopped(background: 1, at: t0 + 10, message: "release started, waiting")
        #expect(subSessionStatus(w, state: .done, detached: 1, screenBusy: false, now: t0 + 300) == .running)
        // Unknown pid (no probe): still waits for Claude's own next Stop.
        #expect(subSessionStatus(w, state: .done, detached: nil, screenBusy: false, now: t0 + 300) == .running)
        w.hook(state: .working, background: nil, message: nil, isStop: false, now: t0 + 301)
        #expect(subSessionStatus(w, state: .working, detached: 0, screenBusy: true, now: t0 + 302) == .running)
        w.hook(state: .done, background: 0, message: "released 1.2.3", isStop: true, now: t0 + 320)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 322) == .running)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 326) == .done)
        #expect(w.lastMessage == "released 1.2.3")
    }

    /// Claude never woke up after its shells ended: done after `backgroundQuiet` with no hooks.
    @Test func backgroundWithoutWakeUpEndsByTheProbe() {
        let w = stopped(background: 2, at: t0)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 29) == .running)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: false, now: t0 + 31) == .done)
        #expect(subSessionStatus(w, state: .done, detached: 0, screenBusy: true, now: t0 + 31) == .running)
    }

    @Test func waitingAndErrorsAreImmediate() {
        let w = stopped(background: 1, at: t0)
        #expect(subSessionStatus(w, state: .waiting, detached: 3, screenBusy: true, now: t0) == .needsInput)
        #expect(subSessionStatus(w, state: .failed, detached: 0, screenBusy: false, now: t0) == .error)
        #expect(subSessionStatus(w, state: .limit, detached: 0, screenBusy: false, now: t0) == .error)
    }

    @Test func aNewTurnStartsANewEpisode() {
        var w = stopped(background: 0, at: t0)
        w.reported = .done
        w.hook(state: .working, background: nil, message: nil, isStop: false, now: t0 + 100)
        #expect(w.reported == nil)
        #expect(w.background == nil)
    }

    @Test func waitEnds() {
        #expect(waitIsOver([.done, .done]))
        #expect(!waitIsOver([.done, .running]))
        #expect(waitIsOver([.running, .needsInput]))
        #expect(waitIsOver([.running, .error]))
        #expect(waitIsOver([]))
    }

    @Test func backgroundTasksPayload() {
        #expect(runningBackgroundTasks(nil) == nil)
        #expect(runningBackgroundTasks("x") == nil)
        #expect(runningBackgroundTasks([]) == 0)
        let list: [Any] = [["id": "a", "type": "shell", "status": "running"], ["id": "b", "status": "completed"],
                           ["id": "c", "status": "failed"], ["id": "d"], 7]
        #expect(runningBackgroundTasks(list) == 3)
        #expect(runningBackgroundTasks(Array(repeating: ["status": "running"], count: 500)) == 99)
    }

    @Test func compactResultMarksTheCut() {
        #expect(compactResult("short", max: 10) == ("short", false))
        #expect(compactResult(nil, max: 10) == (nil, false))
        let long = compactResult(String(repeating: "a", count: 4000), max: 1500)
        #expect(long.truncated && long.text?.count == 1500 && long.text?.hasSuffix("a … [truncated; full output: tabs_read]") == true)
    }
}
