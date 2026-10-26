import Foundation

/// tsserver's stdout (#NN-tsserver): `Content-Length: N\r\n\r\n` + N bytes of JSON. Untrusted: a message over `maxMessage` is
/// skipped unread, a header block without a valid length is dropped, a runaway header is cut, non-objects are ignored.
struct TsFramer {
    static let defaultMaxMessage = 32 << 20
    private static let maxHeader = 1024
    private static let separator = Data("\r\n\r\n".utf8)
    let maxMessage: Int
    private var buffer = Data()
    /// Body bytes of an oversized message still to discard.
    private var skip = 0

    init(maxMessage: Int = defaultMaxMessage) { self.maxMessage = maxMessage }

    var buffered: Int { buffer.count }

    mutating func feed(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var out: [[String: Any]] = []
        while !buffer.isEmpty {
            if skip > 0 {
                let n = min(skip, buffer.count)
                buffer = Data(buffer.dropFirst(n))
                skip -= n
                continue
            }
            guard let sep = buffer.range(of: Self.separator) else {
                // No header end in sight: keep only a tail that could still start one.
                if buffer.count > Self.maxHeader { buffer = Data(buffer.suffix(32)) }
                break
            }
            let header = String(decoding: buffer[buffer.startIndex..<sep.lowerBound], as: UTF8.self)
            let bodyStart = sep.upperBound - buffer.startIndex
            guard let length = Self.contentLength(header) else {
                buffer = Data(buffer.dropFirst(bodyStart))
                continue
            }
            if length > maxMessage {
                buffer = Data(buffer.dropFirst(bodyStart))
                skip = length
                continue
            }
            guard buffer.count - bodyStart >= length else { break }
            let body = buffer.subdata(in: (buffer.startIndex + bodyStart)..<(buffer.startIndex + bodyStart + length))
            buffer = Data(buffer.dropFirst(bodyStart + length))
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { out.append(object) }
        }
        return out
    }

    private static func contentLength(_ header: String) -> Int? {
        // The last field wins; noise glued before it (a cut runaway header) is ignored.
        guard let r = header.lowercased().range(of: "content-length:", options: .backwards) else { return nil }
        let value = header.lowercased()[r.upperBound...].prefix { $0 != "\r" && $0 != "\n" }
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }
}

/// What a framed object is; anything else (requests, unknown types, wrong field types) is ignored.
enum TsMessage: Equatable {
    case response(requestSeq: Int, success: Bool)
    case event(String)

    init?(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "response":
            guard let seq = object["request_seq"] as? Int, let ok = object["success"] as? Bool else { return nil }
            self = .response(requestSeq: seq, success: ok)
        case "event":
            guard let name = object["event"] as? String else { return nil }
            self = .event(name)
        default: return nil
        }
    }
}

/// tsserver reads one JSON request per line.
func tsRequestLine(seq: Int, command: String, arguments: [String: Any]) -> Data? {
    let object: [String: Any] = ["seq": seq, "type": "request", "command": command, "arguments": arguments]
    guard JSONSerialization.isValidJSONObject(object),
          var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
    data.append(0x0A)
    return data
}
