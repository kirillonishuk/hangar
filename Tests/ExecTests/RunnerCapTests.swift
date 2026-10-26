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
