import Foundation
import Exec

// verify: проверить, когда codex будет установлен — схема `account/rateLimits/read` взята из документации.
public func codexUsage(fromResult result: Any, now: Date) -> AgentUsage? {
    var found: [UsageWindow] = []
    var plan: String?
    func walk(_ node: Any) {
        if let d = node as? [String: Any] {
            if let p = (d["usedPercent"] as? NSNumber)?.doubleValue, let m = (d["windowDurationMins"] as? NSNumber)?.intValue {
                let kind: WindowKind? = m == 300 ? .session : m == 10080 ? .weekly : nil
                if let kind, !found.contains(where: { $0.kind == kind }) {
                    let r = (d["resetsAt"] as? NSNumber)?.doubleValue
                    found.append(UsageWindow(kind: kind, usedPercent: p, resetsAt: r.map(Date.init(timeIntervalSince1970:)), updatedAt: now))
                }
            }
            for k in d.keys.sorted() {
                if k == "planType", plan == nil, let s = d[k] as? String { plan = s }
                walk(d[k]!)
            }
        } else if let a = node as? [Any] {
            a.forEach(walk)
        }
    }
    walk(result)
    guard !found.isEmpty else { return nil }
    found.sort { $0.kind == .session && $1.kind != .session }
    return AgentUsage(windows: found, plan: plan, updatedAt: now)
}

public struct CodexReadError: Error, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

/// Short-lived `codex app-server`: three JSON lines in, read stdout until the reply with id 1, then terminate.
public struct CodexUsageReader: Sendable {
    public var executable: String
    public var timeout: Duration

    public init(executable: String, timeout: Duration = .seconds(10)) {
        self.executable = executable; self.timeout = timeout
    }

    // verify: проверить, когда codex будет установлен
    private static let input = [
        #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"hangar","title":"Hangar","version":"0.3"}}}"#,
        #"{"method":"initialized"}"#,
        #"{"method":"account/rateLimits/read","id":1}"#,
    ].joined(separator: "\n") + "\n"

    public func read(now: Date) async throws -> AgentUsage {
        let session = CodexSession()
        let timeout = timeout
        let exe = executable
        let timer = Task {
            try await Task.sleep(for: timeout)
            session.finish(.failure(CodexReadError(reason: "timeout")))
        }
        defer { timer.cancel() }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                session.start(exe, input: Self.input, cont)
            }
        } onCancel: {
            session.finish(.failure(CancellationError()))
        }
        guard let usage = codexUsage(fromResult: result.value, now: now) else { throw CodexReadError(reason: "no windows") }
        return usage
    }
}

/// Parsed JSON, read-only after creation.
private struct Box: @unchecked Sendable { var value: Any }

/// One run; resumes exactly once and always kills the process (group) on the way out.
private final class CodexSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Box, Error>?
    private var done = false
    private var process: Process?
    private var buffer = Data()
    /// Serializes reads of the stdout fd (readability handler vs. the final drain on exit).
    private let readLock = NSLock()

    func start(_ exe: String, input: String, _ c: CheckedContinuation<Box, Error>) {
        lock.lock()
        if done { lock.unlock(); c.resume(throwing: CancellationError()); return }
        cont = c
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["app-server"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        // A write to a dead server must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = outPipe.fileHandleForReading
        p.terminationHandler = { [self] _ in
            // The reply may be in the pipe already (reply, then exit): drain and parse before failing.
            reader.readabilityHandler = nil
            _ = pump(outFD, final: true)
            finish(.failure(CodexReadError(reason: "process exited")))
        }
        reader.readabilityHandler = { [self] h in
            if pump(outFD, final: false) { h.readabilityHandler = nil; finish(.failure(CodexReadError(reason: "eof"))) }
        }
        do { try p.run() } catch {
            lock.unlock()
            finish(.failure(error)); return
        }
        process = p
        lock.unlock()
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        // stdin stays open (a server may exit on EOF before replying); the process is terminated in finish.
    }

    /// Reads everything available; true at EOF. `final` also parses a last line without a trailing newline.
    private func pump(_ fd: Int32, final: Bool) -> Bool {
        readLock.lock(); defer { readLock.unlock() }
        var eof = false
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            else { eof = n == 0; break }  // 0 = EOF, -1 = EAGAIN/error: nothing more right now
        }
        var lines: [Data] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<i])
            buffer.removeSubrange(buffer.startIndex...i)
        }
        if (final || eof), !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == 1 else { continue }
            if obj["error"] != nil { finish(.failure(CodexReadError(reason: "error response"))) }
            else if let r = obj["result"] { finish(.success(Box(value: r))) }
            else { finish(.failure(CodexReadError(reason: "empty response"))) }
            return eof
        }
        return eof
    }

    func finish(_ result: Result<Box, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let c = cont, p = process
        cont = nil
        lock.unlock()
        if let p, p.isRunning {
            let pid = p.processIdentifier
            terminateProcess(pid, group: getpgid(pid) == pid)
        }
        c?.resume(with: result)
    }
}

public func resolveCodex(runner: Runner, shell: String) async -> String? {
    guard let r = try? await runner.run([shell, "-l", "-i", "-c", "command -v codex"], NSHomeDirectory()), r.status == 0 else { return nil }
    return r.stdout.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
}

public struct CodexRefreshGate: Sendable {
    private var running = false
    private var lastEnd: Date?

    public init() {}

    public mutating func begin(afterTurn: Bool, now: Date) -> Bool {
        if running { return false }
        if afterTurn, let last = lastEnd, now.timeIntervalSince(last) < 60 { return false }
        running = true
        return true
    }

    public mutating func end(now: Date) { running = false; lastEnd = now }
}
