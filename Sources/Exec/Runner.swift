import Foundation

public struct RunResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Runs a command (argv, never a shell string) and collects its output. A closure, not a protocol (decisions #42);
/// `Runner.ssh` (SSH.swift) is another value of this type.
public struct Runner: Sendable {
    public var run: @Sendable (_ args: [String], _ cwd: String) async throws -> RunResult
    /// The command runs on this Mac (its paths can be stat'ed locally).
    public var isLocal: Bool

    public init(isLocal: Bool = false, run: @escaping @Sendable (_ args: [String], _ cwd: String) async throws -> RunResult) {
        self.isLocal = isLocal
        self.run = run
    }

    /// Non-zero exit (incl. 127 when env cannot find the command) is returned in `status`, not thrown;
    /// throws only if the process fails to start (e.g. missing cwd) or the task is cancelled.
    public static let local = Runner(isLocal: true) { args, cwd in
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return try await runProcess("/usr/bin/env", args, cwd: cwd, env: env)
    }
}

/// Starts `executable` and collects stdout/stderr; `input` (if any) is written to stdin, else stdin is /dev/null.
/// Cancel terminates the child (and its process group). Past `maxOutput` bytes on stdout or stderr the child is
/// terminated and the stream is cut there (untrusted servers).
func runProcess(_ executable: String, _ args: [String], cwd: String, env: [String: String], input: Data? = nil,
                maxOutput: Int = .max) async throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = env
    let inPipe = input.map { _ in Pipe() }
    process.standardInput = inPipe ?? FileHandle.nullDevice
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let run = RunState()
    let result: RunResult = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            run.set(cont)
            // Both pipes are drained in parallel: a 64 KB pipe buffer would otherwise block the child.
            let group = DispatchGroup()
            let out = Captured(), err = Captured()
            process.terminationHandler = { p in
                group.wait()
                run.finish(.success(RunResult(status: p.terminationStatus, stdout: out.string, stderr: err.string)))
            }
            // Entered before launch so a fast-exiting child cannot make group.wait() return early.
            group.enter(); group.enter()
            do {
                try run.launch(process)
            } catch {
                group.leave(); group.leave()
                run.finish(.failure(error))
                return
            }
            if let inPipe, let input {
                DispatchQueue.global().async { writeAll(input, to: inPipe.fileHandleForWriting) }
            }
            for (pipe, box) in [(outPipe, out), (errPipe, err)] {
                DispatchQueue.global().async {
                    box.data = readCapped(pipe.fileHandleForReading, max: maxOutput) { run.kill() }
                    group.leave()
                }
            }
        }
    } onCancel: {
        run.cancel()
    }
    try Task.checkCancellation()
    return result
}

/// Reads to EOF, keeping at most `max` bytes; `over` runs once when more arrives (the reader keeps draining to EOF).
private func readCapped(_ h: FileHandle, max: Int, over: () -> Void) -> Data {
    guard max < .max else { return h.readDataToEndOfFile() }
    var data = Data(), killed = false
    while let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty {
        let room = max - data.count
        data.append(chunk.prefix(room))
        if chunk.count > room, !killed { killed = true; over() }
    }
    return data
}

/// Writes then closes; a child that exits without reading gets EPIPE, not a SIGPIPE that would kill this process.
private func writeAll(_ data: Data, to handle: FileHandle) {
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
    }
    try? handle.close()
}

private final class Captured: @unchecked Sendable {
    var data = Data()
    var string: String { String(decoding: data, as: UTF8.self) }
}

/// One run: resumes its continuation exactly once — on exit, on launch failure, or right away on cancel (a child
/// that left the process group may hold the pipes open; its output is no longer wanted).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<RunResult, Error>?
    private var cancelled = false
    private var pid: pid_t = 0
    private var ownGroup = false

    func set(_ c: CheckedContinuation<RunResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        cont = c
    }

    /// Cancel before launch → the process is never started.
    func launch(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        pid = p.processIdentifier
        ownGroup = getpgid(pid) == pid
    }

    func finish(_ result: Result<RunResult, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
    }

    /// Terminates the child; its exit still finishes the run with what was read.
    func kill() {
        lock.lock()
        let pid = pid, ownGroup = ownGroup
        lock.unlock()
        if pid > 0 { terminateProcess(pid, group: ownGroup) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pid = pid, ownGroup = ownGroup
        lock.unlock()
        if pid > 0 { terminateProcess(pid, group: ownGroup) }
        finish(.failure(CancellationError()))
    }
}
