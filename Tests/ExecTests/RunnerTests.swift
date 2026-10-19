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
        #expect(Date().timeIntervalSince(start) < 10)  // far below sleep 30; loose for parallel test load
    }

    /// Runs `script` (`$0` = a file receiving the shell's pid = process group id), cancels it, returns the group id
    /// and how long cancel took.
    private func cancelScript(_ script: String) async throws -> (pgid: pid_t, seconds: TimeInterval) {
        let file = NSTemporaryDirectory() + "runner-pid-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: file) }
        let task = Task { try await Runner.local.run(["sh", "-c", "echo $$ > \"$0\"; " + script, file], NSTemporaryDirectory()) }
        var pgid: pid_t = 0
        let deadline = Date().addingTimeInterval(10)
        while pgid == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            pgid = pid_t((try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        try #require(pgid > 0)
        try await Task.sleep(nanoseconds: 200_000_000)  // let the children start
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        return (pgid, Date().timeIntervalSince(start))
    }

    /// kill(-pgid, 0) fails with ESRCH once no member of the group is left.
    private func groupGone(_ pgid: pid_t, within seconds: TimeInterval) async throws -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while kill(-pgid, 0) == 0 {
            if Date() > until { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Like a git fetch whose helper (ssh, remote-ext) holds the pipes: the whole process group dies, cancel is prompt.
    @Test func cancelKillsProcessGroup() async throws {
        let (pgid, seconds) = try await cancelScript("sleep 30 & sleep 30")
        #expect(seconds < 3)
        #expect(try await groupGone(pgid, within: 3), "process group \(pgid) still has members")
    }

    /// Members ignoring SIGTERM get SIGKILL after 2 s — all of them, not only the leader.
    @Test func cancelEscalatesToKillForTheWholeGroup() async throws {
        let (pgid, seconds) = try await cancelScript("trap '' TERM; sleep 30 & sleep 30")
        #expect(seconds < 3)
        #expect(try await groupGone(pgid, within: 4), "process group \(pgid) still has members")
    }

    /// A child that left the group still holds the pipes: cancel doesn't wait for their EOF.
    @Test func cancelDoesNotWaitForEscapedChild() async throws {
        let escaped = NSTemporaryDirectory() + "runner-escaped-\(UUID().uuidString)"
        defer {
            if let pid = pid_t((try? String(contentsOfFile: escaped, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: escaped)
        }
        let (_, seconds) = try await cancelScript(
            "perl -e 'setpgrp(0, 0); open(F, \">\", $ARGV[0]); print F $$; close F; exec \"sleep\", \"30\"' \(escaped) & sleep 30")
        #expect(seconds < 3)
    }

    @Test func fastExitingChildKeepsOutput() async throws {
        for i in 0..<200 {
            let r = try await Runner.local.run(["printf", "x"], NSTemporaryDirectory())
            #expect(r.stdout == "x", "run \(i)")
        }
    }

    @Test func startFailureThrows() async {
        await #expect(throws: (any Error).self) {
            try await Runner.local.run(["true"], "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func missingCommandIsStatus127() async throws {
        let r = try await Runner.local.run(["definitely-not-a-command-xyz"], NSTemporaryDirectory())
        #expect(r.status == 127)
    }
}
