import Foundation

/// How to start one language server (#90): a local executable on stdio, with the login shell's PATH (pyright needs
/// `node`, gopls `go`, rust-analyzer `cargo`; an app started from Finder has none of them).
struct LspLaunch: Equatable, Sendable {
    var executable: String
    var args: [String]
    var cwd: String
    var path: String?
}

/// One JSON-RPC message from a language server (`TsFramer` frames them: the same `Content-Length` header). Untrusted:
/// anything that is not a well-typed response, request or notification is ignored.
enum LspMessage {
    case response(id: Int, result: Any?, error: String?)
    /// The server asks the client; `id` is echoed back as is (an integer or a string).
    case request(id: Any, method: String, params: Any?)
    case notification(method: String, params: Any?)

    init?(_ o: [String: Any]) {
        let method = (o["method"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
        let id = o["id"]
        if let method {
            if let id {
                guard Self.validId(id) else { return nil }
                self = .request(id: id, method: method, params: o["params"])
            } else {
                self = .notification(method: method, params: o["params"])
            }
            return
        }
        guard let n = id as? NSNumber, !Self.isBool(n), let i = n as? Int else { return nil }
        let error = (o["error"] as? [String: Any]).map { e in ((e["message"] as? String) ?? "error").prefix(500) }.map(String.init)
        guard error != nil || o.keys.contains("result") else { return nil }
        self = .response(id: i, result: o["result"] is NSNull ? nil : o["result"], error: error)
    }

    private static func validId(_ id: Any) -> Bool {
        if let s = id as? String { return s.utf8.count <= 256 }
        guard let n = id as? NSNumber, !isBool(n) else { return false }
        return n as? Int != nil
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

/// `Content-Length: N\r\n\r\n` + the JSON body (LSP base protocol).
func lspFrame(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let body = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
    return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
}

/// One language server process: framed JSON-RPC both ways. Requests resolve with their response (nil on exit or
/// stop); the server's own requests get an answer from `LspMap.reply`; notifications go to `onNotification`.
/// Writes run on their own queue so a busy server never blocks the UI.
@MainActor final class LspServer {
    struct Reply: @unchecked Sendable { var result: Any?; var error: String? }

    let launch: LspLaunch
    var onNotification: ((String, Any?) -> Void)?
    /// The process ended without `stop()`.
    var onExit: ((Int32) -> Void)?
    /// Answers `workspace/workspaceFolders`.
    var folders: [[String: Any]] = []
    private var process: Process?
    private var input: FileHandle?
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<Reply?, Never>] = [:]
    private var stopping = false
    private let writes = DispatchQueue(label: "hangar.lsp.write")

    init(launch: LspLaunch) { self.launch = launch }

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.args
        p.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        if let path = launch.path { p.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 } }
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let reader = Reader()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let messages = Reader.Batch(list: reader.feed(data))
            guard !messages.list.isEmpty else { return }
            // FIFO onto the main thread: the server's order is kept.
            DispatchQueue.main.async { MainActor.assumeIsolated { messages.list.forEach { self?.receive($0) } } }
        }
        p.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status) } }
        }
        try p.run()
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = p
        input = inPipe.fileHandleForWriting
    }

    func notify(_ method: String, _ params: Any?) {
        var m: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { m["params"] = params }
        write(lspFrame(m))
    }

    func request(_ method: String, _ params: Any?) async -> Reply? {
        guard isRunning, !stopping else { return nil }
        nextId += 1
        let id = nextId
        var m: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { m["params"] = params }
        guard let frame = lspFrame(m) else { return nil }
        return await withCheckedContinuation { cont in
            pending[id] = cont
            write(frame)
        }
    }

    /// `shutdown`, then `exit` and EOF; a server still alive 3 s later is terminated.
    func stop() {
        guard !stopping else { return }
        if isRunning {
            nextId += 1
            write(lspFrame(["jsonrpc": "2.0", "id": nextId, "method": "shutdown"]))
            notify("exit", nil)
        }
        stopping = true
        let input = input
        writes.async { try? input?.close() }
        self.input = nil
        failPending()
        guard let p = process, p.isRunning else { return }
        Task { [weak p] in
            try? await Task.sleep(for: .seconds(3))
            if let p, p.isRunning { p.terminate() }
        }
    }

    private func write(_ data: Data?) {
        guard let data, let input, !stopping else { return }
        writes.async {
            let fd = input.fileDescriptor
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
        }
    }

    private func receive(_ object: [String: Any]) {
        switch LspMessage(object) {
        case .response(let id, let result, let error)?:
            pending.removeValue(forKey: id)?.resume(returning: Reply(result: result, error: error))
        case .request(let id, let method, let params)?:
            var m: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let result = LspMap.reply(method, params, folders: folders) {
                m["result"] = result
            } else {
                m["error"] = ["code": -32601, "message": "unsupported: " + method]
            }
            write(lspFrame(m))
        case .notification(let method, let params)?: onNotification?(method, params)
        case nil: break
        }
    }

    private func exited(_ status: Int32) {
        failPending()
        process = nil
        input = nil
        if !stopping { onExit?(status) }
    }

    private func failPending() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(returning: nil) }
    }

    /// The framer behind a lock: the pipe's handler runs on its own queue.
    private final class Reader: @unchecked Sendable {
        /// Parsed JSON handed to the main thread once (never shared).
        struct Batch: @unchecked Sendable { var list: [[String: Any]] }
        private let lock = NSLock()
        private var framer = TsFramer()
        func feed(_ data: Data) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return framer.feed(data)
        }
    }
}
