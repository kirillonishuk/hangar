import Foundation
import Testing
@testable import AgentStatus

private func hook(_ kind: HookKind, source: String? = nil) -> AgentSignal {
    .hook(kind, session: nil, notificationType: nil, source: source)
}

private func run(_ signals: [AgentSignal], from start: LeafStatus = LeafStatus()) -> LeafStatus {
    signals.reduce(start) { fold($0, $1, agent: .claude) }
}

@Suite struct SubagentTests {
    @Test func startsAndStopsAreCounted() {
        let s = run([hook(.prompt), hook(.subagentStart), hook(.subagentStart)])
        #expect(s.activeSubagents == 2)
        #expect(s.state == .working)
        let one = fold(s, hook(.subagentStop), agent: .claude)
        #expect(one.activeSubagents == 1)
        #expect(one.state == .working)
    }

    @Test func subagentStartMarksWorking() {
        var waiting = LeafStatus()
        waiting.state = .waiting
        #expect(fold(waiting, hook(.subagentStart), agent: .claude).state == .working)
    }

    @Test func waitingKeepsTheCount() {
        let s = run([hook(.prompt), hook(.subagentStart), .hook(.notification, session: nil, notificationType: "permission_prompt")])
        #expect(s.state == .waiting)
        #expect(s.activeSubagents == 1)
    }

    @Test func clampsAtZero() {
        let s = run([hook(.prompt), hook(.subagentStop), hook(.subagentStop)])
        #expect(s.activeSubagents == 0)
        #expect(s.state == .working)
    }

    @Test func resetsOnStopPromptSessionStartAndExit() {
        let busy = run([hook(.prompt), hook(.subagentStart), hook(.subagentStart)])
        for signal in [hook(.stop), hook(.stopFailure), hook(.prompt), hook(.sessionStart, source: "startup"),
                       AgentSignal.exited(code: 0), .relaunched] {
            #expect(fold(busy, signal, agent: .claude).activeSubagents == 0, "\(signal)")
        }
    }

    @Test func boardSummary() {
        var board = StatusBoard()
        let leaf = UUID()
        _ = board.apply(hook(.prompt), leaf: leaf, agent: .claude)
        let t = board.apply(hook(.subagentStart), leaf: leaf, agent: .claude)
        #expect(t == nil)  // the state did not change, only the count
        #expect(board.statusSummary(leaf) == (state: .working, subagents: 1))
        #expect(board.statusSummary(UUID()) == (state: .idle, subagents: 0))
    }
}
