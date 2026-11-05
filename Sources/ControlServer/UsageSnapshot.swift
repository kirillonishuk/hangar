import Foundation

/// Per window name the newer of the two: a later reset (more than 90 s apart: `resets_at` jitters between ticks) is a
/// newer window; within one window usage only grows, so the higher percent is the fresher figure. A `known` window
/// whose reset has passed is dropped (the tick's own are kept as they came). Sorted by name, at most 8 (the wire limit).
// shortcut: after an account switch the old account's later-resetting windows win until they reset; rare, change if seen
public func freshestWindows(_ known: [WireWindow], _ tick: [WireWindow], now: Double) -> [WireWindow] {
    var byName: [String: WireWindow] = [:]
    for w in known where (w.resetsAt ?? .infinity) > now { byName[w.name] = w }
    for w in tick {
        guard let old = byName[w.name] else { byName[w.name] = w; continue }
        if let a = old.resetsAt, let b = w.resetsAt, abs(a - b) > 90 {
            if b > a { byName[w.name] = w }
        } else if (w.usedPercent ?? -1) >= (old.usedPercent ?? -1) {
            byName[w.name] = w
        }
    }
    return Array(byName.keys.sorted().prefix(8).compactMap { byName[$0] })
}

/// Claude's account-wide limits as the freshest seen across every chat (Mac and ssh hosts): each status line tick is
/// merged in, and the merged set goes back to that chat's line and on to the app, so an idle chat's stale tick never
/// lowers it (HD-137). Shared by every ControlServer of the app; touched on their queues, hence the lock.
public final class UsageSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [WireWindow] = []

    public init() {}

    public func merge(_ tick: [WireWindow], now: Double = Date().timeIntervalSince1970) -> [WireWindow] {
        lock.lock(); defer { lock.unlock() }
        windows = freshestWindows(windows, tick, now: now)
        return windows
    }
}

/// The reply to a `usage` message: `{"ok":true,"windows":[…]}`, the merged windows for the status line that sent it.
public func usageReply(_ windows: [WireWindow]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let list = (try? encoder.encode(windows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    return #"{"ok":true,"windows":"# + list + "}"
}

/// The windows of a `usage` reply; anything else (an older app's `{"ok":true}`, garbage) is none.
public func usageReplyWindows(_ line: Data) -> [WireWindow] {
    struct Reply: Decodable { var windows: [WireWindow] }
    guard let windows = try? JSONDecoder().decode(Reply.self, from: line).windows else { return [] }
    // The same names and values the server accepts from a status line: re-checked as if they came over the wire.
    guard case let .success(.usage(m)) = ControlMessage.decode(ControlMessage.usage(UsageMessage(agent: "claude", windows: Array(windows.prefix(8)))).encoded().dropLast())
    else { return [] }
    return m.windows
}
