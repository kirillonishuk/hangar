import Darwin
import Foundation

public enum ControlClient {
    /// Fire-and-forget: the reply is not awaited, so a hung app never blocks a hook for more than ~1 s.
    public static func send(_ message: ControlMessage, to path: String) -> Bool {
        guard var addr = socketAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return false }
        let data = message.encoded()
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    public static let maxReply = 2 * 1_048_576

    /// One request per connection; `Data` is the JSON of `result`. The timeout applies to each send/receive (`SO_*TIMEO`), no timer.
    public static func request(_ call: ControlCall, to path: String, timeout: Double) -> Result<Data, ControlError> {
        guard var addr = socketAddress(path) else { return .failure(ControlError(code: .failed, message: "socket path is too long")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(ControlError(code: .failed, message: "socket() failed: errno \(errno)")) }
        defer { close(fd) }
        var on: Int32 = 1
        let secs = max(timeout, 0.001)
        var tv = timeval(tv_sec: Int(secs), tv_usec: Int32((secs - Double(Int(secs))) * 1_000_000))
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize) == 0
        else { return .failure(ControlError(code: .failed, message: "setsockopt failed: errno \(errno)")) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { return .failure(ControlError(code: .notRunning, message: "Hangar is not running")) }
            return .failure(ControlError(code: .failed, message: "connect failed: errno \(errno)"))
        }
        let id = 1
        let out = [UInt8](ControlMessage.request(ControlRequest(id: id, call: .success(call))).encoded())
        var offset = 0
        while offset < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            // The server answers an oversize line and closes before reading the rest; its reply is still readable.
            if n < 0 && errno == EPIPE { break }
            return .failure(ioError("send"))
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { return .failure(ioError("receive")) }
            if n == 0 { return .failure(ControlError(code: .failed, message: "Hangar closed the connection without a reply")) }
            let start = reply.count
            reply.append(contentsOf: chunk[..<n])
            if let nl = reply[start...].firstIndex(of: 0x0A) {
                reply = reply.prefix(upTo: nl)
                break
            }
            if reply.count > maxReply { return .failure(ControlError(code: .badRequest, message: "reply is too large")) }
        }
        guard reply.count <= maxReply, let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { return .failure(ControlError(code: .badRequest, message: "malformed reply")) }
        let malformed = ControlError(code: .badRequest, message: "malformed reply")
        guard let replyID = object["id"].flatMap(ControlCall.wireInt) else {
            // No id: the line was rejected before its id was read — `{"id":null,"error":{…}}` or legacy `{"ok":false,"error":"…"}`.
            if let legacy = object["error"] as? String {
                return .failure(ControlError(code: ControlErrorCode(rawValue: legacy) ?? .badRequest, message: "Hangar rejected the request: \(legacy.prefix(64))"))
            }
            return .failure(decodeError(object["error"]) ?? malformed)
        }
        guard replyID == id else { return .failure(malformed) }
        if let result = object["result"] {
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            else { return .failure(ControlError(code: .badRequest, message: "malformed reply")) }
            return .success(data)
        }
        return .failure(decodeError(object["error"]) ?? malformed)
    }

    private static func decodeError(_ raw: Any?) -> ControlError? {
        guard let raw, JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ControlError.self, from: data)
    }

    private static func ioError(_ what: String) -> ControlError {
        errno == EAGAIN || errno == EWOULDBLOCK
            ? ControlError(code: .timeout, message: "Hangar did not answer in time")
            : ControlError(code: .failed, message: "\(what) failed: errno \(errno)")
    }
}
