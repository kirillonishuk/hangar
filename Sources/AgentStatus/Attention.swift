import Foundation

/// Why a leaf needs the user; case order is urgency (permission first).
public enum AttentionReason: String, CaseIterable, Sendable {
    case permission, question, failed, limit, done

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// What a hook brought besides its kind (fields already bounded at the trust boundary).
public struct HookDetail: Equatable, Sendable {
    public var tool, command, text, error: String?
    /// The pid of the agent that ran the hook; only the hooks Hangar passes to a tab's own agent (`--settings`) carry it (#119).
    public var agentPid: Int32?

    public init(tool: String? = nil, command: String? = nil, text: String? = nil, error: String? = nil, agentPid: Int32? = nil) {
        self.tool = tool
        self.command = command
        self.text = text
        self.error = error
        self.agentPid = agentPid
    }
}

public struct Attention: Equatable, Sendable {
    public var reason: AttentionReason
    public var tool, command, text: String?
    public var since: Date
    /// Identifies this exact request: notification buttons act only while it is unchanged.
    public var requestKey: UUID

    public init(reason: AttentionReason, tool: String? = nil, command: String? = nil, text: String? = nil, since: Date, requestKey: UUID) {
        self.reason = reason
        self.tool = tool
        self.command = command
        self.text = text
        self.since = since
        self.requestKey = requestKey
    }

    public func sameRequest(_ o: Attention) -> Bool {
        reason == o.reason && tool == o.tool && command == o.command && text == o.text
    }
}

/// `fold` stamps this; `StatusBoard.apply` replaces it with the old key (same request) or a fresh one.
let placeholderRequestKey = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

/// A PermissionRequest's tool and command, waiting for its permission_prompt Notification.
public struct PendingPermission: Equatable, Sendable {
    public var tool, command: String?
    public var at: Date
}

/// Older details belong to another request (the hook pair arrives within a second or two).
public let pendingPermissionTTL: TimeInterval = 30

public struct AttentionItem: Equatable, Sendable, Identifiable {
    public var leafId, taskId, projectId: UUID
    /// nil — local.
    public var host: String?
    public var agent: String
    public var attention: Attention
    public var id: UUID { leafId }

    public init(leafId: UUID, taskId: UUID, projectId: UUID, host: String?, agent: String, attention: Attention) {
        self.leafId = leafId
        self.taskId = taskId
        self.projectId = projectId
        self.host = host
        self.agent = agent
        self.attention = attention
    }
}

/// Most urgent reason first, older first within a reason.
public func sortedAttention(_ items: [AttentionItem]) -> [AttentionItem] {
    items.sorted {
        let (a, b) = ($0.attention, $1.attention)
        if a.reason != b.reason { return a.reason.rank < b.reason.rank }
        if a.since != b.since { return a.since < b.since }
        return $0.leafId.uuidString < $1.leafId.uuidString
    }
}

/// Inbox: everything but done in urgency order; then the 10 newest done, newest first.
public func inboxSections(_ items: [AttentionItem]) -> (urgent: [AttentionItem], recentDone: [AttentionItem]) {
    let sorted = sortedAttention(items)
    return (sorted.filter { $0.attention.reason != .done },
            Array(sorted.filter { $0.attention.reason == .done }.reversed().prefix(10)))
}

/// The Dock / bell number: only what blocks the agent or went wrong.
public func attentionCount(_ items: [AttentionItem]) -> Int {
    items.filter { [.permission, .question, .failed].contains($0.attention.reason) }.count
}

/// ⌥⌘A: the leaf after `current`, wrapping; the first one if `current` is not in the list.
public func nextAttention(_ ordered: [UUID], after current: UUID?) -> UUID? {
    guard let current, let i = ordered.firstIndex(of: current) else { return ordered.first }
    return ordered[(i + 1) % ordered.count]
}

public struct BannerContext: Equatable, Sendable {
    public var enabled, reasonEnabled, projectUrgentOnly, projectOff, sessionMuted, leafVisible, appActive, notifyWhenActive: Bool

    public init(enabled: Bool = true, reasonEnabled: Bool = true, projectUrgentOnly: Bool = false, projectOff: Bool = false,
                sessionMuted: Bool = false, leafVisible: Bool = false, appActive: Bool = false, notifyWhenActive: Bool = true) {
        self.enabled = enabled
        self.reasonEnabled = reasonEnabled
        self.projectUrgentOnly = projectUrgentOnly
        self.projectOff = projectOff
        self.sessionMuted = sessionMuted
        self.leafVisible = leafVisible
        self.appActive = appActive
        self.notifyWhenActive = notifyWhenActive
    }
}

public func shouldBanner(_ reason: AttentionReason, _ c: BannerContext) -> Bool {
    guard c.enabled, c.reasonEnabled, !c.leafVisible, !c.sessionMuted, !c.projectOff,
          !c.appActive || c.notifyWhenActive else { return false }
    return !c.projectUrgentOnly || reason == .permission || reason == .question
}
