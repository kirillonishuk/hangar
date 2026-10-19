import Foundation
import Testing
@testable import Exec

@Suite struct RunnerTests {
    @Test func runReturnsStatusAndOutput() async throws {
        let r = try await Runner.local.run(["sh", "-c", "echo out; echo err >&2; exit 3"], NSTemporaryDirectory())
        #expect(r.status == 3)
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "err\n")
    }

    @Test func runUsesCwd() async throws {
        let dir = NSTemporaryDirectory() + "runner-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try await Runner.local.run(["pwd"], dir)
        let got = URL(fileURLWithPath: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        #expect(got == URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let r = try await Runner.local.run(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' a"], NSTemporaryDirectory())
        #expect(r.stdout.count == 300000)
    }

    @Test func noPromptEnv() async throws {
        let r = try await Runner.local.run(["sh", "-c", "echo $GIT_TERMINAL_PROMPT"], NSTemporaryDirectory())
        #expect(r.stdout == "0\n")
    }

    @Test func cancelTerminatesProcess() async throws {
        let start = Date()
        let task = Task { try await Runner.local.run(["sleep", "30"], NSTemporaryDirectory()) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
