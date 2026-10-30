import Foundation
import ControlServer

public enum UsageAgent: String, Sendable, CaseIterable { case claude, codex }

public enum WindowKind: Hashable, Sendable { case session, weekly, weeklyModel(String) }

public struct UsageWindow: Equatable, Sendable {
    public var kind: WindowKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var updatedAt: Date

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date?, updatedAt: Date) {
        self.kind = kind; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.updatedAt = updatedAt
    }
}

public struct AgentUsage: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var plan: String?
    public var limitReached: Bool
    public var limitResetsAt: Date?
    public var updatedAt: Date

    public init(windows: [UsageWindow], plan: String?, limitReached: Bool = false, limitResetsAt: Date? = nil, updatedAt: Date) {
        self.windows = windows; self.plan = plan; self.limitReached = limitReached
        self.limitResetsAt = limitResetsAt; self.updatedAt = updatedAt
    }
}

public enum UsageLevel: Int, Comparable, Sendable {
    case ok, warn, full
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The only place for the thresholds; Theme and notifications read them from here.
public enum UsageThreshold {
    public static let warn = 80.0
    public static let full = 95.0
}

public func level(percent: Double, limitReached: Bool) -> UsageLevel {
    if limitReached || percent >= UsageThreshold.full { return .full }
    return percent >= UsageThreshold.warn ? .warn : .ok
}

public func claudeWindows(_ wire: [WireWindow], now: Date) -> [UsageWindow] {
    wire.compactMap { w in
        guard let p = w.usedPercent else { return nil }
        let kind: WindowKind
        if w.name == "five_hour" { kind = .session }
        else if w.name == "seven_day" { kind = .weekly }
        else if w.name.hasPrefix("seven_day_"), w.name.count > "seven_day_".count {
            kind = .weeklyModel(String(w.name.dropFirst("seven_day_".count)))
        } else { return nil }
        return UsageWindow(kind: kind, usedPercent: p, resetsAt: w.resetsAt.map(Date.init(timeIntervalSince1970:)), updatedAt: now)
    }
}

public struct UsageAlert: Equatable, Sendable {
    public var agent: UsageAgent
    public var kind: WindowKind?
    public var level: UsageLevel
    public var percent: Double?

    public init(agent: UsageAgent, kind: WindowKind?, level: UsageLevel, percent: Double?) {
        self.agent = agent; self.kind = kind; self.level = level; self.percent = percent
    }
}

public struct UsageBoard: Equatable, Sendable {
    /// `resetsAt` rounded to the minute: it jitters by a second or so between statusline ticks.
    private struct Key: Hashable {
        var kind: WindowKind
        var resetsAt: Date?
        init(kind: WindowKind, resetsAt: Date?) {
            self.kind = kind
            self.resetsAt = resetsAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
        }
    }
    private struct State: Equatable {
        var usage: AgentUsage
        var notified: [Key: UsageLevel] = [:]
        var limitAlerted = false
    }
    private var states: [UsageAgent: State] = [:]

    public init() {}

    public mutating func update(_ agent: UsageAgent, windows: [UsageWindow], plan: String?, now: Date) -> [UsageAlert] {
        var s = states[agent] ?? State(usage: AgentUsage(windows: [], plan: nil, updatedAt: now))
        // A tick without a window (Claude Code leaves out one it has no figure for) keeps the last known one, so the
        // 5-hour row doesn't vanish; a passed reset shows 0 (`view`). Per-model windows go once their reset passed.
        let kept = s.usage.windows.filter { old in
            !windows.contains { $0.kind == old.kind }
                && (old.kind == .session || old.kind == .weekly || (old.resetsAt ?? .distantPast) > now)
        }
        s.usage.windows = windows + kept
        if let plan { s.usage.plan = plan }
        s.usage.updatedAt = now
        var alerts: [UsageAlert] = []
        for w in windows {
            let l = Usage.level(percent: w.usedPercent, limitReached: false)
            let key = Key(kind: w.kind, resetsAt: w.resetsAt)
            if l > .ok, l > (s.notified[key] ?? .ok) {
                s.notified[key] = l
                // One notification per event: the limit-reached alert already went out.
                if l == .full, s.usage.limitReached, s.limitAlerted, (s.usage.limitResetsAt ?? .distantFuture) > now { continue }
                alerts.append(UsageAlert(agent: agent, kind: w.kind, level: l, percent: w.usedPercent))
            }
        }
        if !windows.isEmpty, s.usage.windows.allSatisfy({ $0.usedPercent < UsageThreshold.full }) {
            s.usage.limitReached = false; s.usage.limitResetsAt = nil; s.limitAlerted = false
        }
        states[agent] = s
        return alerts
    }

    public mutating func markLimitReached(_ agent: UsageAgent, now: Date) -> [UsageAlert] {
        var s = states[agent] ?? State(usage: AgentUsage(windows: [], plan: nil, updatedAt: now))
        if let r = s.usage.limitResetsAt, r <= now { s.limitAlerted = false }
        s.usage.limitReached = true
        s.usage.limitResetsAt = s.usage.windows.max { $0.usedPercent < $1.usedPercent }?.resetsAt
        s.usage.updatedAt = now
        defer { states[agent] = s }
        guard !s.limitAlerted else { return [] }
        s.limitAlerted = true
        // A per-window .full for this event was already delivered: don't notify twice.
        let covered = s.usage.windows.contains { $0.usedPercent >= UsageThreshold.full && s.notified[Key(kind: $0.kind, resetsAt: $0.resetsAt)] == .full }
        if covered { return [] }
        return [UsageAlert(agent: agent, kind: nil, level: .full, percent: nil)]
    }

    /// Windows whose reset time has passed show 0 — computed here at render time, no timer.
    public func view(_ agent: UsageAgent, now: Date) -> AgentUsage? {
        guard var u = states[agent]?.usage else { return nil }
        for i in u.windows.indices {
            if let r = u.windows[i].resetsAt, r <= now { u.windows[i].usedPercent = 0 }
        }
        if u.limitReached, let r = u.limitResetsAt, r <= now { u.limitReached = false }
        return u
    }

    public func level(_ agent: UsageAgent, now: Date) -> UsageLevel? {
        guard let u = view(agent, now: now) else { return nil }
        return u.windows.map { Usage.level(percent: $0.usedPercent, limitReached: u.limitReached) }.max() ?? (u.limitReached ? .full : .ok)
    }
}
