import Foundation

/// One Claude subagent (Agent/Task tool) of a tab's agent, as its hooks tell it (spec agent-subagents §3).
public struct Subagent: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case running, done, failed }

    /// The Agent tool call's `tool_use_id`; a row is born from its PreToolUse.
    public var id: String
    /// SubagentStart's / the tool result's `agent_id`; nil until one of them links it.
    public var agentId: String?
    public var type: String
    /// The tool's `description` («Implement Task 2.2»).
    public var title: String
    /// The orchestrator's `prompt` (bounded at the trust boundary).
    public var prompt: String?
    /// SubagentStop's `last_assistant_message`.
    public var result: String?
    public var state: State = .running
    /// The tool returned `async_launched`: it outlives the turn that started it.
    public var background = false
    public var started: Date
    public var ended: Date?

    public init(id: String, agentId: String? = nil, type: String, title: String, prompt: String? = nil, started: Date) {
        self.id = id
        self.agentId = agentId
        self.type = type
        self.title = title
        self.prompt = prompt
        self.started = started
    }
}

/// What a hook says about subagents; mapped from the hook kinds in `HangarUI` (AppState+Subagents).
public enum SubagentEvent: Equatable, Sendable {
    /// PreToolUse of the Agent/Task tool.
    case launch(toolUseId: String, type: String?, title: String?, prompt: String?)
    /// SubagentStart.
    case started(agentId: String, type: String?)
    /// PostToolUse of the Agent/Task tool: `background` — `async_launched` (it keeps running).
    case returned(toolUseId: String, agentId: String?, background: Bool)
    /// SubagentStop.
    case stopped(agentId: String, result: String?)
    /// UserPromptSubmit (also Claude's own turns): finished rows of earlier turns go.
    case turnStart
    /// Stop / StopFailure: a foreground subagent still running there never returned (interrupted).
    case turnEnd
    /// The agent exited: whatever ran is gone.
    case exited
    /// A new conversation (SessionStart startup/clear/resume, relaunch): nothing carries over.
    case reset
}

/// The subagents of one agent leaf for its current run. Event-driven only: no clock of its own, `now` comes with the event.
public struct SubagentList: Equatable, Sendable {
    /// Rows kept at most; the oldest finished go first.
    public static let cap = 30
    static let pendingCap = 16
    /// Claude's own default type when the tool call names none.
    static let defaultType = "general-purpose"

    public private(set) var items: [Subagent] = []
    /// SubagentStop of an id no row has yet (a foreground agent stops before its tool returns; internal agents never match).
    private var pending: [String: Stop] = [:]
    private var pendingOrder: [String] = []
    private var lastTurnEnd: Date?

    private struct Stop: Equatable, Sendable { var result: String?; var at: Date }

    public init() {}

    public var running: Int { items.filter { $0.state == .running }.count }

    /// Applies one event; false — nothing changed (callers skip the redraw).
    @discardableResult
    public mutating func apply(_ event: SubagentEvent, now: Date) -> Bool {
        let before = self
        switch event {
        case let .launch(toolUseId, type, title, prompt):
            guard !items.contains(where: { $0.id == toolUseId }) else { break }
            let t = type.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultType
            items.append(Subagent(id: toolUseId, type: t, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? t, prompt: prompt, started: now))
            trim()
        case let .started(agentId, type):
            if let i = items.firstIndex(where: { $0.agentId == agentId }) {
                // A resumed subagent runs again.
                if items[i].state != .running { items[i].state = .running; items[i].ended = nil }
                break
            }
            // shortcut: parallel launches of one type are paired in arrival order; the tool's result corrects a wrong guess.
            let free = items.indices.filter { items[$0].state == .running && items[$0].agentId == nil }
            guard let i = free.first(where: { items[$0].type == type }) ?? free.first else { break }
            items[i].agentId = agentId
            settlePending(i)
        case let .returned(toolUseId, agentId, background):
            guard let i = items.firstIndex(where: { $0.id == toolUseId }) else { break }
            if let agentId, items[i].agentId != agentId {
                if let j = items.firstIndex(where: { $0.agentId == agentId }) { items[j].agentId = items[i].agentId }
                items[i].agentId = agentId
            }
            if background {
                items[i].background = true
                settlePending(i)
            } else {
                settlePending(i)
                finish(i, .done, now: now)
            }
        case let .stopped(agentId, result):
            if let i = items.firstIndex(where: { $0.agentId == agentId }) {
                if let result { items[i].result = result }
                finish(i, .done, now: now)
            } else {
                if pending[agentId] == nil { pendingOrder.append(agentId) }
                pending[agentId] = Stop(result: result, at: now)
                while pendingOrder.count > Self.pendingCap { pending[pendingOrder.removeFirst()] = nil }
            }
        case .turnStart:
            // Rows that finished after the last turn ended (a background agent waking Claude) stay for this one.
            items.removeAll { $0.state != .running && ($0.ended ?? now) <= (lastTurnEnd ?? .distantPast) }
        case .turnEnd:
            for i in items.indices where items[i].state == .running && !items[i].background { finish(i, .failed, now: now) }
            lastTurnEnd = now
            pending = [:]
            pendingOrder = []
        case .exited:
            for i in items.indices where items[i].state == .running { finish(i, .failed, now: now) }
            lastTurnEnd = now
        case .reset:
            self = SubagentList()
        }
        return self != before
    }

    private mutating func finish(_ i: Int, _ state: Subagent.State, now: Date) {
        guard items[i].state == .running else { return }
        items[i].state = state
        items[i].ended = now
    }

    /// A stop that came before the row knew its agent id.
    private mutating func settlePending(_ i: Int) {
        guard let id = items[i].agentId, let stop = pending.removeValue(forKey: id) else { return }
        pendingOrder.removeAll { $0 == id }
        if let result = stop.result { items[i].result = result }
        finish(i, .done, now: stop.at)
    }

    private mutating func trim() {
        while items.count > Self.cap {
            items.remove(at: items.firstIndex { $0.state != .running } ?? 0)
        }
    }
}
