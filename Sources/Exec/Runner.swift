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

    /// Non-zero exit is not an error; throws only if the process fails to start or the task is cancelled.
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

        let cancel = CancelFlag()
        let result: RunResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Both pipes are drained in parallel: a 64 KB pipe buffer would otherwise block the child.
                let group = DispatchGroup()
                let out = Captured(), err = Captured()
                process.terminationHandler = { p in
                    group.wait()
                    cont.resume(returning: RunResult(status: p.terminationStatus, stdout: out.string, stderr: err.string))
                }
                do {
                    try cancel.launch(process)
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                for (pipe, box) in [(outPipe, out), (errPipe, err)] {
                    group.enter()
                    DispatchQueue.global().async {
                        box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
            }
        } onCancel: {
            cancel.cancel(process)
        }
        try Task.checkCancellation()
        return result
    }
}

private final class Captured: @unchecked Sendable {
    var data = Data()
    var string: String { String(decoding: data, as: UTF8.self) }
}

/// Handles cancel arriving before or after launch.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func launch(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        try p.run()
        started = true
        if cancelled { p.terminate() }
    }

    func cancel(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if started, p.isRunning { p.terminate() }
    }
}
