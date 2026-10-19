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
}
