import Foundation
import Testing
@testable import Exec

/// `detachedChildren`: tool shells lead their own process group, MCP servers share the agent's (#128).
@Suite struct ProcessProbeTests {
    private func spawn(_ script: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        return p
    }

    private func settle(_ pid: Int32, until ok: (Int?) -> Bool) -> Int? {
        var n = detachedChildren(of: pid)
        for _ in 0..<40 where !ok(n) {
            usleep(50_000)
            n = detachedChildren(of: pid)
        }
        return n
    }

    @Test func countsOnlyChildrenInTheirOwnGroup() throws {
        // `set -m`: each background job gets a process group of its own, as Claude Code's detached Bash tool.
        let detached = try spawn("set -m; sleep 30 & sleep 30 & wait")
        let shared = try spawn("sleep 30 & sleep 30 & wait")
        defer {
            for p in [detached, shared] {
                _ = Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-P", String(p.processIdentifier)])
                p.terminate()
            }
        }
        #expect(settle(detached.processIdentifier) { $0 == 2 } == 2)
        // Its two sleeps share the shell's group: none detached.
        usleep(300_000)
        #expect(detachedChildren(of: shared.processIdentifier) == 0)
        #expect(detachedChildren(of: 999_999) == nil)
        #expect(detachedChildren(of: 1) == nil)
    }
}
