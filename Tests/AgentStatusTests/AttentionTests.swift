import Foundation
import Testing
@testable import AgentStatus

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func hook(_ kind: HookKind, _ type: String? = nil, _ detail: HookDetail = .init()) -> AgentSignal {
    .hook(kind, session: nil, notificationType: type, detail: detail)
}

private func run(_ signals: [AgentSignal], from start: LeafStatus = LeafStatus(), agent: SessionAgent? = .claude, at now: Date = t0) -> LeafStatus {
    signals.reduce(start) { fold($0, $1, agent: agent, now: now) }
}

private func item(_ reason: AttentionReason, since: TimeInterval, id: UUID = UUID()) -> AttentionItem {
    AttentionItem(leafId: id, taskId: UUID(), projectId: UUID(), host: nil, agent: "claude",
                  attention: Attention(reason: reason, since: t0.addingTimeInterval(since), requestKey: UUID()))
}

@Suite struct AttentionTests {
    @Test func sourcesMapToReasons() {
        let s1 = run([hook(.notification, "permission_prompt", HookDetail(text: "Claude needs your permission"))])
        #expect(s1.state == .waiting && s1.attention?.reason == .permission && s1.attention?.text == "Claude needs your permission")
        #expect(s1.attention?.since == t0)

        #expect(run([hook(.notification, "elicitation_dialog")]).attention?.reason == .question)
        #expect(run([hook(.notification)]).attention?.reason == .question)  // older claude: no type
        #expect(run([hook(.notification, "idle_prompt")]).attention == nil)

        let done = run([hook(.prompt), hook(.stop, nil, HookDetail(text: "All set"))])
        #expect(done.state == .done && done.attention?.reason == .done && done.attention?.text == "All set")
        let codex = run([hook(.codexNotify, nil, HookDetail(text: "Fixed"))], agent: .codex)
        #expect(codex.attention?.reason == .done && codex.attention?.text == "Fixed")

        for error in [nil, "rate_limit"] as [String?] {
            let s = run([hook(.prompt), hook(.stopFailure, nil, HookDetail(error: error))])
            #expect(s.state == .limit && s.attention?.reason == .limit, "\(String(describing: error))")
        }
        let failed = run([hook(.prompt), hook(.stopFailure, nil, HookDetail(error: "overloaded"))])
        #expect(failed.state == .failed && failed.attention?.reason == .failed)

        #expect(run([hook(.prompt), .exited(code: 2)]).attention?.reason == .failed)
        #expect(run([hook(.prompt), .exited(code: 0)]).attention == nil)

        let bell = run([.bell], agent: .codex)
        #expect(bell.state == .waiting && bell.attention?.reason == .question && bell.attention?.text == nil)
        let osc = run([.desktopNotification(text: "build?")], agent: .codex)
        #expect(osc.attention?.reason == .question && osc.attention?.text == "build?")
        // With claude hooks the bell is not a question: the hooks say what happens.
        #expect(run([hook(.prompt), .bell]).attention == nil)
    }

    @Test func activityClearsAttention() {
        let asking = run([hook(.notification, "permission_prompt")])
        for signal in [hook(.prompt), hook(.tool), hook(.sessionStart), hook(.subagentStart), .relaunched] {
            #expect(run([signal], from: asking).attention == nil, "\(signal)")
        }
    }

    @Test func focusClearsOnlyHooklessQuestion() {
        let hookless = run([.desktopNotification(text: "y/n?")], agent: .codex)
        let focused = run([.focused], from: hookless)
        #expect(focused.state == .idle && focused.attention == nil)

        let permission = run([hook(.notification, "permission_prompt")])
        #expect(run([.focused], from: permission).attention?.reason == .permission)
        let done = run([hook(.stop)])
        #expect(run([.focused], from: done).attention?.reason == .done)
    }

    @Test func permissionUsesPendingDetails() {
        let working = run([hook(.prompt)])
        let pending = run([hook(.permissionRequest, nil, HookDetail(tool: "Bash", command: "ls"))], from: working)
        #expect(pending.state == .working && pending.attention == nil)
        #expect(pending.pendingPermission?.tool == "Bash" && pending.pendingPermission?.at == t0)

        let asked = run([hook(.notification, "permission_prompt")], from: pending, at: t0.addingTimeInterval(2))
        #expect(asked.attention?.tool == "Bash" && asked.attention?.command == "ls")
        #expect(asked.pendingPermission == nil)
    }

    @Test func stalePendingPermissionIsNotUsed() {
        let pending = run([hook(.permissionRequest, nil, HookDetail(tool: "Bash", command: "ls"))])
        let late = run([hook(.notification, "permission_prompt")], from: pending, at: t0.addingTimeInterval(pendingPermissionTTL + 1))
        #expect(late.attention?.reason == .permission && late.attention?.tool == nil && late.attention?.command == nil)

        for signal in [hook(.prompt), hook(.tool), hook(.stop), hook(.stopFailure), hook(.sessionStart), .relaunched] {
            #expect(run([signal], from: pending).pendingPermission == nil, "\(signal)")
        }
    }

    @Test func requestKeyStableForSameRequest() throws {
        var board = StatusBoard()
        let leaf = UUID()
        let ask = hook(.notification, "permission_prompt", HookDetail(text: "Allow ls?"))
        #expect(board.apply(ask, leaf: leaf, agent: .claude, now: t0) != nil)
        let first = try #require(board.status(leaf).attention)
        #expect(first.since == t0)

        #expect(board.apply(ask, leaf: leaf, agent: .claude, now: t0.addingTimeInterval(5)) == nil)
        #expect(board.status(leaf).attention == first)

        _ = board.apply(hook(.notification, "permission_prompt", HookDetail(text: "Allow rm?")), leaf: leaf, agent: .claude, now: t0.addingTimeInterval(6))
        let other = try #require(board.status(leaf).attention)
        #expect(other.requestKey != first.requestKey && other.since == t0.addingTimeInterval(6))

        _ = board.apply(hook(.notification, nil, HookDetail(text: "Allow rm?")), leaf: leaf, agent: .claude, now: t0.addingTimeInterval(7))
        #expect(board.status(leaf).attention?.requestKey != other.requestKey)
    }

    @Test func dismissDoneOnlyForDone() {
        var board = StatusBoard()
        let done = UUID(), asking = UUID()
        _ = board.apply(hook(.stop), leaf: done, agent: .claude, now: t0)
        _ = board.apply(hook(.notification, "permission_prompt"), leaf: asking, agent: .claude, now: t0)
        let dismissed = board.dismissDone(done)
        #expect(dismissed)
        #expect(board.status(done).attention == nil && board.status(done).state == .done)
        let again = board.dismissDone(done), notDone = board.dismissDone(asking)
        #expect(!again && !notDone)
        #expect(board.status(asking).attention?.reason == .permission)
    }

    @Test func orderAndSections() {
        let oldDone = item(.done, since: 0), newDone = item(.done, since: 50)
        let limit = item(.limit, since: 1), failed = item(.failed, since: 2)
        let question = item(.question, since: 3), olderPermission = item(.permission, since: 4), permission = item(.permission, since: 5)
        let all = [oldDone, newDone, limit, failed, question, permission, olderPermission]
        #expect(sortedAttention(all).map(\.id) == [olderPermission, permission, question, failed, limit, oldDone, newDone].map(\.id))

        let dones = (0..<12).map { item(.done, since: TimeInterval(100 + $0)) }
        let sections = inboxSections(all + dones)
        #expect(sections.urgent.map(\.id) == [olderPermission, permission, question, failed, limit].map(\.id))
        // The 10 newest done items, newest first (ruling R2).
        #expect(sections.recentDone.map(\.id) == dones.reversed().prefix(10).map(\.id))

        #expect(attentionCount(all + dones) == 4)
        #expect(attentionCount([]) == 0)
    }

    @Test func nextAttentionCycles() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(nextAttention([a, b, c], after: nil) == a)
        #expect(nextAttention([a, b, c], after: a) == b)
        #expect(nextAttention([a, b, c], after: c) == a)
        #expect(nextAttention([a, b, c], after: UUID()) == a)
        #expect(nextAttention([], after: a) == nil)
    }

    @Test func bannerPolicyTable() {
        let on = BannerContext()
        for reason in AttentionReason.allCases { #expect(shouldBanner(reason, on)) }

        func with(_ change: (inout BannerContext) -> Void) -> BannerContext {
            var c = on
            change(&c)
            return c
        }
        let blocked: [BannerContext] = [
            with { $0.enabled = false }, with { $0.reasonEnabled = false }, with { $0.leafVisible = true },
            with { $0.sessionMuted = true }, with { $0.projectOff = true },
            with { $0.appActive = true; $0.notifyWhenActive = false },
        ]
        for c in blocked {
            for reason in AttentionReason.allCases { #expect(!shouldBanner(reason, c), "\(reason) \(c)") }
        }
        let active = with { $0.appActive = true }
        #expect(shouldBanner(.done, active))

        let urgentOnly = with { $0.projectUrgentOnly = true }
        #expect(AttentionReason.allCases.filter { shouldBanner($0, urgentOnly) } == [.permission, .question])
    }
}
