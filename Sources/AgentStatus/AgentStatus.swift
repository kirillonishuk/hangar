import Foundation

/// `limit`: the agent stopped on its usage limit (StopFailure rate_limit), not an error.
public enum AgentState: String, Sendable, CaseIterable { case working, waiting, done, failed, idle, limit }

/// Also the `<kind>` in `hangar event <kind>`.
public enum HookKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session-start", prompt, tool, notification, stop
    case stopFailure = "stop-failure", codexNotify = "codex-notify"
    /// PermissionRequest: Claude Code is about to ask for a permission (carries the tool and its command).
    case permissionRequest = "permission-request"
    /// PreToolUse of the Task/Agent tool / SubagentStop.
    case subagentStart = "subagent-start", subagentStop = "subagent-stop"
}

public enum AgentSignal: Equatable, Sendable {
    /// `source`: SessionStart's `source` (startup / resume / clear / compact).
    case hook(HookKind, session: String?, notificationType: String?, source: String? = nil, detail: HookDetail = .init())
    case bell
    /// OSC 9/777 from the terminal; `text` is its body.
    case desktopNotification(text: String? = nil)
    case exited(code: Int32)
    case relaunched
    case focused
}

public struct LeafStatus: Equatable, Sendable {
    public var state: AgentState = .idle
    public var claudeHooks = false
    public var sessionId: String?
    /// The tab's own agent since this launch: the first pid of a hook Hangar passed it (#119); nil — none seen yet.
    public var agentPid: Int32?
    /// Subagents (Task/Agent tool) running now; never below 0, reset whenever the turn starts or ends.
    public var activeSubagents = 0
    /// Why the leaf needs the user now; nil — it doesn't.
    public var attention: Attention?
    public var pendingPermission: PendingPermission?
    public init() {}
}

/// Session ids come from hook stdin (trust boundary): `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
/// The first character is alphanumeric so `--resume <id>` can never read the id as a flag.
public func validSessionId(_ s: String?) -> String? {
    func alnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    guard let s, (1...128).contains(s.utf8.count), let first = s.utf8.first, alnum(first),
          s.utf8.allSatisfy({ alnum($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
    else { return nil }
    return s
}

/// The agent whose session ids a leaf keeps (claude / codex leaf); nil — no session ids (shell, editor).
public enum SessionAgent: Sendable { case claude, codex }

/// Session ids are kept per leaf agent: a codex hook in a claude leaf (or vice versa) neither sets nor is filtered by it.
func ownsSessionId(_ kind: HookKind, agent: SessionAgent?) -> Bool {
    agent == (kind == .codexNotify ? .codex : .claude)
}

/// The hook ran in the tab's own agent: it carries the pid Hangar's `--settings` hooks pass, and it is the launch's first
/// such pid or that same one (#119). Nested agents (`claude -p` from a tool, a teammate) never pass both. A SessionStart
/// marked `--tab-agent` moves the pid: under `CLAUDE_CODE_SHELL_PREFIX` every hook runs under another wrapper process,
/// and a frozen id would make the installed hooks' events after /clear look nested.
public func fromTabAgent(_ status: LeafStatus, kind: HookKind, detail: HookDetail) -> Bool {
    guard let agentPid = detail.agentPid else { return false }
    return status.agentPid == nil || status.agentPid == agentPid || detail.tabAgent && kind == .sessionStart
}

/// The tab's own agent's `--settings` hooks only track its conversation (/resume, /clear, compact, fork, a lost SessionStart);
/// the status still comes from the installed hooks, so the two never count one event twice.
/// Other events: another session id than the leaf's (`known`: the one it was launched with) is a nested agent's. Without
/// any pid this launch (an older `hangar-remote`) SessionStart of a switch still moves the status, never the stored id.
/// Events without an id, of another agent than the leaf's, and codex-notify are always accepted.
public func acceptsHook(_ status: LeafStatus, kind: HookKind, session: String?, source: String?, detail: HookDetail = .init(),
                        agent: SessionAgent?, known: String? = nil) -> Bool {
    guard kind != .codexNotify, ownsSessionId(kind, agent: agent) else { return true }
    if fromTabAgent(status, kind: kind, detail: detail) { return true }
    guard let id = validSessionId(session), let current = status.sessionId ?? known, id != current else { return true }
    return status.agentPid == nil && kind == .sessionStart && ["clear", "compact", "resume", "fork"].contains(source)
}

/// Out-of-order events are deliberately not sequenced: Esc/late events leave the last state (#43).
/// Attention gets `placeholderRequestKey`; `StatusBoard.apply` assigns the real key.
public func fold(_ status: LeafStatus, _ signal: AgentSignal, agent: SessionAgent?, now: Date = Date()) -> LeafStatus {
    var s = status
    func attend(_ reason: AttentionReason, tool: String? = nil, command: String? = nil, text: String? = nil) {
        s.attention = Attention(reason: reason, tool: tool, command: command, text: text, since: now, requestKey: placeholderRequestKey)
    }
    switch signal {
    case let .hook(kind, session, type, source, detail):
        guard acceptsHook(status, kind: kind, session: session, source: source, detail: detail, agent: agent) else { return status }
        if kind != .codexNotify, ownsSessionId(kind, agent: agent), fromTabAgent(status, kind: kind, detail: detail) {
            s.agentPid = detail.agentPid
            if let id = validSessionId(session) { s.sessionId = id }
            return s
        }
        if kind != .codexNotify { s.claudeHooks = true }
        // Once the tab's own agent has reported itself, only it moves the id.
        if ownsSessionId(kind, agent: agent), let id = validSessionId(session), status.agentPid == nil { s.sessionId = id }
        // A missed SubagentStop must not leave a count for good: every turn boundary starts from zero.
        if [.sessionStart, .prompt, .stop, .stopFailure].contains(kind) { s.activeSubagents = 0 }
        if [.sessionStart, .prompt, .tool, .stop, .stopFailure].contains(kind) { s.pendingPermission = nil }
        switch kind {
        case .sessionStart: s.attention = nil
        case .prompt, .tool:
            s.state = .working
            s.attention = nil
        case .subagentStart:
            s.state = .working
            s.attention = nil
            s.activeSubagents = min(s.activeSubagents + 1, 99)
        case .subagentStop: s.activeSubagents = max(s.activeSubagents - 1, 0)
        case .permissionRequest: s.pendingPermission = PendingPermission(tool: detail.tool, command: detail.command, at: now)
        case .notification:
            if type == "permission_prompt" {
                s.state = .waiting
                let p = s.pendingPermission.flatMap { now.timeIntervalSince($0.at) <= pendingPermissionTTL ? $0 : nil }
                // A repeated prompt comes after the pending details were used: keep them so it stays the same request.
                let same = p == nil && status.attention?.reason == .permission && status.attention?.text == detail.text
                attend(.permission, tool: same ? status.attention?.tool : p?.tool,
                       command: same ? status.attention?.command : p?.command, text: detail.text)
                s.pendingPermission = nil
            } else if type == nil || type == "elicitation_dialog" {
                s.state = .waiting
                attend(.question, text: detail.text)
            }
        case .stop, .codexNotify:
            s.state = .done
            attend(.done, text: detail.text)
        case .stopFailure:
            if detail.error == nil || detail.error == "rate_limit" {
                s.state = .limit
                attend(.limit, text: detail.text)
            } else {
                s.state = .failed
                attend(.failed, text: detail.text ?? detail.error)
            }
        }
    case .bell:
        if !s.claudeHooks {
            s.state = .waiting
            attend(.question)
        }
    case let .desktopNotification(text):
        if !s.claudeHooks {
            s.state = .waiting
            attend(.question, text: text)
        }
    case .focused:
        if s.state == .waiting && !s.claudeHooks {
            s.state = .idle
            s.attention = nil
        }
    case let .exited(code):
        if code > 0 {
            s.state = .failed
            // Only an agent's exit is a failure to report; a shell's `npm test` or Ctrl-C keeps just the dot.
            if agent != nil { attend(.failed) } else { s.attention = nil }
        } else {
            s.state = .idle
            s.attention = nil
        }
        s.activeSubagents = 0
        s.pendingPermission = nil
    case .relaunched:
        s.state = .idle
        s.claudeHooks = false
        s.sessionId = nil
        s.agentPid = nil
        s.activeSubagents = 0
        s.attention = nil
        s.pendingPermission = nil
    }
    return s
}

/// waiting > limit > failed > working > done > idle
public func taskState(_ states: [AgentState]) -> AgentState {
    for p in [AgentState.waiting, .limit, .failed, .working, .done] where states.contains(p) { return p }
    return .idle
}

public struct Transition: Equatable, Sendable {
    public var leaf: UUID
    public var from: AgentState
    public var to: AgentState

    public init(leaf: UUID, from: AgentState, to: AgentState) {
        self.leaf = leaf
        self.from = from
        self.to = to
    }
}

public struct StatusBoard: Equatable, Sendable {
    public private(set) var leaves: [UUID: LeafStatus] = [:]
    public init() {}

    public func status(_ leaf: UUID) -> LeafStatus { leaves[leaf] ?? LeafStatus() }

    /// What a leaf's status line shows: «работает · 2 агента».
    public func statusSummary(_ leaf: UUID) -> (state: AgentState, subagents: Int) {
        let s = status(leaf)
        return (s.state, s.activeSubagents)
    }

    /// nil — the state did not change (session id / flags may still have).
    /// A repeated request keeps its `since` and `requestKey`; a new one gets a fresh key.
    public mutating func apply(_ signal: AgentSignal, leaf: UUID, agent: SessionAgent?, now: Date = Date()) -> Transition? {
        let old = status(leaf)
        var new = fold(old, signal, agent: agent, now: now)
        if var a = new.attention, a != old.attention {
            if let o = old.attention, a.sameRequest(o) {
                a.since = o.since
                a.requestKey = o.requestKey
            } else {
                a.requestKey = UUID()
            }
            new.attention = a
        }
        if new != old { leaves[leaf] = new }
        return old.state == new.state ? nil : Transition(leaf: leaf, from: old.state, to: new.state)
    }

    /// «Убрать» in the inbox: drops a done record only; the tab keeps its done dot.
    public mutating func dismissDone(_ leaf: UUID) -> Bool {
        guard leaves[leaf]?.attention?.reason == .done else { return false }
        leaves[leaf]?.attention = nil
        return true
    }

    /// «Разрешить» / «Ответить» typed the answer: that request's record goes (the dot stays until the agent moves on).
    public mutating func clearAnswered(_ leaf: UUID, requestKey: UUID) -> Bool {
        guard leaves[leaf]?.attention?.requestKey == requestKey else { return false }
        leaves[leaf]?.attention = nil
        return true
    }

    public mutating func retain(_ live: Set<UUID>) {
        leaves = leaves.filter { live.contains($0.key) }
    }

    public var workingCount: Int { leaves.values.filter { $0.state == .working }.count }
}
