import Foundation
import Testing
@testable import AgentStatus

private func status(_ state: AgentState, hooks: Bool = false, session: String? = nil) -> LeafStatus {
    var s = LeafStatus()
    s.state = state
    s.claudeHooks = hooks
    s.sessionId = session
    return s
}

/// Most rows are about a claude leaf.
private func fold(_ s: LeafStatus, _ signal: AgentSignal) -> LeafStatus { AgentStatus.fold(s, signal, agent: .claude) }

@Suite struct AgentStatusTests {
    @Test func foldTable() {
        let rows: [(LeafStatus, AgentSignal, AgentState)] = [
            (status(.done), .hook(.sessionStart, session: "a", notificationType: nil), .done),
            (status(.idle), .hook(.prompt, session: nil, notificationType: nil), .working),
            (status(.waiting), .hook(.tool, session: nil, notificationType: nil), .working),
            (status(.working), .hook(.notification, session: nil, notificationType: nil), .waiting),
            (status(.working), .hook(.notification, session: nil, notificationType: "permission_prompt"), .waiting),
            (status(.working), .hook(.notification, session: nil, notificationType: "elicitation_dialog"), .waiting),
            (status(.done), .hook(.notification, session: nil, notificationType: "idle_prompt"), .done),
            (status(.working), .hook(.notification, session: nil, notificationType: "auth_success"), .working),
            (status(.working), .hook(.stop, session: nil, notificationType: nil), .done),
            (status(.waiting), .hook(.stop, session: nil, notificationType: nil), .done),
            (status(.working), .hook(.stopFailure, session: nil, notificationType: nil), .limit),  // hooked with matcher rate_limit only
            (status(.working), .hook(.codexNotify, session: nil, notificationType: nil), .done),
            (status(.idle), .bell, .waiting),
            (status(.idle), .desktopNotification, .waiting),
            (status(.idle, hooks: true), .bell, .idle),
            (status(.done, hooks: true), .desktopNotification, .done),
            (status(.waiting), .focused, .idle),
            (status(.waiting, hooks: true), .focused, .waiting),
            (status(.working), .focused, .working),
            (status(.done), .focused, .done),
            (status(.working), .exited(code: 2), .failed),
            (status(.working), .exited(code: 0), .idle),
            (status(.failed), .relaunched, .idle),
        ]
        for (from, signal, expected) in rows {
            #expect(fold(from, signal).state == expected, "\(from.state) + \(signal)")
        }
    }

    @Test func hooksSetClaudeFlagExceptCodex() {
        #expect(fold(status(.idle), .hook(.stop, session: nil, notificationType: nil)).claudeHooks)
        #expect(fold(status(.idle), .hook(.notification, session: nil, notificationType: "idle_prompt")).claudeHooks)
        #expect(!fold(status(.idle), .hook(.codexNotify, session: nil, notificationType: nil)).claudeHooks)
    }

    @Test func promptStopCycle() {
        var s = LeafStatus()
        s = fold(s, .hook(.sessionStart, session: "abc", notificationType: nil))
        #expect(s.state == .idle && s.sessionId == "abc" && s.claudeHooks)
        s = fold(s, .hook(.prompt, session: nil, notificationType: nil))
        #expect(s.state == .working)
        s = fold(s, .hook(.notification, session: nil, notificationType: "permission_prompt"))
        #expect(s.state == .waiting)
        s = fold(s, .hook(.tool, session: nil, notificationType: nil))
        #expect(s.state == .working)
        s = fold(s, .hook(.stop, session: nil, notificationType: nil))
        #expect(s.state == .done)
    }

    @Test func bellFallbackOnlyWithoutClaudeHooks() {
        var s = LeafStatus()
        s = fold(s, .bell)
        #expect(s.state == .waiting)
        s = fold(s, .focused)
        #expect(s.state == .idle)
        s = fold(s, .hook(.prompt, session: nil, notificationType: nil))
        s = fold(s, .bell)
        #expect(s.state == .working)
        s = fold(s, .focused)
        #expect(s.state == .working)
    }

    @Test func exitCodes() {
        #expect(fold(status(.working), .exited(code: 1)).state == .failed)
        #expect(fold(status(.working), .exited(code: 0)).state == .idle)
        #expect(fold(status(.working), .exited(code: -1)).state == .idle)
        // A new launch: its first session id becomes the leaf's (a failed resume starts a fresh session).
        let r = fold(status(.done, hooks: true, session: "s1"), .relaunched)
        #expect(r.state == .idle && !r.claudeHooks && r.sessionId == nil)
    }

    @Test func invalidSessionIdIgnored() {
        let long = String(repeating: "a", count: 129)
        for bad in ["x; rm -rf ~", "", long, "-x", "--dangerously-skip-permissions", ".x", "_x"] {
            let s = fold(status(.idle, session: "keep"), .hook(.prompt, session: bad, notificationType: nil))
            #expect(s.sessionId == "keep", "\(bad.prefix(12))")
        }
        for good in ["0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "t.1_2-3"] {
            let s = fold(status(.idle), .hook(.prompt, session: good, notificationType: nil))
            #expect(s.sessionId == good)
        }
        #expect(validSessionId(String(repeating: "a", count: 128)) != nil)
        #expect(validSessionId(nil) == nil)
    }

    /// A nested `claude -p` in the leaf reports with its own session id: it must not touch the leaf.
    @Test func nestedSessionIgnored() {
        let leaf = status(.working, hooks: true, session: "main")
        for kind in [HookKind.sessionStart, .prompt, .tool, .notification, .stop, .stopFailure] {
            let signal = AgentSignal.hook(kind, session: "nested", notificationType: nil, source: "startup")
            #expect(fold(leaf, signal) == leaf, "\(kind)")
            #expect(!acceptsHook(leaf, kind: kind, session: "nested", source: "startup", agent: .claude), "\(kind)")
        }
        // Same id, no id, or the first id after a launch: as before.
        #expect(fold(leaf, .hook(.stop, session: "main", notificationType: nil)).state == .done)
        #expect(fold(leaf, .hook(.stop, session: nil, notificationType: nil)).state == .done)
        #expect(fold(LeafStatus(), .hook(.prompt, session: "first", notificationType: nil)).sessionId == "first")
    }

    @Test func sessionSwitchOnlyFromSessionStartClearCompactResume() {
        let leaf = status(.done, hooks: true, session: "main")
        for source in ["clear", "compact", "resume"] {
            let s = fold(leaf, .hook(.sessionStart, session: "next", notificationType: nil, source: source))
            #expect(s.sessionId == "next", "\(source)")
        }
        for source in [nil, "startup", "other"] {
            #expect(fold(leaf, .hook(.sessionStart, session: "next", notificationType: nil, source: source)) == leaf)
        }
        #expect(fold(leaf, .hook(.prompt, session: "next", notificationType: nil, source: "clear")) == leaf)
    }

    @Test func codexNotifyNotFiltered() {
        let s = AgentStatus.fold(status(.working, session: "t1"), .hook(.codexNotify, session: "t2", notificationType: nil), agent: .codex)
        #expect(s.state == .done && s.sessionId == "t2")
    }

    /// Session ids belong to the leaf's own agent: codex run in a claude tab and claude in a codex tab don't touch them.
    @Test func sessionIdsKindMatched() {
        var s = status(.working, hooks: true, session: "main")
        s = AgentStatus.fold(s, .hook(.codexNotify, session: "thread", notificationType: nil), agent: .claude)
        #expect(s.sessionId == "main")
        s = AgentStatus.fold(s, .hook(.stop, session: "main", notificationType: nil), agent: .claude)
        #expect(s.state == .done)
        let codex = AgentStatus.fold(LeafStatus(), .hook(.sessionStart, session: "c1", notificationType: nil, source: "startup"), agent: .codex)
        #expect(codex.sessionId == nil)
        // Not the leaf's agent: not filtered by its id either.
        let other = AgentStatus.fold(status(.idle, session: "t1"), .hook(.prompt, session: "c2", notificationType: nil), agent: .codex)
        #expect(other.state == .working && other.sessionId == "t1")
        #expect(AgentStatus.fold(LeafStatus(), .hook(.prompt, session: "x", notificationType: nil), agent: nil).sessionId == nil)
    }

    @Test func codexNotifyDone() {
        var s = AgentStatus.fold(LeafStatus(), .hook(.codexNotify, session: "t1", notificationType: nil), agent: .codex)
        #expect(s.state == .done && s.sessionId == "t1" && !s.claudeHooks)
        s = fold(s, .bell)
        #expect(s.state == .waiting)
    }

    @Test func taskPriority() {
        #expect(taskState([.done, .working]) == .working)
        #expect(taskState([.working, .failed]) == .failed)
        #expect(taskState([.failed, .waiting]) == .waiting)
        // waiting > limit > failed > working
        #expect(taskState([.failed, .limit, .working]) == .limit)
        #expect(taskState([.limit, .waiting]) == .waiting)
        #expect(taskState([.idle, .done]) == .done)
        #expect(taskState([]) == .idle)
    }

    @Test func boardTransitions() {
        var board = StatusBoard()
        let a = UUID()
        let prompt = AgentSignal.hook(.prompt, session: nil, notificationType: nil)
        #expect(board.apply(prompt, leaf: a, agent: .claude) == Transition(leaf: a, from: .idle, to: .working))
        #expect(board.apply(prompt, leaf: a, agent: .claude) == nil)
        #expect(board.workingCount == 1)
        // No-op signals leave the board untouched (no write for observers).
        let before = board
        #expect(board.apply(.focused, leaf: UUID(), agent: nil) == nil)
        #expect(board == before)
        _ = board.apply(.hook(.stop, session: nil, notificationType: nil), leaf: a, agent: .claude)
        #expect(board.workingCount == 0)
        board.retain([])
        #expect(board.leaves.isEmpty)
        #expect(board.status(a).state == .idle)
    }
}
