import Foundation

/// Newest first: an unknown client version gets the first one.
public let mcpProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

/// One stdin line of `hangar mcp`; longer lines are answered with -32600 and skipped.
public let maxMCPLine = 1_048_576

/// MCP over JSON-RPC 2.0, one message per line (stdio transport). Tools are the control methods, nothing else.
/// Trust boundary: lines come from the agent; `arguments` go through `ControlCall.decode` like socket params.
public struct MCPSession {
    private let call: (ControlCall) -> Result<Data, ControlError>

    public init(call: @escaping (ControlCall) -> Result<Data, ControlError>) {
        self.call = call
    }

    /// The reply without a trailing newline (JSON has none inside); nil for notifications.
    public mutating func handle(_ line: Data) -> Data? {
        guard line.count <= maxMCPLine else { return Self.error(nil, -32600, "request is too large") }
        guard let raw = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
            return Self.error(nil, -32700, "parse error")
        }
        guard let message = raw as? [String: Any] else { return Self.error(nil, -32600, "expected a single JSON-RPC object (batches are not supported)") }
        guard let rawID = message["id"] else { return nil }  // notification: never answered
        guard let id = Self.validID(rawID) else { return Self.error(nil, -32600, "\"id\" must be a string or a number") }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return Self.error(id, -32600, "invalid request")
        }
        let params: [String: Any]
        switch message["params"] {
        case nil, is NSNull: params = [:]
        case let p as [String: Any]: params = p
        default: return Self.error(id, -32602, "\"params\" must be an object")
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { mcpProtocolVersions.contains($0) ? $0 : nil } ?? mcpProtocolVersions[0]
            return Self.result(id, ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                                    "serverInfo": ["name": "hangar", "version": Self.version]])
        case "ping":
            return Self.result(id, [String: Any]())
        case "tools/list":
            return Self.result(id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, let m = ControlMethod.allCases.first(where: { $0.toolName == name }) else {
                return Self.error(id, -32602, "unknown tool \"\(((params["name"] as? String) ?? "").prefix(64))\"")
            }
            let arguments: [String: Any]
            switch params["arguments"] {
            case nil, is NSNull: arguments = [:]
            case let a as [String: Any]: arguments = a
            default: return Self.error(id, -32602, "\"arguments\" must be an object")
            }
            let outcome = ControlCall.decode(method: m.rawValue, params: arguments).flatMap(call)
            switch outcome {
            case let .success(data): return Self.result(id, Self.toolText(String(decoding: data, as: UTF8.self), isError: false))
            case let .failure(e): return Self.result(id, Self.toolText(e.message, isError: true))
            }
        default:
            return Self.error(id, -32601, "method not found: \(method.prefix(64))")
        }
    }

    // MARK: encoding

    private static let version = Bundle.main.executableURL.map(appVersion) ?? "dev"

    /// The enclosing app's version: the CLI is X.app/Contents/Helpers/hangar (often reached through a symlink), so
    /// `Bundle.main` has no Info.plist of its own.
    public static func appVersion(executable: URL) -> String {
        let plist = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// String or a non-boolean number, returned as is.
    private static func validID(_ raw: Any) -> Any? {
        if raw is String { return raw }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n }
        return nil
    }

    private static func toolText(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Key order `jsonrpc`, `id`, then the body, as in the MCP examples.
    private static func envelope(_ id: Any?, _ key: String, _ body: Any) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(json(id ?? NSNull())),"\#(key)":\#(json(body))}"#.utf8)
    }

    private static func result(_ id: Any, _ body: Any) -> Data { envelope(id, "result", body) }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> Data {
        envelope(id, "error", ["code": code, "message": message])
    }

    // MARK: tools

    private static var tools: [[String: Any]] {
        ControlMethod.allCases.map { m in
        var properties: [String: Any] = [:]
        for p in m.params {
            var schema: [String: Any]
            switch p.type {
            case let .string(maxBytes): schema = ["type": "string", "maxLength": maxBytes]
            case .bool: schema = ["type": "boolean"]
            case let .int(range): schema = ["type": "integer", "minimum": range.lowerBound, "maximum": range.upperBound]
            case let .oneOf(options): schema = ["type": "string", "enum": options]
            case let .list(options, max): schema = ["type": "array", "items": ["type": "string", "enum": options], "maxItems": max]
            }
            schema["description"] = p.summary
            properties[p.name] = schema
        }
        return ["name": m.toolName, "description": m.summary, "inputSchema": [
            "type": "object", "properties": properties, "required": m.params.filter(\.required).map(\.name), "additionalProperties": false,
        ] as [String: Any]]
        }
    }
}
