import Foundation
import AgentStatus

/// Pure parts of the `hangar` CLI (the binary itself is Sources/hangar/main.swift).

public let maxStdin = 1_048_576

private func uuid(_ env: [String: String], _ key: String) -> UUID? {
    env[key].flatMap { UUID(uuidString: $0) }
}

/// nil — not inside a Hangar tab, unknown kind, or (Codex) not an `agent-turn-complete` payload.
/// Everything read here comes from hook stdin or argv: any local process may have written it.
public func eventMessage(kind: String, args: [String], env: [String: String], stdin: Data?) -> EventMessage? {
    guard let tab = uuid(env, "HANGAR_TAB_ID"), let leaf = uuid(env, "HANGAR_LEAF_ID") else { return nil }
    return eventMessage(kind: kind, tab: tab, leaf: leaf, args: args, payload: stdin)
}

/// Shared by `hangar event` and the ssh host socket (RemoteMessage), so both read a payload the same way.
public func eventMessage(kind: String, tab: UUID, leaf: UUID, args: [String], payload stdin: Data?) -> EventMessage? {
    guard let kind = HookKind(rawValue: kind) else { return nil }
    let payload = args.last(where: { $0.hasPrefix("{") }).map { Data($0.utf8) } ?? stdin
    let object = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    var m = EventMessage(tab: tab, leaf: leaf, kind: kind)
    if kind == .codexNotify {
        // verify: проверить, когда codex будет установлен
        guard object["type"] as? String == "agent-turn-complete" else { return nil }
        m.session = validSessionId(object["thread-id"] as? String)
        m.message = object["last-assistant-message"] as? String
    } else {
        m.session = validSessionId(object["session_id"] as? String)
        m.notificationType = object["notification_type"] as? String
        m.source = object["source"] as? String
        // Bounded here, before encoding: a long answer or command must not push the line past ControlServer.maxLine.
        m.message = ((object["message"] as? String) ?? (object["last_assistant_message"] as? String)).map { String($0.prefix(500)) }
        if kind == .permissionRequest {
            m.tool = (object["tool_name"] as? String).flatMap { $0.count > 64 ? nil : $0 }
            m.command = ((object["tool_input"] as? [String: Any])?["command"] as? String).map { String($0.prefix(500)) }
        }
        if kind == .stopFailure { m.error = (object["error"] as? String).flatMap { $0.count > 64 ? nil : $0 } }
    }
    if let i = args.firstIndex(of: "--session"), i < (args.firstIndex(of: "--then") ?? args.endIndex),
       i + 1 < args.count {
        m.session = validSessionId(args[i + 1])
    }
    return m
}

/// The user's original `notify` argv: everything between `--then` and the trailing JSON payload.
public func chainedArgv(_ args: [String]) -> [String]? {
    guard let i = args.firstIndex(of: "--then") else { return nil }
    var rest = Array(args[(i + 1)...])
    if rest.last?.hasPrefix("{") == true { rest.removeLast() }
    return rest.isEmpty ? nil : rest
}

/// One window per `rate_limits` key (sorted, so the order is stable) that carries `used_percentage` or `resets_at`.
/// Names/values the server would reject are dropped here, so one odd key cannot discard the rest.
public func statuslineWindows(_ stdin: Data) -> [WireWindow] {
    guard let root = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
          let limits = root["rate_limits"] as? [String: Any] else { return [] }
    var windows: [WireWindow] = []
    for name in limits.keys.sorted() {
        guard let w = limits[name] as? [String: Any],
              (1...64).contains(name.utf8.count),
              name.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F })
        else { continue }
        let used = (w["used_percentage"] as? NSNumber)?.doubleValue
        var resets = (w["resets_at"] as? NSNumber)?.doubleValue
        if let r = resets, !(r > 0 && r < 8_589_934_592) { resets = nil }
        if used == nil && resets == nil { continue }
        windows.append(WireWindow(name: name, usedPercent: used, resetsAt: resets))
    }
    return Array(windows.prefix(8))
}
