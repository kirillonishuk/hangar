import Foundation
import Testing
@testable import AgentStatus

private func hook(_ kind: HookKind, _ type: String? = nil, subagent: Bool = false, error: String? = nil) -> AgentSignal {
    .hook(kind, session: nil, notificationType: type, detail: HookDetail(error: error, subagent: subagent))
}

private func run(_ signals: [AgentSignal], agent: SessionAgent? = .claude) -> LeafStatus {
    signals.reduce(LeafStatus()) { fold($0, $1, agent: agent) }
}

/// No state is a dead end: every one the hooks or the terminal set has a way out on the agent's next activity (HD-166).
@Suite struct StuckStatusTests {
    @Test func failedTurnClearsOnAnyNewActivity() {
        let failed = [hook(.prompt), hook(.stopFailure, error: "server_error")]
        #expect(run(failed).state == .failed)
        for next in [hook(.prompt), hook(.tool), hook(.subagentStart)] {
            let s = run(failed + [next])
            #expect(s.state == .working && s.attention == nil, "\(next)")
        }
        #expect(run(failed + [hook(.stop)]).state == .done)
        #expect(run(failed + [hook(.notification, "permission_prompt")]).state == .waiting)
        #expect(run(failed + [hook(.sessionStart)]).attention == nil)
    }

    /// The owner's case: a subagent's API error must not turn a working chat into «ошибка».
    @Test func subagentErrorKeepsTheTurn() {
        let s = run([hook(.prompt), hook(.subagentStart), hook(.stopFailure, subagent: true, error: "server_error")])
        #expect(s.state == .working && s.inTurn && s.activeSubagents == 1 && s.attention == nil)
        // The main agent's own error still shows.
        #expect(run([hook(.prompt), hook(.stopFailure, error: "server_error")]).state == .failed)
    }

    @Test func crashClearsOnRelaunch() {
        let crashed = run([hook(.prompt), .exited(code: 1)])
        #expect(crashed.state == .failed)
        #expect(fold(crashed, .relaunched, agent: .claude).state == .idle)
    }

    @Test func everyOtherStateHasAWayOut() {
        #expect(run([hook(.prompt), hook(.notification, "permission_prompt"), hook(.tool)]).state == .working)
        #expect(run([hook(.prompt), hook(.notification), hook(.prompt)]).state == .working)
        #expect(run([hook(.prompt), hook(.stopFailure, error: "rate_limit"), hook(.prompt)]).state == .working)
        #expect(run([hook(.prompt), hook(.stop), hook(.prompt)]).state == .working)
        // Codex has no hooks but notify: its bell's «ждёт» goes once the tab is looked at.
        #expect(run([.bell, .focused], agent: .codex).state == .idle)
    }
}
