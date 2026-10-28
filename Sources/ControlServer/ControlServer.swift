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
    public static let maxResponse = 1_048_576
    public static let maxOutbox = 4_194_304
    public static let maxInFlight = 8

    private let path: String
    /// The ssh host socket: one RemoteMessage per connection, no requests (decision #47).
    private let remote: Bool
    private let handler: @MainActor (ControlMessage) -> Void
    private let onRequest: @MainActor (Int, ControlCall) async -> ControlResponse
    /// remote: Hangar's line for a `statusline` payload (nil = the user's line), sent back after the reply (#103).
    private let statusline: (@Sendable (Data) -> String?)?
    private let queue = DispatchQueue(label: "hangar.control-server")
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    /// accept() hit EMFILE/ENFILE: the listener is suspended until a connection closes.
    private var listenerSuspended = false

    /// Test seams (set before `start`).
    var idleTimeout: Double = 10
    var emfileRetry: Double = 1
    private var resumeTimer: DispatchSourceTimer?
    var acceptCall: @Sendable (Int32) -> Int32 = { Darwin.accept($0, nil, nil) }

    /// Only touched on `queue`; Sendable so a finished request can carry it back for the identity check.
    private final class Connection: @unchecked Sendable {
        let source: DispatchSourceRead
        /// One-shot: closes a connection that has not delivered a full line in time.
        var idleTimer: DispatchSourceTimer?
        /// false — SO_NOSIGPIPE could not be set, so a write could kill the app with SIGPIPE.
        let canReply: Bool
        var buffer = Data()
        /// Replies not yet accepted by the socket, from `sent` on; drained by `writer` on EAGAIN.
        var outbox: [UInt8] = []
        var sent = 0
        /// Created on the first EAGAIN, suspended while the outbox is empty, cancelled only with the connection.
        var writer: DispatchSourceWrite?
        var writerSuspended = false
        var inFlight = 0
        /// remote: the header line once read, and its payload length.
        var header: Data?
        var payloadLength = 0
        init(source: DispatchSourceRead, canReply: Bool) {
            self.source = source
            self.canReply = canReply
        }
    }

    /// `remote`: the handler still has to check that the event's tab/leaf belong to that host.
    public init(path: String, remote: Bool = false, handler: @escaping @MainActor (ControlMessage) -> Void,
                onRequest: @escaping @MainActor (Int, ControlCall) async -> ControlResponse = { id, _ in
                    ControlResponse(id: id, body: .failure(ControlError(code: .unknownMethod, message: "not supported")))
                },
                statusline: (@Sendable (Data) -> String?)? = nil) {
        self.path = path
        self.remote = remote
        self.statusline = statusline
        self.handler = handler
        self.onRequest = onRequest
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
        queue.sync { shutdown() }
    }

    // A source that is suspended must be resumed before it can finish cancelling.
    private func shutdown() {
        guard let listener else { return }
        listener.cancel()
        resumeTimer?.cancel()
        resumeTimer = nil
        if listenerSuspended { listener.resume(); listenerSuspended = false }
        self.listener = nil
        for c in connections.values { cancel(c) }
        connections.removeAll()
        unlink(path)
    }

    // No other reference exists here, so touching the state without the queue is safe (and queue.sync could deadlock).
    deinit { shutdown() }

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
        let fd = acceptCall(listenFD)
        guard fd >= 0 else {
            if errno == EMFILE || errno == ENFILE, !listenerSuspended, let listener {
                listener.suspend()
                listenerSuspended = true
                // With no connection to close, nothing else would ever resume the listener.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + emfileRetry)
                timer.setEventHandler { [weak self] in self?.resumeListener() }
                resumeTimer = timer
                timer.resume()
            }
            return
        }
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
        let connection = Connection(source: source, canReply: canReply)
        connections[fd] = connection
        armIdleTimer(connection, fd)
        source.resume()
    }

    private func resumeListener() {
        resumeTimer?.cancel()
        resumeTimer = nil
        guard listenerSuspended, let listener else { return }
        listenerSuspended = false
        listener.resume()
    }

    private func armIdleTimer(_ c: Connection, _ fd: Int32) {
        c.idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.drop(fd) }
        c.idleTimer = timer
        timer.resume()
    }

    private func read(_ fd: Int32) {
        guard let c = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { drop(fd); return }
        c.buffer.append(chunk, count: n)
        if remote { readRemote(fd, c); return }
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            switch ControlMessage.decode(line) {
            case let .success(.request(r)):
                switch r.call {
                case let .failure(error):
                    respond(fd, c, ControlResponse(id: r.id, body: .failure(error)))
                case .success where c.inFlight >= Self.maxInFlight:
                    respond(fd, c, ControlResponse(id: r.id, body: .failure(ControlError(code: .busy, message: "too many requests in flight on this connection"))))
                case let .success(call):
                    c.inFlight += 1
                    c.idleTimer?.cancel()
                    c.idleTimer = nil
                    let onRequest = onRequest, id = r.id
                    Task { @MainActor [weak self] in
                        let response = await onRequest(id, call)
                        guard let self else { return }
                        self.queue.async { self.finish(fd, c, response) }
                    }
                }
            case let .success(message):
                let handler = handler
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(message) } }
                reply(fd, c, #"{"ok":true}"#)
            case .failure(.badRequest):
                let e = ControlError(code: .badRequest, message: "request needs an integer \"id\", a string \"method\" and object \"params\"")
                respond(fd, c, ControlResponse(id: nil, body: .failure(e)))
            case let .failure(error):
                reply(fd, c, #"{"ok":false,"error":"\#(error.rawValue)"}"#)
                if error == .tooLarge { drop(fd); return }
            }
            guard connections[fd] === c else { return }
        }
        if c.buffer.isEmpty, c.inFlight == 0 { armIdleTimer(c, fd) }
        if c.buffer.count > Self.maxLine {
            reply(fd, c, #"{"ok":false,"error":"too-large"}"#)
            drop(fd)
        }
    }

    /// One header + payload, one reply, then close. The idle timer is not re-armed: the whole message gets one deadline.
    private func readRemote(_ fd: Int32, _ c: Connection) {
        func refuse(_ error: ProtocolError) {
            reply(fd, c, #"{"ok":false,"error":"\#(error.rawValue)"}"#)
            drop(fd)
        }
        if c.header == nil {
            guard let nl = c.buffer.firstIndex(of: 0x0A) else {
                if c.buffer.count > RemoteMessage.maxHeader { refuse(.tooLarge) }
                return
            }
            let line = Data(c.buffer[c.buffer.startIndex..<nl])
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            switch RemoteMessage.header(line) {
            case let .request(id):
                respond(fd, c, ControlResponse(id: id, body: .failure(ControlError(code: .unknownMethod, message: "not available over ssh"))))
                drop(fd)
                return
            case let .invalid(error):
                refuse(error)
                return
            case let .message(length):
                c.header = line
                c.payloadLength = length
            }
        }
        guard let header = c.header, c.buffer.count >= c.payloadLength else { return }
        let payload = Data(c.buffer.prefix(c.payloadLength))
        // A second reply line `line:<text>` for hangar-remote to print; rendered even when there is no usage to record.
        let line = RemoteMessage.isStatusline(header) ? statusline?(payload).map { "line:" + $0.filter { $0 != "\n" && $0 != "\r" } } : nil
        switch RemoteMessage.decode(header: header, payload: payload) {
        case let .success(message):
            let handler = handler
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(message) } }
            reply(fd, c, #"{"ok":true}"# + (line.map { "\n" + $0 } ?? ""))
            drop(fd)
        case let .failure(error):
            if let line { reply(fd, c, #"{"ok":false,"error":"\#(error.rawValue)"}"# + "\n" + line); drop(fd) } else { refuse(error) }
        }
    }

    /// A reply for a connection that closed meanwhile is dropped: its fd may already belong to another client.
    private func finish(_ fd: Int32, _ c: Connection, _ response: ControlResponse) {
        guard connections[fd] === c else { return }
        c.inFlight -= 1
        respond(fd, c, response)
        // Armed even with a partial line buffered: its own timer was cancelled when the request started.
        if connections[fd] === c, c.inFlight == 0 { armIdleTimer(c, fd) }
    }

    private func respond(_ fd: Int32, _ c: Connection, _ response: ControlResponse) {
        var data = response.encoded()
        if data.count > Self.maxResponse {
            let e = ControlError(code: .tooLarge, message: "response exceeds \(Self.maxResponse) bytes")
            data = ControlResponse(id: response.id, body: .failure(e)).encoded()
        }
        enqueue(fd, c, data)
    }

    private func reply(_ fd: Int32, _ c: Connection, _ text: String) {
        enqueue(fd, c, Data((text + "\n").utf8))
    }

    /// A reader that falls more than `maxOutbox` behind is dropped rather than buffered without bound.
    private func enqueue(_ fd: Int32, _ c: Connection, _ data: Data) {
        guard c.canReply else { return }
        // Compacting once per reply, not per partial write, keeps draining linear.
        if c.sent > 0 { c.outbox.removeFirst(c.sent); c.sent = 0 }
        c.outbox.append(contentsOf: data)
        guard c.outbox.count <= Self.maxOutbox else { drop(fd); return }
        flush(fd, c)
    }

    private func flush(_ fd: Int32, _ c: Connection) {
        while c.sent < c.outbox.count {
            let n = c.outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + c.sent, $0.count - c.sent) }
            if n > 0 {
                c.sent += n
                // Draining counts as activity: a reader that keeps reading is not idle; one that stopped is dropped.
                c.idleTimer?.schedule(deadline: .now() + idleTimeout)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if let writer = c.writer {
                    if c.writerSuspended { writer.resume(); c.writerSuspended = false }
                } else {
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    writer.setEventHandler { [weak self] in
                        guard let self, self.connections[fd] === c else { return }
                        self.flush(fd, c)
                    }
                    c.writer = writer
                    writer.resume()
                }
                return
            } else {
                drop(fd)
                return
            }
        }
        c.outbox.removeAll(keepingCapacity: c.outbox.count <= 65_536)
        c.sent = 0
        if let writer = c.writer, !c.writerSuspended { writer.suspend(); c.writerSuspended = true }
    }

    private func drop(_ fd: Int32) {
        guard let c = connections.removeValue(forKey: fd) else { return }
        cancel(c)
        resumeListener()
    }

    /// The read source's cancel handler closes the fd, so it is cancelled only from the writer's cancel handler:
    /// the fd cannot be closed (and reused by accept) while the writer is still registered on it.
    private func cancel(_ c: Connection) {
        c.idleTimer?.cancel()
        guard let writer = c.writer else { c.source.cancel(); return }
        let source = c.source
        writer.setCancelHandler { source.cancel() }
        writer.cancel()
        // A suspended source never delivers its cancel handler.
        if c.writerSuspended { writer.resume(); c.writerSuspended = false }
        c.writer = nil
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
