import Exec
import Foundation

/// The project's own TypeScript (#NN-tsserver): nothing is installed, node runs its `lib/tsserver.js`.
struct TsInstall: Equatable, Hashable, Sendable {
    var tsserver: String
    var version: String
    var node: String
    /// The folder holding `node_modules/typescript` (tsserver's cwd).
    var cwd: String

    /// Where node usually is when the login shell doesn't say.
    static let fallbackNodes = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]

    init(tsserver: String, version: String, node: String, cwd: String) {
        self.tsserver = tsserver; self.version = version; self.node = node; self.cwd = cwd
    }

    init(_ l: TsMap.Lookup, node: String) {
        let suffix = "/node_modules/typescript/lib/tsserver.js"
        self.init(tsserver: l.tsserver, version: l.version, node: node,
                  cwd: l.tsserver.hasSuffix(suffix) ? String(l.tsserver.dropLast(suffix.count)) : "/")
    }

    /// Flags after the script: no typings download (no network, no child), diagnostics only when asked.
    func serverArgs(locale: String) -> [String] {
        ["--max-old-space-size=2048", tsserver, "--disableAutomaticTypingAcquisition", "--noGetErrOnBackgroundUpdate", "--locale", locale]
    }

    func localLaunch(locale: String) -> TsLaunch {
        TsLaunch(executable: node, args: serverArgs(locale: locale), cwd: cwd)
    }

    /// This Mac: the lookup script for typescript, `node` from `node()` (the login shell's PATH, cached by the caller).
    static func localLookup(dir: String, root: String, node: @Sendable () async -> String?) async -> TsLookup {
        guard let r = try? await Runner.local.run(["sh", "-c", TsMap.lookupScript, "sh", dir, root], "/") else { return .noTypeScript }
        guard let found = TsMap.parseLookup(r.stdout) else { return .noTypeScript }
        guard let node = await node() else { return .noNode }
        return .found(TsInstall(found, node: node))
    }
}

enum TsLookup: Equatable, Sendable {
    case found(TsInstall)
    case noTypeScript, noNode, notConnected
}

/// How to start one tsserver: node locally, or ssh to the host running node there (stdio over the session).
struct TsLaunch: Equatable, Sendable {
    var executable: String
    var args: [String]
    var cwd: String
}

/// One tsserver process: JSON lines in, framed JSON out (`TsFramer`). Requests resolve with their response's body
/// (nil on failure or exit); events go to `onEvent`. Writes run on their own queue so a busy server never blocks the UI.
@MainActor final class TsServer {
    struct Response: @unchecked Sendable { var success: Bool; var body: Any?; var message: String? }

    let launch: TsLaunch
    var onEvent: ((String, Any?) -> Void)?
    /// The process ended without `stop()`.
    var onExit: ((Int32) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var seq = 0
    private var pending: [Int: CheckedContinuation<Response?, Never>] = [:]
    private var stopping = false
    private let writes = DispatchQueue(label: "hangar.tsserver.write")

    init(launch: TsLaunch) { self.launch = launch }

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.args
        p.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
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
            // FIFO onto the main thread: responses and events keep tsserver's order.
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

    /// A command without a response (`open`, `change`, `close`, `geterr`).
    func notify(_ command: String, _ arguments: [String: Any]) {
        seq += 1
        write(tsRequestLine(seq: seq, command: command, arguments: arguments))
    }

    func request(_ command: String, _ arguments: [String: Any]) async -> Response? {
        guard isRunning, !stopping else { return nil }
        seq += 1
        let id = seq
        guard let line = tsRequestLine(seq: id, command: command, arguments: arguments) else { return nil }
        return await withCheckedContinuation { cont in
            pending[id] = cont
            write(line)
        }
    }

    /// `exit`, then stdin closes (a remote tsserver ends on EOF too); a server still alive 3 s later is terminated.
    func stop() {
        guard !stopping else { return }
        notify("exit", [:])
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
        switch TsMessage(object) {
        case .response(let seq, let success)?:
            pending.removeValue(forKey: seq)?.resume(returning: Response(success: success, body: object["body"], message: object["message"] as? String))
        case .event(let name)?: onEvent?(name, object["body"])
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
