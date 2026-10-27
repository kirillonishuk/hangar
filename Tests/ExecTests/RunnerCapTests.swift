import Foundation
import Testing
@testable import Exec

@Suite struct RunnerCapTests {
    /// A server printing without end must not grow memory without bound: past the cap the child is killed.
    @Test func endlessOutputIsCappedAndKilled() async throws {
        let r = try await runProcess("/bin/sh", ["-c", "exec yes"], cwd: "/", env: [:], maxOutput: 4096)
        #expect(r.stdout.utf8.count == 4096)
        #expect(r.status != 0)
    }

    @Test func outputUnderCapIsComplete() async throws {
        let r = try await runProcess("/bin/sh", ["-c", "printf abc; printf err >&2"], cwd: "/", env: [:], maxOutput: 4096)
        #expect(r == RunResult(status: 0, stdout: "abc", stderr: "err"))
    }

    /// Find in files (#91): stdout arrives in chunks; returning false stops the child, the rest is dropped.
    @Test func streamStopsWhenTheReaderHasEnough() async throws {
        let seen = Seen()
        let r = try await streamProcess("/bin/sh", ["-c", "exec yes"], cwd: "/", env: [:]) { seen.add($0.count) < 100_000 }
        #expect(seen.total >= 100_000)
        #expect(r.status != 0 && r.stdout.isEmpty)
    }

    /// The remote wrapper (#91): stdin EOF (the ssh session gone) terminates the command, not just its next write.
    @Test func watchdogKillsTheCommandOnStdinEOF() async throws {
        let dir = NSTemporaryDirectory() + "hg-watchdog-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let argv = remoteWatchdogArgv(["/bin/sh", "-c", #"echo $$ > "$1"; exec sleep 60"#, "sh", dir + "/pid"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        var pid: pid_t?
        for _ in 0..<400 where pid == nil {
            try await Task.sleep(for: .milliseconds(25))
            pid = (try? String(contentsOfFile: dir + "/pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)
        try stdin.fileHandleForWriting.close()
        var gone = false
        for _ in 0..<400 where !gone {
            gone = kill(child, 0) != 0 && !p.isRunning
            if !gone { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(gone)
        if !gone { kill(child, SIGKILL); p.terminate() }
    }

    /// A command that ends on its own ends the wrapper too (stdin still held open), with its status and output.
    @Test func watchdogPassesStatusAndOutput() async throws {
        let seen = Seen()
        let argv = remoteWatchdogArgv(["/bin/sh", "-c", "printf hi; exit 3"])
        let r = try await streamProcess(argv[0], Array(argv.dropFirst()), cwd: "/", env: [:], holdStdin: true) { seen.add($0.count) < .max }
        #expect(seen.total == 2)
        #expect(r.status == 3)
    }

    @Test func streamKeepsStderrAndStatus() async throws {
        let seen = Seen()
        let r = try await streamProcess("/bin/sh", ["-c", "printf abc; printf err >&2; exit 1"], cwd: "/", env: [:]) { seen.add($0.count) < .max }
        #expect(seen.total == 3)
        #expect(r == RunResult(status: 1, stdout: "", stderr: "err"))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func add(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; bytes += n; return bytes }
}
