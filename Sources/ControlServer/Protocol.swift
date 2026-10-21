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
    case badRequest = "bad-request"
}

/// One JSON object per line: `{"v":1,"type":"event"|"usage",…}\n`.
public enum ControlMessage: Equatable, Sendable {
    case event(EventMessage)
    case usage(UsageMessage)
    case request(ControlRequest)

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        var data: Data
        switch self {
        case let .event(m): data = (try? encoder.encode(Envelope(type: "event", body: m))) ?? Data()
        case let .usage(m): data = (try? encoder.encode(Envelope(type: "usage", body: m))) ?? Data()
        case let .request(r):
            let params = String(decoding: r.call.successValue?.paramsJSON() ?? Data("{}".utf8), as: UTF8.self)
            let method = r.call.successValue?.method.rawValue ?? ""
            data = Data(#"{"v":1,"id":\#(r.id),"method":"\#(method)","params":\#(params)}"#.utf8)
        }
        data.append(0x0A)
        return data
    }

    /// Trust boundary: the line comes from any local process of this user.
    public static func decode(_ line: Data) -> Result<ControlMessage, ProtocolError> {
        guard line.count <= ControlServer.maxLine else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .failure(.badJSON) }
        guard object["v"].flatMap(ControlCall.wireInt) == 1 else { return .failure(.badVersion) }
        if let method = object["method"] {
            guard let id = object["id"].flatMap(ControlCall.wireInt), (0...9_007_199_254_740_992).contains(id),
                  let method = method as? String else { return .failure(.badRequest) }
            var params: [String: Any] = [:]
            if let raw = object["params"] {
                guard let p = raw as? [String: Any] else { return .failure(.badRequest) }
                params = p
            }
            return .success(.request(ControlRequest(id: id, call: ControlCall.decode(method: method, params: params))))
        }
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

/// The ssh host socket (`ControlServer(remote: true)`): one header line + exactly `len` raw payload bytes per connection.
/// `{"v":1,"type":"hook","tab":…,"leaf":…,"kind":…,"session":…?,"len":N}` | `{"v":1,"type":"statusline","len":N}`.
/// Trust boundary: any process of that account on the server can write here; only status updates come out.
public enum RemoteMessage {
    static let maxHeader = 4096
    static let maxPayload = 262_144

    enum Header: Equatable {
        case message(length: Int)
        /// A request line: answered with `unknown-method`, never run.
        case request(id: Int?)
        case invalid(ProtocolError)
    }

    static func header(_ line: Data) -> Header {
        guard line.count <= maxHeader else { return .invalid(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .invalid(.badJSON) }
        if object["method"] != nil { return .request(id: object["id"].flatMap(ControlCall.wireInt)) }
        guard object["v"].flatMap(ControlCall.wireInt) == 1 else { return .invalid(.badVersion) }
        guard ["hook", "statusline"].contains(object["type"] as? String) else { return .invalid(.unknownType) }
        guard let len = object["len"].flatMap(ControlCall.wireInt), len >= 0 else { return .invalid(.badField) }
        return len > maxPayload ? .invalid(.tooLarge) : .message(length: len)
    }

    public static func decode(header: Data, payload: Data) -> Result<ControlMessage, ProtocolError> {
        switch Self.header(header) {
        case .request: return .failure(.badRequest)
        case let .invalid(e): return .failure(e)
        case .message: break
        }
        let object = (try? JSONSerialization.jsonObject(with: header) as? [String: Any]) ?? [:]
        let message: ControlMessage
        if object["type"] as? String == "hook" {
            guard let tab = (object["tab"] as? String).flatMap(UUID.init(uuidString:)),
                  let leaf = (object["leaf"] as? String).flatMap(UUID.init(uuidString:)),
                  let kind = object["kind"] as? String else { return .failure(.badField) }
            let session = validSessionId(object["session"] as? String)
            guard var m = eventMessage(kind: kind, tab: tab, leaf: leaf, args: session.map { ["--session", $0] } ?? [], payload: payload)
            else { return .failure(.badField) }
            m.message = m.message.map { String($0.prefix(500)) }
            message = .event(m)
        } else {
            let windows = statuslineWindows(payload)
            guard !windows.isEmpty else { return .failure(.badField) }
            message = .usage(UsageMessage(agent: "claude", windows: windows))
        }
        // Same field limits as the main socket: re-read through its decoder.
        return ControlMessage.decode(message.encoded().dropLast())
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

public enum ControlErrorCode: String, Codable, Sendable {
    case badRequest = "bad-request", unknownMethod = "unknown-method", badParams = "bad-params", notFound = "not-found", ambiguous
    case confirmRequired = "confirm-required", notStarted = "not-started", exited, failed, busy, tooLarge = "too-large"
    case notRunning = "not-running", timeout
}

public struct ControlError: Error, Equatable, Codable, Sendable {
    public var code: ControlErrorCode
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// `{"v":1,"id":N,"method":"…","params":{…}}`; a bad method or params keeps the id so the error can be answered.
public struct ControlRequest: Equatable, Sendable {
    public var id: Int
    public var call: Result<ControlCall, ControlError>

    public init(id: Int, call: Result<ControlCall, ControlError>) {
        self.id = id
        self.call = call
    }
}

extension Result {
    var successValue: Success? { if case let .success(v) = self { v } else { nil } }
}

/// `{"id":N,"result":{…}}` or `{"id":N,"error":{"code","message"}}`, one line + `\n`.
public struct ControlResponse: Sendable {
    public var id: Int?
    public var body: Result<Data, ControlError>

    public init(id: Int?, body: Result<Data, ControlError>) {
        self.id = id
        self.body = body
    }

    public static func ok<T: Encodable>(_ id: Int, _ value: T) -> ControlResponse {
        ControlResponse(id: id, body: .success((try? wireEncoder.encode(value)) ?? Data("{}".utf8)))
    }

    public func encoded() -> Data {
        var out = Data(#"{"id":"#.utf8)
        out.append(Data((id.map(String.init) ?? "null").utf8))
        switch body {
        case let .success(result):
            out.append(Data(#","result":"#.utf8))
            out.append(result)
        case let .failure(error):
            out.append(Data(#","error":"#.utf8))
            out.append((try? Self.wireEncoder.encode(error)) ?? Data("{}".utf8))
        }
        out.append(Data("}\n".utf8))
        return out
    }

    private static var wireEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

// MARK: results

public struct ProjectInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var exists: Bool

    public init(id: UUID, name: String, path: String, exists: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.exists = exists
    }
}

public struct LeafInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: TabKind
    public var status: String

    public init(id: UUID, kind: TabKind, status: String) {
        self.id = id
        self.kind = kind
        self.status = status
    }
}

/// `kind` and `status` are those of the focused leaf.
public struct TabInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: TabKind
    public var title: String
    public var status: String
    public var leaves: [LeafInfo]

    public init(id: UUID, kind: TabKind, title: String, status: String, leaves: [LeafInfo]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.leaves = leaves
    }
}

public struct TaskInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var project: UUID
    public var projectName: String
    public var status: String
    /// "main-folder" | "worktree"
    public var mode: String
    public var path: String
    public var branch: String?
    public var base: String?
    public var tabs: [TabInfo]

    public init(id: UUID, name: String, project: UUID, projectName: String, status: String, mode: String, path: String,
                branch: String?, base: String?, tabs: [TabInfo]) {
        self.id = id
        self.name = name
        self.project = project
        self.projectName = projectName
        self.status = status
        self.mode = mode
        self.path = path
        self.branch = branch
        self.base = base
        self.tabs = tabs
    }
}

public struct ProjectsResult: Codable, Equatable, Sendable {
    public var projects: [ProjectInfo]
    public init(projects: [ProjectInfo]) { self.projects = projects }
}

public struct ProjectAddResult: Codable, Equatable, Sendable {
    public var project: ProjectInfo
    public var added: Bool
    public init(project: ProjectInfo, added: Bool) {
        self.project = project
        self.added = added
    }
}

public struct TasksResult: Codable, Equatable, Sendable {
    public var tasks: [TaskInfo]
    public init(tasks: [TaskInfo]) { self.tasks = tasks }
}

public struct TaskResult: Codable, Equatable, Sendable {
    public var task: TaskInfo
    public init(task: TaskInfo) { self.task = task }
}

public struct TabResult: Codable, Equatable, Sendable {
    public var task: UUID
    public var tab: TabInfo
    public init(task: UUID, tab: TabInfo) {
        self.task = task
        self.tab = tab
    }
}

public struct SendResult: Codable, Equatable, Sendable {
    public var tab: UUID
    public var leaf: UUID
    public init(tab: UUID, leaf: UUID) {
        self.tab = tab
        self.leaf = leaf
    }
}

public struct ScreenResult: Codable, Equatable, Sendable {
    public var tab: UUID
    public var leaf: UUID
    public var text: String
    public var lines: Int
    public var truncated: Bool
    public init(tab: UUID, leaf: UUID, text: String, lines: Int, truncated: Bool) {
        self.tab = tab
        self.leaf = leaf
        self.text = text
        self.lines = lines
        self.truncated = truncated
    }
}

public struct ArchiveResult: Codable, Equatable, Sendable {
    public var task: UUID
    public var archived: Bool
    public init(task: UUID, archived: Bool) {
        self.task = task
        self.archived = archived
    }
}
