import Foundation
import Testing
@testable import AgentStatus

@Suite struct SubagentListTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func list(_ events: [(SubagentEvent, TimeInterval)]) -> SubagentList {
        var l = SubagentList()
        for (e, s) in events { l.apply(e, now: at(s)) }
        return l
    }

    @Test func foregroundRunsAndReturns() {
        let l = list([
            (.launch(toolUseId: "t1", type: "Explore", title: "Find endpoints", prompt: "P"), 0),
            (.started(agentId: "a1", type: "Explore"), 1),
            (.stopped(agentId: "a1", result: "Found 12"), 90),
            (.returned(toolUseId: "t1", agentId: "a1", background: false), 91),
        ])
        let a = try! #require(l.items.first)
        #expect(l.items.count == 1 && a.agentId == "a1" && a.state == .done && a.result == "Found 12" && a.title == "Find endpoints")
        #expect(a.ended == at(90) && l.running == 0)
    }

    @Test func defaultsWhenTheToolCallNamesNothing() {
        let l = list([(.launch(toolUseId: "t1", type: nil, title: "", prompt: nil), 0)])
        #expect(l.items.first?.type == "general-purpose" && l.items.first?.title == "general-purpose")
    }

    @Test func aStopBeforeTheLinkIsKeptUntilTheToolReturns() {
        // No SubagentStart hook (not updated yet): the tool result links the id and settles the earlier stop.
        let l = list([
            (.launch(toolUseId: "t1", type: "Plan", title: "Plan", prompt: nil), 0),
            (.stopped(agentId: "a1", result: "Plan ready"), 30),
            (.returned(toolUseId: "t1", agentId: "a1", background: false), 31),
        ])
        #expect(l.items.first?.state == .done && l.items.first?.result == "Plan ready" && l.items.first?.ended == at(30))
    }

    @Test func parallelLaunchesPairByTypeAndTheResultCorrectsAWrongGuess() {
        var l = list([
            (.launch(toolUseId: "t1", type: "Explore", title: "A", prompt: nil), 0),
            (.launch(toolUseId: "t2", type: "Plan", title: "B", prompt: nil), 0),
            (.launch(toolUseId: "t3", type: "Explore", title: "C", prompt: nil), 0),
            (.started(agentId: "p", type: "Plan"), 1),
            // Hooks raced: C's agent reported first and took A's row.
            (.started(agentId: "c", type: "Explore"), 1),
            (.started(agentId: "a", type: "Explore"), 1),
        ])
        #expect(l.items.map(\.agentId) == ["c", "p", "a"])
        l.apply(.returned(toolUseId: "t1", agentId: "a", background: false), now: at(5))
        #expect(l.items.map(\.agentId) == ["a", "p", "c"])
        #expect(l.items.map(\.state) == [.done, .running, .running])
    }

    @Test func backgroundAgentsOutliveTheTurnAndStayAfterWakingClaude() {
        var l = list([
            (.turnStart, 0),
            (.launch(toolUseId: "t1", type: "Explore", title: "Bg", prompt: nil), 1),
            (.returned(toolUseId: "t1", agentId: "a1", background: true), 2),
            (.launch(toolUseId: "t2", type: "Explore", title: "Fg", prompt: nil), 3),
            (.turnEnd, 10),
        ])
        // A foreground agent still running at Stop never returned: interrupted.
        #expect(l.items.map(\.state) == [.running, .failed])
        l.apply(.stopped(agentId: "a1", result: "bg done"), now: at(60))
        // Claude's own turn after the background agent finished: the fresh result stays, the earlier failure goes.
        l.apply(.turnStart, now: at(61))
        #expect(l.items.map(\.title) == ["Bg"] && l.items.first?.state == .done)
        l.apply(.turnEnd, now: at(70))
        l.apply(.turnStart, now: at(100))
        #expect(l.items.isEmpty)
    }

    @Test func runningRowsSurviveATurnStart() {
        var l = list([(.launch(toolUseId: "t1", type: nil, title: "X", prompt: nil), 0)])
        #expect(l.apply(.turnStart, now: at(1)) == false)
        #expect(l.items.count == 1)
    }

    @Test func resumedAgentRunsAgain() {
        var l = list([
            (.launch(toolUseId: "t1", type: nil, title: "X", prompt: nil), 0),
            (.started(agentId: "a1", type: nil), 0),
            (.stopped(agentId: "a1", result: nil), 5),
        ])
        l.apply(.started(agentId: "a1", type: nil), now: at(9))
        #expect(l.items.first?.state == .running && l.items.first?.ended == nil)
    }

    @Test func exitFailsTheRunningAndResetClears() {
        var l = list([(.launch(toolUseId: "t1", type: nil, title: "X", prompt: nil), 0), (.exited, 3)])
        #expect(l.items.first?.state == .failed && l.items.first?.ended == at(3))
        l.apply(.reset, now: at(4))
        #expect(l.items.isEmpty)
    }

    @Test func unknownIdsAndDuplicatesChangeNothing() {
        var l = list([(.launch(toolUseId: "t1", type: nil, title: "X", prompt: nil), 0)])
        #expect(l.apply(.launch(toolUseId: "t1", type: nil, title: "Y", prompt: nil), now: at(1)) == false)
        #expect(l.apply(.returned(toolUseId: "nope", agentId: "z", background: false), now: at(1)) == false)
        // An internal agent's stop (prompt suggestions) is only remembered, never shown.
        l.apply(.stopped(agentId: "internal", result: nil), now: at(1))
        #expect(l.items.count == 1 && l.items.first?.state == .running)
    }

    @Test func capDropsTheOldestFinishedFirst() {
        var l = SubagentList()
        l.apply(.launch(toolUseId: "keep", type: nil, title: "running", prompt: nil), now: at(0))
        for i in 0..<SubagentList.cap {
            l.apply(.launch(toolUseId: "t\(i)", type: nil, title: "\(i)", prompt: nil), now: at(Double(i + 1)))
            l.apply(.returned(toolUseId: "t\(i)", agentId: nil, background: false), now: at(Double(i + 1)))
        }
        #expect(l.items.count == SubagentList.cap)
        #expect(l.items.first?.id == "keep" && l.items[1].id == "t1")
    }
}
