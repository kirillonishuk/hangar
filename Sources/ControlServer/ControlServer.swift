import Darwin
import Foundation

public enum ControlServerError: Error, Equatable {
    case pathTooLong
    case alreadyRunning(pid: Int32)
    case system(call: String, errno: Int32)
}

/// NDJSON over a Unix socket. All socket state lives on `queue`; no timers, only DispatchSources.
public final class ControlServer: @unchecked Sendable {
    public static let maxLine = 65_536
    public static let maxConnections = 32

    private let path: String
    private let handler: @MainActor (ControlMessage) -> Void
    private let queue = DispatchQueue(label: "hangar.control-server")
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let source: DispatchSourceRead
        /// false — SO_NOSIGPIPE could not be set, so a write could kill the app with SIGPIPE.
        let canReply: Bool
        var buffer = Data()
        init(source: DispatchSourceRead, canReply: Bool) {
            self.source = source
            self.canReply = canReply
        }
    }

    public init(path: String, handler: @escaping @MainActor (ControlMessage) -> Void) {
        self.path = path
        self.handler = handler
    }

    public func start() throws(ControlServerError) {
        guard var addr = socketAddress(path) else { throw .pathTooLong }
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw .system(call: "bind", errno: EEXIST) }
            if let pid = runningPeer(&addr) { throw .alreadyRunning(pid: pid) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(call: "socket", errno: errno) }
        func fail(_ call: String) -> ControlServerError {
            let e = errno
            close(fd)
            return .system(call: call, errno: e)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        guard chmod(path, 0o600) == 0 else { let e = fail("chmod"); unlink(path); throw e }
        guard listen(fd, SOMAXCONN) == 0 else { let e = fail("listen"); unlink(path); throw e }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        queue.sync { listener = source }
        source.resume()
    }

    public func stop() {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            for c in connections.values { c.source.cancel() }
            connections.removeAll()
            unlink(path)
        }
    }

    /// The probe connection doubles as the second-instance check: a live server answers connect().
    private func runningPeer(_ addr: inout sockaddr_un) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 ? pid : 0
    }

    // MARK: - on queue

    private func accept(on listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), connections.count < Self.maxConnections else {
            close(fd)
            return
        }
        var on: Int32 = 1
        // macOS rejects this with EINVAL once the peer has already closed; its bytes are still readable.
        let canReply = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.setCancelHandler { close(fd) }
        connections[fd] = Connection(source: source, canReply: canReply)
        source.resume()
    }

    private func read(_ fd: Int32) {
        guard let c = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { drop(fd); return }
        c.buffer.append(chunk, count: n)
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            switch ControlMessage.decode(line) {
            case let .success(message):
                let handler = handler
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(message) } }
                reply(fd, #"{"ok":true}"#)
            case let .failure(error):
                reply(fd, #"{"ok":false,"error":"\#(error.rawValue)"}"#)
                if error == .tooLarge { drop(fd); return }
            }
        }
        if c.buffer.count > Self.maxLine {
            reply(fd, #"{"ok":false,"error":"too-large"}"#)
            drop(fd)
        }
    }

    /// shortcut: a reply that does not fit the socket buffer is dropped; replies are tiny and clients may not read them.
    private func reply(_ fd: Int32, _ text: String) {
        guard connections[fd]?.canReply == true else { return }
        let data = Array((text + "\n").utf8)
        _ = Darwin.write(fd, data, data.count)
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.source.cancel()
    }
}

/// nil — the path does not fit `sun_path` (103 bytes + NUL).
func socketAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count <= 103, bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
    }
    return addr
}
