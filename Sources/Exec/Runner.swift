import Foundation

public struct RunResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs a command (argv, never a shell string) and collects its output. A closure, not a protocol (decisions #42);
/// an ssh runner will be another value of this type (stage 6).
public struct Runner: Sendable {
    public var run: @Sendable (_ args: [String], _ cwd: String) async throws -> RunResult

    public init(run: @escaping @Sendable (_ args: [String], _ cwd: String) async throws -> RunResult) {
        self.run = run
    }

    /// Non-zero exit (incl. 127 when env cannot find the command) is returned in `status`, not thrown;
    /// throws only if the process fails to start (e.g. missing cwd) or the task is cancelled.
    public static let local = Runner { args, cwd in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
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
                for (pipe, box) in [(outPipe, out), (errPipe, err)] {
                    DispatchQueue.global().async {
                        box.data = pipe.fileHandleForReading.readDataToEndOfFile()
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

    func cancel() {
        lock.lock()
        cancelled = true
        let pid = pid, ownGroup = ownGroup
        lock.unlock()
        if pid > 0 { Self.terminate(pid, group: ownGroup) }
        finish(.failure(CancellationError()))
    }

    /// Process starts the child as leader of its own group, so git's helpers (ssh, remote-ext) are in it too:
    /// SIGTERM to the group, SIGKILL to whatever is left after 2 s (pids are not reused that fast).
    private static func terminate(_ pid: pid_t, group: Bool) {
        let target = group ? -pid : pid
        kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(target, SIGKILL) }
    }
}
