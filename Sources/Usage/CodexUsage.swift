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
        signal(SIGPIPE, SIG_IGN)
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
        p.terminationHandler = { [self] _ in finish(.failure(CodexReadError(reason: "process exited"))) }
        outPipe.fileHandleForReading.readabilityHandler = { [self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; finish(.failure(CodexReadError(reason: "eof"))) } else { feed(d) }
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

    private func feed(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<i])
            buffer.removeSubrange(buffer.startIndex...i)
        }
        lock.unlock()
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == 1 else { continue }
            if obj["error"] != nil { finish(.failure(CodexReadError(reason: "error response"))) }
            else if let r = obj["result"] { finish(.success(Box(value: r))) }
            else { finish(.failure(CodexReadError(reason: "empty response"))) }
            return
        }
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
            // Process makes the child leader of its own group → kill the group, SIGKILL whatever is left after 2 s.
            let target = getpgid(pid) == pid ? -pid : pid
            kill(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(target, SIGKILL) }
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
