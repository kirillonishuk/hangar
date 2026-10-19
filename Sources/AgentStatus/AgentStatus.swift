import Foundation

public enum AgentState: String, Sendable, CaseIterable { case working, waiting, done, failed, idle }

/// Also the `<kind>` in `hangar event <kind>`.
public enum HookKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session-start", prompt, tool, notification, stop
    case stopFailure = "stop-failure", codexNotify = "codex-notify"
}

public enum AgentSignal: Equatable, Sendable {
    case hook(HookKind, session: String?, notificationType: String?)
    case bell
    case desktopNotification
    case exited(code: Int32)
    case relaunched
    case focused
}

public struct LeafStatus: Equatable, Sendable {
    public var state: AgentState = .idle
    public var claudeHooks = false
    public var sessionId: String?
    public init() {}
}

/// Session ids come from hook stdin (trust boundary): only a safe charset is kept.
public func validSessionId(_ s: String?) -> String? {
    guard let s, (1...128).contains(s.utf8.count),
          s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
    else { return nil }
    return s
}

/// Out-of-order events are deliberately not sequenced: Esc/late events leave the last state (#43).
public func fold(_ status: LeafStatus, _ signal: AgentSignal) -> LeafStatus {
    var s = status
    switch signal {
    case let .hook(kind, session, type):
        if kind != .codexNotify { s.claudeHooks = true }
        if let id = validSessionId(session) { s.sessionId = id }
        switch kind {
        case .sessionStart: break
        case .prompt, .tool: s.state = .working
        case .notification:
            if type == nil || type == "permission_prompt" || type == "elicitation_dialog" { s.state = .waiting }
        case .stop, .codexNotify: s.state = .done
        case .stopFailure: s.state = .failed
        }
    case .bell, .desktopNotification:
        if !s.claudeHooks { s.state = .waiting }
    case .focused:
        if s.state == .waiting && !s.claudeHooks { s.state = .idle }
    case let .exited(code):
        s.state = code > 0 ? .failed : .idle
    case .relaunched:
        s.state = .idle
        s.claudeHooks = false
    }
    return s
}

/// waiting > failed > working > done > idle
public func taskState(_ states: [AgentState]) -> AgentState {
    for p in [AgentState.waiting, .failed, .working, .done] where states.contains(p) { return p }
    return .idle
}

public struct Transition: Equatable, Sendable {
    public var leaf: UUID
    public var from: AgentState
    public var to: AgentState
}

public struct StatusBoard: Equatable, Sendable {
    public private(set) var leaves: [UUID: LeafStatus] = [:]
    public init() {}

    public func status(_ leaf: UUID) -> LeafStatus { leaves[leaf] ?? LeafStatus() }

    /// nil — the state did not change (session id / flags may still have).
    public mutating func apply(_ signal: AgentSignal, leaf: UUID) -> Transition? {
        let old = status(leaf)
        let new = fold(old, signal)
        leaves[leaf] = new
        return old.state == new.state ? nil : Transition(leaf: leaf, from: old.state, to: new.state)
    }

    public mutating func retain(_ live: Set<UUID>) {
        leaves = leaves.filter { live.contains($0.key) }
    }

    public var workingCount: Int { leaves.values.filter { $0.state == .working }.count }
}
