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
}
