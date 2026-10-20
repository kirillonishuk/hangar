import Foundation
import AgentStatus

public struct EventMessage: Codable, Equatable, Sendable {
    public var tab: UUID
    public var leaf: UUID
    public var kind: HookKind
    public var session: String?
    public var notificationType: String?
    public var message: String?
    /// SessionStart's `source`: startup / resume / clear / compact.
    public var source: String?

    public init(tab: UUID, leaf: UUID, kind: HookKind, session: String? = nil, notificationType: String? = nil, message: String? = nil,
                source: String? = nil) {
        self.tab = tab
        self.leaf = leaf
        self.kind = kind
        self.session = session
        self.notificationType = notificationType
        self.message = message
        self.source = source
    }
}

public struct WireWindow: Codable, Equatable, Sendable {
    public var name: String
    public var usedPercent: Double?
    /// epoch seconds
    public var resetsAt: Double?

    public init(name: String, usedPercent: Double?, resetsAt: Double?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct UsageMessage: Codable, Equatable, Sendable {
    /// "claude" | "codex"
    public var agent: String
    public var windows: [WireWindow]

    public init(agent: String, windows: [WireWindow]) {
        self.agent = agent
        self.windows = windows
    }
}

public enum ProtocolError: String, Error, Sendable {
    case badJSON = "bad-json", badVersion = "bad-version", unknownType = "unknown-type", badField = "bad-field", tooLarge = "too-large"
}

/// One JSON object per line: `{"v":1,"type":"event"|"usage",…}\n`.
public enum ControlMessage: Equatable, Sendable {
    case event(EventMessage)
    case usage(UsageMessage)

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        var data: Data
        switch self {
        case let .event(m): data = (try? encoder.encode(Envelope(type: "event", body: m))) ?? Data()
        case let .usage(m): data = (try? encoder.encode(Envelope(type: "usage", body: m))) ?? Data()
        }
        data.append(0x0A)
        return data
    }

    /// Trust boundary: the line comes from any local process of this user.
    public static func decode(_ line: Data) -> Result<ControlMessage, ProtocolError> {
        guard line.count <= ControlServer.maxLine else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .failure(.badJSON) }
        guard (object["v"] as? Int) == 1 else { return .failure(.badVersion) }
        let decoder = JSONDecoder()
        switch object["type"] as? String {
        case "event":
            guard var m = try? decoder.decode(EventMessage.self, from: line) else { return .failure(.badField) }
            if let t = m.notificationType, t.count > 64 { return .failure(.badField) }
            if let t = m.source, t.count > 64 { return .failure(.badField) }
            m.session = validSessionId(m.session)
            m.message = m.message.map { String($0.prefix(500)) }
            return .success(.event(m))
        case "usage":
            guard var m = try? decoder.decode(UsageMessage.self, from: line),
                  m.agent == "claude" || m.agent == "codex", m.windows.count <= 8 else { return .failure(.badField) }
            for i in m.windows.indices {
                let name = m.windows[i].name
                guard (1...64).contains(name.utf8.count),
                      name.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F })
                else { return .failure(.badField) }
                if let p = m.windows[i].usedPercent {
                    guard p.isFinite else { return .failure(.badField) }
                    m.windows[i].usedPercent = min(max(p, 0), 100)
                }
                if let r = m.windows[i].resetsAt, !(r > 0 && r < 8_589_934_592) { return .failure(.badField) }
            }
            return .success(.usage(m))
        default:
            return .failure(.unknownType)
        }
    }
}

/// Writes `v` and `type` into the same JSON object as the body's own keys.
private struct Envelope<Body: Encodable>: Encodable {
    var type: String
    var body: Body

    enum Keys: String, CodingKey { case v, type }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .v)
        try c.encode(type, forKey: .type)
        try body.encode(to: encoder)
    }
}
