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

    @Test func noteLine() {
        let id = UUID()
        let note = SubSessionNote(task: id, name: "Re\"lease", status: .done, message: "line one\n\n  line two  ", link: "hangar://task/x")
        #expect(note.line == "[Hangar] sub-session \"Re'lease\" finished (done): line one line two — hangar://task/x")
        let long = SubSessionNote(task: id, name: "R", status: .error, message: String(repeating: "a", count: 4000), link: "L")
        #expect(long.line.hasSuffix("a … [truncated; full output: tabs_read] — L"))
        #expect(long.line.count < SubSessionNote.maxMessage + 80)
        #expect(compactResult("short", max: 10) == ("short", false))
        #expect(compactResult(nil, max: 10) == (nil, false))
        #expect(SubSessionNote(task: id, name: "R", status: .needsInput, message: nil, link: "L").line
                == "[Hangar] sub-session \"R\" is waiting for input (needs-input) — L")
    }

    /// The child's text is typed into the parent's terminal: nothing in it may act as a key or an escape sequence there.
    @Test func noteLineCarriesNoControls() {
        let hostile = "ok\u{1B}[201~rm -rf ~\r\u{03}\u{15}\u{04}\u{7F}\u{9B}31m\u{9D}0;x\u{07}\u{85}tail\tend\u{2028}last"
        let line = SubSessionNote(task: UUID(), name: "a\u{1B}]0;t\u{07}b\tc", status: .done, message: hostile, link: "L").line
        #expect(!line.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(!line.contains { $0.isNewline })
        #expect(line == "[Hangar] sub-session \"a]0;tb c\" finished (done): ok[201~rm -rf ~ 31m0;x tail end last — L")
    }

    @Test func parentInput() {
        let idle = ParentInput(running: true, state: .done, screenBusy: false, draft: false, lastKey: nil)
        #expect(idle.canDeliver(now: t0))
        for blocked in [ParentInput(running: false, state: .idle, screenBusy: false, draft: false, lastKey: nil),
                        ParentInput(running: true, state: .working, screenBusy: false, draft: false, lastKey: nil),
                        ParentInput(running: true, state: .waiting, screenBusy: false, draft: false, lastKey: nil),
                        ParentInput(running: true, state: .idle, screenBusy: true, draft: false, lastKey: nil),
                        ParentInput(running: true, state: .idle, screenBusy: false, draft: true, lastKey: nil),
                        ParentInput(running: true, state: .idle, screenBusy: false, draft: false, lastKey: t0 - 2)] {
            #expect(!blocked.canDeliver(now: t0))
        }
        #expect(ParentInput(running: true, state: .idle, screenBusy: false, draft: false, lastKey: t0 - 6).canDeliver(now: t0))
    }

    @Test func drafts() {
        #expect(draftAfterKey(false, keyCode: 0, control: false, command: false, printable: true))  // "a"
        #expect(!draftAfterKey(true, keyCode: 36, control: false, command: false, printable: false))  // Return
        #expect(!draftAfterKey(true, keyCode: 8, control: true, command: false, printable: true))  // ⌃C
        #expect(draftAfterKey(true, keyCode: 123, control: false, command: false, printable: false))  // ← keeps it
        #expect(!draftAfterKey(false, keyCode: 123, control: false, command: false, printable: false))
        #expect(draftAfterKey(false, keyCode: 9, control: false, command: true, printable: true))  // ⌘V
        #expect(!draftAfterKey(false, keyCode: 17, control: false, command: true, printable: true))  // ⌘T
    }
}
